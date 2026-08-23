import { useEffect, useMemo, useRef, useState } from "react";
import {
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import type {
  ChatImage,
  ChatItem,
  ChatPendingAction,
  SessionSummary,
} from "@agent-visor/protocol";
import { browserCommand } from "./browser-shortcuts";
import { groupChatTurns, type ChatTurn } from "./chat-presentation";
import type { Palette } from "./theme";
import { useChat } from "./use-chat";

export function Chat({
  contentScale,
  onBack,
  onContentScaleChange,
  onOpenOwner,
  palette,
  session,
}: {
  contentScale: number;
  onBack(): void;
  onContentScaleChange(delta: -0.1 | 0 | 0.1): void;
  onOpenOwner(): void;
  palette: Palette;
  session: SessionSummary;
}) {
  const chat = useChat(session.id);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const styles = useMemo(() => createStyles(palette, contentScale), [contentScale, palette]);
  const turns = useMemo(() => groupChatTurns(chat.page?.items ?? []), [chat.page?.items]);
  const scroll = useRef<ScrollView>(null);
  const didInitialScroll = useRef(false);

  useEffect(() => {
    const keyDown = (event: KeyboardEvent) => {
      const command = browserCommand(event);
      if (command?.type === "scale") {
        event.preventDefault();
        onContentScaleChange(command.delta);
      } else if (event.key === "Escape" && detailsOpen) {
        event.preventDefault();
        setDetailsOpen(false);
      } else if (command?.type === "back" || event.key === "Escape") {
        event.preventDefault();
        onBack();
      }
    };
    window.addEventListener("keydown", keyDown);
    return () => window.removeEventListener("keydown", keyDown);
  }, [detailsOpen, onBack, onContentScaleChange]);

  return (
    <View style={styles.app}>
      <View style={styles.header}>
        <Pressable accessibilityLabel="Back to Sessions" onPress={onBack} style={styles.backButton}>
          <Text style={styles.link}>‹ Back to Sessions</Text>
        </Pressable>
        <View accessibilityLabel={`${sectionLabel(session.section)} status`} style={[styles.status, { backgroundColor: sectionColor(session.section, palette) }]} />
        <Text numberOfLines={1} style={styles.headerTitle}>{session.title}</Text>
        {session.canOpenOwner ? (
          <Pressable accessibilityLabel={`Open in ${session.owner}`} onPress={onOpenOwner} style={styles.headerAction}>
            <Text style={styles.muted}>↗ Open in {session.owner}</Text>
          </Pressable>
        ) : null}
        <Pressable accessibilityLabel="Chat Details" onPress={() => setDetailsOpen((open) => !open)} style={styles.detailsButton}>
          <Text style={styles.muted}>•••</Text>
        </Pressable>
      </View>

      {detailsOpen ? <Details session={session} styles={styles} /> : null}

      {chat.status === "loading" ? (
        <Centered text="Loading Chat history…" styles={styles} />
      ) : chat.status === "failed" ? (
        <Centered text="Unable to load Chat history" styles={styles} />
      ) : (
        <ScrollView
          contentContainerStyle={styles.timeline}
          onContentSizeChange={() => {
            if (!didInitialScroll.current) {
              didInitialScroll.current = true;
              scroll.current?.scrollToEnd({ animated: false });
            }
          }}
          ref={scroll}
          style={styles.scroller}
        >
          <View style={styles.rail}>
            {chat.page?.hasMoreBefore ? (
              <Pressable accessibilityLabel="Load earlier messages" onPress={chat.loadEarlier} style={styles.loadEarlier}>
                <Text style={styles.link}>Load earlier messages</Text>
              </Pressable>
            ) : null}
            {turns.map((turn) => <Turn key={turn.id} styles={styles} turn={turn} />)}
            {!turns.length ? <Centered text="No Chat history yet" styles={styles} /> : null}
          </View>
        </ScrollView>
      )}

      {chat.error ? <Text accessibilityRole="alert" style={styles.errorBanner}>{chat.error}</Text> : null}
      {chat.page?.pendingAction ? (
        <PendingAction action={chat.page.pendingAction} onRespond={chat.respond} styles={styles} />
      ) : chat.page ? (
        <Composer
          canSendImages={chat.page.capabilities.canSendImages}
          canSendText={chat.page.capabilities.canSendText}
          onSend={chat.send}
          readOnlyReason={chat.page.capabilities.readOnlyReason}
          styles={styles}
        />
      ) : null}
      <View style={styles.statusBar}>
        <Text style={styles.statusText}>{session.source}</Text>
        <Text numberOfLines={1} style={styles.statusPath}>{session.cwd}</Text>
        {!chat.page?.capabilities.canSendText ? <Text style={styles.readOnly}>Read only</Text> : null}
      </View>
    </View>
  );
}

function Turn({ styles, turn }: { styles: ChatStyles; turn: ChatTurn }) {
  const requiresAttention = turn.work.some((item) =>
    item.kind === "tool" && ["waiting", "error"].includes(item.status));
  const [expanded, setExpanded] = useState(turn.live || requiresAttention);
  return (
    <View style={styles.turn}>
      {turn.prompt ? <Message item={turn.prompt} styles={styles} /> : null}
      {turn.work.length ? (
        <View style={styles.work}>
          <Pressable
            accessibilityLabel={`${expanded ? "Hide" : "Show"} ${turn.work.length} work items`}
            onPress={() => setExpanded((value) => !value)}
            style={styles.workHeader}
          >
            <Text style={styles.workLabel}>{expanded ? "⌄" : "›"} {turn.live ? "Working…" : `Worked · ${turn.work.length} steps`}</Text>
          </Pressable>
          {expanded ? turn.work.map((item) => <Message item={item} key={item.id} styles={styles} />) : null}
        </View>
      ) : null}
      {turn.answers.map((item) => <Message item={item} key={item.id} styles={styles} />)}
    </View>
  );
}

function Message({ item, styles }: { item: ChatItem; styles: ChatStyles }) {
  if (item.kind === "user") {
    return (
      <View style={styles.userRow}>
        <View style={styles.userBubble}>
          {item.images.map((image, index) => <ChatImageView image={image} key={`${image.name}-${index}`} styles={styles} />)}
          {item.text ? <MessageText styles={styles} text={item.text} /> : null}
        </View>
      </View>
    );
  }
  if (item.kind === "tool") return <Tool item={item} styles={styles} />;
  if (item.kind === "thinking") {
    return <Text selectable style={styles.thinking}>{item.text}</Text>;
  }
  if (item.kind === "system") {
    return <Text selectable style={[styles.system, item.tone === "error" && styles.errorText]}>{item.text}</Text>;
  }
  return <View style={styles.assistant}><View style={styles.assistantDot} /><MessageText styles={styles} text={item.text} /></View>;
}

function MessageText({ styles, text }: { styles: ChatStyles; text: string }) {
  const parts = text.split("```");
  return (
    <View style={styles.messageText}>
      {parts.map((part, index) => index % 2 ? (
        <Text key={index} selectable style={styles.code}>{part.replace(/^\w+\n/, "")}</Text>
      ) : part ? <InlineMarkdown key={index} styles={styles} text={part} /> : null)}
    </View>
  );
}

function InlineMarkdown({ styles, text }: { styles: ChatStyles; text: string }) {
  const parts = text.split(/(\*\*[^*]+\*\*|`[^`]+`)/g);
  return (
    <Text selectable style={styles.body}>
      {parts.map((part, index) => part.startsWith("**") && part.endsWith("**") ? (
        <Text key={index} style={styles.bold}>{part.slice(2, -2)}</Text>
      ) : part.startsWith("`") && part.endsWith("`") ? (
        <Text key={index} style={styles.inlineCode}>{part.slice(1, -1)}</Text>
      ) : part)}
    </Text>
  );
}

function Tool({ item, styles }: { item: Extract<ChatItem, { kind: "tool" }>; styles: ChatStyles }) {
  const [expanded, setExpanded] = useState(item.status === "error" || item.status === "waiting");
  return (
    <View style={styles.tool}>
      <Pressable accessibilityLabel={`${expanded ? "Hide" : "Show"} details for ${item.name}`} onPress={() => setExpanded((value) => !value)} style={styles.toolHeader}>
        <Text style={[styles.toolStatus, item.status === "error" && styles.errorText]}>{toolGlyph(item.status)}</Text>
        <Text style={styles.toolName}>{item.name}</Text>
        <Text numberOfLines={1} style={styles.toolSummary}>{toolSummary(item.input)}</Text>
        <Text style={styles.toolChevron}>{expanded ? "⌄" : "›"}</Text>
      </Pressable>
      {expanded ? (
        <View style={styles.toolDetail}>
          <Text selectable style={styles.code}>{JSON.stringify(item.input, null, 2).slice(0, 20_000)}</Text>
          {item.result ? <Text selectable style={item.status === "error" ? styles.errorText : styles.toolResult}>{item.result}</Text> : null}
        </View>
      ) : null}
    </View>
  );
}

function ChatImageView({ image, styles }: { image: ChatImage; styles: ChatStyles }) {
  const uri = image.data?.startsWith("data:") || image.data?.startsWith("http")
    ? image.data : image.data ? `data:${image.mimeType};base64,${image.data}` : undefined;
  return uri ? <Image accessibilityLabel={image.name} source={{ uri }} style={styles.image} /> : <Text style={styles.muted}>{image.name}</Text>;
}

function PendingAction({
  action,
  onRespond,
  styles,
}: {
  action: ChatPendingAction;
  onRespond(message: Parameters<ReturnType<typeof useChat>["respond"]>[0]): void;
  styles: ChatStyles;
}) {
  if (action.type === "question") return <QuestionAction action={action} onRespond={onRespond} styles={styles} />;
  return (
    <View style={styles.actionPanel}>
      <Text style={styles.actionTitle}>Approve {action.toolName}?</Text>
      <Text selectable style={styles.code}>{JSON.stringify(action.input, null, 2)}</Text>
      <View style={styles.actionButtons}>
        <ActionButton label="Deny" onPress={() => onRespond({ type: "respond_chat", toolUseId: action.toolUseId, decision: "deny" })} styles={styles} />
        <ActionButton label="Allow" onPress={() => onRespond({ type: "respond_chat", toolUseId: action.toolUseId, decision: "allow" })} styles={styles} />
        {action.canPersist ? <ActionButton label="Always allow" onPress={() => onRespond({ type: "respond_chat", toolUseId: action.toolUseId, decision: "allow_always" })} styles={styles} /> : null}
      </View>
    </View>
  );
}

function QuestionAction({
  action,
  onRespond,
  styles,
}: {
  action: Extract<ChatPendingAction, { type: "question" }>;
  onRespond(message: Parameters<ReturnType<typeof useChat>["respond"]>[0]): void;
  styles: ChatStyles;
}) {
  const [answers, setAnswers] = useState<Record<string, string | string[]>>({});
  return (
    <View style={styles.actionPanel}>
      {action.questions.map((question) => (
        <View key={question.id} style={styles.question}>
          <Text style={styles.actionTitle}>{question.question}</Text>
          {question.choices.length ? question.choices.map((choice) => {
            const selected = question.multiple
              ? (answers[question.id] as string[] | undefined)?.includes(choice)
              : answers[question.id] === choice;
            return (
              <Pressable
                accessibilityLabel={`${selected ? "Selected" : "Select"} ${choice}`}
                key={choice}
                onPress={() => setAnswers((current) => ({
                  ...current,
                  [question.id]: question.multiple
                    ? toggleChoice(current[question.id], choice)
                    : choice,
                }))}
                style={[styles.choice, selected && styles.choiceSelected]}
              >
                <Text style={styles.body}>{selected ? "●" : "○"} {choice}</Text>
              </Pressable>
            );
          }) : (
            <TextInput
              accessibilityLabel={`Answer ${question.question}`}
              onChangeText={(text) => setAnswers((current) => ({ ...current, [question.id]: text }))}
              style={styles.answerInput}
              value={answers[question.id] as string | undefined}
            />
          )}
        </View>
      ))}
      <ActionButton
        label="Submit answers"
        onPress={() => onRespond({ type: "respond_chat", toolUseId: action.toolUseId, decision: "answer", answers })}
        styles={styles}
      />
    </View>
  );
}

function Composer({
  canSendImages,
  canSendText,
  onSend,
  readOnlyReason,
  styles,
}: {
  canSendImages: boolean;
  canSendText: boolean;
  onSend(text: string, images: ChatImage[]): void;
  readOnlyReason?: string;
  styles: ChatStyles;
}) {
  const [text, setText] = useState("");
  const [images, setImages] = useState<ChatImage[]>([]);
  if (!canSendText && !canSendImages) {
    return <Text style={styles.readOnlyBanner}>{readOnlyReason ?? "Chat history is read only."}</Text>;
  }
  const submit = () => {
    const body = text.trim();
    if (!body && !images.length) return;
    onSend(body, images);
    setText("");
    setImages([]);
  };
  return (
    <View style={styles.composer}>
      {images.length ? <ScrollView horizontal>{images.map((image, index) => <ChatImageView image={image} key={`${image.name}-${index}`} styles={styles} />)}</ScrollView> : null}
      <View style={styles.composerRow}>
        {canSendImages ? <ActionButton label="Add image" onPress={() => void pickImages().then((picked) => setImages((current) => [...current, ...picked]))} styles={styles} /> : null}
        <TextInput
          accessibilityLabel="Chat message"
          multiline
          onChangeText={setText}
          placeholder="Message agent…"
          style={styles.composerInput}
          value={text}
        />
        <ActionButton label="Send" onPress={submit} styles={styles} />
      </View>
    </View>
  );
}

function Details({ session, styles }: { session: SessionSummary; styles: ChatStyles }) {
  return (
    <View accessibilityLabel="Chat technical details" style={styles.details}>
      <Text style={styles.actionTitle}>Details</Text>
      <Text style={styles.muted}>Source: {session.source}</Text>
      <Text style={styles.muted}>Owner: {session.owner}</Text>
      <Text style={styles.muted}>Project: {session.project}</Text>
      <Text selectable style={styles.muted}>Path: {session.cwd}</Text>
    </View>
  );
}

function ActionButton({ label, onPress, styles }: { label: string; onPress(): void; styles: ChatStyles }) {
  return <Pressable accessibilityLabel={label} onPress={onPress} style={styles.actionButton}><Text style={styles.link}>{label}</Text></Pressable>;
}

function Centered({ text, styles }: { text: string; styles: ChatStyles }) {
  return <View style={styles.centered}><Text style={styles.muted}>{text}</Text></View>;
}

function toggleChoice(value: string | string[] | undefined, choice: string): string[] {
  const choices = Array.isArray(value) ? value : [];
  return choices.includes(choice) ? choices.filter((item) => item !== choice) : [...choices, choice];
}

async function pickImages(): Promise<ChatImage[]> {
  if (typeof document === "undefined") return [];
  return new Promise((resolve) => {
    const picker = document.createElement("input");
    picker.type = "file";
    picker.accept = "image/png,image/jpeg,image/gif,image/webp";
    picker.multiple = true;
    picker.onchange = async () => {
      const supported = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
      const files = [...(picker.files ?? [])]
        .filter((file) => supported.has(file.type) && file.size <= 10_000_000)
        .slice(0, 10);
      resolve(await Promise.all(files.map(async (file) => ({
        name: file.name,
        mimeType: file.type as ChatImage["mimeType"],
        data: await fileData(file),
      }))));
    };
    picker.click();
  });
}

function fileData(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]+,/, ""));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

function toolSummary(input: Record<string, unknown>): string {
  for (const key of ["command", "path", "file_path", "query", "description"]) {
    if (typeof input[key] === "string") return input[key] as string;
  }
  return "";
}

function toolGlyph(status: Extract<ChatItem, { kind: "tool" }>["status"]): string {
  return { running: "●", waiting: "!", success: "✓", error: "×", interrupted: "■" }[status];
}

function sectionLabel(section: SessionSummary["section"]): string {
  return { needs_you: "Needs you", ready: "Ready", working: "In progress", history: "History" }[section];
}

function sectionColor(section: SessionSummary["section"], palette: Palette): string {
  return { needs_you: palette.attention, ready: palette.ready, working: palette.working, history: palette.history }[section];
}

type ChatStyles = ReturnType<typeof createStyles>;
function createStyles(palette: Palette, scale: number) {
  const font = (size: number) => size * scale;
  return StyleSheet.create({
    app: { backgroundColor: palette.background, flex: 1 },
    header: { alignItems: "center", borderBottomColor: palette.border, borderBottomWidth: 1, flexDirection: "row", minHeight: 74, paddingHorizontal: 28, paddingTop: 28 },
    backButton: { justifyContent: "center", minHeight: 44, paddingRight: 12 },
    status: { borderRadius: 4, height: 8, marginRight: 8, width: 8 },
    headerTitle: { color: palette.foreground, flex: 1, fontSize: font(14), fontWeight: "600" },
    headerAction: { justifyContent: "center", minHeight: 44, paddingHorizontal: 12 },
    detailsButton: { alignItems: "center", justifyContent: "center", minHeight: 44, width: 44 },
    link: { color: palette.accent, fontSize: font(12), fontWeight: "600" },
    muted: { color: palette.muted, fontSize: font(12) },
    details: { alignSelf: "flex-end", backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, gap: 5, marginRight: 28, marginTop: 8, maxWidth: 420, padding: 12, position: "absolute", top: 74, zIndex: 4 },
    scroller: { flex: 1 },
    timeline: { paddingBottom: 20, paddingHorizontal: 28, paddingTop: 12 },
    rail: { alignSelf: "center", maxWidth: 980, width: "100%" },
    loadEarlier: { alignSelf: "center", minHeight: 36, padding: 8 },
    turn: { gap: 10, paddingVertical: 8 },
    work: { gap: 7 },
    workHeader: { alignSelf: "flex-start", minHeight: 30, paddingVertical: 6 },
    workLabel: { color: palette.tertiary, fontSize: font(11), fontWeight: "600" },
    userRow: { alignItems: "flex-end", paddingLeft: 60 },
    userBubble: { backgroundColor: palette.card, borderRadius: 18, gap: 8, maxWidth: "82%", paddingHorizontal: 14, paddingVertical: 10 },
    assistant: { alignItems: "flex-start", flexDirection: "row", gap: 8 },
    assistantDot: { backgroundColor: palette.accent, borderRadius: 3, height: 6, marginTop: 7, width: 6 },
    messageText: { flex: 1, gap: 8 },
    body: { color: palette.foreground, fontSize: font(13), lineHeight: font(19) },
    bold: { fontWeight: "700" },
    inlineCode: { backgroundColor: palette.card, fontFamily: "monospace", fontSize: font(12) },
    thinking: { color: palette.tertiary, fontSize: font(12), fontStyle: "italic", lineHeight: font(18), paddingLeft: 14 },
    system: { color: palette.tertiary, fontSize: font(11), textAlign: "center" },
    code: { backgroundColor: palette.card, borderRadius: 7, color: palette.foreground, fontFamily: "monospace", fontSize: font(11), lineHeight: font(17), overflow: "hidden", padding: 10 },
    tool: { paddingLeft: 14 },
    toolHeader: { alignItems: "center", flexDirection: "row", gap: 7, minHeight: 32 },
    toolStatus: { color: palette.ready, fontSize: font(11), width: 12 },
    toolName: { color: palette.foreground, fontSize: font(12), fontWeight: "600" },
    toolSummary: { color: palette.muted, flex: 1, fontFamily: "monospace", fontSize: font(10) },
    toolChevron: { color: palette.tertiary, fontSize: font(14) },
    toolDetail: { gap: 7, paddingLeft: 19, paddingTop: 4 },
    toolResult: { color: palette.muted, fontFamily: "monospace", fontSize: font(11), lineHeight: font(16) },
    image: { borderRadius: 9, height: 120, resizeMode: "contain", width: 180 },
    errorText: { color: palette.error },
    errorBanner: { backgroundColor: `${palette.error}20`, color: palette.error, fontSize: font(11), paddingHorizontal: 28, paddingVertical: 7 },
    actionPanel: { alignSelf: "stretch", backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, gap: 9, marginHorizontal: 28, maxHeight: 300, padding: 12 },
    actionTitle: { color: palette.foreground, fontSize: font(13), fontWeight: "600" },
    actionButtons: { flexDirection: "row", gap: 8, justifyContent: "flex-end" },
    actionButton: { borderColor: palette.border, borderRadius: 8, borderWidth: 1, justifyContent: "center", minHeight: 34, paddingHorizontal: 10 },
    question: { gap: 6 },
    choice: { borderColor: palette.border, borderRadius: 7, borderWidth: 1, minHeight: 34, padding: 8 },
    choiceSelected: { backgroundColor: palette.accentWash, borderColor: palette.accent },
    answerInput: { backgroundColor: palette.background, borderColor: palette.border, borderRadius: 7, borderWidth: 1, color: palette.foreground, fontSize: font(12), minHeight: 38, padding: 8 },
    composer: { alignSelf: "center", gap: 7, maxWidth: 980, paddingHorizontal: 28, paddingVertical: 8, width: "100%" },
    composerRow: { alignItems: "flex-end", flexDirection: "row", gap: 8 },
    composerInput: { backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, color: palette.foreground, flex: 1, fontSize: font(13), maxHeight: 180, minHeight: 42, padding: 10 },
    readOnlyBanner: { color: palette.muted, fontSize: font(11), paddingHorizontal: 28, paddingVertical: 10, textAlign: "center" },
    centered: { alignItems: "center", flex: 1, justifyContent: "center", minHeight: 200 },
    statusBar: { alignItems: "center", borderTopColor: palette.border, borderTopWidth: 1, flexDirection: "row", gap: 10, minHeight: 32, paddingHorizontal: 28 },
    statusText: { color: palette.muted, fontSize: font(10), fontWeight: "600" },
    statusPath: { color: palette.tertiary, flex: 1, fontSize: font(10) },
    readOnly: { color: palette.tertiary, fontSize: font(10), fontWeight: "600" },
  });
}
