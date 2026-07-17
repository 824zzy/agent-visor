import Foundation

/// UserDefaults-backed persistence for the experimental window-mode
/// surface. The window frame uses NSWindow's `setFrameAutosaveName`
/// machinery (no logic of our own to keep), so this struct only owns
/// the small bits that AppKit doesn't persist for us — currently the
/// last-selected session id.
public enum MainWindowSettings {
    /// Stable identifier handed to `NSWindow.setFrameAutosaveName`.
    /// Renaming this resets every existing user's window frame on the
    /// next launch, so keep it pinned.
    public static let frameAutosaveName = "AgentVisor.MainWindow"

    private static let lastSessionKey = "AgentVisor.MainWindow.lastSessionId"
    private static let projectOrderKey = "AgentVisor.MainWindow.projectOrder"
    private static let hiddenSessionsKey = "AgentVisor.MainWindow.hiddenSessions"

    public static func lastSessionId(in defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: lastSessionKey)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    public static func setLastSessionId(_ id: String?, in defaults: UserDefaults = .standard) {
        if let id, !id.isEmpty {
            defaults.set(id, forKey: lastSessionKey)
        } else {
            defaults.removeObject(forKey: lastSessionKey)
        }
    }

    /// User's manual sidebar project order (project keys, top-first), set
    /// by dragging project headers. May contain stale keys for projects
    /// that have since closed — `SidebarProjectOrderer.order` filters them
    /// against the live set at render time, so we persist verbatim.
    public static func projectOrder(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: projectOrderKey) ?? []
    }

    public static func setProjectOrder(_ order: [String], in defaults: UserDefaults = .standard) {
        if order.isEmpty {
            defaults.removeObject(forKey: projectOrderKey)
        } else {
            defaults.set(order, forKey: projectOrderKey)
        }
    }

    // MARK: - Hidden sessions

    /// Sessions the user has dismissed from the sidebar + pills. Persisted as
    /// structured entries (not bare ids) so the settings "Hidden sessions" list
    /// can show a real title and agent without reconstructing them from a row
    /// that, by definition, is no longer published. Survives discovery and
    /// relaunch — `SessionStore` filters these ids at the publish boundary and
    /// skips them during bootstrap so a hidden session can't resurface.
    public static func hiddenSessions(in defaults: UserDefaults = .standard) -> [HiddenSessionEntry] {
        (defaults.stringArray(forKey: hiddenSessionsKey) ?? []).compactMap(HiddenSessionEntry.init(encoded:))
    }

    public static func setHiddenSessions(_ entries: [HiddenSessionEntry], in defaults: UserDefaults = .standard) {
        if entries.isEmpty {
            defaults.removeObject(forKey: hiddenSessionsKey)
        } else {
            defaults.set(entries.map(\.encoded), forKey: hiddenSessionsKey)
        }
    }

    /// Just the ids — the hot-path set used to filter published sessions.
    public static func hiddenSessionIds(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(hiddenSessions(in: defaults).map(\.id))
    }

    /// Add (or refresh) a hidden entry. Replaces any existing entry with the
    /// same id so a re-hide updates the stored title/agent.
    public static func hide(id: String, title: String, agentRaw: String, in defaults: UserDefaults = .standard) {
        guard !id.isEmpty else { return }
        var entries = hiddenSessions(in: defaults).filter { $0.id != id }
        entries.append(HiddenSessionEntry(id: id, title: title, agentRaw: agentRaw))
        setHiddenSessions(entries, in: defaults)
    }

    public static func unhide(id: String, in defaults: UserDefaults = .standard) {
        let entries = hiddenSessions(in: defaults).filter { $0.id != id }
        setHiddenSessions(entries, in: defaults)
    }
}

/// One persisted hidden-session record. Encoded as a single tab-delimited
/// string so it rides the same `[String]` UserDefaults representation the rest
/// of `MainWindowSettings` uses. Tabs/newlines in the title are collapsed to
/// spaces on the way in so the delimiter stays unambiguous.
public struct HiddenSessionEntry: Equatable, Sendable {
    public let id: String
    public let title: String
    public let agentRaw: String

    public init(id: String, title: String, agentRaw: String) {
        self.id = id
        self.title = HiddenSessionEntry.sanitize(title)
        self.agentRaw = agentRaw
    }

    /// `id\ttitle\tagentRaw`.
    public var encoded: String {
        "\(id)\t\(title)\t\(agentRaw)"
    }

    public init?(encoded: String) {
        let parts = encoded.components(separatedBy: "\t")
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        self.id = parts[0]
        self.title = parts[1]
        self.agentRaw = parts[2]
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
