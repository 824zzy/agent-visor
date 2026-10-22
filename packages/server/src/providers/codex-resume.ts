import { closeSync, constants, fstatSync, openSync, readFileSync, readSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import type {
  HistoryRepairSelection,
  NativeHelperGhosttyResumeDispatch,
  NativeHelperGhosttyResumeTarget,
} from "@agent-visor/protocol";
import type {
  RetainedHistoryCodexResumeCapability,
  RetainedHistoryRecord,
} from "../retained-history.js";
import type { DiscoveredProviderSession, ProviderDiscoveryAuthority } from "../sessions.js";
import type {
  ResumeLiveness,
  ResumeProviderAdapter,
  ResumeReconciliation,
  ResumeRepairValidation,
  ResumeTargetResult,
} from "../resume.js";
import type { FreshProcessInventory, ProcessRecord, ProviderEnvironment } from "./environment.js";
import type { ProcessProvenance } from "./process-provenance.js";
import { codexInstanceID, codexThreadReference } from "./codex-instances.js";

const fullThreadID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const pathLimit = 4_096;
const transcriptPrefixLimit = 64 * 1_024;

/** Exact stopped-row strategy for the Codex CLI Ghostty route. */
export class CodexResumeAdapter implements ResumeProviderAdapter {
  readonly id = "codex" as const;
  readonly nativeProvider = "codex_cli" as const;

  constructor(
    private readonly environment: ProviderEnvironment,
    private readonly discoverFresh: () => Promise<DiscoveredProviderSession[] | undefined>,
    private readonly discoveryAuthority: () => ProviderDiscoveryAuthority,
  ) {}

  async resumeLiveness(record: RetainedHistoryRecord): Promise<ResumeLiveness> {
    if (record.provider !== "codex") return { state: "stopped" };
    const inventory = await this.freshInventory();
    if (inventory.state !== "authoritative") {
      return { state: "unknown", reason: `Fresh Codex process inventory is ${inventory.reason}.` };
    }
    const discovered = await this.discoverFresh().catch(() => undefined);
    if (!discovered || this.discoveryAuthority() !== "authoritative") {
      return { state: "unknown", reason: "Fresh Codex conversation discovery is unavailable." };
    }
    const live = discovered.find((session) => this.isExactLiveSession(record, session));
    if (live) return { state: "live", session: live };
    if (await hasPossibleCodexOwner(record, inventory.processes, this.environment)) {
      return { state: "unknown", reason: "A Codex process may still own this conversation." };
    }
    return { state: "stopped" };
  }

  resumeTarget(record: RetainedHistoryRecord, attemptId: string, nonce: string): ResumeTargetResult {
    if (record.provider !== "codex") {
      return { state: "unavailable", reason: "This provider is not supported for Ghostty resume." };
    }
    const capability = record.resume;
    if (!capability || capability.provider !== "codex_cli") {
      return { state: "unavailable", reason: "Codex launch provenance is unavailable for this row." };
    }
    const reason = validateCapability(record, capability);
    if (reason) return { state: "unavailable", reason };
    const reference = codexThreadReference(record.canonicalId);
    if (!reference || !fullThreadID.test(reference.threadID)) {
      return { state: "unavailable", reason: "The full Codex conversation ID is unavailable." };
    }
    const transcriptReason = validateTranscriptPath(record, capability);
    if (transcriptReason) return { state: "unavailable", reason: transcriptReason };
    const target: NativeHelperGhosttyResumeTarget = {
      attemptId,
      provider: "codex_cli",
      sessionId: reference.threadID,
      cwd: record.cwd,
      executable: capability.executableRef,
      configRoot: capability.configRootRef,
      ...(capability.profileRef ? { profileRef: capability.profileRef } : {}),
      profileState: capability.profileState,
      nonce,
    };
    return { state: "eligible", target };
  }

  validateRepair(record: RetainedHistoryRecord, selection: HistoryRepairSelection): ResumeRepairValidation {
    if (selection.kind !== "provider" || record.provider !== "codex") {
      return { state: "unavailable", reason: "This repair does not match the retained Codex provider." };
    }
    if (!record.resume || record.resume.provider !== "codex_cli") {
      return { state: "unavailable", reason: "Codex launch provenance is unavailable for this row." };
    }
    const executableRef = selection.executableRef
      ? canonicalExecutableSelection(selection.executableRef)
      : undefined;
    if (selection.executableRef && (!executableRef || !isTrustedCodexExecutable(executableRef, this.environment.home))) {
      return { state: "unavailable", reason: "The selected Codex executable is not an approved native binary." };
    }
    if (selection.settingsFileRef) {
      return { state: "unavailable", reason: "Codex does not support a separate settings file." };
    }
    let profileRef = record.resume.profileRef;
    let profileState = record.resume.profileState;
    const configRootRef = selection.configRootRef
      ? canonicalDirectorySelection(selection.configRootRef)
      : record.resume.configRootRef;
    if (selection.configRootRef && !configRootRef) {
      return { state: "unavailable", reason: "The selected Codex configuration home is unavailable." };
    }
    if (selection.profileFileRef) {
      if (!configRootRef) return { state: "unavailable", reason: "The Codex configuration home is unavailable." };
      let selected: string;
      try { selected = realpathSync(selection.profileFileRef); } catch {
        return { state: "unavailable", reason: "The selected Codex profile is unavailable." };
      }
      const basename = path.basename(selected);
      const match = /^(.*)\.config\.toml$/.exec(basename);
      let expectedRoot: string;
      try { expectedRoot = realpathSync(configRootRef); } catch {
        return { state: "unavailable", reason: "The selected Codex configuration home is unavailable." };
      }
      if (!match || !isCodexProfileFile(selected) || path.dirname(selected) !== expectedRoot) {
        return { state: "unavailable", reason: "The selected Codex profile is not in the selected configuration home." };
      }
      profileRef = match[1];
      profileState = "present";
    }
    if (selection.profileRef) {
      profileRef = selection.profileRef;
      profileState = "present";
    }
    if (selection.profileState) profileState = selection.profileState;
    if (profileState === "verified_absent") profileRef = undefined;
    if (!configRootRef) return { state: "unavailable", reason: "The Codex configuration home is unavailable." };
    if (!codexHomeMatchesSource(record.canonicalId, configRootRef, this.environment.home)) {
      return { state: "unavailable", reason: "The selected Codex configuration home does not match the retained conversation." };
    }
    const { profileRef: _oldProfileRef, ...withoutOldProfile } = record.resume;
    const capability: RetainedHistoryCodexResumeCapability = {
      ...withoutOldProfile,
      ...(executableRef ? { executableRef } : {}),
      configRootRef,
      ...(profileRef ? { profileRef } : {}),
      profileState,
      provenanceObservedAt: this.environment.now().toISOString(),
    };
    const candidateRecord = selection.configRootRef
      ? { ...record, configHome: configRootRef }
      : record;
    const capabilityReason = validateCapability(candidateRecord, capability);
    if (capabilityReason) return { state: "unavailable", reason: capabilityReason };
    const transcriptReason = validateTranscriptPath(candidateRecord, capability);
    if (transcriptReason) return { state: "unavailable", reason: transcriptReason };
    return { state: "valid", capability };
  }

  async reconcileResume(
    record: RetainedHistoryRecord,
    dispatch: NativeHelperGhosttyResumeDispatch,
  ): Promise<ResumeReconciliation> {
    if (record.provider !== "codex" || dispatch.provider !== "codex_cli") {
      return { state: "unknown", reason: "The native resume receipt does not identify a Codex CLI conversation." };
    }
    const reference = codexThreadReference(record.canonicalId);
    if (!reference || dispatch.sessionId !== reference.threadID) {
      return { state: "unknown", reason: "The native resume receipt does not identify the retained conversation." };
    }
    const discovered = await this.discoverFresh().catch(() => undefined);
    if (!discovered || this.discoveryAuthority() !== "authoritative") {
      return { state: "unknown", retryable: true, reason: "Fresh Codex rediscovery is unavailable." };
    }
    const session = discovered.find((candidate) => this.isExactLiveSession(record, candidate)
      && candidate.cwd === record.cwd);
    if (!session) return { state: "pending", reason: "The launched Codex conversation identity is not visible yet." };
    const target = session.controlTarget?.kind === "terminal" ? session.controlTarget.target : undefined;
    if (!target || target.application !== "Ghostty" || target.pid === undefined || !target.processStartToken) {
      return { state: "unknown", reason: "The resumed Codex process has no exact Ghostty terminal identity." };
    }
    const capability = record.resume;
    if (!capability || capability.provider !== "codex_cli") {
      return { state: "unknown", reason: "The resumed Codex process has no retained launch provenance." };
    }
    const processProof = this.environment.processProvenance
      ? await this.environment.processProvenance(target.pid, "codex_cli", target.processStartToken).catch(() => undefined)
      : undefined;
    if (!processProof || processProof.state !== "available"
      || !sameProcessProvenance(capability, processProof.value)
      || processProof.value.pid !== target.pid
      || processProof.value.processStartToken !== target.processStartToken
      || processProof.value.resumeNonce !== dispatch.nonce) {
      return { state: "unknown", reason: "The launched Codex process did not prove the dispatch nonce." };
    }
    const views = this.environment.ghosttyTerminalViews
      ? await this.environment.ghosttyTerminalViews().catch(() => undefined)
      : undefined;
    const terminals = views?.filter((view) => view.applicationPID === dispatch.applicationPID
      && view.processStartToken === dispatch.processStartToken
      && view.terminalId === dispatch.terminalId
      && view.cwd === record.cwd
      && view.viewMode !== "overview");
    if (!terminals || terminals.length !== 1 || !terminals[0]) {
      return { state: "unknown", reason: "The resumed Codex surface could not be linked exactly." };
    }
    return { state: "matched", sessionId: record.canonicalId, terminal: terminals[0] };
  }

  private isExactLiveSession(record: RetainedHistoryRecord, session: DiscoveredProviderSession): boolean {
    if (session.provider !== "codex" || session.conversationState !== "open") return false;
    const identity = session.historyIdentity;
    const canonicalId = identity?.canonicalId ?? session.id;
    if (canonicalId !== record.canonicalId || !identity?.resume || identity.resume.provider !== "codex_cli") return false;
    if (!sameResumeProvenance(record.resume, session)
      || (record.host !== undefined && identity.host !== record.host)
      || (record.configHome !== undefined && identity.configHome !== record.configHome)) return false;
    return session.controlTarget?.kind === "terminal" || session.controlTarget?.kind === "herdr_surface";
  }

  private async freshInventory(): Promise<FreshProcessInventory> {
    if (this.environment.processesFreshInventory) return this.environment.processesFreshInventory();
    return { state: "unknown", observedAt: this.environment.now().toISOString(), reason: "scan_failed" };
  }
}

function validateCapability(
  record: RetainedHistoryRecord,
  capability: RetainedHistoryCodexResumeCapability,
): string | undefined {
  if (record.host !== "Ghostty" || capability.host !== "Ghostty") {
    return "This Codex session was not observed in a supported Ghostty host.";
  }
  if (!record.configHome || !path.isAbsolute(record.configHome)
    || record.configHome !== capability.configRootRef || !isDirectory(record.configHome)) {
    return "The recorded Codex configuration home is unavailable.";
  }
  if (!path.isAbsolute(record.cwd) || !isDirectory(record.cwd)) return "The original working directory is unavailable.";
  if (!path.isAbsolute(capability.executableRef) || capability.executableRef.length > pathLimit
    || !isExecutableFile(capability.executableRef)) return "The recorded Codex executable is unavailable.";
  try {
    if (realpathSync(capability.executableRef) !== capability.executableRef) {
      return "The recorded Codex executable identity changed.";
    }
    if (realpathSync(record.configHome) !== capability.configRootRef) {
      return "The recorded Codex configuration home identity changed.";
    }
  } catch {
    return "The recorded Codex launch references are unavailable.";
  }
  if (capability.profileState === "present") {
    if (!capability.profileRef) return "The recorded Codex profile is ambiguous.";
    if (!isCodexProfileFile(path.join(capability.configRootRef, `${capability.profileRef}.config.toml`))) {
      return "The recorded Codex profile is unavailable.";
    }
  } else if (capability.profileRef) {
    return "The recorded Codex profile state is inconsistent.";
  }
  if (capability.overrideNames.length > 0) {
    return "This Codex session used a provider override whose value cannot be reconstructed safely.";
  }
  return undefined;
}

function validateTranscriptPath(
  record: RetainedHistoryRecord,
  capability: RetainedHistoryCodexResumeCapability,
): string | undefined {
  if (!record.transcriptPath || !isFile(record.transcriptPath)) return "The saved Codex transcript is unavailable.";
  let actual: string;
  try { actual = realpathSync(record.transcriptPath); } catch { return "The saved Codex transcript is unavailable."; }
  const relative = path.relative(capability.configRootRef, actual);
  const reference = codexThreadReference(record.canonicalId);
  const sessionsRoot = `${path.join(capability.configRootRef, "sessions")}${path.sep}`;
  if (!reference || relative.startsWith("..") || path.isAbsolute(relative) || !actual.startsWith(sessionsRoot)
    || !hasMatchingCodexSessionMetadata(actual, reference.threadID)) {
    return "The saved Codex transcript does not match the retained conversation identity.";
  }
  return undefined;
}

/**
 * Rollout names carry a timestamp and are not identity authority. Read only a
 * bounded prefix and retain the UUID/source marker; prompt and tool content is
 * discarded as soon as each line is inspected.
 */
function hasMatchingCodexSessionMetadata(file: string, threadID: string): boolean {
  let descriptor: number | undefined;
  try {
    descriptor = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
    const info = fstatSync(descriptor);
    if (!info.isFile() || info.size === 0) return false;
    const bytes = Buffer.alloc(Math.min(info.size, transcriptPrefixLimit));
    const length = readSync(descriptor, bytes, 0, bytes.length, 0);
    for (const line of bytes.subarray(0, length).toString("utf8").split("\n")) {
      if (!line.trim()) continue;
      let value: unknown;
      try { value = JSON.parse(line); } catch { continue; }
      if (!isRecord(value) || value.type !== "session_meta" || !isRecord(value.payload)) continue;
      if (typeof value.payload.id !== "string"
        || value.payload.id.toLowerCase() !== threadID.toLowerCase()) continue;
      const originator = value.payload.originator;
      return typeof originator === "string"
        && originator !== "Codex Desktop" && /^codex(?:[-_]|$)/i.test(originator);
    }
  } catch {
    return false;
  } finally {
    if (descriptor !== undefined) {
      try { closeSync(descriptor); } catch { /* best effort close */ }
    }
  }
  return false;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sameResumeProvenance(
  expected: RetainedHistoryRecord["resume"],
  session: DiscoveredProviderSession,
): boolean {
  if (!expected || expected.provider !== "codex_cli") return false;
  const observed = session.historyIdentity?.resume;
  return observed?.provider === "codex_cli"
    && observed.executableRef === expected.executableRef
    && observed.executableVersion === expected.executableVersion
    && observed.configRootRef === expected.configRootRef
    && observed.profileRef === expected.profileRef
    && observed.profileState === expected.profileState
    && JSON.stringify(observed.overrideNames) === JSON.stringify(expected.overrideNames);
}

function sameProcessProvenance(
  expected: RetainedHistoryCodexResumeCapability,
  observed: ProcessProvenance,
): boolean {
  return observed.argvState === "complete"
    && observed.executableRef === expected.executableRef
    && observed.executableVersion === expected.executableVersion
    && observed.configRootRef === expected.configRootRef
    && observed.profileRef === expected.profileRef
    && observed.profileState === expected.profileState
    && JSON.stringify(observed.overrideNames) === JSON.stringify(expected.overrideNames);
}

async function hasPossibleCodexOwner(
  record: RetainedHistoryRecord,
  processes: readonly ProcessRecord[],
  environment: ProviderEnvironment,
): Promise<boolean> {
  for (const process of processes) {
    if (path.basename(process.command) !== "codex") continue;
    const modernServer = /\b(?:app|mcp|exec)-server\b/i.test(process.arguments);
    if (environment.codexProcessHome) {
      const home = await environment.codexProcessHome(process.pid).catch(() => undefined);
      if (home && record.configHome && home !== record.configHome) continue;
      if (home && record.configHome && home === record.configHome) return true;
    }
    // A background server can own a frontend without sharing its cwd. Once
    // its selected home is not disproven, an unavailable or ambiguous client
    // inventory is unknown rather than evidence that the row is stopped.
    if (modernServer) return true;
    const cwd = await environment.cwd(process.pid).catch(() => undefined);
    if (cwd && cwd === record.cwd) return true;
    if (!cwd && record.configHome) return true;
  }
  return false;
}

function isFile(value: string): boolean {
  try { return statSync(value).isFile(); } catch { return false; }
}

function isCodexProfileFile(value: string): boolean {
  try {
    const metadata = statSync(value);
    if (!metadata.isFile() || metadata.size === 0 || metadata.size > 256 * 1_024) return false;
    const content = readFileSync(value, "utf8");
    // Profile files are TOML settings. Only inspect bounded key syntax; never
    // retain or parse values that may contain credentials.
    return /^\s*[A-Za-z][A-Za-z0-9_.-]*\s*=/m.test(content);
  } catch {
    return false;
  }
}

function isExecutableFile(value: string): boolean {
  try {
    const stat = statSync(value);
    return stat.isFile() && (stat.mode & 0o111) !== 0;
  } catch { return false; }
}

function canonicalExecutableSelection(value: string): string | undefined {
  try {
    const resolved = realpathSync(value);
    return isExecutableFile(resolved) ? resolved : undefined;
  } catch {
    return undefined;
  }
}

function canonicalDirectorySelection(value: string): string | undefined {
  try {
    const resolved = realpathSync(value);
    return isDirectory(resolved) ? resolved : undefined;
  } catch {
    return undefined;
  }
}

function isTrustedCodexExecutable(executable: string, home: string): boolean {
  try {
    if (realpathSync(executable) !== executable) return false;
    return [
      path.join(home, ".local", "bin", "codex"),
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
    ].some((candidate) => {
      try { return realpathSync(candidate) === executable; } catch { return false; }
    });
  } catch {
    return false;
  }
}

function codexHomeMatchesSource(canonicalId: string, configRoot: string, home: string): boolean {
  const reference = codexThreadReference(canonicalId);
  if (!reference) return false;
  try {
    const canonicalRoot = realpathSync(configRoot);
    const nativeHome = realpathSync(path.join(home, ".codex"));
    return canonicalRoot === configRoot && codexInstanceID(canonicalRoot, nativeHome) === reference.instanceID;
  } catch {
    return false;
  }
}

function isDirectory(value: string): boolean {
  try { return statSync(value).isDirectory(); } catch { return false; }
}
