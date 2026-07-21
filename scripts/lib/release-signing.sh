#!/bin/bash

release_signature_is_stable() {
    local signing_info="${1:-}"
    local designated_requirement="${2:-}"
    local team_identifier
    local failed=0

    if grep -q '^Signature=adhoc$' <<<"$signing_info"; then
        echo "ERROR: release signature is ad-hoc" >&2
        failed=1
    fi

    if ! grep -q '^Authority=Developer ID Application:' <<<"$signing_info"; then
        echo "ERROR: release is not signed by a Developer ID Application identity" >&2
        failed=1
    fi

    team_identifier="$({
        sed -n 's/^TeamIdentifier=//p' <<<"$signing_info" | head -1
    })"
    if [ -z "$team_identifier" ] || [ "$team_identifier" = "not set" ]; then
        echo "ERROR: release signature has no Team Identifier" >&2
        failed=1
    fi

    if grep -Eq 'designated[[:space:]]*=>[[:space:]]*cdhash' <<<"$designated_requirement"; then
        echo "ERROR: designated requirement is tied to an exact code hash" >&2
        failed=1
    fi

    if ! grep -q 'anchor apple generic' <<<"$designated_requirement"; then
        echo "ERROR: designated requirement is not anchored to Apple" >&2
        failed=1
    fi

    return "$failed"
}
