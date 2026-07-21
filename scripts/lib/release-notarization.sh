#!/bin/bash

release_notarization_is_accepted() {
    local assessment_output="${1:-}"
    local stapler_output="${2:-}"
    local failed=0

    if ! grep -Eq '(^|: )[Aa]ccepted$' <<<"$assessment_output"; then
        echo "ERROR: Gatekeeper did not accept the release app" >&2
        failed=1
    fi

    if ! grep -q '^source=Notarized Developer ID$' <<<"$assessment_output"; then
        echo "ERROR: Gatekeeper does not identify the app as Notarized Developer ID" >&2
        failed=1
    fi

    if ! grep -q 'The validate action worked!' <<<"$stapler_output"; then
        echo "ERROR: the app has no valid stapled notarization ticket" >&2
        failed=1
    fi

    return "$failed"
}
