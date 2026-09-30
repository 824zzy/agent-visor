import { useEffect, useMemo, useState } from "react";
import { Pressable, ScrollView, Text, TextInput, View } from "react-native";
import {
  defaultChatVisibility,
  type AppSettings,
  type AppSettingsPatch,
  type ChatVisibility,
  type NativeServicesState,
} from "@agent-visor/protocol";
import { browserCommand } from "./browser-shortcuts";
import { pillScreenChoices } from "./pill-screen-choice";
import type { Palette } from "./theme";

const sounds = ["None", "Pop", "Ping", "Tink", "Glass"] as const;
const shortcuts = ["off", "controlCommand", "optionCommand", "controlOptionCommand"] as const;
const hotkeyTriggers = ["off", "cmd", "ctrl", "option", "shift"] as const;
const fullScreenPolicies = ["onDemand", "alwaysHide", "alwaysShow"] as const;
const editors = ["auto", "cursor", "vscode", "vscode-insiders", "zed", "xcode", "system-default"] as const;
const shortcutLabels = {
  off: "Off",
  controlCommand: "⌃⌘ Control–Command",
  optionCommand: "⌥⌘ Option–Command",
  controlOptionCommand: "⌃⌥⌘ Control–Option–Command",
};
const hotkeyLabels = {
  off: "Off",
  cmd: "Double-tap ⌘",
  ctrl: "Double-tap ⌃",
  option: "Double-tap ⌥",
  shift: "Double-tap ⇧",
};
const editorLabels = {
  auto: "Auto-detect",
  cursor: "Cursor",
  vscode: "VS Code",
  "vscode-insiders": "VS Code Insiders",
  zed: "Zed",
  xcode: "Xcode",
  "system-default": "System default",
};
const themeLabels = { system: "System", dark: "Dark", light: "Light" };
const fullScreenPolicyLabels = {
  onDemand: "Show on demand",
  alwaysHide: "Always hide",
  alwaysShow: "Always show",
};
const categories = ["general", "appearance", "chat", "pills", "notifications", "agents"] as const;
type SettingsCategory = typeof categories[number];
const categoryLabels: Record<SettingsCategory, string> = {
  general: "General",
  appearance: "Appearance",
  chat: "Chat",
  pills: "Pills",
  notifications: "Notifications",
  agents: "Agents",
};

const chatVisibilitySections: Array<{
  title: string;
  subtitle: string;
  items: Array<[string, keyof ChatVisibility]>;
}> = [
  {
    title: "Layout",
    subtitle: "Group each prompt, its work, and its final answer",
    items: [
      ["Group Claude Code turns", "collapseClaudeTurns"],
      ["Group Codex turns", "collapseCodexTurns"],
      ["Group Pi turns", "collapsePiTurns"],
    ],
  },
  {
    title: "Messages",
    subtitle: "Choose which conversation content remains visible",
    items: [
      ["User messages", "showUserMessage"],
      ["Assistant messages", "showAssistantMessage"],
      ["Thinking", "showThinking"],
    ],
  },
  {
    title: "File tools",
    subtitle: "File reads, searches, and changes",
    items: [
      ["Read", "showRead"], ["Edit", "showEdit"], ["Write", "showWrite"],
      ["Grep", "showGrep"], ["Glob", "showGlob"],
    ],
  },
  {
    title: "Shell, web, and other tools",
    subtitle: "Commands, web access, subagents, questions, and extensions",
    items: [
      ["Bash", "showBash"], ["Bash output", "showBashOutput"],
      ["Kill shell", "showKillShell"], ["Web fetch", "showWebFetch"],
      ["Web search", "showWebSearch"], ["Tasks and subagents", "showTask"],
      ["Todo write", "showTodoWrite"], ["Ask user question", "showAskUserQuestion"],
      ["Plan mode", "showPlanMode"], ["MCP tools", "showMCP"],
      ["Other tools", "showOtherTools"],
    ],
  },
  {
    title: "Session metadata",
    subtitle: "Lifecycle and context markers in the timeline",
    items: [
      ["Turn duration", "showTurnDuration"], ["Recap rows", "showRecap"],
      ["Compact boundaries", "showCompactBoundary"],
      ["Local command output", "showLocalCommandOutput"],
      ["Interrupted", "showInterrupted"],
    ],
  },
];

export function Settings({
  state,
  error,
  onBack,
  update,
  act,
  setAgentConnection,
  palette,
}: {
  state?: NativeServicesState;
  error?: string;
  onBack(): void;
  update(patch: AppSettingsPatch): void;
  palette: Palette;
  act(action: "request_accessibility" | "open_accessibility_settings"
    | "request_notifications" | "check_updates" | "open_update"): void;
  setAgentConnection(agent: "claude" | "auggie" | "codex", enabled: boolean): void;
}) {
  const styles = useMemo(() => createStyles(palette), [palette]);
  const [category, setCategory] = useState<SettingsCategory>("general");
  useEffect(() => {
    const keyDown = (event: KeyboardEvent) => {
      if (browserCommand(event)?.type === "back" || event.key === "Escape") {
        event.preventDefault();
        onBack();
      }
    };
    window.addEventListener("keydown", keyDown);
    return () => window.removeEventListener("keydown", keyDown);
  }, [onBack]);
  if (!state) return <View style={styles.page}><Text style={styles.muted}>{error ?? "Loading settings…"}</Text></View>;
  const settings = state.settings;
  const pillScreen = pillScreenChoices(settings.pillScreen, state.pillScreens);
  const updateText = state.update.status === "available"
    ? `Version ${state.update.availableVersion} is available on GitHub Releases`
    : state.update.status === "up_to_date" ? "Agent Visor is up to date"
      : state.update.status === "checking" ? "Checking for updates…"
        : state.update.status === "error" ? state.update.error ?? "Update check failed"
          : `Current version ${state.update.currentVersion}`;

  return (
    <View style={styles.page}>
      <View style={styles.body}>
        <View style={styles.sidebar}>
          <Pressable accessibilityLabel="Back to Sessions" accessibilityRole="button" onPress={onBack} style={styles.back}>
            <Text style={styles.backText}>← Back to app</Text>
          </Pressable>
          {categories.map((item) => (
            <Pressable
              accessibilityRole="button"
              accessibilityState={{ selected: category === item }}
              key={item}
              onPress={() => setCategory(item)}
              style={category === item ? styles.categorySelected : styles.category}
            >
              <Text style={category === item ? styles.categoryTextSelected : styles.categoryText}>
                {categoryLabels[item]}
              </Text>
            </Pressable>
          ))}
        </View>
        <ScrollView contentContainerStyle={styles.content}>
        {error ? <Text accessibilityRole="alert" style={styles.error}>{error}</Text> : null}
        {category === "general" ? <Section title="General" subtitle="How Agent Visor starts up and stays accessible" styles={styles}>
          <ToggleRow label="Launch at login" value={settings.launchAtLogin} onPress={() => update({ launchAtLogin: !settings.launchAtLogin })} styles={styles} />
          <ChoiceRow
            label="App shortcut"
            values={hotkeyTriggers}
            value={settings.hotkeyTrigger}
            labelFor={(value) => hotkeyLabels[value]}
            onChoose={(hotkeyTrigger) => update({ hotkeyTrigger })}
            styles={styles}
          />
          {settings.hotkeyTrigger === "custom"
            ? <ValueRow label="Custom shortcut" value="Migrated from Agent Visor" styles={styles} />
            : null}
          <ChoiceRow
            label="File links"
            values={editors}
            value={settings.editorPreference}
            labelFor={(value) => editorLabels[value]}
            onChoose={(editorPreference) => update({ editorPreference })}
            styles={styles}
          />
          <ActionRow
            label="Accessibility"
            detail={state.permissions.accessibility === "granted" ? "Allowed" : "Required for native focus"}
            action={state.permissions.accessibility === "granted" ? "Open Settings" : "Enable"}
            onPress={() => act(state.permissions.accessibility === "granted"
              ? "open_accessibility_settings" : "request_accessibility")}
            styles={styles}
          />
          <ActionRow
            label="Notifications"
            detail={state.permissions.notifications.replace("_", " ")}
            action={state.permissions.notifications === "authorized" ? "Allowed" : "Enable"}
            onPress={() => act("request_notifications")}
            styles={styles}
          />
          <ActionRow
            label="Updates"
            detail={updateText}
            action={state.update.status === "available" ? "Open release page" : "Check now"}
            onPress={() => act(state.update.status === "available" ? "open_update" : "check_updates")}
            styles={styles}
          />
        </Section> : null}

        {category === "appearance" ? <Section title="Appearance" subtitle="How the app looks across content sizes" styles={styles}>
          <ChoiceRow
            label="Theme"
            values={["system", "dark", "light"]}
            value={settings.appearance}
            labelFor={(value) => themeLabels[value]}
            onChoose={(appearance) => update({ appearance })}
            styles={styles}
          />
          <StepRow
            label="Content size"
            value={`${Math.round(settings.contentScale * 100)}%`}
            onDecrease={() => update({ contentScale: Math.max(0.8, Math.round((settings.contentScale - 0.1) * 10) / 10) })}
            onIncrease={() => update({ contentScale: Math.min(2.5, Math.round((settings.contentScale + 0.1) * 10) / 10) })}
            styles={styles}
          />
        </Section> : null}

        {category === "chat" ? (
          <ChatSettings settings={settings} styles={styles} update={update} />
        ) : null}

        {category === "pills" ? <Section title="Pills" subtitle="Menu-bar shortcuts for active and recent sessions" styles={styles}>
          <ToggleRow label="Show session pills" value={settings.pillsEnabled} onPress={() => update({ pillsEnabled: !settings.pillsEnabled })} styles={styles} />
          <ChoiceRow
            label="Pill screen"
            values={pillScreen.values}
            value={pillScreen.selected}
            labelFor={pillScreen.labelFor}
            disabledFor={(value) => value === "unavailable"}
            onChoose={(value) => {
              const next = pillScreen.preferenceFor(value);
              if (next) update({ pillScreen: next });
            }}
            styles={styles}
          />
          <ChoiceRow
            label="Full-screen visibility"
            values={fullScreenPolicies}
            value={settings.fullScreenPolicy}
            labelFor={(value) => fullScreenPolicyLabels[value]}
            onChoose={(fullScreenPolicy) => update({ fullScreenPolicy })}
            styles={styles}
          />
          <ToggleRow label="Show Codex usage" value={settings.codexUsageGlanceEnabled} onPress={() => update({ codexUsageGlanceEnabled: !settings.codexUsageGlanceEnabled })} styles={styles} />
          <ValueRow label="Claude usage" value="Waiting for a supported credential route" styles={styles} />
          <ChoiceRow
            label="Session shortcuts"
            values={shortcuts}
            value={settings.sessionShortcutModifierFamily}
            labelFor={(value) => shortcutLabels[value]}
            onChoose={(sessionShortcutModifierFamily) => update({ sessionShortcutModifierFamily })}
            styles={styles}
          />
        </Section> : null}

        {category === "notifications" ? <Section title="Notifications" subtitle="Audio cues for session state changes" styles={styles}>
          <ChoiceRow
            label="Sound"
            values={sounds}
            value={settings.notificationSound}
            onChoose={(notificationSound) => update({ notificationSound })}
            styles={styles}
          />
        </Section> : null}

        {category === "agents" ? <Section title="Agents" subtitle="Connect agents for exact live status and approvals" styles={styles}>
          {state.agents.map((agent) => agent.control === "toggle"
            ? agent.available
              ? <ActionRow
                  action={agent.installed ? "Disconnect" : "Connect"}
                  detail={agent.installed ? "Connected" : "Not connected"}
                  key={agent.id}
                  label={agent.name}
                  onPress={() => setAgentConnection(agent.id as "claude" | "auggie" | "codex", !agent.installed)}
                  styles={styles}
                />
              : <ValueRow key={agent.id} label={agent.name} value="Not detected" styles={styles} />
            : <ValueRow
                key={agent.id}
                label={agent.name}
                value={!agent.available ? "Not detected" : agent.installed ? "Connected automatically" : "Observed automatically"}
                styles={styles}
              />)}
          <StepRow
            label="Observed session window"
            value={`${settings.observedWindowHours}h`}
            onDecrease={() => update({ observedWindowHours: Math.max(1, settings.observedWindowHours - 1) })}
            onIncrease={() => update({ observedWindowHours: Math.min(168, settings.observedWindowHours + 1) })}
            styles={styles}
          />
          <Text style={styles.detail}>Codex conversations remain visible until archived.</Text>
          <CodexHomes settings={settings} statuses={state.codexHomes} update={update} styles={styles} />
        </Section> : null}
        </ScrollView>
      </View>
    </View>
  );
}

function CodexHomes({ settings, statuses, update, styles }: {
  settings: AppSettings;
  statuses: NativeServicesState["codexHomes"];
  update(patch: AppSettingsPatch): void;
  styles: ReturnType<typeof createStyles>;
}) {
  const [homePath, setHomePath] = useState("");
  const [label, setLabel] = useState("");
  const [renaming, setRenaming] = useState<string | null>(null);
  const [newLabel, setNewLabel] = useState("");
  const saveLabel = (homePath: string) => {
    const next = newLabel.trim();
    if (next) update({ codexHomes: settings.codexHomes.map((item) =>
      item.path === homePath ? { ...item, label: next } : item) });
    setRenaming(null);
  };
  return <View>
    <Text style={styles.homeHeading}>Codex Desktop homes</Text>
    <Text style={styles.homeNote}>The default ~/.codex home is always included. Other running Codex profiles are added automatically. Their chats are read-only in Agent Visor.</Text>
    <ValueRow label="Default Codex home" value={statuses[0]?.status ?? "Checking"} styles={styles} />
    {settings.codexHomes.map((home) => <View key={home.path} style={styles.homeRow}>
      {renaming === home.path ? <TextInput
        accessibilityLabel={`Label for ${home.path}`}
        maxLength={64} onChangeText={setNewLabel}
        onSubmitEditing={() => saveLabel(home.path)}
        style={styles.homeInput} value={newLabel}
      /> : <View style={styles.grow}>
        <Text style={styles.label}>{home.label}</Text>
        <Text style={styles.detail}>{home.path} · {statuses.find((item) => item.path === home.path)?.status ?? "Checking"}</Text>
      </View>}
      <Pressable accessibilityLabel={`${renaming === home.path ? "Save label for" : "Rename"} ${home.label}`}
        accessibilityRole="button" onPress={() => {
          if (renaming === home.path) saveLabel(home.path);
          else { setRenaming(home.path); setNewLabel(home.label); }
        }} style={styles.smallButton}>
        <Text style={styles.buttonText}>{renaming === home.path ? "Save" : "Rename"}</Text>
      </Pressable>
      <Pressable accessibilityLabel={`Remove ${home.label}`} accessibilityRole="button"
        onPress={() => update({
          codexHomes: settings.codexHomes.filter((item) => item.path !== home.path),
          ignoredCodexHomes: [...settings.ignoredCodexHomes, home.path].slice(-32),
        })}
        style={styles.smallButton}><Text style={styles.buttonText}>Remove</Text></Pressable>
    </View>)}
    <View style={styles.homeRow}>
      <TextInput accessibilityLabel="Codex home path" autoCapitalize="none" autoCorrect={false}
        maxLength={1_024}
        onChangeText={setHomePath} placeholder="/path/to/CODEX_HOME" placeholderTextColor={styles.detail.color}
        style={styles.homeInput} value={homePath} />
      <TextInput accessibilityLabel="Codex home label" maxLength={64} onChangeText={setLabel}
        placeholder="Label" placeholderTextColor={styles.detail.color}
        style={styles.homeInput} value={label} />
      <Pressable accessibilityLabel="Add Codex home" accessibilityRole="button" style={styles.smallButton}
        onPress={() => {
          const selectedPath = homePath.trim();
          if (!selectedPath || settings.codexHomes.some((home) => home.path === selectedPath)) return;
          const selectedLabel = (label.trim()
            || `Codex · ${selectedPath.split("/").filter(Boolean).at(-1) ?? "Other"}`).slice(0, 64);
          update({
            codexHomes: [...settings.codexHomes, { path: selectedPath, label: selectedLabel }],
            ignoredCodexHomes: settings.ignoredCodexHomes.filter((path) => path !== selectedPath),
          });
          setHomePath(""); setLabel("");
        }}><Text style={styles.buttonText}>Add</Text></Pressable>
    </View>
  </View>;
}

function ChatSettings({
  settings,
  styles,
  update,
}: {
  settings: AppSettings;
  styles: ReturnType<typeof createStyles>;
  update(patch: AppSettingsPatch): void;
}) {
  return <View>
    {chatVisibilitySections.map((section, index) => (
      <Section key={section.title} title={section.title} subtitle={section.subtitle} styles={styles}>
        {index === 0 ? (
          <ActionRow
            action="Reset"
            detail="Show all content and group supported provider turns"
            label="Visibility defaults"
            onPress={() => update({ chatVisibility: { ...defaultChatVisibility } })}
            styles={styles}
          />
        ) : null}
        {section.items.map(([label, key]) => (
          <ToggleRow
            key={key}
            label={label}
            value={settings.chatVisibility[key]}
            onPress={() => update({
              chatVisibility: {
                ...settings.chatVisibility,
                [key]: !settings.chatVisibility[key],
              },
            })}
            styles={styles}
          />
        ))}
      </Section>
    ))}
  </View>;
}

function Section({ title, subtitle, children, styles }: { title: string; subtitle: string; children: React.ReactNode; styles: ReturnType<typeof createStyles> }) {
  return <View style={styles.section}><Text accessibilityRole="header" style={styles.sectionTitle}>{title}</Text><Text style={styles.sectionSubtitle}>{subtitle}</Text><View style={styles.card}>{children}</View></View>;
}

function ToggleRow({ label, value, onPress, styles }: { label: string; value: boolean; onPress(): void; styles: ReturnType<typeof createStyles> }) {
  return <Pressable aria-checked={value} accessibilityLabel={`${label}, ${value ? "On" : "Off"}`} accessibilityRole="switch" accessibilityState={{ checked: value }} onPress={onPress} style={styles.row}><Text style={styles.label}>{label}</Text><Text style={value ? styles.on : styles.off}>{value ? "On" : "Off"}</Text></Pressable>;
}

function ValueRow({ label, value, styles }: { label: string; value: string; styles: ReturnType<typeof createStyles> }) {
  return <View style={styles.row}><Text style={styles.label}>{label}</Text><Text style={styles.value}>{value}</Text></View>;
}

function ActionRow({ label, detail, action, onPress, styles }: { label: string; detail: string; action: string; onPress(): void; styles: ReturnType<typeof createStyles> }) {
  return <View style={styles.row}><View style={styles.grow}><Text style={styles.label}>{label}</Text><Text style={styles.detail}>{detail}</Text></View><Pressable accessibilityLabel={`${action} for ${label}`} accessibilityRole="button" onPress={onPress} style={styles.button}><Text style={styles.buttonText}>{action}</Text></Pressable></View>;
}

function ChoiceRow<T extends string>({ label, values, value, labelFor = (item) => item, disabledFor = () => false, onChoose, styles }: { label: string; values: readonly T[]; value: string; labelFor?(value: T): string; disabledFor?(value: T): boolean; onChoose(value: T): void; styles: ReturnType<typeof createStyles> }) {
  return <View style={styles.choiceRow}>
    <Text style={styles.label}>{label}</Text>
    <View style={styles.choices}>{values.map((item) => {
      const disabled = disabledFor(item);
      return <Pressable
        key={item}
        accessibilityRole="button"
        accessibilityState={{ selected: item === value, disabled }}
        disabled={disabled}
        onPress={() => onChoose(item)}
        style={[item === value ? styles.choiceSelected : styles.choice, disabled && { opacity: 0.5 }]}
      ><Text style={styles.buttonText}>{labelFor(item)}</Text></Pressable>;
    })}</View>
  </View>;
}

function StepRow({ label, value, onDecrease, onIncrease, styles }: { label: string; value: string; onDecrease(): void; onIncrease(): void; styles: ReturnType<typeof createStyles> }) {
  return <View style={styles.row}><Text style={styles.label}>{label}</Text><View style={styles.step}><Pressable accessibilityLabel={`Decrease ${label}`} onPress={onDecrease} style={styles.smallButton}><Text style={styles.buttonText}>−</Text></Pressable><Text style={styles.value}>{value}</Text><Pressable accessibilityLabel={`Increase ${label}`} onPress={onIncrease} style={styles.smallButton}><Text style={styles.buttonText}>+</Text></Pressable></View></View>;
}

function createStyles(palette: Palette) {
  return {
    page: { backgroundColor: palette.background, flex: 1 },
    back: { marginBottom: 4, paddingHorizontal: 4, paddingVertical: 10 }, backText: { color: palette.accent, fontSize: 13, fontWeight: "600" as const },
    body: { flex: 1, flexDirection: "row" as const },
    sidebar: { borderRightColor: palette.border, borderRightWidth: 1, gap: 2, padding: 8, paddingTop: 32, width: 220 },
    category: { borderRadius: 8, paddingHorizontal: 12, paddingVertical: 10 },
    categorySelected: { backgroundColor: palette.accentWash, borderRadius: 8, paddingHorizontal: 12, paddingVertical: 10 },
    categoryText: { color: palette.muted, fontSize: 13, fontWeight: "600" as const },
    categoryTextSelected: { color: palette.accent, fontSize: 13, fontWeight: "700" as const },
    content: { alignSelf: "center" as const, maxWidth: 720, paddingHorizontal: 32, paddingVertical: 24, width: "100%" as const },
    section: { gap: 8, marginBottom: 24 }, sectionTitle: { color: palette.foreground, fontSize: 22, fontWeight: "700" as const }, sectionSubtitle: { color: palette.muted, fontSize: 12, marginBottom: 8 },
    card: { backgroundColor: palette.settingsCard, borderColor: palette.border, borderRadius: 12, borderWidth: 1, overflow: "hidden" as const },
    row: { alignItems: "center" as const, borderBottomColor: palette.border, borderBottomWidth: 1, flexDirection: "row" as const, gap: 16, justifyContent: "space-between" as const, minHeight: 58, paddingHorizontal: 16, paddingVertical: 10 },
    choiceRow: { borderBottomColor: palette.border, borderBottomWidth: 1, gap: 10, padding: 16 },
    label: { color: palette.foreground, fontSize: 14, fontWeight: "600" as const }, value: { color: palette.muted, fontSize: 13 }, detail: { color: palette.tertiary, fontSize: 11, marginTop: 3 }, grow: { flex: 1 },
    on: { color: palette.ready, fontWeight: "700" as const }, off: { color: palette.tertiary, fontWeight: "700" as const },
    button: { backgroundColor: palette.card, borderRadius: 7, paddingHorizontal: 12, paddingVertical: 7 }, smallButton: { backgroundColor: palette.card, borderRadius: 6, paddingHorizontal: 10, paddingVertical: 5 }, buttonText: { color: palette.foreground, fontSize: 12, fontWeight: "600" as const },
    choices: { flexDirection: "row" as const, flexWrap: "wrap" as const, gap: 7 }, choice: { backgroundColor: palette.card, borderRadius: 7, paddingHorizontal: 10, paddingVertical: 7 }, choiceSelected: { backgroundColor: palette.accentWash, borderColor: palette.accent, borderRadius: 7, borderWidth: 1, paddingHorizontal: 10, paddingVertical: 7 },
    step: { alignItems: "center" as const, flexDirection: "row" as const, gap: 10 }, muted: { color: palette.muted, margin: 30 }, error: { color: palette.error, marginBottom: 16 },
    homeHeading: { color: palette.foreground, fontSize: 14, fontWeight: "700" as const, marginHorizontal: 16, marginTop: 18 },
    homeNote: { color: palette.tertiary, fontSize: 11, marginHorizontal: 16, marginVertical: 8 },
    homeRow: { alignItems: "center" as const, borderTopColor: palette.border, borderTopWidth: 1, flexDirection: "row" as const, gap: 8, padding: 12 },
    homeInput: { borderColor: palette.border, borderRadius: 6, borderWidth: 1, color: palette.foreground, flex: 1, fontSize: 12, minWidth: 100, padding: 7 },
  };
}
