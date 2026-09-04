# React Native and Electron migration

Agent Visor 2.7.0 is the first stable Electron cutover. The product uses an
Expo renderer, Electron desktop shell, local TypeScript daemon, and signed
Swift helper for macOS-only operations.

The public Swift 2.6.1 application remains the exact rollback target during the
cutover window. This document keeps the migration record and names the
intentional differences that remain in the first Electron release.

## 2.7.0 cutover boundary

Electron owns the normal user-facing window, Sessions browser, Chat, Settings,
menu-bar coordination, updates, notifications, and daemon lifecycle. The
signed Swift helper continues to own Accessibility checks, native menu panels,
global shortcuts, display topology, notifications, Dock badges, and exact
owner focus.

The cutover migrates the Agent Visor profile only. Provider transcripts, SQLite
databases, hooks, and session records are outside this operation and are always
read in place. Only the staging Electron profile at
`~/Library/Application Support/Agent Visor Next` is copied into the production
profile at `~/Library/Application Support/Agent Visor`, and only when the
staging source is not live. A live staging profile makes import wait; its
source remains untouched and transient Electron lock markers are omitted from
the copied profile.

The first stable release intentionally omits Swift-only Inspect, hide/unhide,
and custom-recording controls. Claude usage is omitted without an
authoritative credential route. Cursor and Zed Chat are read-only, Auggie is
observe-only, and same-boot Pi recovery is verified. Restoration after an
actual macOS reboot remains a required pre-release acceptance item documented
in [macOS cutover parity](cutover-parity.md).

## First stack slice

Requirements:

- Node 22
- npm 11.6.2

Install and run:

```sh
npx npm@11.6.2 ci
npm run dev:desktop
```

The initial slice proved the local path with fixture sessions. The stable
daemon now reads supported live providers and streams stable session revisions.
Its behavior is defined in [Live session daemon](live-session-daemon.md).

The Electron candidate is built with <code>scripts/package-electron.sh</code>
after the workspace build. <code>scripts/create-release.sh</code> is
Electron-aware: it packages the reviewed Electron app, signs the archive for
the Sparkle appcast, updates release metadata, and publishes the GitHub asset,
cask, and appcast in its controlled sequence. This migration document does not
change the appcast, cask version, or published hash.

## Sessions browser

The Expo renderer supplies the stable Electron browser’s state sections, ranked
search, keyboard cursor, source-first rows, and separate Chat actions.

Rows keep fixed owner and Chat columns at desktop and compact widths. Back retains the query, cursor, and viewport because Sessions stays mounted and hidden.

Electron activates only known owner applications. Provider-owned targets add exact TTY and Codex thread focus without exposing target metadata to the renderer.

Run the Electron accessibility and layout check with:

```sh
npm run test:sessions
```

Chat renders a bounded baseline of provider-owned history, grouped work, tool
details, images, pagination, approvals, questions, and technical Details. The
first stable Electron release deliberately keeps a smaller contract than the
Swift application: provider-gated sending, read-only history, and the omitted
Inspect, hidden-session, and custom-recording controls are intentional. The
full contract and evidence are tracked in [Chat feature parity](chat-feature-parity.md).

The daemon contract is defined in [Chat daemon](chat-daemon.md). Verified
Claude Code, Codex, and Pi routes provide text and image delivery. Cursor and
Zed-hosted Chat remain read-only, Auggie remains observe-only, and Claude usage
remains absent without a provider-authoritative credential route.

## Dependency status

`npm audit --omit=dev` reports no production dependency vulnerabilities.

The complete development audit reports ten moderate advisories through Expo’s unused iOS configuration path.

The renderer uses Expo 57 for web only. Keep the development-only advisories
out of the production archive and review them again when dependencies change.

## Rollback and evidence

The rollback artifact is the public Swift Agent Visor v2.6.1 build 53. To
rollback, quit the Electron application, install the verified
[v2.6.1 ZIP](https://github.com/824zzy/agent-visor/releases/download/v2.6.1/AgentVisor-v2.6.1.zip), and launch the Swift application from
<code>/Applications</code>. Keep the production Electron profile at
`~/Library/Application Support/Agent Visor` while diagnosing the cutover; the
staging source at `~/Library/Application Support/Agent Visor Next` remains
untouched. Do not run `brew uninstall --zap` while retaining diagnostic profiles,
because zap removes the application data paths. Provider-owned live sources
remain in place.

Current evidence is recorded in [macOS cutover parity](cutover-parity.md) and
[Chat feature parity](chat-feature-parity.md). It includes clean-profile,
Sessions, native-service, exported-renderer, signed-archive, and provider
fixture checks. Fixture and clean-profile evidence does not claim that every
Swift-only control exists in Electron. Provider-owned live sources are always
read in place and are outside the profile migration.

Physical-reboot Pi restoration remains a required pre-release acceptance item.
This document does not mark physical-reboot behavior as shipped. Remove this
provisional note only after the physical-reboot gate passes.

## Packages

- `packages/protocol`: Zod wire schemas and shared TypeScript types.
- `packages/server`: live provider state, hook intake, and local WebSocket delivery.
- `packages/app`: Expo and React Native Web Sessions renderer.
- `packages/desktop`: Electron lifecycle and daemon startup.

## Native helper

A narrow signed Swift helper keeps Accessibility, native menu items, global session shortcuts, and exact focus operations.

Its socket, validation, and signing contract is defined in [Native macOS helper](native-helper.md).

Its menu behavior and daemon action route are defined in [Native menu bar](native-menu.md).

Settings migration, permissions, notifications, updates, and shutdown behavior are defined in [Native services](native-services.md).

The production decision and provider matrix are defined in [macOS cutover parity](cutover-parity.md).

Paseo source informed the system shape, but no Paseo source code is included.
