/**
 * Transcript-derived phase with a freshness requirement.
 *
 * A transcript can record that a turn started or completed, but it cannot say
 * whether that turn is still alive. Providers that infer a session's phase from
 * transcript markers (Codex desktop, Claude Desktop fallback, Pi hooks) treat a
 * marker as a claim that expires: a transcript quiet for longer than the stale
 * ceiling is dormant whatever its last marker says. Without this, a turn whose
 * process died right after `task_started` reads as "working" for months, and a
 * task finished yesterday sorts above live work as "ready".
 *
 * This is the shared TypeScript twin of Swift's
 * `TranscriptPhaseInferrer.defaultStaleCeiling`. Keep the two values aligned.
 *
 * Catalog membership is a separate policy. A dormant thread is still listed and
 * openable; it is presented as Recent rather than Working or Ready.
 */
export const TRANSCRIPT_STALE_CEILING_MS = 30 * 60 * 1_000;

/** Last lifecycle marker read from a transcript. */
export type TranscriptTurnMarker = "started" | "completed" | "none";

/** Phase claimed by the transcript once freshness is applied. */
export type TranscriptPhase = "working" | "ready" | "recent";

export type TranscriptPhaseInput = {
  marker: TranscriptTurnMarker;
  /** Last time the transcript file changed. Unknown or invalid means no claim. */
  transcriptModifiedAt: Date | number | string | undefined;
  now: Date | number;
  staleCeilingMs?: number;
};

export function transcriptPhase(input: TranscriptPhaseInput): TranscriptPhase {
  if (input.marker === "none") return "recent";
  const modifiedAt = toEpochMs(input.transcriptModifiedAt);
  const now = toEpochMs(input.now);
  if (modifiedAt === undefined || now === undefined) return "recent";
  const ceiling = input.staleCeilingMs ?? TRANSCRIPT_STALE_CEILING_MS;
  if (now - modifiedAt > ceiling) return "recent";
  return input.marker === "started" ? "working" : "ready";
}

function toEpochMs(value: Date | number | string | undefined): number | undefined {
  if (value === undefined) return undefined;
  const ms = value instanceof Date ? value.valueOf()
    : typeof value === "number" ? value
    : Date.parse(value);
  return Number.isFinite(ms) ? ms : undefined;
}
