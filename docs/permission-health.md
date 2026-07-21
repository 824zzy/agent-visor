# Permission Health

Status: Accepted
Last reviewed: 2026-07-20

## Purpose

Agent Visor depends on macOS permissions for global shortcuts, terminal targeting,
menu-bar geometry, and transcript discovery. The product must explain blocked
capabilities without asking users to diagnose TCC entries, choose among app
copies, or repeatedly relaunch the app.

Permission health is a capability contract, not a mirror of the switches shown
in System Settings. A macOS switch may be enabled while the running Agent Visor
binary is still untrusted or while a dependent capability remains unavailable.

## Principles

1. **Verify the running app.** Agent Visor checks the process that is currently
   running. Users are never asked to identify a build by name alone.
2. **Explain only real blockers.** A missing permission and a degraded
   capability are different states with different recovery copy.
3. **Prompt only from an explicit action.** Agent Visor explains why access is
   needed before asking macOS. The native request is issued when the user clicks
   `Enable Accessibility` or the menu-bar `Setup` item, never speculatively
   before the main window is visible.
4. **Recover without relaunch.** When trust becomes available, Agent Visor
   reinstalls permission-dependent monitors and reprobes menu geometry.
5. **Disappear when healthy.** Permission UI is absent after verification
   succeeds. Settings retains the durable health summary.
6. **Honest release identity.** Public releases use one bundle identifier and
   `/Applications/Agent Visor.app` install path. Version 2.4.7 is the one-time
   ad-hoc bridge; 2.4.8 adopts the pinned self-signed release certificate. That
   migration can require a fresh grant; subsequent releases must preserve the
   signed identity. Optional Developer ID mode remains the preferred future
   path. Both contracts are defined in [Release Signing](release-signing.md).
7. **Stable development location.** The development workflow builds in
   DerivedData but deploys and launches `/Applications/Agent Visor Dev.app`.
   Permission UI never asks a developer to browse hidden `/tmp` build output.

## Accessibility States

| State | Meaning | User-facing treatment |
| --- | --- | --- |
| `Needs Accessibility` | `AXIsProcessTrusted()` is false for the running app | Amber setup indicator and direct System Settings action |
| `Verifying` | Trust is true and the functional probe has not completed | Quiet progress treatment |
| `Needs Repair` | Trust is true, but Agent Visor cannot read a known app menu through AX | Amber repair treatment with the installed app path |
| `Ready` | Trust and the functional AX probe both succeed | No setup indicator |

The functional probe reads a menu-bar element from a known regular application.
It does not use Agent Visor's menu-layout result because screen ownership,
full-screen transitions, and app-specific menu behavior can make layout evidence
temporarily unavailable even when Accessibility is healthy.

## Surfaces

### Menu-Bar Setup Indicator

- A compact `Setup` status item appears only for `Needs Accessibility` or
  `Needs Repair`.
- It is a native `NSStatusItem`, so it remains reachable when the custom pill
  strip cannot determine left-side geometry.
- For `Needs Accessibility`, clicking it brings the Agent Visor permission
  explanation forward and issues the native macOS Accessibility request.
- For `Needs Repair`, clicking it opens macOS Accessibility settings directly.
- VoiceOver's accessible session status item remains available. Permission
  health takes visual priority when both are needed.
- `Verifying` does not create a flashing or persistent menu-bar item.

### Main Window

- The Agent Sessions header shows a compact permission banner for every
  non-ready state.
- `Needs Accessibility` explains that global shortcuts and terminal targeting
  are unavailable, names the running app path, and offers `Enable
  Accessibility`. It also explains that an enabled-looking row can refer to a
  previous installed build and tells the user to remove that row, add the
  exact running app again, and turn it on.
- The native prompt is the primary action. `Open Accessibility Settings` and
  `Reveal This App` remain visible fallbacks because macOS may remember a prior
  denial or decline to show another prompt.
- `Verifying` shows progress without asking for another action.
- `Needs Repair` states that macOS reports permission but functional control
  could not be verified. It names the running app path and offers the same
  direct settings action.
- The banner never replaces search, session results, or shortcut education.

### Settings

- The General permission row uses the same shared health state as the banner and
  status item.
- `Ready` renders `Granted`.
- `Verifying` renders `Verifying`.
- `Needs Accessibility` provides the same `Enable Accessibility` primary
  action and explicit settings/reveal fallbacks as the main window.
- `Needs Repair` provides `Open System Settings...`.
- Returning from System Settings refreshes health immediately.

## Setup Request Flow

Agent Visor cannot add or enable itself in macOS Accessibility. TCC requires the
user to approve the running code identity. The product owns the explanation and
recovery flow; macOS owns the grant.

1. On launch, Agent Visor checks trust without prompting.
2. If untrusted, the main window renders the permission explanation after it is
   visible and active.
3. An explicit `Enable Accessibility` or menu-bar `Setup` click activates Agent
   Visor and calls `AXIsProcessTrustedWithOptions` with
   `kAXTrustedCheckOptionPrompt`.
4. The request is never suppressed by an app-local “already requested” flag.
   Only `AXIsProcessTrusted()` determines whether setup is complete.
5. If macOS does not present a native request, the user can open the exact
   Accessibility pane or reveal the stable running app bundle for the pane's
   `+` chooser.
6. The monitor keeps polling while blocked. Granting access transitions through
   `Verifying` to `Ready`, removes setup UI, and rearms permission-dependent
   behavior without relaunching.

Prompting is asynchronous. Issuing a request does not imply that macOS displayed
it, that the app was added to the list, or that the user granted access.

## Lifecycle

1. AppDelegate starts the permission-health monitor before installing
   Accessibility-dependent event monitors.
2. The monitor checks trust at launch, whenever Agent Visor becomes active, and
   periodically while health is not ready.
3. Launch checks never issue or remember a native prompt. Explicit setup
   actions own prompting.
4. A trusted process runs the functional probe off the main thread.
5. A transition from a blocked state to `Ready` posts one permission-recovered
   event.
6. Hotkey monitoring removes and reinstalls its global/local event monitors on
   that event.
7. The menu-layout coordinator reprobes immediately on that event. Its existing
   periodic probe remains a fallback.

Repeated refreshes while already ready do not reinstall monitors or reset
gesture state.

## Installation Identity

The release experience assumes `/Applications/Agent Visor.app`. Development
artifacts use a separate identity:

| Artifact | Release | Development |
| --- | --- | --- |
| App name | `Agent Visor` | `Agent Visor Dev` |
| Bundle | `Agent Visor.app` | `Agent Visor Dev.app` |
| Running path | `/Applications/Agent Visor.app` | `/Applications/Agent Visor Dev.app` |
| Bundle identifier | `com.824zzy.AgentVisor` | `com.824zzy.AgentVisor.Dev` |
| Icon | Production icon | Production icon with a visible `DEV` badge |
| Runtime helper | Not distributed | `AgentVisorDevCodexRuntime` |

This is not a cosmetic suffix. Accessibility authorization follows the running
app's code identity, so Debug must not reuse the release bundle identifier.
Permission UI names the exact visible row and running bundle path, allowing
developers to grant `Agent Visor Dev` without guessing which `Agent Visor`
entry macOS represents.

`scripts/dev-build.sh` treats the Xcode build product as an intermediate
artifact. It stops the previous development process, replaces the stable app in
`/Applications`, registers that copy with LaunchServices, and launches it.
`AV_DEV_INSTALL_DIR` may override the destination on a machine where
`/Applications` is not writable, but the selected directory must remain stable
across rebuilds. The transient DerivedData or `/tmp` app must never be launched
or added to Accessibility.

Release and development variants are not designed to run simultaneously.
Development work should stop the installed release before launching Debug; the
shared session hooks and menu-bar ownership remain single-owner resources.

Version 2.4.7 remains ad-hoc only as the updater bridge. Starting with 2.4.8,
public releases use the dedicated `AgentVisor Release` self-signed certificate.
Homebrew then removes quarantine but preserves that distributed signature. The
first release using this identity can invalidate the previous ad-hoc TCC grant;
ordinary later updates should not. The UI must still use the running process's
`AXIsProcessTrusted()` result as authoritative and provide recovery when macOS
reports otherwise.

An optional Developer ID and notarization mode is also supported by the release
pipeline. When used, Homebrew must preserve the distributed signature instead
of replacing it. The two modes and their validation rules are defined in
[Release Signing](release-signing.md).

## Non-Goals

- Reading or modifying the private TCC database.
- Determining which visually identical row System Settings currently displays.
- Treating every transient menu-layout probe failure as a permission failure.
- Keeping a permanent warning in the menu bar after health is ready.
- Automatically resetting TCC on every launch or build change.

## Test Contract

- Pure Core tests cover every state transition and presentation.
- Pure Core tests cover the setup action contract: untrusted requests access,
  repair opens settings, and ready/verifying do nothing.
- App wiring tests verify launch monitoring, active-app refresh, monitor rearm,
  immediate menu reprobe, main-window banner, explicit native request, fallback
  actions, and setup status-item behavior.
- Existing global shortcut, menu layout, VoiceOver status-item, and Settings
  behavior remain covered.
- Build audits require distinct Debug and Release names, identifiers, icons,
  bundle paths, and Debug runtime-helper identities.
- Manual verification includes first denial, grant while running, repair copy,
  normal ready launch, distinct Debug and Release Accessibility rows,
  VoiceOver, and a release installed in `/Applications`.

## Change Control

Changes to permission-state meaning, blocking behavior, or automatic recovery
require updating this document before implementation.
