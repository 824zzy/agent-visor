import { access, mkdir, mkdtemp, readFile, rm, stat, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { AgentConnectionsRepository } from "./agent-connections.js";

const roots: string[] = [];
afterEach(async () => Promise.all(roots.splice(0).map((root) =>
  rm(root, { recursive: true, force: true }))));

async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-agents-"));
  roots.push(root);
  const home = path.join(root, "home");
  const resources = path.join(root, "resources");
  await mkdir(path.join(home, ".claude"), { recursive: true });
  await mkdir(path.join(home, ".codex"), { recursive: true });
  await mkdir(path.join(home, ".augment"), { recursive: true });
  await mkdir(path.join(home, ".pi/agent"), { recursive: true });
  await mkdir(path.join(home, ".cursor"), { recursive: true });
  await mkdir(resources, { recursive: true });
  await writeFile(path.join(resources, "agent-visor-state.py"), "# claude hook\n");
  await writeFile(path.join(resources, "agent-visor-codex-state.py"), "# codex hook\n");
  await writeFile(path.join(resources, "agent-visor-state-auggie.sh"), "# auggie hook\n");
  await writeFile(path.join(resources, "agent-visor-pi.ts.txt"), "// pi extension\n");
  return { home, resources, repository: new AgentConnectionsRepository({ home, resources }) };
}

describe("agent connections", () => {
  it("applies overlapping connection changes in request order", async () => {
    const { home, repository } = await fixture();

    await Promise.all([
      repository.setEnabled("claude", true),
      repository.setEnabled("claude", false),
    ]);

    expect(repository.current().find(({ id }) => id === "claude")?.installed).toBe(false);
    const settings = JSON.parse(await readFile(path.join(home, ".claude/settings.json"), "utf8"));
    expect(JSON.stringify(settings)).not.toContain("agent-visor-state.py");
  });

  it("connects Claude on a new profile without an existing config folder", async () => {
    const { home, repository } = await fixture();
    await rm(path.join(home, ".claude"), { recursive: true });

    await repository.setEnabled("claude", true);

    expect(JSON.parse(await readFile(path.join(home, ".claude/settings.json"), "utf8")))
      .toHaveProperty("hooks.SessionStart");
  });

  it("does not create agent settings when disconnecting an unused integration", async () => {
    const { home, repository } = await fixture();
    const settings = path.join(home, ".claude/settings.json");

    await repository.setEnabled("claude", false);

    await expect(access(settings)).rejects.toThrow();
  });

  it("rejects an unknown hook shape instead of replacing it", async () => {
    const { home, repository } = await fixture();
    const settings = path.join(home, ".claude/settings.json");
    const original = JSON.stringify({ hooks: { Stop: { custom: true } } });
    await writeFile(settings, original);

    await expect(repository.setEnabled("claude", true)).rejects.toThrow("Invalid hooks");

    expect(await readFile(settings, "utf8")).toBe(original);
    await expect(access(path.join(home, ".claude/hooks/agent-visor-state.py"))).rejects.toThrow();
  });

  it("leaves Claude unchanged when its settings are malformed", async () => {
    const { home, repository } = await fixture();
    const settings = path.join(home, ".claude/settings.json");
    await writeFile(settings, "{broken");

    await expect(repository.setEnabled("claude", true)).rejects.toThrow("Cannot read agent settings");

    expect(await readFile(settings, "utf8")).toBe("{broken");
    await expect(access(path.join(home, ".claude/hooks/agent-visor-state.py"))).rejects.toThrow();
  });

  it("connects Claude without replacing existing settings", async () => {
    const { home, repository } = await fixture();
    const settings = path.join(home, ".claude/settings.json");
    await writeFile(settings, JSON.stringify({ theme: "dark", hooks: {
      Stop: [{ hooks: [{ type: "command", command: "existing-hook" }] }],
    } }));

    await repository.setEnabled("claude", true);

    const written = JSON.parse(await readFile(settings, "utf8"));
    expect(written.theme).toBe("dark");
    expect(written.hooks.Stop).toContainEqual({
      hooks: [{ type: "command", command: "existing-hook" }],
    });
    expect(JSON.stringify(written)).toContain("agent-visor-state.py");
    expect(repository.current().find(({ id }) => id === "claude")).toMatchObject({
      available: true, installed: true, control: "toggle",
    });
  });

  it("detects command-line agents before they create config folders", async () => {
    const { home, repository } = await fixture();
    await Promise.all([".codex", ".augment", ".pi", ".cursor"].map((name) =>
      rm(path.join(home, name), { recursive: true, force: true })));
    const bin = path.join(home, ".local/bin");
    await mkdir(bin, { recursive: true });
    for (const name of ["codex", "auggie", "pi", "cursor-agent"]) {
      await writeFile(path.join(bin, name), "#!/bin/sh\n", { mode: 0o755 });
    }

    await repository.refresh();

    expect(repository.current().filter(({ id }) => id !== "claude").every(({ available }) => available))
      .toBe(true);
    expect(await readFile(path.join(home, ".pi/agent/extensions/agent-visor.ts"), "utf8"))
      .toBe("// pi extension\n");
  });

  it("automatically connects Pi and reports Cursor as read-only", async () => {
    const { home, repository } = await fixture();
    const extension = path.join(home, ".pi/agent/extensions/agent-visor.ts");

    await repository.refresh();
    const retainedDate = new Date("2020-01-02T03:04:05.000Z");
    await utimes(extension, retainedDate, retainedDate);
    await repository.refresh();

    expect(await readFile(extension, "utf8")).toBe("// pi extension\n");
    expect((await stat(extension)).mtime.toISOString()).toBe(retainedDate.toISOString());
    expect(repository.current()).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "pi", available: true, installed: true, control: "automatic" }),
      expect.objectContaining({ id: "cursor", available: true, installed: false, control: "read_only" }),
    ]));
  });

  it("connects Auggie with its required regular-expression matcher", async () => {
    const { home, repository } = await fixture();
    const settings = path.join(home, ".augment/settings.json");
    await writeFile(settings, JSON.stringify({ telemetry: false }));

    await repository.setEnabled("auggie", true);

    const written = JSON.parse(await readFile(settings, "utf8"));
    expect(written.telemetry).toBe(false);
    expect(written.hooks.PreToolUse).toEqual([{
      matcher: ".*",
      hooks: [{ type: "command", command: expect.stringContaining("agent-visor-state-auggie.sh") }],
    }]);
  });

  it("connects and disconnects Codex without changing another hook", async () => {
    const { home, repository } = await fixture();
    const settings = path.join(home, ".codex/hooks.json");
    await writeFile(settings, JSON.stringify({ hooks: {
      Stop: [{ matcher: "keep", hooks: [{ type: "command", command: "existing-hook" }] }],
    } }));

    await repository.setEnabled("codex", true);
    expect(JSON.stringify(JSON.parse(await readFile(settings, "utf8"))))
      .toContain("agent-visor-codex-state.py");

    await repository.setEnabled("codex", false);
    expect(JSON.parse(await readFile(settings, "utf8"))).toEqual({ hooks: {
      Stop: [{ matcher: "keep", hooks: [{ type: "command", command: "existing-hook" }] }],
    } });
  });
});
