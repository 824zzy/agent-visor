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
      hotkeyTrigger: "custom",
      customHotkeyCombo: "49:8",
      sessionShortcutModifierFamily: "controlCommand",
      editorPreference: "zed",
      observedWindowHours: 72,
      screenSelectionMode: "specificScreen",
      selectedScreenIdentifier: Buffer.from(JSON.stringify({
        displayID: 5,
        localizedName: "XZ322QU V3",
      })).toString("base64"),
      fullScreenPolicy: "alwaysHide",
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
      hotkeyTrigger: "custom",
      customHotkeyCombo: "49:8",
      sessionShortcutModifierFamily: "controlCommand",
      editorPreference: "zed",
      observedWindowHours: 72,
      pillScreen: { mode: "specific", displayId: 5, name: "XZ322QU V3" },
      fullScreenPolicy: "alwaysHide",
    });
    expect(JSON.parse(await readFile(path.join(root, "settings.json"), "utf8")))
      .toMatchObject({ legacy });
  });

  it("adds new defaults to an existing Electron settings file", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-settings-"));
    roots.push(root);
    const file = path.join(root, "settings.json");
    await writeFile(file, JSON.stringify({
      version: 1,
      settings: {
        appearance: "dark", contentScale: 1, pillsEnabled: true,
        codexUsageGlanceEnabled: true, claudeUsageGlanceEnabled: true,
        notificationSound: "Pop", sessionShortcutModifierFamily: "optionCommand",
        editorPreference: "auto", observedWindowHours: 42, launchAtLogin: false,
      },
      legacy: {},
    }));

    const repository = await SettingsRepository.open({ root, readLegacy: async () => ({}) });

    const addedDefaults = {
      hotkeyTrigger: "shift",
      customHotkeyCombo: null,
      pillScreen: { mode: "automatic" },
      fullScreenPolicy: "onDemand",
    };
    expect(repository.current()).toMatchObject(addedDefaults);
    expect(JSON.parse(await readFile(file, "utf8")).settings).toMatchObject(addedDefaults);
  });

  it("restores display settings from the preserved legacy plist", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-settings-"));
    roots.push(root);
    const file = path.join(root, "settings.json");
    const identifier = Buffer.from(JSON.stringify({
      displayID: 9,
      localizedName: "Studio Display",
    })).toString("base64");
    const plist = `<?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>screenSelectionMode</key><string>specificScreen</string>
        <key>selectedScreenIdentifier</key><data>${identifier}</data>
        <key>fullScreenPolicy</key><string>alwaysShow</string>
      </dict></plist>`;
    await writeFile(file, JSON.stringify({
      version: 1,
      settings: {
        appearance: "dark", contentScale: 1, pillsEnabled: true,
        codexUsageGlanceEnabled: true, claudeUsageGlanceEnabled: true,
        notificationSound: "Pop", hotkeyTrigger: "shift", customHotkeyCombo: null,
        sessionShortcutModifierFamily: "optionCommand", editorPreference: "auto",
        observedWindowHours: 42, launchAtLogin: false,
      },
      legacy: { __rawPlistBase64: Buffer.from(plist).toString("base64") },
    }));

    const repository = await SettingsRepository.open({ root, readLegacy: async () => ({}) });

    expect(repository.current()).toMatchObject({
      pillScreen: { mode: "specific", displayId: 9, name: "Studio Display" },
      fullScreenPolicy: "alwaysShow",
    });
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
