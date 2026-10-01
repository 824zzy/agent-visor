export type DaemonLifetime = {
  readonly stopping: boolean;
  onStop(cleanup: () => Promise<void>): void;
};

/** The IPC connection owns desktop-launched daemons; standalone servers use signals. */
export async function runDaemon(
  start: (lifetime: DaemonLifetime) => Promise<void>,
  shutdownTimeoutMs = 5_000,
): Promise<void> {
  let stopping = false;
  let started = false;
  let finishing = false;
  let exitCode = 0;
  let cleanup = async () => {};
  let deadline: NodeJS.Timeout | undefined;

  const finish = async () => {
    if (!started || finishing) return;
    finishing = true;
    try { await cleanup(); } catch (error) {
      console.warn(`Agent Visor shutdown failed: ${String(error)}`);
      exitCode = 1;
    }
    clearTimeout(deadline);
    process.exit(exitCode);
  };
  const stop = () => {
    if (stopping) return;
    stopping = true;
    // Keep this timer referenced: startup or cleanup may never settle. Exiting
    // also closes the helper socket, whose EOF terminates the native helper.
    deadline = setTimeout(() => {
      console.warn("Agent Visor shutdown exceeded its deadline.");
      process.exit(1);
    }, shutdownTimeoutMs);
    void finish();
  };

  // Register before the first startup await, and detect a parent already lost
  // while modules were loading. A standalone CLI has no process.send function.
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  if (typeof process.send === "function") {
    process.once("disconnect", stop);
    if (!process.connected) stop();
  }
  try {
    if (!stopping) await start({
      get stopping() { return stopping; },
      onStop(callback) { cleanup = callback; },
    });
  } catch (error) {
    console.error(`Agent Visor startup failed: ${String(error)}`);
    exitCode = 1;
    stop();
  } finally {
    started = true;
    if (stopping) await finish();
  }
}
