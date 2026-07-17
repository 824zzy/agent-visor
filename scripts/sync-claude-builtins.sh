#!/usr/bin/env bash
# sync-claude-builtins.sh
#
# Re-extracts the canonical slash-command set from the installed claude
# binary. Prints two files of raw matches that a human cross-references
# against AgentVisorCore/Sources/AgentVisorCore/SlashCommandBuiltins.swift.
#
# claude-code ships as a single bundled Node binary. Slash commands
# survive minification as "/<name>" string literals; help text often
# appears as "/<name> to <verb> ..." in the same binary. This script
# greps both and dumps to /tmp for hand-review. The minified bundle
# leaks lots of false positives (filesystem paths /etc, /bin; AWS API
# routes /agents, /models), so the output needs editorial judgment
# before paste-in.
#
# Run before each agent-visor release; diff against the current array.

set -euo pipefail

BIN_ROOT="$HOME/Library/Application Support/Claude/claude-code"
if [ ! -d "$BIN_ROOT" ]; then
    echo "claude-code install root not found at $BIN_ROOT"
    exit 1
fi

VERSION=$(/bin/ls "$BIN_ROOT" | sort -V | tail -1)
BIN="$BIN_ROOT/$VERSION/claude.app/Contents/MacOS/claude"
if [ ! -x "$BIN" ]; then
    echo "claude binary not executable at $BIN"
    exit 1
fi

LITERALS=/tmp/av-slash-literals.txt
HINTS=/tmp/av-slash-hints.txt

# Pass 1: every "/<name>" literal that looks like a slash command. Caps
# at 30 chars to filter long URL-shaped paths.
strings -n 4 "$BIN" \
    | grep -E '^/[a-z][a-z0-9_-]{1,30}$' \
    | sort -u > "$LITERALS"

# Pass 2: "/<name> to <verb>" help fragments. Gives one-line description
# starters for many of the visible commands.
strings -n 4 "$BIN" \
    | grep -iE '^/[a-z-]+ (to |for |the |a |your )' \
    | sort -u > "$HINTS"

echo "claude-code version: $VERSION"
echo "binary:    $BIN"
echo "literals:  $(wc -l < "$LITERALS" | tr -d ' ') candidates in $LITERALS"
echo "hints:     $(wc -l < "$HINTS" | tr -d ' ') help fragments in $HINTS"
echo ""
echo "Next steps:"
echo "  1. Open $LITERALS and filter out filesystem paths (/bin, /etc,"
echo "     /var, /tmp, /opt, /lib, /sbin, /priv, /private, /usr) and"
echo "     AWS API routes (/agents, /sessions, /streams). Keep the"
echo "     in-session slash commands."
echo "  2. Cross-reference $HINTS for one-line descriptions."
echo "  3. Update AgentVisorCore/Sources/AgentVisorCore/SlashCommandBuiltins.swift"
echo "     and bump the version comment to $VERSION."
