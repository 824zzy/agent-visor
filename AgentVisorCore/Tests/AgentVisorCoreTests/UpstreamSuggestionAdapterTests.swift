import XCTest
@testable import AgentVisorCore

/// Adapts upstream claude-code's `permission_suggestions` array into the
/// `PermissionSuggestion` shape the chat bar uses. Trusting upstream's
/// verdict is the load-bearing design choice: when upstream returns
/// an empty array (e.g. `find -exec`) we deliberately show no
/// option 2 — the user sees only Yes/No, matching upstream's TUI.
final class UpstreamSuggestionAdapterTests: XCTestCase {

    private let cwd = "/Users/me/proj"

    // MARK: - Empty / nil signals

    func test_emptyArray_returnsNil_soOptionTwoIsHidden() {
        XCTAssertNil(UpstreamSuggestionAdapter.adapt(updates: [], cwd: cwd))
    }

    // MARK: - Single Bash prefix rule

    func test_singleBashPrefixRule_buildsDontAskAgainLabel() {
        let updates = [
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: "git diff:*")],
                behavior: "allow",
                destination: "localSettings"
            )
        ]
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for `git diff` commands in /Users/me/proj")
        XCTAssertEqual(s?.updates, updates)
    }

    func test_singleBashLiteralWithVerbSecondToken_widensToTwoWordPrefix() {
        // When the 2nd token is a verb (npm install …), TUI widens to
        // the two-word `npm install:*` rule rather than bare `npm:*` —
        // mirrors getSimpleCommandPrefix's first attempt.
        let cmd = "npm install some-package --save-dev"
        let updates = [
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: cmd)],
                behavior: "allow",
                destination: "localSettings"
            )
        ]
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for `npm install` commands in /Users/me/proj")
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "npm install:*")
    }

    func test_singleBashLiteralWithUnfitHead_fallsBackToVerbatim() {
        // Some commands have no widenable prefix — e.g. an absolute-path
        // script `/Users/me/run.sh` doesn't pass the verb regex (leading
        // `/`). Upstream's TUI falls back to the literal in this case
        // (BashPermissionRequest.tsx:231), and we should too rather
        // than emit a meaningless `:*` rule.
        let cmd = "/Users/me/run.sh"
        let updates = [
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: cmd)],
                behavior: "allow",
                destination: "localSettings"
            )
        ]
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for `\(cmd)` commands in /Users/me/proj")
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, cmd)
    }

    func test_singleBashLiteralWithBlockingFlag_widensToFirstWordPrefix() {
        // Reproduces the on-machine regression. Upstream's bashPermissions
        // ts:289-294 falls back to suggestionForExactCommand when
        // getSimpleCommandPrefix returns null — which happens whenever the
        // 2nd token is a flag (`-C`, `-la`, `--`). Upstream's TUI then
        // re-widens locally via getFirstWordPrefix in
        // BashPermissionRequest.tsx:229. We must mirror that widen so the
        // label reads `git` and the persisted rule is `Bash(git:*)`, not
        // the dead literal `Bash(git -C /Users/.../proj log --oneline -15)`.
        let cmd = "git -C /Users/me/proj log --oneline -15"
        let updates = [
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: cmd)],
                behavior: "allow",
                destination: "localSettings"
            )
        ]
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for `git` commands in /Users/me/proj")
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "git:*")
    }

    // MARK: - Single Read directory rule (the case from the on-machine probe)

    func test_singleReadDirectoryRule_buildsAllowReadingLabel() {
        let updates = [
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Read", ruleContent: "//private/tmp/**")],
                behavior: "allow",
                destination: "localSettings"
            )
        ]
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, allow reading from tmp/ from this project")
        XCTAssertEqual(s?.updates, updates)
    }

    func test_singleReadRelativeRule_stripsTrailingGlob() {
        let updates = [
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Read", ruleContent: "src/**")],
                behavior: "allow",
                destination: "localSettings"
            )
        ]
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, allow reading from src/ from this project")
    }

    // MARK: - Multiple rules → aggregate label

    func test_twoBashRules_oxfordCommaLabel() {
        let updates = [
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: "git diff:*")],
                behavior: "allow",
                destination: "localSettings"
            ),
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: "ls:*")],
                behavior: "allow",
                destination: "localSettings"
            ),
        ]
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for git diff and ls commands in /Users/me/proj")
        XCTAssertEqual(s?.updates.count, 2)
    }

    func test_threeBashRules_oxfordCommaLabel() {
        let updates = [
            "ls:*", "echo:*", "wc:*"
        ].map {
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: $0)],
                behavior: "allow",
                destination: "localSettings"
            )
        }
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for ls, echo, and wc commands in /Users/me/proj")
    }

    func test_manyBashRules_aboveSimilarThreshold_collapsesToSimilarLabel() {
        // > 50-char joined names triggers upstream's "similar" wording.
        let updates = (0..<6).map { i in
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: "command\(i)long-enough-to-trip-threshold:*")],
                behavior: "allow",
                destination: "localSettings"
            )
        }
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for similar commands in /Users/me/proj")
    }

    func test_mixedReadAndBashRules_usesAlwaysAllowAccessLabel() {
        let updates = [
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Read", ruleContent: "//private/tmp/**")],
                behavior: "allow",
                destination: "session"
            ),
            PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: "ls:*")],
                behavior: "allow",
                destination: "localSettings"
            ),
        ]
        let s = UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd)
        XCTAssertEqual(s?.label, "Yes, and always allow access to tmp/ and ls from this project")
    }

    // MARK: - Robustness

    func test_setModeUpdate_isIgnored_doesNotProduceOptionTwo() {
        // setMode is a different update flavor (used by plan-mode flow).
        // It carries no rule the user can "always allow" — adapter should
        // skip it and return nil if there are no other rule-bearing updates.
        let updates = [
            PermissionUpdate(type: "setMode", destination: "session", mode: "acceptEdits")
        ]
        XCTAssertNil(UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd))
    }

    func test_updateWithoutRules_isIgnored() {
        let updates = [
            PermissionUpdate(type: "addRules", rules: nil, behavior: "allow", destination: "localSettings")
        ]
        XCTAssertNil(UpstreamSuggestionAdapter.adapt(updates: updates, cwd: cwd))
    }
}
