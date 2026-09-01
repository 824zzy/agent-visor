# macOS cutover parity

The released Swift baseline was checked on 2026-08-24 against Agent Visor
2.6.1. Electron migration rows were checked separately on 2026-08-27 in the
local migration worktree; they are not production-release evidence.

`Pass` means the replacement matches the released behavior or uses a verified safer route.

The 2026-08-24 source audit corrected earlier broad Pass claims. `Partial` names a working subset with released behavior still missing.

Chat-specific behavior is tracked in [Chat feature parity](chat-feature-parity.md).
The Chat rows below stay `Partial` until the Electron surface matches the
Swift composer, streaming, rich-content, action, status, and accessibility
contracts. A passing focused check is evidence for that check only.

## Product surfaces

| Surface | Released behavior | Replacement evidence | Status |
| --- | --- | --- | --- |
| Sessions sections | Needs you, Ready to continue, In progress, and History | Snapshot, grouping, ordering, and renderer checks | Pass |
| Sessions search | Title, source, project, owner, and path | Ranking and exported renderer checks | Pass |
| Primary row action | Open the authoritative source | Exact provider control target, then strict owner fallback | Pass |
| Chat action | Separate action when supported | Fixed Chat column and separate pointer target | Pass |
| Keyboard use | Search, arrows, Return, Shift-Return, Command-number, Settings, Back, global pills, and scale | Pure checks, Electron checks, and Computer Use verification | Pass |
| Browser retention | Preserve search, cursor, and viewport through Chat | Mounted hidden browser and Electron check | Pass |
| Session management | Inspect, hide, and unhide Sessions rows | Owner and Chat actions work; Inspect and hidden-session controls remain absent | Partial |
| Responsive layout | Compact widths and large text | One responsive row module from 80% through 250% | Pass |
| Appearance | Released accessible Catppuccin light, dark, and system modes | Exact semantic sRGB tokens, persisted settings, and Computer Use screenshots | Pass |
| Sessions accessibility | Named Sessions controls, stable actions, and hidden retained browser content | Sessions Electron accessibility checks; Chat has its own partial parity row below | Pass |
| Chat history | Grouped turns, reasoning, tools, images, and paging | Provider parsers and bounded Chat Electron check; full Swift rich rendering and streaming behavior remain | Partial |
| Chat actions | Approvals, persistent approvals, denial, questions, and provider details | Basic Electron responses and details; Swift composer, cancellation, and provider-specific controls remain | Partial |
| Text delivery | Send to verified active providers | Daemon routes are present; Swift composer keyboard, draft, failure, and cancel behavior remains | Partial |
| Image delivery | Claude, Pi, and Codex supported image routes | Basic file-picker and local-image routes are present; Swift paste, removal, and draft behavior remains | Partial |
| Menu pills | Released active-first, 42-hour observed recent shortcuts, capsules, colors, actions, keycaps, hover inspectors, and attention order | Source-backed History is restored as dimmed recent candidates; `+N` counts omitted default-overflow-eligible navigator rows while excluding automation; the `Pill Settings...` menu remains absent | Partial |
| Menu packing | App-menu, tray, display, notch, usage, and overflow constraints | Shared packer and click-sized AppKit panels | Pass |
| Display policy | User-selected pill display and released full-screen visibility policy | Migrated display selection, screen-specific full-screen detection, all three visibility choices, intent reveal, and hidden hit testing | Pass |
| Global shortcuts | Configurable visible-session and Sessions shortcuts with modifier reveal | Signed helper registration, frozen snapshots, keycap screenshot, and footer checks | Pass |
| Usage | Codex and Claude limits with retained last valid values and click detail | Codex reading and the shared click detail popover work; Claude usage remains absent | Partial |
| Settings | Native category layout, controls, shortcuts, integrations, and preservation | Core settings, display, full-screen, Chat visibility, and agent connections persist; hidden sessions and custom recording are intentionally omitted | Partial |
| Accessibility repair | Stable signed identity and macOS repair destination | Release-signed helper and live trusted state | Pass |
| Notifications | Native status transitions, exact session action, approval actions, and Dock badge | Modern helper notices, exact Chat clicks, exact Approve and Deny responses, resolved removal, and live badge counts | Pass |
| Updates | Signed public release with downgrade prevention | Validated appcast and manual verified release link; automatic installation remains intentionally disabled | Partial |
| Lifecycle | Close-to-hide, Dock reopen, launch at login, and quit owned processes only | Window lifecycle and owned-process shutdown checks | Pass |
| Agent integrations | Detect and install or remove hook-based integrations | Fresh profiles connect Claude Code, Auggie, and Codex; Pi connects automatically; Cursor remains read-only | Pass |
| Pi restoration | Relaunch exact eligible prior-boot Ghostty sessions | Same-boot exact navigation survives daemon restarts. Atomic prior-boot restoration passes automated checks; a physical reboot remains | Partial |

## Provider matrix

| Provider and host | Discovery and history | Source action | Chat behavior | Status |
| --- | --- | --- | --- | --- |
| Claude Code in Ghostty | Provider metadata and transcript | Exact TTY marker focus | Basic text, images, approvals, and questions | Partial |
| Claude Code in iTerm2 | Provider metadata and transcript | Exact TTY selection | Basic text, images, approvals, and questions | Partial |
| Claude Code in Terminal | Provider metadata and transcript | Exact TTY selection | Basic text, approvals, and questions | Partial |
| Claude Code in Cursor | Claude metadata remains authoritative | Signed Cursor application focus | Basic read-only history and hook responses | Partial |
| Codex CLI | SQLite and rollout history | Exact terminal focus | Basic app-server text and local images | Partial |
| Codex application | SQLite and recent rollout history | `codex://threads/<id>` | Basic app-server text and local images | Partial |
| Headless Codex job | Hook and rollout history | `codex://threads/<id>` | Read-only history | Partial |
| Pi in supported terminals | Incremental transcript scan and validated runtime hook link | Exact TTY focus | Basic text and ordered local-image paths | Partial |
| Historical Pi | Bounded history | No invented active target | Read-only history | Partial |
| Cursor CLI in a terminal | Cursor-owned transcript parser | Exact TTY focus | Basic read-only history | Partial |
| Historical Cursor | Bounded history | Strict Cursor application fallback | Basic read-only history | Partial |
| Zed-hosted agents | Zed database has title authority | Signed Zed application focus without the released verified thread reveal | Read-only history | Partial |
| Auggie | Authenticated hook lifecycle | Strict owner fallback | Observe-only history, matching the released integration | Pass |

Zed documents `zed:///agent/thread/<id>` but reports that it does not select the referenced thread.

Agent Visor therefore uses verified application focus instead of claiming an exact Zed thread route.

Source: [Zed discussion 48083](https://github.com/zed-industries/zed/discussions/48083).

## Clean profile

`npm run test:clean-profile` uses a temporary home, application data directory, hook socket, and Electron user profile.

It verifies:

- No provider rows appear without provider data.
- Typed defaults load without legacy data.
- Settings use mode `0600`.
- The local authenticated protocol returns Sessions and native-service state.
- The exported renderer opens with complete accessibility labels.
- Shutdown removes owned sockets and processes.

A separately signed archive also opened from a temporary profile and showed Sessions and Settings through its packaged file renderer.

A live resumed Pi session used its hook PID and TTY to recover Ghostty `ttys020`. A normal capsule click selected that exact terminal.

The test started from a different Ghostty terminal. Option-click opened the same session in Agent Visor Chat, preserving the explicit secondary action.

## Archive and public identity

The candidate packager uses the installed Electron runtime and no packaging dependency.

It includes only compiled application files, `ws`, `zod`, the protocol package, and the release-signed native helper.

The candidate uses:

- Bundle identifier `com.824zzy.AgentVisor`.
- Existing `AgentVisor Release` certificate.
- Version 2.7.0 and build 54 by default.
- Hardened runtime entitlements required by Electron.
- A metadata-clean ZIP with SHA-256 `3cb9228b35e213b67e8e8abd3eb1406614470c65e253d42a3a8ac2e30a39f50f`.

Checks cover strict nested signatures, archive extraction, disabled application sandbox, library validation, and Homebrew ad-hoc re-signing.

The candidate designated requirement matches `/Applications/Agent Visor.app`.

The public 2.6.1 ZIP hash matches the cask and its identity matches the installed application.

## Update and rollback

The replacement opens only a newer, signed, public Agent Visor release entry.

It does not perform an automatic in-place install.

The existing release scripts still own signing, notarization, appcast publication, cask publication, hashes, and public checks.

No release script, appcast, or cask points to the Electron candidate yet.

Rollback remains the public Swift release:

1. Quit the Electron release.
2. Install the previous public cask or verified public ZIP.
3. Start the Swift application with the same signing identity.
4. Keep `Agent Visor Next/settings.json` for diagnosis or remove it after rollback approval.

The raw migrated Swift property list remains in the private settings file. It does not mean every released control or behavior is implemented.

The [historical, superseded source audit](/Users/zhengyuanz/Codes/.scratch/agent-visor-electron-parity-audit/report.md)
is retained for provenance only. It predates this contract and must not be
used as current parity or release evidence.

## Removal decision

Do not remove the Swift production application in this change.

Remove it only after one approved Electron production release succeeds and its rollback window closes.
