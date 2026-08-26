export function runBackground(label: string, task: () => Promise<unknown>): void {
  try {
    void task().catch((error: unknown) => {
      console.warn(`Agent Visor ${label} failed: ${String(error)}`);
    });
  } catch (error) {
    console.warn(`Agent Visor ${label} failed: ${String(error)}`);
  }
}
