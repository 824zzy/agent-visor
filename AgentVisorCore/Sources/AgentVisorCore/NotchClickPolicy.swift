import Foundation

/// Status of the notch overlay panel. Mirrors the AppKit-side enum
/// (`NotchStatus`) but lives here so the policy stays AppKit-free.
public enum NotchStatusInput: Sendable, Equatable {
    case closed
    case popping
    case opened
}

/// What a global mouseDown should cause, given the current notch
/// state. Persistence is uniform across content types — outside
/// clicks never close the panel, regardless of whether the user is
/// in chat, sessions list, or the menu. Dismissal is always explicit
/// (notch-shape click, Esc, or hotkey).
public enum NotchClickAction: Sendable, Equatable {
    /// Open the panel (closed → opened).
    case open
    /// Close the panel (opened → closed).
    case close
    /// Don't react. Either the click is inside our panel and SwiftUI
    /// will handle it, or it's outside and we want the panel to
    /// persist while the user operates in another app.
    case ignore
}

/// Pure decision function for global mouseDown handling. Tested in
/// isolation; the AppKit side (NotchViewModel.handleMouseDown) is a
/// thin shim that translates geometry queries into these flags and
/// performs the resulting action.
///
/// Truth table:
///
/// | status         | inNotch | inVisiblePanel | action |
/// |----------------|---------|----------------|--------|
/// | closed         |  true   |  any           | open   |
/// | popping        |  true   |  any           | open   |
/// | closed/popping |  false  |  any           | ignore |
/// | opened         |  true   |  any           | close  |
/// | opened         |  false  |  any           | ignore |
public enum NotchClickPolicy {
    public static func action(
        status: NotchStatusInput,
        inNotch: Bool,
        inVisiblePanel: Bool
    ) -> NotchClickAction {
        switch status {
        case .closed, .popping:
            return inNotch ? .open : .ignore
        case .opened:
            // Notch-shape click is the universal dismissal gesture —
            // spatially symmetric with the open gesture (same target
            // opens and closes). Outside clicks are always ignored so
            // the panel persists while the user operates elsewhere.
            return inNotch ? .close : .ignore
        }
    }
}
