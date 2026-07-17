import Foundation

/// Decides whether `parseFullConversation` should skip the on-disk
/// cache and rebuild from the last `compact_boundary` in the JSONL.
///
/// Background. The chat-panel parser keeps a per-session cache of the
/// last parsed `IncrementalParseState`. On open, the normal path is:
/// load the cache (covers most of the JSONL), parse only the bytes
/// appended since. That's milliseconds when the cache is fresh.
///
/// Two cases break that assumption:
///   1. **Cold / missing cache** on a huge JSONL — first open of a
///      large session, or the cache was deleted. The full re-parse
///      walks every byte; we observed 15 s on a 458 MB transcript.
///   2. **Warm cache far behind tip** — app was closed for hours, the
///      JSONL grew by 100+ MB, the small "delta to parse" suddenly
///      isn't small.
///
/// Both have a much faster alternative: scan the file once for the
/// LAST `compact_boundary` line, parse only the post-boundary tail
/// (typically <2 MB), save a fresh small cache. The chat panel only
/// renders the post-compact view anyway, so this is lossless.
///
/// `shouldBypassCache` is the *gate* for that alternative — it answers
/// "is bypass worth attempting here?". The caller still needs
/// `CompactBoundaryLocator.findLastBoundaryOffset` to find a boundary;
/// if no boundary exists the caller falls back to the regular path.
public enum ConversationCacheBypassPolicy {

    /// Returns true when the bypass-to-last-compact-boundary path should
    /// be tried, false to take the regular cache-load + delta-parse path.
    ///
    /// The decision uses a single threshold (`thresholdBytes`) symmetric
    /// across two predicates:
    ///   - cold path: `jsonlSize > threshold` AND no cache.
    ///   - warm path: `jsonlSize > threshold` AND
    ///     `(jsonlSize - cachedJsonlBytes) > threshold`.
    ///
    /// Bytes-strictly-greater (`>`, not `>=`) matches the existing
    /// guard in `pruneToLastCompactBoundary`, so a session that never
    /// triggered a prune also never triggers a bypass.
    ///
    /// - Parameters:
    ///   - jsonlSize: size of the JSONL file on disk, in bytes.
    ///   - cachedJsonlBytes: `jsonlBytesParsed` from the on-disk cache,
    ///     or nil if the cache is missing/unreadable. A cache value
    ///     greater than `jsonlSize` (file rotated/truncated) is treated
    ///     as "no useful cache" — the regular path's existing fallback
    ///     handles that re-parse.
    ///   - thresholdBytes: the size above which work is considered "big
    ///     enough" to bypass. Reuse of `pruneToLastCompactBoundary`'s
    ///     threshold keeps a single tuning knob.
    public static func shouldBypassCache(
        jsonlSize: UInt64,
        cachedJsonlBytes: UInt64?,
        thresholdBytes: UInt64
    ) -> Bool {
        guard jsonlSize > thresholdBytes else { return false }

        guard let cached = cachedJsonlBytes else {
            // Cold path: no usable cache, JSONL is large → bypass.
            return true
        }

        // Defensive: if cache claims more bytes than the file holds,
        // the cache is inconsistent. Decline to bypass; the caller's
        // regular path includes a `fileSize >= cached.jsonlBytesParsed`
        // guard that already handles this by falling back to a full
        // re-parse from offset 0.
        guard cached <= jsonlSize else { return false }

        let delta = jsonlSize - cached
        return delta > thresholdBytes
    }
}
