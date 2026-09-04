#!/bin/bash
set -euo pipefail

APP_PATH="${1:?app path is required}"
ZIP_PATH="${2:?release zip path is required}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: release app is missing: $APP_PATH" >&2
    exit 1
fi
if [[ ! -x /usr/bin/zip ]]; then
    echo "ERROR: /usr/bin/zip is required to create the release archive" >&2
    exit 1
fi

APP_PARENT="$(cd "$(dirname "$APP_PATH")" && pwd)"
APP_NAME="$(basename "$APP_PATH")"
mkdir -p "$(dirname "$ZIP_PATH")"
ZIP_PARENT="$(cd "$(dirname "$ZIP_PATH")" && pwd)"
ZIP_PATH="$ZIP_PARENT/$(basename "$ZIP_PATH")"

rm -f "$ZIP_PATH"
(
    cd "$APP_PARENT"
    # ditto's ZIP byte order varies across supported macOS releases. A sorted
    # path list plus stripped extra fields keeps repeated archives of the same
    # signed app byte-identical while -y preserves framework symlinks.
    find "$APP_NAME" -print \
        | LC_ALL=C sort \
        | COPYFILE_DISABLE=1 /usr/bin/zip -q -X -y "$ZIP_PATH" -@
)

if [[ ! -f "$ZIP_PATH" ]]; then
    echo "ERROR: release archive was not created: $ZIP_PATH" >&2
    exit 1
fi
