import { describe, expect, it } from "vitest";
import {
  nativeHelperRequestSchema,
  nativeHelperResponseSchema,
} from "./index.js";

const requests = [
  { version: 1, id: "screens", method: "screen_topology" },
  { version: 1, id: "access", method: "accessibility_status" },
  { version: 1, id: "notifications", method: "notification_status" },
  { version: 1, id: "request-notifications", method: "request_notifications" },
  { version: 1, id: "request-access", method: "request_accessibility" },
  { version: 1, id: "open-access", method: "open_accessibility_settings" },
  {
    version: 1,
    id: "notifications",
    method: "reconcile_notifications",
    params: {
      presentNew: true,
      notifications: [{
        id: "attention-1",
        sessionId: "session-1",
        title: "Bash needs approval",
        subtitle: "Review migration",
        body: "{\"command\":\"npm test\"}",
        toolUseId: "tool-7",
        sound: "Pop",
      }],
    },
  },
  {
    version: 1,
    id: "pi-restoration",
    method: "reconcile_pi_restoration",
    params: {
      candidates: [{
        sessionId: "pi-1",
        sessionFile: "/Users/me/.pi/agent/sessions/pi-1.jsonl",
        cwd: "/Users/me/Codes/agent-visor",
        sessionName: "Restore Pi sessions",
        pid: 43,
        tty: "ttys001",
      }],
      liveSessionIds: ["pi-1"],
      removeCandidateSessionIds: [],
      cleanTermination: false,
    },
  },
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
          inspector: {
            status: "Ready",
            runtimeItems: ["Pi · Ghostty", "Claude Sonnet 4"],
            detailRows: [{ label: "Reasoning", value: "High" }],
            projectPath: "~/Codes/agent-visor",
            activityAt: "2026-08-22T21:02:18.000Z",
            context: { usedLabel: "84k", windowLabel: "200k", percentage: 42 },
          },
          phase: "ready",
          priority: 1,
          accessibilityLabel: "Review migration, ready",
        },
        {
          id: "session-2",
          title: "Recent migration",
          phase: "history",
          priority: 2,
          accessibilityLabel: "Recent migration, recent session",
        },
      ],
      navigatorPills: [{
        id: "chat-history",
        title: "Chat history",
        phase: "history",
        priority: 3,
        accessibilityLabel: "Chat history, recent session",
      }],
      shortcutModifierFamily: "controlCommand",
      pillScreen: { mode: "specific", displayId: 5, name: "XZ322QU V3" },
      fullScreenPolicy: "alwaysHide",
      hotkeyTrigger: "custom",
      customHotkeyCombo: "49:8",
      usageGlances: [
        {
          id: "codex",
          heading: "Codex Usage",
          width: 114,
          label: "5h 82% | 7d 61%",
          detail: "Codex usage, 5 hour 82 percent remaining, weekly 61 percent remaining",
          tone: "normal",
          priority: 100,
          accessibilityLabel: "Codex usage, 5 hour 82 percent remaining, weekly 61 percent remaining",
          observedAt: "2026-08-24T12:00:00.000Z",
          windows: [
            {
              title: "5 hour limit",
              remainingPercent: 82,
              tone: "normal",
              resetsAt: "2026-08-24T13:00:00.000Z",
            },
            {
              title: "Weekly limit",
              remainingPercent: 61,
              tone: "normal",
            },
          ],
          resetCreditsAvailable: 3,
          stale: true,
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
  {
    version: 1,
    id: "focus-terminal",
    method: "focus_terminal",
    params: { target: { application: "Ghostty", tty: "ttys012", cwd: "/tmp/project" } },
  },
  {
    version: 1,
    id: "send-terminal",
    method: "send_terminal",
    params: {
      target: { application: "Ghostty", tty: "/dev/ttys012", cwd: "/tmp/project" },
      text: "Continue",
      submit: true,
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
    expect(
      nativeHelperRequestSchema.safeParse({
        version: 1,
        id: "unsafe-terminal",
        method: "focus_terminal",
        params: { target: { application: "Ghostty", tty: "/dev/null", cwd: "/" } },
      }).success,
    ).toBe(false);
    expect(nativeHelperRequestSchema.safeParse({
      version: 1,
      id: "unsafe-hotkey",
      method: "present_pills",
      params: { pills: [], hotkeyTrigger: "custom", customHotkeyCombo: "99999:99" },
    }).success).toBe(false);
    expect(nativeHelperRequestSchema.safeParse({
      version: 1,
      id: "unsafe-usage",
      method: "present_pills",
      params: {
        pills: [],
        usageGlances: [{
          id: "codex",
          label: "5h 0%",
          detail: "Codex usage",
          tone: "critical",
          priority: 100,
          accessibilityLabel: "Codex usage",
          windows: [{ title: "5 hour limit", remainingPercent: 101 }],
        }],
      },
    }).success).toBe(false);
    expect(nativeHelperRequestSchema.safeParse({
      version: 1,
      id: "unsafe-screen",
      method: "present_pills",
      params: { pills: [], pillScreen: { mode: "automatic", name: "Injected" } },
    }).success).toBe(false);
    expect(nativeHelperRequestSchema.safeParse({
      version: 1,
      id: "unsafe-restoration",
      method: "reconcile_pi_restoration",
      params: {
        candidates: [{
          sessionId: "pi-1",
          sessionFile: "relative.jsonl",
          cwd: "/project",
          pid: 43,
          tty: "ttys001",
          provider: "Pi",
        }],
        liveSessionIds: ["pi-1"],
        removeCandidateSessionIds: [],
        cleanTermination: false,
      },
    }).success).toBe(false);
    expect(nativeHelperRequestSchema.safeParse({
      version: 1,
      id: "untitled-usage",
      method: "present_pills",
      params: {
        pills: [],
        usageGlances: [{
          id: "codex",
          label: "5h 82%",
          detail: "Codex usage",
          tone: "normal",
          priority: 100,
          accessibilityLabel: "Codex usage",
          windows: [{ remainingPercent: 82 }],
        }],
      },
    }).success).toBe(false);
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
      event: "activate_pill",
      sessionId: "session-1",
      intent: "chat",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "activate_pill",
      sessionId: "session-1",
      intent: "unsafe",
    }).success).toBe(false);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "open_sessions",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "toggle_sessions",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "open_settings",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "refresh_usage",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "notification_permission",
      status: "authorized",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "notification_action",
      action: "activate",
      sessionId: "session-1",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "notification_action",
      action: "approve",
      sessionId: "session-1",
      toolUseId: "tool-7",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "notification_action",
      action: "deny",
      sessionId: "session-1",
      toolUseId: "tool-7",
    }).success).toBe(true);
    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      type: "event",
      event: "notification_action",
      action: "approve",
      sessionId: "session-1",
    }).success).toBe(false);
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
              name: "Built-in Retina Display",
              isBuiltIn: true,
              frame: { x: 0, y: 0, width: 1512, height: 982 },
              visibleFrame: { x: 0, y: 37, width: 1512, height: 945 },
              scale: 2,
              isMain: true,
            },
          ],
        },
      }).success,
    ).toBe(true);

    expect(nativeHelperResponseSchema.safeParse({
      version: 1,
      id: "notifications",
      ok: true,
      result: { type: "notification_status", status: "authorized" },
    }).success).toBe(true);

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
