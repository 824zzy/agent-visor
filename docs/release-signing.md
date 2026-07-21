# Release Signing

Status: Accepted
Last reviewed: 2026-07-20

## Purpose

Agent Visor supports public distribution without a paid Apple Developer ID.
The release pipeline must be honest about the resulting macOS tradeoffs rather
than treating Developer ID as a prerequisite.

Accessibility authorization follows the running code identity, not merely the
app name, bundle identifier, or enabled-looking row in System Settings. An
ad-hoc signature is tied to the app's code hash, so an updated build can require
the user to refresh Accessibility even when the previous row still looks on.

## Supported Distribution Modes

`scripts/create-release.sh` determines the mode from the exported app's actual
signature. An environment flag cannot relabel one mode as the other.

### Ad-Hoc

Ad-hoc is the default and currently supported public release mode.

- `scripts/build.sh` creates an ad-hoc Release app when no Developer ID
  variables are configured.
- The app still uses Hardened Runtime and excludes debug entitlements.
- GitHub Releases and Sparkle distribute the verified ad-hoc app.
- The Homebrew cask removes quarantine and re-signs the installed app while
  preserving release entitlements.
- Direct-download users may need macOS `Open Anyway` recovery.
- Accessibility permission may need to be removed and granted again after an
  update because the code requirement changed.

The candidate, archive, and cask tests must all verify this installation path
before publication.

### Developer ID

Developer ID is an optional preferred mode when the release owner later joins
the Apple Developer Program.

- The app is signed with a `Developer ID Application` identity and Team ID.
- The designated requirement is stable rather than tied to an exact code hash.
- Apple notarization is accepted and stapled before the final ZIP is created.
- GitHub Releases, Sparkle, and Homebrew distribute the same signed bytes.
- The Homebrew cask must not strip quarantine or re-sign the app.

This mode provides the cleanest Gatekeeper experience and is expected to
preserve Accessibility authorization across ordinary updates.

## Build And Release Flow

### Current Ad-Hoc Flow

```bash
scripts/build.sh
scripts/create-release.sh
```

The build output explicitly identifies itself as ad-hoc but publishable through
the matching Homebrew contract. `create-release.sh` validates the app, simulated
Homebrew re-sign, cask source, final ZIP, and Sparkle metadata before external
publication.

### Optional Developer ID Flow

```bash
AV_RELEASE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
AV_RELEASE_TEAM_ID="TEAMID" \
scripts/build.sh

AV_NOTARY_KEYCHAIN_PROFILE="agent-visor-release" \
scripts/notarize-release.sh

scripts/create-release.sh
```

Before using this mode, the cask must be changed to preserve the Developer ID
signature. Candidate validation rejects a mismatched cask in either direction.

## Publication Boundary

The release command always validates the candidate before creating a ZIP,
editing cask or appcast metadata, creating a tag, or uploading an asset.

- An ad-hoc app must have the expected ad-hoc Homebrew recovery path.
- A Developer ID app must have a stable signature, accepted notarization, a
  stapled ticket, and a signature-preserving cask.
- Apple Development, self-signed development, unsigned, and unknown identities
  are not public release modes.
- Dry run does not bypass candidate validation.

## Accessibility Recovery

The running process's `AXIsProcessTrusted()` result is authoritative. In ad-hoc
mode, blocked UI explains that an enabled-looking row may belong to the previous
build and instructs the user to remove that row, add the exact running app
again, and turn it on in Accessibility.

Agent Visor never reads or edits the private TCC database and never resets TCC
automatically. macOS owns the grant; Agent Visor owns accurate explanation and
recovery guidance.

## Test Contract

- Pure policy tests classify ad-hoc, Developer ID, and unsupported signatures.
- Ad-hoc integration tests verify candidate acceptance only with the matching
  quarantine and re-signing cask behavior.
- Developer ID policy tests reject ad-hoc signatures and missing notarization.
- Archive tests select the same mode from the extracted app and rerun the
  appropriate distribution checks.
- Wiring audits prove candidate validation runs before publication mutations.
- CI builds and validates the supported ad-hoc Release artifact without Apple
  credentials.
