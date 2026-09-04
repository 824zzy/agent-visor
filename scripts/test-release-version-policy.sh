#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/release-version.sh"

EXPECTED_VERSION="$(release_product_version "$PROJECT_DIR")"
EXPECTED_BUILD="$(release_product_build "$PROJECT_DIR")"
if [[ "$EXPECTED_VERSION" != "2.7.0" ]]; then
    echo "ERROR: canonical release version drifted: $EXPECTED_VERSION" >&2
    exit 1
fi
if [[ "$EXPECTED_BUILD" != "54" ]]; then
    echo "ERROR: canonical release build drifted: $EXPECTED_BUILD" >&2
    exit 1
fi

if [[ "$(release_assert_coordinates "$PROJECT_DIR" 2.7.0 54)" != $'2.7.0\t54' ]]; then
    echo "ERROR: canonical release coordinates were not resolved" >&2
    exit 1
fi
if release_assert_coordinates "$PROJECT_DIR" 2.7.1 54 >/dev/null 2>&1; then
    echo "ERROR: a mismatched release version was accepted" >&2
    exit 1
fi
if release_assert_coordinates "$PROJECT_DIR" 2.7.0 55 >/dev/null 2>&1; then
    echo "ERROR: a mismatched release build was accepted" >&2
    exit 1
fi

FALLBACK_PATH="/usr/bin:/bin"
if [[ "$(PATH="$FALLBACK_PATH" release_product_version "$PROJECT_DIR")" != "$EXPECTED_VERSION" ]]; then
    echo "ERROR: no-Node release version fallback did not resolve the root version" >&2
    exit 1
fi

INVALID_PROJECT="$(mktemp -d -t av-invalid-release-version.XXXXXX)"
cleanup_invalid_project() {
    rm -rf "$INVALID_PROJECT"
}
trap cleanup_invalid_project EXIT
printf '%s\n' '{"name":"agent-visor","version":""}' > "$INVALID_PROJECT/package.json"
if PATH="$FALLBACK_PATH" release_product_version "$INVALID_PROJECT" >/dev/null 2>&1; then
    echo "ERROR: no-Node release version fallback accepted an empty version" >&2
    exit 1
fi
printf '%s\n' '{"name":"agent-visor","version":"2.7"}' > "$INVALID_PROJECT/package.json"
if PATH="$FALLBACK_PATH" release_product_version "$INVALID_PROJECT" >/dev/null 2>&1; then
    echo "ERROR: no-Node release version fallback accepted an invalid version" >&2
    exit 1
fi

if ! grep -Fq '"version": "2.7.0"' "$PROJECT_DIR/package.json"; then
    echo "ERROR: package.json does not declare the canonical release version" >&2
    exit 1
fi
if ! grep -Fq '"version": "2.7.0"' "$PROJECT_DIR/package-lock.json"; then
    echo "ERROR: package-lock.json does not declare the canonical release version" >&2
    exit 1
fi

echo "Release version policy PASS: 2.7.0/build 54"
