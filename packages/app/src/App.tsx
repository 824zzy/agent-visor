import { useMemo, useState } from "react";
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import type { SessionSummary } from "@agent-visor/protocol";
import { groupSessions } from "./session-groups";
import { useSessionSnapshot } from "./use-session-snapshot";

const colors = {
  background: "#f1f2f7",
  border: "#d8dae5",
  card: "#e5e7ef",
  foreground: "#36394a",
  muted: "#74798e",
  accent: "#4e78ee",
  attention: "#d4a72c",
  ready: "#43a86b",
  working: "#c04b1c",
  history: "#686c80",
};

export function App() {
  const connection = useSessionSnapshot();
  const [query, setQuery] = useState("");

  const sessions = useMemo(() => {
    if (connection.status !== "connected") return [];
    const needle = query.trim().toLocaleLowerCase();
    if (!needle) return connection.snapshot.sessions;
    return connection.snapshot.sessions.filter((session) =>
      [session.title, session.subtitle, session.source, session.project, session.owner, session.cwd]
        .some((value) => value.toLocaleLowerCase().includes(needle)),
    );
  }, [connection, query]);

  return (
    <View style={styles.app}>
      <View style={styles.header}>
        <TextInput
          accessibilityLabel="Search sessions"
          onChangeText={setQuery}
          placeholder="Search all sessions"
          placeholderTextColor={colors.muted}
          style={styles.search}
          value={query}
        />
        <Pressable accessibilityLabel="Settings" accessibilityRole="button" style={styles.settings}>
          <Text style={styles.settingsText}>⚙</Text>
        </Pressable>
      </View>

      {connection.status === "failed" ? (
        <CenteredMessage text="Unable to connect to Agent Visor" />
      ) : connection.status === "connecting" ? (
        <CenteredMessage text="Connecting to Agent Visor…" />
      ) : (
        <ScrollView contentContainerStyle={styles.list}>
          {groupSessions(sessions).map((group) => (
            <View key={group.id}>
              <View style={styles.sectionHeader}>
                <Text style={styles.sectionTitle}>{group.title}</Text>
                <Text style={styles.count}>{group.sessions.length}</Text>
              </View>
              {group.sessions.map((session) => (
                <SessionRow key={session.id} session={session} />
              ))}
            </View>
          ))}
          {sessions.length === 0 ? <CenteredMessage text="No matching sessions" /> : null}
        </ScrollView>
      )}

      <View style={styles.footer}>
        <Text style={styles.footerText}>↑↓ Navigate</Text>
        <Text style={styles.footerText}>↩ Open source app</Text>
        <Text style={styles.footerText}>⇧↩ Open Chat</Text>
      </View>
    </View>
  );
}

function SessionRow({ session }: { session: SessionSummary }) {
  return (
    <View style={styles.row}>
      <Pressable
        accessibilityLabel={`${session.title}, open in ${session.owner}`}
        accessibilityRole="button"
        style={styles.primaryAction}
      >
        <View style={[styles.statusDot, { backgroundColor: sectionColor(session.section) }]} />
        <View style={styles.identity}>
          <View style={styles.titleLine}>
            <Text numberOfLines={1} style={styles.title}>{session.title}</Text>
            <Chip label={session.source} />
            <Chip label={session.project} />
          </View>
          <Text numberOfLines={1} style={styles.subtitle}>{session.subtitle || session.cwd}</Text>
        </View>
        <View style={styles.ownerColumn}>
          <Text numberOfLines={1} style={styles.actionText}>↗ Open in {session.owner}</Text>
        </View>
      </Pressable>
      <View style={styles.chatColumn}>
        {session.canEnterChat ? (
          <Pressable
            accessibilityLabel={`Open Chat for ${session.title}`}
            accessibilityRole="button"
            style={styles.chatAction}
          >
            <Text style={styles.chatText}>▢ Open Chat</Text>
          </Pressable>
        ) : null}
      </View>
    </View>
  );
}

function Chip({ label }: { label: string }) {
  return <Text style={styles.chip}>{label}</Text>;
}

function CenteredMessage({ text }: { text: string }) {
  return (
    <View style={styles.centered}>
      <Text style={styles.muted}>{text}</Text>
    </View>
  );
}

function sectionColor(section: SessionSummary["section"]): string {
  return {
    needs_you: colors.attention,
    ready: colors.ready,
    working: colors.working,
    history: colors.history,
  }[section];
}

const styles = StyleSheet.create({
  app: { backgroundColor: colors.background, flex: 1 },
  header: { alignItems: "center", borderBottomColor: colors.border, borderBottomWidth: 1, flexDirection: "row", gap: 12, paddingBottom: 18, paddingHorizontal: 18, paddingTop: 42 },
  search: { borderColor: colors.accent, borderRadius: 10, borderWidth: 1.5, color: colors.foreground, flex: 1, fontSize: 15, height: 44, paddingHorizontal: 14 },
  settings: { alignItems: "center", backgroundColor: colors.card, borderRadius: 9, height: 40, justifyContent: "center", width: 40 },
  settingsText: { color: colors.muted, fontSize: 17 },
  list: { paddingBottom: 24, paddingHorizontal: 18 },
  sectionHeader: { alignItems: "center", flexDirection: "row", gap: 7, paddingBottom: 6, paddingTop: 18 },
  sectionTitle: { color: colors.muted, fontSize: 12, fontWeight: "600" },
  count: { backgroundColor: colors.border, borderRadius: 10, color: colors.muted, fontSize: 10, fontWeight: "600", overflow: "hidden", paddingHorizontal: 7, paddingVertical: 2 },
  row: { alignItems: "stretch", flexDirection: "row", minHeight: 62 },
  primaryAction: { alignItems: "center", borderRadius: 10, flex: 1, flexDirection: "row", gap: 12, paddingHorizontal: 12 },
  statusDot: { borderRadius: 4, height: 8, width: 8 },
  identity: { flex: 1, gap: 5, minWidth: 180 },
  titleLine: { alignItems: "center", flexDirection: "row", gap: 7 },
  title: { color: colors.foreground, flexShrink: 1, fontSize: 14, fontWeight: "600" },
  subtitle: { color: colors.muted, fontSize: 12 },
  chip: { backgroundColor: colors.card, borderRadius: 9, color: colors.muted, fontSize: 10, fontWeight: "600", overflow: "hidden", paddingHorizontal: 7, paddingVertical: 3 },
  ownerColumn: { alignItems: "flex-start", justifyContent: "center", width: 132 },
  actionText: { color: colors.foreground, fontSize: 11, fontWeight: "600" },
  chatColumn: { alignItems: "flex-start", justifyContent: "center", width: 112 },
  chatAction: { borderRadius: 8, paddingHorizontal: 6, paddingVertical: 10 },
  chatText: { color: colors.muted, fontSize: 11, fontWeight: "600" },
  centered: { alignItems: "center", flex: 1, justifyContent: "center", minHeight: 240 },
  muted: { color: colors.muted, fontSize: 13 },
  footer: { borderTopColor: colors.border, borderTopWidth: 1, flexDirection: "row", gap: 18, minHeight: 42, paddingHorizontal: 18, paddingVertical: 13 },
  footerText: { color: colors.muted, fontSize: 10 },
});
