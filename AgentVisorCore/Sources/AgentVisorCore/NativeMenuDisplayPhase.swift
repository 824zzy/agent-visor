import Foundation

/// Phase used by the overflow presentation for grouping and status copy.
///
/// The wire phase remains the provider's turn phase. A history attention tier
/// is a menu-only projection for an old Ready row, so it must not erase the
/// Ready phase that drives the native age fade.
public enum NativeMenuDisplayPhase {
    public static func phase(for pill: NativeHelperPill) -> NativeHelperPillPhase {
        guard let attentionTier = pill.attentionTier else { return pill.phase }
        switch attentionTier {
        case .needsYou: return .needsYou
        case .ready, .acknowledgedReady: return .ready
        case .working: return .working
        case .history: return .history
        }
    }
}
