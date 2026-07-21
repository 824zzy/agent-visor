#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$SCRIPT_DIR/../.github/workflows/ci.yml"

for test_script in \
    test-release-build-mode.sh \
    test-release-build-wiring.sh \
    test-release-signing-policy.sh \
    test-release-signing-integration.sh \
    test-release-notarization-policy.sh \
    test-release-notarization-integration.sh \
    test-notarize-release-wiring.sh \
    test-release-publication-policy.sh \
    test-release-candidate-integration.sh \
    test-release-publication-wiring.sh \
    test-ci-release-policy-wiring.sh; do
    if ! grep -Fq "scripts/$test_script" "$WORKFLOW"; then
        echo "ERROR: CI does not run scripts/$test_script" >&2
        exit 1
    fi
done

echo "CI release policy wiring PASS"
