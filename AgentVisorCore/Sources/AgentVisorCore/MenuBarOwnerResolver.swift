import Foundation

/// Decides which app's menu bar is rendered on the target screen — the app
/// whose menu the left pill bar must avoid overlapping.
///
/// **The bug this fixes (twice seen).** On multi-monitor +
/// `screensHaveSeparateSpaces`, each screen shows the menu of the app that
/// is *active on that screen's space*. The previous heuristic picked the
/// topmost layer-0 *window* whose center sits on the target screen. That
/// mispicks a background app: e.g. Obsidian has a window centered on the
/// target screen, so it was chosen (menu width 493) while Chrome was actually
/// frontmost with its window on the target screen and owned the displayed
/// menu (width ~628). The bar reserved against 493 and overlapped Chrome.
///
/// **The rule.** macOS gives menu ownership of a screen to the *frontmost*
/// app when that app has a window on the screen. Only when the frontmost
/// app has no window on the target screen (it's active on a different
/// display — the legitimate Outlook-on-target / Ghostty-on-external case)
/// does the menu fall to whichever app is topmost on the target screen.
///
/// Pure / value-in-value-out so it's unit-testable without AppKit or AX.
public enum MenuBarOwnerResolver {
    public struct Resolution: Equatable, Sendable {
        public enum Source: Equatable, Sendable {
            case sharedFrontmost
            case frontmostOnTargetScreen
            case topmostOnTargetScreen
            case fallbackFrontmost
            case unavailable
        }

        public let ownerPid: pid_t?
        public let source: Source

        public var isConfident: Bool {
            switch source {
            case .sharedFrontmost, .frontmostOnTargetScreen, .topmostOnTargetScreen:
                return ownerPid != nil
            case .fallbackFrontmost, .unavailable:
                return false
            }
        }
    }

    /// - Parameters:
    ///   - frontmostPid: globally frontmost app's pid (NSWorkspace).
    ///   - frontmostHasWindowOnTargetScreen: whether the frontmost app has a
    ///     layer-0 window on the target screen. When true the frontmost app
    ///     owns that screen's menu.
    ///   - topmostOnTargetPid: pid of the topmost layer-0 window centered on
    ///     the target screen, or nil if none.
    ///   - separateSpaces: `NSScreen.screensHaveSeparateSpaces`.
    ///   - isSingleScreen: true when the target screen is the only screen.
    /// - Returns: pid of the target-screen menu owner, or nil.
    public static func owner(
        frontmostPid: pid_t?,
        frontmostHasWindowOnTargetScreen: Bool,
        topmostOnTargetPid: pid_t?,
        separateSpaces: Bool,
        isSingleScreen: Bool
    ) -> pid_t? {
        resolve(
            frontmostPid: frontmostPid,
            frontmostHasWindowOnTargetScreen: frontmostHasWindowOnTargetScreen,
            topmostOnTargetPid: topmostOnTargetPid,
            separateSpaces: separateSpaces,
            isSingleScreen: isSingleScreen
        ).ownerPid
    }

    public static func resolve(
        frontmostPid: pid_t?,
        frontmostHasWindowOnTargetScreen: Bool,
        topmostOnTargetPid: pid_t?,
        separateSpaces: Bool,
        isSingleScreen: Bool
    ) -> Resolution {
        // Single shared menu bar (one screen, or spaces not separate): the
        // globally frontmost app always owns it.
        if !separateSpaces || isSingleScreen {
            return Resolution(
                ownerPid: frontmostPid,
                source: frontmostPid == nil ? .unavailable : .sharedFrontmost
            )
        }
        // Per-screen menu bars: the frontmost app owns the target screen's
        // menu IF it has a window there. This is the common, correct case
        // (Chrome frontmost with a window on the target display).
        if let frontmostPid, frontmostHasWindowOnTargetScreen {
            return Resolution(ownerPid: frontmostPid, source: .frontmostOnTargetScreen)
        }
        // Frontmost app is active on a different display — the target screen
        // shows whichever app is topmost there.
        if let topmostOnTargetPid {
            return Resolution(ownerPid: topmostOnTargetPid, source: .topmostOnTargetScreen)
        }
        if let frontmostPid {
            return Resolution(ownerPid: frontmostPid, source: .fallbackFrontmost)
        }
        return Resolution(ownerPid: nil, source: .unavailable)
    }
}
