import type {
  AppSettings,
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
  | {
    action: "notify";
    notification: {
      id: string;
      sessionId: string;
      title: string;
      body: string;
      owner: string;
      sound: AppSettings["notificationSound"];
    };
  };

export class NativeServicesRepository implements NativeServicesSource {
  private revision = 0;
  private state: NativeServicesState;
  private readonly listeners = new Set<(state: NativeServicesState) => void>();
  private previousSections: Map<string, string> | undefined;

  constructor(private readonly options: {
    settings: SettingsRepository;
    helper: NativeHelperAdapter;
    connections: AgentConnectionsRepository;
    currentVersion: string;
    checkUpdates: () => Promise<UpdateState>;
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

  async checkForUpdates(): Promise<void> {
    this.publish({ update: { status: "checking", currentVersion: this.options.currentVersion } });
    this.publish({ update: await this.options.checkUpdates() });
  }

  reconcileSessions(snapshot: SessionSnapshot): void {
    const next = new Map(snapshot.sessions.map((session) => [session.id, session.section]));
    if (this.previousSections) {
      for (const session of snapshot.sessions) {
        const previous = this.previousSections.get(session.id);
        if (previous === session.section
          || (session.section !== "needs_you" && session.section !== "ready")) continue;
        this.options.emitDesktop({
          action: "notify",
          notification: {
            id: `${session.section}-${session.id}-${snapshot.revision}`,
            sessionId: session.id,
            title: session.title,
            body: session.section === "needs_you"
              ? `${session.source} needs you`
              : `${session.source} is ready to continue`,
            owner: session.owner,
            sound: this.state.settings.notificationSound,
          },
        });
      }
    }
    this.previousSections = next;
  }

  async refresh(): Promise<void> {
    const accessibility = await this.options.helper.accessibilityStatus();
    const screens = await this.options.helper.screenTopology();
    await this.options.connections.refresh();
    this.publish({
      permissions: {
        ...this.state.permissions,
        accessibility: accessibility ? "granted" : "needed",
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
