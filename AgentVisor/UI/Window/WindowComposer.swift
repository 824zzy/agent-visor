//
//  WindowComposer.swift
//  AgentVisor
//
//  Multi-line composer for the window-mode chat. Wraps the same
//  `MultiLineInput` the notch uses, plus the slash-command popover
//  and the attachment strip. Sends text/images via `SessionSender`
//  (without notch focus-theft handling, since the window has no
//  NotchPanel to re-key).
//
//  Owns its own composer state — text, attachments, slash controller,
//  focus controller, font scale. Per-session because parent uses
//  `.id(sessionId)` to recreate the view when the user switches
//  sessions, so the draft is naturally per-session.
//

import AppKit
import AgentVisorCore
import os.log
import SwiftUI

@MainActor
struct WindowComposer: View {
    let session: SessionState
    let isProcessing: Bool

    /// Local copy of the session, refreshed by parent on each
    /// SessionStore publish. `WindowComposer` itself is short-lived
    /// (recreated on session switch via `.id(sessionId)` upstream),
    /// so we don't subscribe — the parent passes a fresh copy.
    @State private var inputText: String = ""
    @State private var attachments: [ImageAttachment] = []
    @StateObject private var slashController = SlashCommandPopoverController()
    @StateObject private var inputFocus = InputFocusController()
    @AppStorage("chatFontScale") private var chatFontScaleStorage: Double = 1.0
    /// Observe theme so MultiLineInput.updateNSView fires on Light/Dark
    /// flip — the inner NSTextView's `textColor`, `insertionPointColor`,
    /// and `selectedTextAttributes` are NSColor-baked at make time and
    /// only refreshed by `updateNSView`. Without this dependency, theme
    /// flips leave the composer text in the previous palette's color.
    @ObservedObject private var appearance = AppearanceSelector.shared
    /// Last submitted text, for cancel-and-restore.
    @State private var lastSubmittedText: String = ""
    /// VISUAL line count from the NSTextView's layout manager —
    /// counts soft-wrapped lines (long string with no newline that
    /// the text view wrapped to a second row) as well as hard
    /// newlines. Updated on every text change via `onTextChanged`.
    /// Falling back to a `\n`-count miscalculates whenever a single
    /// line is long enough to wrap, which is the bug that clipped
    /// the second visual row of long prompts.
    @State private var visualLineCount: Int = 1

    /// Composer line count, capped to prevent paste-bombs from
    /// growing the input unboundedly. `visualLineCount` is the live
    /// signal from the layout manager. Used only for the
    /// height-changed Notification observers (which want to know
    /// "did line count cross a boundary"); the actual box height is
    /// driven by `composerTextHeight` below.
    private var composerLineCount: Int {
        min(8, max(1, visualLineCount))
    }
    /// Live per-line height in points, refreshed alongside
    /// `visualLineCount`. Pulled from the NSTextView's typesetter
    /// (`defaultLineHeight(for: font)`) so it tracks whatever font
    /// the input currently has. Used to cap the box at 8 lines.
    @State private var composerLineHeight: CGFloat = 22
    /// Live measured height of the rendered text in the NSTextView,
    /// in points. Source of truth for the box's frame height. Reads
    /// `usedRect.height + extraLineFragmentRect.height` directly off
    /// the layout manager — same geometry the text view itself uses
    /// — so the box bottom always sits exactly where the rendered
    /// text ends, no phantom gap and no off-by-one.
    @State private var composerTextHeight: CGFloat = 22

    private var composerInputHeight: CGFloat {
        // The outer SwiftUI frame must INCLUDE the NSTextView's
        // textContainerInset on both top and bottom. Otherwise the
        // NSTextView's intrinsic content size is taller than the
        // visible scroll bounds, and AppKit shifts the clip view on
        // caret movement — the user-reported drift bug. See
        // [[ComposerOuterFrameHeight]].
        ComposerOuterFrameHeight.height(.init(
            usedRectHeight: composerTextHeight,
            lineHeight: composerLineHeight,
            visualLineCount: visualLineCount,
            maxLines: 8,
            textContainerInset: MultiLineInput.textContainerInsetY
        ))
    }


    /// Notification name fired when the composer's height changes
    /// (line count crossed an integer boundary). WindowChatView
    /// observes this to scroll-to-bottom so the latest message stays
    /// visible as the composer grows upward.
    static let composerHeightDidChange = Notification.Name("AgentVisor.composerHeightDidChange")

    /// Posted by WindowChatView's ESC monitor when the user wants to
    /// cancel an in-flight query. Composer responds by triggering its
    /// internal `cancelQuery()` (which sends ESC to the TTY + clears
    /// the leftover prompt buffer).
    static let requestCancel = Notification.Name("AgentVisor.composerRequestCancel")

    /// Posted by WindowChatView's ESC monitor when the user wants to
    /// clear the composer draft (ESC pressed, no drill-down open, no
    /// processing in flight). Composer responds by emptying inputText.
    static let requestClearDraft = Notification.Name("AgentVisor.composerRequestClearDraft")

    /// Fired when the user submits a query. WindowChatView pins the
    /// chat to the bottom unconditionally on receipt so the just-sent
    /// echo + the assistant's reply land in view, even if the user
    /// had previously scrolled up. This is distinct from the streaming/
    /// insert auto-pin (which only fires when already near the bottom)
    /// — a deliberate user action should always reset the viewport.
    static let didSendMessage = Notification.Name("AgentVisor.composerDidSendMessage")

    /// Whether the composer can submit. Cursor-observed sessions and
    /// sessions without a TTY can't be silent-sent to.
    private var canSendMessages: Bool {
        session.supportsSilentSend
    }

    private var composerPlaceholder: String {
        canSendMessages ? "Message Claude (↵ to send)…" : "No terminal connected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if slashController.isOpen {
                SlashCommandPopover(controller: slashController) { replacement in
                    inputText = replacement
                    inputFocus.replaceText(replacement, caretAtEnd: true)
                }
                .padding(.horizontal, 14)
                .transition(.opacity)
            }

            if !attachments.isEmpty {
                attachmentStrip
            }

            MultiLineInput(
                text: $inputText,
                placeholder: composerPlaceholder,
                isEnabled: canSendMessages,
                onSubmit: { sendMessage() },
                onImagePasted: { image in handleImagePaste(image) },
                onCycleMode: session.tty == nil ? nil : {
                    Task { await PermissionModeCycler.cycle(session: session) }
                },
                onCancelQuery: isProcessing ? { cancelQuery() } : nil,
                onTextChanged: { newText in
                    slashController.update(composerText: newText)
                    // Refresh measured text geometry from the live
                    // NSTextView. Do this on the next runloop tick
                    // so the layout manager has finished glyph
                    // generation for the latest character — reading
                    // synchronously can return a stale rect for
                    // the just-typed character.
                    DispatchQueue.main.async {
                        visualLineCount = inputFocus.visualLineCount()
                        composerLineHeight = inputFocus.visualLineHeight()
                        composerTextHeight = inputFocus.visualTextHeight()
                    }
                },
                slashController: slashController,
                focusController: inputFocus,
                scale: CGFloat(chatFontScaleStorage)
            )
            // Codex-style auto-grow: composer height tracks line count
            // in the bound text. Fixed exact height (not min/max
            // range) so SwiftUI doesn't inflate the box to maxHeight
            // when the parent has slack — that's the bug that made
            // the empty composer render at 176pt instead of 22pt.
            // Past 8 lines, NSTextView's internal scroll takes over.
            // Animated so growth/shrink reads as a smooth slide rather
            // than jumping.
            .frame(height: composerInputHeight)
            // Animate height transitions only when the user-visible
            // line count changes (or a large same-line jump happens).
            // Animating the empty → 1-char sub-pixel drift produced
            // visible jitter on every keystroke. See
            // [[ComposerHeightAnimationPolicy]] for the rule.
            //
            // We pipe through a stable identity that only changes
            // when the policy approves animating. SwiftUI's
            // `.animation(_:value:)` runs ONLY when `value` changes,
            // so sub-pixel re-measures (which don't bump the value)
            // apply instantly with no animation.
            .animation(
                .easeOut(duration: 0.12),
                value: composerLineCount
            )
            .onChange(of: composerLineCount) { _, _ in
                // Composer just grew/shrunk by one line. Tell the
                // chat scroll to re-pin its bottom so the latest
                // message stays visible (otherwise the taller
                // composer overlaps the last row).
                NotificationCenter.default.post(
                    name: WindowComposer.composerHeightDidChange,
                    object: nil
                )
            }
            .onChange(of: inputText) { _, newValue in
                // Programmatic mutations (send-and-clear, ESC clear-
                // draft, slash-command popover replacement) update the
                // SwiftUI binding but DON'T fire NSTextView's
                // `textDidChange` delegate, so `onTextChanged` above
                // doesn't get called and the composer would visually
                // remain multi-line after a Shift+Enter send until
                // some unrelated event triggered a recompute. Mirror
                // the geometry refresh here for the binding-only path.
                let lineHeight = inputFocus.visualLineHeight()
                if newValue.isEmpty {
                    visualLineCount = 1
                    composerLineHeight = lineHeight
                    composerTextHeight = lineHeight
                } else {
                    DispatchQueue.main.async {
                        visualLineCount = inputFocus.visualLineCount()
                        composerLineHeight = inputFocus.visualLineHeight()
                        composerTextHeight = inputFocus.visualTextHeight()
                    }
                }
            }
            .onChange(of: chatFontScaleStorage) { _, _ in
                // Cmd-+/-/0 zoom changed the input's font, which
                // changed the per-line height. Refresh the live
                // geometry so the box re-fits.
                DispatchQueue.main.async {
                    composerLineHeight = inputFocus.visualLineHeight()
                    composerTextHeight = inputFocus.visualTextHeight()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // System styling — adapts to Light/Dark and reads as a
            // proper editable field, not a disabled placeholder.
            // ChatTheme.inputBg was tuned for the Catppuccin notch
            // panel and bled grey-on-grey in a system-styled window.
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.textBackgroundColor)
                            .opacity(canSendMessages ? 1 : 0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
        // Per-session draft persistence. WindowChatView upstream uses
        // `.id(sessionId)`, so a session switch tears down this view —
        // .onDisappear runs at exactly the right moment to flush.
        .onAppear {
            restoreDraft()
            // Focus the input on mount so the user can start typing
            // immediately on session switch, no Tab needed. We defer
            // by 100ms: focusing during the in-flight SwiftUI mount
            // cycle while the chat-table coordinator is also running
            // settle-layout passes triggered an
            // `_postWindowNeedsUpdateConstraints` exception (AppKit
            // detected concurrent constraint mutation). The longer
            // delay lets both the NSTextView attach AND the chat
            // table's settle passes finish before we touch the
            // window's first responder.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                inputFocus.focus()
                // Refresh the seeded line height with the real
                // typesetter value AFTER the NSTextView has mounted.
                // The `@State` initial values (22pt) are a stale
                // guess — the actual line height at the user's
                // current font/zoom is often smaller. Without this
                // refresh, the empty composer renders at the stale
                // height and SNAPS DOWN on the first character —
                // visible as a sudden box-shrink the user reported
                // after switching sessions and typing a char.
                let lineHeight = inputFocus.visualLineHeight()
                let textHeight = inputFocus.visualTextHeight()
                if lineHeight > 0 {
                    composerLineHeight = lineHeight
                }
                if textHeight > 0 {
                    composerTextHeight = textHeight
                } else if lineHeight > 0 {
                    // Empty input: floor at one line so the box
                    // matches what the first-character measure would
                    // produce.
                    composerTextHeight = lineHeight
                }
            }
        }
        .onDisappear(perform: persistDraft)
        // ESC is dispatched from WindowChatView's chat-level monitor
        // (which knows about drill-down overlays). It posts ONE of
        // these two notifications based on context. The composer
        // handles both: cancel an in-flight query OR clear the draft.
        .onReceive(NotificationCenter.default.publisher(for: WindowComposer.requestCancel)) { _ in
            cancelQuery()
        }
        .onReceive(NotificationCenter.default.publisher(for: WindowComposer.requestClearDraft)) { _ in
            inputText = ""
            attachments = []
            slashController.close()
        }
    }

    private func restoreDraft() {
        guard inputText.isEmpty, attachments.isEmpty else { return }
        if let draft = DraftStore.shared.load(sessionId: session.sessionId) {
            inputText = draft.text
            attachments = draft.attachments
        }
    }

    /// Sending clears both fields to empty, which DraftStore treats as
    /// "delete entry" — no separate clear path needed.
    private func persistDraft() {
        DraftStore.shared.save(
            sessionId: session.sessionId,
            text: inputText,
            attachments: attachments
        )
    }

    // MARK: - Attachments

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                        try? FileManager.default.removeItem(at: attachment.url)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 56)
    }

    private func handleImagePaste(_ image: NSImage) {
        guard let url = ImagePasteSender.savePNG(image) else { return }
        let thumbnail = Self.makeThumbnail(from: image, maxSize: 80)
        attachments.append(ImageAttachment(id: UUID(), url: url, thumbnail: thumbnail))
    }

    private static func makeThumbnail(from image: NSImage, maxSize: CGFloat) -> NSImage {
        let size = image.size
        let scale = min(maxSize / size.width, maxSize / size.height, 1.0)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver,
                   fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }

    // MARK: - Send

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentAttachments = attachments
        guard !text.isEmpty || !currentAttachments.isEmpty else { return }

        if !text.isEmpty {
            lastSubmittedText = text
        }
        inputText = ""
        attachments = []
        slashController.close()

        // Optimistic local echo. JSONL syncs 1-2 s after send (TTY ↔
        // Claude Code roundtrip), which reads as "the app ate my
        // message" if the bubble doesn't appear immediately. Push the
        // user's text into PendingEchoStore so WindowChatViewModel
        // can merge it into the visible timeline NOW; the echo
        // self-evicts once the real JSONL row arrives (matched by
        // trimmed text) or after a 30s TTL backstop.
        if !text.isEmpty {
            PendingEchoStore.shared.push(sessionId: session.sessionId, text: text)
        }

        NotificationCenter.default.post(
            name: WindowComposer.didSendMessage,
            object: session.sessionId
        )

        let target = session
        Task {
            await SessionSender.send(
                text: text,
                attachments: currentAttachments,
                to: target,
                keepFocusOnHost: false
            )
            scheduleAttachmentCleanup(currentAttachments)
        }
    }

    private func scheduleAttachmentCleanup(_ attachments: [ImageAttachment]) {
        guard !attachments.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            for attachment in attachments {
                try? FileManager.default.removeItem(at: attachment.url)
            }
        }
    }

    // MARK: - Cancel

    private func cancelQuery() {
        let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "Cancel")
        logger.info("cancel: triggered isProcessing=\(isProcessing, privacy: .public)")
        guard isProcessing else {
            logger.info("cancel: skip — !isProcessing")
            return
        }
        let target = session
        let textToRestore = lastSubmittedText
        logger.info("cancel: tty=\(target.tty ?? "nil", privacy: .public) lastSubmittedLen=\(textToRestore.count, privacy: .public)")
        // Evict any pending optimistic echoes for this session BEFORE
        // doing the slow TTY round-trip. Claude Code may have already
        // written the user turn to JSONL (the canonical row), in which
        // case our echo bubble is a duplicate. The merged-rows view
        // refreshes on echoesBySession publishes, so the duplicate
        // disappears in the same frame as the cancel.
        PendingEchoStore.shared.evictAll(sessionId: target.sessionId)
        let isITerm = TerminalAdapterRegistry.adapter(for: target) is ITermAdapter
        DispatchQueue.global(qos: .userInitiated).async {
            let ok: Bool
            if isITerm {
                ok = ITermAdapter().sendEscape(toSession: target)
            } else {
                ok = GhosttyScripting.sendKeystroke(named: "escape", toSession: target)
            }
            logger.info("cancel: ESC sent isITerm=\(isITerm, privacy: .public) ok=\(ok, privacy: .public)")
            guard ok else {
                logger.error("cancel: ESC FAILED — bailing without clear")
                return
            }
            // Always clear the TUI's prompt buffer after ESC. Claude
            // Code preserves the user's input on interrupt by design,
            // so without this clear the canceled text sits in the
            // buffer and gets prepended to the next send.
            usleep(200_000)
            if isITerm {
                // Ctrl+U via `write text "\u{15}"` is silently dropped
                // by Claude Code's Ink-based input field — iTerm's
                // `write text` is user-input emulation, not a raw
                // PTY write, and the TUI input handler doesn't
                // interpret NAK as kill-to-start-of-line. Use a
                // backspace-byte burst instead: 0x08 IS recognized
                // by the TUI as "delete one char." Same chunked
                // dispatch as the Ghostty path below for safety
                // against AppleScript size limits, plus a 3× over-
                // count to handle multi-line / decorated input.
                let totalToSend = min(4096, max(256, textToRestore.count * 3))
                let chunkSize = 256  // iTerm `write text` is one PTY
                                     // write per call — much higher
                                     // safe-chunk-size than Ghostty's
                                     // per-keystroke `send key`.
                var remaining = totalToSend
                var chunkCount = 0
                var okCount = 0
                while remaining > 0 {
                    let n = min(chunkSize, remaining)
                    let chunkOk = ITermAdapter().sendBackspaces(count: n, toSession: target)
                    if chunkOk { okCount += 1 }
                    chunkCount += 1
                    remaining -= n
                    usleep(20_000)
                }
                logger.info("cancel: iTerm clear total=\(totalToSend, privacy: .public) chunks=\(chunkCount, privacy: .public) ok=\(okCount, privacy: .public)")
            } else {
                // Ghostty's AppleScript channel filters control bytes
                // (no Ctrl+U), so we backspace the prompt clean.
                //
                // Two pitfalls we've already hit:
                //   1. ONE giant AppleScript with ~600 `send key` lines
                //      gets dropped/timed-out past some Ghostty
                //      internal limit, leaving the input partly intact.
                //   2. AX-readback via TUIInputBoxParser only matches
                //      the legacy `╭ ╰` boxed input — modern Claude
                //      Code uses `─`/`❯` shape, so the parser returns
                //      nil and the readback path no-ops entirely.
                //
                // Fix: chunk the backspace burst into batches of 64
                // with brief settles between, AND massively over-
                // count (3× submitted length, capped at 4096). Extra
                // backspaces past start-of-line are harmless no-ops
                // in Claude Code's TUI. The chunked dispatch keeps
                // each AppleScript small enough to always complete.
                // See [[feedback_ghostty_no_ctrl_injection]].
                let totalToSend = min(4096, max(256, textToRestore.count * 3))
                let chunkSize = 64
                var remaining = totalToSend
                var chunkCount = 0
                var okCount = 0
                while remaining > 0 {
                    let n = min(chunkSize, remaining)
                    let chunkOk = GhosttyScripting.sendBackspaces(count: n, toSession: target)
                    if chunkOk { okCount += 1 }
                    chunkCount += 1
                    remaining -= n
                    usleep(20_000)  // 20ms settle between chunks
                }
                logger.info("cancel: clear total=\(totalToSend, privacy: .public) chunks=\(chunkCount, privacy: .public) ok=\(okCount, privacy: .public)")
            }
            DispatchQueue.main.async {
                if inputText.isEmpty, !textToRestore.isEmpty {
                    inputText = textToRestore
                }
                // Drive the phase off `.processing` immediately so
                // the "Working…" indicator hides as soon as the user
                // sees their cancel land. Without this, the indicator
                // lingers 1-3 s while we wait for Claude Code's
                // `[Request interrupted]` JSONL append → parser →
                // SessionStore round-trip — which reads as "the
                // cancel didn't work." Idempotent with the eventual
                // JSONL-driven interruptDetected later in the round-
                // trip. Mirrors the notch path in ChatView.cancelQuery.
                Task {
                    await SessionStore.shared.process(
                        .interruptDetected(sessionId: target.sessionId)
                    )
                }
            }
        }
    }
}
