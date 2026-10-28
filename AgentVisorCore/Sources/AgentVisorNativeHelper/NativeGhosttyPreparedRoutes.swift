import AgentVisorCore
import Foundation

/// A helper-owned TTY→surface capability. Only a unique metadata marker can
/// mint it; titles and directories alone never select a surface. The helper's
/// serialized connection shares preparation with terminal send/cancel work.
public final class NativeGhosttyPreparedRoutes {
    public typealias Application = NativeGhosttyTerminalController.ApplicationIdentity
    public typealias Surface = NativeGhosttyAppleEvents.Surface
    public struct Environment {
        public var application: () -> Application?
        public var verify: (NativeHelperTerminalTarget) -> Bool
        public var surfaces: () -> [Surface]?
        public var surface: (String) -> Surface?
        public var focus: (String, String?, String?) -> Bool
        public var viewMode: (Application, String) -> NativeHelperGhosttyViewMode?
        public var writeMetadata: (String, NativeHelperTerminalTarget) -> Bool
        public var pause: () -> Void
        public init(application: @escaping () -> Application?, verify: @escaping (NativeHelperTerminalTarget) -> Bool,
                    surfaces: @escaping () -> [Surface]?, surface: @escaping (String) -> Surface?,
                    focus: @escaping (String, String?, String?) -> Bool,
                    viewMode: @escaping (Application, String) -> NativeHelperGhosttyViewMode?,
                    writeMetadata: @escaping (String, NativeHelperTerminalTarget) -> Bool, pause: @escaping () -> Void) {
            self.application = application; self.verify = verify; self.surfaces = surfaces; self.surface = surface
            self.focus = focus; self.viewMode = viewMode; self.writeMetadata = writeMetadata; self.pause = pause
        }
    }
    private struct Entry {
        let target: NativeHelperTerminalTarget
        let application: Application
        let surface: Surface
        let conversationOnly: Bool
    }
    private let environment: Environment
    private var entries: [String: Entry] = [:]

    public init(environment: Environment? = nil) { self.environment = environment ?? Self.liveEnvironment() }

    /// No input, focus, activation, persistent title, or selection changes.
    /// The OSC7 locator is metadata output and is restored before returning.
    public func prepare(_ target: NativeHelperTerminalTarget, conversationOnly: Bool = true) -> Bool {
        guard target.application == .ghostty, target.pid != nil, environment.verify(target),
              let application = environment.application() else { return false }
        if let entry = entries[target.tty], entry.target == target, entry.conversationOnly == conversationOnly,
           entry.application == application,
           let current = environment.surface(entry.surface.id), current.cwd == target.cwd,
           sameTitle(current.title, entry.surface.title),
           !conversationOnly || environment.viewMode(application, current.title) == .conversation {
            return true
        }
        entries.removeValue(forKey: target.tty)
        let marker = GhosttyMarkerLocator.makeMarker()
        guard environment.writeMetadata(marker, target) else { return false }
        var restored = false
        defer {
            if !restored && environment.verify(target) { _ = environment.writeMetadata(target.cwd, target) }
        }
        var match: Surface?
        for _ in 0..<12 {
            guard environment.verify(target), environment.application() == application,
                  let views = environment.surfaces() else { return false }
            let matches = views.filter { $0.cwd == marker }
            guard matches.count <= 1 else { return false }
            if let view = matches.first { match = view; break }
            environment.pause()
        }
        guard let match, !conversationOnly || environment.viewMode(application, match.title) == .conversation,
              environment.verify(target), environment.application() == application,
              environment.writeMetadata(target.cwd, target) else { return false }
        let restoredTitle = match.title.replacingOccurrences(of: marker, with: target.cwd)
        for _ in 0..<12 {
            guard environment.verify(target), environment.application() == application,
                  let surface = environment.surface(match.id) else { return false }
            // OSC7 also changes directory-based titles. Wait for both fields
            // to restore before caching a title that the next focus rechecks.
            if surface.cwd == target.cwd, sameTitle(surface.title, restoredTitle) {
                restored = true
                if entries.count >= 128 { entries.removeAll() }
                entries[target.tty] = Entry(target: target, application: application, surface: surface, conversationOnly: conversationOnly)
                return true
            }
            environment.pause()
        }
        return false
    }

    /// nil means no prepared route; false is a rejected exact route. A failed
    /// conversation guard never falls through to generic terminal activation.
    public func focus(_ target: NativeHelperTerminalTarget, conversationOnly: Bool = true) -> Bool? {
        guard let entry = entries[target.tty] else { return nil }
        guard entry.target == target, entry.conversationOnly == conversationOnly,
              environment.verify(target), environment.application() == entry.application,
              let surface = environment.surface(entry.surface.id), surface.cwd == target.cwd,
              sameTitle(surface.title, entry.surface.title),
              !conversationOnly || environment.viewMode(entry.application, surface.title) == .conversation else {
            entries.removeValue(forKey: target.tty)
            return false
        }
        guard environment.focus(surface.id, surface.title, target.cwd), environment.verify(target),
              environment.application() == entry.application,
              !conversationOnly || environment.viewMode(entry.application, surface.title) == .conversation else {
            entries.removeValue(forKey: target.tty)
            return false
        }
        return true
    }

    /// Missing capabilities get one exact preparation. Rejection never falls
    /// through to a terminal route with weaker conversation guards.
    public func focusOrPrepare(_ target: NativeHelperTerminalTarget, conversationOnly: Bool) -> Bool {
        if let result = focus(target, conversationOnly: conversationOnly) { return result }
        return prepare(target, conversationOnly: conversationOnly)
            && focus(target, conversationOnly: conversationOnly) == true
    }

    private func sameTitle(_ lhs: String, _ rhs: String) -> Bool {
        let normalize: (String) -> String = {
            $0.range(of: #"^[✳◐◑] "#, options: .regularExpression) == nil ? $0 : String($0.dropFirst(2))
        }
        return normalize(lhs) == normalize(rhs)
    }

    private static func liveEnvironment() -> Environment {
        func sdk() -> NativeGhosttyAppleEvents? {
            guard let app = NativeGhosttyTerminalController.liveApplication() else { return nil }
            return NativeGhosttyAppleEvents(pid: app.pid)
        }
        return Environment(application: NativeGhosttyTerminalController.liveApplication,
            verify: NativeTerminalController.liveTargetMatches,
            surfaces: { sdk()?.surfaces() }, surface: { sdk()?.surface(id: $0) },
            focus: { sdk()?.focus(terminalID: $0, expectedTitle: $1, expectedCWD: $2) ?? false },
            viewMode: { app, title in
                NativeGhosttyViewModeReader.readFooter(application: app, title: title)
                    .flatMap { NativeGhosttyViewModeReader.mode(footer: $0, title: title) }
            }, writeMetadata: { cwd, target in
                guard NativeTerminalController.liveTargetMatches(target),
                      let handle = FileHandle(forWritingAtPath: target.tty.hasPrefix("/dev/") ? target.tty : "/dev/\(target.tty)") else { return false }
                defer { try? handle.close() }
                do { try handle.write(contentsOf: Data(GhosttyMarkerLocator.osc7Sequence(cwd: cwd).utf8)); return true }
                catch { return false }
            }, pause: { Thread.sleep(forTimeInterval: 0.005) })
    }
}
