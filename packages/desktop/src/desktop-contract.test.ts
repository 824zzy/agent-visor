import { mkdir, mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  daemonUrlFromArguments,
  daemonUrlFromReadyMessage,
  electronDataName,
  electronStagingDataName,
  integrationResourcesPath,
  nativeActionFromDaemonMessage,
  nativeEffectFromDaemonMessage,
  ownerApplication,
  productName,
  rendererLocation,
  rendererURLAllowed,
  safeExternalURL,
  windowCloseAction,
} from "./desktop-contract.js";
import { migrateElectronDataDirectory } from "./electron-data-migration.js";
import { runIfSingleInstance } from "./single-instance.js";

const daemonUrl = "ws://127.0.0.1:49152?token=secret";

describe("desktop launch contract", () => {
  it("uses bundled agent integrations when a release folder contains them", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-resources-"));
    try {
      await mkdir(path.join(root, "AgentIntegrations"));
      expect(integrationResourcesPath(root, "/source/integrations"))
        .toBe(path.join(root, "AgentIntegrations"));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("uses the stable Electron profile name while preserving the product name", () => {
    expect(electronDataName).toBe("Agent Visor");
    expect(productName).toBe("Agent Visor");
  });

  it("copies the staging profile once and preserves settings, images, and Pi state", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-data-migration-"));
    try {
      const staging = path.join(root, electronStagingDataName);
      await mkdir(path.join(staging, "chat-images", "delivery-1"), { recursive: true });
      await writeFile(path.join(staging, "settings.json"), "staging-settings");
      await writeFile(path.join(staging, "chat-images", "delivery-1", "image.png"), "image");
      await writeFile(path.join(staging, "pi-runtime-links.json"), "pi-links");

      await expect(migrateElectronDataDirectory(root)).resolves.toEqual({
        status: "migrated", entryCount: 3,
      });

      const stable = path.join(root, electronDataName);
      await expect(readFile(path.join(stable, "settings.json"), "utf8"))
        .resolves.toBe("staging-settings");
      await expect(readFile(path.join(stable, "chat-images", "delivery-1", "image.png"), "utf8"))
        .resolves.toBe("image");
      await expect(readFile(path.join(stable, "pi-runtime-links.json"), "utf8"))
        .resolves.toBe("pi-links");
      await expect(readFile(path.join(staging, "settings.json"), "utf8"))
        .resolves.toBe("staging-settings");

      await writeFile(path.join(staging, "added-after-migration.json"), "staging-only");
      await expect(migrateElectronDataDirectory(root)).resolves.toEqual({
        status: "already_present",
      });
      await expect(readFile(path.join(stable, "added-after-migration.json"), "utf8"))
        .rejects.toMatchObject({ code: "ENOENT" });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("imports staging data when Electron pre-creates an empty stable directory", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-data-migration-empty-stable-"));
    try {
      const stable = path.join(root, electronDataName);
      const staging = path.join(root, electronStagingDataName);
      await mkdir(stable, { recursive: true });
      await writeFile(path.join(stable, "Local State"), "electron-bootstrap");
      await mkdir(staging, { recursive: true });
      await writeFile(path.join(staging, "settings.json"), "staging-settings");

      await expect(migrateElectronDataDirectory(root)).resolves.toEqual({
        status: "migrated", entryCount: 1,
      });
      await expect(readFile(path.join(stable, "settings.json"), "utf8"))
        .resolves.toBe("staging-settings");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not overwrite a stable profile with staging data", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-data-migration-"));
    try {
      const stable = path.join(root, electronDataName);
      const staging = path.join(root, electronStagingDataName);
      await mkdir(stable, { recursive: true });
      await mkdir(staging, { recursive: true });
      await writeFile(path.join(stable, "settings.json"), "newer-stable-settings");
      await writeFile(path.join(staging, "settings.json"), "older-staging-settings");

      await expect(migrateElectronDataDirectory(root)).resolves.toEqual({
        status: "already_present",
      });
      await expect(readFile(path.join(stable, "settings.json"), "utf8"))
        .resolves.toBe("newer-stable-settings");
      await expect(readFile(path.join(staging, "settings.json"), "utf8"))
        .resolves.toBe("older-staging-settings");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("defers migration while Chromium holds the staging profile lock", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-data-migration-live-"));
    const staging = path.join(root, electronStagingDataName);
    const lockPath = path.join(staging, "Local Storage", "leveldb", "LOCK");
    try {
      // Electron may bootstrap the stable directory before main.ts redirects
      // userData to the single-instance path.
      const stable = path.join(root, electronDataName);
      await mkdir(stable, { recursive: true });
      await writeFile(path.join(stable, "Local State"), "electron-bootstrap");
      await mkdir(path.dirname(lockPath), { recursive: true });
      await writeFile(path.join(staging, "settings.json"), "live-staging-settings");
      const lock = await open(lockPath, "w");
      try {
        await expect(migrateElectronDataDirectory(root)).resolves.toEqual({
          status: "source_live",
        });
        await expect(readFile(path.join(staging, "settings.json"), "utf8"))
          .resolves.toBe("live-staging-settings");
        await expect(readFile(path.join(root, electronDataName, "settings.json"), "utf8"))
          .rejects.toMatchObject({ code: "ENOENT" });
      } finally {
        await lock.close();
      }
      await expect(migrateElectronDataDirectory(root)).resolves.toEqual({
        status: "migrated", entryCount: 2,
      });
      await expect(readFile(path.join(stable, "settings.json"), "utf8"))
        .resolves.toBe("live-staging-settings");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("omits stale Chromium lock markers while preserving the staging source", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-data-migration-stale-"));
    const staging = path.join(root, electronStagingDataName);
    const staleMarkers = [
      "SingletonLock",
      "SingletonCookie",
      path.join("Local Storage", "leveldb", "LOCK"),
      path.join("Session Storage", "LOCK"),
      path.join("Session Storage", "leveldb", "LOCK"),
      path.join("IndexedDB", "https_example", "leveldb", "LOCK"),
    ];
    try {
      await mkdir(staging, { recursive: true });
      await writeFile(path.join(staging, "settings.json"), "staging-settings");
      await writeFile(path.join(staging, "SingletonLock"), "stale");
      await writeFile(path.join(staging, "SingletonCookie"), "stale");
      for (const relativePath of staleMarkers.slice(2)) {
        await mkdir(path.dirname(path.join(staging, relativePath)), { recursive: true });
        await writeFile(path.join(staging, relativePath), "stale");
      }
      await writeFile(path.join(staging, "Local Storage", "leveldb", "CURRENT"), "current");

      await expect(migrateElectronDataDirectory(root)).resolves.toEqual({
        status: "migrated", entryCount: 4,
      });

      const stable = path.join(root, electronDataName);
      await expect(readFile(path.join(stable, "settings.json"), "utf8"))
        .resolves.toBe("staging-settings");
      await expect(readFile(path.join(stable, "Local Storage", "leveldb", "CURRENT"), "utf8"))
        .resolves.toBe("current");
      for (const relativePath of staleMarkers) {
        await expect(readFile(path.join(stable, relativePath), "utf8"))
          .rejects.toMatchObject({ code: "ENOENT" });
        await expect(readFile(path.join(staging, relativePath), "utf8"))
          .resolves.toBe("stale");
      }
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not start migration or services in a second instance", async () => {
    const calls: string[] = [];
    let lockHeld = false;
    const launch = () => runIfSingleInstance(
      () => {
        calls.push("lock");
        if (lockHeld) return false;
        lockHeld = true;
        return true;
      },
      async () => {
        calls.push("migration", "daemon", "helper");
        return "started";
      },
      () => calls.push("quit"),
    );

    await expect(launch()).resolves.toBe("started");
    await expect(launch()).resolves.toBeUndefined();
    expect(calls).toEqual(["lock", "migration", "daemon", "helper", "lock", "quit"]);
  });

  it("hides the main window unless the application is quitting", () => {
    expect(windowCloseAction(false)).toBe("hide");
    expect(windowCloseAction(true)).toBe("close");
  });

  it("keeps the daemon credential out of an Expo development URL", () => {
    expect(rendererLocation("http://127.0.0.1:8081")).toEqual({
      kind: "url",
      value: "http://127.0.0.1:8081/",
    });
  });

  it("allows only explicit loopback renderer origins", () => {
    const location = rendererLocation("http://127.0.0.1:8081");
    expect(location).toEqual({ kind: "url", value: "http://127.0.0.1:8081/" });
    expect(rendererLocation("https://remote.example/app")).toBeUndefined();
    expect(rendererLocation("http://192.168.1.20:8081/app")).toBeUndefined();
    expect(rendererLocation("http://127.0.0.1:8081/app#unsafe")).toBeUndefined();
    expect(rendererURLAllowed(location!, "http://127.0.0.1:8081/chat")).toBe(true);
    expect(rendererURLAllowed(location!, "http://localhost:8081/chat")).toBe(false);
    expect(rendererURLAllowed(location!, "https://127.0.0.1:8081/chat")).toBe(false);
  });

  it("loads an exported renderer file without a credential query", () => {
    const location = rendererLocation("/tmp/app/index.html");
    expect(location).toEqual({
      kind: "file",
      path: "/tmp/app/index.html",
    });
    expect(rendererURLAllowed(location!, "file:///tmp/app/index.html")).toBe(true);
    expect(rendererURLAllowed(location!, "file:///tmp/app/other.html")).toBe(false);
    expect(rendererURLAllowed(location!, "file:///tmp/app/index.html?redirect=1")).toBe(false);
    expect(rendererURLAllowed(location!, "http://127.0.0.1:8081/index.html")).toBe(false);
  });

  it("accepts only a local WebSocket daemon ready message", () => {
    expect(daemonUrlFromReadyMessage({ type: "ready", url: daemonUrl })).toBe(daemonUrl);
    expect(
      daemonUrlFromReadyMessage({ type: "ready", url: "ws://127.0.0.1:49152" }),
    ).toBeUndefined();
    expect(
      daemonUrlFromReadyMessage({ type: "ready", url: "wss://remote.example" }),
    ).toBeUndefined();
    expect(daemonUrlFromReadyMessage({ type: "ready" })).toBeUndefined();
  });

  it("accepts only bounded native actions from the daemon", () => {
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "open_owner",
      owner: "Ghostty",
      sessionId: "session-1",
    })).toEqual({ action: "open_owner", owner: "Ghostty", sessionId: "session-1" });
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "open_sessions",
    })).toEqual({ action: "open_sessions" });
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "toggle_sessions",
    })).toEqual({ action: "toggle_sessions" });
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "open_settings",
    })).toEqual({ action: "open_settings" });
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "open_chat",
      sessionId: "session-1",
    })).toEqual({ action: "open_chat", sessionId: "session-1" });
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "open_chat",
      sessionId: "",
    })).toBeUndefined();
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "open_session_url",
      url: "codex://threads/019f3931-ec11-7f31-8400-1c8624aa9e4d",
    })).toEqual({
      action: "open_session_url",
      url: "codex://threads/019f3931-ec11-7f31-8400-1c8624aa9e4d",
    });
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "open_session_url",
      url: "file:///tmp/unsafe",
    })).toBeUndefined();
    expect(nativeActionFromDaemonMessage({
      type: "native_action",
      action: "open_owner",
      owner: "arbitrary --argument",
      sessionId: "session-1",
    })).toBeUndefined();
  });

  it("accepts only bounded native effects from the daemon", () => {
    expect(nativeEffectFromDaemonMessage({
      type: "native_effect", action: "request_notifications",
    })).toEqual({ action: "request_notifications" });
    expect(nativeEffectFromDaemonMessage({
      type: "native_effect", action: "notify", notification: {},
    })).toBeUndefined();
    expect(nativeEffectFromDaemonMessage({
      type: "native_effect", action: "set_badge", count: 2,
    })).toEqual({ action: "set_badge", count: 2 });
    expect(nativeEffectFromDaemonMessage({
      type: "native_effect", action: "set_login_item", enabled: true,
    })).toEqual({ action: "set_login_item", enabled: true });
    expect(nativeEffectFromDaemonMessage({
      type: "native_effect",
      action: "open_update",
      url: "https://github.com/824zzy/agent-visor/releases/tag/v2.6.3",
    })).toEqual({
      action: "open_update",
      url: "https://github.com/824zzy/agent-visor/releases/tag/v2.6.3",
    });
    expect(nativeEffectFromDaemonMessage({
      type: "native_effect", action: "open_update", url: "https://example.com/update",
    })).toBeUndefined();
  });

  it("allows only known owner applications", () => {
    expect(ownerApplication("Ghostty")).toBe("Ghostty");
    expect(ownerApplication("Claude Code")).toBe("Claude");
    expect(ownerApplication("arbitrary --argument")).toBeUndefined();
  });

  it("allows only bounded host-safe external URLs", () => {
    expect(safeExternalURL("https://example.com/docs")).toBe("https://example.com/docs");
    expect(safeExternalURL("mailto:owner@example.com")).toBe("mailto:owner@example.com");
    expect(safeExternalURL("javascript:alert(1)")).toBeUndefined();
    expect(safeExternalURL("file:///tmp/private")).toBeUndefined();
    expect(safeExternalURL("https://example.com/\nopen")).toBeUndefined();
    expect(safeExternalURL("https://example.com/" + "x".repeat(4_096))).toBeUndefined();
    expect(safeExternalURL({ href: "https://example.com" })).toBeUndefined();
  });

  it("reads the daemon credential from Electron's isolated preload argument", () => {
    expect(daemonUrlFromArguments(["electron", `--agent-visor-daemon=${daemonUrl}`])).toBe(
      daemonUrl,
    );
    expect(daemonUrlFromArguments(["electron", "--agent-visor-daemon=wss://remote.example"]))
      .toBeUndefined();
  });
});
