# Release Signing

Status: Accepted
Last reviewed: 2026-07-20

## Purpose

Agent Visor supports public distribution without a paid Apple Developer ID.
The release pipeline must preserve one long-lived code identity across public
updates so macOS can continue to recognize the app after its executable
changes. The target public contract uses a dedicated self-signed release
certificate; Developer ID remains the preferred future distribution mode.

Accessibility authorization follows the running code identity, not merely the
app name, bundle identifier, or enabled-looking row in System Settings. An
ad-hoc signature is tied to the app's code hash, so an updated build can require
the user to refresh Accessibility even when the previous row still looks on.

## Supported Distribution Modes

`scripts/create-release.sh` determines the mode from the exported app's actual
signature. An environment flag cannot relabel one mode as the other.

### Self-Signed Release

Self-signed release signing is the target public distribution mode after the
one-time 2.4.7 bridge.

- Every public build is signed with the same `AgentVisor Release` certificate.
- The certificate's public SHA-1 identity is pinned in the repository. The
  private key remains in the maintainer's login keychain and encrypted local
  backup; it is never committed.
- The designated requirement is anchored to the certificate leaf rather than
  the executable's changing code hash.
- GitHub Releases, Sparkle, and Homebrew distribute the same signed app bytes.
- The Homebrew cask removes quarantine but must not re-sign the app.
- Gatekeeper still treats the app as coming from an unidentified developer, so
  direct-download users may need `Open Anyway` recovery.
- The first self-signed release requires one fresh Accessibility grant because
  it intentionally changes identity from the previous ad-hoc release. Later
  releases are expected to retain that grant while the certificate remains
  unchanged.

Certificate rotation is an identity-breaking product migration. It must never
happen implicitly because losing or replacing the private key would require all
users to grant Accessibility again.

## Migration From Ad-Hoc Releases

The existing 2.4.6 updater re-signs every Sparkle replacement ad-hoc immediately
before relaunch. It would therefore erase a self-signed signature delivered
directly as the next update. Migration requires two ordered releases:

1. A one-time ad-hoc bridge release removes Sparkle's `codesign --sign -` step
   while retaining the previous Homebrew installation contract.
2. The following release adopts `AgentVisor Release`, changes Homebrew to
   preserve that signature, and declares the bridge build as its
   `sparkle:minimumUpdateVersion`.

Sparkle 2.9 then keeps older clients on the bridge path instead of allowing them
to skip directly from the re-signing updater to the self-signed release. The
bridge exception is pinned to `2.4.7` build `48` and requires the explicit
`AV_ALLOW_ADHOC_BRIDGE_RELEASE=1` publication flag. The following stable
release must declare build `48` as its minimum update version. This exception
is not a general return to ad-hoc publication.

### Migration Release Sequence

The two releases are deliberately separate commits and artifacts. Do not
publish both from one mutable release worktree.

1. Prepare `2.4.7` build `48` with the new Sparkle delegate, an ad-hoc build,
   and the historical cask postflight that removes quarantine and re-signs
   ad-hoc while preserving entitlements. Publish it only with
   `AV_ALLOW_ADHOC_BRIDGE_RELEASE=1`.
2. Verify that an installed `2.4.6` updates to `2.4.7` and relaunches. The
   bridge must remain ad-hoc; its purpose is only to stop future replacement
   signatures from being erased.
3. Prepare `2.4.8` build `49` with `AV_RELEASE_SIGN_IDENTITY="AgentVisor
   Release"` and the signature-preserving cask. Its appcast item must contain
   `<sparkle:minimumUpdateVersion>48</sparkle:minimumUpdateVersion>`.
4. Verify `2.4.7` updates to `2.4.8`, grant Accessibility once for the new
   identity, then verify a separately changed self-signed candidate has the
   same designated requirement before publishing later releases.

Before step 1, copy the encrypted P12 and its password to separate secure
locations. Keeping both only in `.release-keys/` is a local convenience, not a
recovery strategy.

### Ad-Hoc

Ad-hoc is retained for credential-free local and CI validation. The only public
exception is the pinned bridge release described above; after that release it
is not an accepted publication mode.

- `scripts/build.sh` creates an ad-hoc Release app when no Developer ID
  variables are configured.
- The app still uses Hardened Runtime and excludes debug entitlements.
- Integration tests may simulate Homebrew's former ad-hoc recovery behavior.
  `scripts/create-release.sh` refuses every ad-hoc candidate except the exact
  bridge coordinates with the explicit migration flag.
- Accessibility permission is not stable because the code requirement changes
  with the executable.

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

### Current Self-Signed Flow

```bash
scripts/release-sign-setup.sh
AV_RELEASE_SIGN_IDENTITY="AgentVisor Release" scripts/build.sh
scripts/create-release.sh
```

The setup command is a one-time maintainer action. It creates or verifies the
dedicated identity and writes an encrypted local backup outside version
control. The build verifies the configured certificate fingerprint before
signing. `create-release.sh` validates the app, cask source, final ZIP, and
Sparkle metadata before external publication.

CI continues to run `scripts/build.sh` without credentials. That produces an
ad-hoc validation artifact, not a publishable release.

### Optional Developer ID Flow

```bash
AV_RELEASE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
AV_RELEASE_TEAM_ID="TEAMID" \
scripts/build.sh

AV_NOTARY_KEYCHAIN_PROFILE="agent-visor-release" \
scripts/notarize-release.sh

scripts/create-release.sh
```

Developer ID and self-signed candidates both require a signature-preserving
cask. Their Gatekeeper and notarization requirements remain different.

## Publication Boundary

The release command always validates the candidate before creating a ZIP,
editing cask or appcast metadata, creating a tag, or uploading an asset.

- A self-signed app must match the pinned release certificate, use a
  certificate-leaf designated requirement, and have a quarantine-removing but
  signature-preserving cask.
- An ad-hoc app may be validated by local and CI tests. Publication rejects it
  except for the exact, explicit `2.4.7` build `48` migration bridge.
- A Developer ID app must have a stable signature, accepted notarization, a
  stapled ticket, and a signature-preserving cask.
- Apple Development, the `AgentVisor Dev` identity, unsigned, and unknown
  identities are not public release modes.
- Dry run does not bypass candidate validation.

## Accessibility Recovery

The running process's `AXIsProcessTrusted()` result is authoritative. The first
self-signed release is an intentional identity migration from ad-hoc signing,
so its blocked UI may need to explain one final Accessibility refresh. Ordinary
self-signed updates should then preserve the grant; a failure is a release
identity regression, not routine recovery.

Agent Visor never reads or edits the private TCC database and never resets TCC
automatically. macOS owns the grant; Agent Visor owns accurate explanation and
recovery guidance.

## Test Contract

- Pure policy tests classify ad-hoc, self-signed release, Developer ID, and
  unsupported signatures.
- Self-signed policy tests pin the exact release authority and certificate leaf.
- Ad-hoc integration tests verify candidate acceptance only with the matching
  historical quarantine and re-signing fixture. Publication rejects that mode
  unless the candidate and explicit flag match the one-time bridge coordinates.
- Appcast policy tests keep pre-bridge clients on the bridge and prevent them
  from skipping directly to a stable-signed release.
- Self-signed integration verification compares independently changed builds
  and requires different code hashes but the same designated requirement.
- Developer ID policy tests reject ad-hoc signatures and missing notarization.
- Archive tests select the same mode from the extracted app and rerun the
  appropriate distribution checks.
- Wiring audits prove candidate validation runs before publication mutations.
- CI builds and validates the supported ad-hoc Release artifact without Apple
  credentials.

## References

- [Apple TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
  describes designated requirements, self-signed identities, and Gatekeeper's
  separate trust requirements.
- [Sparkle: Publishing an update](https://sparkle-project.org/documentation/publishing/)
  defines `sparkle:minimumUpdateVersion` and its Sparkle 2.9 requirement.
- [Sparkle documentation](https://sparkle-project.org/documentation/) defines
  EdDSA-signed appcast publication and archive verification.
