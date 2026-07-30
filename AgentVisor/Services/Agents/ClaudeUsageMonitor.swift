import AgentVisorCore
import Combine
import Foundation
import os.log

/// Read-only Claude (Anthropic subscription) usage glance.
///
/// Source: `GET https://api.anthropic.com/api/oauth/usage` — the same
/// endpoint Claude Code's `/usage` uses — authenticated with the OAuth
/// access token Pi maintains in `~/.pi/agent/auth.json`.
///
/// SAFETY: this monitor NEVER refreshes or writes the token. Anthropic
/// rotates refresh tokens on use, so an independent refresh here would
/// invalidate Pi's stored credential and break Pi's own auth. When the
/// access token is expired we simply go stale and wait for Pi (which
/// refreshes ~5 min before expiry) to rewrite `auth.json`.
@MainActor
final class ClaudeUsageMonitor: ObservableObject {
    static let shared = ClaudeUsageMonitor()

    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var enabled = AppSettings.claudeUsageGlanceEnabled
    @Published private(set) var hasAttemptedRefresh = false

    private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "ClaudeUsage"
    )
    private static let refreshIntervalNanoseconds: UInt64 = 300_000_000_000
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let oauthBeta = "oauth-2025-04-20"

    private var started = false
    private var refreshLoop: Task<Void, Never>?

    private init() {}

    var availability: ClaudeUsageAvailability {
        ClaudeUsageGlancePolicy.availability(
            preferenceEnabled: enabled,
            snapshot: snapshot,
            isRefreshing: isRefreshing,
            hasAttemptedRefresh: hasAttemptedRefresh,
            hasRefreshError: lastError != nil
        )
    }

    var showsPill: Bool { availability.showsPill }

    func start() {
        guard !started else { return }
        started = true
        guard enabled else { return }
        beginRefreshLoop()
        Task { await refresh() }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        AppSettings.claudeUsageGlanceEnabled = value
        enabled = value
        if value {
            if started { beginRefreshLoop() }
            Task { await refresh() }
        } else {
            refreshLoop?.cancel()
            refreshLoop = nil
        }
    }

    func refresh() async {
        guard enabled, !isRefreshing else { return }
        isRefreshing = true
        defer {
            hasAttemptedRefresh = true
            isRefreshing = false
        }
        do {
            guard let token = Self.readValidAccessToken() else {
                // Missing or expired token: keep any prior snapshot as
                // stale; do not attempt a refresh (rotation would break Pi).
                lastError = "No fresh Anthropic OAuth token available"
                return
            }
            let latest = try await Self.fetchUsage(accessToken: token)
            snapshot = latest
            lastError = nil
            if let spend = latest.spend {
                Self.logger.notice(
                    "claude usage used=\(spend.usedMinor, privacy: .public) limit=\(spend.limitMinor, privacy: .public) pct=\(spend.usedPercent, privacy: .public)"
                )
            }
        } catch {
            lastError = error.localizedDescription
            Self.logger.warning("claude usage refresh failed: \(error.localizedDescription, privacy: .public)")
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

    // MARK: - Token (read-only)

    /// Path to Pi's credential store. Anthropic entry shape:
    /// `{ "anthropic": { "type": "oauth", "access": "…", "expires": <ms> } }`.
    private static var authPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/auth.json")
    }

    /// Return the access token only when it is present and not expired.
    /// A 60s skew avoids using a token about to expire mid-request.
    static func readValidAccessToken(now: Date = Date()) -> String? {
        guard let data = try? Data(contentsOf: authPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let anthropic = root["anthropic"] as? [String: Any],
              let access = anthropic["access"] as? String,
              !access.isEmpty else {
            return nil
        }
        if let expires = (anthropic["expires"] as? NSNumber)?.doubleValue {
            // Pi stores epoch milliseconds.
            let expirySeconds = expires > 1_000_000_000_000 ? expires / 1000 : expires
            if now.timeIntervalSince1970 + 60 >= expirySeconds { return nil }
        }
        return access
    }

    static func fetchUsage(accessToken: String) async throws -> ClaudeUsageSnapshot {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentVisor (usage-glance; read-only)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.transport
        }
        guard http.statusCode == 200 else {
            throw ClaudeUsageError.status(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = ClaudeUsageSnapshotParser.response(
                AnyCodableEquatableBox(object),
                observedAt: Date()
              ) else {
            throw ClaudeUsageError.unrecognizedPayload
        }
        return parsed
    }

    enum ClaudeUsageError: LocalizedError {
        case transport
        case status(Int)
        case unrecognizedPayload

        var errorDescription: String? {
            switch self {
            case .transport: return "Network error contacting Anthropic usage endpoint"
            case .status(let code): return "Anthropic usage endpoint returned HTTP \(code)"
            case .unrecognizedPayload: return "Anthropic usage response was not recognized"
            }
        }
    }
}
