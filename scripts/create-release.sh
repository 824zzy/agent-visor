#!/bin/bash
# Create an Agent Visor release: zip the app, sign with Sparkle, upload to
# GitHub, and print the appcast item.
# Non-dry runs are tag-first: run from a clean local release commit before
# pushing the Pages branch. The script pushes tag vX.Y.Z, creates the GitHub
# release asset, then pushes the branch so Sparkle never sees an asset URL
# before the asset exists.
#
# Requires:
#   - scripts/build.sh already run (produces $EXPORT_PATH/Agent Visor.app)
#   - A Sparkle EdDSA private key at $PROJECT_DIR/.sparkle-keys/eddsa_private_key
#   - gh CLI authenticated against 824zzy/agent-visor
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="$PROJECT_DIR/releases"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"
RELEASE_DERIVED="${AV_RELEASE_DERIVED:-/tmp/av-release-build}"

# GitHub repository (owner/repo format).
GITHUB_REPO="824zzy/agent-visor"

# Appcast lives in-repo at docs/appcast.xml and is served via GitHub Pages.
APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml"

APP_PATH="$EXPORT_PATH/Agent Visor.app"
ARTIFACT_NAME="AgentVisor"
TAP_REPO="824zzy/homebrew-agent-visor"
TAP_REPO_SSH="git@github.com:824zzy/homebrew-agent-visor.git"
LOCAL_CASKS=(
    "$PROJECT_DIR/Casks/agent-visor.rb"
)
DRY_RUN="${AV_RELEASE_DRY_RUN:-${AV_DRY_RUN:-0}}"
GITHUB_LOGIN="${AV_RELEASE_GITHUB_LOGIN:-824zzy}"
RELEASE_BRANCH="${AV_RELEASE_BRANCH:-main}"
RELEASE_GIT_SSH_COMMAND="${AV_RELEASE_GIT_SSH_COMMAND:-ssh -i $HOME/.ssh/id_ed25519_personal_github -o IdentitiesOnly=yes -o BatchMode=yes}"
GH_RELEASE_TOKEN=""
TAP_CLONE_DIR=""
RELEASE_NOTES_HTML=""
RELEASE_NOTES_MARKDOWN=""
GITHUB_NOTES_PATH=""
APPCAST_ITEM_INSERTED=false
APPCAST_ALREADY_CONTAINS=false
APPCAST_ITEM_REPLACED=false
RELEASE_HEAD_SHA=""
REMOTE_HEAD_SHA=""
BRANCH_PUSH_NEEDED=false
BRANCH_PUSHED=false
TAG_PUSHED=false

if [ "$#" -ne 0 ]; then
    echo "ERROR: create-release.sh does not accept a version argument."
    echo "       Update AgentVisor/Info.plist, run scripts/build.sh, then run scripts/create-release.sh."
    exit 1
fi

cleanup() {
    if [ -n "$TAP_CLONE_DIR" ] && [ -d "$TAP_CLONE_DIR" ]; then
        rm -rf "$TAP_CLONE_DIR"
    fi
}
trap cleanup EXIT

require_nonempty_file() {
    local label="$1"
    local path="$2"
    if [ ! -f "$path" ]; then
        echo "ERROR: $label file not found at $path."
        exit 1
    fi
    if [ -z "$(tr -d '[:space:]' < "$path")" ]; then
        echo "ERROR: $label file is empty: $path."
        exit 1
    fi
}

require_private_key_security() {
    local path="$1"
    local key_owner
    local key_mode
    local key_mode_value

    key_owner=$(stat -f '%u' "$path")
    if [ "$key_owner" != "$(id -u)" ]; then
        echo "ERROR: Sparkle private key is not owned by the current user: $path"
        exit 1
    fi

    key_mode=$(stat -f '%Lp' "$path")
    key_mode_value=$((8#$key_mode))
    if (( (key_mode_value & 077) != 0 )); then
        echo "ERROR: Sparkle private key is readable or writable by another user: $path"
        echo "       Run: chmod 600 '$path'"
        exit 1
    fi
}

load_release_notes() {
    if [ -n "${AV_RELEASE_NOTES_HTML:-}" ]; then
        RELEASE_NOTES_HTML="$AV_RELEASE_NOTES_HTML"
    elif [ -n "${AV_RELEASE_NOTES_HTML_FILE:-}" ]; then
        require_nonempty_file "appcast release notes HTML" "$AV_RELEASE_NOTES_HTML_FILE"
        RELEASE_NOTES_HTML="$(cat "$AV_RELEASE_NOTES_HTML_FILE")"
    else
        echo "ERROR: appcast release notes are required before publishing."
        echo "       Provide AV_RELEASE_NOTES_HTML_FILE=/path/to/notes.html"
        echo "       or AV_RELEASE_NOTES_HTML='<ul><li>...</li></ul>'."
        exit 1
    fi

    if [ -z "$(printf "%s" "$RELEASE_NOTES_HTML" | tr -d '[:space:]')" ]; then
        echo "ERROR: appcast release notes HTML is empty."
        exit 1
    fi
    if printf "%s" "$RELEASE_NOTES_HTML" | grep -q ']]>'; then
        echo "ERROR: appcast release notes HTML cannot contain ']]>' because it is embedded in CDATA."
        exit 1
    fi

    if [ -n "${AV_RELEASE_NOTES_MARKDOWN_FILE:-}" ]; then
        require_nonempty_file "GitHub release notes Markdown" "$AV_RELEASE_NOTES_MARKDOWN_FILE"
        RELEASE_NOTES_MARKDOWN="$(cat "$AV_RELEASE_NOTES_MARKDOWN_FILE")"
    elif [ -n "${AV_RELEASE_NOTES_MARKDOWN:-}" ]; then
        RELEASE_NOTES_MARKDOWN="$AV_RELEASE_NOTES_MARKDOWN"
    else
        RELEASE_NOTES_MARKDOWN="$RELEASE_NOTES_HTML"
    fi
}

resolve_github_release_token() {
    if [ -n "$GH_RELEASE_TOKEN" ]; then
        return
    fi
    if ! command -v gh &> /dev/null; then
        echo "ERROR: gh CLI not found. Install with: brew install gh"
        exit 1
    fi
    if [ -n "${AV_RELEASE_GH_TOKEN:-}" ]; then
        GH_RELEASE_TOKEN="$AV_RELEASE_GH_TOKEN"
    else
        GH_RELEASE_TOKEN=$(gh auth token --hostname github.com --user "$GITHUB_LOGIN" 2>/dev/null || true)
    fi
    if [ -z "$GH_RELEASE_TOKEN" ]; then
        echo "ERROR: could not resolve a GitHub token for $GITHUB_LOGIN."
        echo "       Run: gh auth login --hostname github.com --git-protocol https --web"
        echo "       Or provide AV_RELEASE_GH_TOKEN."
        exit 1
    fi
    local login
    login=$(GH_TOKEN="$GH_RELEASE_TOKEN" gh api user --jq .login 2>/dev/null || true)
    if [ "$login" != "$GITHUB_LOGIN" ]; then
        echo "ERROR: release GitHub token resolves to '$login', expected '$GITHUB_LOGIN'."
        echo "       Run: gh auth switch -h github.com -u $GITHUB_LOGIN"
        echo "       Or provide AV_RELEASE_GH_TOKEN for $GITHUB_LOGIN."
        exit 1
    fi
}

gh_release() {
    GH_TOKEN="$GH_RELEASE_TOKEN" gh "$@"
}

require_clean_release_tree() {
    if [ "$DRY_RUN" = "1" ] || [ "${AV_ALLOW_DIRTY_RELEASE:-0}" = "1" ]; then
        return
    fi
    if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        echo "ERROR: refusing to publish from a dirty worktree."
        echo "       Commit the app, cask, and appcast changes first so GitHub Pages and"
        echo "       the release asset can point at the same versioned state."
        echo "       Use AV_ALLOW_DIRTY_RELEASE=1 only for an intentional recovery publish."
        git -C "$PROJECT_DIR" status --short
        exit 1
    fi
    if [ -n "$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard)" ]; then
        echo "ERROR: refusing to publish with untracked files in the worktree."
        echo "       Commit or remove generated release files before publishing, or set"
        echo "       AV_ALLOW_DIRTY_RELEASE=1 for an intentional recovery publish."
        git -C "$PROJECT_DIR" status --short
        exit 1
    fi
}

prepare_release_git_publication() {
    if [ "$DRY_RUN" = "1" ] || [ "${AV_ALLOW_UNPUSHED_RELEASE:-0}" = "1" ]; then
        return
    fi

    local branch
    branch=$(git -C "$PROJECT_DIR" branch --show-current)
    if [ "$branch" != "$RELEASE_BRANCH" ]; then
        echo "ERROR: refusing to publish from branch '$branch'."
        echo "       Publish releases from '$RELEASE_BRANCH' so GitHub Pages serves"
        echo "       the committed docs/appcast.xml update."
        echo "       Set AV_RELEASE_BRANCH=<branch> only if Pages is intentionally served elsewhere."
        exit 1
    fi

    RELEASE_HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD)
    git -C "$PROJECT_DIR" fetch --quiet origin "$RELEASE_BRANCH:refs/remotes/origin/$RELEASE_BRANCH"
    REMOTE_HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse "refs/remotes/origin/$RELEASE_BRANCH" 2>/dev/null || true)
    if [ -z "$REMOTE_HEAD_SHA" ]; then
        echo "ERROR: could not resolve origin/$RELEASE_BRANCH."
        echo "       Push the release branch or set AV_RELEASE_BRANCH to the Pages branch."
        exit 1
    fi

    if ! git -C "$PROJECT_DIR" merge-base --is-ancestor "$REMOTE_HEAD_SHA" "$RELEASE_HEAD_SHA"; then
        echo "ERROR: origin/$RELEASE_BRANCH is not an ancestor of local HEAD."
        echo "       local HEAD:  $RELEASE_HEAD_SHA"
        echo "       remote HEAD: $REMOTE_HEAD_SHA"
        echo "       Rebase or merge origin/$RELEASE_BRANCH before publishing."
        exit 1
    fi

    if [ "$RELEASE_HEAD_SHA" != "$REMOTE_HEAD_SHA" ]; then
        BRANCH_PUSH_NEEDED=true
        echo "origin/$RELEASE_BRANCH is behind the local release commit."
        echo "The script will push tag v$VERSION first, create the GitHub release asset,"
        echo "then push $RELEASE_BRANCH so the Sparkle appcast cannot point at a missing asset."
    fi
}

ensure_remote_release_tag() {
    if [ "$DRY_RUN" = "1" ] || [ "${AV_ALLOW_UNPUSHED_RELEASE:-0}" = "1" ]; then
        return
    fi
    if [ -z "$RELEASE_HEAD_SHA" ]; then
        RELEASE_HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD)
    fi

    local tag_name="v$VERSION"
    local remote_tag_sha
    remote_tag_sha=$(git -C "$PROJECT_DIR" ls-remote origin "refs/tags/$tag_name^{}" | awk '{print $1}')
    if [ -z "$remote_tag_sha" ]; then
        remote_tag_sha=$(git -C "$PROJECT_DIR" ls-remote origin "refs/tags/$tag_name" | awk '{print $1}')
    fi

    if [ -n "$remote_tag_sha" ]; then
        if [ "$remote_tag_sha" != "$RELEASE_HEAD_SHA" ]; then
            echo "ERROR: remote tag $tag_name already exists at $remote_tag_sha."
            echo "       Expected it to point at local release commit $RELEASE_HEAD_SHA."
            echo "       Bump the version or repair the tag intentionally before publishing."
            exit 1
        fi
        echo "Remote tag $tag_name already points at the release commit."
        return
    fi

    echo "Pushing tag $tag_name at $RELEASE_HEAD_SHA before creating the GitHub release..."
    GIT_SSH_COMMAND="$RELEASE_GIT_SSH_COMMAND" git -C "$PROJECT_DIR" push --quiet origin "$RELEASE_HEAD_SHA:refs/tags/$tag_name"
    TAG_PUSHED=true
}

push_release_branch_if_needed() {
    if [ "$DRY_RUN" = "1" ] || [ "${AV_ALLOW_UNPUSHED_RELEASE:-0}" = "1" ]; then
        return
    fi
    if [ "$BRANCH_PUSH_NEEDED" != true ]; then
        return
    fi

    echo "Pushing $RELEASE_BRANCH after GitHub release asset creation..."
    GIT_SSH_COMMAND="$RELEASE_GIT_SSH_COMMAND" git -C "$PROJECT_DIR" push --quiet origin "HEAD:refs/heads/$RELEASE_BRANCH"
    BRANCH_PUSHED=true
}

echo "=== Creating Agent Visor Release ==="
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    echo "Run ./scripts/build.sh first"
    exit 1
fi

# Get version from app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$ARTIFACT_NAME-v$VERSION.zip"

echo "Version: $VERSION (build $BUILD)"
if [ "$DRY_RUN" = "1" ]; then
    echo "Mode: dry run (GitHub release and tap push will be skipped)"
fi
echo ""

mkdir -p "$BUILD_DIR" "$RELEASE_DIR"

if [ "$DRY_RUN" != "1" ]; then
    resolve_github_release_token
fi

if [ "$DRY_RUN" != "1" ] && gh_release release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
    if [ "${AV_ALLOW_EXISTING_RELEASE_UPLOAD:-0}" != "1" ]; then
        echo "ERROR: GitHub release v$VERSION already exists in $GITHUB_REPO."
        echo "       Bump MARKETING_VERSION / CURRENT_PROJECT_VERSION before releasing,"
        echo "       or set AV_ALLOW_EXISTING_RELEASE_UPLOAD=1 to intentionally replace the asset."
        exit 1
    fi
fi

load_release_notes

GITHUB_NOTES_PATH="$BUILD_DIR/github-release-notes-v$VERSION.md"
{
    printf "%s\n\n" "$RELEASE_NOTES_MARKDOWN"
    cat <<EOF
### Installation

**Homebrew (recommended):**
\`\`\`
brew install --cask 824zzy/agent-visor/agent-visor
\`\`\`

**Direct download:**
1. Download \`$ARTIFACT_NAME-v$VERSION.zip\`
2. Unzip and drag Agent Visor.app to /Applications
3. Launch Agent Visor from /Applications

### Auto-updates
Sparkle will check for updates in the background and prompt you to install.
EOF
} > "$GITHUB_NOTES_PATH"

echo "Release notes loaded."
echo "GitHub notes: $GITHUB_NOTES_PATH"
echo ""

# ============================================
# Step 1: Confirm ad-hoc release app
# ============================================
echo "=== Step 1: Confirming App ==="
echo "Using ad-hoc release app at: $APP_PATH"
"$SCRIPT_DIR/test-release-bundle.sh" "$APP_PATH"
"$SCRIPT_DIR/test-homebrew-resign.sh" "$APP_PATH"
echo "Homebrew removes quarantine and re-signs after install; direct-download users follow README.md."

echo ""

# ============================================
# Step 2: Create release ZIP
# ============================================
# We ship ZIP (not DMG) to match the existing appcast.
echo "=== Step 2: Creating Release ZIP ==="

mkdir -p "$RELEASE_DIR"
ZIP_PATH="$RELEASE_DIR/$ARTIFACT_NAME-v$VERSION.zip"

if [ -f "$ZIP_PATH" ]; then
    echo "Removing existing ZIP..."
    rm -f "$ZIP_PATH"
fi

COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP_PATH" "$ZIP_PATH"
"$SCRIPT_DIR/test-release-archive.sh" "$ZIP_PATH"
ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
ZIP_SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

echo "ZIP created: $ZIP_PATH ($ZIP_SIZE bytes)"
echo ""

# ============================================
# Step 3: Update local casks
# ============================================
echo "=== Step 3: Updating Local Casks ==="

for local_cask in "${LOCAL_CASKS[@]}"; do
    if [ ! -f "$local_cask" ]; then
        echo "ERROR: local cask not found at $local_cask."
        exit 1
    fi
    sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$local_cask"
    sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$ZIP_SHA\"/" "$local_cask"
    echo "Updated $(basename "$local_cask") to v$VERSION ($ZIP_SHA)"
done

echo ""

# ============================================
# Step 4: Sign for Sparkle and generate appcast
# ============================================
echo "=== Step 4: Signing for Sparkle ==="

# Find Sparkle tools. After building in Xcode, these live under DerivedData.
SPARKLE_SIGN=""

POSSIBLE_PATHS=(
    "$RELEASE_DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
    "$HOME/Library/Developer/Xcode/DerivedData/AgentVisor-*/SourcePackages/artifacts/sparkle/Sparkle/bin"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path/sign_update" ]; then
            SPARKLE_SIGN="$path/sign_update"
            break 2
        fi
    done
done

SPARKLE_SIGNATURE=""
if [ -z "$SPARKLE_SIGN" ]; then
    echo "ERROR: Could not find Sparkle tools (sign_update)."
    echo "       Open the project in Xcode once so Swift Package Manager fetches Sparkle,"
    echo "       then re-run this script."
    if [ "${AV_ALLOW_UNSIGNED_APPCAST:-0}" != "1" ]; then
        exit 1
    fi
    echo "WARNING: continuing without Sparkle signature because AV_ALLOW_UNSIGNED_APPCAST=1."
elif [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
    echo "ERROR: No Sparkle private key at $KEYS_DIR/eddsa_private_key"
    echo "       Run ./scripts/generate-keys.sh first."
    if [ "${AV_ALLOW_UNSIGNED_APPCAST:-0}" != "1" ]; then
        exit 1
    fi
    echo "WARNING: continuing without Sparkle signature because AV_ALLOW_UNSIGNED_APPCAST=1."
else
    require_private_key_security "$KEYS_DIR/eddsa_private_key"
    echo "Signing ZIP for Sparkle..."
    SPARKLE_SIGNATURE_RAW=$("$SPARKLE_SIGN" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$ZIP_PATH")
    SPARKLE_SIGNATURE=$(printf "%s" "$SPARKLE_SIGNATURE_RAW" | sed -E 's/[[:space:]]+length="[^"]+"//g')
    if [ -z "$SPARKLE_SIGNATURE" ]; then
        echo "ERROR: Sparkle sign_update returned an empty signature."
        exit 1
    fi
    echo ""
    echo "Sparkle signature line:"
    echo "  $SPARKLE_SIGNATURE"
fi

echo ""

# ============================================
# Step 5: Preflight Homebrew Cask
# ============================================
# brew installs read from github.com/$TAP_REPO, NOT from this repo's Casks/.
# Validate before creating the GitHub release so a stale cask cannot leave a
# half-published release behind.
echo "=== Step 5: Preflighting Homebrew Cask ==="

TAP_PUSHED=false
CASK_PREFLIGHT_OK=false
GITHUB_RELEASE_DONE=false
TAP_SYNC_READY=false
TAP_HAS_CHANGES=false

for local_cask in "${LOCAL_CASKS[@]}"; do
    if [ ! -f "$local_cask" ]; then
        echo "ERROR: local cask not found at $local_cask."
        exit 1
    fi
    LOCAL_CASK_VERSION=$(grep -E '^\s*version\s+"' "$local_cask" | head -1 | sed -E 's/.*version "([^"]+)".*/\1/')
    if [ "$LOCAL_CASK_VERSION" != "$VERSION" ]; then
        echo "ERROR: $(basename "$local_cask") pinned to v$LOCAL_CASK_VERSION, expected v$VERSION."
        echo "       The automatic cask update failed; inspect Casks/ before publishing."
        exit 1
    fi

    LOCAL_CASK_SHA=$(grep -E '^\s*sha256\s+"' "$local_cask" | head -1 | sed -E 's/.*sha256 "([^"]+)".*/\1/')
    if [ "$LOCAL_CASK_SHA" != "$ZIP_SHA" ]; then
        echo "ERROR: $(basename "$local_cask") sha256 does not match the built zip."
        echo "       cask:  $LOCAL_CASK_SHA"
        echo "       zip:   $ZIP_SHA"
        echo "       zip path: $ZIP_PATH"
        echo "       The automatic cask update failed; inspect Casks/ before publishing."
        exit 1
    fi
done
CASK_PREFLIGHT_OK=true
echo "All local cask versions and sha256 values match the built zip."

echo ""

# ============================================
# Step 6: Preflight Homebrew Tap Push
# ============================================
# Clone the tap, stage the cask update, and run a dry-run push before creating
# the GitHub release. This catches missing push auth or commit config before a
# public release exists.
echo "=== Step 6: Preflighting Homebrew Tap Push ==="

if [ "$CASK_PREFLIGHT_OK" != true ]; then
    echo "Skipping tap preflight because cask preflight did not run."
elif [[ "$RELEASE_GIT_SSH_COMMAND" == *"id_ed25519_personal_github"* ]] && [ ! -f "$HOME/.ssh/id_ed25519_personal_github" ]; then
    echo "ERROR: personal GitHub SSH key not found at ~/.ssh/id_ed25519_personal_github."
    echo "       Provide AV_RELEASE_GIT_SSH_COMMAND if using a different key."
    exit 1
else
    TAP_CLONE_DIR="$(mktemp -d -t av-tap.XXXXXX)"
    echo "Cloning $TAP_REPO into $TAP_CLONE_DIR..."
    GIT_SSH_COMMAND="$RELEASE_GIT_SSH_COMMAND" git clone "$TAP_REPO_SSH" "$TAP_CLONE_DIR" --quiet
    mkdir -p "$TAP_CLONE_DIR/Casks"
    for local_cask in "${LOCAL_CASKS[@]}"; do
        cp "$local_cask" "$TAP_CLONE_DIR/Casks/$(basename "$local_cask")"
    done
    if [ -z "$(git -C "$TAP_CLONE_DIR" status --porcelain -- Casks/agent-visor.rb)" ]; then
        echo "Tap cask already at v$VERSION — no tap push needed."
        TAP_SYNC_READY=true
    else
        git -C "$TAP_CLONE_DIR" add Casks/agent-visor.rb
        git -C "$TAP_CLONE_DIR" commit -m "chore: sync casks to v$VERSION" --quiet
        GIT_SSH_COMMAND="$RELEASE_GIT_SSH_COMMAND" git -C "$TAP_CLONE_DIR" push --dry-run --quiet
        echo "Tap push dry-run succeeded."
        TAP_SYNC_READY=true
        TAP_HAS_CHANGES=true
    fi
fi

echo ""

# ============================================
# Step 7: Update Appcast
# ============================================
# Insert the newest item immediately after <language>. This keeps the release
# feed sorted newest-first and fails before any public release if the XML shape
# is not what we expect.
echo "=== Step 7: Updating Appcast ==="

PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
APPCAST_ITEM_PATH="$BUILD_DIR/appcast-item-v$VERSION.xml"

cat > "$APPCAST_ITEM_PATH" <<EOF
    <item>
      <title>v$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<h2>v$VERSION</h2>
$RELEASE_NOTES_HTML
]]></description>
      <enclosure
        url="$GITHUB_DOWNLOAD_URL"
        type="application/octet-stream"
        $SPARKLE_SIGNATURE
        length="$ZIP_SIZE"
      />
    </item>
EOF

if [ ! -f "$APPCAST_PATH" ]; then
    echo "ERROR: appcast not found at $APPCAST_PATH."
    exit 1
fi

if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_PATH"; then
    APPCAST_ALREADY_CONTAINS=true
    APPCAST_EXISTING_ITEM_PATH="$BUILD_DIR/appcast-existing-item-v$VERSION.xml"
    if ! awk -v version="$VERSION" '
        /<item>/ {
            in_item = 1
            item = $0 ORS
            next
        }
        in_item {
            item = item $0 ORS
            if ($0 ~ /<\/item>/) {
                if (index(item, "<sparkle:shortVersionString>" version "</sparkle:shortVersionString>") > 0) {
                    printf "%s", item
                    found = 1
                    exit
                }
                in_item = 0
                item = ""
            }
        }
        END { if (!found) exit 42 }
    ' "$APPCAST_PATH" > "$APPCAST_EXISTING_ITEM_PATH"; then
        echo "ERROR: appcast claims to contain v$VERSION, but the matching <item> could not be extracted."
        exit 1
    fi

    GENERATED_APPCAST_NORMALIZED="$(mktemp -t av-appcast-generated.XXXXXX)"
    EXISTING_APPCAST_NORMALIZED="$(mktemp -t av-appcast-existing.XXXXXX)"
    sed '/<pubDate>/d' "$APPCAST_ITEM_PATH" > "$GENERATED_APPCAST_NORMALIZED"
    sed '/<pubDate>/d' "$APPCAST_EXISTING_ITEM_PATH" > "$EXISTING_APPCAST_NORMALIZED"

    if cmp -s "$GENERATED_APPCAST_NORMALIZED" "$EXISTING_APPCAST_NORMALIZED"; then
        echo "Appcast already contains matching v$VERSION metadata; leaving $APPCAST_PATH unchanged."
    else
        if [ "${AV_ALLOW_EXISTING_APPCAST_ITEM:-0}" != "1" ]; then
            echo "ERROR: appcast already contains v$VERSION, but it does not match the current build metadata."
            echo "       Review the diff below, then set AV_ALLOW_EXISTING_APPCAST_ITEM=1"
            echo "       only when intentionally replacing the local appcast item with the"
            echo "       current build metadata."
            diff -u "$EXISTING_APPCAST_NORMALIZED" "$GENERATED_APPCAST_NORMALIZED" || true
            exit 1
        fi
        echo "Appcast already contains v$VERSION, but it does not match the current build metadata."
        echo "Replacing the local appcast item because AV_ALLOW_EXISTING_APPCAST_ITEM=1."
        diff -u "$EXISTING_APPCAST_NORMALIZED" "$GENERATED_APPCAST_NORMALIZED" || true
        TMP_APPCAST="$(mktemp -t av-appcast-replace.XXXXXX)"
        if ! awk -v version="$VERSION" -v item_path="$APPCAST_ITEM_PATH" '
            /<item>/ {
                in_item = 1
                item = $0 ORS
                next
            }
            in_item {
                item = item $0 ORS
                if ($0 ~ /<\/item>/) {
                    if (index(item, "<sparkle:shortVersionString>" version "</sparkle:shortVersionString>") > 0) {
                        while ((getline line < item_path) > 0) print line
                        close(item_path)
                        replaced = 1
                    } else {
                        printf "%s", item
                    }
                    in_item = 0
                    item = ""
                }
                next
            }
            { print }
            END { if (!replaced) exit 42 }
        ' "$APPCAST_PATH" > "$TMP_APPCAST"; then
            rm -f "$TMP_APPCAST"
            echo "ERROR: could not replace v$VERSION item in $APPCAST_PATH."
            exit 1
        fi
        mv "$TMP_APPCAST" "$APPCAST_PATH"
        APPCAST_ITEM_REPLACED=true
        echo "Replaced existing v$VERSION item in $APPCAST_PATH."
    fi

    rm -f "$GENERATED_APPCAST_NORMALIZED" "$EXISTING_APPCAST_NORMALIZED"
else
    TMP_APPCAST="$(mktemp -t av-appcast.XXXXXX)"
    if ! awk -v item_path="$APPCAST_ITEM_PATH" '
        {
            print
            if (!inserted && $0 ~ /^[[:space:]]*<language>[^<]*<\/language>[[:space:]]*$/) {
                while ((getline line < item_path) > 0) print line
                close(item_path)
                inserted = 1
            }
        }
        END { if (!inserted) exit 42 }
    ' "$APPCAST_PATH" > "$TMP_APPCAST"; then
        rm -f "$TMP_APPCAST"
        echo "ERROR: could not insert appcast item after <language> in $APPCAST_PATH."
        exit 1
    fi
    mv "$TMP_APPCAST" "$APPCAST_PATH"
    APPCAST_ITEM_INSERTED=true
    echo "Inserted v$VERSION into $APPCAST_PATH."
fi

if command -v xmllint &>/dev/null; then
    xmllint --noout "$APPCAST_PATH"
fi

echo ""

require_clean_release_tree
prepare_release_git_publication

# ============================================
# Step 8: Create GitHub Release
# ============================================
echo "=== Step 8: Creating GitHub Release ==="

if [ "$DRY_RUN" = "1" ]; then
    echo "DRY-RUN: skipping GitHub release."
else
    resolve_github_release_token
    ensure_remote_release_tag
    if gh_release release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
        if [ "${AV_ALLOW_EXISTING_RELEASE_UPLOAD:-0}" != "1" ]; then
            echo "ERROR: release v$VERSION already exists."
            echo "       Refusing to clobber-upload $ZIP_PATH without an explicit override."
            echo "       Set AV_ALLOW_EXISTING_RELEASE_UPLOAD=1 only when intentionally"
            echo "       repairing an existing release asset."
            exit 1
        fi
        echo "Release v$VERSION already exists. Uploading ZIP because AV_ALLOW_EXISTING_RELEASE_UPLOAD=1..."
        gh_release release upload "v$VERSION" "$ZIP_PATH" --repo "$GITHUB_REPO" --clobber
        GITHUB_RELEASE_DONE=true
    else
        echo "Creating release v$VERSION..."
        gh_release release create "v$VERSION" "$ZIP_PATH" \
            --repo "$GITHUB_REPO" \
            --title "Agent Visor v$VERSION" \
            --notes-file "$GITHUB_NOTES_PATH"
        GITHUB_RELEASE_DONE=true
    fi

    echo "GitHub release: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
    echo "Download URL:   $GITHUB_DOWNLOAD_URL"
    push_release_branch_if_needed
fi

echo ""

# ============================================
# Step 9: Appcast Item
# ============================================
echo "=== Step 9: Appcast Item ==="
echo ""
if [ "$APPCAST_ITEM_INSERTED" = true ]; then
    echo "Appcast item inserted into $APPCAST_PATH:"
elif [ "$APPCAST_ITEM_REPLACED" = true ]; then
    echo "Appcast item replaced in $APPCAST_PATH:"
elif [ "$APPCAST_ALREADY_CONTAINS" = true ]; then
    echo "Generated appcast item for v$VERSION; not inserted because $APPCAST_PATH already contains this version:"
else
    echo "Generated appcast item for v$VERSION:"
fi
echo ""
cat "$APPCAST_ITEM_PATH"

echo ""
if [ "$DRY_RUN" = "1" ]; then
    echo "Review $APPCAST_PATH, commit the release state, then run without AV_DRY_RUN."
    echo "For a race-free publish, run the real release before pushing $RELEASE_BRANCH;"
    echo "the script will push tag v$VERSION, create the GitHub release asset, then push $RELEASE_BRANCH."
elif [ "$BRANCH_PUSHED" = true ]; then
    echo "Pushed $RELEASE_BRANCH after creating the GitHub release asset; Sparkle feed can now see v$VERSION."
else
    echo "$RELEASE_BRANCH already pointed at this release commit before the GitHub release step."
fi
echo ""

# ============================================
# Step 10: Sync cask to Homebrew tap
# ============================================
# Propagate the verified local cask to the public tap.
echo "=== Step 10: Sync Cask to Homebrew Tap ==="

if [ "$CASK_PREFLIGHT_OK" != true ]; then
    echo "Skipping tap sync because cask preflight did not run."
elif [ "$TAP_SYNC_READY" != true ]; then
    echo "ERROR: tap push was not preflighted; refusing to sync tap after release."
    exit 1
elif [ "$TAP_HAS_CHANGES" != true ]; then
    echo "Tap cask already at v$VERSION — nothing to push."
elif [ "$DRY_RUN" = "1" ]; then
    echo "DRY-RUN: tap push skipped after successful dry-run preflight."
else
    GIT_SSH_COMMAND="$RELEASE_GIT_SSH_COMMAND" git -C "$TAP_CLONE_DIR" push --quiet
    echo "Pushed v$VERSION cask to https://github.com/$TAP_REPO"
    TAP_PUSHED=true
fi

echo ""

echo "=== Release Complete ==="
echo ""
echo "Files created:"
echo "  - ZIP: $ZIP_PATH"
if [ "$GITHUB_RELEASE_DONE" = true ]; then
    echo "  - GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
else
    echo "  - GitHub: skipped"
fi
if [ "$TAG_PUSHED" = true ]; then
    echo "  - Git tag: pushed v$VERSION before publishing the appcast branch"
fi
if [ "$BRANCH_PUSHED" = true ]; then
    echo "  - Branch: pushed $RELEASE_BRANCH after GitHub release creation"
fi
if [ "$APPCAST_ITEM_INSERTED" = true ]; then
    echo "  - Appcast: updated $APPCAST_PATH"
elif [ "$APPCAST_ITEM_REPLACED" = true ]; then
    echo "  - Appcast: replaced v$VERSION in $APPCAST_PATH"
elif [ "$APPCAST_ALREADY_CONTAINS" = true ]; then
    echo "  - Appcast: already contained v$VERSION"
else
    echo "  - Appcast: generated $APPCAST_ITEM_PATH"
fi
if [ "$TAP_PUSHED" = true ]; then
    echo "  - Homebrew tap: pushed v$VERSION to $TAP_REPO"
fi
