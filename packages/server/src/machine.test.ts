import { describe, expect, it } from "vitest";
import { BoundedWork, runProcess } from "./machine.js";

describe("runProcess", () => {
  it("captures a successful child process", async () => {
    await expect(
      runProcess("/bin/echo", ["hello"], { deadlineMs: 1_000 }),
    ).resolves.toMatchObject({ status: "success", stdout: "hello\n" });
  });

  it("bounds a child that retains its output pipe", async () => {
    const started = Date.now();
    const result = await runProcess(
      "/bin/sh",
      ["-c", "sleep 5 & echo retained"],
      { deadlineMs: 100 },
    );

    expect(result.status).toBe("timed_out");
    expect(Date.now() - started).toBeLessThan(1_000);
  });
});

describe("BoundedWork", () => {
  it("never exceeds its configured concurrency", async () => {
    const work = new BoundedWork(2);
    let active = 0;
    let maximum = 0;

    await Promise.all(
      Array.from({ length: 8 }, () => work.run(async () => {
        active += 1;
        maximum = Math.max(maximum, active);
        await new Promise((resolve) => setTimeout(resolve, 10));
        active -= 1;
      })),
    );

    expect(maximum).toBe(2);
  });
});
