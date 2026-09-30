import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { openCursorWorkspace } from "./cursor-workspace.js";
import { runProcess } from "./machine.js";

vi.mock("./machine.js", () => ({ runProcess: vi.fn() }));
const roots: string[] = [];
afterEach(async () => {
  vi.resetAllMocks();
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

it("opens the owning workspace as one literal argument, without launching a prompt", async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), "visor Cursor space '$(literal)-"));
  roots.push(cwd);
  vi.mocked(runProcess).mockResolvedValue({ status: "success", stdout: "", stderr: "", exitCode: 0 });
  await openCursorWorkspace(cwd);
  expect(runProcess).toHaveBeenCalledWith("/usr/bin/open", ["-b", "com.todesktop.230313mzl4w4u92", cwd], {
    deadlineMs: 5_000, maxOutputBytes: 4_096,
  });
});

it("rejects missing, file, and invalid workspace targets before launching Cursor", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "visor-cursor-missing-"));
  roots.push(root);
  const file = path.join(root, "file");
  await writeFile(file, "fixture");
  for (const cwd of ["relative", "/", "/bad\0path", path.join(root, "missing"), file]) {
    await expect(openCursorWorkspace(cwd)).rejects.toThrow(/workspace/i);
  }
  expect(runProcess).not.toHaveBeenCalled();
});

it.each(["failed", "timed_out"] as const)("reports a %s workspace launch", async (status) => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), "visor-cursor-error-"));
  roots.push(cwd);
  vi.mocked(runProcess).mockResolvedValue({ status, stdout: "", stderr: "", exitCode: 1 });
  await expect(openCursorWorkspace(cwd)).rejects.toThrow("Cursor could not open this workspace.");
});
