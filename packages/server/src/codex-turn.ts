import { spawn, type ChildProcess } from "node:child_process";
import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import os from "node:os";
import type { ChatPendingAction, ClientMessage } from "@agent-visor/protocol";
import { agentVisorVersion } from "./runtime-version.js";

export type CodexActionRegistrar = (
  sessionId: string,
  pending: ChatPendingAction,
  respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>,
  generation?: number,
) => () => void;

/**
 * The provider's JSON-RPC id is only unique within one app-server process.
 * Keep approval routing tied to every non-sensitive owner coordinate instead
 * of exposing that id (or any prompt content) to the renderer. The process
 * instance id is generated once per app-server child and prevents two
 * concurrent children from colliding when they reuse the same JSON-RPC ids.
 */
export type CodexApprovalOwner = {
  sessionId: string;
  threadId: string;
  turnId: string;
  deliveryId: string;
  requestId?: string;
  generation?: number;
  appServerRequestId: string | number;
  appServerInstanceId: string;
};

export function codexApprovalId(owner: CodexApprovalOwner): string {
  const ownerIdentity = JSON.stringify([
    ["session", owner.sessionId],
    ["thread", owner.threadId],
    ["turn", owner.turnId],
    ["delivery", owner.deliveryId],
    ["request", owner.requestId ?? null],
    ["generation", owner.generation ?? null],
    ["rpc", owner.appServerRequestId],
    ["process", owner.appServerInstanceId],
  ]);
  return `codex-approval-${createHash("sha256").update(ownerIdentity, "utf8").digest("hex")}`;
}

type ActiveTurn = {
  stop(error?: Error): void;
  interrupt(): boolean;
};

const activeTurns = new Set<ActiveTurn>();
const activeTurnsByIdentity = new Map<string, Set<ActiveTurn>>();
const activeDeliveryIDsByThread = new Map<string, Set<string>>();

export async function sendCodexTurn(
  threadId: string,
  text: string,
  imagePaths: string[],
  registerAction?: CodexActionRegistrar,
  deliveryId?: string,
  requestId?: string,
  generation?: number,
): Promise<void> {
  const executable = await codexExecutable();
  if (!executable) throw new Error("Codex message delivery is unavailable.");
  const appServerInstanceId = randomUUID();
  await new Promise<void>((resolve, reject) => {
    const child = spawn(executable, ["app-server", "--listen", "stdio://"], {
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffer = "";
    let outputBytes = 0;
    let accepted = false;
    let closed = false;
    const unregisters = new Map<string, () => void>();
    let turnId: string | undefined;
    let registeredIdentity = false;
    let cancelRequested = false;
    let deadline = setTimeout(() => cleanup(new Error("Codex message delivery timed out.")), 10_000);
    const activeTurn: ActiveTurn = {
      stop: cleanup,
      interrupt: () => {
        if (cancelRequested) return true;
        if (!turnId || closed) return false;
        cancelRequested = true;
        write({
          id: randomUUID(),
          method: "turn/interrupt",
          params: { threadId, expectedTurnId: turnId },
        });
        return true;
      },
    };
    activeTurns.add(activeTurn);

    child.once("error", cleanup);
    child.once("close", (code) => {
      cleanup(accepted ? undefined : new Error(`Codex message delivery exited with status ${code ?? "unknown"}.`));
    });
    child.stdin.on("error", cleanup);
    child.stdout.on("error", cleanup);
    child.stderr?.on("data", countOutput);
    child.stdout.on("data", (chunk: Buffer) => {
      countOutput(chunk);
      if (closed) return;
      buffer += chunk.toString("utf8");
      while (buffer.includes("\n")) {
        const newline = buffer.indexOf("\n");
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let message: Record<string, unknown>;
        try { message = JSON.parse(line) as Record<string, unknown>; } catch { continue; }
        if (message.error) return cleanup(new Error(codexError(message.error)));
        if (message.id === 1) {
          write({ method: "initialized" });
          write({ id: 2, method: "thread/resume", params: { threadId } });
        } else if (message.id === 2) {
          write({
            id: 3,
            method: "turn/start",
            params: {
              threadId,
              input: [
                ...(text ? [{ type: "text", text }] : []),
                ...imagePaths.map((path) => ({ type: "localImage", path })),
              ],
            },
          });
        } else if (message.id === 3) {
          turnId = codexTurnID(message.result);
          if (!turnId) return cleanup(new Error("Codex did not return a concrete turn ID."));
          accepted = true;
          registerActiveIdentity();
          clearTimeout(deadline);
          deadline = setTimeout(() => cleanup(), 30 * 60_000);
          deadline.unref();
          resolve();
        } else if (typeof message.method === "string") {
          if (message.method === "turn/started") {
            turnId = turnId ?? codexTurnID(message.params);
            registerActiveIdentity();
          }
          if (message.method === "turn/completed") {
            cleanup();
          } else if (message.id !== undefined && registerAction) {
            const pending = codexPendingAction(message.method, message.params);
            if (!pending) {
              write({ id: message.id, error: { code: -32601, message: "Unsupported Codex request." } });
              continue;
            }
            const requestKey = String(message.id);
            if (unregisters.has(requestKey)) {
              write({ id: message.id, error: { code: -32000, message: "This Codex approval request is already pending." } });
              continue;
            }
            // A request is routable only after the provider has supplied a
            // concrete turn and the renderer has supplied its delivery
            // identity. Without both, fail closed rather than routing an
            // approval by a process-local JSON-RPC id.
            if (!turnId || !deliveryId) {
              write({
                id: message.id,
                error: { code: -32000, message: "This Codex approval has no complete owner identity." },
              });
              continue;
            }
            const approvalId = codexApprovalId({
              sessionId: threadId,
              threadId,
              turnId,
              deliveryId,
              ...(requestId ? { requestId } : {}),
              ...(generation !== undefined ? { generation } : {}),
              appServerRequestId: message.id as string | number,
              appServerInstanceId,
            });
            const pendingWithIdentity = { ...pending, approvalId };
            const unregister = registerAction(threadId, pendingWithIdentity, async (response) => {
              write(codexResponseFor(message.id!, message.method as string, message.params, response));
              unregisters.get(requestKey)?.();
              unregisters.delete(requestKey);
            }, generation);
            unregisters.set(requestKey, unregister);
          }
        }
      }
    });

    write({
      id: 1,
      method: "initialize",
      params: { clientInfo: { name: "agent-visor", version: agentVisorVersion() } },
    });

    function countOutput(chunk: Buffer): void {
      // ponytail: one MiB per turn; raise or stream-account if large turns reach this limit.
      outputBytes += chunk.length;
      if (outputBytes > 1_048_576) cleanup(new Error("Codex message delivery returned too much output."));
    }

    function write(message: unknown): void {
      if (!closed) child.stdin.write(`${JSON.stringify(message)}\n`);
    }

    function registerActiveIdentity(): void {
      if (registeredIdentity || !turnId || !deliveryId || closed) return;
      const key = activeTurnKey(threadId, deliveryId);
      let turns = activeTurnsByIdentity.get(key);
      if (!turns) {
        turns = new Set();
        activeTurnsByIdentity.set(key, turns);
      }
      turns.add(activeTurn);
      let deliveryIDs = activeDeliveryIDsByThread.get(threadId);
      if (!deliveryIDs) {
        deliveryIDs = new Set();
        activeDeliveryIDsByThread.set(threadId, deliveryIDs);
      }
      deliveryIDs.add(deliveryId);
      registeredIdentity = true;
    }

    function cleanup(error?: Error): void {
      if (closed) return;
      closed = true;
      activeTurns.delete(activeTurn);
      if (registeredIdentity && deliveryId) {
        const key = activeTurnKey(threadId, deliveryId);
        const turns = activeTurnsByIdentity.get(key);
        turns?.delete(activeTurn);
        if (turns?.size === 0) {
          activeTurnsByIdentity.delete(key);
          const deliveryIDs = activeDeliveryIDsByThread.get(threadId);
          deliveryIDs?.delete(deliveryId);
          if (deliveryIDs?.size === 0) activeDeliveryIDsByThread.delete(threadId);
        }
      }
      clearTimeout(deadline);
      for (const unregister of unregisters.values()) unregister();
      unregisters.clear();
      child.stdin.destroy();
      child.stdout.destroy();
      stop(child);
      if (!accepted && error) reject(error);
    }
  });
}

export function stopCodexTurns(): void {
  for (const turn of [...activeTurns]) turn.stop(new Error("Codex message delivery stopped."));
}

/** Interrupt one daemon-owned Codex turn. Returns false when no live turn is known. */
export function stopCodexTurn(threadId: string, deliveryId?: string): boolean {
  if (!deliveryId) return false;
  const turns = activeTurnsByIdentity.get(activeTurnKey(threadId, deliveryId));
  if (!turns?.size) return false;
  let interrupted = false;
  for (const turn of turns) interrupted = turn.interrupt() || interrupted;
  return interrupted;
}

export function hasActiveCodexTurn(threadId: string, deliveryId?: string): boolean {
  if (!deliveryId) return false;
  return (activeTurnsByIdentity.get(activeTurnKey(threadId, deliveryId))?.size ?? 0) > 0;
}

/**
 * Return the newest exact active delivery only after its concrete turn is
 * registered. Renderer state follows the newest submitted delivery, so the
 * provider capability must select that same insertion-order policy when more
 * than one daemon-owned turn is live.
 */
export function activeCodexTurnDeliveryId(threadId: string): string | undefined {
  const deliveryIDs = activeDeliveryIDsByThread.get(threadId);
  const deliveryId = deliveryIDs ? [...deliveryIDs].at(-1) : undefined;
  return typeof deliveryId === "string" ? deliveryId : undefined;
}

function activeTurnKey(threadId: string, deliveryId: string): string {
  return JSON.stringify([threadId, deliveryId]);
}

export function codexPendingAction(method: string, value: unknown): ChatPendingAction | undefined {
  const params = record(value) ?? {};
  const toolUseId = `codex-${String(params.itemId ?? params.callId ?? method)}`.slice(0, 512);
  if (method === "item/tool/requestUserInput") {
    const questions = Array.isArray(params.questions) ? params.questions.flatMap((value) => {
      const question = record(value);
      const id = string(question?.id);
      const prompt = string(question?.question) || string(question?.prompt);
      if (!id || !prompt) return [];
      const choices = Array.isArray(question?.options) ? question.options.flatMap((option) => {
        const item = record(option);
        const label = typeof option === "string" ? option : string(item?.label);
        return label ? [label] : [];
      }) : [];
      return [{ id, question: prompt, choices, multiple: question?.multiSelect === true }];
    }) : [];
    return questions.length ? { type: "question", toolUseId, questions } : undefined;
  }
  if (!approvalMethods.has(method)) return undefined;
  return {
    type: "approval",
    toolUseId,
    toolName: approvalName(method),
    input: params,
    canPersist: true,
  };
}

export function codexResponseFor(
  id: unknown,
  method: string,
  paramsValue: unknown,
  response: Extract<ClientMessage, { type: "respond_chat" }>,
): Record<string, unknown> {
  if (method === "item/tool/requestUserInput") {
    if (response.decision !== "answer") {
      return { id, error: { code: -32000, message: "Cancelled by user." } };
    }
    return {
      id,
      result: {
        answers: Object.fromEntries(Object.entries(response.answers ?? {}).map(([key, answer]) => [
          key, { answers: Array.isArray(answer) ? answer : [answer] },
        ])),
      },
    };
  }
  const allowed = response.decision === "allow" || response.decision === "allow_always";
  const persistent = response.decision === "allow_always";
  if (method === "item/permissions/requestApproval") {
    const permissions = record(paramsValue)?.permissions;
    return {
      id,
      result: {
        permissions: allowed && record(permissions) ? permissions : {},
        scope: persistent ? "session" : "turn",
        strictAutoReview: false,
      },
    };
  }
  const modern = method === "item/commandExecution/requestApproval"
    || method === "item/fileChange/requestApproval";
  return {
    id,
    result: {
      decision: modern
        ? allowed ? persistent ? "acceptForSession" : "accept" : "decline"
        : allowed ? persistent ? "approved_for_session" : "approved" : "denied",
    },
  };
}

const approvalMethods = new Set([
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/permissions/requestApproval",
  "execCommandApproval",
  "applyPatchApproval",
]);

function approvalName(method: string): string {
  if (method.includes("fileChange") || method === "applyPatchApproval") return "File change";
  if (method.includes("permissions")) return "Permissions";
  return "Command";
}

function codexError(value: unknown): string {
  const message = record(value)?.message;
  return typeof message === "string" && message ? message : "Codex rejected the message.";
}

function codexTurnID(value: unknown): string | undefined {
  const recordValue = record(value);
  const nested = record(recordValue?.turn);
  const id = nested?.id ?? recordValue?.turnId ?? recordValue?.turn_id ?? recordValue?.id;
  return typeof id === "string" && id ? id : undefined;
}

async function codexExecutable(): Promise<string | undefined> {
  const home = os.homedir();
  for (const candidate of [
    process.env.CODEX_BINARY,
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    `${home}/.local/bin/codex`,
  ]) {
    if (!candidate) continue;
    try {
      await access(candidate, constants.X_OK);
      return candidate;
    } catch { /* try the next known path */ }
  }
  return undefined;
}

function stop(child: ChildProcess): void {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    if (child.pid) process.kill(-child.pid, "SIGTERM");
    else child.kill("SIGTERM");
  } catch { child.kill("SIGTERM"); }
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}
