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

release_signature_field() {
    local field="${1:?signature field is required}"
    local signing_info="${2:-}"

    sed -n "s/^${field}=//p" <<<"$signing_info" | head -1
}

release_validate_nested_signature() {
    local mode="${1:?release signing mode is required}"
    local outer_signing_info="${2:-}"
    local helper_signing_info="${3:-}"
    local pinned_identity="${4:-}"
    local pinned_team="${5:-}"
    local outer_authority
    local helper_authority
    local outer_team
    local helper_team
    local failed=0

    case "$mode" in
        ad-hoc)
            if ! grep -q '^Signature=adhoc$' <<<"$helper_signing_info"; then
                echo "ERROR: nested native helper is not ad-hoc signed with the outer app" >&2
                failed=1
            fi
            ;;
        self-signed | developer-id)
            outer_authority="$(release_signature_field Authority "$outer_signing_info")"
            helper_authority="$(release_signature_field Authority "$helper_signing_info")"
            outer_team="$(release_signature_field TeamIdentifier "$outer_signing_info")"
            helper_team="$(release_signature_field TeamIdentifier "$helper_signing_info")"

            if [[ -n "$pinned_identity" && "$outer_authority" != "$pinned_identity" ]]; then
                echo "ERROR: outer release app is not signed by the pinned identity" >&2
                failed=1
            fi
            if [[ -z "$outer_authority" || "$helper_authority" != "$outer_authority" ]]; then
                echo "ERROR: nested native helper signing identity does not match the outer app" >&2
                failed=1
            fi
            if [[ -z "$outer_team" || "$helper_team" != "$outer_team" ]]; then
                echo "ERROR: nested native helper TeamIdentifier does not match the outer app" >&2
                failed=1
            fi
            if [[ -n "$pinned_team" && "$outer_team" != "$pinned_team" ]]; then
                echo "ERROR: outer release app does not carry the pinned TeamIdentifier" >&2
                failed=1
            fi
            ;;
        *)
            echo "ERROR: unsupported nested release signing mode: $mode" >&2
            failed=1
            ;;
    esac

    return "$failed"
}
