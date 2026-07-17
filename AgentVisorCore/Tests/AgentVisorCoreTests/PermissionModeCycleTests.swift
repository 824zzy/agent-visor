import XCTest
@testable import AgentVisorCore

final class PermissionModeCycleTests: XCTestCase {
    // The cycle deliberately skips `auto`: it's enterprise-gated
    // (TRANSCRIPT_CLASSIFIER feature flag) and we have no hook signal
    // that tells agent-visor whether the current backend supports it.
    // Predicting `auto` after `plan` mispredicts on Bedrock/Vertex/
    // standard Anthropic API, where the TUI actually lands on `default`.
    // For enterprise users who do have auto, the AX probe will see the
    // `⏵⏵ auto` chevron within ~1.5s and reconcile the chip.

    func test_defaultGoesToAcceptEdits() {
        XCTAssertEqual(PermissionModeCycle.next(after: "default"), "acceptEdits")
    }

    func test_acceptEditsGoesToPlan() {
        XCTAssertEqual(PermissionModeCycle.next(after: "acceptEdits"), "plan")
    }

    func test_planGoesToDefault_notAuto() {
        XCTAssertEqual(PermissionModeCycle.next(after: "plan"), "default")
    }

    func test_autoGoesToDefault_inCaseAXProbeLandsOnAutoFirst() {
        // Enterprise users who have auto-mode-available will land on
        // `auto` via the probe. From there, Shift+Tab cycles back to
        // default (matches Claude Code's TUI cycle).
        XCTAssertEqual(PermissionModeCycle.next(after: "auto"), "default")
    }

    func test_bypassPermissionsGoesToDefault() {
        XCTAssertEqual(PermissionModeCycle.next(after: "bypassPermissions"), "default")
    }

    func test_unknownModeReturnsNil() {
        XCTAssertNil(PermissionModeCycle.next(after: "garbage"))
        XCTAssertNil(PermissionModeCycle.next(after: ""))
    }

    // MARK: - Backend-scenario walk-throughs
    //
    // These tests pin the optimistic-chip prediction path used by
    // agent-visor's PermissionModeCycler. The motivating bug: on
    // Bedrock the TUI cycles `plan → default` (no `auto`), but the
    // cycler's optimistic prediction was `plan → auto`, so the chip
    // flashed "auto" before the AX probe reconciled it back to default.
    // The Bedrock walk-through below would have caught it.

    /// Bedrock / Vertex / standard Anthropic API: `auto` is enterprise-
    /// gated (TRANSCRIPT_CLASSIFIER feature flag) and is absent from
    /// the TUI cycle. A user pressing Shift+Tab repeatedly walks
    /// `default → acceptEdits → plan → default → ...`. Predicting
    /// `auto` anywhere in this chain produces a visible chip flicker.
    func test_bedrockBackend_fullCycleNeverPredictsAuto() {
        var current = "default"
        var visited: [String] = [current]
        // Walk a full lap. With 3 reachable modes on Bedrock we only
        // need 3 hops to detect a stray `auto` prediction; we walk 5
        // to confirm the cycle stays stable across multiple laps.
        for _ in 0..<5 {
            guard let next = PermissionModeCycle.next(after: current) else {
                XCTFail("cycle dead-ended at \(current)")
                return
            }
            visited.append(next)
            current = next
        }
        XCTAssertFalse(
            visited.contains("auto"),
            "Bedrock cycle should never visit `auto`, got: \(visited)"
        )
        // Also pin the exact lap so a re-ordering (e.g. plan→accept)
        // can't sneak through under the no-auto check.
        XCTAssertEqual(
            visited,
            ["default", "acceptEdits", "plan", "default", "acceptEdits", "plan"]
        )
    }

    /// Enterprise backends with TRANSCRIPT_CLASSIFIER: the AX probe
    /// detects the `⏵⏵ auto` chevron in Ghostty's TUI and applies
    /// `auto` to the chip. From there, the user's next Shift+Tab
    /// must roll back to `default` — the cycler must not get stuck
    /// in an `auto → ?` loop.
    func test_enterpriseBackend_autoCyclesBackToDefault() {
        XCTAssertEqual(PermissionModeCycle.next(after: "auto"), "default")
    }

    /// Symmetric to the Bedrock test: walking forward from any starting
    /// mode must reach `default` within at most 4 hops (the longest
    /// path in either backend topology). Guards against a future change
    /// that introduces an unreachable mode or a 2-cycle.
    func test_anyStartingMode_reachesDefaultWithinFourHops() {
        for start in ["default", "acceptEdits", "plan", "auto", "bypassPermissions"] {
            var current = start
            var hops = 0
            while current != "default" && hops < 4 {
                guard let next = PermissionModeCycle.next(after: current) else {
                    XCTFail("dead-end at \(current) starting from \(start)")
                    break
                }
                current = next
                hops += 1
            }
            XCTAssertEqual(current, "default", "starting from \(start) failed to reach default within 4 hops")
        }
    }
}
