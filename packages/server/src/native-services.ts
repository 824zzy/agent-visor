import { createHash } from "node:crypto";
import type {
  AppSettings,
  ChatPendingAction,
  ClientMessage,
  NativeServicesState,
  SessionSnapshot,
} from "@agent-visor/protocol";
import type { NativeServicesSource } from "./server.js";
import type { AgentConnectionsRepository } from "./agent-connections.js";
import type { NativeHelperAdapter } from "./native-helper.js";
import type { SettingsRepository } from "./settings.js";
import type { UpdateState } from "./updates.js";

export type DesktopNativeEffect =
  | { action: "set_login_item"; enabled: boolean }
  | { action: "open_update"; url: string }
  | { action: "request_notifications" }
  | { action: "set_badge"; count: number };

export class NativeServicesRepository implements NativeServicesSource {
  private revision = 0;
  private state: NativeServicesState;
  private readonly listeners = new Set<(state: NativeServicesState) => void>();
  private previousAttentionKeys: Set<string> | undefined;

  constructor(private readonly options: {
    settings: SettingsRepository;
    helper: NativeHelperAdapter;
    connections: AgentConnectionsRepository;
    currentVersion: string;
    checkUpdates: () => Promise<UpdateState>;
    pendingAction?: (sessionId: string) => ChatPendingAction | undefined;
    emitDesktop: (effect: DesktopNativeEffect) => void;
  }) {
    this.state = {
      type: "native_services_state",
      revision: 0,
      settings: options.settings.current(),
      permissions: { accessibility: "needed", notifications: "not_determined" },
      agents: options.connections.current(),
      pillScreens: [],
      update: { status: "idle", currentVersion: options.currentVersion },
    };
  }

  async start(): Promise<void> {
    this.options.settings.subscribe((settings) => this.publish({ settings }));
    await this.refresh();
    if (this.state.permissions.notifications === "not_determined") {
      await this.options.helper.requestNotifications().catch(() => undefined);
    }
  }

  current(): NativeServicesState {
    return structuredClone(this.state);
  }

  subscribe(listener: (state: NativeServicesState) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async action(message: Extract<ClientMessage, {
    type: "update_settings" | "native_service_action" | "set_agent_connection";
  }>): Promise<string | undefined> {
    try {
      if (message.type === "update_settings") {
        const previous = this.options.settings.current();
        const next = await this.options.settings.update(message.patch);
        if (next.launchAtLogin !== previous.launchAtLogin) {
          this.options.emitDesktop({ action: "set_login_item", enabled: next.launchAtLogin });
        }
        return undefined;
      }

      if (message.type === "set_agent_connection") {
        await this.options.connections.setEnabled(message.agent, message.enabled);
        this.publish({ agents: this.options.connections.current() });
        return undefined;
      }

      switch (message.action) {
      case "request_accessibility":
        await this.options.helper.requestAccessibility();
        break;
      case "open_accessibility_settings":
        await this.options.helper.openAccessibilitySettings();
        break;
      case "request_notifications":
        await this.options.helper.requestNotifications();
        this.options.emitDesktop({ action: "request_notifications" });
        return undefined;
      case "check_updates":
        await this.checkForUpdates();
        return undefined;
      case "open_update": {
        const url = this.state.update.releaseUrl;
        if (!url) return "No verified update is available.";
        this.options.emitDesktop({ action: "open_update", url });
        return undefined;
      }
      }
      await this.refresh();
      return undefined;
    } catch (error) {
      return String(error).slice(0, 1_024);
    }
  }

  setNotificationPermission(
    notifications: NativeServicesState["permissions"]["notifications"],
  ): void {
    this.publish({ permissions: { ...this.state.permissions, notifications } });
  }

  async checkForUpdates(): Promise<void> {
    this.publish({ update: { status: "checking", currentVersion: this.options.currentVersion } });
    this.publish({ update: await this.options.checkUpdates() });
  }

  reconcileSessions(snapshot: SessionSnapshot): void {
    const notifications = snapshot.sessions.flatMap((session) => {
      if (session.section !== "needs_you" && session.section !== "ready") return [];
      const pending = this.options.pendingAction?.(session.id);
      const approval = session.section === "needs_you" && pending?.type === "approval"
        ? pending
        : undefined;
      const key = approval
        ? `${session.id}|approval|${approval.toolUseId}`
        : `${session.id}|turn`;
      return [{
        id: notificationId(key),
        sessionId: session.id,
        title: approval ? `${approval.toolName} needs approval` : session.title,
        ...(approval ? {
          subtitle: session.title,
          body: boundedJSON(approval.input),
          toolUseId: approval.toolUseId,
        } : {
          body: session.section === "needs_you"
            ? `${session.source} needs you`
            : `${session.source} is ready to continue`,
        }),
        sound: this.state.settings.notificationSound,
      }];
    });
    const currentKeys = new Set(notifications.map(({ id }) => id));
    const previousKeys = this.previousAttentionKeys;
    this.previousAttentionKeys = currentKeys;
    void this.options.helper.reconcileNotifications(notifications, previousKeys !== undefined)
      .catch((error: unknown) => {
        console.warn(`Agent Visor notification update failed: ${String(error)}`);
      });
    if (!previousKeys ? currentKeys.size > 0 : currentKeys.size !== previousKeys.size) {
      this.options.emitDesktop({ action: "set_badge", count: currentKeys.size });
    }
  }

  async refresh(): Promise<void> {
    const accessibility = await this.options.helper.accessibilityStatus();
    const notifications = await this.options.helper.notificationStatus();
    const screens = await this.options.helper.screenTopology();
    await this.options.connections.refresh();
    this.publish({
      permissions: {
        accessibility: accessibility ? "granted" : "needed",
        notifications,
      },
      agents: this.options.connections.current(),
      pillScreens: screens.map(({ displayId, name, isBuiltIn, isMain }) => ({
        displayId, name, isBuiltIn, isMain,
      })),
    });
  }

  private publish(patch: Partial<Omit<NativeServicesState, "type" | "revision">>): void {
    const next = { ...this.state, ...patch };
    if (JSON.stringify({ ...next, revision: 0 }) === JSON.stringify({ ...this.state, revision: 0 })) {
      return;
    }
    this.revision += 1;
    this.state = { ...next, revision: this.revision };
    for (const listener of this.listeners) listener(this.current());
  }
}

function notificationId(key: string): string {
  return `attention-${createHash("sha256").update(key).digest("hex")}`;
}

function boundedJSON(value: unknown): string {
  const text = JSON.stringify(value) ?? "";
  return text.length > 240 ? text.slice(0, 240) : text;
}
