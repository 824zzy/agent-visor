import type {
  NativeHelperProcessProvenanceResult,
  NativeHelperProcessProvenanceTarget,
} from "@agent-visor/protocol";

export type ProvenanceState = "present" | "verified_absent" | "unknown";
export type ProvenanceExpectedProvider = "claude_code" | "codex_cli";

export type ProcessProvenance = {
  version: 1;
  pid: number;
  processStartToken: string;
  executableRef: string;
  executableVersion?: string;
  configRootRef?: string;
  profileRef?: string;
  profileState: ProvenanceState;
  settingsFileRef?: string;
  settingSources?: Array<"user" | "project" | "local">;
  /** Names only; values and raw environment entries are discarded. */
  overrideNames: string[];
  /** One-shot launch correlation evidence; never retained in history. */
  resumeNonce?: string;
  argvState: "complete" | "unknown";
  observedAt: string;
};

export type ProcessProvenanceResult =
  | { state: "available"; value: ProcessProvenance }
  | { state: "unavailable"; reason:
      "process_missing" | "argv_unreadable" | "argv_ambiguous" | "executable_untrusted" | "config_untrusted" };

export interface ProcessProvenanceReader {
  read(
    pid: number,
    expected: ProvenanceExpectedProvider,
    processStartToken?: string,
  ): Promise<ProcessProvenanceResult>;
}

/** Missing native wiring is unavailable evidence, never a raw argv fallback. */
export class UnavailableProcessProvenanceReader implements ProcessProvenanceReader {
  async read(): Promise<ProcessProvenanceResult> {
    return { state: "unavailable", reason: "argv_unreadable" };
  }
}

/** Reads sanitized provenance from the signed native helper. */
export class NativeHelperProcessProvenanceReader implements ProcessProvenanceReader {
  constructor(
    private readonly home: string,
    private readonly readNative: (target: NativeHelperProcessProvenanceTarget) => Promise<NativeHelperProcessProvenanceResult>,
  ) {}

  async read(
    pid: number,
    expected: ProvenanceExpectedProvider,
    processStartToken = "",
  ): Promise<ProcessProvenanceResult> {
    if (!Number.isInteger(pid) || pid <= 0) return { state: "unavailable", reason: "process_missing" };
    if (!processStartToken) return { state: "unavailable", reason: "argv_ambiguous" };
    return this.readNative({
      pid,
      provider: expected,
      processStartToken,
      homeDirectory: this.home,
    }).catch(() => ({ state: "unavailable", reason: "argv_unreadable" as const }));
  }
}
