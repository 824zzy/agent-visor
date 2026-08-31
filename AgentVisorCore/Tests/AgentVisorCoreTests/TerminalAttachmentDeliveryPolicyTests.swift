import XCTest
@testable import AgentVisorCore

final class TerminalAttachmentDeliveryPolicyTests: XCTestCase {
    func testNoStepsIsDelivered() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.outcome(for: []),
            .delivered
        )
    }

    func testFirstPreWriteFailureIsRecoverable() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.outcome(for: [
                .failedBeforeWrite(step: "attachment:one", reason: "host unavailable")
            ]),
            .failedBeforeWrite(reason: "host unavailable")
        )
    }

    func testMiddleAttachmentFailureIsUncertainAndStopsAtFailure() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.outcome(for: [
                .succeeded(step: "attachment:one"),
                .failedAfterWrite(step: "attachment:two", reason: "paste interrupted"),
                .succeeded(step: "attachment:three")
            ]),
            .uncertainAfterPartialWrite(
                reason: "paste interrupted",
                completedSteps: ["attachment:one"]
            )
        )
    }

    func testTextFailureAfterImageIsUncertain() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.outcome(for: [
                .succeeded(step: "attachment:one"),
                .failedBeforeWrite(step: "text", reason: "text channel failed")
            ]),
            .uncertainAfterPartialWrite(
                reason: "text channel failed",
                completedSteps: ["attachment:one"]
            )
        )
    }

    func testImageOnlyEnterFailureIsUncertain() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.outcome(for: [
                .succeeded(step: "attachment:one"),
                .failedAfterWrite(step: "enter", reason: "submit failed")
            ]),
            .uncertainAfterPartialWrite(
                reason: "submit failed",
                completedSteps: ["attachment:one"]
            )
        )
    }

    func testTextAcceptedButEnterRejectedIsUncertain() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
                textAccepted: true,
                enterAccepted: false,
                enterFailureReason: "Enter was rejected after text was accepted."
            ),
            .uncertainAfterPartialWrite(
                reason: "Enter was rejected after text was accepted.",
                completedSteps: ["text"]
            )
        )
    }

    func testAcceptedTextWithProvenRejectedEnterIsUncertain() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
                textDispatch: .accepted,
                enterDispatch: .provenRejected(reason: "Enter was rejected.")
            ),
            .uncertainAfterPartialWrite(
                reason: "Enter was rejected.",
                completedSteps: ["text"]
            )
        )
    }

    func testAcceptedTextWithIndeterminateEnterIsUncertain() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
                textDispatch: .accepted,
                enterDispatch: .indeterminate(reason: "Enter timed out after dispatch.")
            ),
            .uncertainAfterPartialWrite(
                reason: "Enter timed out after dispatch.",
                completedSteps: ["text"]
            )
        )
    }

    func testProvenRejectedTextIsFailedBeforeWrite() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
                textDispatch: .provenRejected(reason: "No unique Ghostty target."),
                enterDispatch: .accepted
            ),
            .failedBeforeWrite(reason: "No unique Ghostty target.")
        )
    }

    func testTextRejectedBeforeEnterIsFailedBeforeWrite() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
                textAccepted: false,
                enterAccepted: false,
                textFailureReason: "Text was rejected before write."
            ),
            .failedBeforeWrite(reason: "Text was rejected before write.")
        )
    }

    func testUnknownTextDispatchIsUncertainAndOwnsTheTextBoundary() {
        XCTAssertEqual(
            TerminalAttachmentDeliveryPolicy.textDispatchOutcome(
                .unknown(reason: "AppleScript timed out after dispatch.")
            ),
            .uncertainAfterPartialWrite(
                reason: "AppleScript timed out after dispatch.",
                completedSteps: ["text"]
            )
        )
    }

    func testTextDispatchFallsBackOnlyAfterExplicitPreWriteRejection() {
        var attempts: [String] = []
        let uncertain = TerminalAttachmentDeliveryPolicy.runTextDispatchTiers(
            ["cwd", "osc7"]
        ) { tier in
            attempts.append(tier)
            return .unknown(reason: "\(tier) timed out")
        }

        XCTAssertEqual(attempts, ["cwd"])
        XCTAssertEqual(
            uncertain,
            .unknown(reason: "cwd timed out")
        )

        attempts.removeAll()
        let accepted = TerminalAttachmentDeliveryPolicy.runTextDispatchTiers(
            ["cwd", "osc7"]
        ) { tier in
            attempts.append(tier)
            return tier == "cwd"
                ? .rejectedBeforeWrite(reason: "CWD was not unique.")
                : .accepted
        }
        XCTAssertEqual(attempts, ["cwd", "osc7"])
        XCTAssertEqual(accepted, .accepted)
    }

    func testRunnerDoesNotInvokeStepsAfterFirstFailure() {
        var invoked: [String] = []
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["attachment:one", "attachment:two", "text", "enter"]
        ) { step in
            invoked.append(step)
            if step == "attachment:two" {
                return .failedAfterWrite(step: step, reason: "paste interrupted")
            }
            return .succeeded(step: step)
        }
        XCTAssertEqual(invoked, ["attachment:one", "attachment:two"])
        XCTAssertEqual(
            result,
            .uncertainAfterPartialWrite(
                reason: "paste interrupted",
                completedSteps: ["attachment:one"]
            )
        )
    }

    func testRunnerStopsAfterFirstAttachmentPreWriteFailure() {
        var invoked: [String] = []
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["attachment:one", "text", "enter"]
        ) { step in
            invoked.append(step)
            return .failedBeforeWrite(step: step, reason: "attachment unavailable")
        }
        XCTAssertEqual(invoked, ["attachment:one"])
        XCTAssertEqual(result, .failedBeforeWrite(reason: "attachment unavailable"))
    }

    func testRunnerStopsAfterTextFailureFollowingAttachment() {
        var invoked: [String] = []
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["attachment:one", "text", "enter"]
        ) { step in
            invoked.append(step)
            if step == "text" {
                return .failedBeforeWrite(step: step, reason: "text unavailable")
            }
            return .succeeded(step: step)
        }
        XCTAssertEqual(invoked, ["attachment:one", "text"])
        XCTAssertEqual(
            result,
            .uncertainAfterPartialWrite(
                reason: "text unavailable",
                completedSteps: ["attachment:one"]
            )
        )
    }

    func testRunnerStopsAfterEnterFailureFollowingAttachment() {
        var invoked: [String] = []
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["attachment:one", "enter"]
        ) { step in
            invoked.append(step)
            if step == "enter" {
                return .failedAfterWrite(step: step, reason: "enter unavailable")
            }
            return .succeeded(step: step)
        }
        XCTAssertEqual(invoked, ["attachment:one", "enter"])
        XCTAssertEqual(
            result,
            .uncertainAfterPartialWrite(
                reason: "enter unavailable",
                completedSteps: ["attachment:one"]
            )
        )
    }

    func testRunnerExecutesEveryStepOnFullSuccess() {
        var invoked: [String] = []
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["attachment:one", "attachment:two", "text", "enter"]
        ) { step in
            invoked.append(step)
            return .succeeded(step: step)
        }
        XCTAssertEqual(invoked, ["attachment:one", "attachment:two", "text", "enter"])
        XCTAssertEqual(result, .delivered)
    }

    func testVerifiedRunnerRechecksBeforeEveryIrreversibleStep() {
        var invoked: [String] = []
        var verifications = 0
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["text", "enter"],
            verifyTarget: {
                verifications += 1
                return verifications == 1
            }
        ) { step in
            invoked.append(step)
            return .succeeded(step: step)
        }

        XCTAssertEqual(invoked, ["text"])
        XCTAssertEqual(verifications, 2)
        XCTAssertEqual(
            result,
            .uncertainAfterPartialWrite(
                reason: "Terminal target identity changed before enter.",
                completedSteps: ["text"]
            )
        )
    }

    func testVerifiedRunnerStopsAfterProcessSwapBetweenAttachments() {
        var invoked: [String] = []
        var live = true
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["attachment:one", "attachment:two", "enter"],
            verifyTarget: { live }
        ) { step in
            invoked.append(step)
            live = false
            return .succeeded(step: step)
        }

        XCTAssertEqual(invoked, ["attachment:one"])
        XCTAssertEqual(
            result,
            .uncertainAfterPartialWrite(
                reason: "Terminal target identity changed before attachment:two.",
                completedSteps: ["attachment:one"]
            )
        )
    }

    func testGhosttyMarkerSwapBlocksProviderActionAndRestore() {
        var invoked: [String] = []
        var checks = 0
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["osc7-marker", "ghostty-text", "ghostty-enter", "osc7-restore"],
            verifyTarget: {
                checks += 1
                return checks < 3
            }
        ) { step in
            invoked.append(step)
            return .succeeded(step: step)
        }

        XCTAssertEqual(invoked, ["osc7-marker", "ghostty-text"])
        XCTAssertEqual(
            result,
            .uncertainAfterPartialWrite(
                reason: "Terminal target identity changed before ghostty-enter.",
                completedSteps: ["osc7-marker", "ghostty-text"]
            )
        )
    }

    func testTmuxPasteAndEnterRevalidateTheSameTarget() {
        var invoked: [String] = []
        var targetStillLive = true
        let result = TerminalAttachmentDeliveryPolicy.run(
            steps: ["tmux-load-buffer", "tmux-paste-buffer", "tmux-enter"],
            verifyTarget: { targetStillLive }
        ) { step in
            invoked.append(step)
            if step == "tmux-paste-buffer" { targetStillLive = false }
            return .succeeded(step: step)
        }

        XCTAssertEqual(invoked, ["tmux-load-buffer", "tmux-paste-buffer"])
        XCTAssertEqual(
            result,
            .uncertainAfterPartialWrite(
                reason: "Terminal target identity changed before tmux-enter.",
                completedSteps: ["tmux-load-buffer", "tmux-paste-buffer"]
            )
        )
    }
}
