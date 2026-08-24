import { useEffect, useMemo, useRef, useState } from "react";
import {
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  useColorScheme,
  useWindowDimensions,
  View,
  type ViewStyle,
} from "react-native";
import type { AppSettings, SessionSummary } from "@agent-visor/protocol";
import {
  browserCommand,
  changeContentScale,
  sessionShortcutEducation,
} from "./browser-shortcuts";
import { Chat } from "./Chat";
import { Settings } from "./Settings";
import {
  moveSessionCursor,
  reconcileSessionCursor,
  relativeSessionAge,
  sessionAction,
  selectSessions,
} from "./session-groups";
import { palettes, type Palette } from "./theme";
import { useNativeServices } from "./use-native-services";
import { focusSession, useSessionSnapshot } from "./use-session-snapshot";

const agentImages: Record<string, number> = {
  auggie: require("../assets/agents/auggie.png"),
  claude: require("../assets/agents/claude.png"),
  codex: require("../assets/agents/codex.png"),
  cursor: require("../assets/agents/cursor.png"),
  pi: require("../assets/agents/pi.png"),
};

type BrowserStyles = ReturnType<typeof createStyles>;
const hiddenBrowserStyle = {
  bottom: 0,
  left: 0,
  pointerEvents: "none",
  position: "absolute",
  right: 0,
  top: 0,
  visibility: "hidden",
} as unknown as ViewStyle;

export function App() {
  const connection = useSessionSnapshot();
  const nativeServices = useNativeServices();
  const [chatSessionId, setChatSessionId] = useState<string>();
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [contentScale, setContentScale] = useState(1);
  const sessions = connection.status === "connected" ? connection.snapshot.sessions : [];
  const chatSession = sessions.find(({ id }) => id === chatSessionId);
  const systemScheme = useColorScheme();
  const appearance = nativeServices.state?.settings.appearance ?? "system";
  const palette = palettes[
    appearance === "system" ? (systemScheme === "dark" ? "dark" : "light") : appearance
  ];
  const browserHidden = Boolean(chatSessionId || settingsOpen);
  const adjustContentScale = (delta: -0.1 | 0 | 0.1) => {
    setContentScale((scale) => {
      const next = changeContentScale(scale, delta);
      nativeServices.update({ contentScale: next });
      return next;
    });
  };

  useEffect(() => {
    if (nativeServices.state) setContentScale(nativeServices.state.settings.contentScale);
  }, [nativeServices.state?.settings.contentScale]);

  useEffect(() => {
    if (connection.status === "connected" && chatSessionId && !chatSession) {
      setChatSessionId(undefined);
    }
  }, [chatSession, chatSessionId, connection.status]);

  useEffect(() => window.agentVisor?.onNavigate((action) => {
    if (action.page === "sessions") {
      setChatSessionId(undefined);
      setSettingsOpen(false);
    } else if (action.page === "settings") {
      setChatSessionId(undefined);
      setSettingsOpen(true);
      if (action.checkUpdates) nativeServices.act("check_updates");
    } else if (action.page === "chat") {
      setSettingsOpen(false);
      setChatSessionId(action.sessionId);
    } else {
      adjustContentScale(action.delta);
    }
  }), [nativeServices.act, nativeServices.update]);

  if (connection.status === "failed") return <CenteredMessage text="Unable to connect to Agent Visor" palette={palette} />;
  if (connection.status === "connecting") return <CenteredMessage text="Connecting to Agent Visor…" palette={palette} />;

  return (
    <View style={{ backgroundColor: palette.background, flex: 1 }}>
      <View
        aria-hidden={browserHidden}
        accessibilityElementsHidden={browserHidden}
        importantForAccessibility={browserHidden ? "no-hide-descendants" : "auto"}
        style={browserHidden ? hiddenBrowserStyle : styles.visible}
      >
        <SessionBrowser
          active={!browserHidden}
          contentScale={contentScale}
          onContentScaleChange={adjustContentScale}
          onOpenChat={({ id }) => setChatSessionId(id)}
          onOpenSettings={() => setSettingsOpen(true)}
          palette={palette}
          sessions={sessions}
          shortcutModifierFamily={nativeServices.state?.settings.sessionShortcutModifierFamily ?? "off"}
        />
      </View>
      {chatSession ? (
        <Chat
          contentScale={contentScale}
          onBack={() => setChatSessionId(undefined)}
          onContentScaleChange={adjustContentScale}
          onOpenOwner={() => openOwner(chatSession)}
          palette={palette}
          session={chatSession}
        />
      ) : null}
      {settingsOpen ? (
        <Settings
          act={nativeServices.act}
          error={nativeServices.error}
          onBack={() => setSettingsOpen(false)}
          palette={palette}
          state={nativeServices.state}
          update={nativeServices.update}
        />
      ) : null}
    </View>
  );
}

function SessionBrowser({
  active,
  contentScale,
  onContentScaleChange,
  onOpenChat,
  onOpenSettings,
  palette,
  sessions,
  shortcutModifierFamily,
}: {
  active: boolean;
  contentScale: number;
  onContentScaleChange(delta: -0.1 | 0 | 0.1): void;
  onOpenChat(session: SessionSummary): void;
  onOpenSettings(): void;
  palette: Palette;
  sessions: SessionSummary[];
  shortcutModifierFamily: AppSettings["sessionShortcutModifierFamily"];
}) {
  const [query, setQuery] = useState("");
  const [searchFocused, setSearchFocused] = useState(false);
  const [cursorId, setCursorId] = useState<string>();
  const [revealRequest, setRevealRequest] = useState<{ id: string; serial: number }>();
  const [commandHeld, setCommandHeld] = useState(false);
  const [now, setNow] = useState(() => new Date());
  const searchRef = useRef<TextInput>(null);
  const previous = useRef({ query, ids: [] as string[] });
  const { width } = useWindowDimensions();
  const compact = width < 1_000 || contentScale >= 1.4;
  const browserStyles = useMemo(
    () => createStyles(palette, contentScale, compact),
    [compact, contentScale, palette],
  );
  const selection = useMemo(() => selectSessions(sessions, query), [query, sessions]);
  const visibleIds = selection.orderedSessions.map(({ id }) => id);
  const visibleKey = visibleIds.join("\0");
  const cursorSession = selection.orderedSessions.find(({ id }) => id === cursorId);
  const primaryFooterAction = cursorSession ? sessionAction(cursorSession) : "owner";
  const alternateFooterAction = cursorSession ? sessionAction(cursorSession, true) : "chat";
  const shortcutEducation = sessionShortcutEducation(shortcutModifierFamily);

  useEffect(() => {
    const reason = previous.current.query === query ? "background" : "query";
    const decision = reconcileSessionCursor(
      cursorId,
      previous.current.ids,
      visibleIds,
      reason,
    );
    setCursorId(decision.cursorId);
    if (decision.revealId) {
      setRevealRequest((current) => ({ id: decision.revealId!, serial: (current?.serial ?? 0) + 1 }));
    }
    previous.current = { query, ids: visibleIds };
  }, [query, visibleKey]);

  useEffect(() => {
    if (!revealRequest || typeof document === "undefined") return;
    document.getElementById(rowId(revealRequest.id))?.scrollIntoView({ block: "nearest" });
  }, [revealRequest]);

  useEffect(() => {
    if (active) requestAnimationFrame(() => searchRef.current?.focus());
    else setCommandHeld(false);
  }, [active]);

  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 60_000);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    if (!active || typeof window === "undefined") return;
    const keyDown = (event: KeyboardEvent) => {
      setCommandHeld(event.metaKey);
      const command = browserCommand(event);
      if (!command || (command.type === "clear_search" && !query)) return;
      event.preventDefault();
      if (command.type === "focus_search") searchRef.current?.focus();
      if (command.type === "open_settings") onOpenSettings();
      if (command.type === "clear_search") setQuery("");
      if (command.type === "scale") onContentScaleChange(command.delta);
      if (command.type === "move") {
        const decision = moveSessionCursor(cursorId, visibleIds, command.offset);
        setCursorId(decision.cursorId);
        if (decision.revealId) {
          setRevealRequest((current) => ({ id: decision.revealId!, serial: (current?.serial ?? 0) + 1 }));
        }
      }
      if (command.type === "activate") {
        const session = selection.orderedSessions.find(({ id }) => id === cursorId);
        if (session) activateSession(session, command.alternate, onOpenChat);
      }
      if (command.type === "hotkey") {
        const session = selection.orderedSessions[command.position];
        if (session) activateSession(session, false, onOpenChat);
      }
    };
    const keyUp = (event: KeyboardEvent) => setCommandHeld(event.metaKey);
    const blur = () => setCommandHeld(false);
    window.addEventListener("blur", blur);
    window.addEventListener("keydown", keyDown);
    window.addEventListener("keyup", keyUp);
    return () => {
      window.removeEventListener("blur", blur);
      window.removeEventListener("keydown", keyDown);
      window.removeEventListener("keyup", keyUp);
    };
  }, [active, cursorId, onContentScaleChange, onOpenChat, onOpenSettings, query, visibleKey]);

  return (
    <View style={browserStyles.app}>
      <View style={browserStyles.header}>
        <View style={browserStyles.railRow}>
          <View style={[browserStyles.searchShell, searchFocused && browserStyles.searchFocused]}>
            <Text style={browserStyles.searchIcon}>⌕</Text>
            <TextInput
              accessibilityLabel="Search sessions"
              onBlur={() => setSearchFocused(false)}
              onChangeText={setQuery}
              onFocus={() => setSearchFocused(true)}
              placeholder="Search all sessions"
              placeholderTextColor={palette.tertiary}
              ref={searchRef}
              style={browserStyles.search}
              value={query}
            />
            <View style={browserStyles.searchTrailing}>
              {query ? (
                <Pressable accessibilityLabel="Clear search" onPress={() => setQuery("")}>
                  <Text style={browserStyles.searchHint}>×</Text>
                </Pressable>
              ) : <Text style={browserStyles.searchHint}>⌘F</Text>}
            </View>
          </View>
          {query ? (
            <Text accessibilityLabel={`${visibleIds.length} search results`} style={browserStyles.resultCount}>
              {visibleIds.length} {visibleIds.length === 1 ? "result" : "results"}
            </Text>
          ) : null}
          <Pressable accessibilityLabel="Settings" accessibilityRole="button" onPress={onOpenSettings} style={browserStyles.settings}>
            <Text style={browserStyles.settingsText}>⚙</Text>
          </Pressable>
        </View>
      </View>

      <ScrollView contentContainerStyle={browserStyles.list} style={browserStyles.scroller}>
        <View style={browserStyles.rail}>
          {selection.groups.map((group) => (
            <View key={group.id}>
              <View style={browserStyles.sectionHeader}>
                <Text style={browserStyles.sectionTitle}>{group.title}</Text>
                <Text style={browserStyles.count}>{group.sessions.length}</Text>
              </View>
              {group.sessions.map((session) => (
                <SessionRow
                  active={active}
                  commandHeld={commandHeld}
                  compact={compact}
                  cursor={session.id === cursorId}
                  hotkeyPosition={visibleIds.indexOf(session.id)}
                  key={session.id}
                  now={now}
                  onActivate={(alternate) => activateSession(session, alternate, onOpenChat)}
                  onOpenChat={() => onOpenChat(session)}
                  palette={palette}
                  session={session}
                  styles={browserStyles}
                />
              ))}
            </View>
          ))}
          {!visibleIds.length ? <EmptyState query={query} styles={browserStyles} /> : null}
        </View>
      </ScrollView>

      <View style={browserStyles.footer}>
        <View style={[browserStyles.railRow, browserStyles.footerRail]}>
          <View style={browserStyles.footerGroup}>
            <FooterHint keys="↑↓" label="Navigate" styles={browserStyles} />
            {primaryFooterAction ? (
              <FooterHint keys="↩" label={footerLabel(primaryFooterAction)} styles={browserStyles} />
            ) : null}
            {alternateFooterAction && alternateFooterAction !== primaryFooterAction ? (
              <FooterHint keys="⇧↩" label={footerLabel(alternateFooterAction)} styles={browserStyles} />
            ) : null}
          </View>
          <View style={browserStyles.footerSpacer} />
          <View style={browserStyles.footerGroup}>
            {shortcutEducation.disabledMessage ? (
              <Text style={browserStyles.footerText}>{shortcutEducation.disabledMessage}</Text>
            ) : shortcutEducation.hints.map((hint) => (
              <FooterHint key={hint.keys} keys={hint.keys} label={hint.label} styles={browserStyles} />
            ))}
          </View>
        </View>
      </View>
    </View>
  );
}

function SessionRow({
  active,
  commandHeld,
  compact,
  cursor,
  hotkeyPosition,
  now,
  onActivate,
  onOpenChat,
  palette,
  session,
  styles: rowStyles,
}: {
  active: boolean;
  commandHeld: boolean;
  compact: boolean;
  cursor: boolean;
  hotkeyPosition: number;
  now: Date;
  onActivate(alternate: boolean): void;
  onOpenChat(): void;
  palette: Palette;
  session: SessionSummary;
  styles: BrowserStyles;
}) {
  const [primaryHovered, setPrimaryHovered] = useState(false);
  const [chatHovered, setChatHovered] = useState(false);
  useEffect(() => {
    if (!active) {
      setPrimaryHovered(false);
      setChatHovered(false);
    }
  }, [active]);
  const primary = sessionAction(session);
  const hasSeparateChat = session.canOpenOwner && session.canEnterChat;
  const actionLabel = primary === "owner" ? `Open in ${session.owner}` : "Open Chat";
  const sectionTitle = {
    needs_you: "Needs you", ready: "Ready to continue", working: "In progress", history: "History",
  }[session.section];
  const logo = agentImage(session.source);

  return (
    <View nativeID={rowId(session.id)} style={rowStyles.row}>
      <Pressable
        accessibilityLabel={`${session.title}, ${sectionTitle}, ${session.source}, ${session.project}, ${actionLabel}`}
        accessibilityRole="button"
        accessibilityState={{ selected: cursor }}
        disabled={!primary}
        onHoverIn={() => setPrimaryHovered(true)}
        onHoverOut={() => setPrimaryHovered(false)}
        onPress={() => onActivate(false)}
        style={({ pressed }) => [
          rowStyles.primaryAction,
          cursor && rowStyles.primarySelected,
          primaryHovered && !cursor && rowStyles.primaryHovered,
          pressed && rowStyles.pressed,
        ]}
      >
        <View style={[rowStyles.statusSlot, { backgroundColor: sectionColor(session.section, palette) }]} />
        {logo ? (
          <Image accessibilityIgnoresInvertColors accessibilityLabel="" source={logo} style={rowStyles.logo} />
        ) : (
          <View style={rowStyles.logoFallback}><Text style={rowStyles.logoLetter}>{session.source[0]}</Text></View>
        )}
        <View style={rowStyles.identity}>
          <View style={rowStyles.titleLine}>
            <Text numberOfLines={1} style={rowStyles.title}>{session.title}</Text>
            <Chip label={session.source} styles={rowStyles} />
            {!compact ? <Chip label={session.project} styles={rowStyles} /> : null}
          </View>
          <Text numberOfLines={1} style={rowStyles.subtitle}>{session.subtitle || session.cwd}</Text>
        </View>
        <Text style={rowStyles.age}>{relativeSessionAge(session.updatedAt, now)}</Text>
        <View style={rowStyles.hotkeySlot}>
          {commandHeld && hotkeyPosition < 9 ? (
            <Text style={rowStyles.hotkey}>⌘{hotkeyPosition + 1}</Text>
          ) : null}
        </View>
        <View style={rowStyles.ownerColumn}>
          <Text numberOfLines={1} style={[rowStyles.actionText, primaryHovered && rowStyles.linkText]}>
            {primary === "owner" ? `↗ ${compact ? session.owner : `Open in ${session.owner}`}` : "▢ Open Chat"}
          </Text>
        </View>
      </Pressable>
      <View style={rowStyles.chatColumn}>
        {hasSeparateChat ? (
          <Pressable
            accessibilityLabel={`Open Chat for ${session.title}`}
            accessibilityRole="button"
            onHoverIn={() => setChatHovered(true)}
            onHoverOut={() => setChatHovered(false)}
            onPress={onOpenChat}
            style={({ pressed }) => [
              rowStyles.chatAction,
              chatHovered && rowStyles.chatHovered,
              pressed && rowStyles.pressed,
            ]}
          >
            <Text style={[rowStyles.chatText, chatHovered && rowStyles.linkText]}>
              ▢ {compact ? "Chat" : "Open Chat"}
            </Text>
          </Pressable>
        ) : null}
      </View>
    </View>
  );
}

function Chip({ label, styles }: { label: string; styles: BrowserStyles }) {
  return <Text numberOfLines={1} style={styles.chip}>{label}</Text>;
}

function FooterHint({ keys, label, styles }: { keys: string; label: string; styles: BrowserStyles }) {
  return <View style={styles.footerHint}><Text style={styles.footerKeys}>{keys}</Text><Text style={styles.footerText}>{label}</Text></View>;
}

function EmptyState({ query, styles }: { query: string; styles: BrowserStyles }) {
  return (
    <View style={styles.empty}>
      <Text style={styles.emptyIcon}>{query ? "⌕" : "▤"}</Text>
      <Text style={styles.emptyTitle}>{query ? "No matching sessions" : "No sessions available"}</Text>
      <Text style={styles.emptyDetail}>
        {query ? "Try a title, project, source, or path." : "Start a session in Codex, Claude Code, Cursor, or a terminal."}
      </Text>
    </View>
  );
}

function CenteredMessage({ text, palette }: { text: string; palette: Palette }) {
  return <View style={[styles.centered, { backgroundColor: palette.background }]}><Text style={{ color: palette.muted }}>{text}</Text></View>;
}

function activateSession(
  session: SessionSummary,
  alternate: boolean,
  onOpenChat: (session: SessionSummary) => void,
): void {
  const action = sessionAction(session, alternate);
  if (action === "owner") void openOwner(session);
  if (action === "chat") onOpenChat(session);
}

async function openOwner(session: SessionSummary): Promise<void> {
  if (!session.canOpenOwner) return;
  if (!await focusSession(session.id)) window.agentVisor?.openOwner(session.owner);
}

function footerLabel(action: "owner" | "chat"): string {
  return action === "owner" ? "Open source app" : "Open Chat";
}

function rowId(sessionId: string): string {
  return `session-row-${encodeURIComponent(sessionId)}`;
}

function agentImage(source: string): number | undefined {
  const key = source.toLocaleLowerCase().split(" ")[0] ?? "";
  return agentImages[key];
}

function sectionColor(section: SessionSummary["section"], palette: Palette): string {
  return {
    needs_you: palette.attention,
    ready: palette.ready,
    working: palette.working,
    history: palette.history,
  }[section];
}

function createStyles(palette: Palette, scale: number, compact: boolean) {
  const font = (size: number) => size * scale;
  return StyleSheet.create({
    app: { backgroundColor: palette.background, flex: 1 },
    header: { borderBottomColor: palette.border, borderBottomWidth: 1, paddingBottom: 12, paddingHorizontal: 28, paddingTop: 32 },
    rail: { alignSelf: "center", maxWidth: 980, width: "100%" },
    railRow: { alignItems: "center", alignSelf: "center", flexDirection: "row", gap: 10, maxWidth: 980, width: "100%" },
    searchShell: { alignItems: "center", backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, flex: 1, flexDirection: "row", minHeight: Math.max(40, 28 + font(12)), paddingHorizontal: 13 },
    searchFocused: { borderColor: palette.accent, borderWidth: 1.2 },
    searchIcon: { color: palette.tertiary, fontSize: font(13), fontWeight: "600" },
    search: { backgroundColor: "transparent", borderWidth: 0, color: palette.foreground, flex: 1, fontSize: font(14), outlineColor: "transparent", outlineStyle: "solid", outlineWidth: 0, paddingHorizontal: 10, paddingVertical: 8 },
    searchTrailing: { alignItems: "center", justifyContent: "center", width: 34 },
    searchHint: { color: palette.tertiary, fontSize: font(10), fontWeight: "600" },
    resultCount: { color: palette.tertiary, fontSize: font(11) },
    settings: { alignItems: "center", backgroundColor: palette.card, borderRadius: 8, height: 34, justifyContent: "center", width: 34 },
    settingsText: { color: palette.muted, fontSize: 14 },
    scroller: { flex: 1 },
    list: { paddingBottom: 24, paddingHorizontal: 28, paddingTop: 10 },
    sectionHeader: { alignItems: "center", flexDirection: "row", gap: 7, paddingBottom: 5, paddingHorizontal: 10, paddingTop: 11 },
    sectionTitle: { color: palette.muted, fontSize: font(12), fontWeight: "600" },
    count: { backgroundColor: palette.border, borderRadius: 10, color: palette.tertiary, fontSize: font(10), fontWeight: "600", overflow: "hidden", paddingHorizontal: 6, paddingVertical: 2 },
    row: { alignItems: "stretch", flexDirection: "row", minHeight: Math.max(58, 40 + font(18)) },
    primaryAction: { alignItems: "center", borderColor: "transparent", borderRadius: 10, borderWidth: 1, flex: 1, flexDirection: "row", gap: 13, minWidth: 0, paddingLeft: 12, paddingRight: 8 },
    primarySelected: { backgroundColor: palette.card, borderColor: palette.accent },
    primaryHovered: { backgroundColor: palette.card },
    pressed: { opacity: 0.72 },
    statusSlot: { borderRadius: 4, height: 8, width: 8 },
    logo: { borderRadius: 6, height: 28, width: 28 },
    logoFallback: { alignItems: "center", backgroundColor: palette.card, borderRadius: 6, height: 28, justifyContent: "center", width: 28 },
    logoLetter: { color: palette.muted, fontSize: 13, fontWeight: "700" },
    identity: { flex: 1, gap: 5, minWidth: compact ? 120 : 180 },
    titleLine: { alignItems: "center", flexDirection: "row", gap: 7, minWidth: 0 },
    title: { color: palette.foreground, flexShrink: 1, fontSize: font(14), fontWeight: "600" },
    subtitle: { color: palette.muted, fontSize: font(12) },
    chip: { backgroundColor: palette.card, borderRadius: 9, color: palette.muted, flexShrink: 0, fontSize: font(10), fontWeight: "600", overflow: "hidden", paddingHorizontal: 6, paddingVertical: 2 },
    age: { color: palette.tertiary, fontSize: font(11), fontWeight: "500", minWidth: 28, textAlign: "right" },
    hotkeySlot: { alignItems: "center", justifyContent: "center", minHeight: 24, width: 35 },
    hotkey: { backgroundColor: palette.border, borderRadius: 10, color: palette.muted, fontSize: font(10), fontWeight: "600", overflow: "hidden", paddingHorizontal: 5, paddingVertical: 3 },
    ownerColumn: { alignItems: "flex-start", justifyContent: "center", minHeight: 32, width: 120 },
    actionText: { color: palette.muted, fontSize: font(11), fontWeight: "600" },
    linkText: { color: palette.accent },
    chatColumn: { alignItems: "flex-start", justifyContent: "center", paddingRight: 8, width: 138 },
    chatAction: { borderRadius: 8, minHeight: 32, paddingHorizontal: 6, paddingVertical: 8, width: "100%" },
    chatHovered: { backgroundColor: palette.accentWash },
    chatText: { color: palette.tertiary, fontSize: font(11), fontWeight: "600" },
    empty: { alignItems: "center", justifyContent: "center", minHeight: 330, padding: 24 },
    emptyIcon: { color: palette.tertiary, fontSize: 30 },
    emptyTitle: { color: palette.foreground, fontSize: font(16), fontWeight: "600", marginTop: 12 },
    emptyDetail: { color: palette.muted, fontSize: font(12), marginTop: 8, textAlign: "center" },
    footer: { borderTopColor: palette.border, borderTopWidth: 1, minHeight: 42, paddingHorizontal: 28, paddingVertical: 9 },
    footerRail: { alignItems: scale > 1.6 ? "flex-start" : "center", flexDirection: scale > 1.6 ? "column" : "row" },
    footerGroup: { alignItems: "center", flexDirection: "row", flexWrap: scale > 1.6 ? "wrap" : "nowrap", gap: 16 },
    footerSpacer: { display: scale > 1.6 ? "none" : "flex", flex: 1, minWidth: 8 },
    footerHint: { alignItems: "center", flexDirection: "row", gap: 5 },
    footerKeys: { color: palette.muted, fontSize: font(10), fontWeight: "600" },
    footerText: { color: palette.tertiary, fontSize: font(10) },
  });
}

const styles = StyleSheet.create({
  visible: { flex: 1 },
  centered: { alignItems: "center", flex: 1, justifyContent: "center" },
});
