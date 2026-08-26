import { readFileSync } from "node:fs";
import { expect, it, vi } from "vitest";
import { runBackground } from "./background-task.js";

it("reports rejected background work without leaving an unhandled promise", async () => {
  const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);

  runBackground("session refresh", async () => {
    throw new Error("provider file changed");
  });

  await expect.poll(() => warning.mock.calls.length).toBe(1);
  expect(warning).toHaveBeenCalledWith(
    "Agent Visor session refresh failed: Error: provider file changed",
  );
  warning.mockRestore();
});

it("routes daemon background work through the rejection handler", () => {
  const bin = readFileSync(new URL("./bin.ts", import.meta.url), "utf8");

  for (const label of [
    "notification action", "usage refresh", "session focus", "native services refresh",
    "update check", "session refresh", "shutdown",
  ]) {
    expect(bin).toMatch(new RegExp(`runBackground\\(\\s*\"${label}\"`));
  }
  expect(bin).not.toMatch(/setInterval\(\(\) => void/);
});
