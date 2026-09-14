/**
 * Human durations shared by the daemon (which writes "Turn duration: 6m 2s"
 * rows) and the app (which folds those rows into the turn header). Keeping
 * both ends on one formatter means the app can also parse what the daemon
 * wrote, so several turns under one prompt can be summed.
 */
export function formatDuration(milliseconds: number): string {
  if (!Number.isFinite(milliseconds) || milliseconds < 0) return "0ms";
  if (milliseconds < 1_000) return `${Math.round(milliseconds)}ms`;
  if (milliseconds < 10_000) return `${(milliseconds / 1_000).toFixed(1)}s`;
  const totalSeconds = Math.round(milliseconds / 1_000);
  if (totalSeconds < 60) return `${totalSeconds}s`;
  const totalMinutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  if (totalMinutes < 60) return seconds ? `${totalMinutes}m ${seconds}s` : `${totalMinutes}m`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
}

const durationPart = /(\d+(?:\.\d+)?)\s*(ms|h|m|s)\b/g;
const unitMs: Record<string, number> = { ms: 1, s: 1_000, m: 60_000, h: 3_600_000 };

/** Inverse of `formatDuration`. Returns undefined for text with no duration parts. */
export function parseDuration(text: string): number | undefined {
  let total = 0;
  let matched = false;
  for (const match of text.matchAll(durationPart)) {
    total += Number.parseFloat(match[1]!) * unitMs[match[2]!]!;
    matched = true;
  }
  return matched ? Math.round(total) : undefined;
}
