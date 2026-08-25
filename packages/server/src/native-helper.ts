import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm, stat } from "node:fs/promises";
import net, { type Socket } from "node:net";
import os from "node:os";
import path from "node:path";
import {
  nativeHelperResponseSchema,
  type AppSettings,
  type NativeHelperFocusTarget,
  type NativeHelperNotification,
  type NativeHelperNotificationPermission,
  type NativeHelperPiRestorationCandidate,
  type NativeHelperPiRestorationUpdate,
  type NativeHelperPill,
  type NativeHelperTerminalTarget,
  type NativeHelperResponse,
  type NativeHelperScreen,
  type NativeHelperUsageGlance,
} from "@agent-visor/protocol";

export interface NativeHelperAdapter {
  screenTopology(): Promise<NativeHelperScreen[]>;
  accessibilityStatus(): Promise<boolean>;
  notificationStatus(): Promise<NativeHelperNotificationPermission>;
  requestNotifications(): Promise<void>;
  reconcileNotifications(
    notifications: NativeHelperNotification[],
    presentNew: boolean,
  ): Promise<void>;
  reconcilePiRestoration(update: NativeHelperPiRestorationUpdate): Promise<void>;
  requestAccessibility(): Promise<void>;
  openAccessibilitySettings(): Promise<void>;
  presentPills(
    pills: NativeHelperPill[],
    usageGlances: NativeHelperUsageGlance[],
    shortcutModifierFamily?: AppSettings["sessionShortcutModifierFamily"],
    hotkeyTrigger?: AppSettings["hotkeyTrigger"],
    customHotkeyCombo?: AppSettings["customHotkeyCombo"],
    navigatorPills?: NativeHelperPill[],
    pillScreen?: AppSettings["pillScreen"],
    fullScreenPolicy?: AppSettings["fullScreenPolicy"],
  ): Promise<void>;
  focus(target: NativeHelperFocusTarget): Promise<void>;
  focusTerminal(target: NativeHelperTerminalTarget): Promise<void>;
  sendTerminal(target: NativeHelperTerminalTarget, text: string, submit: boolean): Promise<void>;
}

export type NativeHelperEvent = Extract<NativeHelperResponse, { type: "event" }>;

export class FakeNativeHelper implements NativeHelperAdapter {
  readonly focusRequests: NativeHelperFocusTarget[] = [];
  readonly terminalFocusRequests: NativeHelperTerminalTarget[] = [];
  readonly terminalSendRequests: Array<{ target: NativeHelperTerminalTarget; text: string; submit: boolean }> = [];
  presentedPills: NativeHelperPill[] = [];
  presentedNotifications: NativeHelperNotification[] = [];
  presentedNewNotifications = false;
  piRestorationCandidates: NativeHelperPiRestorationCandidate[] = [];
  piRestorationLiveSessionIds: string[] = [];
  piRestorationRemovedSessionIds: string[] = [];
  invalidatedPiRestoration = false;
  readonly notificationPresentations: Array<{
    notifications: NativeHelperNotification[];
    presentNew: boolean;
  }> = [];
  presentedNavigatorPills: NativeHelperPill[] = [];
  presentedUsageGlances: NativeHelperUsageGlance[] = [];
  shortcutModifierFamily: AppSettings["sessionShortcutModifierFamily"] = "optionCommand";
  hotkeyTrigger: AppSettings["hotkeyTrigger"] = "shift";
  customHotkeyCombo: AppSettings["customHotkeyCombo"] = null;
  pillScreen: AppSettings["pillScreen"] = { mode: "automatic" };
  fullScreenPolicy: AppSettings["fullScreenPolicy"] = "onDemand";
  requestedAccessibility = false;
  requestedNotifications = false;
  openedAccessibilitySettings = false;

  private readonly screens: NativeHelperScreen[];
  private readonly trusted: boolean;
  private readonly notificationPermission: NativeHelperNotificationPermission;

  constructor(options: {
    screens?: NativeHelperScreen[];
    trusted?: boolean;
    notifications?: NativeHelperNotificationPermission;
  } = {}) {
    this.screens = structuredClone(options.screens ?? []);
    this.trusted = options.trusted ?? false;
    this.notificationPermission = options.notifications ?? "not_determined";
  }

  async screenTopology(): Promise<NativeHelperScreen[]> {
    return structuredClone(this.screens);
  }

  async accessibilityStatus(): Promise<boolean> {
    return this.trusted;
  }

  async notificationStatus(): Promise<NativeHelperNotificationPermission> {
    return this.notificationPermission;
  }

  async requestNotifications(): Promise<void> {
    this.requestedNotifications = true;
  }

  async reconcileNotifications(
    notifications: NativeHelperNotification[],
    presentNew: boolean,
  ): Promise<void> {
    this.presentedNotifications = structuredClone(notifications);
    this.presentedNewNotifications = presentNew;
    this.notificationPresentations.push({
      notifications: structuredClone(notifications),
      presentNew,
    });
  }

  async reconcilePiRestoration(update: NativeHelperPiRestorationUpdate): Promise<void> {
    this.piRestorationCandidates = structuredClone(update.candidates);
    this.piRestorationLiveSessionIds = structuredClone(update.liveSessionIds);
    this.piRestorationRemovedSessionIds = structuredClone(update.removeCandidateSessionIds);
    this.invalidatedPiRestoration = update.cleanTermination;
  }

  async requestAccessibility(): Promise<void> {
    this.requestedAccessibility = true;
  }

  async openAccessibilitySettings(): Promise<void> {
    this.openedAccessibilitySettings = true;
  }

  async presentPills(
    pills: NativeHelperPill[],
    usageGlances: NativeHelperUsageGlance[],
    shortcutModifierFamily: AppSettings["sessionShortcutModifierFamily"] = "optionCommand",
    hotkeyTrigger: AppSettings["hotkeyTrigger"] = "shift",
    customHotkeyCombo: AppSettings["customHotkeyCombo"] = null,
    navigatorPills: NativeHelperPill[] = pills,
    pillScreen: AppSettings["pillScreen"] = { mode: "automatic" },
    fullScreenPolicy: AppSettings["fullScreenPolicy"] = "onDemand",
  ): Promise<void> {
    this.presentedPills = structuredClone(pills);
    this.presentedNavigatorPills = structuredClone(navigatorPills);
    this.presentedUsageGlances = structuredClone(usageGlances);
    this.shortcutModifierFamily = shortcutModifierFamily;
    this.hotkeyTrigger = hotkeyTrigger;
    this.customHotkeyCombo = customHotkeyCombo;
    this.pillScreen = structuredClone(pillScreen);
    this.fullScreenPolicy = fullScreenPolicy;
  }

  async focus(target: NativeHelperFocusTarget): Promise<void> {
    this.focusRequests.push(structuredClone(target));
  }

  async focusTerminal(target: NativeHelperTerminalTarget): Promise<void> {
    this.terminalFocusRequests.push(structuredClone(target));
  }

  async sendTerminal(target: NativeHelperTerminalTarget, text: string, submit: boolean): Promise<void> {
    this.terminalSendRequests.push(structuredClone({ target, text, submit }));
  }
}

export class UnavailableNativeHelper implements NativeHelperAdapter {
  async screenTopology(): Promise<NativeHelperScreen[]> { return []; }
  async accessibilityStatus(): Promise<boolean> { return false; }
  async notificationStatus(): Promise<NativeHelperNotificationPermission> { return "not_determined"; }
  async requestNotifications(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
  async reconcileNotifications(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
  async reconcilePiRestoration(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
  async requestAccessibility(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
  async openAccessibilitySettings(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
  async presentPills(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
  async focus(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
  async focusTerminal(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
  async sendTerminal(): Promise<void> { throw new Error("The signed native helper is unavailable."); }
}

export class NativeHelperProcess implements NativeHelperAdapter {
  private buffer = Buffer.alloc(0);
  private closed = false;
  private failure: Error | undefined;
  private readonly pending = new Map<string, {
    resolve: (response: Exclude<NativeHelperResponse, { type: "event" }>) => void;
    reject: (error: Error) => void;
    deadline: NodeJS.Timeout;
  }>();

  private constructor(
    private readonly child: ChildProcess,
    private readonly socket: Socket,
    private readonly root: string,
    private readonly onEvent: (event: NativeHelperEvent) => void,
  ) {
    socket.on("data", (data) => this.ingest(data));
    socket.once("close", () => this.fail(new Error("The native helper connection closed.")));
    socket.once("error", (error) => this.fail(error));
    child.once("exit", () => this.fail(new Error("The native helper exited.")));
  }

  static async start(
    executable: string,
    onEvent: (event: NativeHelperEvent) => void,
  ): Promise<NativeHelperProcess> {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-native-"));
    const socketPath = path.join(root, "helper.sock");
    const child = spawn("/usr/bin/open", [
      "-n",
      "-W",
      path.resolve(executable, "../../.."),
      "--args",
      "--socket",
      socketPath,
    ], { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    let spawnError: Error | undefined;
    child.once("error", (error) => { spawnError = error; });
    child.stderr?.on("data", (data: Buffer) => {
      stderr = (stderr + data.toString("utf8")).slice(-16_384);
    });

    try {
      await waitForSocket(socketPath, child, () => stderr, () => spawnError);
      const socket = net.createConnection(socketPath);
      await new Promise<void>((resolve, reject) => {
        socket.once("connect", resolve);
        socket.once("error", reject);
      });
      return new NativeHelperProcess(child, socket, root, onEvent);
    } catch (error) {
      child.kill("SIGTERM");
      await rm(root, { recursive: true, force: true });
      throw error;
    }
  }

  async screenTopology(): Promise<NativeHelperScreen[]> {
    const response = await this.request("screen_topology");
    if (response.result.type !== "screen_topology") throw new Error("Unexpected helper response.");
    return response.result.screens;
  }

  async accessibilityStatus(): Promise<boolean> {
    const response = await this.request("accessibility_status");
    if (response.result.type !== "accessibility_status") throw new Error("Unexpected helper response.");
    return response.result.trusted;
  }

  async requestAccessibility(): Promise<void> {
    await this.accepted("request_accessibility");
  }

  async notificationStatus(): Promise<NativeHelperNotificationPermission> {
    const response = await this.request("notification_status");
    if (response.result.type !== "notification_status") {
      throw new Error("Unexpected helper response.");
    }
    return response.result.status;
  }

  async requestNotifications(): Promise<void> {
    await this.accepted("request_notifications");
  }

  async reconcileNotifications(
    notifications: NativeHelperNotification[],
    presentNew: boolean,
  ): Promise<void> {
    await this.accepted("reconcile_notifications", { notifications, presentNew });
  }

  async reconcilePiRestoration(update: NativeHelperPiRestorationUpdate): Promise<void> {
    await this.accepted("reconcile_pi_restoration", update);
  }

  async openAccessibilitySettings(): Promise<void> {
    await this.accepted("open_accessibility_settings");
  }

  async presentPills(
    pills: NativeHelperPill[],
    usageGlances: NativeHelperUsageGlance[],
    shortcutModifierFamily?: AppSettings["sessionShortcutModifierFamily"],
    hotkeyTrigger?: AppSettings["hotkeyTrigger"],
    customHotkeyCombo?: AppSettings["customHotkeyCombo"],
    navigatorPills?: NativeHelperPill[],
    pillScreen?: AppSettings["pillScreen"],
    fullScreenPolicy?: AppSettings["fullScreenPolicy"],
  ): Promise<void> {
    await this.accepted("present_pills", {
      pills,
      ...(navigatorPills ? { navigatorPills } : {}),
      usageGlances,
      ...(shortcutModifierFamily ? { shortcutModifierFamily } : {}),
      ...(pillScreen ? { pillScreen } : {}),
      ...(fullScreenPolicy ? { fullScreenPolicy } : {}),
      ...(hotkeyTrigger ? { hotkeyTrigger, customHotkeyCombo } : {}),
    });
  }

  async focus(target: NativeHelperFocusTarget): Promise<void> {
    await this.accepted("focus", { target });
  }

  async focusTerminal(target: NativeHelperTerminalTarget): Promise<void> {
    await this.accepted("focus_terminal", { target });
  }

  async sendTerminal(target: NativeHelperTerminalTarget, text: string, submit: boolean): Promise<void> {
    await this.accepted("send_terminal", { target, text, submit });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    let invalidationError: unknown;
    try {
      await this.reconcilePiRestoration({
        candidates: [],
        liveSessionIds: [],
        removeCandidateSessionIds: [],
        cleanTermination: true,
      });
    } catch (error) {
      invalidationError = error;
    }
    this.closed = true;
    this.socket.end();
    if (this.child.exitCode === null && this.child.signalCode === null) {
      const exited = new Promise<void>((resolve) => this.child.once("exit", () => resolve()));
      const graceful = await Promise.race([
        exited.then(() => true),
        new Promise<false>((resolve) => setTimeout(() => resolve(false), 2_000)),
      ]);
      if (!graceful) {
        this.child.kill("SIGTERM");
        await exited;
      }
    }
    await rm(this.root, { recursive: true, force: true });
    if (invalidationError) throw invalidationError;
  }

  private async accepted(method: string, params?: unknown): Promise<void> {
    const response = await this.request(method, params);
    if (response.result.type !== "accepted") throw new Error("Unexpected helper response.");
  }

  private request(method: string, params?: unknown) {
    if (this.closed) return Promise.reject(new Error("The native helper is closed."));
    if (this.failure) return Promise.reject(this.failure);
    const id = randomUUID();
    const body = Buffer.from(JSON.stringify({
      version: 1,
      id,
      method,
      ...(params === undefined ? {} : { params }),
    }));
    const header = Buffer.alloc(4);
    header.writeUInt32BE(body.length);

    return new Promise<Extract<NativeHelperResponse, { ok: true }>>((resolve, reject) => {
      const deadline = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`The native helper did not answer ${method}.`));
      }, 3_000);
      this.pending.set(id, {
        resolve: (response) => {
          if (response.ok) resolve(response);
          else reject(new Error(response.error.message));
        },
        reject,
        deadline,
      });
      this.socket.write(Buffer.concat([header, body]));
    });
  }

  private ingest(data: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, data]);
    while (this.buffer.length >= 4) {
      const size = this.buffer.readUInt32BE(0);
      if (size > 1_048_576) {
        this.fail(new Error("The native helper sent an oversized frame."));
        return;
      }
      if (this.buffer.length < size + 4) return;
      const raw = this.buffer.subarray(4, size + 4);
      this.buffer = this.buffer.subarray(size + 4);
      let value: unknown;
      try { value = JSON.parse(raw.toString("utf8")); } catch {
        this.fail(new Error("The native helper sent invalid JSON."));
        return;
      }
      const parsed = nativeHelperResponseSchema.safeParse(value);
      if (!parsed.success) {
        this.fail(new Error("The native helper sent an invalid response."));
        return;
      }
      if ("type" in parsed.data) {
        this.onEvent(parsed.data);
        continue;
      }
      const pending = this.pending.get(parsed.data.id);
      if (!pending) continue;
      clearTimeout(pending.deadline);
      this.pending.delete(parsed.data.id);
      pending.resolve(parsed.data);
    }
  }

  private fail(error: Error): void {
    if (this.closed) return;
    this.failure = error;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.deadline);
      pending.reject(error);
    }
    this.pending.clear();
  }
}

async function waitForSocket(
  socketPath: string,
  child: ChildProcess,
  stderr: () => string,
  spawnError: () => Error | undefined,
): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (spawnError()) throw spawnError()!;
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`The native helper exited during startup. ${stderr()}`.trim());
    }
    try {
      await stat(socketPath);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
  throw new Error("The native helper did not create its socket.");
}
