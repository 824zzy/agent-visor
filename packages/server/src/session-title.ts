/** Ambient labels use the first meaningful line; provider text remains intact. */
export function sessionDisplayTitle(value: string | undefined): string | undefined {
  return value?.split(/[\r\n\v\f\u0085\u2028\u2029]/u)
    .map((line) => line.trim().replace(/\s+/gu, " "))
    .find(Boolean);
}
