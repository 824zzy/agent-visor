import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  appSettingsPatchSchema,
  appSettingsSchema,
  type AppSettings,
  type AppSettingsPatch,
} from "@agent-visor/protocol";
import { runProcess } from "./machine.js";

const defaults: AppSettings = {
  appearance: "dark",
  contentScale: 1,
  pillsEnabled: true,
  codexUsageGlanceEnabled: true,
  claudeUsageGlanceEnabled: true,
  notificationSound: "Pop",
  hotkeyTrigger: "shift",
  customHotkeyCombo: null,
  sessionShortcutModifierFamily: "optionCommand",
  editorPreference: "auto",
  observedWindowHours: 42,
  launchAtLogin: false,
};

export class SettingsRepository {
  private readonly listeners = new Set<(settings: AppSettings) => void>();
  private updateQueue = Promise.resolve();

  private constructor(
    private readonly file: string,
    private value: AppSettings,
    private readonly legacy: Record<string, unknown>,
  ) {}

  static async open(options: {
    root: string;
    readLegacy: () => Promise<Record<string, unknown>>;
  }): Promise<SettingsRepository> {
    await mkdir(options.root, { recursive: true, mode: 0o700 });
    await chmod(options.root, 0o700);
    const file = path.join(options.root, "settings.json");
    try {
      const stored = JSON.parse(await readFile(file, "utf8")) as Record<string, unknown>;
      const storedSettings = record(stored.settings);
      const needsHotkeyDefaults = storedSettings != null
        && (!Object.hasOwn(storedSettings, "hotkeyTrigger")
          || !Object.hasOwn(storedSettings, "customHotkeyCombo"));
      const repository = new SettingsRepository(
        file,
        appSettingsSchema.parse({
          hotkeyTrigger: defaults.hotkeyTrigger,
          customHotkeyCombo: defaults.customHotkeyCombo,
          ...storedSettings,
        }),
        record(stored.legacy) ?? {},
      );
      if (needsHotkeyDefaults) await repository.save();
      return repository;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }

    const legacy = await options.readLegacy();
    const repository = new SettingsRepository(file, migrate(legacy), structuredClone(legacy));
    await repository.save();
    return repository;
  }

  current(): AppSettings {
    return structuredClone(this.value);
  }

  subscribe(listener: (settings: AppSettings) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  update(patch: AppSettingsPatch): Promise<AppSettings> {
    const operation = this.updateQueue.then(async () => {
      const parsed = appSettingsPatchSchema.parse(patch);
      const previous = this.value;
      const next = appSettingsSchema.parse({ ...previous, ...parsed });
      this.value = next;
      try {
        await this.save();
      } catch (error) {
        this.value = previous;
        throw error;
      }
      for (const listener of this.listeners) listener(this.current());
      return this.current();
    });
    this.updateQueue = operation.then(() => undefined, () => undefined);
    return operation;
  }

  private async save(): Promise<void> {
    const temporary = `${this.file}.${process.pid}.tmp`;
    const data = `${JSON.stringify({ version: 1, settings: this.value, legacy: this.legacy }, null, 2)}\n`;
    try {
      await writeFile(temporary, data, { mode: 0o600 });
      await rename(temporary, this.file);
      await chmod(this.file, 0o600);
    } finally {
      await rm(temporary, { force: true });
    }
  }
}

export async function readLegacyDefaults(
  domain: string,
  scratchRoot: string,
): Promise<Record<string, unknown>> {
  const plist = path.join(scratchRoot, "legacy-settings.plist");
  const exported = await runProcess("/usr/bin/defaults", ["export", domain, plist], {
    deadlineMs: 3_000,
  });
  if (exported.status !== "success") return {};
  const legacy: Record<string, unknown> = {
    __rawPlistBase64: (await readFile(plist)).toString("base64"),
  };
  const keys = [
    "appearance", "chatFontScale", "pillsEnabled", "codexUsageGlanceEnabled",
    "claudeUsageGlanceEnabled", "notificationSound", "hotkeyTrigger", "customHotkeyCombo",
    "sessionShortcutModifierFamily", "editorPreference", "observedWindowHours",
  ];
  for (const key of keys) {
    const extracted = await runProcess(
      "/usr/bin/plutil",
      ["-extract", key, "raw", "-o", "-", plist],
      { deadlineMs: 1_000, maxOutputBytes: 4_096 },
    );
    if (extracted.status === "success") legacy[key] = rawValue(extracted.stdout.trim());
  }
  await rm(plist, { force: true });
  return legacy;
}

function migrate(legacy: Record<string, unknown>): AppSettings {
  return appSettingsSchema.parse({
    appearance: oneOf(legacy.appearance, ["system", "dark", "light"]) ?? defaults.appearance,
    contentScale: clamp(number(legacy.chatFontScale) ?? defaults.contentScale, 0.8, 2.5),
    pillsEnabled: boolean(legacy.pillsEnabled) ?? defaults.pillsEnabled,
    codexUsageGlanceEnabled: boolean(legacy.codexUsageGlanceEnabled)
      ?? defaults.codexUsageGlanceEnabled,
    claudeUsageGlanceEnabled: boolean(legacy.claudeUsageGlanceEnabled)
      ?? defaults.claudeUsageGlanceEnabled,
    notificationSound: oneOf(legacy.notificationSound, [
      "None", "Pop", "Ping", "Tink", "Glass", "Blow", "Bottle", "Frog",
      "Funk", "Hero", "Morse", "Purr", "Sosumi", "Submarine", "Basso",
    ]) ?? defaults.notificationSound,
    hotkeyTrigger: oneOf(legacy.hotkeyTrigger, [
      "off", "cmd", "ctrl", "option", "shift", "custom",
    ]) ?? defaults.hotkeyTrigger,
    customHotkeyCombo: customHotkeyCombo(legacy.customHotkeyCombo)
      ?? defaults.customHotkeyCombo,
    sessionShortcutModifierFamily: oneOf(legacy.sessionShortcutModifierFamily, [
      "off", "controlCommand", "optionCommand", "controlOptionCommand",
    ]) ?? defaults.sessionShortcutModifierFamily,
    editorPreference: oneOf(legacy.editorPreference, [
      "auto", "cursor", "vscode", "vscode-insiders", "zed", "xcode", "system-default",
    ]) ?? defaults.editorPreference,
    observedWindowHours: Math.round(clamp(
      number(legacy.observedWindowHours) ?? defaults.observedWindowHours,
      1,
      168,
    )),
    launchAtLogin: defaults.launchAtLogin,
  });
}

function rawValue(value: string): string | number | boolean {
  if (value === "true") return true;
  if (value === "false") return false;
  const number = Number(value);
  return value && Number.isFinite(number) ? number : value;
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}

function boolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function oneOf<T extends string>(value: unknown, values: readonly T[]): T | undefined {
  return typeof value === "string" && values.includes(value as T) ? value as T : undefined;
}

function customHotkeyCombo(value: unknown): AppSettings["customHotkeyCombo"] | undefined {
  const parsed = appSettingsSchema.shape.customHotkeyCombo.safeParse(value);
  return parsed.success ? parsed.data : undefined;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}
