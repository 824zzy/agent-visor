import Foundation

/// Lightweight fingerprint for an ordered, append-only history
/// sequence — used by view-models that subscribe to noisy
/// `@Published` dictionaries shared across many sessions to dedupe
/// re-emissions of THIS session's slice.
///
/// Chat items mostly grow append-only with stable ids, but two
/// classes of in-place mutation also have to flip the fingerprint:
///   1. The streaming assistant text item grows on the same id,
///      and when a tool placeholder lands later in the same turn
///      that text item is no longer at `last`.
///   2. ToolCall items mutate their `status` (running → success /
///      error) without changing position.
/// Both fail a (count, lastId)-only check and produce silent UI
/// freezes ("missing response until I ask another question"). To
/// catch them, the fingerprint also encodes a coarse size/status
/// signal aggregated over the LAST few items.
///
/// O(tailWindow) per emission, not O(N) — `tailWindow = 4` is
/// enough to cover the realistic "tool placeholder appended after
/// streaming text" pattern without sliding into per-item hashing.
public struct HistorySliceFingerprint: Equatable, Sendable {
    public let count: Int
    public let lastId: String
    /// Aggregate size/status signal over the tail window. See
    /// `from(items:)` for what this includes.
    public let tailHash: Int

    public init(count: Int, lastId: String, tailHash: Int = 0) {
        self.count = count
        self.lastId = lastId
        self.tailHash = tailHash
    }

    /// Sentinel value any `lastFingerprint`-tracking call site can
    /// initialise to so the first real emission is always treated as
    /// a change. `count = -1` is unreachable from a real `[T]`.
    public static let initial = HistorySliceFingerprint(count: -1, lastId: "", tailHash: 0)

    /// Legacy two-field factory. Retained for the small number of
    /// call sites that don't have richer per-item data on hand.
    /// Prefer `from(items:)` so streaming text growth and toolCall
    /// status flips at non-tail positions still flip the fingerprint.
    public static func from(itemCount: Int, lastId: String?) -> HistorySliceFingerprint {
        HistorySliceFingerprint(count: itemCount, lastId: lastId ?? "", tailHash: 0)
    }

    /// How many tail items the app-side factory should hash over.
    /// Exposed so the call site doesn't have to redeclare the
    /// constant. See `HistorySliceFingerprint+Items.swift` in the
    /// app target for the actual factory; `ChatHistoryItem` lives
    /// outside Core so the heavy logic can't live here.
    public static let tailWindow = 4
}
