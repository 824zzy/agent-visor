#!/bin/bash

release_build_mode() {
    local signing_identity="${1:-}"
    local team_identifier="${2:-}"

    if [[ -z "$signing_identity" && -z "$team_identifier" ]]; then
        printf '%s\n' "local-adhoc"
        return 0
    fi

    if [[ "$signing_identity" == "AgentVisor Release" && -z "$team_identifier" ]]; then
        printf '%s\n' "self-signed"
        return 0
    fi

    if [[ -z "$signing_identity" || -z "$team_identifier" ]]; then
        echo "ERROR: AV_RELEASE_SIGN_IDENTITY and AV_RELEASE_TEAM_ID must be set together" >&2
        return 1
    fi

    if [[ "$signing_identity" != "Developer ID Application:"* ]]; then
        echo "ERROR: release identity must be a Developer ID Application identity" >&2
        return 1
    fi

    printf '%s\n' "developer-id"
}
