import XCTest
@testable import AgentVisorCore

/// `shouldBypassCache` decides whether `parseFullConversation` should
/// throw away (or skip loading) the on-disk cache and instead seek to
/// the last `compact_boundary` line in the JSONL, parse forward from
/// there, and write a fresh small cache.
///
/// The bypass is a strict win whenever:
///   - JSONL is large enough that a full re-parse would be slow, AND
///   - the work to do is large — either because there is no cache, or
///     because the cache is far behind the current end of file.
///
/// The bypass relies on `CompactBoundaryLocator` finding a boundary;
/// the policy itself just gates *whether to try*. If a boundary lookup
/// returns nil, the caller falls through to the regular path.
final class ConversationCacheBypassPolicyTests: XCTestCase {

    private let threshold: UInt64 = 5 * 1024 * 1024  // matches pruneThresholdBytes

    // MARK: - Cold cache (no cached state)

    func test_coldCache_smallJsonl_doesNotBypass() {
        // 2 MB JSONL, no cache. Full parse is cheap; bypass would be
        // overhead. Stay on the regular path.
        XCTAssertFalse(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 2 * 1024 * 1024,
                cachedJsonlBytes: nil,
                thresholdBytes: threshold
            )
        )
    }

    func test_coldCache_largeJsonl_bypasses() {
        // 458 MB JSONL, no cache (was just deleted, or first open of
        // this session). This is the exact case we observed taking
        // 15 s in the wild. Must bypass.
        XCTAssertTrue(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 458 * 1024 * 1024,
                cachedJsonlBytes: nil,
                thresholdBytes: threshold
            )
        )
    }

    func test_coldCache_atThreshold_doesNotBypass() {
        // Exactly at threshold: not "large enough" yet — strictly above
        // threshold to bypass, matching the existing `> pruneThresholdBytes`
        // guard in pruneToLastCompactBoundary.
        XCTAssertFalse(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: threshold,
                cachedJsonlBytes: nil,
                thresholdBytes: threshold
            )
        )
    }

    func test_coldCache_oneByteOverThreshold_bypasses() {
        XCTAssertTrue(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: threshold + 1,
                cachedJsonlBytes: nil,
                thresholdBytes: threshold
            )
        )
    }

    // MARK: - Warm cache (cached jsonlBytesParsed exists)

    func test_warmCache_smallDelta_doesNotBypass() {
        // 458 MB JSONL, cache covers all but the last 100 KB.
        // Incremental parse from cache is the right move (we measured
        // 4 ms in the wild). Don't bypass — that would throw away a
        // valid cache for nothing.
        XCTAssertFalse(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 458 * 1024 * 1024,
                cachedJsonlBytes: 458 * 1024 * 1024 - 100_000,
                thresholdBytes: threshold
            )
        )
    }

    func test_warmCache_largeDelta_bypasses() {
        // App was closed for hours; JSONL grew by 100 MB while cache
        // sat at the old offset. Parsing 100 MB of delta would be
        // multi-second; bypass to the new last-boundary instead.
        XCTAssertTrue(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 458 * 1024 * 1024,
                cachedJsonlBytes: 358 * 1024 * 1024,
                thresholdBytes: threshold
            )
        )
    }

    func test_warmCache_zeroDelta_doesNotBypass() {
        // Cache is exactly current. Incremental parse will read 0
        // bytes; bypass would be pure waste.
        XCTAssertFalse(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 458 * 1024 * 1024,
                cachedJsonlBytes: 458 * 1024 * 1024,
                thresholdBytes: threshold
            )
        )
    }

    func test_warmCache_deltaAtThreshold_doesNotBypass() {
        // delta == threshold: not "large enough" — symmetric with the
        // cold-cache jsonlSize gate.
        XCTAssertFalse(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 458 * 1024 * 1024,
                cachedJsonlBytes: 458 * 1024 * 1024 - threshold,
                thresholdBytes: threshold
            )
        )
    }

    func test_warmCache_deltaOneByteOverThreshold_bypasses() {
        XCTAssertTrue(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 458 * 1024 * 1024,
                cachedJsonlBytes: 458 * 1024 * 1024 - threshold - 1,
                thresholdBytes: threshold
            )
        )
    }

    func test_warmCache_smallJsonl_doesNotBypass() {
        // Small JSONL with a small warm cache. Even if delta is the
        // whole file, file is small — bypass is overhead. Symmetric
        // with cold-cache small case.
        XCTAssertFalse(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 2 * 1024 * 1024,
                cachedJsonlBytes: 0,
                thresholdBytes: threshold
            )
        )
    }

    // MARK: - Defensive cases

    func test_warmCache_cachedAheadOfFile_doesNotBypass() {
        // Pathological: cache claims more bytes than the file currently
        // has (file shrank, was rotated, etc.). This is an unsupported
        // state for the bypass — let the caller's existing fallthrough
        // path handle the inconsistency (it triggers a full re-parse).
        XCTAssertFalse(
            ConversationCacheBypassPolicy.shouldBypassCache(
                jsonlSize: 100,
                cachedJsonlBytes: 200,
                thresholdBytes: threshold
            )
        )
    }
}
