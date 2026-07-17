import XCTest
@testable import AgentVisorCore

final class PermissionSuggestionBuilderTests: XCTestCase {
    // MARK: - PermissionUpdate wire format (setMode + addRules)

    func test_setModeUpdate_encodesWithMode_omitsRulesAndBehavior() throws {
        // The plan-mode "Yes, auto-accept edits" path emits a setMode
        // update. Wire shape must match upstream's permissionUpdateSchema
        // (PermissionUpdateSchema.ts:62-66): {type, mode, destination},
        // with no `rules` or `behavior` keys.
        let update = PermissionUpdate(
            type: "setMode",
            destination: "session",
            mode: "acceptEdits"
        )
        let json = try JSONEncoder().encode(update)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertEqual(dict["type"] as? String, "setMode")
        XCTAssertEqual(dict["mode"] as? String, "acceptEdits")
        XCTAssertEqual(dict["destination"] as? String, "session")
        XCTAssertNil(dict["rules"], "setMode must not carry a rules field")
        XCTAssertNil(dict["behavior"], "setMode must not carry a behavior field")
    }

    func test_addRulesUpdate_encodesWithRulesAndBehavior_omitsMode() throws {
        // The "always allow" path (Bash/Read/Edit/Write rules) emits an
        // addRules update. Wire shape must NOT include a `mode` key.
        let update = PermissionUpdate(
            type: "addRules",
            rules: [PermissionRuleValue(toolName: "Bash", ruleContent: "ls:*")],
            behavior: "allow",
            destination: "localSettings"
        )
        let json = try JSONEncoder().encode(update)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertEqual(dict["type"] as? String, "addRules")
        XCTAssertEqual(dict["behavior"] as? String, "allow")
        XCTAssertEqual(dict["destination"] as? String, "localSettings")
        XCTAssertNotNil(dict["rules"])
        XCTAssertNil(dict["mode"], "addRules must not carry a mode field")
    }

    func test_setModeAcceptEdits_isUniversallyValidUpstreamMode() {
        // The mode value we send for plan-mode auto-accept MUST be in
        // claude-code's EXTERNAL_PERMISSION_MODES (types/permissions.ts:16-22).
        // 'acceptEdits' is the only mode that's valid across every backend
        // (Anthropic API / Bedrock / Vertex / enterprise) without
        // requiring --dangerously-skip-permissions or feature flags.
        // This test pins our choice — changing the literal here means
        // changing user behavior across all backends.
        let update = PermissionUpdate(
            type: "setMode",
            destination: "session",
            mode: "acceptEdits"
        )
        XCTAssertEqual(update.mode, "acceptEdits")
        // Defensive: ensure we don't accidentally regress to 'auto' or
        // 'bypassPermissions' which require runtime gates we can't read.
        XCTAssertNotEqual(update.mode, "auto")
        XCTAssertNotEqual(update.mode, "bypassPermissions")
    }

    // MARK: - Interpreter binds to script path

    func test_bashScript_yieldsScriptPathPrefix() {
        // `bash /path/to/foo.sh ...` -> rule `Bash(bash /path/to/foo.sh:*)`
        // (binds to THIS script, not all bash invocations).
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "bash /Users/me/proj/scripts/dev-build.sh"],
            cwd: "/Users/me/proj"
        )
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "bash /Users/me/proj/scripts/dev-build.sh:*")
        XCTAssertEqual(s?.label, "Yes, and don't ask again for `bash /Users/me/proj/scripts/dev-build.sh` commands in /Users/me/proj")
    }

    func test_pythonScript_yieldsScriptPathPrefix() {
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "python3 /tmp/script.py --flag"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "python3 /tmp/script.py:*")
    }

    func test_bashWithoutScript_fallsBackToVerbOnly() {
        // `bash` alone (e.g. spawning interactive shell) — no second
        // positional, so the prefix is just `bash`. Acceptable since
        // there's no script to bind to.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "bash"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "bash:*")
    }

    func test_bashScriptViaPipe_stillBindsToScript() {
        // First-segment is `bash /path/foo.sh 2>&1`. After redirection
        // strip + chain split, the classifier-or-prefix path runs on
        // `bash /path/foo.sh`.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "bash /Users/me/scripts/dev.sh 2>&1 | tail -3"],
            cwd: "/Users/me"
        )
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "bash /Users/me/scripts/dev.sh:*")
    }

    // MARK: - Multi-segment scripts (architecture regression)

    func test_screenshot_multilineScript_emitsAggregatedSuggestion() {
        // The exact regression that drove the architecture rewrite.
        // Multi-line script with the awk script in single-quotes —
        // upstream's TUI emits "similar commands" for this and persists
        // a rule per safe segment.
        let script = """
        echo "=== file ==="
        ls -la ~/AkashicRecords/dev/telemetry/
        echo ""
        echo "=== word count ==="
        wc -w ~/AkashicRecords/dev/telemetry/llm-telemetry.md | awk '{print $1, "words"}'
        echo ""
        echo "=== _index.md dev section now ==="
        sed -n '/^## Dev/,/^## /p' ~/AkashicRecords/_index.md | head -25
        """
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": script],
            cwd: "/Users/me/Codes"
        )
        // Capped at 5 rules (upstream parity).
        XCTAssertEqual(s?.updates.count, 5)
        // Multi-segment scripts skip the read classifier — every safe
        // segment goes through the Bash prefix path. Result is the
        // all-Bash "don't ask again ... commands in cwd" wording,
        // matching upstream when paths are already in allowed dirs.
        XCTAssertNotNil(s?.label)
        XCTAssertTrue(
            s!.label.hasPrefix("Yes, and don't ask again for "),
            "Expected all-Bash label prefix, got: \(s!.label)"
        )
        XCTAssertTrue(
            s!.label.hasSuffix(" commands in /Users/me/Codes"),
            "Expected cwd suffix, got: \(s!.label)"
        )
        // All emitted rules are Bash, never Read (read-classifier is
        // gated to single-segment scripts).
        XCTAssertTrue(s!.updates.allSatisfy { $0.rules?.first?.toolName == "Bash" })
    }

    func test_longJoinedDisplayNames_yieldsSimilar() {
        // Many bash exact-match rules whose joined string > 50 chars.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "longcommandname1; longcommandname2; longcommandname3"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 3)
        XCTAssertTrue(
            s!.label.contains("similar"),
            "Expected 'similar' for joined > 50 chars, got: \(s!.label)"
        )
    }

    func test_twoSimpleCommands_emitsCommaList() {
        // Short joined names → comma + "and" wording.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "make; pwd"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 2)
        // ls is now a read command, so we use `make; pwd` (both are
        // bare-prefix Bash rules).
        XCTAssertEqual(s?.label, "Yes, and don't ask again for make and pwd commands in /p")
    }

    func test_threeBashCommands_oxfordComma() {
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "make; npm; pwd"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 3)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for make, npm, and pwd commands in /p")
    }

    func test_compoundOver5Rules_capsAt5() {
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "make; npm; pwd; date; uptime; free; uname"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 5)
    }

    func test_segmentsContainingDollarParen_areSkipped() {
        // `echo $(whoami)` is unsafe and dropped. `make` and `pwd`
        // survive. Two updates, label aggregates them.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "make; echo $(whoami); pwd"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 2)
        XCTAssertEqual(s?.label, "Yes, and don't ask again for make and pwd commands in /p")
    }

    func test_singleQuotedDollar_isNotUnsafe() {
        // The key regression: `$1` inside `'...'` is literal text and
        // must NOT trip the unsafe gate. Single segment, single rule.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "make '{print $1}'"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 1)
        XCTAssertEqual(s?.updates.first?.rules?.first?.toolName, "Bash")
    }

    func test_emptyAfterAllUnsafe_returnsNil() {
        // Every segment is unsafe → no suggestion.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "echo $(date) && echo `pwd`"],
            cwd: "/p"
        )
        XCTAssertNil(s)
    }

    // MARK: - MCP and universal fallback

    func test_mcpTool_yieldsEntireToolRuleWithPrettyLabel() {
        // mcp__server__tool -> rule with no ruleContent (matches whole
        // tool), destination localSettings. Label parses the wire name
        // into a "server: tool" form for readability.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "mcp__github-dotcom__pull_request_review_write",
            input: ["method": "create", "owner": "Adobe-Experience-Platform", "repo": "ao", "pullNumber": 2953],
            cwd: "/Users/me/Codes"
        )
        XCTAssertEqual(s?.label, "Yes, and don't ask again for `github-dotcom: pull_request_review_write` commands in /Users/me/Codes")
        let update = s?.updates.first
        XCTAssertEqual(update?.type, "addRules")
        XCTAssertEqual(update?.behavior, "allow")
        XCTAssertEqual(update?.destination, "localSettings")
        XCTAssertEqual(update?.rules?.first?.toolName, "mcp__github-dotcom__pull_request_review_write")
        XCTAssertNil(update?.rules?.first?.ruleContent)
    }

    func test_unknownTool_yieldsToolPrefixRule() {
        // Tools that aren't Bash/Read/Edit/Write/MCP fall back to the
        // entire-tool rule with the verbatim tool name as the label.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "WebFetch",
            input: ["url": "https://example.com"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.label, "Yes, and don't ask again for `WebFetch` commands in /p")
        XCTAssertEqual(s?.updates.first?.rules?.first?.toolName, "WebFetch")
        XCTAssertNil(s?.updates.first?.rules?.first?.ruleContent)
        XCTAssertEqual(s?.updates.first?.destination, "localSettings")
    }

    func test_taskTool_yieldsToolPrefixRule() {
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Task",
            input: ["description": "do thing"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.label, "Yes, and don't ask again for `Task` commands in /p")
        XCTAssertEqual(s?.updates.first?.rules?.first?.toolName, "Task")
    }

    // MARK: - Bash read-classifier integration

    func test_bashCatWithinCwd_yieldsReadRuleSessionDestination() {
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "cat src/foo.txt"],
            cwd: "/Users/me/proj"
        )
        XCTAssertEqual(s?.label, "Yes, allow reading from src/ from this project")
        let update = s?.updates.first
        XCTAssertEqual(update?.type, "addRules")
        XCTAssertEqual(update?.behavior, "allow")
        XCTAssertEqual(update?.destination, "session")
        XCTAssertEqual(update?.rules?.first?.toolName, "Read")
        XCTAssertEqual(update?.rules?.first?.ruleContent, "//Users/me/proj/src/**")
    }

    func test_bashSedInPlace_fallsBackToPrefix() {
        // sed -i is a write — classifier returns nil — prefix path runs.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "sed -i s/x/y/ file.txt"],
            cwd: "/p"
        )
        // `s/x/y/` would normally trigger containsDangerousMeta if it had
        // `$`/`>` etc., but plain slashes survive — so we should fall to
        // the Bash-prefix path with destination=localSettings.
        XCTAssertEqual(s?.updates.first?.rules?.first?.toolName, "Bash")
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "sed:*")
        XCTAssertEqual(s?.updates.first?.destination, "localSettings")
    }

    func test_bashNpmTest_unchanged_prefixWithLocalSettings() {
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "npm test"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.first?.rules?.first?.toolName, "Bash")
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "npm test:*")
        XCTAssertEqual(s?.updates.first?.destination, "localSettings")
    }

    func test_bashFindWithStderrRedirectionAndPipe_emitsTwoBashRules() {
        // Multi-segment skips the read classifier. Both segments end
        // up as Bash rules (find prefix + head exact-match).
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "find /Users/me/proj -name \"package.json\" 2>/dev/null | head -1"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 2)
        XCTAssertTrue(s!.updates.allSatisfy { $0.rules?.first?.toolName == "Bash" })
        XCTAssertEqual(s?.updates[0].rules?.first?.ruleContent, "find:*")
    }

    func test_bashWithStdoutRedirectionToFile_stillBailsAsDangerous() {
        // `cat > foo.txt` redirects stdout to a writable target — we
        // still want to bail. Stripping is for read-only redirections.
        // For now any `>` makes us conservative; v2 can refine.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "cat > foo.txt"],
            cwd: "/p"
        )
        XCTAssertNil(s)
    }

    func test_bashChainedCatThenLs_skipsClassifierForMultiSegment() {
        // Multi-segment scripts route through the Bash prefix path
        // even when individual segments would classify as reads —
        // mirrors upstream's "all-Bash branch when paths are in
        // allowed dirs" behavior.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "cat foo.txt && ls"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 2)
        XCTAssertTrue(s!.updates.allSatisfy { $0.rules?.first?.toolName == "Bash" })
        XCTAssertEqual(s?.label, "Yes, and don't ask again for cat and ls commands in /p")
    }

    // MARK: - Existing builder behavior

    func test_readWithFilePath_yieldsParentDirRule() {
        let suggestion = PermissionSuggestionBuilder.suggestion(
            tool: "Read",
            input: ["file_path": "/Users/me/proj/src/app.swift"],
            cwd: "/Users/me/proj"
        )
        XCTAssertEqual(suggestion?.label, "Yes, and always allow access to src/ from this project")
        let update = suggestion?.updates.first
        XCTAssertEqual(update?.type, "addRules")
        XCTAssertEqual(update?.behavior, "allow")
        XCTAssertEqual(update?.destination, "localSettings")
        XCTAssertEqual(update?.rules?.first?.toolName, "Read")
        // Mirrors claude-code's createReadRuleSuggestion: absolute path gets
        // a doubled leading slash + /** suffix.
        XCTAssertEqual(update?.rules?.first?.ruleContent, "//Users/me/proj/src/**")
    }

    func test_editWithFilePath_yieldsEditRule() {
        let suggestion = PermissionSuggestionBuilder.suggestion(
            tool: "Edit",
            input: ["file_path": "/abs/dir/foo.txt"],
            cwd: "/abs/dir"
        )
        XCTAssertEqual(suggestion?.updates.first?.rules?.first?.toolName, "Edit")
        XCTAssertEqual(suggestion?.updates.first?.rules?.first?.ruleContent, "//abs/dir/**")
        XCTAssertEqual(suggestion?.label, "Yes, and always allow access to dir/ from this project")
    }

    func test_writeWithFilePathOutsideCwd_stillUsesAbsoluteParent() {
        let suggestion = PermissionSuggestionBuilder.suggestion(
            tool: "Write",
            input: ["file_path": "/tmp/foo.log"],
            cwd: "/home/me"
        )
        XCTAssertEqual(suggestion?.updates.first?.rules?.first?.toolName, "Write")
        XCTAssertEqual(suggestion?.updates.first?.rules?.first?.ruleContent, "//tmp/**")
        XCTAssertEqual(suggestion?.label, "Yes, and always allow access to tmp/ from this project")
    }

    func test_readWithRootLevelFile_returnsNil() {
        // /foo.txt has parent "/" which is too broad. Mirror upstream's
        // root-dir guard.
        XCTAssertNil(PermissionSuggestionBuilder.suggestion(
            tool: "Read",
            input: ["file_path": "/foo.txt"],
            cwd: "/"
        ))
    }

    func test_readMissingFilePath_returnsNil() {
        XCTAssertNil(PermissionSuggestionBuilder.suggestion(
            tool: "Read",
            input: [:],
            cwd: "/p"
        ))
    }

    func test_bashWithSubstitutionOrRedirection_returnsNilOrSkipsSegment() {
        // Substitution and redirection-to-file remain bail-out cases.
        // Newlines and chains are now SAFE (segmenter splits them) —
        // tested elsewhere.
        let bailOut = [
            "echo $(whoami)",
            "echo `id`",
            "ls > /tmp/out",
            "cat < input",
        ]
        for cmd in bailOut {
            let s = PermissionSuggestionBuilder.suggestion(
                tool: "Bash",
                input: ["command": cmd],
                cwd: "/p"
            )
            XCTAssertNil(s, "Expected nil for unsafe command: \(cmd)")
        }
    }

    func test_bashChainedCommand_emitsRulePerSegment() {
        // Architecture rewrite: chains now emit a rule PER segment and
        // aggregate via the comma-list label. The first segment widens
        // to `git:*` because `--version` doesn't match upstream's verb
        // regex (^[a-z][a-z0-9]*...) — leading `-` disqualifies it.
        // Mirrors what claude-code's TUI emits via getFirstWordPrefix.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "git --version && git log --oneline -1"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 2)
        XCTAssertEqual(s?.updates[0].rules?.first?.ruleContent, "git:*")
        XCTAssertEqual(s?.updates[1].rules?.first?.ruleContent, "git log:*")
        XCTAssertEqual(s?.label, "Yes, and don't ask again for git and git log commands in /p")
    }

    func test_bashSemicolonChain_usesFirstSegment() {
        // First segment is `make`, a non-read command — exercises the
        // prefix path through the chain split.
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "make; echo done"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "make:*")
    }

    func test_bashPipeChain_usesFirstSegment() {
        // Use a non-read first segment so this test exercises the
        // prefix-fallback branch specifically. (When the first segment
        // is a read command, the classifier-first branch covers it.)
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "make build | tee log"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "make:*")
    }

    func test_bashUnsafeSegmentSkipped_remainingEmitted() {
        // Architecture rewrite: unsafe segments (real $(), real
        // backticks) are silently dropped and the loop continues —
        // we still emit rules for the safe segments. Here `echo $()`
        // is unsafe → skipped; `ls` survives and yields a Bash rule
        // (multi-segment skips the read classifier).
        let s = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "echo $(whoami) && ls"],
            cwd: "/p"
        )
        XCTAssertEqual(s?.updates.count, 1)
        XCTAssertEqual(s?.updates.first?.rules?.first?.toolName, "Bash")
        XCTAssertEqual(s?.updates.first?.rules?.first?.ruleContent, "ls:*")
    }

    func test_bashGitSubcommand_yieldsTwoTokenPrefix() {
        let suggestion = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "git diff HEAD~1"],
            cwd: "/Users/me/proj"
        )
        XCTAssertEqual(suggestion?.updates.first?.rules?.first?.ruleContent, "git diff:*")
        XCTAssertEqual(suggestion?.label, "Yes, and don't ask again for `git diff` commands in /Users/me/proj")
    }

    func test_bashGitWithFlagsOnly_yieldsTwoTokenPrefix() {
        let suggestion = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "git status"],
            cwd: "/p"
        )
        XCTAssertEqual(suggestion?.updates.first?.rules?.first?.ruleContent, "git status:*")
    }

    func test_bashSimpleCommand_yieldsPrefixSuggestion() {
        // `make build` is not a known read command — exercises the
        // prefix-fallback branch with a tool name + verb that's still
        // alphanumeric-friendly.
        let suggestion = PermissionSuggestionBuilder.suggestion(
            tool: "Bash",
            input: ["command": "make build"],
            cwd: "/Users/me/proj"
        )

        XCTAssertNotNil(suggestion)
        XCTAssertEqual(suggestion?.label, "Yes, and don't ask again for `make` commands in /Users/me/proj")
        XCTAssertEqual(suggestion?.updates.count, 1)
        let update = suggestion?.updates.first
        XCTAssertEqual(update?.type, "addRules")
        XCTAssertEqual(update?.behavior, "allow")
        XCTAssertEqual(update?.destination, "localSettings")
        XCTAssertEqual(update?.rules?.count, 1)
        XCTAssertEqual(update?.rules?.first?.toolName, "Bash")
        XCTAssertEqual(update?.rules?.first?.ruleContent, "make:*")
    }
}
