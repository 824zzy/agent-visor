import Foundation

/// Reserved widths for the sidebar row's trailing slot. The slot
/// hosts ONE of: the relative timestamp ("23h"), the hover-only
/// terminal-jump icon, the ⌘N hotkey badge, or inline approval
/// buttons. Earlier code let SwiftUI pick the natural width per
/// variant; the result was visible reflow on hover (the row's
/// `.animation(value: isHovered)` then animated the width swap),
/// which the user perceived as jitter.
///
/// Rule: every non-approval variant reserves the SAME slot width.
/// Approval is special-cased — it's wider but appears only during a
/// permission prompt, where the row is supposed to grow.
public enum SidebarTrailingSlotMetrics {
    public enum Variant: Equatable, Sendable {
        case timestamp
        case terminalIcon
        case commandBadge
        case approvalButtons
    }

    /// Width reserved for the swappable variants. Sized to fit the
    /// widest realistic timestamp text ("365d") plus padding, AND the
    /// terminal icon button (~22pt) AND the ⌘N badge (~24pt). Pinning
    /// at 28pt comfortably accommodates all three with no clipping
    /// and no surplus that would visually push the subtitle short.
    public static let stableWidth: CGFloat = 28
    /// Approval bar is two action chips side by side. Matches the
    /// existing InlineApprovalButtons natural width.
    public static let approvalWidth: CGFloat = 80

    public static func reservedWidth(for variant: Variant) -> CGFloat {
        switch variant {
        case .timestamp, .terminalIcon, .commandBadge:
            return stableWidth
        case .approvalButtons:
            return approvalWidth
        }
    }
}
