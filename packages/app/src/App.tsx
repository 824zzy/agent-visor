import { useEffect, useMemo, useRef, useState } from "react";
import {
  Image,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  useColorScheme,
  useWindowDimensions,
  View,
  type ViewStyle,
} from "react-native";
import {
  defaultChatVisibility,
  sessionLifecyclePresentation,
  type AppSettings,
  type HistoryRepairSelection,
  type SessionLifecycleTone,
  type SessionSummary,
} from "@agent-visor/protocol";
import {
  browserCommand,
  changeContentScale,
  sessionShortcutEducation,
} from "./browser-shortcuts";
import { Chat } from "./Chat";
import { chatSessionFor, reduceChatSelection, type ChatSelection } from "./chat-selection";
import { CONTENT_RAIL_INSET, contentRailStyle } from "./content-rail";
import { Settings } from "./Settings";
import { SessionViewport } from "./SessionViewport";
import {
  moveSessionCursor,
  reconcileSessionCursor,
  relativeSessionAge,
  sessionAction,
  sessionPresentation,
  selectSessions,
} from "./session-groups";
import { palettes, type Palette } from "./theme";
import { useNativeServices } from "./use-native-services";
import { useSessionHistory, type SessionHistoryState } from "./use-session-history";
import {
  focusSession,
  mergeSessionHistory,
  resumeSession as requestResumeSession,
  useSessionSnapshot,
  type ResumeActionState,
} from "./use-session-snapshot";

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
const titleBarDragStyle = {
  height: 32,
  left: 0,
  position: "absolute",
  right: 0,
  top: 0,
  WebkitAppRegion: "drag",
  zIndex: 1,
} as unknown as ViewStyle;

export function App() {
  const connection = useSessionSnapshot();
  const nativeServices = useNativeServices();
  const [chatSelection, setChatSelection] = useState<ChatSelection>({});
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [contentScale, setContentScale] = useState(1);
  const [query, setQuery] = useState("");
  const liveSessions = connection.status === "connected" ? connection.snapshot.sessions : [];
  const history = useSessionHistory(query, liveSessions.map(({ id }) => id));
  const sessions = useMemo(
    () => mergeSessionHistory(liveSessions, history.page),
    [history.page, liveSessions],
  );
  const chatSession = chatSessionFor(chatSelection, sessions);
  const systemScheme = useColorScheme();
  const appearance = nativeServices.state?.settings.appearance ?? "system";
  const palette = palettes[
    appearance === "system" ? (systemScheme === "dark" ? "dark" : "light") : appearance
  ];
  const browserHidden = Boolean(chatSelection.sessionId || settingsOpen);
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
    if (connection.status !== "connected" || !chatSelection.sessionId) return;
    setChatSelection((selection) => reduceChatSelection(selection, { type: "refresh", sessions }));
  }, [chatSelection.sessionId, chatSelection.lastKnownSession, connection.status, sessions]);

  useEffect(() => window.agentVisor?.onNavigate((action) => {
    if (action.page === "sessions") {
      setChatSelection((selection) => reduceChatSelection(selection, { type: "back" }));
      setSettingsOpen(false);
    } else if (action.page === "settings") {
      setChatSelection((selection) => reduceChatSelection(selection, { type: "back" }));
      setSettingsOpen(true);
      if (action.checkUpdates) nativeServices.act("check_updates");
    } else if (action.page === "chat") {
      setSettingsOpen(false);
      setChatSelection((selection) => reduceChatSelection(selection, {
        type: "navigate",
        sessionId: action.sessionId,
        sessions,
      }));
    } else {
      adjustContentScale(action.delta);
    }
  }), [nativeServices.act, nativeServices.update, sessions]);

  if (connection.status === "failed") return <CenteredMessage text="Unable to connect to Agent Visor" palette={palette} />;
  if (connection.status === "connecting") return <CenteredMessage text="Connecting to Agent Visor…" palette={palette} />;

  return (
    <View style={{ backgroundColor: palette.background, flex: 1 }}>
      <View aria-hidden importantForAccessibility="no-hide-descendants" style={titleBarDragStyle} />
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
          onOpenChat={(session) => setChatSelection((selection) => reduceChatSelection(selection, { type: "open", session }))}
          onRemoveHistory={history.remove}
          onRepair={history.repair}
          onResume={async (session) => {
            const result = await requestResumeSession(session.id);
            if (!result.ok && result.error) window.alert(result.error);
            return result;
          }}
          onOpenSettings={() => setSettingsOpen(true)}
          onLoadMoreHistory={history.loadMore}
          onQueryChange={setQuery}
          palette={palette}
          historyState={history}
          query={query}
          sessions={sessions}
          shortcutModifierFamily={nativeServices.state?.settings.sessionShortcutModifierFamily ?? "off"}
        />
      </View>
      {chatSession ? (
        <Chat
          contentScale={contentScale}
          onBack={() => setChatSelection((selection) => reduceChatSelection(selection, { type: "back" }))}
          onContentScaleChange={adjustContentScale}
          onOpenOwner={() => openOwner(chatSession)}
          palette={palette}
          session={chatSession}
          visibility={nativeServices.state?.settings.chatVisibility ?? defaultChatVisibility}
        />
      ) : null}
      {settingsOpen ? (
        <Settings
          act={nativeServices.act}
          error={nativeServices.error}
          onBack={() => setSettingsOpen(false)}
          palette={palette}
          state={nativeServices.state}
          setAgentConnection={nativeServices.setAgentConnection}
          update={nativeServices.update}
        />
      ) : null}
    </View>
  );
}

function SessionBrowser({
  active,
  contentScale,
  historyState,
  onContentScaleChange,
  onLoadMoreHistory,
  onOpenChat,
  onRemoveHistory,
  onRepair,
  onResume,
  onOpenSettings,
  onQueryChange,
  palette,
  query,
  sessions,
  shortcutModifierFamily,
}: {
  active: boolean;
  contentScale: number;
  historyState: SessionHistoryState;
  onContentScaleChange(delta: -0.1 | 0 | 0.1): void;
  onLoadMoreHistory(): void;
  onOpenChat(session: SessionSummary): void;
  onRemoveHistory(sessionId: string): void;
  onRepair(sessionId: string, selection: HistoryRepairSelection | null): void;
  onResume(session: SessionSummary): Promise<{ ok: boolean; state: ResumeActionState; error?: string }>;
  onOpenSettings(): void;
  onQueryChange(query: string): void;
  palette: Palette;
  query: string;
  sessions: SessionSummary[];
  shortcutModifierFamily: AppSettings["sessionShortcutModifierFamily"];
}) {
  const [searchFocused, setSearchFocused] = useState(false);
  const [cursorId, setCursorId] = useState<string>();
  const [revealRequest, setRevealRequest] = useState<{ id: string; serial: number }>();
  const [resumeStates, setResumeStates] = useState<Record<string, "reopening" | "uncertain">>({});
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
  const selection = useMemo(() => selectSessions(sessions, query, now), [now, query, sessions]);
  const visibleIds = selection.orderedSessions.map(({ id }) => id);
  const visibleKey = visibleIds.join("\0");
  const cursorSession = selection.orderedSessions.find(({ id }) => id === cursorId);
  const primaryFooterAction = cursorSession ? sessionAction(cursorSession) : "owner";
  const alternateFooterAction = cursorSession ? sessionAction(cursorSession, true) : "chat";
  const shortcutEducation = sessionShortcutEducation(shortcutModifierFamily);

  const beginRepair = async (session: SessionSummary): Promise<void> => {
    if (session.repairKind === "working_directory") {
      const picked = await window.agentVisor?.pickRepairPath?.("workingDirectory");
      if (!picked) {
        onRepair(session.id, null);
        return;
      }
      onRepair(session.id, { kind: "working_directory", cwd: picked });
      return;
    }
    const fields = session.repairFields ?? ["executable"];
    const selection: Extract<HistoryRepairSelection, { kind: "provider" }> = { kind: "provider" };
    for (const field of fields) {
      const picked = await window.agentVisor?.pickRepairPath?.(field);
      if (!picked) {
        onRepair(session.id, null);
        return;
      }
      if (field === "executable") selection.executableRef = picked;
      else if (field === "configRoot") selection.configRootRef = picked;
      else if (field === "settingsFile") selection.settingsFileRef = picked;
      else if (session.source === "Codex") selection.profileFileRef = picked;
      else selection.profileRef = selectedProfileName(picked);
    }
    onRepair(session.id, selection);
  };

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
    if (active) {
      setNow(new Date());
      requestAnimationFrame(() => searchRef.current?.focus());
    } else setCommandHeld(false);
  }, [active]);

  useEffect(() => {
    const refresh = () => setNow(new Date());
    const timer = setInterval(refresh, 60_000);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      clearInterval(timer);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
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
      if (command.type === "clear_search") onQueryChange("");
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
  }, [active, cursorId, onContentScaleChange, onOpenChat, onOpenSettings, onQueryChange, query, visibleKey]);

  return (
    <View nativeID="sessions-canvas" style={browserStyles.app}>
      <View style={browserStyles.header}>
        <View style={browserStyles.railRow}>
          <View style={[browserStyles.searchShell, searchFocused && browserStyles.searchFocused]}>
            <Text style={browserStyles.searchIcon}>⌕</Text>
            <TextInput
              accessibilityLabel="Search sessions"
              onBlur={() => setSearchFocused(false)}
              onChangeText={onQueryChange}
              onFocus={() => setSearchFocused(true)}
              placeholder="Search all sessions"
              placeholderTextColor={palette.tertiary}
              ref={searchRef}
              style={browserStyles.search}
              value={query}
            />
            <View style={browserStyles.searchTrailing}>
              {query ? (
                <Pressable accessibilityLabel="Clear search" onPress={() => onQueryChange("")}>
                  <Text style={browserStyles.searchHint}>×</Text>
                </Pressable>
              ) : <Text style={browserStyles.searchHint}>⌘F</Text>}
            </View>
          </View>
          {historyState.loadingMore ? <Text style={browserStyles.resultCount}>Loading…</Text> : null}
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

      <SessionViewport
        contentContainerStyle={browserStyles.list}
        style={browserStyles.scroller}
        query={query}
        orderKey={selection.groups.map(group => `${group.id}:${group.sessions.map(({ id }) => id).join("\0")}`).join("\n")}
      >
        <View style={browserStyles.rail}>
          {historyState.page?.historyWarning ? (
            <View accessibilityLabel="History storage warning" style={browserStyles.historyWarning}>
              <Text style={browserStyles.historyWarningText}>{historyState.page.historyWarning}</Text>
            </View>
          ) : null}
          {historyState.removeError ? (
            <View accessibilityLabel="History removal error" style={browserStyles.historyWarning}>
              <Text style={browserStyles.historyWarningText}>{historyState.removeError}</Text>
            </View>
          ) : null}
          {historyState.repairError ? (
            <View accessibilityLabel="History repair error" style={browserStyles.historyWarning}>
              <Text style={browserStyles.historyWarningText}>{historyState.repairError}</Text>
            </View>
          ) : null}
          {selection.groups.flatMap((group) => [
              <View key={`header:${group.id}`} style={browserStyles.sectionHeader}>
                <Text style={browserStyles.sectionTitle}>{group.title}</Text>
                <Text style={browserStyles.count}>{group.sessions.length}</Text>
              </View>,
              ...group.sessions.map((session) => (
                <SessionRow
                  active={active}
                  commandHeld={commandHeld}
                  compact={compact}
                  cursor={session.id === cursorId}
                  hotkeyPosition={visibleIds.indexOf(session.id)}
                  key={`session:${session.id}`}
                  now={now}
                  onActivate={(alternate) => activateSession(session, alternate, onOpenChat)}
                  onOpenChat={() => onOpenChat(session)}
                  resumeState={resumeStates[session.id] ?? session.resumeState}
                  onResume={session.resumeState === "eligible" || session.resumeState === "uncertain"
                    || resumeStates[session.id] !== undefined
                    ? async () => {
                      setResumeStates((current) => ({ ...current, [session.id]: "reopening" }));
                      const result = await onResume(session);
                      if (result.ok) {
                        setResumeStates((current) => {
                          const next = { ...current };
                          delete next[session.id];
                          return next;
                        });
                      } else {
                        setResumeStates((current) => ({
                          ...current,
                          [session.id]: result.state === "joined" ? "reopening" : "uncertain",
                        }));
                      }
                    }
                    : undefined}
                  onRemoveHistory={session.canRemoveHistory === true
                    ? () => onRemoveHistory(session.id)
                    : undefined}
                  onRepair={session.repairKind === "provider" || session.repairKind === "working_directory"
                    ? () => void beginRepair(session)
                    : undefined}
                  repairing={historyState.repairingSessionID === session.id}
                  removing={historyState.removingSessionID === session.id}
                  palette={palette}
                  session={session}
                  styles={browserStyles}
                />
              )),
          ])}
          {!visibleIds.length ? <EmptyState query={query} styles={browserStyles} /> : null}
          {historyState.page?.nextCursor ? (
            <Pressable
              accessibilityLabel="Load more History"
              accessibilityRole="button"
              onPress={onLoadMoreHistory}
              style={browserStyles.loadMore}
            >
              <Text style={browserStyles.loadMoreText}>Load more History</Text>
            </Pressable>
          ) : null}
        </View>
      </SessionViewport>

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
  onResume,
  resumeState: resumeStateOverride,
  onRemoveHistory,
  onRepair,
  palette,
  repairing,
  removing,
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
  onResume?: () => Promise<void>;
  resumeState?: SessionSummary["resumeState"];
  onRemoveHistory?: () => void;
  onRepair?: () => void;
  palette: Palette;
  repairing: boolean;
  removing: boolean;
  session: SessionSummary;
  styles: BrowserStyles;
}) {
  const [primaryHovered, setPrimaryHovered] = useState(false);
  const [chatHovered, setChatHovered] = useState(false);
  const [removeHovered, setRemoveHovered] = useState(false);
  useEffect(() => {
    if (!active) {
      setPrimaryHovered(false);
      setChatHovered(false);
      setRemoveHovered(false);
    }
  }, [active]);
  const primary = sessionAction(session);
  const hasSeparateChat = session.canOpenOwner && session.canEnterChat;
  const actionLabel = primary === "owner" ? `Open in ${session.owner}` : "Open Chat";
  const resumeState = resumeStateOverride === "eligible"
    || resumeStateOverride === "uncertain" || resumeStateOverride === "reopening"
    ? resumeStateOverride : undefined;
  const canResume = onResume !== undefined;
  const presentation = sessionPresentation(session, now);
  const lifecycle = sessionLifecyclePresentation(session);
  const statusLabel = lifecycle.label;
  const statusColor = lifecycleColor(lifecycle.tone, palette);
  const logo = agentImage(session.source);
  const sourceLabel = session.source === "Codex" && session.owner.startsWith("Codex ·")
    ? session.owner : session.source;

  return (
    <View nativeID={rowId(session.id)} style={rowStyles.row}>
      <Pressable
        accessibilityLabel={`${session.title}, ${statusLabel}, ${sourceLabel}, ${session.project}, ${session.managedBy ? `Managed by ${session.managedBy}, ` : ""}${actionLabel}${presentation.pillNotice ? `, ${presentation.pillNotice}` : ""}`}
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
        <View style={[rowStyles.statusSlot, { backgroundColor: statusColor }]} />
        {logo ? (
          <Image accessibilityIgnoresInvertColors accessibilityLabel="" source={logo} style={rowStyles.logo} />
        ) : (
          <View style={rowStyles.logoFallback}><Text style={rowStyles.logoLetter}>{session.source[0]}</Text></View>
        )}
        <View style={rowStyles.identity}>
          <View style={rowStyles.titleLine}>
            <Text numberOfLines={1} style={rowStyles.title}>{session.title}</Text>
            <Chip label={sourceLabel} styles={rowStyles} />
            {!compact ? <Chip label={session.project} styles={rowStyles} /> : null}
          </View>
          <Text numberOfLines={1} style={rowStyles.subtitle}>{presentation.subtitle || session.cwd}</Text>
          {presentation.pillNotice ? <Text style={rowStyles.pillNotice}>{presentation.pillNotice}</Text> : null}
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
        {canResume ? (
          <Pressable
            accessibilityLabel={resumeState === "uncertain"
              ? `Retry resume for ${session.title}`
              : resumeState === "eligible" ? `Resume ${session.title} in Ghostty` : `Reopening ${session.title} in Ghostty`}
            accessibilityRole="button"
            disabled={resumeState === "reopening"}
            onPress={() => void onResume?.()}
            style={({ pressed }) => [
              rowStyles.chatAction,
              resumeState !== "reopening" && rowStyles.chatHovered,
              pressed && rowStyles.pressed,
            ]}
          >
            <Text style={[rowStyles.chatText, rowStyles.linkText]}>
              {resumeState === "uncertain" ? "Retry resume" : resumeState === "reopening" ? "Reopening…" : "Resume in Ghostty"}
            </Text>
          </Pressable>
        ) : session.resumeState === "unavailable" && session.resumeReason ? (
          <Text
            accessibilityLabel={`Resume unavailable for ${session.title}: ${session.resumeReason}`}
            numberOfLines={2}
            style={rowStyles.chatText}
          >
            {`Resume unavailable · ${session.resumeReason}`}
          </Text>
        ) : null}
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
        {onRemoveHistory ? (
          <Pressable
            accessibilityLabel={removing
              ? `Removing ${session.title} from Agent Visor`
              : `Remove ${session.title} from Agent Visor`}
            accessibilityRole="button"
            disabled={removing}
            onHoverIn={() => setRemoveHovered(true)}
            onHoverOut={() => setRemoveHovered(false)}
            onPress={onRemoveHistory}
            style={({ pressed }) => [
              rowStyles.chatAction,
              removeHovered && rowStyles.chatHovered,
              pressed && rowStyles.pressed,
            ]}
          >
            <Text style={[rowStyles.chatText, removeHovered && rowStyles.linkText]}>
              {removing ? "Removing from Agent Visor…" : "Remove from Agent Visor"}
            </Text>
          </Pressable>
        ) : null}
        {onRepair ? (
          <Pressable
            accessibilityLabel={repairing
              ? "Repairing " + session.title
              : session.repairKind === "working_directory"
                ? "Locate folder for " + session.title
                : "Repair provider references for " + session.title}
            accessibilityRole="button"
            disabled={repairing}
            onPress={onRepair}
            style={({ pressed }) => [
              rowStyles.chatAction,
              !repairing && rowStyles.chatHovered,
              pressed && rowStyles.pressed,
            ]}
          >
            <Text style={[rowStyles.chatText, rowStyles.linkText]}>
              {repairing
                ? "Repairing…"
                : session.repairKind === "working_directory" ? "Locate folder" : "Repair provider references"}
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

function selectedProfileName(value: string): string {
  const basename = value.replaceAll("\\", "/").split("/").pop() ?? value;
  return basename.replace(/\.(?:toml|json|jsonl|yaml|yml)$/i, "");
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
  const result = await focusSession(session.id);
  if (result.ok) return;
  if (session.source === "Codex") {
    window.alert(result.error ?? "Could not open this thread in its owning Codex window.");
    return;
  }
  window.agentVisor?.openOwner(session.owner);
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

function lifecycleColor(tone: SessionLifecycleTone, palette: Palette): string {
  return {
    attention: palette.attention,
    ready: palette.ready,
    working: palette.working,
    neutral: palette.history,
  }[tone];
}

function createStyles(palette: Palette, scale: number, compact: boolean) {
  const font = (size: number) => size * scale;
  return StyleSheet.create({
    app: { backgroundColor: palette.background, flex: 1 },
    header: { borderBottomColor: palette.border, borderBottomWidth: 1, paddingBottom: 12, paddingHorizontal: CONTENT_RAIL_INSET, paddingTop: 32 },
    rail: contentRailStyle(),
    railRow: { ...contentRailStyle(), alignItems: "center", flexDirection: "row", gap: 10 },
    searchShell: { alignItems: "center", backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, flex: 1, flexDirection: "row", minHeight: Math.max(40, 28 + font(12)), paddingHorizontal: 13 },
    searchFocused: { borderColor: palette.accent, borderWidth: 1.2 },
    searchIcon: { color: palette.tertiary, fontSize: font(18), fontWeight: "600" },
    search: { backgroundColor: "transparent", borderWidth: 0, color: palette.foreground, flex: 1, fontSize: font(14), outlineColor: "transparent", outlineStyle: "solid", outlineWidth: 0, paddingHorizontal: 10, paddingVertical: 8 },
    searchTrailing: { alignItems: "center", justifyContent: "center", width: 34 },
    searchHint: { color: palette.tertiary, fontSize: font(10), fontWeight: "600" },
    resultCount: { color: palette.tertiary, fontSize: font(11) },
    historyWarning: { backgroundColor: palette.card, borderColor: palette.attention, borderRadius: 8, borderWidth: 1, marginHorizontal: 10, marginTop: 8, paddingHorizontal: 10, paddingVertical: 8 },
    historyWarningText: { color: palette.attention, fontSize: font(11) },
    settings: { alignItems: "center", backgroundColor: palette.card, borderRadius: 8, height: 34, justifyContent: "center", width: 34 },
    settingsText: { color: palette.muted, fontSize: font(18) },
    scroller: { flex: 1 },
    list: { paddingBottom: 24, paddingHorizontal: CONTENT_RAIL_INSET, paddingTop: 10 },
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
    pillNotice: { color: palette.muted, fontSize: font(11) },
    chip: { backgroundColor: palette.card, borderRadius: 9, color: palette.muted, flexShrink: 0, fontSize: font(10), fontWeight: "600", overflow: "hidden", paddingHorizontal: 6, paddingVertical: 2 },
    age: { color: palette.tertiary, fontSize: font(11), fontWeight: "500", minWidth: 28, textAlign: "right" },
    hotkeySlot: { alignItems: "center", justifyContent: "center", minHeight: 24, width: 35 },
    hotkey: { backgroundColor: palette.border, borderRadius: 10, color: palette.muted, fontSize: font(10), fontWeight: "600", overflow: "hidden", paddingHorizontal: 5, paddingVertical: 3 },
    ownerColumn: { alignItems: "flex-start", justifyContent: "center", minHeight: 32, width: 120 },
    actionText: { color: palette.muted, fontSize: font(11), fontWeight: "600" },
    linkText: { color: palette.accent },
    chatColumn: { alignItems: "flex-start", justifyContent: "center", paddingRight: 8, width: 190 },
    chatAction: { borderRadius: 8, minHeight: 32, paddingHorizontal: 6, paddingVertical: 8, width: "100%" },
    chatHovered: { backgroundColor: palette.accentWash },
    chatText: { color: palette.tertiary, fontSize: font(11), fontWeight: "600" },
    loadMore: { alignItems: "center", alignSelf: "stretch", backgroundColor: palette.card, borderRadius: 8, marginHorizontal: 12, marginTop: 8, paddingVertical: 10 },
    loadMoreText: { color: palette.accent, fontSize: font(11), fontWeight: "600" },
    empty: { alignItems: "center", justifyContent: "center", minHeight: 330, padding: 24 },
    emptyIcon: { color: palette.tertiary, fontSize: 30 },
    emptyTitle: { color: palette.foreground, fontSize: font(16), fontWeight: "600", marginTop: 12 },
    emptyDetail: { color: palette.muted, fontSize: font(12), marginTop: 8, textAlign: "center" },
    footer: { borderTopColor: palette.border, borderTopWidth: 1, minHeight: 42, paddingHorizontal: CONTENT_RAIL_INSET, paddingVertical: 9 },
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
