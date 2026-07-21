#!/bin/bash

release_signature_is_stable() {
    local signing_info="${1:-}"
    local designated_requirement="${2:-}"
    local self_signed_identity="${3:-}"
    local self_signed_sha1="${4:-}"
    local team_identifier
    local failed=0

    if [[ -n "$self_signed_identity" ]] \
        && grep -Fqx "Authority=$self_signed_identity" <<<"$signing_info"; then
        local normalized_sha1

        if [[ ! "$self_signed_sha1" =~ ^[[:xdigit:]]{40}$ ]]; then
            echo "ERROR: pinned self-signed certificate SHA-1 is invalid" >&2
            return 1
        fi
        normalized_sha1="$(tr '[:upper:]' '[:lower:]' <<<"$self_signed_sha1")"

        if grep -q '^Signature=adhoc$' <<<"$signing_info"; then
            echo "ERROR: release signature is ad-hoc" >&2
            failed=1
        fi
        if ! grep -Fqx "Authority=$self_signed_identity" <<<"$signing_info"; then
            echo "ERROR: release is not signed by the pinned self-signed identity" >&2
            failed=1
        fi
        if ! grep -Fq "certificate leaf = H\"$normalized_sha1\"" <<<"$designated_requirement"; then
            echo "ERROR: designated requirement does not match the pinned certificate leaf" >&2
            failed=1
        fi
        if grep -Eq 'designated[[:space:]]*=>[[:space:]]*cdhash' <<<"$designated_requirement"; then
            echo "ERROR: designated requirement is tied to an exact code hash" >&2
            failed=1
        fi
        return "$failed"
    fi

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
