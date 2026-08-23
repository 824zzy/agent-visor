import { spawn, type ChildProcess } from "node:child_process";
import { access } from "node:fs/promises";
import { constants } from "node:fs";
import os from "node:os";
import type { ChatPendingAction, ClientMessage } from "@agent-visor/protocol";

export type CodexActionRegistrar = (
  sessionId: string,
  pending: ChatPendingAction,
  respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>,
) => () => void;

const activeTurns = new Set<(error?: Error) => void>();

export async function sendCodexTurn(
  threadId: string,
  text: string,
  imagePaths: string[],
  registerAction?: CodexActionRegistrar,
): Promise<void> {
  const executable = await codexExecutable();
  if (!executable) throw new Error("Codex message delivery is unavailable.");
  await new Promise<void>((resolve, reject) => {
    const child = spawn(executable, ["app-server", "--listen", "stdio://"], {
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffer = "";
    let outputBytes = 0;
    let accepted = false;
    let closed = false;
    let unregister: (() => void) | undefined;
    let deadline = setTimeout(() => cleanup(new Error("Codex message delivery timed out.")), 10_000);
    activeTurns.add(cleanup);

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
          accepted = true;
          clearTimeout(deadline);
          deadline = setTimeout(() => cleanup(), 30 * 60_000);
          deadline.unref();
          resolve();
        } else if (typeof message.method === "string") {
          if (message.method === "turn/completed") {
            cleanup();
          } else if (message.id !== undefined && registerAction) {
            const pending = codexPendingAction(message.method, message.params);
            if (!pending) {
              write({ id: message.id, error: { code: -32601, message: "Unsupported Codex request." } });
              continue;
            }
            if (unregister) {
              write({ id: message.id, error: { code: -32000, message: "Another Codex decision is pending." } });
              continue;
            }
            unregister = registerAction(threadId, pending, async (response) => {
              write(codexResponseFor(message.id!, message.method as string, message.params, response));
              unregister?.();
              unregister = undefined;
            });
          }
        }
      }
    });

    write({
      id: 1,
      method: "initialize",
      params: { clientInfo: { name: "agent-visor", version: "2.7.0" } },
    });

    function countOutput(chunk: Buffer): void {
      // ponytail: one MiB per turn; raise or stream-account if large turns reach this limit.
      outputBytes += chunk.length;
      if (outputBytes > 1_048_576) cleanup(new Error("Codex message delivery returned too much output."));
    }

    function write(message: unknown): void {
      if (!closed) child.stdin.write(`${JSON.stringify(message)}\n`);
    }

    function cleanup(error?: Error): void {
      if (closed) return;
      closed = true;
      activeTurns.delete(cleanup);
      clearTimeout(deadline);
      unregister?.();
      child.stdin.destroy();
      child.stdout.destroy();
      stop(child);
      if (!accepted && error) reject(error);
    }
  });
}

export function stopCodexTurns(): void {
  for (const stop of [...activeTurns]) stop(new Error("Codex message delivery stopped."));
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
