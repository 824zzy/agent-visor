//
//  ComposerRecoveryScopeStore.swift
//  AgentVisor
//
//  App-owned lifetime for submitted composer snapshots and recovery cards.
//  WindowComposer instances are intentionally ephemeral (session switches,
//  window destruction, and SwiftUI identity changes recreate them), while a
//  failed send must remain recoverable across those boundaries.  This store
//  is the single app-level owner of the Core recovery ledger and the
//  AppKit attachment values that make a retry possible.
//

import AgentVisorCore
import AppKit
import Combine
import Foundation

/// The complete immutable value captured at the instant a composer submit
/// clears its fields.  The attachment values stay with the exact delivery so
/// a later edit, retry, or session cannot accidentally borrow them.
struct SubmittedComposerSnapshot: Equatable {
    let deliveryID: String
    let sessionId: String
    let generationID: String
    let text: String
    let attachments: [ImageAttachment]
    let pendingEchoID: String?
    let submittedRevision: Int
    let clearedRevision: Int
    /// The route used by this delivery, retained with the snapshot so file
    /// cleanup does not depend on whichever provider happens to be mounted
    /// when the view later disappears.
    let imageRoute: ImageSubmissionRoute

    init(
        deliveryID: String,
        sessionId: String,
        generationID: String,
        text: String,
        attachments: [ImageAttachment],
        pendingEchoID: String?,
        submittedRevision: Int,
        clearedRevision: Int,
        imageRoute: ImageSubmissionRoute = .unavailable
    ) {
        self.deliveryID = deliveryID
        self.sessionId = sessionId
        self.generationID = generationID
        self.text = text
        self.attachments = attachments
        self.pendingEchoID = pendingEchoID
        self.submittedRevision = submittedRevision
        self.clearedRevision = clearedRevision
        self.imageRoute = imageRoute
    }

    var recoveryPolicySnapshot: ComposerCancellationSnapshot {
        ComposerCancellationSnapshot(
            sessionId: sessionId,
            text: text,
            attachmentIDs: attachments.map { $0.id.uuidString },
            pendingEchoID: pendingEchoID,
            submittedRevision: submittedRevision,
            clearedRevision: clearedRevision
        )
    }

    @MainActor
    func sendRecoverySnapshot() -> ComposerSendRecoverySnapshot {
        ComposerSendRecoverySnapshot(
            deliveryID: deliveryID,
            sessionID: sessionId,
            generationID: generationID,
            text: text,
            attachmentIDs: attachments.map { $0.id.uuidString },
            attachmentMetadata: attachments.map(Self.recoveryMetadata(for:)),
            pendingEchoID: pendingEchoID,
            submittedRevision: submittedRevision,
            clearedRevision: clearedRevision
        )
    }

    private static func recoveryMetadata(
        for attachment: ImageAttachment
    ) -> ComposerSendRecoveryAttachment {
        let contentBytes = (try? FileManager.default.attributesOfItem(
            atPath: attachment.url.path
        )[.size] as? NSNumber)?.intValue ?? 0
        let thumbnailBytes = attachment.thumbnail.tiffRepresentation?.count ?? 0
        return ComposerSendRecoveryAttachment(
            id: attachment.id.uuidString,
            path: attachment.url.path,
            contentBytes: contentBytes,
            thumbnailBytes: thumbnailBytes
        )
    }
}

/// Shared app-level recovery scope service.
///
/// A scope is exact `(sessionID, generationID)`.  Switching away from a
/// session only changes the observing view; it does not destroy that scope.
/// Explicit repository removal or generation replacement is the only path
/// that releases it.  New scopes are rejected at the bound rather than
/// silently evicting actionable user content.
@MainActor
final class ComposerRecoveryScopeStore: ObservableObject {
    static let shared = ComposerRecoveryScopeStore()

    // ponytail: bound retained app scopes at 32.  Refuse admission when all
    // scopes contain recoverable content; increase only with persistence and
    // a user-visible recovery policy.
    static let maxScopes = 32

    typealias ScopeKey = ComposerRecoveryScopeKey

    private struct Scope {
        var snapshots: [String: SubmittedComposerSnapshot] = [:]
        var pendingDeliveryIDs: Set<String> = []
        var activeDeliveryID: String?
    }

    private struct AttachmentCleanupRequest {
        var attachments: [ImageAttachment]
        let route: ImageSubmissionRoute
        let event: ImageAttachmentRetentionPolicy.TerminalEvent
    }

    @Published private(set) var revision: UInt = 0

    private var policy = ComposerRecoveryScopeLedger()
    private var scopes: [ScopeKey: Scope] = [:]
    private var lifecycle = ComposerRecoveryLifecycleCoordinator()
    /// Last authoritative runtime identity observed for each repository
    /// session.  A mounted view must never infer this from its own lifetime:
    /// the same session id can be reattached to a new process instance.
    private var identityBySession: [String: ComposerRecoveryGenerationIdentity] = [:]
    /// Pending-echo expiry is app-owned so a view can disappear without
    /// stopping the TTL/canonical lifecycle.  Keys are exact session+echo
    /// identities; replacement generations cancel the old task.
    private var pendingEchoExpiryTasks: [String: Task<Void, Never>] = [:]
    /// Cleanup is owned by this service rather than a mounted composer. A
    /// request remains tracked when a draft/recovery reference still protects
    /// a file; a later scope or draft mutation drains it safely.
    private var attachmentCleanupRequests: [String: AttachmentCleanupRequest] = [:]
    private var attachmentCleanupTasks: [String: Task<Void, Never>] = [:]

    // ponytail: terminal cleanup work is bounded independently from the
    // recovery ledger. Keep at most 512 coalesced requests; if this bound is
    // reached, drain synchronously and retain any still-protected references.
    private static let maxAttachmentCleanupRequests = 512

    // ponytail: this is the one lifecycle scheduler for optimistic echoes.
    // Keep one bounded task per retained echo and cancel it on canonical,
    // dismissal, generation replacement, or repository removal.
    static let pendingEchoTTL: TimeInterval = 30

    private init() {}

    /// Returns the stable generation for a session for this app lifetime.
    /// Repository/session replacement should call `replaceGeneration` rather
    /// than inventing a generation in a view.
    func generation(for sessionID: String) -> String {
        policy.generation(for: sessionID)
    }

    /// Read-only generation lookup for renderers and action clients.  Unlike
    /// `generation(for:)`, this never creates ownership during a SwiftUI
    /// body evaluation.
    func currentGeneration(for sessionID: String) -> String? {
        policy.currentGeneration(for: sessionID)
    }

    /// Folds an authoritative SessionStore refresh into the app-owned
    /// generation ledger.  Same-PID process-token replacement is treated as a
    /// new provider identity; transient missing metadata is fail-closed and
    /// does not discard recoverable content.
    @discardableResult
    func observeAuthoritativeSession(_ session: SessionState) -> String {
        let observed = ComposerRecoveryGenerationIdentity(session: session)
        let current = policy.currentGeneration(for: session.sessionId)
            ?? policy.generation(for: session.sessionId)
        var generationID = current
        if let previous = identityBySession[session.sessionId],
           previous.requiresReplacement(comparedTo: observed) {
            let replacement = UUID().uuidString
            let oldSnapshots = replaceGeneration(
                sessionID: session.sessionId,
                from: current,
                to: replacement
            )
            // The old echo belongs to the retired process. Remove only that
            // exact echo; migrated snapshots remain restorable under the new
            // generation and their attachment files stay retained.
            for snapshot in oldSnapshots {
                if let echoID = snapshot.pendingEchoID {
                    PendingEchoStore.shared.evict(
                        sessionId: session.sessionId,
                        id: echoID,
                        reason: "generation-replaced"
                    )
                }
            }
            generationID = replacement
        }
        identityBySession[session.sessionId] = observed
        return generationID
    }

    /// Begin the one app-lifetime TTL for an optimistic echo.  This method is
    /// intentionally separate from the renderer so expiry continues while no
    /// WindowComposer is mounted.
    func schedulePendingEchoExpiry(
        sessionID: String,
        echoID: String,
        generationID: String? = nil,
        deliveryID: String? = nil
    ) -> Bool {
        let resolvedGeneration = generationID
            ?? currentGeneration(for: sessionID)
            ?? generation(for: sessionID)
        let expiresAt = Date().addingTimeInterval(Self.pendingEchoTTL)
        guard lifecycle.register(
            sessionID: sessionID,
            generationID: resolvedGeneration,
            echoID: echoID,
            deliveryID: deliveryID,
            expiresAt: expiresAt
        ) else { return false }
        let key = pendingEchoTaskKey(sessionID: sessionID, echoID: echoID)
        pendingEchoExpiryTasks[key]?.cancel()
        pendingEchoExpiryTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.pendingEchoTTL * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let expired = self.lifecycle.expire(at: Date())
                for echo in expired {
                    let taskKey = self.pendingEchoTaskKey(
                        sessionID: echo.sessionID,
                        echoID: echo.echoID
                    )
                    self.pendingEchoExpiryTasks.removeValue(forKey: taskKey)?.cancel()
                    PendingEchoStore.shared.evict(
                        sessionId: echo.sessionID,
                        id: echo.echoID,
                        reason: "expired"
                    )
                }
            }
        }
        return true
    }

    func cancelPendingEchoExpiry(sessionID: String, echoID: String) {
        let key = pendingEchoTaskKey(sessionID: sessionID, echoID: echoID)
        pendingEchoExpiryTasks.removeValue(forKey: key)?.cancel()
        _ = lifecycle.cancel(sessionID: sessionID, echoID: echoID)
    }

    /// Clears every pending-echo timer and lifecycle record for one removed
    /// repository session. This is separate from `forget(sessionID:)`, which
    /// also removes recoverable composer snapshots; PendingEchoStore uses it
    /// when only its transcript-side scope is being retired.
    func forgetPendingEchoes(sessionID: String) {
        let pending = lifecycle.forget(sessionID: sessionID)
        for echo in pending {
            pendingEchoExpiryTasks.removeValue(
                forKey: pendingEchoTaskKey(sessionID: echo.sessionID, echoID: echo.echoID)
            )?.cancel()
        }
    }

    private func pendingEchoTaskKey(sessionID: String, echoID: String) -> String {
        "\(sessionID)\u{1f}\(echoID)"
    }

    /// Schedules cleanup for attachment values released by any terminal
    /// snapshot transition. The route is captured with the submission so a
    /// later provider/session refresh cannot shorten the retention window.
    func scheduleAttachmentCleanup(
        _ attachments: [ImageAttachment],
        route: ImageSubmissionRoute,
        event: ImageAttachmentRetentionPolicy.TerminalEvent = .canonicalSuccess
    ) {
        let uniqueAttachments = Dictionary(
            attachments.map { ($0.id.uuidString, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !uniqueAttachments.isEmpty else { return }

        // Coalesce repeated canonical/dismiss events for the same exact set.
        let key = attachmentCleanupKey(
            attachments: uniqueAttachments,
            route: route,
            event: event
        )
        if attachmentCleanupRequests[key] == nil,
           attachmentCleanupRequests.count >= Self.maxAttachmentCleanupRequests {
            // A cleanup request never represents the only copy of user data;
            // it is safe to attempt an immediate bounded drain. Protected
            // references remain in the request table and are not dropped.
            drainAttachmentCleanup()
        }
        attachmentCleanupRequests[key] = AttachmentCleanupRequest(
            attachments: uniqueAttachments,
            route: route,
            event: event
        )
        attachmentCleanupTasks[key]?.cancel()

        let delay = ImageAttachmentRetentionPolicy.cleanupDelay(for: route) ?? 0
        guard delay > 0 else {
            performAttachmentCleanup(key: key)
            return
        }
        attachmentCleanupTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.performAttachmentCleanup(key: key)
            }
        }
    }

    /// Rechecks cleanup requests after DraftStore or a recovery scope changes.
    /// This is intentionally public to the app module but remains MainActor
    /// isolated with the owning store; WindowComposer only delegates here.
    func drainAttachmentCleanup() {
        for key in Array(attachmentCleanupRequests.keys) {
            performAttachmentCleanup(key: key)
        }
    }

    private func attachmentCleanupKey(
        attachments: [ImageAttachment],
        route: ImageSubmissionRoute,
        event: ImageAttachmentRetentionPolicy.TerminalEvent
    ) -> String {
        let routeToken: String
        switch route {
        case .unavailable: routeToken = "unavailable"
        case .appServerLocalImage: routeToken = "app-server-local"
        case .terminalAttachment: routeToken = "terminal-attachment"
        case .terminalPathPrompt: routeToken = "terminal-path"
        }
        let eventToken: String
        switch event {
        case .canonicalSuccess: eventToken = "canonical"
        case .explicitDismiss: eventToken = "dismiss"
        case .expiredAfterRestore: eventToken = "expired"
        }
        return "\(routeToken):\(eventToken):\(attachments.map { $0.id.uuidString }.joined(separator: ","))"
    }

    private func performAttachmentCleanup(key: String) {
        guard var request = attachmentCleanupRequests[key] else { return }
        let retainedIDs = retainedAttachmentIDs()
        let releasableIDs = ImageAttachmentRetentionPolicy.releasableAttachmentIDs(
            request.attachments.map { $0.id.uuidString },
            event: request.event,
            retainedAttachmentIDs: retainedIDs
        )
        var remaining: [ImageAttachment] = []
        for attachment in request.attachments {
            let attachmentID = attachment.id.uuidString
            guard releasableIDs.contains(attachmentID) else {
                remaining.append(attachment)
                continue
            }
            do {
                try FileManager.default.removeItem(at: attachment.url)
            } catch {
                // Keep failed cleanup bounded and retry when a later draft or
                // scope transition drains the registry. Never forget a path
                // that still needs cleanup.
            }
            if FileManager.default.fileExists(atPath: attachment.url.path) {
                remaining.append(attachment)
            }
        }

        attachmentCleanupTasks.removeValue(forKey: key)?.cancel()
        if remaining.isEmpty {
            attachmentCleanupRequests.removeValue(forKey: key)
        } else {
            request.attachments = remaining
            attachmentCleanupRequests[key] = request
        }
    }

    /// Applies a canonical/expiry event without a mounted view.  The exact
    /// pending echo id is the only join key.  Canonical removes settled
    /// snapshots; expiry creates a visible recovery entry.  Attachment
    /// values are still owned by this service and are never released merely
    /// because a view disappeared.
    func handlePendingEchoLifecycle(sessionID: String, echoID: String, reason: String) {
        cancelPendingEchoExpiry(sessionID: sessionID, echoID: echoID)
        let keys = scopes.keys.filter { $0.sessionID == sessionID }
        for key in keys {
            if reason == "canonical" {
                _ = removeResolvedCanonical(
                    sessionID: sessionID,
                    generationID: key.generationID,
                    pendingEchoID: echoID
                )
                _ = reconcileCanonical(
                    sessionID: sessionID,
                    generationID: key.generationID,
                    pendingEchoID: echoID
                )
            } else if reason == "expired",
                      let snapshot = snapshot(
                          pendingEchoID: echoID,
                          sessionID: sessionID,
                          generationID: key.generationID
                      ) {
                let recoveryEntries = policy.entries(for: key)
                if recoveryEntries.contains(where: {
                    $0.snapshot.deliveryID == snapshot.deliveryID
                }) {
                    // A retry already owns this delivery under the original
                    // recovery ID. Expiry must transition that card in place;
                    // admitting the replacement snapshot would create a
                    // second card keyed by its delivery ID.
                    _ = recordFailureForPendingEcho(
                        snapshot,
                        pendingEchoID: echoID,
                        reason: "The message did not reach the agent. Your draft was restored."
                    )
                } else {
                    // The first attempt has no recovery card yet. Expiry is
                    // its terminal failure and therefore needs normal
                    // admission under the original delivery ID.
                    _ = recordFailure(
                        snapshot,
                        reason: "The message did not reach the agent. Your draft was restored."
                    )
                }
            }
        }
    }

    func entries(sessionID: String, generationID: String) -> [ComposerSendRecoveryEntry] {
        policy.entries(for: ScopeKey(sessionID: sessionID, generationID: generationID))
    }

    func entry(
        recoveryID: String,
        sessionID: String,
        generationID: String
    ) -> ComposerSendRecoveryEntry? {
        guard scopes[ScopeKey(sessionID: sessionID, generationID: generationID)] != nil else {
            return nil
        }
        return policy.entry(
            recoveryID: recoveryID,
            in: ScopeKey(sessionID: sessionID, generationID: generationID)
        )
    }

    func snapshot(
        deliveryID: String,
        sessionID: String,
        generationID: String
    ) -> SubmittedComposerSnapshot? {
        scopes[ScopeKey(sessionID: sessionID, generationID: generationID)]?.snapshots[deliveryID]
    }

    func submissions(sessionID: String, generationID: String) -> [SubmittedComposerSnapshot] {
        scopes[ScopeKey(sessionID: sessionID, generationID: generationID)]?.snapshots.values.map { $0 } ?? []
    }

    func isRecovery(
        deliveryID: String,
        sessionID: String,
        generationID: String
    ) -> Bool {
        policy.entries(for: ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: generationID
        )).contains { $0.snapshot.deliveryID == deliveryID }
    }

    /// Classifies a successful sender acknowledgement against the exact
    /// app-owned snapshot. A late acknowledgement may settle the live
    /// delivery marker, but it must not remove a snapshot already retained by
    /// an expiry-created recovery card.
    func deliveredAckDisposition(
        deliveryID: String,
        sessionID: String,
        generationID: String
    ) -> ComposerSnapshotLifecyclePolicy.DeliveredAckDisposition {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        return ComposerSnapshotLifecyclePolicy.deliveredAckDisposition(
            snapshot: scopes[key]?.snapshots[deliveryID]?.sendRecoverySnapshot(),
            deliveryID: deliveryID,
            sessionID: sessionID,
            generationID: generationID,
            recoveryEntries: policy.entries(for: key)
        )
    }

    func snapshotForRecovery(
        recoveryID: String,
        sessionID: String,
        generationID: String
    ) -> SubmittedComposerSnapshot? {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard let scope = scopes[key],
              let entry = policy.entry(
                  recoveryID: recoveryID,
                  in: key
              ) else {
            return nil
        }
        return scope.snapshots[entry.snapshot.deliveryID]
    }

    func activeSnapshot(sessionID: String, generationID: String) -> SubmittedComposerSnapshot? {
        guard let scope = scopes[ScopeKey(sessionID: sessionID, generationID: generationID)],
              let activeID = scope.activeDeliveryID else {
            return nil
        }
        return scope.snapshots[activeID]
    }

    func snapshot(
        pendingEchoID: String,
        sessionID: String,
        generationID: String
    ) -> SubmittedComposerSnapshot? {
        scopes[ScopeKey(sessionID: sessionID, generationID: generationID)]?.snapshots.values
            .first { $0.pendingEchoID == pendingEchoID }
    }

    func isPending(
        deliveryID: String,
        sessionID: String,
        generationID: String
    ) -> Bool {
        scopes[ScopeKey(sessionID: sessionID, generationID: generationID)]?.pendingDeliveryIDs
            .contains(deliveryID) == true
    }

    /// Admission for a live send is checked before the view clears its
    /// composer.  This includes the bytes and attachment references retained
    /// by a recovery snapshot, not just the number of records.  The caller
    /// must preserve the complete draft when this returns false.
    func canRegisterSubmission(_ snapshot: SubmittedComposerSnapshot) -> Bool {
        let key = ScopeKey(
            sessionID: snapshot.sessionId,
            generationID: snapshot.generationID
        )
        guard let scope = scopes[key]
                ?? (policy.canEnsureScope(key) ? Scope() : nil),
              ComposerSendRecoveryLedger.canAdmitLiveSubmission(
                  existing: scope.snapshots.values.map {
                      $0.sendRecoverySnapshot()
                  },
                  candidate: snapshot.sendRecoverySnapshot()
              ) else {
            return false
        }
        return true
    }

    /// Compatibility query for non-submit callers that only know the scope.
    /// New sends should use `canRegisterSubmission(_:)` so byte and reference
    /// limits are checked before the composer is cleared.
    func canRegisterSubmission(sessionID: String, generationID: String) -> Bool {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard let scope = scopes[key] else {
            return policy.canEnsureScope(ComposerRecoveryScopeKey(
                sessionID: sessionID,
                generationID: generationID
            ))
        }
        return scope.snapshots.count < ComposerSendRecoveryLedger.maxRecords
    }

    /// Registers the snapshot before the provider send begins.  This is the
    /// atomic admission point: callers must keep the composer draft intact if
    /// it returns false.
    @discardableResult
    func registerSubmission(_ snapshot: SubmittedComposerSnapshot) -> Bool {
        guard canRegisterSubmission(snapshot) else { return false }
        guard let key = admitScope(sessionID: snapshot.sessionId, generationID: snapshot.generationID) else {
            return false
        }
        guard var scope = scopes[key], scope.snapshots[snapshot.deliveryID] == nil else {
            return false
        }
        scope.snapshots[snapshot.deliveryID] = snapshot
        scope.pendingDeliveryIDs.insert(snapshot.deliveryID)
        scope.activeDeliveryID = snapshot.deliveryID
        scopes[key] = scope
        publish()
        return true
    }

    func markResolved(
        deliveryID: String,
        sessionID: String,
        generationID: String
    ) {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard var scope = scopes[key] else { return }
        scope.pendingDeliveryIDs.remove(deliveryID)
        if scope.activeDeliveryID == deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        pruneEmptyScopes()
        publish()
    }

    @discardableResult
    func removeSubmission(
        deliveryID: String,
        sessionID: String,
        generationID: String,
        event: ImageAttachmentRetentionPolicy.TerminalEvent = .canonicalSuccess
    ) -> SubmittedComposerSnapshot? {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard var scope = scopes[key],
              let snapshot = scope.snapshots.removeValue(forKey: deliveryID) else {
            return nil
        }
        if let echoID = snapshot.pendingEchoID {
            cancelPendingEchoExpiry(sessionID: snapshot.sessionId, echoID: echoID)
        }
        scope.pendingDeliveryIDs.remove(deliveryID)
        if scope.activeDeliveryID == deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        pruneEmptyScopes()
        scheduleAttachmentCleanup(
            snapshot.attachments,
            route: snapshot.imageRoute,
            event: event
        )
        publish()
        return snapshot
    }

    /// Records a failure and retains the full AppKit snapshot only when Core
    /// admits the exact identity. A rejected admission leaves no side-map
    /// entry and lets the caller restore its complete draft immediately.
    @discardableResult
    func recordFailure(
        _ snapshot: SubmittedComposerSnapshot,
        reason: String
    ) -> ComposerSendRecoveryAdmission {
        guard let key = admitScope(sessionID: snapshot.sessionId, generationID: snapshot.generationID),
              var scope = scopes[key] else {
            return .rejected(reason: "Recovery is full. Your submitted message remains in the composer.")
        }
        let admission = policy.admitFailure(snapshot.sendRecoverySnapshot(), reason: reason)
        guard admission == .retained else { return admission }
        scope.snapshots[snapshot.deliveryID] = snapshot
        scope.pendingDeliveryIDs.remove(snapshot.deliveryID)
        if scope.activeDeliveryID == snapshot.deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        publish()
        return admission
    }

    /// Transitions an already-retained retry card to an actionable expiry
    /// failure. Core owns the recovery identity and replacement snapshot;
    /// this adapter only clears the live-delivery bookkeeping. Keeping this
    /// separate from `recordFailure` prevents admission from being keyed by
    /// the replacement delivery ID.
    @discardableResult
    func recordFailureForPendingEcho(
        _ snapshot: SubmittedComposerSnapshot,
        pendingEchoID: String,
        reason: String
    ) -> ComposerSendRecoveryAdmission {
        let key = ScopeKey(
            sessionID: snapshot.sessionId,
            generationID: snapshot.generationID
        )
        guard var scope = scopes[key],
              let existing = policy.entries(for: key).first(where: {
                  $0.snapshot.deliveryID == snapshot.deliveryID
                      && $0.snapshot.pendingEchoID == pendingEchoID
                      && $0.pendingEchoIDs.contains(pendingEchoID)
              }) else {
            return .rejected(reason: "The pending echo no longer owns this recovery entry.")
        }
        let admission = policy.recordFailureForPendingEcho(
            snapshot.sendRecoverySnapshot(),
            pendingEchoID: pendingEchoID,
            reason: reason,
            in: key
        )
        guard admission == .retained else { return admission }
        // The Core transition deliberately retains `existing.snapshot`, so
        // the app-side replacement snapshot remains keyed by the same
        // delivery ID. Only the in-flight markers change here.
        scope.pendingDeliveryIDs.remove(existing.snapshot.deliveryID)
        if scope.activeDeliveryID == existing.snapshot.deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        publish()
        return admission
    }

    /// Keeps a partial terminal delivery recoverable without advertising a
    /// one-click Retry that could duplicate already-written content.
    @discardableResult
    func recordUncertain(
        _ snapshot: SubmittedComposerSnapshot,
        reason: String
    ) -> ComposerSendRecoveryAdmission {
        guard let key = admitScope(sessionID: snapshot.sessionId, generationID: snapshot.generationID),
              var scope = scopes[key] else {
            return .rejected(reason: "Recovery is full. Your submitted message remains in the composer.")
        }
        let admission = policy.recordUncertain(snapshot.sendRecoverySnapshot(), reason: reason)
        guard admission == .retained else { return admission }
        scope.snapshots[snapshot.deliveryID] = snapshot
        scope.pendingDeliveryIDs.remove(snapshot.deliveryID)
        if scope.activeDeliveryID == snapshot.deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        publish()
        return admission
    }

    /// Starts a retry without deleting the original card until Core accepts
    /// the exact replacement.  The old AppKit snapshot therefore remains
    /// recoverable if admission fails.
    func beginRetry(
        recoveryID: String,
        sessionID: String,
        generationID: String,
        replacement: SubmittedComposerSnapshot,
        allowUncertain: Bool = false
    ) -> ComposerSendRecoveryRetry? {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard var scope = scopes[key],
              let previousEntry = policy.entry(recoveryID: recoveryID, in: key),
              let retry = policy.beginRetry(
                  recoveryID: recoveryID,
                  replacement: replacement.sendRecoverySnapshot(),
                  in: key,
                  allowUncertain: allowUncertain
              ) else {
            return nil
        }
        guard retry.isNew else {
            scopes[key] = scope
            return retry
        }
        let oldDeliveryID = previousEntry.snapshot.deliveryID
        if oldDeliveryID != replacement.deliveryID {
            scope.snapshots.removeValue(forKey: oldDeliveryID)
            scope.pendingDeliveryIDs.remove(oldDeliveryID)
        }
        scope.snapshots[replacement.deliveryID] = replacement
        scope.pendingDeliveryIDs.insert(replacement.deliveryID)
        scope.activeDeliveryID = replacement.deliveryID
        scopes[key] = scope
        publish()
        return retry
    }

    @discardableResult
    func finishRetry(
        recoveryID: String,
        deliveryID: String,
        sessionID: String,
        generationID: String,
        succeeded: Bool,
        reason: String = "Send failed"
    ) -> Bool {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard var scope = scopes[key],
              policy.finishRetry(
                  recoveryID: recoveryID,
                  deliveryID: deliveryID,
                  succeeded: succeeded,
                  reason: reason,
                  in: key
              ) else { return false }
        scope.pendingDeliveryIDs.remove(deliveryID)
        if scope.activeDeliveryID == deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        publish()
        return true
    }

    /// Atomically records a partial retry failure under the original recovery
    /// identity. Calling finishRetry(false) and then recordUncertain would
    /// admit the replacement delivery as a second recovery record.
    @discardableResult
    func finishRetryUncertain(
        recoveryID: String,
        deliveryID: String,
        sessionID: String,
        generationID: String,
        reason: String
    ) -> Bool {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard var scope = scopes[key],
              policy.finishRetryUncertain(
                  recoveryID: recoveryID,
                  deliveryID: deliveryID,
                  reason: reason,
                  in: key
              ) else { return false }
        scope.pendingDeliveryIDs.remove(deliveryID)
        if scope.activeDeliveryID == deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        publish()
        return true
    }

    /// Removes one exact failed card and returns its retained AppKit values
    /// for event-specific file cleanup.
    @discardableResult
    func dismiss(
        recoveryID: String,
        sessionID: String,
        generationID: String
    ) -> SubmittedComposerSnapshot? {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard var scope = scopes[key],
              let entry = policy.entry(recoveryID: recoveryID, in: key),
              policy.dismiss(recoveryID: recoveryID, in: key) else { return nil }
        if let echoID = entry.snapshot.pendingEchoID {
            cancelPendingEchoExpiry(sessionID: key.sessionID, echoID: echoID)
        }
        let snapshot = scope.snapshots.removeValue(forKey: entry.snapshot.deliveryID)
        scope.pendingDeliveryIDs.remove(entry.snapshot.deliveryID)
        if scope.activeDeliveryID == entry.snapshot.deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        pruneEmptyScopes()
        if let snapshot {
            scheduleAttachmentCleanup(
                snapshot.attachments,
                route: snapshot.imageRoute,
                event: .explicitDismiss
            )
        }
        publish()
        return snapshot
    }

    /// Reconciles only the exact echo in this scope. The returned snapshots
    /// are the only files eligible for canonical-success cleanup.
    @discardableResult
    func reconcileCanonical(
        sessionID: String,
        generationID: String,
        pendingEchoID: String
    ) -> [SubmittedComposerSnapshot] {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard var scope = scopes[key] else { return [] }
        let candidates = policy.entries(for: key).filter {
            $0.snapshot.pendingEchoID == pendingEchoID
                || $0.pendingEchoIDs.contains(pendingEchoID)
        }
        let removedIDs = policy.reconcileCanonical(pendingEchoID: pendingEchoID, in: key)
        var removed: [SubmittedComposerSnapshot] = []
        for recoveryID in removedIDs {
            guard let entry = candidates.first(where: { $0.recoveryID == recoveryID }) else { continue }
            if let snapshot = scope.snapshots.removeValue(forKey: entry.snapshot.deliveryID) {
                removed.append(snapshot)
                scope.pendingDeliveryIDs.remove(entry.snapshot.deliveryID)
                if scope.activeDeliveryID == entry.snapshot.deliveryID {
                    scope.activeDeliveryID = nil
                }
            }
        }
        scopes[key] = scope
        pruneEmptyScopes()
        for snapshot in removed {
            scheduleAttachmentCleanup(
                snapshot.attachments,
                route: snapshot.imageRoute,
                event: .canonicalSuccess
            )
        }
        if !removed.isEmpty { publish() }
        return removed
    }

    /// Removes a successfully canonical submitted snapshot that was never a
    /// recovery card. It deliberately ignores unresolved provider sends.
    @discardableResult
    func removeResolvedCanonical(
        sessionID: String,
        generationID: String,
        pendingEchoID: String
    ) -> [SubmittedComposerSnapshot] {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        guard var scope = scopes[key] else { return [] }
        let recoveryDeliveryIDs = Set(policy.entries(for: key).map { $0.snapshot.deliveryID })
        let ids = scope.snapshots.compactMap { deliveryID, snapshot -> String? in
            guard snapshot.pendingEchoID == pendingEchoID,
                  !scope.pendingDeliveryIDs.contains(deliveryID),
                  !recoveryDeliveryIDs.contains(deliveryID) else { return nil }
            return deliveryID
        }
        let removed = ids.compactMap { scope.snapshots.removeValue(forKey: $0) }
        for snapshot in removed {
            if let echoID = snapshot.pendingEchoID {
                cancelPendingEchoExpiry(sessionID: snapshot.sessionId, echoID: echoID)
            }
        }
        for deliveryID in ids where scope.activeDeliveryID == deliveryID {
            scope.activeDeliveryID = nil
        }
        scopes[key] = scope
        pruneEmptyScopes()
        for snapshot in removed {
            scheduleAttachmentCleanup(
                snapshot.attachments,
                route: snapshot.imageRoute,
                event: .canonicalSuccess
            )
        }
        if !removed.isEmpty { publish() }
        return removed
    }

    func retainedAttachmentIDs() -> Set<String> {
        var result = Set<String>()
        result.formUnion(policy.retainedAttachmentIDs)
        // DraftStore is the app-level owner for restored/current composer
        // files. It must participate even when no WindowComposer is mounted.
        result.formUnion(DraftStore.shared.retainedAttachmentIDs())
        for scope in scopes.values {
            result.formUnion(scope.snapshots.values.flatMap { snapshot in
                snapshot.attachments.map { $0.id.uuidString }
            })
        }
        return result
    }

    /// Explicit repository removal. View disappearance must not call this:
    /// away/back navigation is expected to preserve cards and attachments.
    @discardableResult
    func forget(sessionID: String, generationID: String) -> [SubmittedComposerSnapshot] {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        let removed = scopes.removeValue(forKey: key)?.snapshots.values.map { $0 } ?? []
        for snapshot in removed {
            if let echoID = snapshot.pendingEchoID {
                cancelPendingEchoExpiry(sessionID: sessionID, echoID: echoID)
            }
        }
        _ = policy.forget(key)
        _ = lifecycle.forget(sessionID: sessionID, generationID: generationID)
        for snapshot in removed {
            scheduleAttachmentCleanup(
                snapshot.attachments,
                route: snapshot.imageRoute,
                event: .explicitDismiss
            )
        }
        if !removed.isEmpty { publish() }
        return removed
    }

    /// Explicit repository removal forgets every provider generation for the
    /// session. Away/back navigation must not call this overload: its scopes
    /// are durable until the repository has authoritatively removed the row.
    @discardableResult
    func forget(sessionID: String) -> [SubmittedComposerSnapshot] {
        let keys = scopes.keys.filter { $0.sessionID == sessionID }
        var removed: [SubmittedComposerSnapshot] = []
        for key in keys {
            if let snapshots = scopes.removeValue(forKey: key)?.snapshots.values {
                let values = Array(snapshots)
                removed.append(contentsOf: values)
                for snapshot in values {
                    if let echoID = snapshot.pendingEchoID {
                        cancelPendingEchoExpiry(sessionID: sessionID, echoID: echoID)
                    }
                }
            }
        }
        _ = policy.forget(sessionID: sessionID)
        _ = lifecycle.forget(sessionID: sessionID)
        identityBySession.removeValue(forKey: sessionID)
        for snapshot in removed {
            scheduleAttachmentCleanup(
                snapshot.attachments,
                route: snapshot.imageRoute,
                event: .explicitDismiss
            )
        }
        if !removed.isEmpty || !keys.isEmpty { publish() }
        return removed
    }

    /// Starts a new authoritative generation. Old snapshots are migrated to a
    /// failed, restorable card under the new generation and also returned to
    /// the caller so obsolete optimistic echoes can be retired. They are never
    /// silently retried with the new provider identity or released as files.
    @discardableResult
    func replaceGeneration(
        sessionID: String,
        from oldGenerationID: String,
        to newGenerationID: String
    ) -> [SubmittedComposerSnapshot] {
        let oldKey = ScopeKey(sessionID: sessionID, generationID: oldGenerationID)
        let oldSnapshots = scopes.removeValue(forKey: oldKey)?.snapshots.values.map { $0 } ?? []
        _ = lifecycle.replaceGeneration(
            sessionID: sessionID,
            from: oldGenerationID,
            to: newGenerationID
        )
        for snapshot in oldSnapshots {
            if let echoID = snapshot.pendingEchoID {
                cancelPendingEchoExpiry(sessionID: sessionID, echoID: echoID)
            }
        }
        _ = policy.replaceGeneration(
            sessionID: sessionID,
            from: oldGenerationID,
            to: newGenerationID
        )
        scopes.removeValue(forKey: oldKey)
        let newKey = ScopeKey(sessionID: sessionID, generationID: newGenerationID)
        if policy.containsScope(ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: newGenerationID
        )) {
            var newScope = Scope()
            var migratedDeliveryIDs = Set<String>()
            // A provider restart invalidates old request/echo identities. Keep
            // the exact submitted content as a visible failed recovery card in
            // the new generation so it remains restorable, but never expose a
            // stale Retry or optimistic echo as if it belonged to the new
            // provider process.
            for oldSnapshot in oldSnapshots {
                guard let migratedCore = ComposerRecoveryScopeLedger
                    .restorableSnapshotForGeneration(
                        oldSnapshot.sendRecoverySnapshot(),
                        generationID: newGenerationID
                    ) else { continue }
                let migrated = SubmittedComposerSnapshot(
                    deliveryID: migratedCore.deliveryID,
                    sessionId: migratedCore.sessionID,
                    generationID: migratedCore.generationID,
                    text: migratedCore.text,
                    attachments: oldSnapshot.attachments,
                    pendingEchoID: migratedCore.pendingEchoID,
                    submittedRevision: migratedCore.submittedRevision,
                    clearedRevision: migratedCore.clearedRevision,
                    imageRoute: oldSnapshot.imageRoute
                )
                let admission = policy.admitFailure(
                    migratedCore,
                    reason: "The provider session restarted. Restore this message before sending it again."
                )
                if admission == .retained {
                    newScope.snapshots[migrated.deliveryID] = migrated
                    migratedDeliveryIDs.insert(oldSnapshot.deliveryID)
                }
            }
            scopes[newKey] = newScope
            // If Core could not admit a migrated record, no mounted view can
            // release its AppKit file on our behalf. Release only that exact
            // non-migrated snapshot through the shared retention service.
            for snapshot in oldSnapshots where
                !migratedDeliveryIDs.contains(snapshot.deliveryID) {
                scheduleAttachmentCleanup(
                    snapshot.attachments,
                    route: snapshot.imageRoute,
                    event: .explicitDismiss
                )
            }
        } else {
            for snapshot in oldSnapshots {
                scheduleAttachmentCleanup(
                    snapshot.attachments,
                    route: snapshot.imageRoute,
                    event: .explicitDismiss
                )
            }
        }
        publish()
        return oldSnapshots
    }

    private func admitScope(sessionID: String, generationID: String) -> ScopeKey? {
        let key = ScopeKey(sessionID: sessionID, generationID: generationID)
        if scopes[key] != nil { return key }
        let coreKey = ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: generationID
        )
        guard policy.ensureScope(coreKey) else { return nil }
        scopes[key] = Scope()
        return key
    }

    private func publish() {
        // DraftStore can change while no scope mutation occurs (for example
        // a mounted composer removes a chip). Recheck retained references at
        // every store publication so deferred cleanup is eventually exact.
        drainAttachmentCleanup()
        revision &+= 1
    }

    /// Empty scopes carry no recoverable content and can be reclaimed. This
    /// keeps the bounded scope table usable after dismiss/canonical cleanup
    /// while never evicting a scope that still owns a snapshot or pending ID.
    private func pruneEmptyScopes() {
        let emptyKeys = scopes.compactMap { key, scope -> ScopeKey? in
            guard scope.snapshots.isEmpty,
                  scope.pendingDeliveryIDs.isEmpty,
                  scope.activeDeliveryID == nil else { return nil }
            return key
        }
        guard !emptyKeys.isEmpty else { return }
        for key in emptyKeys {
            scopes.removeValue(forKey: key)
            _ = policy.forget(key)
        }
    }
}
