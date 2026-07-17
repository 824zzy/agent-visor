import AgentVisorCore
import Combine
import Foundation
import os.log

@MainActor
final class CodexUsageMonitor: ObservableObject {
    static let shared = CodexUsageMonitor()

    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var enabled = AppSettings.codexUsageGlanceEnabled
    @Published private(set) var hasAttemptedRefresh = false

    private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "CodexUsage"
    )
    private static let refreshIntervalNanoseconds: UInt64 = 300_000_000_000
    private static let postTurnDelayNanoseconds: UInt64 = 2_000_000_000

    private var started = false
    private var refreshLoop: Task<Void, Never>?
    private var postTurnRefresh: Task<Void, Never>?

    private init() {}

    var availability: CodexUsageAvailability {
        CodexUsageGlancePolicy.availability(
            preferenceEnabled: enabled,
            snapshot: snapshot,
            isRefreshing: isRefreshing,
            hasAttemptedRefresh: hasAttemptedRefresh,
            hasRefreshError: lastError != nil
        )
    }

    var showsPill: Bool {
        availability.showsPill
    }

    func start() {
        guard !started else { return }
        started = true
        guard enabled else { return }
        beginRefreshLoop()
        Task { await refresh() }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        AppSettings.codexUsageGlanceEnabled = value
        enabled = value
        if value {
            if started { beginRefreshLoop() }
            Task { await refresh() }
        } else {
            refreshLoop?.cancel()
            refreshLoop = nil
            postTurnRefresh?.cancel()
            postTurnRefresh = nil
        }
    }

    func refreshAfterTurnCompletion() {
        guard enabled else { return }
        postTurnRefresh?.cancel()
        postTurnRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.postTurnDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func handleNotification(_ params: AnyCodableEquatableBox) {
        guard enabled,
              let update = CodexUsageSnapshotParser.notification(
                params,
                observedAt: Date()
              ) else { return }
        if let current = snapshot {
            snapshot = current.merging(update)
        } else {
            snapshot = update
        }
        lastError = nil
    }

    func refresh() async {
        guard enabled, !isRefreshing else { return }
        isRefreshing = true
        defer {
            hasAttemptedRefresh = true
            isRefreshing = false
        }
        do {
            let latest = try await CodexAppServerClient.shared.readAccountRateLimits()
            snapshot = latest
            lastError = nil
            let primary = latest.primary.map { String($0.remainingPercent) } ?? "-"
            let secondary = latest.secondary.map { String($0.remainingPercent) } ?? "-"
            Self.logger.notice(
                "rate-limit snapshot remaining primary=\(primary, privacy: .public) secondary=\(secondary, privacy: .public)"
            )
        } catch {
            lastError = error.localizedDescription
            Self.logger.warning("rate-limit refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginRefreshLoop() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshIntervalNanoseconds)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }
}
