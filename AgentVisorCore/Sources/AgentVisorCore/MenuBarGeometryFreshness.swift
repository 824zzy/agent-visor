import CoreGraphics
import Foundation

/// Guards menu-bar click routing against screen geometry that was captured
/// from a display arrangement which no longer exists.
///
/// Why this exists: the pills strip captures its display's frame once, at
/// controller build time, and every click decision (pill slot ranges, the
/// menu-bar interaction band) is expressed in that frame. When the user
/// undocks, sleeps an external display, or re-arranges displays, the same
/// display reports a different frame — and any geometry captured before the
/// change now describes a rectangle that overlaps *other* displays.
///
/// A concrete regression this prevents: geometry captured while the built-in
/// MacBook display was the main display, `(0, 0, 2056, 1329)`, kept claiming
/// clicks after the display moved to `(406, -1329, 2056, 1329)`. In global
/// coordinates the stale rectangle then covered empty space in the middle of
/// an external monitor, so clicks there were treated as menu-bar clicks.
///
/// The rule is deliberately strict: a captured frame is fresh only when the
/// display it came from still reports exactly that frame. Anything else —
/// display detached, moved, or resized — is stale, and the caller must not
/// route the click.
public enum MenuBarGeometryFreshness {
    /// - Parameters:
    ///   - captured: The screen frame the click geometry was built from.
    ///   - live: The frame the same display reports now, or `nil` when that
    ///     display is no longer attached.
    public static func isFresh(captured: CGRect, live: CGRect?) -> Bool {
        guard let live else { return false }
        return live == captured
    }

    /// Inverse of `isFresh`, for the early-return shape click handlers use.
    public static func isStale(captured: CGRect, live: CGRect?) -> Bool {
        !isFresh(captured: captured, live: live)
    }
}
