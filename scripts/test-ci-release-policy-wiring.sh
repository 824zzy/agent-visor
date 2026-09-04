#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$SCRIPT_DIR/../.github/workflows/ci.yml"

for test_script in \
    test-release-version-policy.sh \
    test-release-build-mode.sh \
    test-release-build-wiring.sh \
    test-release-swift-legacy.sh \
    test-release-helper-signing-policy.sh \
    test-release-bundle-negative.sh \
    test-release-archive-negative.sh \
    test-release-signing-policy.sh \
    test-release-signing-integration.sh \
    test-release-identity-continuity-policy.sh \
    test-release-sign-setup-wiring.sh \
    test-release-notarization-policy.sh \
    test-release-notarization-integration.sh \
    test-notarize-release-wiring.sh \
    test-release-publication-policy.sh \
    test-release-candidate-integration.sh \
    test-release-publication-wiring.sh \
    test-release-dry-run.sh \
    test-release-publication-commit-gate.sh \
    test-ci-release-policy-wiring.sh; do
    if ! grep -Fq "scripts/$test_script" "$WORKFLOW"; then
        echo "ERROR: CI does not run scripts/$test_script" >&2
        exit 1
    fi
done

require_workflow() {
    local pattern="$1"
    local message="$2"
    if ! grep -Fq "$pattern" "$WORKFLOW"; then
        echo "ERROR: $message" >&2
        exit 1
    fi
}

require_workflow 'uses: actions/setup-node@v4' \
    "CI does not install the pinned Node 22 toolchain"
require_workflow 'node-version: 22.20.0' \
    "CI does not use Node 22.20.0"
require_workflow 'cache: npm' \
    "CI does not enable npm dependency caching"
require_workflow 'cache-dependency-path: package-lock.json' \
    "CI npm cache is not keyed by package-lock.json"
require_workflow 'run: npm ci' \
    "CI does not install from the committed npm lockfile"
for command in \
    'run: npm run build' \
    'run: npm run typecheck' \
    'run: npm test' \
    'run: npm run test:sessions' \
    'run: npm run test:chat' \
    'run: npm run test:clean-profile' \
    'run: npm run test:native-services' \
    'run: npm run test:native-helper' \
    'run: npm run test:native-helper-usage' \
    'run: swift test --package-path AgentVisorCore' \
    'AV_RELEASE_DERIVED="$RUNNER_TEMP/av-release-build" scripts/build.sh'; do
    require_workflow "$command" "CI is missing product gate: $command"
done
require_workflow 'name: Upload tested Electron candidate' \
    "CI does not retain the tested Electron release artifact"
require_workflow 'name: AgentVisor-${{ github.sha }}' \
    "CI artifact is not traceable to the tested commit"
require_workflow 'build/export/AgentVisor-release.zip' \
    "CI does not upload the stable generated Electron archive path"
require_workflow 'build/export/AgentVisor-release.zip.sha256' \
    "CI does not upload the stable generated Electron checksum path"
if grep -Fq 'build/export/AgentVisor-v2.7.0.zip' "$WORKFLOW"; then
    echo "ERROR: CI artifact path hardcodes the release version" >&2
    exit 1
fi

echo "CI release policy wiring PASS"
