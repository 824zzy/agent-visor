import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  daemonUrlFromArguments,
  daemonUrlFromReadyMessage,
  electronDataName,
  integrationResourcesPath,
  nativeActionFromDaemonMessage,
  nativeEffectFromDaemonMessage,
  ownerApplication,
  productName,
  rendererLocation,
  windowCloseAction,
} from "./desktop-contract.js";

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

  it("keeps Electron data separate while preserving the product name", () => {
    expect(electronDataName).toBe("Agent Visor Next");
    expect(productName).toBe("Agent Visor");
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

  it("loads an exported renderer file without a credential query", () => {
    expect(rendererLocation("/tmp/app/index.html")).toEqual({
      kind: "file",
      path: "/tmp/app/index.html",
    });
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

  it("reads the daemon credential from Electron's isolated preload argument", () => {
    expect(daemonUrlFromArguments(["electron", `--agent-visor-daemon=${daemonUrl}`])).toBe(
      daemonUrl,
    );
    expect(daemonUrlFromArguments(["electron", "--agent-visor-daemon=wss://remote.example"]))
      .toBeUndefined();
  });
});
