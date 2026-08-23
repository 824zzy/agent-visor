import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SettingsRepository } from "./settings.js";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("settings repository", () => {
  it("migrates released UserDefaults once and preserves every legacy value", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-settings-"));
    roots.push(root);
    const legacy = {
      appearance: "light",
      chatFontScale: 1.4,
      pillsEnabled: false,
      codexUsageGlanceEnabled: false,
      claudeUsageGlanceEnabled: true,
      notificationSound: "Ping",
      sessionShortcutModifierFamily: "controlCommand",
      editorPreference: "zed",
      observedWindowHours: 72,
      futureReleasedSetting: { nested: true },
    };
    const repository = await SettingsRepository.open({
      root,
      readLegacy: async () => legacy,
    });

    expect(repository.current()).toMatchObject({
      appearance: "light",
      contentScale: 1.4,
      pillsEnabled: false,
      codexUsageGlanceEnabled: false,
      claudeUsageGlanceEnabled: true,
      notificationSound: "Ping",
      sessionShortcutModifierFamily: "controlCommand",
      editorPreference: "zed",
      observedWindowHours: 72,
    });
    expect(JSON.parse(await readFile(path.join(root, "settings.json"), "utf8")))
      .toMatchObject({ legacy });
  });

  it("does not overwrite an unreadable settings file", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-settings-"));
    roots.push(root);
    const file = path.join(root, "settings.json");
    await writeFile(file, "not-json");

    await expect(SettingsRepository.open({ root, readLegacy: async () => ({}) })).rejects.toThrow();
    expect(await readFile(file, "utf8")).toBe("not-json");
  });

  it("validates updates and replaces the file atomically", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-settings-"));
    roots.push(root);
    const repository = await SettingsRepository.open({ root, readLegacy: async () => ({}) });

    await Promise.all([
      repository.update({ appearance: "system" }),
      repository.update({ contentScale: 2.5, observedWindowHours: 168 }),
    ]);
    expect(repository.current()).toMatchObject({
      appearance: "system",
      contentScale: 2.5,
      observedWindowHours: 168,
    });
    await expect(repository.update({ contentScale: 4 } as never)).rejects.toThrow();
    expect(repository.current().contentScale).toBe(2.5);
  });
});
