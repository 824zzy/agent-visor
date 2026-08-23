import { describe, expect, it } from "vitest";
import {
  nativeHelperRequestSchema,
  nativeHelperResponseSchema,
} from "./index.js";

const requests = [
  { version: 1, id: "screens", method: "screen_topology" },
  { version: 1, id: "access", method: "accessibility_status" },
  { version: 1, id: "request-access", method: "request_accessibility" },
  { version: 1, id: "open-access", method: "open_accessibility_settings" },
  {
    version: 1,
    id: "pills",
    method: "present_pills",
    params: {
      pills: [
        {
          id: "session-1",
          title: "Review migration",
          subtitle: "Ready to continue",
          source: "Pi",
          project: "agent-visor",
          owner: "Ghostty",
          phase: "ready",
          priority: 1,
          accessibilityLabel: "Review migration, ready",
        },
      ],
      shortcutModifierFamily: "controlCommand",
      usageGlances: [
        {
          id: "codex",
          label: "5h 82% | 7d 61%",
          detail: "Codex usage, 5 hour 82 percent remaining, weekly 61 percent remaining",
          tone: "normal",
          priority: 100,
          accessibilityLabel: "Codex usage, 5 hour 82 percent remaining, weekly 61 percent remaining",
        },
      ],
    },
  },
  {
    version: 1,
    id: "legacy-pills",
    method: "present_pills",
    params: {
      pills: [{
        id: "legacy-session",
        title: "Legacy session",
        phase: "working",
        priority: 2,
        accessibilityLabel: "Legacy session, in progress",
      }],
    },
  },
  {
    version: 1,
    id: "focus",
    method: "focus",
    params: {
      target: {
        pid: 42,
        bundleIdentifier: "com.mitchellh.ghostty",
        windowId: 7,
      },
    },
  },
] as const;

describe("native helper protocol", () => {
  it("validates every supported request", () => {
    for (const request of requests) {
      expect(nativeHelperRequestSchema.parse(request)).toEqual(request);
    }
  });

  it("rejects unknown methods and inexact focus targets", () => {
    expect(
      nativeHelperRequestSchema.safeParse({
        version: 1,
        id: "bad",
        method: "parse_provider",
      }).success,
    ).toBe(false);

    expect(
      nativeHelperRequestSchema.safeParse({
        version: 1,
        id: "bad-focus",
        method: "focus",
        params: { target: { pid: 0, bundleIdentifier: "" } },
      }).success,
    ).toBe(false);
  });

  it("validates helper activation events", () => {
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "activate_pill",
      sessionId: "session-1",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "open_sessions",
    }).success).toBe(true);
  });

  it("validates typed results and structured errors", () => {
    expect(
      nativeHelperResponseSchema.safeParse({
        version: 1,
        id: "screens",
        ok: true,
        result: {
          type: "screen_topology",
          screens: [
            {
              displayId: 1,
              frame: { x: 0, y: 0, width: 1512, height: 982 },
              visibleFrame: { x: 0, y: 37, width: 1512, height: 945 },
              scale: 2,
              isMain: true,
            },
          ],
        },
      }).success,
    ).toBe(true);

    expect(
      nativeHelperResponseSchema.safeParse({
        version: 1,
        id: "focus",
        ok: false,
        error: { code: "invalid_request", message: "pid must be positive" },
      }).success,
    ).toBe(true);
  });
});
