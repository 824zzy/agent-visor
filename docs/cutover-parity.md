# macOS cutover parity

Checked on 2026-08-24 against released Agent Visor 2.6.1.

`Pass` means the replacement matches the released behavior or uses a verified safer route.

The 2026-08-24 source audit corrected earlier broad Pass claims. `Partial` names a working subset with released behavior still missing.

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
| Accessibility | Named controls, stable actions, and hidden retained content | Electron accessibility checks | Pass |
| Chat history | Grouped turns, reasoning, tools, images, and paging | Provider parsers and Chat Electron check | Pass |
| Chat actions | Approvals, persistent approvals, denial, questions, and provider controls | Authenticated Claude hook response checks; permission, model, context, and visibility controls remain absent | Partial |
| Text delivery | Send to verified active providers | Exact terminal routes and Codex app-server route | Pass |
| Image delivery | Claude, Pi, and Codex supported image routes | Private path paste, path prompt, and local-image input | Pass |
| Menu pills | Released capsules, colors, actions, keycaps, hover inspectors, and attention order | Core capsules match; the searchable `+N` navigator and `Pill Settings...` menu remain absent | Partial |
| Menu packing | App-menu, tray, display, notch, usage, and overflow constraints | Shared packer and click-sized AppKit panels | Pass |
| Display policy | User-selected pill display and released full-screen visibility policy | Helper follows the status-item screen and always joins full-screen spaces | Partial |
| Global shortcuts | Configurable visible-session and Sessions shortcuts with modifier reveal | Signed helper registration, frozen snapshots, keycap screenshot, and footer checks | Pass |
| Usage | Codex and Claude limits with retained last valid values and click detail | Codex reading works; Claude usage and the click detail popover remain absent | Partial |
| Settings | Native category layout, controls, shortcuts, integrations, and preservation | Core settings and agent connections persist; display, full-screen, hidden sessions, Chat visibility, and custom recording remain absent | Partial |
| Accessibility repair | Stable signed identity and macOS repair destination | Release-signed helper and live trusted state | Pass |
| Notifications | Native status transitions, exact session action, approval actions, and Dock badge | Phase notices work; clicks open only the owner application and interactive actions remain absent | Partial |
| Updates | Signed public release with downgrade prevention | Validated appcast and manual verified release link; automatic installation remains intentionally disabled | Partial |
| Lifecycle | Close-to-hide, Dock reopen, launch at login, and quit owned processes only | Window lifecycle and owned-process shutdown checks | Pass |
| Agent integrations | Detect and install or remove hook-based integrations | Fresh profiles connect Claude Code, Auggie, and Codex; Pi connects automatically; Cursor remains read-only | Pass |
| Pi restoration | Relaunch exact eligible prior-boot Ghostty sessions | No Electron restoration coordinator exists | Missing |

## Provider matrix

| Provider and host | Discovery and history | Source action | Chat behavior | Status |
| --- | --- | --- | --- | --- |
| Claude Code in Ghostty | Provider metadata and transcript | Exact TTY marker focus | Text, images, approvals, and questions | Pass |
| Claude Code in iTerm2 | Provider metadata and transcript | Exact TTY selection | Text, images, approvals, and questions | Pass |
| Claude Code in Terminal | Provider metadata and transcript | Exact TTY selection | Text, approvals, and questions | Pass |
| Claude Code in Cursor | Claude metadata remains authoritative | Signed Cursor application focus | Read-only history and hook responses | Pass |
| Codex CLI | SQLite and rollout history | Exact terminal focus | App-server text and local images | Pass |
| Codex application | SQLite and recent rollout history | `codex://threads/<id>` | App-server text and local images | Pass |
| Pi in supported terminals | Incremental transcript scan and validated runtime hook link | Exact TTY focus | Text and ordered local-image paths | Pass |
| Historical Pi | Bounded history | No invented active target | Read-only history | Pass |
| Cursor CLI in a terminal | Cursor-owned transcript parser | Exact TTY focus | Read-only history | Pass |
| Historical Cursor | Bounded history | Strict Cursor application fallback | Read-only history | Pass |
| Zed-hosted agents | Zed database has title authority | Signed Zed application focus without the released verified thread reveal | Read-only history | Partial |
| Auggie | Authenticated hook lifecycle | Strict owner fallback | Observe-only, matching the released integration | Pass |

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

The detailed source audit is stored at `/Users/zhengyuanz/Codes/.scratch/agent-visor-electron-parity-audit/report.md`.

## Removal decision

Do not remove the Swift production application in this change.

Remove it only after one approved Electron production release succeeds and its rollback window closes.
