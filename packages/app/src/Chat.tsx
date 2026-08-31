import { createElement, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  FlatList,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import type { ImageStyle, TextStyle } from "react-native";
import type { ListRenderItemInfo } from "react-native";
import type {
  ChatImage,
  ChatItem,
  ChatMetadata,
  ChatPendingAction,
  ChatSlashCommand,
  ChatVisibility,
  SessionSummary,
} from "@agent-visor/protocol";
import { browserCommand } from "./browser-shortcuts";
import {
  accessibleThinkingText,
  chatMetadataRows,
  filterChatItems,
  filterChatTurns,
  groupChatTurns,
  historyImageDataURI,
  shouldGroupChatTurns,
} from "./chat-presentation";
import {
  chatToolPresentation,
  chatLocalReference,
  parseChatRichText,
  presentChatMath,
  safeChatLink,
  tokenizeChatCode,
  type ChatRichBlock,
  type ChatRichInline,
} from "./chat-rich-content";
import {
  chatActionTitle,
  normalizeQuestionAnswers,
  pendingChatActionIdentity,
  validateQuestionAnswers,
} from "./chat-action-policy";
import { chatStatusSummary, displayMode } from "./chat-status";
import {
  appendComposerAttachments,
  applyComposerRecoveryCommand,
  composerDraftToSubmitted,
  composerDraftStore,
  composerEscapeAction,
  composerKeyAction,
  composerLayoutForContent,
  COMPOSER_DEFAULT_LINE_HEIGHT,
  COMPOSER_MAX_LINES,
  COMPOSER_MAX_FILE_SELECTION,
  COMPOSER_MAX_TEXT_LENGTH,
  COMPOSER_MIN_HEIGHT,
  COMPOSER_VERTICAL_PADDING,
  draftSubmission,
  createComposerAttachmentOperations,
  preflightComposerFiles,
  filterSlashCommands,
  removeComposerAttachment,
  slashQuery,
  validateComposerText,
  type ComposerAttachment,
  type ComposerAttachmentCandidate,
  type ComposerDraft,
  type ComposerRecoveryCommand,
} from "./chat-composer";
import {
  COMPOSER_PASTE_CANCELED_MESSAGE,
  composerPasteSnapshotIsCurrent,
  createComposerPasteSnapshot,
  extractComposerPaste,
  hasComposerPastePayload,
  insertComposerTextAtSelection,
} from "./chat-paste";
import { CONTENT_RAIL_INSET, contentRailStyle } from "./content-rail";
import type { Palette } from "./theme";
import { chatCancellationView, type ChatCancellationView } from "./chat-cancellation";
import type { ChatDeliveryRecoveryRecord } from "./chat-delivery-recovery";
import { chatRecoveryView } from "./chat-recovery-presentation";
import {
  CHAT_NEAR_BOTTOM_THRESHOLD,
  chatTailAction,
  classifyChatItemsChange,
  type ChatItemsChange,
  type ChatTailScrollAction,
} from "./chat-tail";
import { useChat } from "./use-chat";

type ChatTimelineRow =
  | { type: "item"; id: string; item: ChatItem }
  | { type: "group-prompt"; id: string; turnID: string; item: Extract<ChatItem, { kind: "user" }> }
  | { type: "group-work-header"; id: string; turnID: string; count: number; live: boolean; expanded: boolean }
  | { type: "group-work-item"; id: string; turnID: string; item: ChatItem }
  | { type: "group-answer"; id: string; turnID: string; item: ChatItem };

type ChatPrependAnchor = {
  sessionID: string;
  anchorID?: string;
  anchorTop?: number;
  scrollTop: number;
  scrollHeight?: number;
  contentHeight?: number;
  itemCount: number;
};

// ponytail: keep this recovery loop bounded; increase only with a measured
// FlatList layout trace showing that variable-height cells settle later.
const CHAT_TAIL_SETTLE_FRAMES = 8;

export function Chat({
  contentScale,
  onBack,
  onContentScaleChange,
  onOpenOwner,
  palette,
  session,
  visibility,
}: {
  contentScale: number;
  onBack(): void;
  onContentScaleChange(delta: -0.1 | 0 | 0.1): void;
  onOpenOwner(): void;
  palette: Palette;
  session: SessionSummary;
  visibility: ChatVisibility;
}) {
  const chat = useChat(session.id, session.section);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const chatSurface = useMemo(() => createChatPalette(palette), [palette]);
  const styles = useMemo(() => createStyles(chatSurface, contentScale), [chatSurface, contentScale]);
  const canonicalItems = chat.page?.items ?? [];
  const canonicalItemCount = useRef(canonicalItems.length);
  canonicalItemCount.current = canonicalItems.length;
  const items = useMemo(
    () => filterChatItems(canonicalItems, visibility),
    [canonicalItems, visibility],
  );
  const grouped = shouldGroupChatTurns(session.source, visibility);
  const turns = useMemo(
    () => grouped ? filterChatTurns(groupChatTurns(canonicalItems), visibility) : [],
    [canonicalItems, grouped, visibility],
  );
  const [turnExpansionOverrides, setTurnExpansionOverrides] = useState<Record<string, boolean>>({});
  const timelineRows = useMemo<ChatTimelineRow[]>(
    () => grouped ? turns.flatMap((turn) => {
      const expanded = turnExpansionOverrides[turn.id]
        ?? (turn.live || turn.work.some((item) => item.kind === "tool"
          && ["waiting", "error"].includes(item.status)));
      const rows: ChatTimelineRow[] = [];
      if (turn.prompt) rows.push({
        type: "group-prompt",
        // Message-backed keys survive a prepended page even when grouping
        // re-anchors an assistant-only turn to its new first item.
        id: turn.prompt.id,
        turnID: turn.id,
        item: turn.prompt,
      });
      if (turn.work.length) rows.push({
        type: "group-work-header",
        id: `turn-work-${turn.id}`,
        turnID: turn.id,
        count: turn.work.length,
        live: turn.live,
        expanded,
      });
      if (expanded) {
        for (const item of turn.work) rows.push({
          type: "group-work-item",
          id: item.id,
          turnID: turn.id,
          item,
        });
      }
      for (const item of turn.answers) rows.push({
        type: "group-answer",
        id: item.id,
        turnID: turn.id,
        item,
      });
      return rows;
    }) : items.map((item) => ({ type: "item", id: item.id, item })),
    [grouped, items, turns, turnExpansionOverrides],
  );
  const initialTimelineIndex = useRef<{ sessionID: string; index?: number }>({
    sessionID: session.id,
  });
  if (initialTimelineIndex.current.sessionID !== session.id) {
    initialTimelineIndex.current = { sessionID: session.id };
  }
  if (initialTimelineIndex.current.index === undefined && timelineRows.length) {
    initialTimelineIndex.current.index = Math.max(0, timelineRows.length - 24);
  }
  const scroll = useRef<FlatList<ChatTimelineRow>>(null);
  const didInitialScroll = useRef(false);
  const distanceFromBottom = useRef(0);
  const scrollTop = useRef(0);
  const contentHeight = useRef<number | undefined>(undefined);
  const viewportHeight = useRef<number | undefined>(undefined);
  const previousItems = useRef<ChatItem[]>([]);
  const pendingPrepend = useRef<ChatPrependAnchor | undefined>(undefined);
  const pendingLocalSend = useRef(false);
  const animationFrames = useRef(new Set<number>());
  const tailPinToken = useRef(0);
  const tailPinInProgress = useRef(false);
  const activeTimelineSession = useRef(session.id);
  // Update during render so a queued frame from the previous session cannot
  // observe the old identity in the commit-to-effect gap.
  activeTimelineSession.current = session.id;

  const cancelAnimationFrames = () => {
    if (typeof cancelAnimationFrame === "function") {
      for (const frame of animationFrames.current) cancelAnimationFrame(frame);
    }
    animationFrames.current.clear();
  };

  const scheduleAnimationFrame = (callback: () => void, targetSessionID = session.id) => {
    if (typeof requestAnimationFrame !== "function") {
      if (activeTimelineSession.current === targetSessionID) callback();
      return;
    }
    const frame = requestAnimationFrame(() => {
      animationFrames.current.delete(frame);
      if (activeTimelineSession.current !== targetSessionID) return;
      callback();
    });
    animationFrames.current.add(frame);
  };

  const timelineElement = (targetSessionID = session.id): HTMLElement | undefined => {
    if (typeof document === "undefined" || activeTimelineSession.current !== targetSessionID) return undefined;
    const element = document.getElementById(chatTimelineNativeID(targetSessionID));
    return element instanceof HTMLElement ? element : undefined;
  };

  const pinToTail = (targetSessionID = session.id) => {
    if (activeTimelineSession.current !== targetSessionID) return;
    scroll.current?.scrollToEnd({ animated: false });
    const element = timelineElement(targetSessionID);
    if (element) element.scrollTop = element.scrollHeight;
  };

  const scheduleTailPin = () => {
    const targetSessionID = session.id;
    const token = ++tailPinToken.current;
    tailPinInProgress.current = true;
    if (typeof requestAnimationFrame !== "function") {
      pinToTail(targetSessionID);
      tailPinInProgress.current = false;
      return;
    }
    const settle = (remaining: number) => {
      if (tailPinToken.current !== token) return;
      pinToTail(targetSessionID);
      if (remaining === 0) tailPinInProgress.current = false;
      if (remaining > 0) {
        // React Native Web can publish several variable-height cell layouts;
        // keep the tail pinned while those bounded measurements settle.
        scheduleAnimationFrame(() => settle(remaining - 1), targetSessionID);
      }
    };
    scheduleAnimationFrame(() => settle(CHAT_TAIL_SETTLE_FRAMES), targetSessionID);
  };

  const capturePrependAnchor = () => {
    const targetSessionID = session.id;
    const element = timelineElement(targetSessionID);
    const rows = element
      ? [...element.querySelectorAll<HTMLElement>('[id^="chat-item-"]')]
      : [];
    const viewportTop = element?.getBoundingClientRect().top ?? 0;
    const anchor = rows
      .map((row) => ({ row, rect: row.getBoundingClientRect() }))
      .filter(({ rect }) => rect.bottom > viewportTop)
      .sort((left, right) => left.rect.top - right.rect.top)[0]
      ?? (rows[0] ? { row: rows[0], rect: rows[0].getBoundingClientRect() } : undefined);
    pendingPrepend.current = {
      sessionID: targetSessionID,
      anchorID: anchor?.row.id,
      anchorTop: anchor?.rect.top,
      scrollTop: element?.scrollTop ?? scrollTop.current,
      scrollHeight: element?.scrollHeight,
      contentHeight: contentHeight.current,
      itemCount: canonicalItemCount.current,
    };
  };

  const restorePrependAnchor = (targetSessionID: string, attempt = 0) => {
    if (activeTimelineSession.current !== targetSessionID) return;
    const pending = pendingPrepend.current;
    if (!pending || pending.sessionID !== targetSessionID) return;
    if (canonicalItemCount.current <= pending.itemCount) {
      if (attempt < 12) {
        scheduleAnimationFrame(
          () => restorePrependAnchor(targetSessionID, attempt + 1),
          targetSessionID,
        );
      }
      return;
    }
    const element = timelineElement(targetSessionID);
    if (!element) {
      if (attempt < 12) {
        scheduleAnimationFrame(
          () => restorePrependAnchor(targetSessionID, attempt + 1),
          targetSessionID,
        );
      }
      return;
    }
    const measuredHeight = element.scrollHeight;
    if (pending.scrollHeight !== undefined
      && measuredHeight <= pending.scrollHeight + 0.5
      && attempt < 12) {
      scheduleAnimationFrame(
        () => restorePrependAnchor(targetSessionID, attempt + 1),
        targetSessionID,
      );
      return;
    }
    const anchor = pending.anchorID
      ? [...element.querySelectorAll<HTMLElement>('[id^="chat-item-"]')]
        .find((row) => row.id === pending.anchorID)
      : undefined;
    const currentHeight = contentHeight.current;
    if (!anchor && attempt < 12) {
      // Give the list one more layout pass to recycle the original anchor
      // before falling back to aggregate height correction.
      scheduleAnimationFrame(
        () => restorePrependAnchor(targetSessionID, attempt + 1),
        targetSessionID,
      );
      return;
    }
    // If the browser does not expose a changed scrollHeight yet, an
    // already-mounted anchor still gives an exact correction.
    if (anchor instanceof HTMLElement) {
      const delta = anchor.getBoundingClientRect().top - (pending.anchorTop ?? 0);
      const nextOffset = Math.max(0, element.scrollTop + delta);
      if (Math.abs(delta) > 0.5) {
        element.scrollTop = nextOffset;
        scroll.current?.scrollToOffset({ animated: false, offset: nextOffset });
      }
      pendingPrepend.current = undefined;
      return;
    }
    if (pending.scrollHeight !== undefined && measuredHeight > pending.scrollHeight + 0.5) {
      const delta = measuredHeight - pending.scrollHeight;
      const nextOffset = Math.max(0, element.scrollTop + delta);
      element.scrollTop = nextOffset;
      scroll.current?.scrollToOffset({ animated: false, offset: nextOffset });
      pendingPrepend.current = undefined;
      return;
    }
    // FlatList measures variable-height cells over several layout passes. Keep
    // the anchor request alive until its post-prepend cell is measurable.
    if (attempt < 12) {
      scheduleAnimationFrame(
        () => restorePrependAnchor(targetSessionID, attempt + 1),
        targetSessionID,
      );
      return;
    }
    if (element && pending.contentHeight !== undefined && currentHeight !== undefined) {
      const delta = currentHeight - pending.contentHeight;
      const nextOffset = Math.max(0, element.scrollTop + delta);
      element.scrollTop = nextOffset;
      scroll.current?.scrollToOffset({ animated: false, offset: nextOffset });
    }
    pendingPrepend.current = undefined;
  };

  const sendChat = (text: string, images: ChatImage[]): boolean | void => {
    pendingLocalSend.current = true;
    const accepted = chat.send(text, images);
    if (accepted === false) {
      pendingLocalSend.current = false;
    } else {
      // Local sends are an explicit user action: pin immediately, then let
      // the item-change effect pin again after FlatList lays out the echo.
      scheduleTailPin();
    }
    return accepted;
  };

  const handleComposerResize = () => {
    const element = timelineElement(session.id);
    const liveDistanceFromBottom = element
      ? element.scrollHeight - (element.scrollTop + element.clientHeight)
      : distanceFromBottom.current;
    if (didInitialScroll.current
      && chatTailAction({
        type: "composer-resize",
        distanceFromBottom: liveDistanceFromBottom,
      }) === "pin-to-tail") {
      scheduleTailPin();
    }
  };

  useEffect(() => {
    activeTimelineSession.current = session.id;
    tailPinToken.current += 1;
    tailPinInProgress.current = false;
    cancelAnimationFrames();
    didInitialScroll.current = false;
    distanceFromBottom.current = 0;
    scrollTop.current = 0;
    contentHeight.current = undefined;
    viewportHeight.current = undefined;
    previousItems.current = [];
    pendingPrepend.current = undefined;
    pendingLocalSend.current = false;
    return () => {
      cancelAnimationFrames();
      if (activeTimelineSession.current === session.id) activeTimelineSession.current = "";
    };
  }, [session.id]);

  useLayoutEffect(() => {
    const previous = previousItems.current;
    const contentChanged = previous.length === canonicalItems.length
      && previous.some((item, index) => chatItemContentChanged(item, canonicalItems[index]!));
    const change: ChatItemsChange = classifyChatItemsChange({
      previousIDs: previous.map(({ id }) => id),
      nextIDs: canonicalItems.map(({ id }) => id),
      contentChanged,
    });
    previousItems.current = canonicalItems;
    if (!didInitialScroll.current) return;

    if (change === "head-prepend") {
      scheduleAnimationFrame(() => restorePrependAnchor(session.id), session.id);
      return;
    }
    if (change === "unchanged" || change === "initial") return;
    const element = timelineElement(session.id);
    const liveDistanceFromBottom = element
      ? element.scrollHeight - (element.scrollTop + element.clientHeight)
      : distanceFromBottom.current;
    const action: ChatTailScrollAction = pendingLocalSend.current
      ? "pin-to-tail"
      : chatTailAction({
        type: change === "stream-growth" ? "stream-growth" : "tail-insert",
        distanceFromBottom: liveDistanceFromBottom,
      });
    pendingLocalSend.current = false;
    if (action === "pin-to-tail") scheduleTailPin();
  }, [canonicalItems, session.id]);

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
        <View accessibilityLabel="Chat header rail" style={styles.headerRail}>
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
      </View>

      {detailsOpen ? (
        <View pointerEvents="box-none" style={styles.detailsOverlay}>
          <View accessibilityLabel="Chat details rail" style={styles.detailsRail}>
            <Details metadata={chat.page?.metadata} session={session} styles={styles} />
          </View>
        </View>
      ) : null}

      {chat.status === "loading" ? (
        <Centered text="Loading Chat history…" styles={styles} />
      ) : chat.status === "failed" ? (
        <Centered text="Unable to load Chat history" styles={styles} />
      ) : (
        <>
          <FlatList
            accessibilityLabel="Chat timeline"
            data={timelineRows}
            contentContainerStyle={styles.timeline}
            nativeID={chatTimelineNativeID(session.id)}
            onContentSizeChange={(_width, height) => {
              contentHeight.current = height;
              if (pendingPrepend.current?.sessionID === session.id) {
                scheduleAnimationFrame(() => restorePrependAnchor(session.id), session.id);
                return;
              }
              if (!didInitialScroll.current) {
                didInitialScroll.current = true;
                scheduleTailPin();
              }
            }}
            onLayout={(event) => {
              viewportHeight.current = event.nativeEvent.layout.height;
            }}
            onScrollBeginDrag={() => {
              // A real reader gesture cancels a queued tail settle. Do not use
              // onScroll for this: FlatList emits intermediate programmatic
              // offsets while scrollToEnd is settling, and treating those as a
              // user escape can cancel the very pin that was requested.
              tailPinToken.current += 1;
              tailPinInProgress.current = false;
            }}
            onTouchStart={() => {
              // RN Web can report a touch-driven scroll without a native
              // onScrollBeginDrag callback; keep the same explicit gesture
              // cancellation path for that surface.
              tailPinToken.current += 1;
              tailPinInProgress.current = false;
            }}
            onScroll={(event) => {
              const next = event.nativeEvent;
              scrollTop.current = next.contentOffset.y;
              const nextDistanceFromBottom = next.contentSize.height
                - (next.contentOffset.y + next.layoutMeasurement.height);
              distanceFromBottom.current = nextDistanceFromBottom;
              if (nextDistanceFromBottom > CHAT_NEAR_BOTTOM_THRESHOLD && !tailPinInProgress.current) {
                // A far offset outside an active pin is a reader move. During
                // the bounded programmatic settle, FlatList may emit the same
                // offsets on its way to the tail and must not cancel itself.
                tailPinToken.current += 1;
              }
            }}
            ref={scroll}
            style={styles.scroller}
            // ponytail: if scroll sampling changes, keep tail release responsive
            // and update the focused scroll-policy tests with the new cadence.
            scrollEventThrottle={16}
            // ponytail: increasing this initial batch needs a measured first
            // paint; keep it at the initial client page cap so the first
            // scroll-to-tail has measured rows without rendering expansions.
            initialNumToRender={24}
            // ponytail: this remains an average-length fallback, not a claimed
            // fixed row layout. The list remeasures variable-height cells.
            initialScrollIndex={initialTimelineIndex.current.index}
            onScrollToIndexFailed={({ averageItemLength, index }) => {
              const offset = Math.max(0, averageItemLength * index);
              scheduleAnimationFrame(() => {
                if (offset > 0) scroll.current?.scrollToOffset({ animated: false, offset });
              }, session.id);
            }}
            // ponytail: raise this only with a measured fill-rate review; large
            // batches can block the composer while variable rows are measured.
            maxToRenderPerBatch={24}
            // ponytail: widen this only when fast scroll reveals blank rows; it
            // directly increases mounted cells around the current viewport.
            windowSize={3}
            // ponytail: keep clipping enabled for the 4,000-row retained cap;
            // disable only with a platform-specific focus/accessibility proof.
            removeClippedSubviews
            extraData={styles}
            keyExtractor={(row) => row.id}
            renderItem={renderChatTimelineRow(styles, (turnID, expanded) => {
              setTurnExpansionOverrides((current) => ({ ...current, [turnID]: expanded }));
            })}
            ListHeaderComponent={(
              <TimelineHeader
                hasMoreBefore={chat.page?.hasMoreBefore ?? false}
                historyLimitReached={chat.clientHistoryLimitReached ?? false}
                retainedCount={canonicalItems.length}
                onLoadEarlier={() => {
                  capturePrependAnchor();
                  chat.loadEarlier();
                }}
                styles={styles}
              />
            )}
            ListEmptyComponent={!timelineRows.length ? <Centered text="No visible Chat history" styles={styles} /> : undefined}
          />
          <Text
            accessibilityLabel="Chat timeline update"
            accessibilityLiveRegion="polite"
            nativeID={chatTimelineUpdateNativeID(session.id)}
            style={styles.timelineUpdate}
          >
            {chatTimelineUpdateSignal(canonicalItems)}
          </Text>
        </>
      )}

      {chat.error ? <Text accessibilityRole="alert" style={styles.errorBanner}>{chat.error}</Text> : null}
      {chat.recovery?.length ? (
        <RecoverySurface
          onDismiss={chat.dismissRecovery}
          onRetry={chat.retryRecovery}
          recovery={chat.recovery}
          styles={styles}
        />
      ) : null}
      {(() => {
        const cancellation = chatCancellationView(
          session.section,
          chat.canCancelForActiveDelivery ?? false,
          chat.cancel?.status,
        );
        const pendingActions = chat.page?.pendingActions
          ?? (chat.page?.pendingAction ? [chat.page.pendingAction] : []);
        return pendingActions.length > 0 ? (
        <View style={styles.actionSurface}>
          <View accessibilityLabel="Chat action rail" style={styles.actionRail}>
            {pendingActions.map((action, index) => (
              <PendingAction
                action={action}
                canRespond={action.type === "approval"
                  ? chat.page?.capabilities.canApprove === true
                  : chat.page?.capabilities.canAnswer === true}
                cancellation={index === 0 ? cancellation : undefined}
                onCancel={chat.cancelChat}
                key={action.approvalId ?? action.toolUseId}
                onRespond={chat.respond}
                source={session.source}
                styles={styles}
              />
            ))}
          </View>
        </View>
        ) : chat.page && chat.page.capabilities.canSendText === false
          && chat.page.capabilities.canSendImages === false ? (
          <ReadOnlyNotice reason={chat.page.capabilities.readOnlyReason} styles={styles} />
        ) : chat.page ? (
          <Composer
            key={session.id}
            canSendImages={chat.page.capabilities.canSendImages}
            canSendText={chat.page.capabilities.canSendText}
            maxTextBytes={chat.page.capabilities.maxTextBytes}
            metadata={chat.page.metadata}
            onDraftChange={chat.noteComposerDraft}
            onCancel={chat.cancelChat}
            cancellation={cancellation}
            canCyclePermissionMode={chat.page.capabilities.canCyclePermissionMode === true}
            onCycleMode={chat.cyclePermissionMode}
            cycleModeDisabled={chat.permissionModeCycle !== undefined}
            onResize={handleComposerResize}
            onRequestSlashCommands={chat.loadSlashCommands}
            onSend={sendChat}
            permissionModeOverride={chat.optimisticPermissionMode}
            recoveryCommand={chat.recoveryCommand}
            sessionId={session.id}
            session={session}
            slashCommands={chat.slashCommands}
            slashCommandsError={chat.slashCommandsError}
            slashCommandsTruncated={chat.slashCommandsTruncated}
            styles={styles}
          />
        ) : null;
      })()}
    </View>
  );
}

function renderChatTimelineRow(
  styles: ChatStyles,
  onToggleWork: (turnID: string, expanded: boolean) => void,
) {
  return ({ item: row }: ListRenderItemInfo<ChatTimelineRow>) => {
    if (row.type === "item") {
      return <View style={styles.rail}><Message item={row.item} styles={styles} /></View>;
    }
    if (row.type === "group-prompt") {
      return <View style={[styles.rail, styles.turnPrompt]}><Message item={row.item} styles={styles} /></View>;
    }
    if (row.type === "group-work-header") {
      return (
        <View style={[styles.rail, styles.work]}>
          <Pressable
            accessibilityLabel={`${row.expanded ? "Hide" : "Show"} ${row.count} work items`}
            onPress={() => onToggleWork(row.turnID, !row.expanded)}
            style={styles.workHeader}
          >
            <Text style={styles.workLabel}>{row.expanded ? "⌄" : "›"} {row.live ? "Working…" : `Worked · ${row.count} steps`}</Text>
          </Pressable>
        </View>
      );
    }
    if (row.type === "group-work-item") {
      return <View style={[styles.rail, styles.workItem]}><Message item={row.item} styles={styles} /></View>;
    }
    return <View style={[styles.rail, styles.turnAnswer]}><Message item={row.item} styles={styles} /></View>;
  };
}

function TimelineHeader({
  hasMoreBefore,
  historyLimitReached,
  onLoadEarlier,
  retainedCount,
  styles,
}: {
  hasMoreBefore: boolean;
  historyLimitReached: boolean;
  onLoadEarlier(): void;
  retainedCount: number;
  styles: ChatStyles;
}) {
  return (
    <View accessibilityLabel="Chat timeline rail" style={styles.rail}>
      <Text accessibilityLabel={`Chat history count: ${retainedCount} retained messages`} style={styles.historyCount}>
        Showing {retainedCount} retained messages
      </Text>
      {hasMoreBefore && !historyLimitReached ? (
        <Pressable accessibilityLabel="Load earlier messages" onPress={onLoadEarlier} style={styles.loadEarlier}>
          <Text style={styles.link}>Load earlier messages</Text>
        </Pressable>
      ) : null}
      {historyLimitReached ? (
        <View accessibilityLabel="Chat history display limit" style={styles.historyLimitSurface}>
          <Text style={styles.historyLimitText}>Chat history display limit reached. Older messages are not shown.</Text>
        </View>
      ) : null}
    </View>
  );
}

function chatTimelineNativeID(sessionID: string): string {
  return `chat-timeline-${encodeURIComponent(sessionID)}`;
}

function chatTimelineUpdateNativeID(sessionID: string): string {
  return `chat-timeline-update-${encodeURIComponent(sessionID)}`;
}

function chatTimelineUpdateSignal(items: ChatItem[]): string {
  const latest = items.at(-1);
  if (!latest) return `count:${items.length};latest:none`;
  const content = latest.kind === "tool"
    ? `${latest.name}:${latest.status}:${latest.result ?? ""}`
    : latest.text;
  // ponytail: keep the live-region payload bounded; the retained transcript is
  // already available through the virtualized rows and count status.
  const safeSuffix = content.replace(/[\\*_~`]/g, "").replace(/\s+/g, " ").slice(-128);
  return `count:${items.length};latest:${latest.id};${safeSuffix}`;
}

function Message({ item, styles }: { item: ChatItem; styles: ChatStyles }) {
  if (item.kind === "user") {
    return (
      <View
        accessibilityLabel={`User message: ${item.text || `${item.images.length} image${item.images.length === 1 ? "" : "s"}`}`}
        accessibilityRole="text"
        nativeID={messageNativeID(item.id)}
        style={styles.userRow}
      >
        <View style={styles.userBubble}>
          {item.images.map((image, index) => <ChatImageView image={image} key={`${image.name}-${index}`} styles={styles} />)}
          {item.text ? <RichMessageText styles={styles} text={item.text} /> : null}
        </View>
      </View>
    );
  }
  if (item.kind === "tool") return <Tool item={item} styles={styles} />;
  if (item.kind === "thinking") {
    return (
      <View
        accessibilityLabel={`Thinking: ${accessibleThinkingText(item.text)}`}
        accessibilityRole="text"
        nativeID={messageNativeID(item.id)}
        style={styles.thinking}
      >
        <RichMessageText
          styles={styles}
          text={item.text}
          tone="thinking"
        />
      </View>
    );
  }
  if (item.kind === "system") {
    return (
      <View
        accessibilityLabel={systemAccessibilityLabel(item)}
        accessibilityRole="text"
        nativeID={messageNativeID(item.id)}
        style={styles.systemRow}
      >
        <SystemMessage item={item} styles={styles} />
      </View>
    );
  }
  return (
    <View
      accessibilityLabel={`Assistant message: ${item.text}`}
      accessibilityRole="text"
      nativeID={messageNativeID(item.id)}
      style={styles.assistant}
    >
      <RichMessageText styles={styles} text={item.text} />
    </View>
  );
}

function RichMessageText({
  styles,
  text,
  tone = "body",
}: {
  styles: ChatStyles;
  text: string;
  tone?: "body" | "thinking";
}) {
  const document = parseChatRichText(text);
  return (
    <View style={styles.messageText}>
      {document.blocks.map((block, index) => (
        <RichBlockView key={`${block.kind}-${index}`} block={block} styles={styles} tone={tone} />
      ))}
    </View>
  );
}

function RichBlockView({ block, styles, tone }: {
  block: ChatRichBlock;
  styles: ChatStyles;
  tone: "body" | "thinking";
}) {
  if (block.kind === "code") {
    const tokens = tokenizeChatCode(block.text, block.language);
    return (
      <View accessibilityLabel={`Code block${block.language ? ` (${block.language})` : ""}`} style={styles.codeBlock}>
        {block.language ? <Text style={styles.codeLanguage}>{block.language}</Text> : null}
        <Text selectable style={styles.code}>
          {tokens.map((token, index) => (
            <Text key={`${token.kind}-${index}`} style={styles[`codeToken${token.kind[0]!.toUpperCase()}${token.kind.slice(1)}` as keyof ChatStyles]}>
              {token.text}
            </Text>
          ))}
        </Text>
      </View>
    );
  }
  if (block.kind === "table") {
    return (
      <View accessibilityLabel="Markdown table" style={styles.table}>
        <View style={styles.tableRow}>
          {block.header.map((cell, index) => <View key={`header-${index}`} style={styles.tableCell}><RichInlineText parts={cell} styles={styles} tone={tone} /></View>)}
        </View>
        {block.rows.map((row, rowIndex) => (
          <View key={`row-${rowIndex}`} style={styles.tableRow}>
            {row.map((cell, cellIndex) => <View key={`cell-${cellIndex}`} style={styles.tableCell}><RichInlineText parts={cell} styles={styles} tone={tone} /></View>)}
          </View>
        ))}
      </View>
    );
  }
  if (block.kind === "math") {
    return <ChatMath source={block.text} display styles={styles} />;
  }
  if (block.kind === "thematic-break") return <View accessibilityLabel="Markdown divider" style={styles.thematicBreak} />;
  if (block.kind === "list") {
    return (
      <View style={styles.list}>
        {block.items.map((parts, index) => (
          <View key={index} style={styles.listItem}>
            <Text style={styles.listMarker}>{block.ordered ? `${index + 1}.` : "•"}</Text>
            <RichInlineText parts={parts} styles={styles} tone={tone} />
          </View>
        ))}
      </View>
    );
  }
  const style = block.kind === "heading"
    ? [styles.body, styles.heading, tone === "thinking" && styles.thinkingText]
    : block.kind === "blockquote"
      ? [styles.body, styles.blockquote, tone === "thinking" && styles.thinkingText]
      : [styles.body, tone === "thinking" && styles.thinkingText];
  return <Text selectable style={style}><RichInlineText parts={block.inlines} styles={styles} tone={tone} /></Text>;
}

function ChatMath({ source, display = false, styles }: { source: string; display?: boolean; styles: ChatStyles }) {
  const presentation = presentChatMath(source, display);
  if (presentation.mathML && typeof document !== "undefined") {
    if (!display) {
      return createElement("span", {
        "aria-label": `Formula: ${source}`,
        dangerouslySetInnerHTML: { __html: presentation.mathML },
        role: "math",
      });
    }
    return (
      <View accessibilityLabel={`Formula: ${source}`} accessibilityRole="image" style={styles.mathBlock}>
        {createElement("span", {
          "aria-label": `Formula: ${source}`,
          dangerouslySetInnerHTML: { __html: presentation.mathML },
          role: "math",
        })}
      </View>
    );
  }
  return <Text accessibilityLabel={`Formula: ${source}`} selectable style={display ? styles.math : styles.inlineMath}>{source}</Text>;
}

function RichInlineText({
  parts,
  styles,
  tone,
}: {
  parts: ChatRichInline[];
  styles: ChatStyles;
  tone: "body" | "thinking";
}) {
  return (
    <Text selectable style={[styles.inlineFlow, tone === "thinking" && styles.thinkingText]}>
      {parts.map((part, index) => {
    if (part.kind === "strong") return <Text key={index} style={styles.bold}>{part.text}</Text>;
    if (part.kind === "emphasis") return <Text key={index} style={styles.emphasis}>{part.text}</Text>;
    if (part.kind === "strike") return <Text key={index} style={styles.strike}>{part.text}</Text>;
    if (part.kind === "code") return <Text key={index} style={styles.inlineCode}>{part.text}</Text>;
    if (part.kind === "math") return <ChatMath key={index} source={part.text} styles={styles} />;
    if (part.kind === "link") {
      const href = safeChatLink(part.href);
      return href ? (
        <Text
          accessibilityLabel={`Link: ${part.text}`}
          accessibilityRole="link"
          key={index}
          onPress={() => openChatLink(href)}
          style={styles.chatLink}
        >
          {part.text}
        </Text>
      ) : <Text key={index}>{part.text}</Text>;
    }
    if (part.kind === "local-reference") {
      const reference = chatLocalReference(part.href, part.text);
      if (!reference) return <Text key={index}>{part.text}</Text>;
      return (
        <LocalReference
          key={index}
          label={reference.label}
          path={reference.path}
          styles={styles}
          textStyle={styles.localReference}
        />
      );
    }
    return <Text key={index} style={tone === "thinking" ? styles.thinkingText : undefined}>{part.text}</Text>;
      })}
    </Text>
  );
}

function Tool({ item, styles }: { item: Extract<ChatItem, { kind: "tool" }>; styles: ChatStyles }) {
  const [expanded, setExpanded] = useState(item.status === "error" || item.status === "waiting");
  const presentation = chatToolPresentation(item);
  return (
    <View accessibilityLabel={`Tool ${item.name}: ${item.status}`} nativeID={messageNativeID(item.id)} style={styles.tool}>
      <Pressable accessibilityLabel={`${expanded ? "Hide" : "Show"} details for ${item.name}`} onPress={() => setExpanded((value) => !value)} style={styles.toolHeader}>
        <Text style={[styles.toolStatus, item.status === "error" && styles.errorText]}>{toolGlyph(item.status)}</Text>
        <Text style={styles.toolName}>{item.name}</Text>
        <Text numberOfLines={1} style={styles.toolSummary}>{toolSummary(item.input)}</Text>
        <Text style={styles.toolChevron}>{expanded ? "⌄" : "›"}</Text>
      </Pressable>
      {expanded ? (
        <ToolDetail item={item} presentation={presentation} styles={styles} />
      ) : null}
    </View>
  );
}

function ToolDetail({
  item,
  presentation,
  styles,
}: {
  item: Extract<ChatItem, { kind: "tool" }>;
  presentation: ReturnType<typeof chatToolPresentation>;
  styles: ChatStyles;
}) {
  if (presentation.kind === "plan") {
    return (
      <View accessibilityLabel="Plan" style={styles.planCard}>
        <Text style={styles.planTitle}>{presentation.title}</Text>
        {presentation.filePath ? <LocalPath path={presentation.filePath} styles={styles} textStyle="planPath" /> : null}
        {presentation.text ? <RichMessageText styles={styles} text={presentation.text} /> : <Text style={styles.muted}>No plan content available.</Text>}
      </View>
    );
  }
  if (presentation.kind === "edit") {
    return (
      <View accessibilityLabel="Edit hunk" style={styles.editCard}>
        {presentation.filePath ? <LocalPath path={presentation.filePath} styles={styles} textStyle="editPath" /> : null}
        {presentation.oldText ? <Text selectable style={styles.diffRemoved}>{`- ${presentation.oldText}`}</Text> : null}
        {presentation.newText ? <Text selectable style={styles.diffAdded}>{`+ ${presentation.newText}`}</Text> : null}
      </View>
    );
  }
  return (
    <View style={styles.toolDetail}>
      <Text selectable style={styles.code}>{presentation.inputText}</Text>
      {presentation.resultText ? (
        <RichMessageText styles={styles} text={presentation.resultText} tone={item.status === "error" ? "thinking" : "body"} />
      ) : null}
    </View>
  );
}

function LocalPath({
  path,
  styles,
  textStyle,
}: {
  path: string;
  styles: ChatStyles;
  textStyle: "planPath" | "editPath";
}) {
  const reference = chatLocalReference(path);
  if (!reference) return <Text selectable style={styles[textStyle]}>{path}</Text>;
  return (
    <LocalReference
      label={reference.label}
      path={reference.path}
      styles={styles}
      textStyle={styles[textStyle]}
    />
  );
}

function LocalReference({
  label,
  path,
  styles,
  textStyle,
}: {
  label: string;
  path: string;
  styles: ChatStyles;
  textStyle: TextStyle;
}) {
  const [revealed, setRevealed] = useState(false);
  const toggle = () => setRevealed((value) => !value);
  return createElement(Text, {
    accessibilityHint: revealed ? "Press to hide the full local path." : "Press to reveal the full local path; the revealed text can be copied.",
    accessibilityLabel: "Local file reference: " + path,
    accessibilityRole: "button",
    accessibilityState: { expanded: revealed },
    onKeyDown: (event: { key: string; preventDefault(): void }) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      toggle();
    },
    onPress: toggle,
    selectable: true,
    style: [textStyle, revealed && styles.localReferenceFull],
  } as never, revealed ? path : label);
}

function SystemMessage({
  item,
  styles,
}: {
  item: Extract<ChatItem, { kind: "system" }>;
  styles: ChatStyles;
}) {
  if (item.category === "compact_boundary") {
    return (
      <View accessibilityLabel="Conversation compacted" style={styles.compactBoundary}>
        <View style={styles.thematicBreak} />
        <Text selectable style={styles.system}>{item.text}</Text>
      </View>
    );
  }
  if (item.category === "recap") {
    return <Text selectable style={[styles.system, styles.recap]}>※ recap: {item.text}</Text>;
  }
  if (item.category === "local_command_output") {
    return <Text selectable style={[styles.system, styles.localCommand]}>⎿ {item.text}</Text>;
  }
  if (item.category === "turn_duration") {
    return <Text selectable style={styles.duration}>✻ {item.text}</Text>;
  }
  return <Text selectable style={[styles.system, item.tone === "error" && styles.errorText]}>{item.text}</Text>;
}

function systemAccessibilityLabel(item: Extract<ChatItem, { kind: "system" }>): string {
  switch (item.category) {
    case "compact_boundary": return `Conversation compacted: ${item.text}`;
    case "recap": return `Recap: ${item.text}`;
    case "turn_duration": return `Turn duration: ${item.text}`;
    case "local_command_output": return `Command output: ${item.text}`;
    default: return item.text;
  }
}

function openChatLink(href: string): void {
  if (typeof window === "undefined") return;
  const safe = safeChatLink(href);
  if (!safe) return;
  void window.agentVisor?.openExternal(safe).catch(() => undefined);
}

function messageNativeID(id: string): string {
  return `chat-item-${encodeURIComponent(id)}`;
}

function chatItemContentChanged(previous: ChatItem, next: ChatItem): boolean {
  if (previous.id !== next.id || previous.kind !== next.kind) return true;
  if (previous.kind === "user" && next.kind === "user") {
    return previous.text !== next.text
      || previous.images.length !== next.images.length
      || previous.images.some((image, index) => {
        const other = next.images[index];
        return image.name !== other?.name
          || image.mimeType !== other?.mimeType
          || image.data !== other?.data;
      });
  }
  if (previous.kind === "tool" && next.kind === "tool") {
    return previous.name !== next.name
      || previous.status !== next.status
      || previous.result !== next.result;
  }
  if ("text" in previous && "text" in next) return previous.text !== next.text;
  return false;
}

function ChatImageView({ image, styles }: { image: ChatImage; styles: ChatStyles }) {
  const uri = historyImageDataURI(image);
  return uri ? (
    <Image accessibilityLabel={image.name} accessibilityRole="image" source={{ uri }} style={styles.image as ImageStyle} />
  ) : (
    <Text accessibilityLabel={`Image unavailable: ${image.name}`} accessibilityRole="text" style={styles.muted}>
      Image unavailable: {image.name}
    </Text>
  );
}

function RecoverySurface({
  onDismiss,
  onRetry,
  recovery,
  styles,
}: {
  onDismiss(recoveryId: string): void;
  onRetry(recoveryId: string): void;
  recovery: ChatDeliveryRecoveryRecord[];
  styles: ChatStyles;
}) {
  return (
    <View accessibilityLabel="Chat delivery recovery" style={styles.recoverySurface}>
      <View accessibilityLabel="Chat delivery recovery rail" style={styles.recoveryRail}>
        {recovery.map((record) => {
          const view = chatRecoveryView(record);
          return (
            <View
              accessibilityLabel={view.accessibilityLabel}
              key={record.id}
              nativeID={`chat-recovery-${encodeURIComponent(record.id)}`}
              style={styles.recoveryCard}
            >
              <Text style={[styles.recoveryTitle, record.status !== "canceled" && styles.errorText]}>{view.title}</Text>
              <Text accessibilityRole="alert" selectable style={styles.recoveryReason}>{view.reason}</Text>
              {view.attachmentsLabel ? <Text style={styles.recoveryAttachments}>{view.attachmentsLabel}</Text> : null}
              <View style={styles.recoveryActions}>
                <ActionButton
                  disabled={!view.retryEnabled}
                  label={view.retryLabel}
                  onPress={() => onRetry(record.id)}
                  styles={styles}
                />
                <ActionButton
                  disabled={!view.dismissEnabled}
                  label={view.dismissLabel}
                  onPress={() => onDismiss(record.id)}
                  styles={styles}
                />
              </View>
            </View>
          );
        })}
      </View>
    </View>
  );
}

function PendingAction({
  action,
  canRespond,
  cancellation,
  onRespond,
  onCancel,
  source,
  styles,
}: {
  action: ChatPendingAction;
  canRespond: boolean;
  cancellation?: ChatCancellationView;
  onRespond(message: Parameters<ReturnType<typeof useChat>["respond"]>[0]): void;
  onCancel?(): boolean;
  source: string;
  styles: ChatStyles;
}) {
  const [localResponding, setResponding] = useState(false);
  const responding = localResponding || action.responding === true;
  const enabled = canRespond && !responding;
  const respondOnce = (message: Parameters<typeof onRespond>[0]) => {
    if (!enabled) return;
    setResponding(true);
    onRespond(message);
  };
  useEffect(() => {
    if (!enabled || typeof window === "undefined") return undefined;
    const handleEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      const approvalId = pendingChatActionIdentity(action);
      respondOnce({
        type: "respond_chat",
        toolUseId: action.toolUseId,
        approvalId,
        decision: "deny",
        reason: "Canceled by user",
      });
    };
    // Capture before Chat's navigation listener so an action's exact pending
    // identity owns Escape and the page cannot navigate away underneath it.
    window.addEventListener("keydown", handleEscape, true);
    return () => window.removeEventListener("keydown", handleEscape, true);
  }, [action, enabled]);
  if (action.type === "question") {
    return <QuestionAction action={action} canRespond={canRespond} cancellation={cancellation} onCancel={onCancel} onRespond={respondOnce} responding={responding} source={source} styles={styles} />;
  }
  const approvalId = pendingChatActionIdentity(action);
  return (
    <View
      accessibilityLabel={`Approval ${approvalId}`}
      style={styles.actionPanel}
    >
      <Text style={styles.actionTitle}>Approve {action.toolName}?</Text>
      <Text accessibilityLabel={chatActionTitle(action, source)} style={styles.actionContext}>{source} · approval {approvalId}</Text>
      <Text selectable style={styles.code}>{JSON.stringify(action.input, null, 2)}</Text>
      {!canRespond ? <Text accessibilityRole="alert" style={styles.actionUnavailable}>This approval is not available from this Chat surface.</Text> : null}
      <View style={styles.actionButtons}>
        <ActionButton disabled={!enabled} label="Deny" onPress={() => respondOnce({ type: "respond_chat", toolUseId: action.toolUseId, approvalId, decision: "deny" })} styles={styles} />
        <ActionButton disabled={!enabled} label="Allow" onPress={() => respondOnce({ type: "respond_chat", toolUseId: action.toolUseId, approvalId, decision: "allow" })} styles={styles} />
        {action.canPersist ? <ActionButton disabled={!enabled} label="Always allow" onPress={() => respondOnce({ type: "respond_chat", toolUseId: action.toolUseId, approvalId, decision: "allow_always" })} styles={styles} /> : null}
        {cancellation?.visible && onCancel ? <CancellationButton cancellation={cancellation} onCancel={onCancel} primary={!enabled} styles={styles} /> : null}
      </View>
      {responding ? <Text accessibilityLiveRegion="polite" style={styles.cancelStatus}>Responding…</Text> : null}
    </View>
  );
}

function QuestionAction({
  action,
  canRespond,
  cancellation,
  onCancel,
  onRespond,
  responding,
  source,
  styles,
}: {
  action: Extract<ChatPendingAction, { type: "question" }>;
  canRespond: boolean;
  cancellation?: ChatCancellationView;
  onCancel?(): boolean;
  onRespond(message: Parameters<ReturnType<typeof useChat>["respond"]>[0]): void;
  responding: boolean;
  source: string;
  styles: ChatStyles;
}) {
  const [answers, setAnswers] = useState<Record<string, string | string[]>>({});
  const [errors, setErrors] = useState<string[]>([]);
  const enabled = canRespond && !responding;
  const submit = () => {
    if (!enabled) return;
    const normalized = normalizeQuestionAnswers(action, answers);
    const validation = validateQuestionAnswers(action, normalized);
    if (validation.length) {
      setErrors(validation);
      return;
    }
    setErrors([]);
    onRespond({
      type: "respond_chat",
      toolUseId: action.toolUseId,
      approvalId: pendingChatActionIdentity(action),
      decision: "answer",
      answers: normalized,
    });
  };
  const cancel = () => {
    if (!enabled) return;
    setErrors([]);
    onRespond({
      type: "respond_chat",
      toolUseId: action.toolUseId,
      approvalId: pendingChatActionIdentity(action),
      decision: "deny",
      reason: "Canceled by user",
    });
  };
  return (
    <View
      accessibilityLabel={`Question ${pendingChatActionIdentity(action)}`}
      style={styles.actionPanel}
    >
      <Text style={styles.actionTitle}>{chatActionTitle(action, source)}</Text>
      {action.questions.map((question) => (
        <View accessibilityLabel={`Question: ${question.question}`} key={question.id} style={styles.question}>
          <Text style={styles.actionTitle}>{question.question}</Text>
          {question.choices.length ? question.choices.map((choice) => {
            const selected = question.multiple
              ? (answers[question.id] as string[] | undefined)?.includes(choice)
              : answers[question.id] === choice;
            return (
              <Pressable
                accessibilityLabel={`${selected ? "Selected" : "Select"} ${choice}`}
                accessibilityRole="radio"
                accessibilityState={{ checked: selected, disabled: !enabled }}
                disabled={!enabled}
                key={choice}
                onPress={() => {
                  setErrors([]);
                  setAnswers((current) => ({
                    ...current,
                    [question.id]: question.multiple
                      ? toggleChoice(current[question.id], choice)
                      : choice,
                  }));
                }}
                style={[styles.choice, selected && styles.choiceSelected]}
              >
                <Text style={styles.body}>{selected ? "●" : "○"} {choice}</Text>
              </Pressable>
            );
          }) : (
            <TextInput
              accessibilityLabel={`Answer ${question.question}`}
              editable={enabled}
              onChangeText={(text) => setAnswers((current) => ({ ...current, [question.id]: text }))}
              style={styles.answerInput}
              value={answers[question.id] as string | undefined}
            />
          )}
        </View>
      ))}
      {errors.length ? (
        <View accessibilityLabel="Question validation errors" accessibilityRole="alert" style={styles.validationErrors}>
          {errors.map((error) => <Text key={error} style={styles.validationError}>{error}</Text>)}
        </View>
      ) : null}
      <View style={styles.actionButtons}>
        <ActionButton label="Cancel" disabled={!enabled} onPress={cancel} styles={styles} />
        <ActionButton label="Submit answers" disabled={!enabled} onPress={submit} styles={styles} />
        {cancellation?.visible && onCancel ? <CancellationButton cancellation={cancellation} onCancel={onCancel} primary={!enabled} styles={styles} /> : null}
      </View>
      {responding ? <Text accessibilityLiveRegion="polite" style={styles.cancelStatus}>Responding…</Text> : !canRespond ? <Text accessibilityRole="alert" style={styles.actionUnavailable}>This question is not available from this Chat surface.</Text> : null}
    </View>
  );
}

function ReadOnlyNotice({ reason, styles }: { reason?: string; styles: ChatStyles }) {
  return (
    <View accessibilityLabel="Chat read-only notice" style={styles.readOnlySurface}>
      <View style={styles.readOnlyRail}>
        <Text accessibilityLabel={reason ?? "This conversation is read only."} style={styles.readOnlyNotice}>
          {reason ?? "This conversation is read only."}
        </Text>
      </View>
    </View>
  );
}

export function Composer({
  canSendImages,
  canSendText,
  canCyclePermissionMode,
  cancellation,
  maxTextBytes,
  metadata,
  onCancel,
  onDraftChange,
  onCycleMode,
  cycleModeDisabled = false,
  onResize,
  onRequestSlashCommands,
  onSend,
  permissionModeOverride,
  recoveryCommand,
  sessionId,
  session,
  slashCommands,
  slashCommandsError,
  slashCommandsTruncated,
  styles,
}: {
  canSendImages: boolean;
  canSendText: boolean;
  canCyclePermissionMode: boolean;
  cancellation: ChatCancellationView;
  maxTextBytes?: number;
  metadata?: ChatMetadata;
  onCancel(): boolean;
  onDraftChange?(draft: { text: string; images: ChatImage[] }): void;
  onCycleMode?(): boolean;
  cycleModeDisabled?: boolean;
  onResize?(): void;
  onRequestSlashCommands(): void;
  onSend(text: string, images: ChatImage[]): boolean | void;
  permissionModeOverride?: string;
  recoveryCommand?: ComposerRecoveryCommand;
  sessionId: string;
  session: SessionSummary;
  slashCommands?: ChatSlashCommand[];
  slashCommandsError?: string;
  slashCommandsTruncated?: boolean;
  styles: ChatStyles;
}) {
  const [draft, setDraft] = useState<ComposerDraft>(() => composerDraftStore.load(sessionId));
  const [validationErrors, setValidationErrors] = useState<string[]>([]);
  const [layout, setLayout] = useState(() => composerLayoutForContent({
    contentHeight: COMPOSER_MIN_HEIGHT,
    lineHeight: COMPOSER_DEFAULT_LINE_HEIGHT,
    verticalPadding: COMPOSER_VERTICAL_PADDING,
  }));
  const [selectedSlashIndex, setSelectedSlashIndex] = useState(0);
  const [dismissedSlashQuery, setDismissedSlashQuery] = useState<string | undefined>(undefined);
  const attachmentOperations = useRef(createComposerAttachmentOperations(composerDraftStore)).current;
  const inputId = `chat-composer-input-${encodeURIComponent(sessionId)}`;
  const draftRef = useRef(draft);
  const submitRef = useRef<() => void>(() => undefined);
  const acceptSlashRef = useRef<(index?: number) => void>(() => undefined);
  const clearDraftRef = useRef<() => void>(() => undefined);
  const draftRevisionRef = useRef(0);
  const appliedRecoveryCommandRef = useRef<string | undefined>(undefined);
  const statusMetadata = permissionModeOverride
    ? { ...(metadata ?? {}), permissionMode: permissionModeOverride }
    : metadata;
  const composerContext = chatStatusSummary(session, statusMetadata, {
    canSendText,
  });

  draftRef.current = draft;
  const commitDraft = (nextOrUpdate: ComposerDraft | ((current: ComposerDraft) => ComposerDraft)) => {
    const next = typeof nextOrUpdate === "function"
      ? nextOrUpdate(draftRef.current)
      : nextOrUpdate;
    draftRef.current = next;
    composerDraftStore.save(sessionId, next);
    setDraft(next);
    draftRevisionRef.current += 1;
    onDraftChange?.(composerDraftToSubmitted(next));
  };

  const query = slashQuery(draft.text);
  const slashSuggestions = query !== undefined && slashCommands
    ? filterSlashCommands(query, slashCommands)
    : [];
  const slashOpen = query !== undefined
    && query !== dismissedSlashQuery
    && (slashSuggestions.length > 0 || Boolean(slashCommandsError) || Boolean(slashCommandsTruncated));

  useEffect(() => {
    composerDraftStore.save(sessionId, draft);
  }, [draft, sessionId]);

  useEffect(() => {
    if (!onDraftChange) return;
    draftRevisionRef.current += 1;
    onDraftChange(composerDraftToSubmitted(draftRef.current));
  }, [onDraftChange, sessionId]);

  useEffect(() => {
    const command = recoveryCommand;
    if (!command || appliedRecoveryCommandRef.current === command.id) return;
    appliedRecoveryCommandRef.current = command.id;
    const result = applyComposerRecoveryCommand(
      composerDraftStore,
      sessionId,
      draftRef.current,
      draftRevisionRef.current,
      command,
    );
    if (result.status !== "applied") return;
    draftRef.current = result.draft;
    setDraft(result.draft);
    setValidationErrors([]);
    setDismissedSlashQuery(undefined);
    setSelectedSlashIndex(0);
    draftRevisionRef.current += 1;
    onDraftChange?.(composerDraftToSubmitted(result.draft));
  }, [onDraftChange, recoveryCommand, sessionId]);

  useEffect(() => () => attachmentOperations.cancel(sessionId), [attachmentOperations, sessionId]);

  useEffect(() => {
    if (query !== dismissedSlashQuery) setDismissedSlashQuery(undefined);
    if (!slashSuggestions.length) {
      setSelectedSlashIndex(0);
    } else if (selectedSlashIndex >= slashSuggestions.length) {
      setSelectedSlashIndex(0);
    }
  }, [query, dismissedSlashQuery, selectedSlashIndex, slashSuggestions.length]);

  useEffect(() => {
    if (query !== undefined && slashCommands === undefined && !slashCommandsError) onRequestSlashCommands();
  }, [onRequestSlashCommands, query, slashCommands, slashCommandsError]);

  const updateMeasuredHeight = () => {
    if (typeof document === "undefined") return;
    const input = document.getElementById(inputId);
    if (!input) return;
    const element = input as HTMLTextAreaElement;
    const computed = getComputedStyle(element);
    const lineHeight = Number.parseFloat(computed.lineHeight) || COMPOSER_DEFAULT_LINE_HEIGHT;
    const padding = (Number.parseFloat(computed.paddingTop) || 0)
      + (Number.parseFloat(computed.paddingBottom) || 0);
    const assignedHeight = element.style.height;
    element.style.height = "0px";
    const contentHeight = element.scrollHeight;
    element.style.height = assignedHeight;
    const nextLayout = composerLayoutForContent({
      contentHeight,
      lineHeight,
      verticalPadding: padding || COMPOSER_VERTICAL_PADDING,
    });
    setLayout((current) => current.height === nextLayout.height
      && current.maxHeight === nextLayout.maxHeight
      && current.visualLineCount === nextLayout.visualLineCount
      && current.scrollable === nextLayout.scrollable
      ? current
      : nextLayout);
  };

  useLayoutEffect(() => {
    if (typeof document === "undefined") return;
    const frame = requestAnimationFrame(updateMeasuredHeight);
    return () => cancelAnimationFrame(frame);
  }, [draft.text, inputId, styles.composerInput]);

  const submit = () => {
    const textError = validateComposerText(draftRef.current.text, maxTextBytes);
    if (textError) {
      setValidationErrors([textError.message]);
      return;
    }
    const submission = draftSubmission(draftRef.current, maxTextBytes);
    if (!submission) return;
    if ((submission.text && !canSendText) || (submission.images.length && !canSendImages)) {
      setValidationErrors([
        submission.text && !canSendText
          ? "Text messages are unavailable from this Chat surface."
          : "Image attachments are unavailable from this Chat surface.",
      ]);
      return;
    }
    const previousDraft = {
      text: draftRef.current.text,
      images: draftRef.current.images.map((image) => ({ ...image })),
    };
    attachmentOperations.cancel(sessionId);
    commitDraft({ text: "", images: [] });
    const accepted = onSend(
      submission.text,
      submission.images.map(({ id: _id, ...image }) => image),
    );
    if (accepted === false) commitDraft(previousDraft);
    setValidationErrors([]);
    setDismissedSlashQuery(undefined);
  };
  submitRef.current = submit;

  const acceptSlash = (index = selectedSlashIndex) => {
    const command = slashSuggestions[index];
    if (!command) return;
    commitDraft((current) => ({ ...current, text: `/${command.name} ` }));
    setDismissedSlashQuery(undefined);
    setSelectedSlashIndex(0);
  };
  acceptSlashRef.current = acceptSlash;

  const appendFiles = async (
    files: File[],
    operation = attachmentOperations.begin(sessionId),
  ) => {
    const preflight = preflightComposerFiles(files, draftRef.current.images.length);
    const candidates: ComposerAttachmentCandidate[] = [];
    const readErrors: string[] = [];
    for (const file of preflight.accepted) {
      try {
        candidates.push({
          name: file.name || "image",
          mimeType: file.type,
          byteLength: file.size,
          data: await fileData(file),
        });
      } catch {
        readErrors.push(`${file.name || "Image"}: the image could not be read.`);
      }
    }
    const result = attachmentOperations.complete(operation, candidates);
    if (!result) return;
    commitDraft(result.draft);
    setValidationErrors([
      ...preflight.errors.map(({ message }) => message),
      ...readErrors,
      ...result.errors.map(({ message }) => message),
    ]);
  };
  const appendCandidates = (
    candidates: ComposerAttachmentCandidate[],
    operation = attachmentOperations.begin(sessionId),
  ) => {
    const result = attachmentOperations.complete(operation, candidates);
    if (!result) return;
    commitDraft(result.draft);
    setValidationErrors(result.errors.map(({ message }) => message));
  };
  const clearDraft = () => {
    attachmentOperations.cancel(sessionId);
    commitDraft({ text: "", images: [] });
    setValidationErrors([]);
    setDismissedSlashQuery(undefined);
    setSelectedSlashIndex(0);
  };
  clearDraftRef.current = clearDraft;

  useLayoutEffect(() => {
    if (typeof document === "undefined") return;
    const input = document.getElementById(inputId);
    if (!input) return;
    const keyDown = (event: KeyboardEvent) => {
      const action = composerKeyAction({
        key: event.key,
        shiftKey: event.shiftKey,
        isComposing: event.isComposing,
        keyCode: event.keyCode,
      });
      if (slashOpen && slashSuggestions.length && event.key === "ArrowUp") {
        event.preventDefault();
        setSelectedSlashIndex((index) => (index - 1 + slashSuggestions.length) % slashSuggestions.length);
        return;
      }
      if (slashOpen && slashSuggestions.length && event.key === "ArrowDown") {
        event.preventDefault();
        setSelectedSlashIndex((index) => (index + 1) % slashSuggestions.length);
        return;
      }
      if (slashOpen && event.key === "Tab" && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        acceptSlashRef.current();
        return;
      }
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        if (composerEscapeAction(slashOpen) === "close_suggestions") {
          setDismissedSlashQuery(query);
        } else {
          clearDraftRef.current();
        }
        return;
      }
      if (action === "submit") {
        event.preventDefault();
        event.stopPropagation();
        submitRef.current();
      }
      // Shift+Enter deliberately falls through to the textarea default so
      // the browser inserts a newline while retaining the current draft.
    };
    const paste = async (event: ClipboardEvent) => {
      if (!canSendImages) return;
      if (!hasComposerPastePayload(event.clipboardData)) return;
      const pasteInput = input as HTMLTextAreaElement;
      const pasteSnapshot = createComposerPasteSnapshot(sessionId, draftRef.current, {
        value: pasteInput.value,
        selectionStart: pasteInput.selectionStart,
        selectionEnd: pasteInput.selectionEnd,
      });
      event.preventDefault();
      const operation = attachmentOperations.begin(sessionId);
      const pasteResult = await extractComposerPaste(
        event.clipboardData,
        (url) => window.agentVisor?.readImageFile?.(url) ?? Promise.resolve(undefined),
      );
      if (pasteResult.files.length) void appendFiles(pasteResult.files, operation);
      if (pasteResult.urlCandidates.length) {
        appendCandidates(pasteResult.urlCandidates, operation);
        return;
      }
      if (pasteResult.files.length) return;
      const completed = attachmentOperations.complete(operation, []);
      if (!completed || pasteResult.fallbackText === undefined) return;
      const element = document.getElementById(inputId) as HTMLTextAreaElement | null;
      if (!element) return;
      if (!composerPasteSnapshotIsCurrent(pasteSnapshot, sessionId, draftRef.current, {
        value: element.value,
        selectionStart: element.selectionStart,
        selectionEnd: element.selectionEnd,
      })) {
        setValidationErrors([COMPOSER_PASTE_CANCELED_MESSAGE]);
        return;
      }
      const insertion = insertComposerTextAtSelection(
        element.value,
        pasteResult.fallbackText,
        element.selectionStart,
        element.selectionEnd,
      );
      const textError = validateComposerText(insertion.value, maxTextBytes);
      if (textError) {
        setValidationErrors([textError.message]);
        return;
      }
      commitDraft((current) => ({ ...current, text: insertion.value }));
      requestAnimationFrame(() => {
        const current = document.getElementById(inputId) as HTMLTextAreaElement | null;
        if (!current) return;
        current.setSelectionRange(insertion.selectionStart, insertion.selectionEnd);
        current.focus();
      });
    };
    input.addEventListener("keydown", keyDown);
    input.addEventListener("paste", paste);
    return () => {
      input.removeEventListener("keydown", keyDown);
      input.removeEventListener("paste", paste);
    };
  }, [attachmentOperations, canSendImages, inputId, maxTextBytes, query, sessionId, slashCommandsError, slashCommandsTruncated, slashOpen, slashSuggestions.length]);

  useEffect(() => {
    if (!canSendText || typeof document === "undefined") return;
    const frame = requestAnimationFrame(() => document.getElementById(inputId)?.focus());
    return () => cancelAnimationFrame(frame);
  }, [canSendText, inputId]);

  const addPickedImages = () => {
    const operation = attachmentOperations.begin(sessionId);
    void pickImages().then((files) => appendFiles(files, operation));
  };

  if (!canSendText && !canSendImages) {
    return null;
  }

  const submission = draftSubmission(draft, maxTextBytes);
  const canSendDraft = Boolean(submission
    && (!submission.text || canSendText)
    && (!submission.images.length || canSendImages));

  return (
    <View onLayout={onResize} style={styles.composerSurface}>
      <View accessibilityLabel="Chat composer rail" style={styles.composerRailContainer}>
        <View accessibilityLabel="Chat composer" style={styles.composerRail}>
        {slashOpen ? (
          <View accessibilityLabel="Slash command suggestions" style={styles.slashPopover}>
            <ScrollView keyboardShouldPersistTaps="handled" style={styles.slashScroller}>
              {slashSuggestions.map((command, index) => (
                <Pressable
                  accessibilityLabel={`Slash command /${command.name}`}
                  key={`${command.source}-${command.name}`}
                  onPress={() => {
                    setSelectedSlashIndex(index);
                    acceptSlashRef.current(index);
                  }}
                  style={[styles.slashRow, index === selectedSlashIndex && styles.slashRowSelected]}
                >
                  <Text style={styles.slashName}>/{command.name}</Text>
                  {command.argumentHint ? <Text style={styles.slashHint}>{command.argumentHint}</Text> : null}
                  <Text numberOfLines={1} style={styles.slashDescription}>{command.description}</Text>
                  {command.source !== "builtin" ? <Text style={styles.slashSource}>{command.sourceLabel ?? command.source}</Text> : null}
                </Pressable>
              ))}
              {slashCommandsTruncated ? (
                <Text accessibilityLabel="Slash command discovery limit reached" style={styles.slashTruncation}>
                  Command discovery limit reached — some commands may be unavailable.
                </Text>
              ) : null}
              {slashCommandsError ? (
                <Text accessibilityLabel="Slash command error" accessibilityRole="alert" style={styles.slashTruncation}>
                  Unable to load slash commands: {slashCommandsError}
                </Text>
              ) : null}
            </ScrollView>
          </View>
        ) : null}
        {draft.images.length ? (
          <ScrollView accessibilityLabel="Attached images" contentContainerStyle={styles.attachmentStrip} horizontal>
            {draft.images.map((image) => (
              <View key={image.id} style={styles.attachmentPreview}>
                <Image accessibilityLabel={`Attached image ${image.name}`} source={{ uri: image.data ? `data:${image.mimeType};base64,${image.data}` : undefined }} style={styles.attachmentImage as ImageStyle} />
                <Pressable accessibilityLabel={`Remove image ${image.name}`} onPress={() => commitDraft((current) => removeComposerAttachment(current, image.id))} style={styles.removeAttachment}>
                  <Text style={styles.removeAttachmentText}>×</Text>
                </Pressable>
              </View>
            ))}
          </ScrollView>
        ) : null}
        {validationErrors.length ? (
          <View accessibilityLabel="Composer validation errors" accessibilityRole="alert" style={styles.validationErrors}>
            {validationErrors.map((error, index) => <Text key={`${error}-${index}`} style={styles.validationError}>{error}</Text>)}
          </View>
        ) : null}
        <TextInput
          accessibilityLabel="Chat message"
          accessibilityHint={maxTextBytes
            ? `Maximum ${maxTextBytes.toLocaleString()} UTF-8 bytes for this terminal`
            : undefined}
          editable={canSendText}
          multiline
          maxLength={COMPOSER_MAX_TEXT_LENGTH}
          nativeID={inputId}
          onChangeText={(value) => {
            const textError = validateComposerText(value, maxTextBytes);
            if (textError) {
              setValidationErrors([textError.message]);
              return;
            }
            commitDraft((current) => ({ ...current, text: value }));
            setValidationErrors([]);
          }}
          onLayout={updateMeasuredHeight}
          placeholder={canSendText ? "Message agent…" : "Text messages are unavailable"}
          placeholderTextColor={styles.composerPlaceholder.color}
          scrollEnabled={layout.scrollable}
          style={[styles.composerInput, {
            height: layout.height,
            maxHeight: layout.maxHeight,
            overflowY: layout.scrollable ? "auto" : "hidden",
          } as unknown as TextStyle]}
          value={draft.text}
        />
        <View accessibilityLabel="Chat composer actions" style={styles.composerToolbar}>
          <View style={styles.composerLeadingActions}>
            {canSendImages ? <ComposerIconButton label="Add image" onPress={addPickedImages} styles={styles}>+</ComposerIconButton> : null}
            {composerContext.permission ? (
              onCycleMode && canCyclePermissionMode ? (
                <Pressable
                  accessibilityLabel={`Permission mode: ${composerContext.permission.label}`}
                  accessibilityRole="button"
                  accessibilityState={{ disabled: cycleModeDisabled }}
                  disabled={cycleModeDisabled}
                  onPress={() => { onCycleMode(); }}
                  style={styles.permissionButton}
                >
                  <Text style={[styles.composerPermission, cycleModeDisabled && styles.composerPermissionDisabled]}>
                    {composerContext.permission.label}
                  </Text>
                </Pressable>
              ) : (
                <Text accessibilityLabel={`Permission mode: ${composerContext.permission.label}`} style={styles.composerPermission}>
                  {composerContext.permission.label}
                </Text>
              )
            ) : null}
          </View>
          <View style={styles.composerToolbarSpacer} />
          <Text accessibilityLabel="Composer model and effort" numberOfLines={1} style={styles.composerModel}>
            {composerContext.model ?? composerContext.source}
            {composerContext.effort ? ` · Reasoning ${displayComposerMode(composerContext.effort)}` : ""}
          </Text>
          <View style={styles.composerActionCluster}>
            {cancellation.visible ? (
              <CancellationButton
                cancellation={cancellation}
                onCancel={onCancel}
                primary={!canSendDraft}
                styles={styles}
              />
            ) : null}
            <SendButton disabled={!canSendDraft} onPress={submit} styles={styles} />
          </View>
        </View>
        </View>
      </View>
    </View>
  );
}

function Details({
  metadata,
  session,
  styles,
}: {
  metadata?: ChatMetadata;
  session: SessionSummary;
  styles: ChatStyles;
}) {
  const rows = metadata ? chatMetadataRows(metadata) : [];
  const statusMetadata = metadata;
  const usage = chatStatusSummary(session, statusMetadata, {}).usage;
  return (
    <View accessibilityLabel="Chat technical details" style={styles.details}>
      <Text style={styles.actionTitle}>Details</Text>
      {rows.map((row) => (
        <Text key={row.label} selectable style={styles.muted}>{row.label}: {row.value}</Text>
      ))}
      {usage ? (
        <Text accessibilityLabel={`${usage.detail}; ${usage.percentUsed}% used`} selectable style={styles.muted}>
          Usage: {usage.detail} ({usage.percentUsed}% used)
        </Text>
      ) : null}
      <Text style={styles.muted}>Source: {session.source}</Text>
      <Text style={styles.muted}>Owner: {session.owner}</Text>
      <Text style={styles.muted}>Project: {session.project}</Text>
      <Text selectable style={styles.muted}>Path: {session.cwd}</Text>
    </View>
  );
}

function ActionButton({ disabled = false, label, onPress, styles }: { disabled?: boolean; label: string; onPress(): void; styles: ChatStyles }) {
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={[styles.actionButton, disabled && styles.actionButtonDisabled]}
    >
      <Text style={[styles.link, disabled && styles.cancelStatus]}>{label}</Text>
    </Pressable>
  );
}

function ComposerIconButton({
  children,
  label,
  onPress,
  styles,
}: {
  children: string;
  label: string;
  onPress(): void;
  styles: ChatStyles;
}) {
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      onBlur={() => setFocused(false)}
      onFocus={() => setFocused(true)}
      onPress={onPress}
      style={[styles.composerIconButton, focused && styles.composerFocusRing]}
    >
      <Text style={styles.composerPlus}>{children}</Text>
    </Pressable>
  );
}

function SendButton({ disabled, onPress, styles }: { disabled: boolean; onPress(): void; styles: ChatStyles }) {
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel="Send"
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onBlur={() => setFocused(false)}
      onFocus={() => setFocused(true)}
      onPress={onPress}
      style={[styles.sendButton, disabled && styles.sendButtonDisabled, focused && styles.composerFocusRing]}
    >
      <View style={[styles.sendFace, disabled && styles.sendFaceDisabled]}>
        <Text style={[styles.sendGlyph, disabled && styles.sendGlyphDisabled]}>↑</Text>
      </View>
    </Pressable>
  );
}

function CancellationButton({
  cancellation,
  onCancel,
  primary,
  styles,
}: {
  cancellation: ChatCancellationView;
  onCancel(): boolean;
  primary: boolean;
  styles: ChatStyles;
}) {
  const [focused, setFocused] = useState(false);
  const disabled = !cancellation.enabled;
  return (
    <Pressable
      accessibilityLabel={cancellation.accessibilityLabel}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onBlur={() => setFocused(false)}
      onFocus={() => setFocused(true)}
      onPress={onCancel}
      style={[
        styles.stopButton,
        primary && styles.stopButtonPrimary,
        disabled && styles.stopButtonDisabled,
        focused && styles.composerFocusRing,
      ]}
    >
      <Text style={[
        styles.stopLabel,
        primary && styles.stopLabelPrimary,
        disabled && !primary && styles.stopLabelDisabled,
      ]}>{cancellation.label}</Text>
    </Pressable>
  );
}

function displayComposerMode(value: string): string {
  return displayMode(value).replace(/^Extra /, "");
}

function Centered({ text, styles }: { text: string; styles: ChatStyles }) {
  return <View style={styles.centered}><Text style={styles.muted}>{text}</Text></View>;
}

function toggleChoice(value: string | string[] | undefined, choice: string): string[] {
  const choices = Array.isArray(value) ? value : [];
  return choices.includes(choice) ? choices.filter((item) => item !== choice) : [...choices, choice];
}

async function pickImages(): Promise<File[]> {
  if (typeof document === "undefined") return [];
  return new Promise((resolve) => {
    const picker = document.createElement("input");
    picker.type = "file";
  picker.accept = "image/png,image/jpeg,image/gif,image/webp,image/tiff,image/heic";
    picker.multiple = true;
    picker.onchange = async () => {
      const files = picker.files;
      const selected: File[] = [];
      for (let index = 0; files && index < Math.min(files.length, COMPOSER_MAX_FILE_SELECTION); index += 1) {
        selected.push(files[index]!);
      }
      resolve(selected);
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

// Chat uses a calm reading surface while Sessions keeps the shared palette.
// Semantic accents remain provider/status colors so state and links retain
// their existing meaning in both appearances.
function createChatPalette(palette: Palette): Palette {
  const isDark = hexLuminance(palette.background) < 0.2;
  return {
    ...palette,
    background: isDark ? "#202124" : "#ffffff",
    border: isDark ? "#3b3d43" : "#e7e7e3",
    card: isDark ? "#2b2d31" : "#f7f7f5",
    settingsCard: isDark ? "#2b2d31" : "#f7f7f5",
    foreground: isDark ? "#ecece8" : "#2d2d2b",
    muted: isDark ? "#b7b7b1" : "#6c6c68",
    tertiary: isDark ? "#92928d" : "#70706b",
    accentWash: isDark ? "#ffffff10" : "#00000008",
  };
}

function hexLuminance(value: string): number {
  const match = /^#([0-9a-f]{6})$/i.exec(value);
  if (!match) return 1;
  const channels = [0, 2, 4].map((start) => Number.parseInt(match[1]!.slice(start, start + 2), 16) / 255);
  const linear = channels.map((channel) => channel <= 0.03928
    ? channel / 12.92
    : ((channel + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear[0]! + 0.7152 * linear[1]! + 0.0722 * linear[2]!;
}

type ChatStyles = ReturnType<typeof createStyles>;
function createStyles(palette: Palette, scale: number) {
  const font = (size: number) => size * scale;
  return StyleSheet.create({
    app: { backgroundColor: palette.background, flex: 1 },
    header: { borderBottomColor: palette.border, borderBottomWidth: 1, minHeight: 74, paddingHorizontal: CONTENT_RAIL_INSET, paddingTop: 28 },
    headerRail: { ...contentRailStyle(), alignItems: "center", flexDirection: "row", minHeight: 46 },
    backButton: { justifyContent: "center", minHeight: 44, paddingRight: 12 },
    status: { borderRadius: 4, height: 8, marginRight: 8, width: 8 },
    headerTitle: { color: palette.foreground, flex: 1, fontSize: font(14), fontWeight: "600" },
    headerAction: { justifyContent: "center", minHeight: 44, paddingHorizontal: 12 },
    detailsButton: { alignItems: "center", justifyContent: "center", minHeight: 44, width: 44 },
    link: { color: palette.accent, fontSize: font(12), fontWeight: "600" },
    muted: { color: palette.muted, fontSize: font(12) },
    detailsOverlay: { left: 0, paddingHorizontal: CONTENT_RAIL_INSET, position: "absolute", right: 0, top: 74, zIndex: 4 },
    detailsRail: { ...contentRailStyle(), alignItems: "flex-end", paddingTop: 8 },
    details: { backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, gap: 5, maxWidth: 420, padding: 12 },
    scroller: { flex: 1 },
    timeline: { paddingBottom: 28, paddingHorizontal: CONTENT_RAIL_INSET, paddingTop: 16, width: "100%" },
    // Keep update announcements in the accessibility tree without adding a
    // visible row or participating in the FlatList layout.
    timelineUpdate: { height: 1, opacity: 0, overflow: "hidden", position: "absolute", width: 1 },
    rail: contentRailStyle(),
    loadEarlier: { alignSelf: "center", minHeight: 36, padding: 8 },
    historyCount: { color: palette.tertiary, fontSize: font(10), paddingVertical: 3, textAlign: "center" },
    historyLimitSurface: { alignItems: "center", paddingHorizontal: 8, paddingVertical: 8 },
    historyLimitText: { color: palette.tertiary, fontSize: font(11), textAlign: "center" },
    // Each grouped turn is split into bounded FlatList cells. These styles
    // retain the visual turn spacing without mounting a whole turn at once.
    turnPrompt: { paddingTop: 10 },
    turnAnswer: { paddingTop: 10 },
    work: { paddingTop: 7 },
    workItem: { paddingTop: 6 },
    workHeader: { alignSelf: "flex-start", minHeight: 30, paddingVertical: 6 },
    workLabel: { color: palette.tertiary, fontSize: font(11), fontWeight: "600" },
    userRow: { alignItems: "flex-end", paddingLeft: 60 },
    userBubble: { backgroundColor: palette.foreground + "12", borderRadius: 15, gap: 8, maxWidth: "82%", minWidth: 0, paddingHorizontal: 14, paddingVertical: 10 },
    assistant: { alignItems: "flex-start", maxWidth: "100%", minWidth: 0 },
    messageText: { flex: 1, gap: 16, maxWidth: "100%", minWidth: 0 },
    inlineFlow: { color: palette.foreground, flex: 1, flexShrink: 1, fontSize: font(14), lineHeight: font(22), maxWidth: "100%", minWidth: 0 },
    body: { color: palette.foreground, flexShrink: 1, fontSize: font(14), lineHeight: font(22), maxWidth: "100%", minWidth: 0 },
    heading: { fontWeight: "700" },
    emphasis: { fontStyle: "italic" },
    strike: { textDecorationLine: "line-through" },
    chatLink: { color: palette.accent, textDecorationLine: "underline" },
    localReference: { color: palette.muted, fontFamily: "monospace", fontSize: font(12), textDecorationLine: "underline" },
    localReferenceFull: { fontSize: font(10) },
    bold: { fontWeight: "700" },
    inlineCode: { backgroundColor: palette.card, fontFamily: "monospace", fontSize: font(12) },
    inlineMath: { backgroundColor: palette.card, fontFamily: "monospace", fontSize: font(12), fontStyle: "italic" },
    blockquote: { borderLeftColor: palette.border, borderLeftWidth: 3, paddingLeft: 10 },
    list: { gap: 6, paddingLeft: 2 },
    listItem: { alignItems: "flex-start", flexDirection: "row", gap: 8, maxWidth: "100%", minWidth: 0 },
    listMarker: { color: palette.tertiary, fontSize: font(14), lineHeight: font(22), minWidth: 22 },
    thinking: { paddingLeft: 0 },
    thinkingText: { color: palette.tertiary, fontSize: font(12), fontStyle: "italic", lineHeight: font(18) },
    systemRow: { maxWidth: "100%", width: "100%" },
    system: { color: palette.tertiary, flexShrink: 1, fontSize: font(11), maxWidth: "100%", textAlign: "left" },
    duration: { color: palette.tertiary, fontSize: font(11), letterSpacing: 0.1, lineHeight: font(16), paddingVertical: 4, textAlign: "left" },
    recap: { fontStyle: "italic" },
    localCommand: { color: palette.accent },
    compactBoundary: { alignItems: "center", gap: 6, width: "100%" },
    thematicBreak: { backgroundColor: palette.border, height: 1, marginVertical: 4, width: "100%" },
    codeBlock: { backgroundColor: palette.card, borderRadius: 7, maxWidth: "100%", minWidth: 0, overflow: "hidden", padding: 10 },
    codeLanguage: { color: palette.accent, fontFamily: "monospace", fontSize: font(10), fontWeight: "600", marginBottom: 5 },
    code: { color: palette.foreground, flexShrink: 1, fontFamily: "monospace", fontSize: font(11), lineHeight: font(17), maxWidth: "100%", padding: 0 },
    codeTokenPlain: { color: palette.foreground },
    codeTokenKeyword: { color: palette.accent, fontWeight: "600" },
    codeTokenString: { color: palette.ready },
    codeTokenComment: { color: palette.tertiary, fontStyle: "italic" },
    codeTokenNumber: { color: palette.attention },
    codeTokenLiteral: { color: palette.foreground },
    math: { backgroundColor: palette.card, color: palette.foreground, fontFamily: "monospace", fontSize: font(12), padding: 8 },
    mathBlock: { alignItems: "center", backgroundColor: palette.card, borderRadius: 6, maxWidth: "100%", minHeight: 32, padding: 8, width: "100%" },
    table: { borderColor: palette.border, borderRadius: 6, borderWidth: 1, maxWidth: "100%", overflow: "hidden" },
    tableRow: { borderBottomColor: palette.border, borderBottomWidth: 1, flexDirection: "row", maxWidth: "100%", minWidth: 0 },
    tableCell: { flex: 1, minWidth: 0, paddingHorizontal: 8, paddingVertical: 6 },
    tool: { paddingLeft: 0 },
    toolHeader: { alignItems: "center", flexDirection: "row", gap: 7, minHeight: 32 },
    toolStatus: { color: palette.ready, fontSize: font(11), width: 12 },
    toolName: { color: palette.foreground, fontSize: font(12), fontWeight: "600" },
    toolSummary: { color: palette.muted, flex: 1, fontFamily: "monospace", fontSize: font(10) },
    toolChevron: { color: palette.tertiary, fontSize: font(14) },
    toolDetail: { gap: 7, maxWidth: "100%", minWidth: 0, paddingLeft: 0, paddingTop: 4 },
    toolResult: { color: palette.muted, fontFamily: "monospace", fontSize: font(11), lineHeight: font(16) },
    planCard: { backgroundColor: palette.accentWash, borderColor: palette.accent, borderRadius: 8, borderWidth: 1, gap: 5, maxWidth: "100%", padding: 9 },
    planTitle: { color: palette.accent, fontSize: font(12), fontWeight: "700" },
    planPath: { color: palette.muted, fontFamily: "monospace", fontSize: font(10) },
    editCard: { backgroundColor: palette.card, borderColor: palette.border, borderRadius: 7, borderWidth: 1, gap: 4, maxWidth: "100%", padding: 9 },
    editPath: { color: palette.muted, fontFamily: "monospace", fontSize: font(10) },
    diffRemoved: { color: palette.error, fontFamily: "monospace", fontSize: font(11), maxWidth: "100%" },
    diffAdded: { color: palette.ready, fontFamily: "monospace", fontSize: font(11), maxWidth: "100%" },
    image: { borderRadius: 9, height: 120, resizeMode: "contain", width: 180 },
    errorText: { color: palette.error },
    errorBanner: { backgroundColor: `${palette.error}20`, color: palette.error, fontSize: font(11), paddingHorizontal: CONTENT_RAIL_INSET, paddingVertical: 7 },
    cancelSurface: { paddingHorizontal: CONTENT_RAIL_INSET, paddingTop: 8 },
    cancelRail: { ...contentRailStyle(), alignItems: "flex-end" },
    cancelButton: { borderColor: palette.border, borderRadius: 8, borderWidth: 1, justifyContent: "center", minHeight: 34, paddingHorizontal: 12 },
    cancelButtonDisabled: { opacity: 0.7 },
    cancelStatus: { color: palette.muted },
    recoverySurface: { paddingHorizontal: CONTENT_RAIL_INSET, paddingVertical: 8 },
    recoveryRail: { ...contentRailStyle(), gap: 8 },
    recoveryCard: { backgroundColor: `${palette.error}12`, borderColor: `${palette.error}55`, borderRadius: 9, borderWidth: 1, gap: 5, padding: 10 },
    recoveryTitle: { color: palette.foreground, fontSize: font(12), fontWeight: "600" },
    recoveryReason: { color: palette.foreground, fontSize: font(11), lineHeight: font(16) },
    recoveryAttachments: { color: palette.muted, fontSize: font(10) },
    recoveryActions: { flexDirection: "row", gap: 8, justifyContent: "flex-end" },
    actionSurface: { paddingHorizontal: CONTENT_RAIL_INSET, paddingVertical: 8 },
    actionRail: contentRailStyle(),
    actionPanel: { alignSelf: "stretch", backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, gap: 9, maxHeight: 300, maxWidth: "100%", minWidth: 0, padding: 12 },
    actionTitle: { color: palette.foreground, fontSize: font(13), fontWeight: "600" },
    actionContext: { color: palette.muted, fontFamily: "monospace", fontSize: font(10) },
    actionUnavailable: { color: palette.muted, fontSize: font(11) },
    actionButtons: { flexDirection: "row", gap: 8, justifyContent: "flex-end" },
    actionButton: { borderColor: palette.border, borderRadius: 8, borderWidth: 1, justifyContent: "center", minHeight: 34, paddingHorizontal: 10 },
    actionButtonDisabled: { opacity: 0.7 },
    question: { gap: 6 },
    choice: { borderColor: palette.border, borderRadius: 7, borderWidth: 1, minHeight: 34, padding: 8 },
    choiceSelected: { backgroundColor: palette.accentWash, borderColor: palette.accent },
    answerInput: { backgroundColor: palette.background, borderColor: palette.border, borderRadius: 7, borderWidth: 1, color: palette.foreground, fontSize: font(12), minHeight: 38, padding: 8 },
    composerSurface: { paddingHorizontal: CONTENT_RAIL_INSET, paddingVertical: 8 },
    composerRailContainer: contentRailStyle(),
    composerRail: { ...contentRailStyle(), backgroundColor: palette.card, borderColor: palette.border, borderRadius: 22, borderWidth: 1, gap: 4, paddingBottom: 5, paddingHorizontal: 10, paddingTop: 8 },
    composerInput: { backgroundColor: "transparent", borderColor: "transparent", borderRadius: 4, borderWidth: 0, color: palette.foreground, fontSize: font(14), lineHeight: font(22), maxHeight: 180, minHeight: 42, paddingHorizontal: 7, paddingTop: 2, paddingBottom: 6, width: "100%" },
    composerToolbar: { alignItems: "center", flexDirection: "row", flexWrap: "wrap", gap: 4, minHeight: 44 },
    composerLeadingActions: { alignItems: "center", flexDirection: "row", flexShrink: 1, gap: 4, minHeight: 44, minWidth: 0 },
    composerToolbarSpacer: { flex: 1, minWidth: 8 },
    composerIconButton: { alignItems: "center", borderColor: "transparent", borderRadius: 12, borderWidth: 0, height: 44, justifyContent: "center", padding: 0, width: 44 },
    composerPlus: { color: palette.muted, fontSize: 18, lineHeight: 22 },
    composerPlaceholder: { color: palette.tertiary },
    composerPermission: { color: palette.muted, fontSize: font(12), lineHeight: font(18), maxWidth: 220 },
    composerPermissionDisabled: { color: palette.tertiary },
    permissionButton: { alignItems: "center", justifyContent: "center", minHeight: 44, paddingHorizontal: 4 },
    composerModel: { color: palette.muted, flexShrink: 1, fontSize: font(12), lineHeight: font(18), marginHorizontal: 4, maxWidth: 300, minWidth: 0, textAlign: "right" },
    composerActionCluster: { alignItems: "center", flexDirection: "row", flexShrink: 0, gap: 2, minHeight: 44 },
    sendButton: { alignItems: "center", backgroundColor: "transparent", borderColor: "transparent", borderRadius: 22, borderWidth: 0, height: 44, justifyContent: "center", padding: 6, width: 44 },
    sendButtonDisabled: { opacity: 1 },
    sendFace: { alignItems: "center", backgroundColor: palette.foreground, borderRadius: 16, height: 32, justifyContent: "center", width: 32 },
    sendFaceDisabled: { backgroundColor: palette.border },
    sendGlyph: { color: palette.background, fontSize: 18, lineHeight: 20 },
    sendGlyphDisabled: { color: palette.tertiary },
    stopButton: { alignItems: "center", backgroundColor: "transparent", borderColor: palette.border, borderRadius: 14, borderWidth: 1, justifyContent: "center", minHeight: 44, paddingHorizontal: 12 },
    stopButtonPrimary: { backgroundColor: palette.foreground, borderColor: palette.foreground },
    stopButtonDisabled: { opacity: 0.7 },
    stopLabel: { color: palette.foreground, fontSize: font(12), fontWeight: "600" },
    stopLabelPrimary: { color: palette.background },
    stopLabelDisabled: { color: palette.muted },
    composerFocusRing: { borderColor: palette.accent, borderWidth: 2 },
    readOnlySurface: { paddingHorizontal: CONTENT_RAIL_INSET, paddingVertical: 8 },
    readOnlyRail: { ...contentRailStyle() },
    readOnlyNotice: { color: palette.muted, fontSize: font(12), lineHeight: font(18), paddingHorizontal: 4, paddingVertical: 6 },
    slashPopover: { backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, maxHeight: 148, overflow: "hidden" },
    slashScroller: { maxHeight: 148 },
    slashRow: { alignItems: "center", flexDirection: "row", gap: 7, minHeight: 28, paddingHorizontal: 10, paddingVertical: 5 },
    slashRowSelected: { backgroundColor: palette.accentWash },
    slashName: { color: palette.accent, fontFamily: "monospace", fontSize: font(12), fontWeight: "600" },
    slashHint: { color: palette.tertiary, fontFamily: "monospace", fontSize: font(11) },
    slashDescription: { color: palette.muted, flex: 1, fontSize: font(11) },
    slashSource: { color: palette.tertiary, fontSize: font(10) },
    slashTruncation: { color: palette.tertiary, fontSize: font(10), paddingHorizontal: 10, paddingVertical: 7 },
    attachmentStrip: { gap: 8, paddingHorizontal: 2, paddingVertical: 2 },
    attachmentPreview: { height: 64, position: "relative", width: 76 },
    attachmentImage: { borderColor: palette.border, borderRadius: 8, borderWidth: 1, height: 64, resizeMode: "cover", width: 64 },
    removeAttachment: { alignItems: "center", backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, height: 20, justifyContent: "center", position: "absolute", right: 0, top: -2, width: 20 },
    removeAttachmentText: { color: palette.foreground, fontSize: font(14), lineHeight: font(16) },
    validationErrors: { backgroundColor: `${palette.error}16`, borderColor: `${palette.error}55`, borderRadius: 7, borderWidth: 1, gap: 3, paddingHorizontal: 8, paddingVertical: 5 },
    validationError: { color: palette.error, fontSize: font(11) },
    centered: { alignItems: "center", flex: 1, justifyContent: "center", minHeight: 200 },
  });
}
