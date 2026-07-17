import Foundation

/// Decides which app's menu bar is rendered on the notch screen — the app
/// whose menu the left pill bar must avoid overlapping.
///
/// **The bug this fixes (twice seen).** On multi-monitor +
/// `screensHaveSeparateSpaces`, each screen shows the menu of the app that
/// is *active on that screen's space*. The previous heuristic picked the
/// topmost layer-0 *window* whose center sits on the notch screen. That
/// mispicks a background app: e.g. Obsidian has a window centered on the
/// notch screen, so it was chosen (menu width 493) while Chrome was actually
/// frontmost with its window on the notch screen and owned the displayed
/// menu (width ~628). The bar reserved against 493 and overlapped Chrome.
///
/// **The rule.** macOS gives menu ownership of a screen to the *frontmost*
/// app when that app has a window on the screen. Only when the frontmost
/// app has no window on the notch screen (it's active on a different
/// display — the legitimate Outlook-on-notch / Ghostty-on-external case)
/// does the menu fall to whichever app is topmost on the notch screen.
///
/// Pure / value-in-value-out so it's unit-testable without AppKit or AX.
public enum NotchMenuOwnerResolver {
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
    ///   - frontmostHasWindowOnNotchScreen: whether the frontmost app has a
    ///     layer-0 window on the notch screen. When true the frontmost app
    ///     owns that screen's menu.
    ///   - topmostOnNotchPid: pid of the topmost layer-0 window centered on
    ///     the notch screen, or nil if none.
    ///   - separateSpaces: `NSScreen.screensHaveSeparateSpaces`.
    ///   - isSingleScreen: true when the notch screen is the only screen.
    /// - Returns: pid of the notch-screen menu owner, or nil.
    public static func owner(
        frontmostPid: pid_t?,
        frontmostHasWindowOnNotchScreen: Bool,
        topmostOnNotchPid: pid_t?,
        separateSpaces: Bool,
        isSingleScreen: Bool
    ) -> pid_t? {
        resolve(
            frontmostPid: frontmostPid,
            frontmostHasWindowOnNotchScreen: frontmostHasWindowOnNotchScreen,
            topmostOnNotchPid: topmostOnNotchPid,
            separateSpaces: separateSpaces,
            isSingleScreen: isSingleScreen
        ).ownerPid
    }

    public static func resolve(
        frontmostPid: pid_t?,
        frontmostHasWindowOnNotchScreen: Bool,
        topmostOnNotchPid: pid_t?,
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
        // Per-screen menu bars: the frontmost app owns the notch screen's
        // menu IF it has a window there. This is the common, correct case
        // (Chrome frontmost with a window on the notch display).
        if let frontmostPid, frontmostHasWindowOnNotchScreen {
            return Resolution(ownerPid: frontmostPid, source: .frontmostOnTargetScreen)
        }
        // Frontmost app is active on a different display — the notch screen
        // shows whichever app is topmost there.
        if let topmostOnNotchPid {
            return Resolution(ownerPid: topmostOnNotchPid, source: .topmostOnTargetScreen)
        }
        if let frontmostPid {
            return Resolution(ownerPid: frontmostPid, source: .fallbackFrontmost)
        }
        return Resolution(ownerPid: nil, source: .unavailable)
    }
}
