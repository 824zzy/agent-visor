#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RELEASE_SCRIPT="$SCRIPT_DIR/create-release.sh"
source "$SCRIPT_DIR/lib/release-version.sh"
release_load_version_config "$PROJECT_DIR"

first_line() {
    local pattern="$1"
    grep -nF "$pattern" "$RELEASE_SCRIPT" | head -1 | cut -d: -f1
}

last_exact_line() {
    local pattern="$1"
    grep -nE "^[[:space:]]*${pattern}[[:space:]]*$" "$RELEASE_SCRIPT" \
        | tail -1 | cut -d: -f1
}

require_source() {
    local pattern="$1"
    local message="$2"
    if ! grep -Fq "$pattern" "$RELEASE_SCRIPT"; then
        echo "ERROR: $message" >&2
        exit 1
    fi
}

require_source 'source "$SCRIPT_DIR/lib/release-publication.sh"' \
    "create-release.sh does not use publication policy"
require_source 'source "$SCRIPT_DIR/lib/release-version.sh"' \
    "create-release.sh does not use the canonical release coordinates"
require_source 'release_load_version_config "$PROJECT_DIR"' \
    "create-release.sh does not load the tracked release configuration"
require_source 'release_assert_coordinates "$PROJECT_DIR" "$APP_VERSION" "$APP_BUILD"' \
    "create-release.sh does not reject artifact/version coordinate drift"
require_source 'validate-release-candidate.sh' \
    "create-release.sh does not validate the signed and notarized candidate"
require_source 'create-release-archive.sh' \
    "create-release.sh does not use the deterministic release archiver"
require_source 'release_distribution_mode_is_publishable' \
    "create-release.sh does not reject non-public ad-hoc candidates"
require_source 'AV_ALLOW_ADHOC_BRIDGE_RELEASE' \
    "create-release.sh does not make the one-time ad-hoc bridge explicit"
require_source 'AGENT_VISOR_ADHOC_BRIDGE_VERSION' \
    "create-release.sh does not pin the ad-hoc bridge version"
require_source 'release_appcast_minimum_update_version_xml' \
    "create-release.sh does not keep pre-bridge clients on the migration path"
require_source '<sparkle:minimumSystemVersion>$AGENT_VISOR_MIN_MACOS</sparkle:minimumSystemVersion>' \
    "create-release.sh hardcodes the appcast minimum macOS version"
require_source 'an Ed25519 signature field with the expected metadata' \
    "generated release notes do not describe Electron update metadata checks"
require_source 'opens the matching GitHub Releases page' \
    "generated release notes do not describe manual release-page updates"
require_source 'It does not cryptographically verify ZIP bytes before opening' \
    "generated release notes overstate the Electron archive verification contract"
require_source 'DRY-RUN: skipping Homebrew tap clone and push preflight.' \
    "dry runs still require a remote Homebrew tap preflight"
require_source 'require_committed_release_metadata' \
    "real publication does not gate remote mutation on committed metadata"
require_source 'APPCAST_METADATA_MATCH=true' \
    "real publication does not record a committed appcast metadata match"

validation_line="$(first_line '"$SCRIPT_DIR/validate-release-candidate.sh"')"
publication_mode_line="$(first_line 'release_distribution_mode_is_publishable')"
zip_line="$(first_line '=== Step 2: Creating Release ZIP ===')"
cask_line="$(first_line '=== Step 3: Updating Local Casks ===')"
appcast_line="$(first_line '=== Step 6: Updating Appcast ===')"
clean_tree_line="$(last_exact_line 'require_clean_release_tree')"
prepare_publication_line="$(last_exact_line 'prepare_release_git_publication')"
metadata_gate_line="$(last_exact_line 'require_committed_release_metadata')"
dry_run_tap_line="$(first_line 'DRY-RUN: skipping Homebrew tap clone and push preflight.')"
tap_clone_line="$(first_line 'git clone "$TAP_REPO_SSH"')"
tag_line="$(last_exact_line 'ensure_remote_release_tag')"
branch_line="$(last_exact_line 'push_release_branch_if_needed')"
release_create_line="$(first_line 'gh_release release create')"

if [[ -z "$validation_line" || -z "$publication_mode_line" || -z "$zip_line" || -z "$cask_line" \
    || -z "$appcast_line" || -z "$clean_tree_line" || -z "$prepare_publication_line" \
    || -z "$metadata_gate_line" || -z "$dry_run_tap_line" || -z "$tap_clone_line" \
    || -z "$tag_line" || -z "$branch_line" || -z "$release_create_line" ]]; then
    echo "ERROR: could not locate publication ordering markers" >&2
    exit 1
fi

if (( validation_line >= zip_line || publication_mode_line >= zip_line \
    || validation_line >= cask_line || validation_line >= appcast_line \
    || clean_tree_line >= zip_line || clean_tree_line >= cask_line \
    || clean_tree_line >= appcast_line || prepare_publication_line >= zip_line \
    || dry_run_tap_line >= tap_clone_line || metadata_gate_line >= tap_clone_line \
    || metadata_gate_line >= tag_line || metadata_gate_line >= release_create_line \
    || metadata_gate_line >= branch_line )); then
    echo "ERROR: release validation runs after local publication artifacts are mutated" >&2
    exit 1
fi

if grep -Fq 'AV_RELEASE_DRY_RUN_ALLOW_UNSTABLE' "$RELEASE_SCRIPT"; then
    echo "ERROR: create-release.sh can bypass candidate validation instead of validating both modes" >&2
    exit 1
fi

if grep -Eq '<sparkle:minimumSystemVersion>[0-9]+([.][0-9]+)*</sparkle:minimumSystemVersion>' "$RELEASE_SCRIPT"; then
    echo "ERROR: create-release.sh retains a hardcoded appcast minimum macOS version" >&2
    exit 1
fi

if grep -Fq '### Auto-updates' "$RELEASE_SCRIPT" || grep -Fq 'Sparkle will check for updates' "$RELEASE_SCRIPT"; then
    echo "ERROR: create-release.sh still promises automatic Sparkle installation" >&2
    exit 1
fi

echo "Release publication wiring PASS"
