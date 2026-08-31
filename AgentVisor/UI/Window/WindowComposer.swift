//
//  WindowComposer.swift
//  AgentVisor
//
//  Multi-line composer for Agent Visor Chat. It combines MultiLineInput,
//  slash commands, attachments, and SessionSender.
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
    /// Durable submitted/recovery state is app-owned so destroying this view
    /// or switching A→B→A cannot orphan the exact attachment snapshot.
    @ObservedObject private var recoveryScope = ComposerRecoveryScopeStore.shared
    /// Read-only view of the authoritative provider generation. The mounted
    /// composer never creates or advances generation ownership.
    private var composerGenerationID: String {
        recoveryScope.currentGeneration(for: session.sessionId) ?? ""
    }
    /// The body reads this cache only. The blocking process/TTY probe is
    /// refreshed asynchronously when this exact identity changes.
    @StateObject private var terminalIdentityCapability = TerminalIdentityCapabilityCache()
    /// Monotonic local draft revision. Cancellation may restore only the
    /// revision immediately after its own send-and-clear operation.
    @State private var draftRevision: Int = 0
    /// Escape is a request/response operation; suppress duplicate key/button
    /// requests until the current terminal route confirms success or failure.
    @State private var cancelInFlight = false
    /// Visible, accessible admission guidance.  A rejected image must not
    /// clear the composer or leave its newly-created temp file behind.
    @State private var attachmentAdmissionError: String?
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

    /// Context compaction is active work for status purposes but is not a
    /// terminal turn that the composer may interrupt. Keep this gate next to
    /// both the button wiring and the action guard so an Escape notification
    /// cannot mutate the draft during compaction.
    private var canCancelProcessing: Bool {
        let identity = terminalIdentityCapability.state(
            for: session,
            generationID: composerGenerationID
        )
        return ComposerCancellationCapabilityPolicy.availability(
            phase: session.phase,
            terminalHost: session.terminalHost,
            hasVerifiedTarget: identity.isVerified
        ).canCancel
    }

    private var terminalIdentityNotice: String? {
        guard session.phase == .processing,
              !canCancelProcessing else { return nil }
        return terminalIdentityCapability.state(
            for: session,
            generationID: composerGenerationID
        ).accessibilityLabel
    }

    /// Compaction is active provider work, but Escape cannot safely interrupt
    /// it. Keep the explanation in the composer so the consumed Escape has a
    /// visible and VoiceOver-readable outcome instead of looking ignored.
    private var compactionNotice: String? {
        guard session.phase == .compacting else { return nil }
        return ComposerCancellationCapabilityPolicy.availability(
            phase: .compacting
        ).reason
    }

    private var composerPlaceholder: String {
        guard canSendMessages else { return "No terminal connected" }
        let agentName = AgentRegistry.provider(for: session.agentID)?.displayName ?? "agent"
        return "Message \(agentName) (↵ to send)…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if slashController.isOpen {
                SlashCommandPopover(controller: slashController) { replacement in
                    inputText = replacement
                    draftRevision += 1
                    persistDraft()
                    inputFocus.replaceText(replacement, caretAtEnd: true)
                }
                .padding(.horizontal, 14)
                .transition(.opacity)
            }

            if !visibleRecoveryEntries.isEmpty {
                recoveryCards
            }

            if let compactionNotice {
                Text(compactionNotice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(compactionNotice)
            }

            if let terminalIdentityNotice {
                Text(terminalIdentityNotice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(terminalIdentityNotice)
            }

            if let attachmentAdmissionError {
                Text(attachmentAdmissionError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Attachment error: \(attachmentAdmissionError)")
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
                onCycleMode: session.permissionModeSurfaceDecision.canCycle
                    ? { Task { await PermissionModeCycler.cycle(session: session) } }
                    : nil,
                onCancelQuery: canCancelProcessing ? { cancelQuery() } : nil,
                onTextChanged: { newText in
                    // This delegate callback represents user text edits. The
                    // binding-only send/clear mutations below advance the
                    // revision explicitly so cancellation can distinguish a
                    // newer edit even when it was later cleared back to empty.
                    draftRevision += 1
                    slashController.update(composerText: newText)
                    // Cleanup is app-owned and may run after a cancellation
                    // while this newer draft remains mounted. Keep DraftStore
                    // current so shared attachment files stay protected.
                    DraftStore.shared.save(
                        sessionId: session.sessionId,
                        text: newText,
                        attachments: attachments
                    )
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
            .onChange(of: isProcessing) { _, processing in
                guard !processing else { return }
                clearSnapshotsWithoutPendingEcho()
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
            // Generation ownership lives in the app-level service. This
            // observation is idempotent for an unchanged session and lets a
            // same-session process replacement rebind this mounted renderer.
            let generationID = recoveryScope.observeAuthoritativeSession(session)
            terminalIdentityCapability.refresh(
                session: session,
                generationID: generationID
            )
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
        .onDisappear {
            persistDraft()
            terminalIdentityCapability.cancel(sessionID: session.sessionId)
            // Recovery state is app-owned and intentionally survives view
            // destruction/session switches. Explicit repository removal uses
            // ComposerRecoveryScopeStore.forget instead.
        }
        .onChange(of: identityCapabilityKey) { _, _ in
            terminalIdentityCapability.refresh(
                session: session,
                generationID: composerGenerationID
            )
        }
        // ESC is dispatched from WindowChatView's chat-level monitor
        // (which knows about drill-down overlays). It posts ONE of
        // these two notifications based on context. The composer
        // handles both: cancel an in-flight query OR clear the draft.
        .onReceive(NotificationCenter.default.publisher(for: WindowComposer.requestCancel)) { _ in
            cancelQuery()
        }
        .onReceive(NotificationCenter.default.publisher(for: WindowComposer.requestClearDraft)) { _ in
            // WindowChatView consumes Escape during compaction, but keep this
            // second guard at the mutating seam so another notification
            // source cannot clear the user's draft while the provider owns
            // the active compaction operation.
            guard session.phase != .compacting else { return }
            let removedAttachments = attachments
            inputText = ""
            attachments = []
            draftRevision += 1
            slashController.close()
            persistDraft()
            scheduleAttachmentCleanup(removedAttachments, event: .explicitDismiss)
        }
    }

    private var identityCapabilityKey: TerminalIdentityCapabilityKey {
        TerminalIdentityCapabilityPolicy.key(
            session: session,
            generationID: composerGenerationID
        )
    }

    private var visibleRecoveryEntries: [ComposerSendRecoveryEntry] {
        recoveryScope.entries(
            sessionID: session.sessionId,
            generationID: composerGenerationID
        )
    }

    @ViewBuilder
    private var recoveryCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleRecoveryEntries) { entry in
                let presentation = ComposerSendRecoveryPresentationPolicy.presentation(for: entry)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(presentation.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if presentation.attachmentCount > 0 {
                            Text("\(presentation.attachmentCount) attachment\(presentation.attachmentCount == 1 ? "" : "s") retained")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if presentation.canConfirmRiskRetry {
                        Button("Retry anyway") {
                            retryRecovery(entry.recoveryID, allowUncertain: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("Retry uncertain message")
                        .accessibilityHint("The message may already have reached the agent")
                        if presentation.canRestore {
                            Button("Restore") {
                                restoreUncertain(entry.recoveryID)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Restore uncertain message draft")
                        }
                        Button("Dismiss") {
                            dismissRecovery(entry.recoveryID)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Dismiss uncertain message")
                    } else if !presentation.canRetry {
                        Text("Retrying…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(presentation.accessibilityLabel)
                    } else {
                        Button("Retry") {
                            retryRecovery(entry.recoveryID)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("Retry failed message")
                        .accessibilityHint("Send the retained message and attachments again")
                        Button("Dismiss") {
                            dismissRecovery(entry.recoveryID)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Dismiss failed message")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.systemOrange).opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(NSColor.systemOrange).opacity(0.35), lineWidth: 1)
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel(presentation.accessibilityLabel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
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
                            draftRevision += 1
                            persistDraft()
                            // A failed/retrying submission may still own this
                            // file.  Delayed cleanup rechecks exact recovery
                            // references before releasing it.
                            scheduleAttachmentCleanup(
                                [attachment],
                                event: .explicitDismiss
                            )
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 56)
    }

    private func handleImagePaste(_ image: NSImage) {
        guard session.imageSubmissionRoute != .unavailable else {
            showAttachmentAdmissionError("This session cannot receive image attachments.")
            return
        }
        guard let url = ImagePasteSender.savePNG(image) else {
            showAttachmentAdmissionError("The image could not be encoded for delivery.")
            return
        }
        let thumbnail = Self.makeThumbnail(from: image, maxSize: 80)
        let attachment = ImageAttachment(id: UUID(), url: url, thumbnail: thumbnail)
        let result = ImageAttachmentAdmissionPolicy.validate(
            (attachments + [attachment]).map(Self.admissionMetadata(for:))
        )
        guard result.isAccepted else {
            try? FileManager.default.removeItem(at: url)
            showAttachmentAdmissionError(Self.admissionMessage(for: result))
            return
        }
        attachmentAdmissionError = nil
        attachments.append(attachment)
        draftRevision += 1
        persistDraft()
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

    private static func admissionMetadata(
        for attachment: ImageAttachment
    ) -> ImageAttachmentAdmissionMetadata {
        let fileExists = FileManager.default.fileExists(atPath: attachment.url.path)
        let byteCount: Int
        if let values = try? FileManager.default.attributesOfItem(atPath: attachment.url.path),
           let number = values[.size] as? NSNumber {
            byteCount = number.intValue
        } else {
            byteCount = -1
        }
        let data = try? Data(contentsOf: attachment.url)
        let bitmap = data.flatMap(NSBitmapImageRep.init(data:))
        let decodedImage = bitmap == nil ? NSImage(contentsOf: attachment.url) : nil
        let width = bitmap?.pixelsWide ?? Int(decodedImage?.size.width ?? 0)
        let height = bitmap?.pixelsHigh ?? Int(decodedImage?.size.height ?? 0)
        return ImageAttachmentAdmissionMetadata(
            id: attachment.id.uuidString,
            byteCount: byteCount,
            width: width,
            height: height,
            fileExists: fileExists,
            isDecodable: bitmap != nil || decodedImage != nil
        )
    }

    private static func admissionMessage(
        for result: ImageAttachmentAdmissionResult
    ) -> String {
        guard let issue = result.errors.first else {
            return "The image attachment was rejected."
        }
        switch issue.error {
        case .tooMany(let maximum):
            return "You can attach at most \(maximum) images."
        case .emptyID:
            return "The image attachment has no stable identity."
        case .missingFile:
            return "The image file is no longer available."
        case .undecodable:
            return "The image could not be decoded."
        case .invalidDimensions:
            return "The image dimensions are not supported."
        case .perFileTooLarge(let maximumBytes):
            return "Each image must be at most \(maximumBytes / 1_000_000) MB."
        case .aggregateTooLarge(let maximumBytes):
            return "Images together must be at most \(maximumBytes / 1_000_000) MB."
        }
    }

    private func showAttachmentAdmissionError(_ message: String) {
        attachmentAdmissionError = message
        NotificationCenter.default.post(
            name: .cvShowToast,
            object: nil,
            userInfo: ["text": message]
        )
    }

    // MARK: - Send

    private func sendMessage() {
        guard !cancelInFlight else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentAttachments = attachments
        guard !text.isEmpty || !currentAttachments.isEmpty else { return }
        guard currentAttachments.isEmpty || session.imageSubmissionRoute != .unavailable else {
            showAttachmentAdmissionError("This session cannot receive image attachments.")
            return
        }
        let admission = ImageAttachmentAdmissionPolicy.validate(
            currentAttachments.map(Self.admissionMetadata(for:))
        )
        guard admission.isAccepted else {
            showAttachmentAdmissionError(Self.admissionMessage(for: admission))
            return
        }

        let submittedRevision = draftRevision
        let submissionID = UUID().uuidString
        let preliminarySnapshot = SubmittedComposerSnapshot(
            deliveryID: submissionID,
            sessionId: session.sessionId,
            generationID: composerGenerationID,
            text: text,
            attachments: currentAttachments,
            pendingEchoID: nil,
            submittedRevision: submittedRevision,
            clearedRevision: submittedRevision + 1,
            imageRoute: session.imageSubmissionRoute
        )
        guard recoveryScope.canRegisterSubmission(preliminarySnapshot) else {
            showAttachmentAdmissionError(
                "Recovery storage is full. Resolve a recovery card before sending."
            )
            return
        }
        guard PendingEchoStore.shared.canAccept(sessionId: session.sessionId) else {
            showAttachmentAdmissionError(
                "Too many messages are awaiting delivery. Resolve a recovery card first."
            )
            return
        }

        // Optimistic local echo. JSONL syncs 1-2 s after send (TTY ↔
        // agent roundtrip), which reads as "the app ate my message" if
        // the bubble doesn't appear immediately. Pi's canonical user row
        // contains the composed paths, so echo that exact payload for
        // image-only visibility and deterministic transcript reconciliation.
        let pendingEchoText: String? = optimisticEchoText(
            text: text,
            currentAttachments: currentAttachments
        )
        let pendingEchoID: String?
        if let pendingEchoText {
            pendingEchoID = PendingEchoStore.shared.push(
                sessionId: session.sessionId,
                text: pendingEchoText,
                imageReferences: currentAttachments.map { $0.url.path },
                generationID: composerGenerationID,
                deliveryID: submissionID
            )
            guard pendingEchoID != nil else {
                inputText = text
                attachments = currentAttachments
                draftRevision = submittedRevision
                persistDraft()
                showAttachmentAdmissionError(
                    "The message could not be queued. Your draft remains in the composer."
                )
                return
            }
        } else {
            pendingEchoID = nil
        }
        let snapshot = SubmittedComposerSnapshot(
            deliveryID: submissionID,
            sessionId: session.sessionId,
            generationID: composerGenerationID,
            text: text,
            attachments: currentAttachments,
            pendingEchoID: pendingEchoID,
            submittedRevision: submittedRevision,
            clearedRevision: submittedRevision + 1,
            imageRoute: session.imageSubmissionRoute
        )
        // The shared scope is the atomic owner of this snapshot. If scope
        // admission fails, restore the exact text/images before any provider
        // work starts; no view-local side map may lose the submission.
        guard recoveryScope.registerSubmission(snapshot) else {
            if let pendingEchoID {
                PendingEchoStore.shared.evict(
                    sessionId: session.sessionId,
                    id: pendingEchoID,
                    reason: "scope-admission-rejected"
                )
            }
            inputText = text
            attachments = currentAttachments
            draftRevision = submittedRevision
            persistDraft()
            showAttachmentAdmissionError(
                "The message could not be queued. Your draft remains in the composer."
            )
            return
        }

        // Clear only after the complete snapshot has been admitted by both
        // the recovery scope and the optimistic echo store.  Any rejected
        // path above therefore leaves text, images, and files untouched.
        inputText = ""
        attachments = []
        draftRevision += 1
        slashController.close()
        attachmentAdmissionError = nil
        persistDraft()

        NotificationCenter.default.post(
            name: WindowComposer.didSendMessage,
            object: session.sessionId
        )

        let target = session
        Task {
            let outcome = await SessionSender.send(
                text: text,
                attachments: currentAttachments,
                to: target,
                keepFocusOnHost: false
            )
            await MainActor.run {
                recoveryScope.markResolved(
                    deliveryID: submissionID,
                    sessionID: target.sessionId,
                    generationID: snapshot.generationID
                )
                switch outcome {
                case .delivered:
                    clearSnapshotIfResolved(submissionID)
                case .failedBeforeWrite(let reason):
                    recoverSubmission(
                        submissionID,
                        reason: reason
                    )
                case .uncertainAfterPartialWrite(let reason, let completedSteps):
                    let stepWord = completedSteps.count == 1 ? "step" : "steps"
                    recoverUncertainSubmission(
                        submissionID,
                        reason: "Delivery may be partial (\(completedSteps.count) \(stepWord) completed): \(reason)"
                    )
                }
            }
        }
    }

    private func scheduleAttachmentCleanup(
        _ attachments: [ImageAttachment],
        event: ImageAttachmentRetentionPolicy.TerminalEvent = .canonicalSuccess
    ) {
        recoveryScope.scheduleAttachmentCleanup(
            attachments,
            route: session.imageSubmissionRoute,
            event: event
        )
    }

    private func optimisticEchoText(
        text: String,
        currentAttachments: [ImageAttachment]
    ) -> String? {
        switch session.imageSubmissionRoute {
        case .terminalPathPrompt:
            return PiImagePromptComposer.compose(
                text: text,
                imagePaths: currentAttachments.map { $0.url.path }
            )
        case .appServerLocalImage, .terminalAttachment, .unavailable:
            // Image-only sends still need a visible, recoverable row. The
            // placeholder is not used as a content-only canonical match.
            return text.isEmpty
                ? (currentAttachments.isEmpty ? nil : "[Image]")
                : text
        }
    }

    // MARK: - Cancel

    private func cancelQuery() {
        let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "Cancel")
        logger.info("cancel: triggered isProcessing=\(isProcessing, privacy: .public) inFlight=\(cancelInFlight, privacy: .public)")
        guard isProcessing,
              canCancelProcessing,
              !cancelInFlight else {
            logger.info("cancel: skip — not processing or already in flight")
            return
        }
        let target = session
        guard let snapshot = recoveryScope.activeSnapshot(
                  sessionID: target.sessionId,
                  generationID: composerGenerationID
              ),
              snapshot.sessionId == target.sessionId else {
            logger.info("cancel: skip — no submitted snapshot for session")
            return
        }
        let submissionID = snapshot.deliveryID
        let operationID = "chat-cancel-\(UUID().uuidString)"
        let textToRestore = snapshot.text
        cancelInFlight = true
        logger.info("cancel: tty=\(target.tty ?? "nil", privacy: .public) submittedLen=\(textToRestore.count, privacy: .public) attachments=\(snapshot.attachments.count, privacy: .public)")
        // Do not evict the optimistic echo until the terminal confirms
        // Escape. If the helper fails, the echo and immutable snapshot remain
        // available for a retry and the current composer is untouched.
        let terminalHost = target.terminalHost
        // Destructive prompt clearing runs off the main actor, so every chunk
        // re-enters the composer state before sending. A user edit, session
        // replacement, or newer submission must turn cancellation into a
        // non-destructive failure rather than deleting the wrong prompt.
        let cancellationState: () -> ComposerCancellationClearState? = {
            DispatchQueue.main.sync {
                guard recoveryScope.snapshot(
                    deliveryID: submissionID,
                    sessionID: target.sessionId,
                    generationID: composerGenerationID
                ) == snapshot,
                      session.sessionId == target.sessionId else { return nil }
                return ComposerCancellationClearState(
                    sessionId: target.sessionId,
                    submissionId: submissionID,
                    clearedRevision: snapshot.clearedRevision,
                    textIsEmpty: inputText.isEmpty,
                    attachmentIDs: attachments.map { $0.id.uuidString }
                )
            }
        }
        Task { @MainActor in
            do {
                try await TerminalTransportSerializer.shared.withLane(
                    sessionID: target.sessionId,
                    ownerID: operationID,
                    operationTimeout: 120,
                    operation: {
                    await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { completion.resume() }
            let ok: Bool
            switch terminalHost {
            case .iterm2:
                ok = ITermAdapter().sendEscape(
                    toSession: target,
                    operationID: operationID
                )
            case .ghostty:
                ok = GhosttyScripting.sendKeystroke(
                    named: "escape",
                    toSession: target,
                    operationID: operationID
                )
            case .terminalApp:
                ok = TerminalAppAdapter().sendEscape(
                    toSession: target,
                    operationID: operationID
                )
            default:
                // Unsupported/read-only hosts must fail closed. In
                // particular, Terminal.app must never be treated as a
                // Ghostty fallback just because both are terminal hosts.
                ok = false
            }
            logger.info("cancel: ESC sent host=\(terminalHost?.rawValue ?? "unknown", privacy: .public) ok=\(ok, privacy: .public)")
            guard ok else {
                logger.error("cancel: ESC FAILED — bailing without clear")
                DispatchQueue.main.async {
                    // Failure is deliberately non-destructive: retain the
                    // echo, snapshot, and whatever the user is composing.
                    cancelInFlight = false
                }
                return
            }
            // Always clear the TUI's prompt buffer after ESC. Claude
            // Code preserves the user's input on interrupt by design,
            // so without this clear the canceled text sits in the
            // buffer and gets prepended to the next send.
            usleep(200_000)
            var clearProgress = ComposerCancellationClearProgress(expected: ComposerCancellationClearState(
                sessionId: target.sessionId,
                submissionId: submissionID,
                clearedRevision: snapshot.clearedRevision,
                textIsEmpty: true,
                attachmentIDs: []
            ))
            if terminalHost == .iterm2 {
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
                // ponytail: cap the recovery clear burst at 4,096 chars and
                // keep each 256-byte PTY write bounded; raise only with a
                // matching Swift/helper wire-limit review.
                let totalToSend = min(4096, max(256, textToRestore.count * 3))
                let chunkSize = 256  // iTerm `write text` is one PTY
                                     // write per call — much higher
                                     // safe-chunk-size than Ghostty's
                                     // per-keystroke `send key`.
                var remaining = totalToSend
                var chunkCount = 0
                var okCount = 0
                var clearSucceeded = true
                while remaining > 0 {
                    guard let current = cancellationState(),
                          clearProgress.beginChunk(current: current) == .proceed else {
                        clearSucceeded = false
                        clearProgress.abort()
                        break
                    }
                    let n = min(chunkSize, remaining)
                    let chunkOk = ITermAdapter().sendBackspaces(
                        count: n,
                        toSession: target,
                        operationID: operationID
                    )
                    if chunkOk { okCount += 1 }
                    if clearProgress.finishChunk(succeeded: chunkOk) == .aborted {
                        clearSucceeded = false
                    }
                    chunkCount += 1
                    remaining -= n
                    if !clearSucceeded { break }
                    usleep(20_000)
                }
                logger.info("cancel: iTerm clear total=\(totalToSend, privacy: .public) chunks=\(chunkCount, privacy: .public) ok=\(okCount, privacy: .public)")
                guard clearSucceeded else {
                    DispatchQueue.main.async { cancelInFlight = false }
                    return
                }
            } else if terminalHost == .ghostty {
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
                // ponytail: cap the recovery clear burst at 4,096 chars and
                // keep each 64-key AppleScript batch bounded; raise only with
                // a matching Swift/helper wire-limit review.
                let totalToSend = min(4096, max(256, textToRestore.count * 3))
                let chunkSize = 64
                var remaining = totalToSend
                var chunkCount = 0
                var okCount = 0
                var clearSucceeded = true
                while remaining > 0 {
                    guard let current = cancellationState(),
                          clearProgress.beginChunk(current: current) == .proceed else {
                        clearSucceeded = false
                        clearProgress.abort()
                        break
                    }
                    let n = min(chunkSize, remaining)
                    let chunkOk = GhosttyScripting.sendBackspaces(
                        count: n,
                        toSession: target,
                        operationID: operationID
                    )
                    if chunkOk { okCount += 1 }
                    if clearProgress.finishChunk(succeeded: chunkOk) == .aborted {
                        clearSucceeded = false
                    }
                    chunkCount += 1
                    remaining -= n
                    if !clearSucceeded { break }
                    usleep(20_000)  // 20ms settle between chunks
                }
                logger.info("cancel: clear total=\(totalToSend, privacy: .public) chunks=\(chunkCount, privacy: .public) ok=\(okCount, privacy: .public)")
                guard clearSucceeded else {
                    DispatchQueue.main.async { cancelInFlight = false }
                    return
                }
            } else if terminalHost == .terminalApp {
                // Terminal.app has a host-specific System Events route; do
                // not reuse Ghostty's OSC-7/backspace path.
                let totalToSend = min(4096, max(256, textToRestore.count * 3))
                let chunkSize = 128
                var remaining = totalToSend
                var clearSucceeded = true
                while remaining > 0 {
                    guard let current = cancellationState(),
                          clearProgress.beginChunk(current: current) == .proceed else {
                        clearSucceeded = false
                        clearProgress.abort()
                        break
                    }
                    let n = min(chunkSize, remaining)
                    let chunkOk = TerminalAppAdapter().sendBackspaces(
                        count: n,
                        toSession: target,
                        operationID: operationID
                    )
                    if clearProgress.finishChunk(succeeded: chunkOk) == .aborted {
                        clearSucceeded = false
                    }
                    remaining -= n
                    if !clearSucceeded { break }
                    usleep(20_000)
                }
                guard clearSucceeded else {
                    DispatchQueue.main.async { cancelInFlight = false }
                    return
                }
            } else {
                DispatchQueue.main.async { cancelInFlight = false }
                return
            }
            DispatchQueue.main.async {
                defer { cancelInFlight = false }
                // A newer submission may have replaced the snapshot while
                // Escape was in flight. In that case neither its echo nor its
                // composer state belongs to this cancellation result.
                guard recoveryScope.snapshot(
                    deliveryID: submissionID,
                    sessionID: target.sessionId,
                    generationID: composerGenerationID
                ) == snapshot else {
                    logger.info("cancel: snapshot superseded while Escape was in flight")
                    return
                }
                let decision = ComposerCancellationRecoveryPolicy.decision(
                    snapshot: snapshot.recoveryPolicySnapshot,
                    currentSessionId: target.sessionId,
                    currentText: inputText,
                    currentAttachmentIDs: attachments.map { $0.id.uuidString },
                    currentRevision: draftRevision
                )
                if case .restore = decision {
                    inputText = snapshot.text
                    attachments = snapshot.attachments
                    draftRevision += 1
                    persistDraft()
                } else {
                    logger.info("cancel: preserving newer composer edits")
                }
                if let echoId = snapshot.pendingEchoID {
                    PendingEchoStore.shared.evict(
                        sessionId: target.sessionId,
                        id: echoId,
                        reason: "canceled"
                    )
                }
                _ = recoveryScope.removeSubmission(
                    deliveryID: submissionID,
                    sessionID: target.sessionId,
                    generationID: composerGenerationID,
                    event: .explicitDismiss
                )
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
                , terminate: {
                    await ProcessExecutor.shared.terminateActiveProcesses(
                        operationID: operationID
                    )
                }
                )
            } catch {
                // A bounded acquisition/operation failure is non-destructive:
                // retain the exact snapshot and optimistic echo for retry.
                logger.error("cancel: transport lane failed: \(error.localizedDescription, privacy: .public)")
                cancelInFlight = false
            }
        }
    }

    /// A failed direct send uses the same non-clobbering revision policy as a
    /// confirmed cancel, but keeps its optimistic row and exact ledger entry
    /// so the user can retry from the preserved delivery context.
    private func recoverSubmission(
        _ submissionID: String,
        reason: String
    ) {
        guard let snapshot = recoveryScope.snapshot(
                  deliveryID: submissionID,
                  sessionID: session.sessionId,
                  generationID: composerGenerationID
              ),
              snapshot.sessionId == session.sessionId,
              snapshot.generationID == composerGenerationID else { return }
        let admission = recoveryScope.recordFailure(snapshot, reason: reason)
        guard admission == .retained else {
            // The bounded ledger refuses to drop user content silently. Put
            // the exact submitted text/images back before showing guidance.
            restoreComposerIfSafe(from: snapshot)
            NotificationCenter.default.post(
                name: .cvShowToast,
                object: nil,
                userInfo: [
                    "text": "Couldn’t retain the retry card. Your draft remains in the composer."
                ]
            )
            return
        }
        let decision = ComposerCancellationRecoveryPolicy.decision(
            snapshot: snapshot.recoveryPolicySnapshot,
            currentSessionId: session.sessionId,
            currentText: inputText,
            currentAttachmentIDs: attachments.map { $0.id.uuidString },
            currentRevision: draftRevision
        )
        if case .restore = decision {
            restoreComposer(from: snapshot)
        }
    }

    /// Retain a partial terminal delivery without automatically putting its
    /// snapshot back in the composer.  Earlier attachment/text writes may
    /// already have reached the provider, so an ordinary retry could
    /// duplicate user content.  The card exposes Restore, Dismiss, and an
    /// explicit risk-confirmed retry instead.
    private func recoverUncertainSubmission(
        _ submissionID: String,
        reason: String
    ) {
        guard let snapshot = recoveryScope.snapshot(
                  deliveryID: submissionID,
                  sessionID: session.sessionId,
                  generationID: composerGenerationID
              ),
              snapshot.sessionId == session.sessionId,
              snapshot.generationID == composerGenerationID else { return }
        let admission = recoveryScope.recordUncertain(snapshot, reason: reason)
        guard admission == .retained else {
            // A full ledger must never turn a partial send into silent data
            // loss. Restore only when the composer still has the submitted
            // clear state; otherwise leave newer edits untouched and explain
            // the fail-safe through the existing accessible toast channel.
            restoreComposerIfSafe(from: snapshot)
            NotificationCenter.default.post(
                name: .cvShowToast,
                object: nil,
                userInfo: [
                    "text": "Couldn’t retain the uncertain delivery. Your draft remains in the composer."
                ]
            )
            return
        }
        // Do not restore here.  The user may have edited the composer while
        // the provider was processing; Restore performs the same revision
        // guard when explicitly requested from the card.
    }

    private func retryRecovery(_ recoveryID: String, allowUncertain: Bool = false) {
        guard let entry = recoveryScope.entry(
                  recoveryID: recoveryID,
                  sessionID: session.sessionId,
                  generationID: composerGenerationID
              ),
              let original = recoveryScope.snapshotForRecovery(
                  recoveryID: recoveryID,
                  sessionID: session.sessionId,
                  generationID: composerGenerationID
              ),
              original.sessionId == session.sessionId,
              original.generationID == composerGenerationID else { return }
        switch entry.state {
        case .failed:
            break
        case .uncertain where allowUncertain:
            break
        default:
            return
        }

        let shouldClear = ComposerSendRecoveryLedger.shouldClearComposerForRetry(
            snapshot: entry.snapshot,
            currentText: inputText,
            currentAttachmentIDs: attachments.map { $0.id.uuidString },
            currentRevision: draftRevision
        )
        let nextRevision = shouldClear ? draftRevision + 1 : draftRevision
        let nextDeliveryID = UUID().uuidString
        let nextEchoText = optimisticEchoText(
            text: original.text,
            currentAttachments: original.attachments
        )
        let nextEchoID = nextEchoText.flatMap {
            PendingEchoStore.shared.push(
                sessionId: session.sessionId,
                text: $0,
                imageReferences: original.attachments.map { $0.url.path },
                generationID: composerGenerationID,
                deliveryID: nextDeliveryID
            )
        }
        // Do not transition the recovery card to awaiting-canonical when its
        // replacement echo could not be admitted.  Keeping the original card
        // and attachment references is the only lossless outcome at capacity.
        guard nextEchoID != nil || nextEchoText == nil else { return }
        let replacement = SubmittedComposerSnapshot(
            deliveryID: nextDeliveryID,
            sessionId: original.sessionId,
            generationID: original.generationID,
            text: original.text,
            attachments: original.attachments,
            pendingEchoID: nextEchoID,
            submittedRevision: draftRevision,
            clearedRevision: nextRevision,
            imageRoute: session.imageSubmissionRoute
        )
        guard let retry = recoveryScope.beginRetry(
            recoveryID: recoveryID,
            sessionID: session.sessionId,
            generationID: composerGenerationID,
            replacement: replacement,
            allowUncertain: allowUncertain
        ) else {
            if let nextEchoID {
                PendingEchoStore.shared.evict(
                    sessionId: session.sessionId,
                    id: nextEchoID,
                    reason: "superseded"
                )
            }
            return
        }
        guard retry.isNew else {
            if let nextEchoID {
                PendingEchoStore.shared.evict(
                    sessionId: session.sessionId,
                    id: nextEchoID,
                    reason: "superseded"
                )
            }
            return
        }

        // Retire the prior synthetic row only after Core accepted the exact
        // replacement transition. A failed replacement remains actionable
        // under the new identity.
        if let oldEchoID = original.pendingEchoID {
            PendingEchoStore.shared.evict(
                sessionId: session.sessionId,
                id: oldEchoID,
                reason: "superseded"
            )
        }
        if shouldClear {
            inputText = ""
            attachments = []
            draftRevision = nextRevision
            persistDraft()
        }
        NotificationCenter.default.post(
            name: WindowComposer.didSendMessage,
            object: session.sessionId
        )

        let target = session
        Task {
            let outcome = await SessionSender.send(
                text: replacement.text,
                attachments: replacement.attachments,
                to: target,
                keepFocusOnHost: false
            )
            await MainActor.run {
                recoveryScope.markResolved(
                    deliveryID: nextDeliveryID,
                    sessionID: target.sessionId,
                    generationID: replacement.generationID
                )
                switch outcome {
                case .delivered:
                    _ = recoveryScope.finishRetry(
                        recoveryID: recoveryID,
                        deliveryID: nextDeliveryID,
                        sessionID: target.sessionId,
                        generationID: replacement.generationID,
                        succeeded: true
                    )
                case .failedBeforeWrite(let reason):
                    _ = recoveryScope.finishRetry(
                        recoveryID: recoveryID,
                        deliveryID: nextDeliveryID,
                        sessionID: target.sessionId,
                        generationID: replacement.generationID,
                        succeeded: false,
                        reason: reason
                    )
                    restoreComposerIfSafe(from: replacement)
                case .uncertainAfterPartialWrite(let reason, let completedSteps):
                    let stepWord = completedSteps.count == 1 ? "step" : "steps"
                    let retryReason = "Retry may be partial (\(completedSteps.count) \(stepWord) completed): \(reason)"
                    _ = recoveryScope.finishRetryUncertain(
                        recoveryID: recoveryID,
                        deliveryID: nextDeliveryID,
                        sessionID: target.sessionId,
                        generationID: replacement.generationID,
                        reason: retryReason
                    )
                }
            }
        }
    }

    private func dismissRecovery(_ recoveryID: String) {
        guard let snapshot = recoveryScope.dismiss(
                recoveryID: recoveryID,
                sessionID: session.sessionId,
                generationID: composerGenerationID
              ) else { return }
        if let echoID = snapshot.pendingEchoID {
            PendingEchoStore.shared.evict(
                sessionId: session.sessionId,
                id: echoID,
                reason: "dismissed"
            )
        }
    }

    private func restoreUncertain(_ recoveryID: String) {
        guard let snapshot = recoveryScope.snapshotForRecovery(
                  recoveryID: recoveryID,
                  sessionID: session.sessionId,
                  generationID: composerGenerationID
              ) else { return }
        let decision = ComposerCancellationRecoveryPolicy.decision(
            snapshot: snapshot.recoveryPolicySnapshot,
            currentSessionId: session.sessionId,
            currentText: inputText,
            currentAttachmentIDs: attachments.map { $0.id.uuidString },
            currentRevision: draftRevision
        )
        guard case .restore = decision else {
            NotificationCenter.default.post(
                name: .cvShowToast,
                object: nil,
                userInfo: [
                    "text": "Your newer composer edits were preserved; the uncertain delivery remains available."
                ]
            )
            return
        }
        restoreComposer(from: snapshot)
        dismissRecovery(recoveryID)
    }

    private func restoreComposerIfSafe(from snapshot: SubmittedComposerSnapshot) {
        let decision = ComposerCancellationRecoveryPolicy.decision(
            snapshot: snapshot.recoveryPolicySnapshot,
            currentSessionId: session.sessionId,
            currentText: inputText,
            currentAttachmentIDs: attachments.map { $0.id.uuidString },
            currentRevision: draftRevision
        )
        if case .restore = decision { restoreComposer(from: snapshot) }
    }

    private func restoreComposer(from snapshot: SubmittedComposerSnapshot) {
        inputText = snapshot.text
        attachments = snapshot.attachments
        draftRevision += 1
        persistDraft()
    }

    private func clearSnapshotsWithoutPendingEcho() {
        for snapshot in recoveryScope.submissions(
            sessionID: session.sessionId,
            generationID: composerGenerationID
        ) {
            guard !recoveryScope.isPending(
                deliveryID: snapshot.deliveryID,
                sessionID: session.sessionId,
                generationID: composerGenerationID
            ),
            !recoveryScope.isRecovery(
                deliveryID: snapshot.deliveryID,
                sessionID: session.sessionId,
                generationID: composerGenerationID
            ) else { continue }
            guard let echoID = snapshot.pendingEchoID,
                  !PendingEchoStore.shared.contains(
                      sessionId: session.sessionId,
                      id: echoID
                  ) else { continue }
            _ = recoveryScope.removeSubmission(
                deliveryID: snapshot.deliveryID,
                sessionID: session.sessionId,
                generationID: composerGenerationID,
                event: .expiredAfterRestore
            )
        }
    }

    private func removeSnapshots(for event: ComposerSnapshotLifecycleEvent) {
        if case .canonical(let sessionID, let echoID) = event {
            // A canonical row is the only implicit success signal. Hold the
            // files until the aggregate send has also settled, then schedule
            // cleanup for exactly these snapshots; a send acknowledgement
            // alone is intentionally insufficient.
            _ = recoveryScope.removeResolvedCanonical(
                sessionID: sessionID,
                generationID: composerGenerationID,
                pendingEchoID: echoID
            )
            _ = recoveryScope.reconcileCanonical(
                sessionID: sessionID,
                generationID: composerGenerationID,
                pendingEchoID: echoID
            )
        }
    }

    private func clearSnapshotIfResolved(_ submissionID: String) {
        guard let snapshot = recoveryScope.snapshot(
                  deliveryID: submissionID,
                  sessionID: session.sessionId,
                  generationID: composerGenerationID
              ),
              !recoveryScope.isPending(
                  deliveryID: submissionID,
                  sessionID: session.sessionId,
                  generationID: composerGenerationID
              ),
              let echoID = snapshot.pendingEchoID,
              !PendingEchoStore.shared.contains(sessionId: session.sessionId, id: echoID) else { return }
        switch recoveryScope.deliveredAckDisposition(
            deliveryID: submissionID,
            sessionID: session.sessionId,
            generationID: composerGenerationID
        ) {
        case .removeSnapshot:
            _ = recoveryScope.removeSubmission(
                deliveryID: submissionID,
                sessionID: session.sessionId,
                generationID: composerGenerationID,
                event: .canonicalSuccess
            )
        case .retainRecoverySnapshot, .ignore:
            return
        }
    }
}
