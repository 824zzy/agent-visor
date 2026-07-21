#!/bin/bash

release_distribution_mode() {
    local signing_info="${1:-}"
    local team_identifier

    if grep -q '^Signature=adhoc$' <<<"$signing_info"; then
        printf '%s\n' "ad-hoc"
        return 0
    fi

    team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<<"$signing_info" | head -1)"
    if grep -q '^Authority=Developer ID Application:' <<<"$signing_info" \
        && [[ -n "$team_identifier" && "$team_identifier" != "not set" ]]; then
        printf '%s\n' "developer-id"
        return 0
    fi

    echo "ERROR: unsupported release signing identity" >&2
    return 1
}

release_cask_preserves_signature() {
    local cask_source="${1:-}"
    local failed=0

    if grep -Eq '(^|[^[:alnum:]_])codesign([^[:alnum:]_]|$)' <<<"$cask_source"; then
        echo "ERROR: Homebrew cask must not replace the Developer ID signature" >&2
        failed=1
    fi

    if grep -q 'com.apple.quarantine' <<<"$cask_source"; then
        echo "ERROR: Homebrew cask must preserve Gatekeeper quarantine for the notarized app" >&2
        failed=1
    fi

    return "$failed"
}

release_cask_supports_adhoc_install() {
    local cask_source="${1:-}"
    local failed=0

    if ! grep -q 'com.apple.quarantine' <<<"$cask_source"; then
        echo "ERROR: ad-hoc Homebrew cask must remove Gatekeeper quarantine" >&2
        failed=1
    fi

    if ! grep -Eq '(^|[^[:alnum:]_])codesign([^[:alnum:]_]|$)' <<<"$cask_source"; then
        echo "ERROR: ad-hoc Homebrew cask must re-sign the installed app" >&2
        failed=1
    fi

    if ! grep -q -- '--preserve-metadata=entitlements,flags' <<<"$cask_source"; then
        echo "ERROR: ad-hoc Homebrew re-signing must preserve release entitlements" >&2
        failed=1
    fi

    return "$failed"
}
