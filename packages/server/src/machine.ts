import { spawn } from "node:child_process";

export type ProcessResult =
  | { status: "success"; stdout: string; stderr: string; exitCode: number }
  | { status: "failed"; stdout: string; stderr: string; exitCode: number | null }
  | { status: "timed_out"; stdout: string; stderr: string };

export async function runProcess(
  executable: string,
  arguments_: string[],
  options: { deadlineMs: number; maxOutputBytes?: number },
): Promise<ProcessResult> {
  const maxOutputBytes = options.maxOutputBytes ?? 1_048_576;

  return new Promise((resolve) => {
    const child = spawn(executable, arguments_, {
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let outputBytes = 0;
    let resolved = false;
    let forcedStatus: "timed_out" | "failed" | undefined;

    const collect = (destination: Buffer[]) => (chunk: Buffer) => {
      outputBytes += chunk.length;
      if (outputBytes > maxOutputBytes) {
        forcedStatus = "failed";
        stopChild();
        return;
      }
      destination.push(chunk);
    };
    child.stdout.on("data", collect(stdout));
    child.stderr.on("data", collect(stderr));

    const deadline = setTimeout(() => {
      forcedStatus = "timed_out";
      stopChild();
    }, options.deadlineMs);

    const fallback = () => setTimeout(() => finish(null), 250);
    let closeFallback: NodeJS.Timeout | undefined;

    child.once("error", () => {
      forcedStatus = "failed";
      closeFallback ??= fallback();
    });
    child.once("close", (code) => finish(code));

    function stopChild(): void {
      if (child.pid) {
        try { process.kill(-child.pid, "SIGTERM"); } catch { /* already gone */ }
        setTimeout(() => {
          try { process.kill(-child.pid!, "SIGKILL"); } catch { /* already gone */ }
        }, 100).unref();
      }
      child.stdout.destroy();
      child.stderr.destroy();
      closeFallback ??= fallback();
    }

    function finish(exitCode: number | null): void {
      if (resolved) return;
      resolved = true;
      clearTimeout(deadline);
      if (closeFallback) clearTimeout(closeFallback);
      const output = {
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
      };
      if (forcedStatus === "timed_out") {
        resolve({ status: "timed_out", ...output });
      } else if (forcedStatus === "failed" || exitCode !== 0) {
        resolve({ status: "failed", ...output, exitCode });
      } else {
        resolve({ status: "success", ...output, exitCode: 0 });
      }
    }
  });
}

export class BoundedWork {
  private active = 0;
  private readonly waiting: Array<() => void> = [];

  constructor(private readonly limit: number) {
    if (!Number.isInteger(limit) || limit < 1) throw new Error("Work limit must be positive.");
  }

  async run<T>(operation: () => Promise<T>): Promise<T> {
    await this.acquire();
    try {
      return await operation();
    } finally {
      this.active -= 1;
      this.waiting.shift()?.();
    }
  }

  private async acquire(): Promise<void> {
    if (this.active >= this.limit) {
      await new Promise<void>((resolve) => this.waiting.push(resolve));
    }
    this.active += 1;
  }
}

export const machineWork = new BoundedWork(4);
export const summaryWork = new BoundedWork(2);
