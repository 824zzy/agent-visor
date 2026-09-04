#!/bin/bash

# Resolve the product coordinates used by the Electron release artifact.
# The root package.json owns the semantic version. The build number and the
# bundle constants live in config/release-version.env so scripts and tests do
# not each carry a second copy of the release contract.

release_version_config_path() {
    local project_dir="${1:?project directory is required}"
    printf '%s\n' "$project_dir/config/release-version.env"
}

release_product_version() {
    local project_dir="${1:?project directory is required}"
    local package_json="$project_dir/package.json"

    if [[ ! -f "$package_json" ]]; then
        echo "ERROR: root package.json is missing: $package_json" >&2
        return 1
    fi

    if command -v node >/dev/null 2>&1; then
        node -e '
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version;
if (typeof value !== "string" || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(value)) process.exit(1);
process.stdout.write(value + "\n");
' "$package_json" || {
            echo "ERROR: root package.json has no valid semantic version: $package_json" >&2
            return 1
        }
        return 0
    fi

    # Node 22 is a release prerequisite, but keep a small fallback so the
    # policy scripts can still report a useful error on an unprovisioned host.
    # Stop at the first root version field so an invalid value cannot silently
    # fall through to a different version-looking field in the JSON file.
    local fallback_version
    fallback_version="$(sed -n '
        /^[[:space:]]*"version"[[:space:]]*:/ {
            s/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p
            q
        }
    ' "$package_json")"
    if [[ -z "$fallback_version" || ! "$fallback_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: root package.json has no valid semantic version: $package_json" >&2
        return 1
    fi
    printf '%s\n' "$fallback_version"
}

release_load_version_config() {
    local project_dir="${1:?project directory is required}"
    local config_path
    config_path="$(release_version_config_path "$project_dir")"
    if [[ ! -f "$config_path" ]]; then
        echo "ERROR: release version config is missing: $config_path" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$config_path"
    return 0
}

release_product_build() {
    local project_dir="${1:?project directory is required}"
    release_load_version_config "$project_dir" || return
    if [[ ! "${AGENT_VISOR_BUILD:-}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: AGENT_VISOR_BUILD must be a positive integer" >&2
        return 1
    fi
    printf '%s\n' "$AGENT_VISOR_BUILD"
}

release_assert_coordinates() {
    local project_dir="${1:?project directory is required}"
    local requested_version="${2:-}"
    local requested_build="${3:-}"
    local version
    local build

    version="$(release_product_version "$project_dir")" || return
    build="$(release_product_build "$project_dir")" || return

    if [[ -n "$requested_version" && "$requested_version" != "$version" ]]; then
        echo "ERROR: requested release version '$requested_version' does not match root package.json '$version'" >&2
        return 1
    fi
    if [[ -n "$requested_build" && "$requested_build" != "$build" ]]; then
        echo "ERROR: requested release build '$requested_build' does not match tracked build '$build'" >&2
        return 1
    fi

    printf '%s\t%s\n' "$version" "$build"
}
