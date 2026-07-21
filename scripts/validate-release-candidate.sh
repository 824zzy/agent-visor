#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-publication.sh"

if (( $# < 2 )); then
    echo "Usage: $0 /path/to/Agent\ Visor.app /path/to/cask.rb [...]" >&2
    exit 2
fi

APP_PATH="$1"
shift

"$SCRIPT_DIR/test-release-bundle.sh" "$APP_PATH"
SIGNING_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
DISTRIBUTION_MODE="$(release_distribution_mode "$SIGNING_INFO")"

case "$DISTRIBUTION_MODE" in
    ad-hoc)
        for cask_path in "$@"; do
            if [[ ! -f "$cask_path" ]]; then
                echo "ERROR: Homebrew cask not found: $cask_path" >&2
                exit 1
            fi
            release_cask_supports_adhoc_install "$(cat "$cask_path")"
        done
        "$SCRIPT_DIR/test-homebrew-resign.sh" "$APP_PATH"
        ;;
    developer-id)
        "$SCRIPT_DIR/verify-stable-release-signature.sh" "$APP_PATH"
        "$SCRIPT_DIR/verify-notarized-release.sh" "$APP_PATH"
        for cask_path in "$@"; do
            if [[ ! -f "$cask_path" ]]; then
                echo "ERROR: Homebrew cask not found: $cask_path" >&2
                exit 1
            fi
            release_cask_preserves_signature "$(cat "$cask_path")"
        done
        ;;
    *)
        echo "ERROR: unsupported release distribution mode: $DISTRIBUTION_MODE" >&2
        exit 1
        ;;
esac

echo "Release candidate PASS: $DISTRIBUTION_MODE distribution contract is intact."
