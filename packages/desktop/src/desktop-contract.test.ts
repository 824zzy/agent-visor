import { describe, expect, it } from "vitest";
import {
  daemonUrlFromArguments,
  daemonUrlFromReadyMessage,
  rendererLocation,
} from "./desktop-contract.js";

const daemonUrl = "ws://127.0.0.1:49152?token=secret";

describe("desktop launch contract", () => {
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

  it("reads the daemon credential from Electron's isolated preload argument", () => {
    expect(daemonUrlFromArguments(["electron", `--agent-visor-daemon=${daemonUrl}`])).toBe(
      daemonUrl,
    );
    expect(daemonUrlFromArguments(["electron", "--agent-visor-daemon=wss://remote.example"]))
      .toBeUndefined();
  });
});
