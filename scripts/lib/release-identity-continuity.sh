#!/bin/bash

release_identity_is_continuous() {
    local first_executable_hash="${1:-}"
    local second_executable_hash="${2:-}"
    local first_requirement="${3:-}"
    local second_requirement="${4:-}"
    local failed=0

    if [[ -z "$first_executable_hash" || -z "$second_executable_hash" ]]; then
        echo "ERROR: executable hashes are required" >&2
        failed=1
    elif [[ "$first_executable_hash" == "$second_executable_hash" ]]; then
        echo "ERROR: continuity check did not compare two different builds" >&2
        failed=1
    fi

    if [[ -z "$first_requirement" || "$first_requirement" != "$second_requirement" ]]; then
        echo "ERROR: designated requirement changed across builds" >&2
        failed=1
    fi

    return "$failed"
}
