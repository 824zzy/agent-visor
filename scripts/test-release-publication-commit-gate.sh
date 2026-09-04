#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(dirname "$SCRIPT_DIR")"
FIXTURE="$SCRIPT_DIR/fixtures/create-release-bundle-fixture.sh"
REAL_GIT="$(command -v git)"
TEMP_ROOT="$(mktemp -d -t av-release-commit-gate.XXXXXX)"
REMOTE_ROOT="$(mktemp -d -t av-release-commit-gate-remote.XXXXXX)"
OUTPUT_PATH="$TEMP_ROOT/publisher.log"
MISMATCH_OUTPUT_PATH="$TEMP_ROOT/mismatch.log"
MATCHED_OUTPUT_PATH="$TEMP_ROOT/matched.log"
EXPECTED_MIN_MACOS=""

cleanup() {
    rm -rf "$TEMP_ROOT"
    rm -rf "$REMOTE_ROOT"
}
trap cleanup EXIT

unset AV_RELEASE_DRY_RUN AV_DRY_RUN AV_ALLOW_DIRTY_RELEASE \
    AV_ALLOW_UNPUSHED_RELEASE AV_ALLOW_UNSIGNED_APPCAST \
    AV_ALLOW_EXISTING_APPCAST_ITEM AV_ALLOW_EXISTING_RELEASE_UPLOAD

# Keep the isolated fixture on the historical migration bridge so the actual
# candidate validator runs without weakening the publication policy.
source "$SOURCE_ROOT/config/release-version.env"
EXPECTED_MIN_MACOS="$AGENT_VISOR_MIN_MACOS"

mkdir -p \
    "$TEMP_ROOT/scripts/lib" \
    "$TEMP_ROOT/scripts/fixtures" \
    "$TEMP_ROOT/config" \
    "$TEMP_ROOT/docs" \
    "$TEMP_ROOT/Casks" \
    "$TEMP_ROOT/build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    "$TEMP_ROOT/.sparkle-keys"

for relative_path in \
    scripts/create-release.sh \
    scripts/create-release-archive.sh \
    scripts/lib/release-publication.sh \
    scripts/lib/release-version.sh \
    scripts/lib/release-signing.sh \
    scripts/validate-release-candidate.sh \
    scripts/test-release-archive.sh \
    scripts/test-release-bundle.sh \
    scripts/test-homebrew-resign.sh \
    scripts/fixtures/create-release-bundle-fixture.sh; do
    destination="$TEMP_ROOT/$relative_path"
    mkdir -p "$(dirname "$destination")"
    cp "$SOURCE_ROOT/$relative_path" "$destination"
done
cp "$SOURCE_ROOT/config/release-signing.env" "$TEMP_ROOT/config/release-signing.env"
cp "$SOURCE_ROOT/LICENSE.md" "$TEMP_ROOT/LICENSE.md"

cat > "$TEMP_ROOT/package.json" <<'EOF'
{"name":"agent-visor","version":"2.4.7","private":true}
EOF
cat > "$TEMP_ROOT/config/release-version.env" <<EOF
AGENT_VISOR_BUILD="48"
AGENT_VISOR_MIN_MACOS="$EXPECTED_MIN_MACOS"
AGENT_VISOR_BUNDLE_IDENTIFIER="com.824zzy.AgentVisor"
AGENT_VISOR_EXECUTABLE="Agent Visor"
AGENT_VISOR_PRODUCT_NAME="Agent Visor"
AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION="Agent Visor uses automation to focus and control the terminal session you choose."
AGENT_VISOR_THIRD_PARTY_LICENSES_DIR="ThirdPartyLicenses"
EOF
cat > "$TEMP_ROOT/Casks/agent-visor.rb" <<'EOF'
cask "agent-visor" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/824zzy/agent-visor/releases/download/v#{version}/AgentVisor-v#{version}.zip"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Agent Visor.app"]
    system_command "/usr/bin/codesign",
                   args: ["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements,flags", "#{appdir}/Agent Visor.app"]
  end
end
EOF
cat > "$TEMP_ROOT/docs/appcast.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agent Visor Updates</title>
    <link>https://824zzy.github.io/agent-visor/appcast.xml</link>
    <description>Agent Visor updates</description>
    <language>en</language>
  </channel>
</rss>
EOF

cat > "$TEMP_ROOT/build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" <<'EOF'
#!/bin/bash
printf '%s\n' 'sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="'
EOF
chmod 700 "$TEMP_ROOT/build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
printf '%s\n' 'synthetic private key for the publication commit-gate test' \
    > "$TEMP_ROOT/.sparkle-keys/eddsa_private_key"
chmod 600 "$TEMP_ROOT/.sparkle-keys/eddsa_private_key"

cat > "$TEMP_ROOT/.gitignore" <<'EOF'
build/
releases/
.sparkle-keys/
*.log
EOF
"$REAL_GIT" -C "$TEMP_ROOT" init -q
"$REAL_GIT" -C "$TEMP_ROOT" branch -M main
"$REAL_GIT" -C "$TEMP_ROOT" config user.email release-test@example.com
"$REAL_GIT" -C "$TEMP_ROOT" config user.name "Release Commit Gate Test"
"$REAL_GIT" -C "$TEMP_ROOT" add .
"$REAL_GIT" -C "$TEMP_ROOT" commit -qm "test fixture"

# Make the tap a local bare repository. The publisher still takes its normal
# clone and dry-run push path, but the test cannot mutate a public remote.
TAP_SEED="$REMOTE_ROOT/tap-seed"
TAP_REPO="$REMOTE_ROOT/tap.git"
mkdir -p "$TAP_SEED/Casks"
cp "$TEMP_ROOT/Casks/agent-visor.rb" "$TAP_SEED/Casks/agent-visor.rb"
"$REAL_GIT" -C "$TAP_SEED" init -q
"$REAL_GIT" -C "$TAP_SEED" branch -M main
"$REAL_GIT" -C "$TAP_SEED" config user.email tap-test@example.com
"$REAL_GIT" -C "$TAP_SEED" config user.name "Tap Commit Gate Test"
"$REAL_GIT" -C "$TAP_SEED" add Casks/agent-visor.rb
"$REAL_GIT" -C "$TAP_SEED" commit -qm "initial tap fixture"
"$REAL_GIT" clone -q --bare "$TAP_SEED" "$TAP_REPO"
TAP_HEAD_BEFORE="$($REAL_GIT --git-dir="$TAP_REPO" rev-parse refs/heads/main)"

# Rewrite only the tap clone source and GitHub CLI calls. All other git calls
# delegate to the host git binary, so worktree and commit checks remain real.
mkdir -p "$REMOTE_ROOT/bin"
cat > "$REMOTE_ROOT/bin/git" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "clone" && "${2:-}" == "git@github.com:824zzy/homebrew-agent-visor.git" ]]; then
    exec "$AV_TEST_REAL_GIT" clone "$AV_TEST_TAP_REPO" "$3" --quiet
fi
exec "$AV_TEST_REAL_GIT" "$@"
EOF
chmod 700 "$REMOTE_ROOT/bin/git"
cat > "$REMOTE_ROOT/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$AV_TEST_GH_LOG"
case "${1:-} ${2:-}" in
    "api user")
        printf '%s\n' '824zzy'
        exit 0
        ;;
    "release view")
        exit 1
        ;;
    "release create")
        # Reaching this command proves the committed metadata gate passed.
        exit 99
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 700 "$REMOTE_ROOT/bin/gh"
export AV_TEST_REAL_GIT="$REAL_GIT"
export AV_TEST_TAP_REPO="$TAP_REPO"
export AV_TEST_GH_LOG="$TEMP_ROOT/gh.log"
export PATH="$REMOTE_ROOT/bin:$PATH"

"$TEMP_ROOT/scripts/fixtures/create-release-bundle-fixture.sh" \
    "$TEMP_ROOT/build/export/Agent Visor.app" >/dev/null

run_publisher() {
    local output_path="$1"
    shift
    AV_ALLOW_ADHOC_BRIDGE_RELEASE=1 \
    AV_ALLOW_UNPUSHED_RELEASE=1 \
    AV_RELEASE_GIT_SSH_COMMAND=local-test \
    AV_RELEASE_DERIVED="$TEMP_ROOT/build/derived" \
    AV_RELEASE_NOTES_HTML='<ul><li>publication commit-gate test</li></ul>' \
    AV_RELEASE_NOTES_MARKDOWN='publication commit-gate test' \
    AV_RELEASE_GH_TOKEN='local-test-token' \
    "$TEMP_ROOT/scripts/create-release.sh" > "$output_path" 2>&1 "$@"
}

# The first real run starts from a clean commit whose cask and appcast are
# stale. Generation therefore leaves a diff, and publication must stop before
# either the tap preflight or any GitHub call.
if run_publisher "$MISMATCH_OUTPUT_PATH"; then
    echo "ERROR: real publication succeeded with uncommitted generated metadata" >&2
    cat "$MISMATCH_OUTPUT_PATH" >&2
    exit 1
fi
if ! grep -Fq 'generated cask metadata does not match the committed cask' "$MISMATCH_OUTPUT_PATH" \
    || ! grep -Fq 'generated appcast metadata does not match the committed appcast' "$MISMATCH_OUTPUT_PATH"; then
    echo "ERROR: real publication did not report both committed metadata mismatches" >&2
    cat "$MISMATCH_OUTPUT_PATH" >&2
    exit 1
fi
if grep -Fq '=== Step 7: Preflighting Homebrew Tap Push ===' "$MISMATCH_OUTPUT_PATH" \
    || [[ -s "$TEMP_ROOT/gh.log" ]]; then
    echo "ERROR: real publication reached a remote mutation boundary before the metadata gate" >&2
    cat "$MISMATCH_OUTPUT_PATH" >&2
    exit 1
fi
if [[ -n "$("$REAL_GIT" -C "$TEMP_ROOT" status --short)" ]]; then
    echo "ERROR: metadata mismatch changed the isolated tracked tree" >&2
    "$REAL_GIT" -C "$TEMP_ROOT" status --short >&2
    exit 1
fi

# A dry run writes the exact generated cask/appcast for review. Committing
# those files creates the required pre-matched shape for a real publication.
if ! AV_RELEASE_DRY_RUN=1 \
    AV_ALLOW_ADHOC_BRIDGE_RELEASE=1 \
    AV_RELEASE_DERIVED="$TEMP_ROOT/build/derived" \
    AV_RELEASE_NOTES_HTML='<ul><li>publication commit-gate test</li></ul>' \
    AV_RELEASE_NOTES_MARKDOWN='publication commit-gate test' \
    "$TEMP_ROOT/scripts/create-release.sh" > "$OUTPUT_PATH" 2>&1; then
    echo "ERROR: dry run could not generate pre-matched metadata" >&2
    cat "$OUTPUT_PATH" >&2
    exit 1
fi
"$REAL_GIT" -C "$TEMP_ROOT" add Casks/agent-visor.rb docs/appcast.xml
"$REAL_GIT" -C "$TEMP_ROOT" commit -qm "match generated release metadata"

TAP_HEAD_BEFORE_MATCHED="$($REAL_GIT --git-dir="$TAP_REPO" rev-parse refs/heads/main)"
if [[ "$TAP_HEAD_BEFORE_MATCHED" != "$TAP_HEAD_BEFORE" ]]; then
    echo "ERROR: mismatch test unexpectedly mutated the local tap" >&2
    exit 1
fi

# The second real run uses committed/pre-matched metadata. It is stopped by a
# fake GitHub create after the gate and tap dry-run, proving the gate passed
# without publishing to either public boundary.
if run_publisher "$MATCHED_OUTPUT_PATH"; then
    echo "ERROR: fake GitHub publisher unexpectedly completed" >&2
    cat "$MATCHED_OUTPUT_PATH" >&2
    exit 1
fi
if grep -Eq 'generated (cask|appcast) metadata does not match' "$MATCHED_OUTPUT_PATH"; then
    echo "ERROR: pre-matched committed metadata failed the real publication gate" >&2
    cat "$MATCHED_OUTPUT_PATH" >&2
    exit 1
fi
if ! grep -Fq 'release create' "$TEMP_ROOT/gh.log"; then
    echo "ERROR: matched publication did not reach the fake GitHub boundary after the gate" >&2
    cat "$MATCHED_OUTPUT_PATH" >&2
    exit 1
fi
TAP_HEAD_AFTER_MATCHED="$($REAL_GIT --git-dir="$TAP_REPO" rev-parse refs/heads/main)"
if [[ "$TAP_HEAD_AFTER_MATCHED" != "$TAP_HEAD_BEFORE" ]]; then
    echo "ERROR: publication commit-gate test mutated the local tap" >&2
    exit 1
fi
if [[ -n "$("$REAL_GIT" -C "$TEMP_ROOT" status --short)" ]]; then
    echo "ERROR: matched publication changed the isolated tracked tree" >&2
    "$REAL_GIT" -C "$TEMP_ROOT" status --short >&2
    exit 1
fi

echo "Release publication commit gate PASS: stale generated metadata stops real publication before tap/GitHub, while committed dry-run metadata passes the gate."
