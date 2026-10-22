import { closeSync, constants, fstatSync, openSync, readFileSync, readSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import type {
  HistoryRepairSelection,
  NativeHelperGhosttyResumeDispatch,
  NativeHelperGhosttyResumeTarget,
  NativeHelperGhosttyTerminalView,
  NativeHelperTerminalTarget,
} from "@agent-visor/protocol";
import type {
  RetainedHistoryClaudeResumeCapability,
  RetainedHistoryRecord,
  RetainedHistoryResumeCapability,
} from "../retained-history.js";
import type { DiscoveredProviderSession, ProviderDiscoveryAuthority } from "../sessions.js";
import type {
  ResumeLiveness,
  ResumeProviderAdapter,
  ResumeReconciliation,
  ResumeRepairValidation,
  ResumeTargetResult,
  ResumeWorkingDirectoryValidation,
} from "../resume.js";
import type { FreshProcessInventory, ProcessRecord, ProviderEnvironment } from "./environment.js";
import type { ProcessProvenance } from "./process-provenance.js";
import { isRecord, processInstanceToken } from "./shared.js";
import { trustedClaudeExecutableCandidates } from "./claude-agent-inventory.js";

const fullSessionID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const pathLimit = 4_096;
const transcriptPrefixLimit = 64 * 1_024;

/** Claude-specific strategy. It owns only resume validation and reconciliation. */
export class ClaudeResumeAdapter implements ResumeProviderAdapter {
  readonly id = "claude_code" as const;
  readonly nativeProvider = "claude_code" as const;

  constructor(
    private readonly environment: ProviderEnvironment,
    private readonly discoverFresh: () => Promise<DiscoveredProviderSession[] | undefined>,
    private readonly discoveryAuthority: () => ProviderDiscoveryAuthority,
  ) {}

  async resumeLiveness(record: RetainedHistoryRecord): Promise<ResumeLiveness> {
    const inventory = await this.freshInventory();
    if (inventory.state !== "authoritative") {
      return { state: "unknown", reason: `Fresh Claude process inventory is ${inventory.reason}.` };
    }
    const discovered = await this.discoverFresh().catch(() => undefined);
    if (!discovered || this.discoveryAuthority() !== "authoritative") {
      return { state: "unknown", reason: "Fresh Claude conversation discovery is unavailable." };
    }
    const live = discovered.find((session) => session.provider === "claude_code"
      && (session.id === record.id || session.id === record.canonicalId || record.aliases?.includes(session.id))
      && session.conversationState === "open"
      && record.host === "Ghostty"
      && session.controlTarget?.kind === "terminal"
      && session.controlTarget.target.application === "Ghostty"
      && sameResumeProvenance(record.resume, session));
    if (live) return { state: "live", session: live };
    if (await hasPossibleOwner(record, inventory.processes, this.environment, discovered)) {
      return { state: "unknown", reason: "A Claude process may still own this conversation." };
    }
    return { state: "stopped" };
  }

  resumeTarget(record: RetainedHistoryRecord, attemptId: string, nonce: string): ResumeTargetResult {
    if (record.provider !== "claude_code") return { state: "unavailable", reason: "This provider is not supported for Ghostty resume." };
    if (record.host !== "Ghostty") return { state: "unavailable", reason: "This Claude session was not observed in a supported Ghostty host." };
    if (!fullSessionID.test(record.canonicalId)) return { state: "unavailable", reason: "The full Claude conversation ID is unavailable." };
    if (!isDirectory(record.cwd)) return { state: "unavailable", reason: "The original working directory is unavailable." };
    if (!record.resume) return { state: "unavailable", reason: "Claude launch provenance is unavailable for this row." };
    const capability = record.resume;
    if (capability.provider !== "claude_code") {
      return { state: "unavailable", reason: "Claude launch provenance is unavailable for this row." };
    }
    if (record.configHome !== undefined && record.configHome !== capability.configRootRef) {
      return { state: "unavailable", reason: "The recorded Claude configuration identity changed." };
    }
    const reason = validateCapability(capability, record.cwd, this.environment.home);
    if (reason) return { state: "unavailable", reason };
    const transcriptReason = validateTranscriptPath(record, capability, this.environment.home);
    if (transcriptReason) return { state: "unavailable", reason: transcriptReason };
    const target: NativeHelperGhosttyResumeTarget = {
      attemptId,
      provider: "claude_code",
      sessionId: record.canonicalId,
      cwd: record.cwd,
      executable: capability.executableRef,
      ...(capability.configRootRef ? { configRoot: capability.configRootRef } : {}),
      ...(capability.settingsFileRef ? { settingsFile: capability.settingsFileRef } : {}),
      ...(capability.settingSources ? { settingSources: capability.settingSources } : {}),
      ...(capability.profileRef ? { profileRef: capability.profileRef } : {}),
      profileState: capability.profileState,
      nonce,
    };
    return { state: "eligible", target };
  }

  validateRepair(record: RetainedHistoryRecord, selection: HistoryRepairSelection): ResumeRepairValidation {
    if (selection.kind !== "provider" || record.provider !== "claude_code") {
      return { state: "unavailable", reason: "This repair does not match the retained Claude provider." };
    }
    if (!fullSessionID.test(record.canonicalId)) {
      return { state: "unavailable", reason: "The full Claude conversation ID is unavailable." };
    }
    if (!record.resume || record.resume.provider !== "claude_code") {
      return { state: "unavailable", reason: "Claude launch provenance is unavailable for this row." };
    }
    if (selection.profileFileRef) {
      return { state: "unavailable", reason: "Claude profile repair requires an explicit profile and settings file." };
    }
    if (selection.profileRef) {
      return { state: "unavailable", reason: "Claude named profile repair has no supported native readback." };
    }
    const executableRef = selection.executableRef
      ? canonicalExecutableSelection(selection.executableRef)
      : undefined;
    if (selection.executableRef && !executableRef) {
      return { state: "unavailable", reason: "The selected Claude executable is unavailable." };
    }
    const configRootRef = selection.configRootRef
      ? canonicalDirectorySelection(selection.configRootRef)
      : undefined;
    if (selection.configRootRef && !configRootRef) {
      return { state: "unavailable", reason: "The selected Claude configuration root is unavailable." };
    }
    const settingsFileRef = selection.settingsFileRef
      ? canonicalFileSelection(selection.settingsFileRef)
      : undefined;
    if (selection.settingsFileRef && !settingsFileRef) {
      return { state: "unavailable", reason: "The selected Claude settings file is unavailable." };
    }
    let capability: RetainedHistoryClaudeResumeCapability = {
      ...record.resume,
      ...(executableRef ? { executableRef } : {}),
      ...(configRootRef ? { configRootRef } : {}),
      ...(settingsFileRef ? { settingsFileRef } : {}),
      ...(selection.profileRef ? { profileRef: selection.profileRef, profileState: "present" as const } : {}),
      ...(selection.profileState ? { profileState: selection.profileState } : {}),
      provenanceObservedAt: this.environment.now().toISOString(),
    };
    if (selection.profileState === "verified_absent") {
      const { profileRef: _profileRef, ...withoutProfile } = capability;
      capability = withoutProfile;
    }
    const capabilityReason = validateCapability(capability, record.cwd, this.environment.home);
    if (capabilityReason) return { state: "unavailable", reason: capabilityReason };
    const transcriptReason = validateTranscriptPath(record, capability, this.environment.home);
    if (transcriptReason) return { state: "unavailable", reason: transcriptReason };
    return { state: "valid", capability };
  }

  async validateWorkingDirectory(
    record: RetainedHistoryRecord,
    candidateCwd: string,
  ): Promise<ResumeWorkingDirectoryValidation> {
    if (record.provider !== "claude_code") {
      return { state: "unavailable", reason: "This repair does not match the retained Claude provider." };
    }
    const selectedCwd = canonicalDirectorySelection(candidateCwd);
    if (!selectedCwd) {
      return { state: "unavailable", reason: "The selected Claude working directory is unavailable." };
    }
    const originalCwd = canonicalDirectorySelection(record.cwd);
    if (!originalCwd || originalCwd !== selectedCwd) {
      return {
        state: "unavailable",
        reason: "Claude Code cannot prove that this saved conversation belongs to the selected folder; the provider does not expose a supported relocation mapping.",
      };
    }
    const capability = record.resume;
    if (!capability || capability.provider !== "claude_code") {
      return { state: "unavailable", reason: "Claude launch provenance is unavailable for this row." };
    }
    if (record.configHome !== undefined && record.configHome !== capability.configRootRef) {
      return { state: "unavailable", reason: "The recorded Claude configuration identity changed." };
    }
    const candidateRecord = { ...record, cwd: selectedCwd };
    const capabilityReason = validateCapability(capability, selectedCwd, this.environment.home);
    if (capabilityReason) return { state: "unavailable", reason: capabilityReason };
    const transcriptReason = validateTranscriptPath(candidateRecord, capability, this.environment.home);
    if (transcriptReason) return { state: "unavailable", reason: transcriptReason };
    return { state: "valid", cwd: selectedCwd };
  }

  async reconcileResume(
    record: RetainedHistoryRecord,
    dispatch: NativeHelperGhosttyResumeDispatch,
  ): Promise<ResumeReconciliation> {
    if (dispatch.provider !== "claude_code" || dispatch.sessionId !== record.canonicalId || record.host !== "Ghostty") {
      return { state: "unknown", reason: "The native resume receipt does not identify the retained conversation." };
    }
    const discovered = await this.discoverFresh().catch(() => undefined);
    if (!discovered || this.discoveryAuthority() !== "authoritative") {
      return { state: "unknown", retryable: true, reason: "Fresh Claude rediscovery is unavailable." };
    }
    const session = discovered.find((candidate) => candidate.provider === "claude_code"
      && candidate.id === record.canonicalId
      && candidate.conversationState === "open"
      && candidate.cwd === record.cwd);
    if (!session) {
      return { state: "pending", reason: "The launched Claude conversation identity is not visible yet." };
    }
    if (!sameResumeProvenance(record.resume, session)) {
      return { state: "unknown", reason: "The launched Claude process did not prove the retained conversation identity." };
    }
    const target = session.controlTarget?.kind === "terminal" ? session.controlTarget.target : undefined;
    if (!target || target.application !== "Ghostty" || target.pid === undefined || !target.processStartToken) {
      return { state: "unknown", reason: "The resumed Claude process has no exact Ghostty terminal identity." };
    }
    const processProof = this.environment.processProvenance
      ? await this.environment.processProvenance(target.pid, "claude_code", target.processStartToken).catch(() => undefined)
      : undefined;
    if (!processProof || processProof.state !== "available"
      || !sameProcessProvenance(record.resume, processProof.value)
      || processProof.value.pid !== target.pid
      || processProof.value.processStartToken !== target.processStartToken
      || processProof.value.resumeNonce !== dispatch.nonce) {
      return { state: "unknown", reason: "The launched Claude process did not prove the dispatch nonce." };
    }
    const binding = await exactGhosttyProcessBinding(record, target, dispatch, this.environment);
    if (binding.state !== "bound") return binding;
    const readViews = this.environment.ghosttyTerminalViews;
    if (!readViews) return { state: "unknown", reason: "Ghostty surface readback is unavailable." };
    const views = await readViews().catch(() => undefined);
    const terminals = views?.filter((view) => view.applicationPID === dispatch.applicationPID
      && view.processStartToken === dispatch.processStartToken
      && view.terminalId === dispatch.terminalId
      && view.cwd === record.cwd
      && view.viewMode !== "overview");
    if (!terminals || terminals.length !== 1 || !terminals[0]) {
      return { state: "unknown", reason: "The resumed Claude surface could not be linked exactly." };
    }
    const terminal = terminals[0];
    return { state: "matched", sessionId: record.canonicalId, terminal };
  }

  private async freshInventory(): Promise<FreshProcessInventory> {
    if (this.environment.processesFreshInventory) return this.environment.processesFreshInventory();
    return { state: "unknown", observedAt: this.environment.now().toISOString(), reason: "scan_failed" };
  }
}

function validateCapability(
  capability: RetainedHistoryClaudeResumeCapability,
  cwd: string,
  home: string,
): string | undefined {
  if (capability.host !== "Ghostty") return "This Claude session was not observed in a supported Ghostty host.";
  if (!path.isAbsolute(capability.executableRef) || capability.executableRef.length > pathLimit
    || !isExecutableFile(capability.executableRef)
    || !isTrustedClaudeExecutable(capability.executableRef, home)) return "The recorded Claude executable is unavailable.";
  let executable: string;
  try { executable = realpathSync(capability.executableRef); } catch { return "The recorded Claude executable is unavailable."; }
  if (executable !== capability.executableRef) return "The recorded Claude executable identity changed.";
  if (capability.profileState === "present" && !capability.profileRef) {
    return "The recorded Claude profile is ambiguous.";
  }
  if (capability.profileRef && !capability.settingsFileRef) {
    return "The recorded Claude profile has no supported settings file.";
  }
  if (capability.settingsFileRef && !isReadableJSONFile(capability.settingsFileRef)) {
    return "The recorded Claude settings file is unavailable.";
  }
  if (capability.configRootRef && !isDirectory(capability.configRootRef)) {
    return "The recorded Claude configuration root is unavailable.";
  }
  if (capability.overrideNames.length) return "This Claude session used an unsupported provider override.";
  if (!path.isAbsolute(cwd) || !isDirectory(cwd)) return "The original working directory is unavailable.";
  return undefined;
}

function validateTranscriptPath(
  record: RetainedHistoryRecord,
  capability: RetainedHistoryResumeCapability,
  home: string,
): string | undefined {
  if (!record.transcriptPath || !isFile(record.transcriptPath)) {
    return "The saved Claude transcript is unavailable.";
  }
  const project = record.cwd.replaceAll("/", "-").replaceAll(".", "-").replaceAll("_", "-");
  const configRoots = new Set([capability.configRootRef ?? path.join(home, ".claude")]);
  const expected = [...configRoots].flatMap((root) => {
    try {
      return [path.join(realpathSync(root), "projects", project, `${record.canonicalId}.jsonl`)];
    } catch {
      return [];
    }
  });
  let actual: string;
  try { actual = realpathSync(record.transcriptPath); } catch {
    return "The saved Claude transcript is unavailable.";
  }
  if (!expected.includes(actual)) return "The saved Claude transcript does not match the retained conversation identity.";
  return hasMatchingClaudeSessionMetadata(actual, record.canonicalId, record.cwd)
    ? undefined
    : "The saved Claude transcript does not prove the retained conversation identity.";
}

function hasMatchingClaudeSessionMetadata(file: string, sessionID: string, cwd: string): boolean {
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
      if (!isRecord(value)) continue;
      const observedID = value.sessionId ?? value.session_id;
      if (typeof observedID !== "string" || observedID.toLowerCase() !== sessionID.toLowerCase()) continue;
      const observedCWD = value.cwd;
      if (observedCWD !== undefined && observedCWD !== cwd) continue;
      return true;
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

function sameResumeProvenance(
  expected: RetainedHistoryResumeCapability | undefined,
  session: DiscoveredProviderSession,
): boolean {
  if (!expected || expected.provider !== "claude_code") return false;
  const observed = session.historyIdentity?.resume;
  if (!observed) return false;
  return observed.provider === expected.provider
    && observed.host === expected.host
    && observed.executableRef === expected.executableRef
    && observed.executableVersion === expected.executableVersion
    && observed.configRootRef === expected.configRootRef
    && observed.settingsFileRef === expected.settingsFileRef
    && JSON.stringify(normalizedSettingSources(observed)) === JSON.stringify(normalizedSettingSources(expected))
    && observed.profileRef === expected.profileRef
    && observed.profileState === expected.profileState
    && JSON.stringify(observed.overrideNames) === JSON.stringify(expected.overrideNames);
}

function sameProcessProvenance(
  expected: RetainedHistoryResumeCapability | undefined,
  observed: ProcessProvenance,
): boolean {
  if (!expected || expected.provider !== "claude_code" || observed.argvState !== "complete") return false;
  return observed.executableRef === expected.executableRef
    && observed.executableVersion === expected.executableVersion
    && observed.configRootRef === expected.configRootRef
    && observed.settingsFileRef === expected.settingsFileRef
    && JSON.stringify(normalizedSettingSources(observed)) === JSON.stringify(normalizedSettingSources(expected))
    && observed.profileRef === expected.profileRef
    && observed.profileState === expected.profileState
    && JSON.stringify(observed.overrideNames) === JSON.stringify(expected.overrideNames);
}

function normalizedSettingSources(
  value: Pick<RetainedHistoryClaudeResumeCapability, "settingsFileRef" | "settingSources">,
): Array<"user" | "project" | "local"> {
  return value.settingSources ?? (value.settingsFileRef ? ["user", "project", "local"] : []);
}

async function hasPossibleOwner(
  record: RetainedHistoryRecord,
  processes: readonly { pid: number; processStartToken?: string; command: string; arguments: string }[],
  environment: ProviderEnvironment,
  discovered: readonly DiscoveredProviderSession[],
): Promise<boolean> {
  const expectedExecutable = record.resume?.executableRef;
  for (const process of processes) {
    const command = process.command.trim();
    const isClaude = /(?:^|[\\/])claude(?:$|[\\/])/i.test(command)
      || /(?:^|\s)(?:claude|claude-code)(?:\s|$)/i.test(process.arguments);
    if (!isClaude) continue;
    if (process.arguments.includes(record.canonicalId) || process.arguments.includes(record.id)) return true;
    const exactOtherFrontend = discovered.some((session) => {
      if (session.provider !== "claude_code" || session.conversationState !== "open"
        || session.id === record.id || session.id === record.canonicalId
        || record.aliases?.includes(session.id) === true
        || session.historyIdentity?.verified !== true || session.historyIdentity.current !== true) {
        return false;
      }
      const target = session.controlTarget?.kind === "terminal" ? session.controlTarget.target : undefined;
      return target?.application === "Ghostty"
        && target.pid === process.pid
        && target.processStartToken !== undefined
        && target.processStartToken === process.processStartToken;
    });
    if (exactOtherFrontend) continue;
    if (expectedExecutable && command === expectedExecutable) return true;
    const cwd = await environment.cwd(process.pid).catch(() => undefined);
    if (cwd === record.cwd) return true;
    // An authoritative Claude process without an identity or cwd mapping is
    // still a possible owner. Explicit resume must fail closed until it is
    // mapped or has exited.
    if (!cwd) return true;
  }
  return false;
}

async function exactGhosttyProcessBinding(
  record: RetainedHistoryRecord,
  target: NativeHelperTerminalTarget,
  dispatch: NativeHelperGhosttyResumeDispatch,
  environment: ProviderEnvironment,
): Promise<ProcessBinding> {
  if (target.application !== "Ghostty" || target.cwd !== record.cwd
    || target.pid === undefined || !target.processStartToken) {
    return { state: "unknown", reason: "The resumed Claude process has no exact Ghostty terminal identity." };
  }
  const inventory = environment.processesFreshInventory
    ? await environment.processesFreshInventory().catch(() => undefined)
    : undefined;
  if (!inventory || inventory.state !== "authoritative") {
    return { state: "unknown", reason: "Fresh process binding evidence is unavailable." };
  }
  const byPID = new Map(inventory.processes.map((process) => [process.pid, process]));
  const provider = byPID.get(target.pid);
  const application = byPID.get(dispatch.applicationPID);
  if (!provider || !application || !isGhosttyCommand(application.command)
    || normalizeTTY(provider.tty) !== normalizeTTY(target.tty)
    || await processToken(provider, environment) !== target.processStartToken
    || await processToken(application, environment) !== dispatch.processStartToken) {
    return { state: "unknown", reason: "The resumed process identity changed before surface readback." };
  }
  const expectedExecutable = record.resume?.executableRef;
  if (expectedExecutable && provider.command !== expectedExecutable) {
    return { state: "unknown", reason: "The resumed Claude executable identity changed." };
  }
  const visited = new Set<number>();
  let current: ProcessRecord | undefined = provider;
  while (current && !visited.has(current.pid)) {
    if (current.pid === application.pid) return { state: "bound" };
    visited.add(current.pid);
    current = byPID.get(current.parentPID);
  }
  return { state: "unknown", reason: "The resumed Claude process is not owned by the dispatched Ghostty instance." };
}

type ProcessBinding =
  | { state: "bound" }
  | { state: "unknown"; reason: string };

async function processToken(process: ProcessRecord, environment: ProviderEnvironment): Promise<string | undefined> {
  if (process.processStartToken) return process.processStartToken;
  if (!environment.processStartedAt) return undefined;
  return processInstanceToken(process.pid, await environment.processStartedAt(process.pid));
}

function normalizeTTY(value: string | undefined): string | undefined {
  return value?.startsWith("/dev/") ? value.slice(5) : value;
}

function isGhosttyCommand(command: string): boolean {
  return /(?:^|[\\/])ghostty(?:$|[\\/])/i.test(command);
}

function isFile(value: string): boolean {
  try { return statSync(value).isFile(); } catch { return false; }
}

function isReadableJSONFile(value: string): boolean {
  try {
    const metadata = statSync(value);
    if (!metadata.isFile() || metadata.size === 0 || metadata.size > 256 * 1_024) return false;
    const parsed: unknown = JSON.parse(readFileSync(value, "utf8"));
    return isRecord(parsed);
  } catch {
    return false;
  }
}

function isExecutableFile(value: string): boolean {
  try {
    const metadata = statSync(value);
    return metadata.isFile() && (metadata.mode & 0o111) !== 0;
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

function canonicalFileSelection(value: string): string | undefined {
  try {
    const resolved = realpathSync(value);
    return isFile(resolved) ? resolved : undefined;
  } catch {
    return undefined;
  }
}

function isTrustedClaudeExecutable(executable: string, home: string): boolean {
  try {
    if (realpathSync(executable) !== executable) return false;
    const native = path.dirname(executable) === path.join(realpathSync(home), ".local", "share", "claude", "versions")
      && /^\d+\.\d+\.\d+$/.test(path.basename(executable));
    if (native) return true;
    return trustedClaudeExecutableCandidates(home).some((candidate) => {
      try { return realpathSync(candidate) === executable; } catch { return false; }
    });
  } catch { return false; }
}

function isDirectory(value: string): boolean {
  try { return statSync(value).isDirectory(); } catch { return false; }
}
