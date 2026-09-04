#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SOURCE_ROOT/config/release-version.env"
EXPECTED_MIN_MACOS="$AGENT_VISOR_MIN_MACOS"
FIXTURE="$SCRIPT_DIR/fixtures/create-release-bundle-fixture.sh"
TEMP_ROOT="$(mktemp -d -t av-release-dry-run.XXXXXX)"
OUTPUT_PATH="$TEMP_ROOT/dry-run.log"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

for required_path in \
    "$SCRIPT_DIR/create-release.sh" \
    "$SCRIPT_DIR/create-release-archive.sh" \
    "$SCRIPT_DIR/lib/release-publication.sh" \
    "$SCRIPT_DIR/lib/release-version.sh" \
    "$SCRIPT_DIR/lib/release-signing.sh" \
    "$SCRIPT_DIR/validate-release-candidate.sh" \
    "$SCRIPT_DIR/test-release-archive.sh" \
    "$SCRIPT_DIR/test-release-bundle.sh" \
    "$SCRIPT_DIR/test-homebrew-resign.sh" \
    "$FIXTURE"; do
    if [[ ! -f "$required_path" ]]; then
        echo "ERROR: release dry-run fixture dependency is missing: $required_path" >&2
        exit 1
    fi
done

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

# Use the historical bridge coordinates so the real candidate validators can
# exercise an ad-hoc fixture without weakening the publication policy. The
# behavior under test is dry-run isolation: no dirty or unpushed override is
# set, and local cask/appcast output is still produced.
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

# A deterministic signing-tool stub keeps this test independent of a local
# Sparkle checkout while still proving that create-release emits an Ed25519
# appcast signature instead of using AV_ALLOW_UNSIGNED_APPCAST.
cat > "$TEMP_ROOT/build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" <<'EOF'
#!/bin/bash
printf '%s\n' 'sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="'
EOF
chmod 700 "$TEMP_ROOT/build/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
printf '%s\n' 'synthetic private key for the isolated dry-run test' \
    > "$TEMP_ROOT/.sparkle-keys/eddsa_private_key"
chmod 600 "$TEMP_ROOT/.sparkle-keys/eddsa_private_key"

cat > "$TEMP_ROOT/.gitignore" <<'EOF'
build/
releases/
.sparkle-keys/
*.log
EOF
git -C "$TEMP_ROOT" init -q
git -C "$TEMP_ROOT" branch -M main
git -C "$TEMP_ROOT" config user.email release-test@example.com
git -C "$TEMP_ROOT" config user.name "Release Dry Run Test"
git -C "$TEMP_ROOT" add .
git -C "$TEMP_ROOT" commit -qm "test fixture"

# Keep the input worktree dirty to prove dry-run mode does not require the
# publication-only AV_ALLOW_DIRTY_RELEASE override.
printf '\n<!-- isolated dry-run input -->\n' >> "$TEMP_ROOT/docs/appcast.xml"

unset AV_ALLOW_DIRTY_RELEASE AV_ALLOW_UNPUSHED_RELEASE AV_ALLOW_UNSIGNED_APPCAST \
    AV_ALLOW_EXISTING_APPCAST_ITEM AV_ALLOW_EXISTING_RELEASE_UPLOAD

"$TEMP_ROOT/scripts/fixtures/create-release-bundle-fixture.sh" \
    "$TEMP_ROOT/build/export/Agent Visor.app" >/dev/null

if ! AV_RELEASE_DRY_RUN=1 \
    AV_ALLOW_ADHOC_BRIDGE_RELEASE=1 \
    AV_RELEASE_DERIVED="$TEMP_ROOT/build/derived" \
    AV_RELEASE_NOTES_HTML='<ul><li>isolated dry-run test</li></ul>' \
    AV_RELEASE_NOTES_MARKDOWN='isolated dry-run test' \
    "$TEMP_ROOT/scripts/create-release.sh" > "$OUTPUT_PATH" 2>&1; then
    echo "ERROR: create-release.sh dry run failed" >&2
    cat "$OUTPUT_PATH" >&2
    exit 1
fi

for expected_output in \
    'DRY-RUN: skipping Homebrew tap clone and push preflight.' \
    'DRY-RUN: tap clone and push skipped after local cask validation.' \
    'DRY-RUN: skipping GitHub release.'; do
    if ! grep -Fq "$expected_output" "$OUTPUT_PATH"; then
        echo "ERROR: dry run did not report expected local-only behavior: $expected_output" >&2
        cat "$OUTPUT_PATH" >&2
        exit 1
    fi
done

NOTES_PATH="$TEMP_ROOT/build/github-release-notes-v2.4.7.md"
for expected_note in \
    'an Ed25519 signature field with the expected metadata' \
    'opens the matching GitHub Releases page' \
    'does not cryptographically verify ZIP bytes' \
    'installed automatically.'; do
    if ! grep -Fq "$expected_note" "$NOTES_PATH"; then
        echo "ERROR: generated GitHub notes omitted expected manual update language: $expected_note" >&2
        exit 1
    fi
done
if grep -Fq 'Sparkle will check for updates' "$NOTES_PATH"; then
    echo "ERROR: generated GitHub notes still promise automatic Sparkle installation" >&2
    exit 1
fi

if ! grep -Fq 'version "2.4.7"' "$TEMP_ROOT/Casks/agent-visor.rb" \
    || grep -Fq 'sha256 "0000000000000000000000000000000000000000000000000000000000000000"' \
        "$TEMP_ROOT/Casks/agent-visor.rb"; then
    echo "ERROR: dry run did not generate local cask metadata" >&2
    exit 1
fi
for expected_appcast in \
    '<sparkle:shortVersionString>2.4.7</sparkle:shortVersionString>' \
    "<sparkle:minimumSystemVersion>$EXPECTED_MIN_MACOS</sparkle:minimumSystemVersion>" \
    'sparkle:edSignature='; do
    if ! grep -Fq "$expected_appcast" "$TEMP_ROOT/docs/appcast.xml"; then
        echo "ERROR: dry run did not generate expected local appcast metadata: $expected_appcast" >&2
        exit 1
    fi
done

STATUS="$(git -C "$TEMP_ROOT" status --short)"
if ! grep -Fq ' M Casks/agent-visor.rb' <<<"$STATUS" \
    || ! grep -Fq ' M docs/appcast.xml' <<<"$STATUS"; then
    echo "ERROR: dry run did not leave the generated cask/appcast changes reviewable" >&2
    printf '%s\n' "$STATUS" >&2
    exit 1
fi

echo "Release dry-run behavior PASS: dirty isolated worktree generated local cask/appcast metadata without remote publication or unsafe dirty-tree overrides."
