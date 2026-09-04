# macOS cutover parity

The released Swift baseline was checked on 2026-08-24 against Agent Visor
2.6.1. The Electron rows were checked again for the 2.7.0 cutover on
2026-09-03. Agent Visor 2.7.0 is the first stable Electron release; the public
Swift 2.6.1 build 53 remains the exact rollback artifact during the cutover
window.

`Pass` means the Electron release matches the released behavior or uses a
verified safer route. `Partial` identifies an explicit first-release boundary
or a capability that remains provider-dependent. It is a release scope label,
not permission to claim an unverified behavior.

The 2026-08-24 source audit corrected earlier broad Pass claims. Historical
evidence remains below so later reviews can distinguish a completed check from
an intentional Electron difference.

Chat-specific behavior is tracked in [Chat feature parity](chat-feature-parity.md).
The first stable Electron release preserves the provider and read-only
boundaries described there instead of claiming pixel or control parity with
Swift. A passing focused check is evidence for that check only.

## Product surfaces

| Surface | Released behavior | Replacement evidence | Status |
| --- | --- | --- | --- |
| Sessions sections | Needs you, Ready to continue, In progress, and History | Snapshot, grouping, ordering, and renderer checks | Pass |
| Sessions search | Title, source, project, owner, and path | Ranking and exported renderer checks | Pass |
| Primary row action | Open the authoritative source | Exact provider control target, then strict owner fallback | Pass |
| Chat action | Separate action when supported | Fixed Chat column and separate pointer target | Pass |
| Keyboard use | Search, arrows, Return, Shift-Return, Command-number, Settings, Back, global pills, and scale | Pure checks, Electron checks, and Computer Use verification | Pass |
| Browser retention | Preserve search, cursor, and viewport through Chat | Mounted hidden browser and Electron check | Pass |
| Session management | Inspect, hide, and unhide Sessions rows | Owner and Chat actions work; Inspect and hidden-session controls are intentionally deferred from 2.7.0 | Partial |
| Responsive layout | Compact widths and large text | One responsive row module from 80% through 250% | Pass |
| Appearance | Released accessible Catppuccin light, dark, and system modes | Exact semantic sRGB tokens, persisted settings, and Computer Use screenshots | Pass |
| Sessions accessibility | Named Sessions controls, stable actions, and hidden retained browser content | Sessions Electron accessibility checks; Chat has its own partial parity row below | Pass |
| Chat history | Grouped turns, reasoning, tools, images, and paging | Provider parsers, bounded history, rich content, and Electron checks are shipped; provider-specific rendering remains capability-dependent | Partial |
| Chat actions | Approvals, persistent approvals, denial, questions, and provider details | Verified action identities, responses, and Details are shipped; unsupported providers remain read-only | Partial |
| Text delivery | Send to verified active providers | Daemon routes and provider/image capability checks are shipped; unverified and historical rows remain read-only | Partial |
| Image delivery | Claude, Pi, and Codex supported image routes | File-picker and local-image routes are shipped; provider-specific image support remains capability-dependent | Partial |
| Menu pills | Released active-first, 42-hour observed recent shortcuts, capsules, colors, actions, keycaps, hover inspectors, and attention order | Source-backed History is restored as dimmed recent candidates; `+N` counts omitted default-overflow-eligible navigator rows while excluding automation; the `Pill Settings...` menu remains absent | Partial |
| Menu packing | App-menu, tray, display, notch, usage, and overflow constraints | Shared packer and click-sized AppKit panels | Pass |
| Display policy | User-selected pill display and released full-screen visibility policy | Migrated display selection, screen-specific full-screen detection, all three visibility choices, intent reveal, and hidden hit testing | Pass |
| Global shortcuts | Configurable visible-session and Sessions shortcuts with modifier reveal | Signed helper registration, frozen snapshots, keycap screenshot, and footer checks | Pass |
| Usage | Codex and Claude limits with retained last valid values and click detail | Codex reading and the shared click detail popover ship; Claude usage remains intentionally absent | Partial |
| Settings | Native category layout, controls, shortcuts, integrations, and preservation | Core settings, display, full-screen, Chat visibility, and agent connections persist; hidden sessions and custom recording are intentionally omitted from 2.7.0 | Partial |
| Accessibility repair | Stable signed identity and macOS repair destination | Release-signed helper and live trusted state | Pass |
| Notifications | Native status transitions, exact session action, approval actions, and Dock badge | Modern helper notices, exact Chat clicks, exact Approve and Deny responses, resolved removal, and live badge counts | Pass |
| Updates | Public release metadata with version, URL, and signature checks plus downgrade prevention | Newer entries with valid version, HTTPS release URL, and signature metadata shape are opened at the matching GitHub release page; automatic installation remains intentionally disabled | Partial |
| Lifecycle | Close-to-hide, Dock reopen, launch at login, and quit owned processes only | Window lifecycle and owned-process shutdown checks | Pass |
| Agent integrations | Detect and install or remove hook-based integrations | Fresh profiles connect Claude Code, Auggie, and Codex; Pi connects automatically; Cursor remains read-only | Pass |
| Pi restoration | Relaunch exact eligible prior-boot Ghostty sessions | Same-boot exact navigation survives daemon restarts and atomic runtime-link checks pass; real physical-reboot acceptance is deferred from 2.7.0 | Partial |

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
| Zed-hosted agents | Zed database has title authority | Signed Zed application focus; exact thread reveal remains best effort | Read-only history | Partial |
| Auggie | Authenticated hook lifecycle | Strict owner fallback | Observe-only history, matching the released integration | Pass |

Zed documents `zed:///agent/thread/<id>` but reports that it does not select the referenced thread.

Agent Visor therefore uses verified application focus instead of claiming an exact Zed thread route.

Source: [Zed discussion 48083](https://github.com/zed-industries/zed/discussions/48083).

## Stable cutover evidence

The 2.7.0 cutover evidence covers the packaged Electron renderer, Sessions,
native services, clean-profile isolation, signed archive inspection, provider
fixtures, and the Swift helper boundary. The focused checks establish the
behaviors they exercise; they do not migrate or rewrite live provider sources.

The first release keeps the intentional boundaries in this document: provider
dependent Chat controls, read-only Cursor and Zed Chat, observe-only Auggie,
absent Claude usage, deferred Inspect and hidden-session controls, manual
update installation, and physical-reboot Pi restoration outside the verified
2.7.0 release scope.
Detailed dated test history, including prior failures and their follow-up checks,
stays in [Chat feature parity](chat-feature-parity.md).

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
- The staged metadata-clean ZIP passed the archive and signature checks. Its
  candidate hash is historical and intentionally omitted; insert the final
  public SHA-256 after the release publication dry-run.

Checks cover strict nested signatures, archive extraction, disabled application sandbox, library validation, and Homebrew ad-hoc re-signing.

The candidate designated requirement matches `/Applications/Agent Visor.app`.

The public 2.6.1 ZIP hash matches the cask and its identity matches the installed application.

## Update and rollback

The Electron updater checks the public appcast at startup and every six hours.
It accepts only a newer three-part version with a matching HTTPS GitHub release
ZIP URL and an Ed25519 signature field with the expected metadata shape. It
then opens the matching GitHub release tag. The Electron updater does not
cryptographically verify ZIP bytes before opening GitHub. Sparkle Ed25519
signing still protects published archive metadata for compatible consumers, and
the Electron app does not perform an automatic in-place install.

The release scripts still own signing, notarization, appcast publication, cask
publication, hashes, and public checks. The 2.7.0 staging change leaves the
existing appcast and cask version/hash untouched; publication must switch those
metadata surfaces together with the reviewed Electron archive.
`scripts/create-release.sh` is Electron-aware and validates, packages, and
publishes the reviewed Electron candidate in that controlled sequence.

### Mandatory publication flow

1. Build the candidate, then run `AV_RELEASE_DRY_RUN=1 scripts/create-release.sh`.
   Review the generated archive, cask, and appcast locally; the dry run skips
   remote GitHub and tap publication.
2. Review and commit the cask and appcast updates, together with the release
   notes, from the release worktree.
3. Run `scripts/create-release.sh` without the dry-run flag from that clean
   release commit. The script verifies that generated cask and appcast metadata
   match the committed files before it performs publication.

The exact rollback target is the public Swift **v2.6.1 build 53**:

1. Quit Agent Visor 2.7.0.
2. Install [Agent Visor v2.6.1](https://github.com/824zzy/agent-visor/releases/download/v2.6.1/AgentVisor-v2.6.1.zip), or the v2.6.1 cask while the public cask points to that version.
3. Move the app to `/Applications` and open it. Use macOS **Open Anyway** if the direct ZIP is blocked.
4. Grant Accessibility only if macOS asks for the exact running app.
5. Keep `~/Library/Application Support/Agent Visor` while diagnosing the cutover; the staging source at `~/Library/Application Support/Agent Visor Next` remains untouched. Do not run `brew uninstall --zap` while retaining these diagnostic profiles because zap removes the application data paths. Remove either profile only after the rollback issue is understood.

The cutover copies only the Agent Visor staging profile into the production
Electron profile. The raw migrated Swift property list remains in the private
settings file. Provider transcripts, databases, hooks, and live session records
are outside this operation and are always read in place. A live staging profile
makes import wait; its source remains untouched and transient Electron lock
markers are omitted from the copied profile.

Physical-reboot Pi restoration is deferred from the 2.7.0 acceptance matrix.
Its design and remaining real-machine test stay documented in
[Pi Integration](pi-integration.md#reboot-restoration).

The historical, superseded source audit is retained outside the repository for
provenance only. It predates this contract and must not be used as current
parity or release evidence.

## Legacy Swift retention

Retain the signed Swift v2.6.1 application and its public download while the
2.7.0 cutover rollback window is open. Remove the rollback artifact only after
the stable Electron release has completed its approved rollback review.
