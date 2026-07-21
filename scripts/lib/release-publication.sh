#!/bin/bash

release_distribution_mode() {
    local signing_info="${1:-}"
    local team_identifier

    if grep -q '^Signature=adhoc$' <<<"$signing_info"; then
        printf '%s\n' "ad-hoc"
        return 0
    fi

    if grep -Fqx 'Authority=AgentVisor Release' <<<"$signing_info"; then
        printf '%s\n' "self-signed"
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

release_distribution_mode_is_publishable() {
    local mode="${1:-}"
    local allow_adhoc_bridge="${2:-0}"
    local version="${3:-}"
    local build="${4:-}"
    local bridge_version="${5:-}"
    local bridge_build="${6:-}"

    case "$mode" in
        self-signed | developer-id)
            return 0
            ;;
        ad-hoc)
            if [[ "$allow_adhoc_bridge" != "1" ]]; then
                echo "ERROR: ad-hoc candidates are for local and CI validation only" >&2
                return 1
            fi
            if [[ -z "$bridge_version" || -z "$bridge_build" \
                || "$version" != "$bridge_version" \
                || "$build" != "$bridge_build" ]]; then
                echo "ERROR: ad-hoc publication is limited to the pinned migration bridge" >&2
                return 1
            fi
            return 0
            ;;
        *)
            echo "ERROR: unsupported release distribution mode: $mode" >&2
            return 1
            ;;
    esac
}

release_appcast_minimum_update_version_xml() {
    local mode="${1:-}"
    local minimum_build="${2:-}"

    case "$mode" in
        ad-hoc)
            return 0
            ;;
        self-signed | developer-id)
            if [[ ! "$minimum_build" =~ ^[1-9][0-9]*$ ]]; then
                echo "ERROR: stable releases require a numeric migration update floor" >&2
                return 1
            fi
            printf '      <sparkle:minimumUpdateVersion>%s</sparkle:minimumUpdateVersion>\n' \
                "$minimum_build"
            ;;
        *)
            echo "ERROR: unsupported release distribution mode: $mode" >&2
            return 1
            ;;
    esac
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

release_cask_supports_self_signed_install() {
    local cask_source="${1:-}"
    local failed=0

    if ! grep -q 'com.apple.quarantine' <<<"$cask_source"; then
        echo "ERROR: self-signed Homebrew cask must remove Gatekeeper quarantine" >&2
        failed=1
    fi

    if grep -Eq '(^|[^[:alnum:]_])codesign([^[:alnum:]_]|$)' <<<"$cask_source"; then
        echo "ERROR: Homebrew cask must preserve the self-signed release signature" >&2
        failed=1
    fi

    return "$failed"
}
