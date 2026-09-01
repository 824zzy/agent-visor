# Chat feature parity

Status: Phases 4 through 8—streaming-aware tail pinning, bounded paging,
virtualized rendering, rich content, approvals/questions, provider-aware
status and modes, and read-only/accessibility/theme/scale behavior—remain
implemented and verified as of 2026-08-29. The approved 2026-08-31 composer
enclosure implementation is present on `migration/react-native-electron-macos`,
and scoped composer verification passes. Three bounded source-review fixes—
permission capability, pending Stop visibility, and typography remeasurement—
have regression coverage, and the scoped composer checks now pass. The overall
verification gate remains blocked by current failures in the full npm test and
full Chat E2E runs. The full scrolling Chat E2E caveat remains unresolved, so
this document does not claim a final pass for the composer change.

This document is the behavior contract for the Electron Chat migration. The
approved target is parity with the released Swift Chat behavior. Electron may
use React Native Web and Electron-native controls, but a different
implementation must preserve the same user-visible result, interaction, and
provider capability rules. Pixel identity is not required.

The Swift implementation is the source of truth:

- `AgentVisor/UI/Window/SessionWorkspaceDetail.swift` and
  `AgentVisor/UI/Window/ChatViewHost.swift` own the Chat destination and its
  window-level lifecycle.
- `AgentVisor/UI/Window/WindowChatView.swift` owns the window conversation,
  paging, streaming updates, turn rows, and provider-gated interactive
  surfaces.
- `AgentVisor/UI/Window/ChatTableView.swift` owns the AppKit row table,
  visible-row layout, expansion, and scroll/tail coordination.
- `AgentVisor/UI/Window/WindowComposer.swift` owns drafts, focus, keyboard
  input, line growth, slash commands, image paste, send, and cancel.
- `AgentVisor/UI/Components/ChatStatusBar.swift` owns model, effort, context,
  usage, project, and Claude-only permission mode presentation.
- `AgentVisor/UI/Components/MarkdownRenderer.swift`,
  `AgentVisor/UI/Views/ChatView.swift`, and
  `AgentVisor/UI/Views/ToolResultViews.swift` own rich message, tool, image,
  plan, edit, approval, and question presentation.
- `AgentVisorCore` owns the pure policies used by those views, including
  pagination, tail pinning, pending echoes, visibility, composer sizing,
  provider permission, and question input.

## Contract

| Surface | Swift behavior that Electron must match | Current Electron baseline |
| --- | --- | --- |
| Shell and rail | Chat replaces the browser in the same window. Header, conversation, composer, and status content use one centered rail with the established maximum width. | Shared rail alignment is implemented. Other header and footer details remain under review. |
| Transcript | Provider parsers retain canonical text and images. Chat is lazy, bounded, and read-only when control metadata is not verified. | Claude Code, Codex, Pi, and Cursor pages render through the daemon with canonical provider text preserved and provider-neutral presentation transforms. |
| Turn presentation | User prompts, assistant answers, thinking, tools, system rows, durations, recaps, compact boundaries, and provider grouping follow the visibility rules. | Turn grouping, thinking/tool/system rows, durations, recaps, compact boundaries, and provider-neutral rich presentation are implemented and covered by pure and Electron checks. |
| Composer state | Draft and attachments are per session. Focus, multiline growth, Enter/Shift-Enter, Escape, slash completion, paste, and removal follow the Swift interaction contract. | The current pass uses one rounded enclosure for attachment previews, the multiline textarea, and the bottom toolbar. The enclosure shares the Chat and Sessions canvas fill and relies on its border for separation. Add image and Send expose 44 px targets; Send's visible face is 32 px. Model/effort and truthful permission context stay near the draft, while context/usage/provider/path diagnostics remain in Details. Text and image capabilities remain independent, with eight-line measured growth and internal scrolling. Scoped composer checks pass; the overall gate remains blocked. |
| Send and cancel | Sends use the provider route, show an optimistic echo, reconcile or remove it safely, restore canceled input, and report failures. | The daemon re-checks the live working section and provider/image capabilities before every send. The shared action area keeps Send and Stop capability-correct: Stop requires an identity-bound active cancellable delivery, can occupy the primary position with no sendable draft, and remains beside Send when both are legitimate. Repeat cancellation is disabled and drafts remain recoverable. Scoped composer checks pass; the overall gate remains blocked. |
| Scrolling and scale | Initial history is bounded. Streaming follows the tail only when the user is near it. Loading earlier rows preserves the reading position. Content scale does not create horizontal overflow. | The daemon requests an initial 100 rows. Turn-aligned pages may exceed that request up to the protocol cap. The client keeps at most 4,000 retained rows and shows a visible history-limit status. FlatList renders grouped turns as virtualized cells. The exact 80 px near-tail policy preserves far-reader position, while local sends always pin and composer resize pins only near the tail. Earlier paging is single-flight with a stable anchor, and a latest no-overlap response inserts one visible history-gap row. Tail frames are session-scoped and canceled on session change or unmount. |
| Rich content | Markdown includes block structure, links, code, tables, emphasis, strike-through, syntax highlighting, LaTeX, images, tools, plans, and edit hunks. | Provider-neutral block/inline Markdown, safe links, bounded syntax-token presentation, MathML with literal fallback, tables, images/placeholders, tools, plans, edit hunks, and thinking/recap rows are implemented without rewriting canonical text. |
| Approvals and questions | Controls show provider context, validate answers, support keyboard use and cancellation, and send the exact provider response. | Exact action identity, provider context, validation, multiple choice/text answers, disabled/responding state, keyboard actions, Escape cancellation, and exact provider responses are implemented. |
| Status and modes | The footer shows resolved model and effort, context and usage, project, and provider-gated permission modes. | Model/effort and provider-truthful permission context now sit beside the draft in the composer; context/usage/provider/path diagnostics remain in Details. No fake model selector is introduced. Existing provider-aware usage and Claude permission action seams remain in force. |
| Accessibility and read-only | Labels, focus order, keyboard actions, state announcements, theme, scaling, and ended-session behavior remain usable and truthful. | Chat labels, focus order, live state announcements, keyboard actions, read-only/ended controls, light/dark palette, 250% scaling, and no-overflow rail geometry remain in scope. Read-only shows one reason and the supported source action without a dead composer shell; text and image capability gates stay independent. Scoped visual/state checks pass; the overall gate remains blocked. |
| Large history | The renderer uses bounded visible rows and safe pagination without freezing during stream updates or repeated expansion. | Initial daemon requests use 100 rows, with turn alignment allowed to return a larger page up to the protocol cap. Earlier requests are single-flight and preserve the reader's anchor. The client retains at most 4,000 rows, reports when that limit is reached, and uses FlatList virtualization, including flattened cells for grouped turns. Replayed or out-of-order earlier responses are rejected, and a latest page with no overlap does not erase loaded history. |

The Electron baseline does not normalize, reflow, or rewrite provider text.
Provider parsers remain the canonical source for transcript text and images.
Presentation-only Markdown or rich-content transforms must be
provider-neutral, must preserve that canonical content, and need a separate
approved contract before they can be called parity.

## Implementation order

1. Keep this contract and the public test seams current.
2. [Complete] Add per-session composer state, focus, keyboard submission,
   growth, slash completion, and attachment management.
3. [Complete] Add provider-honest cancellation, failed-send handling, and
   reliable optimistic echo reconciliation.
4. [Complete] Add streaming-aware tail pinning and a virtualized, bounded
   conversation list.
5. [Complete] Add Swift-equivalent Markdown, image, tool, plan, edit, and turn
   presentation.
6. [Complete] Complete approval and question controls.
7. [Complete] Add the provider-aware status bar and permission modes.
8. [Scoped pass; overall blocked] Complete read-only states, accessibility, theme,
   scaling, and composer visual review.
9. [Blocked] Run the complete local gates, leave the exact worktree uncommitted, and
   open it in Cursor for review before any commit.

Phase 1 delivered the rail alignment and thinking Markdown improvement. The
stable rail accessibility labels are test hooks with no visible style change.
Phase 2 owns the composer behavior described above. Phase 3 owns the
provider cancellation route, Stop state, request-scoped delivery identity,
optimistic echo reconciliation, bounded expiry, and failed-send/cancel
recovery. Phase 4 owns the exact tail policy, safe paging, retained-history
cap, virtualized visible cells, and session-scoped frame cleanup. Phases 5
through 8 now own the completed rich presentation, action surfaces,
provider-aware status/modes, and read-only/accessibility/theme/scale behavior
described in the contract. The 2026-08-31 composer enclosure pass refines the
existing composer/action seams and remains in verification.

## Public test seams

Use the smallest seam that proves the behavior. A renderer test must not be
used as proof of daemon or Swift behavior.

| Seam | Public entry point | Contract covered |
| --- | --- | --- |
| Pure app presentation | `packages/app/src/chat-presentation.test.ts` and `npm run test --workspace=@agent-visor/app` | Turn grouping, visibility, metadata formatting, and page merging. |
| Pure app scrolling and paging | `packages/app/src/chat-tail.test.ts` and `packages/app/src/chat-pagination-window.test.ts` | Exact 80 px near-tail behavior, stream/local-send/composer-resize decisions, stable prepend anchors, single-flight earlier requests, bounded turn-aligned expansion, replay rejection, and the latest no-overlap history gap. |
| Pure composer policy | `packages/app/src/chat-composer.ts` and `packages/app/src/chat-composer.test.ts` | Per-session draft storage, keyboard/IME policy, measured line growth, attachment validation, submission, and slash filtering. |
| Clipboard and local-image adapter | `packages/app/src/chat-paste.ts`, `packages/app/src/chat-paste.test.ts`, and `packages/desktop/src/image-file-reader.test.ts` | Direct image files, `ClipboardItem.getAsFile()` fallback, Swift PNG/TIFF/HEIC MIME coverage, and one validated local `file://` image URL through the isolated Electron IPC bridge. |
| Protocol contract | `packages/protocol/src/index.test.ts` and `npm run test --workspace=@agent-visor/protocol` | Chat page, item, capability, pending-action, and request schemas. |
| Daemon contract | `packages/server/src/chat.test.ts`, `packages/server/src/slash-commands.ts`, and `npm run test --workspace=@agent-visor/server` | Provider parsing, metadata, bounded pages, ended-session capabilities, filesystem-backed slash discovery, hook-backed command fallback, and responses. |
| Session transport controller | `packages/app/src/chat-session-controller.test.ts` | Reused Chat sessions reset state and ignore delayed page/action callbacks from an earlier transport generation. |
| Cancellation controller/presentation | `packages/app/src/chat-session-controller.test.ts` and `packages/app/src/chat-cancellation.test.ts` | Working-only identity-bound cancel requests, duplicate-click suppression, confirmed/failure state, and provider/session fail-closed presentation. |
| Delivery and recovery policy | `packages/app/src/chat-delivery.test.ts`, `packages/app/src/chat-delivery-recovery.test.ts`, and `packages/app/src/chat-session-recovery.test.ts` | Immediate optimistic rows, request/provider identity matching, bounded content fallback, page/ack ordering, duplicate replay, identical consecutive messages, TTL expiry, non-clobbering draft restoration, retry identity/idempotence, dismiss, and confirmed-cancel recovery. |
| Exported Electron app/UI surface | `packages/app/src/Chat.tsx` exercised by `packages/desktop/scripts/test-chat-accessibility.mjs` through `npm run test:chat` | A focused Electron check of the exported renderer DOM: accessibility labels, routing, actions, bounded/virtualized history, tail and prepend behavior, visible history-limit status, images, Markdown, shared rail geometry, scale, composer focus/keyboard, slash completion, attachments, per-session restore, and ended-session controls. It is not full Swift parity evidence. |
| Browser integration | `npm run test:sessions` | Entry to Chat from Sessions, owner routing, and retained browser state. |
| Swift pure-policy seam | `swift test --package-path AgentVisorCore` | Pure Core contracts: `ChatPaginationWindowTests`, `ChatTailAutoPinPolicyTests`, `ChatRowDiffTests`, `ChatVisibilityRulesTests`, `ChatFontScaleCommandTests`, `ComposerHeightCalculatorTests`, `ComposerOuterFrameHeightTests`, `ComposerSendRecoveryPolicyTests`, `PendingEchoLogicTests`, `PermissionModeSurfacePolicyTests`, `TurnCollapsePlannerTests`, and the `AskUserQuestion*Tests` family. UI source-audit tests are supplemental wiring checks, not behavior proof. |
| Local gates | `npm run typecheck` and `git diff --check` | Type safety and patch hygiene. |

Behavior changes should add or update a pure test or a public Electron
accessibility check. Do not add source-text audit tests to claim parity.

## Limit policy

Every new hard limit in implementation code must have a nearby concise
`ponytail:` comment. The comment must state what change is required if the
limit is reached. Phase 1 adopted the contract-backed presentation limits for
the shared Sessions and Chat rail: a 980-point maximum width and 28-point
minimum window inset. Phase 2 adds the Swift composer limits: eight visual
lines before internal scrolling, ten images per message, 10 MB per image, a
1,000-command wire/catalog result ceiling, and a four-level filesystem walk.
Slash discovery also bounds directory entries, plugin/version scans, global
work, candidate files, and document bytes. Each limit has a nearby
`ponytail:` comment in the owning module. Existing protocol and daemon limits
remain owned by their current contracts.

Phase 4 adds the 100-row initial daemon request, the protocol page ceiling,
the 4,000-row client retention cap, and the bounded FlatList render window.
The tail settle loop is limited to eight animation frames, and tail decisions
use the exact 80 px near-bottom threshold. These are renderer memory,
latency, and interaction safeguards. Each new limit has nearby `ponytail:`
guidance; changes require updated app tests and a review of the Swift
scrolling contract.

Image transport derives its maximum base64 character count from the shared
10 MB decoded-byte cap. The protocol also bounds the aggregate attachment
base64 budget and the WebSocket payload before JSON is materialized. The wire
bound is the aggregate base64 budget plus worst-case JSON escaping for the
1,000,000 UTF-16-unit text ceiling and an explicit envelope allowance. If
those budgets change, update the derived constants and their `ponytail:`
guidance in `packages/protocol/src/index.ts`. Async clipboard retention is
bounded to 256 KiB, and enabled plugin marketplace/name components are bounded
safe single path components.

## Phase 2 evidence

The deep renderer policy is in `packages/app/src/chat-composer.ts`; the
renderer only supplies browser file/DOM adapters and calls that public policy.
Drafts live in an app-lifetime in-memory map keyed by session ID, including
attachment data. Slash commands are requested lazily through
`get_chat_commands`; the daemon keeps file paths private and discovers the
Swift built-ins plus enabled plugin, user, and project command locations.

Focused evidence on 2026-08-28:

- `chat-composer.test.ts`, `chat-paste.test.ts`, `chat-session-controller.test.ts`,
  `image-file-reader.test.ts`, `slash-commands.test.ts`, `chat.test.ts`,
  `outbound.test.ts`, `server.test.ts`, `sessions.test.ts`, and
  `protocol/src/index.test.ts`:
  focused corrections passed.
- The complete app, protocol, server, and desktop source test set passed: 433
  tests across 42 files (protocol 21, server 236, app 159, desktop 17). This
  includes bounded response-answer validation,
  exact slash-catalog truncation boundary coverage, raw image normalization,
  the directory-overflow truth correction, symlinked slash-root coverage, and
  generation-scoped daemon-error handling for invalid or oversized Chat pages
  and slash catalogs, including errors whose response type is absent.
- `packages/desktop/scripts/test-chat-accessibility.mjs`: focused Electron
  Chat surface check passed against the current renderer export, including the
  phase-2 composer, session-switch, `ClipboardItem.getAsFile()` TIFF fallback,
  validated local copied-image URL scenarios, and incoming history-image
  presentation. The valid history fixture is raw provider base64 containing a
  minimally decodable 1x1 PNG; the app seam normalizes it to a validated data
  URI.
  React Native Web is checked through its accessible `role="img"`/name,
  nonzero layout, and exact validated data URI presentation contract rather
  than an implementation-specific HTML tag. It also preserves asynchronous
  multi-URL text at the active selection and checks the production renderer
  trust seam rejects an unexpected origin and packaged navigation. The preload keeps
  `contextIsolation` and `sandbox` enabled, and the main-process reader accepts
  only local `file://` image paths with shared MIME and byte limits. Remote and
  raw local history-image paths render accessible non-fetching placeholders;
  no remote image request is made. Renderer image decoding and trusted
  local-path history presentation are covered by the completed rich-content
  surface.
- Image delivery uses one shared byte-signature policy at the app, daemon, and
  desktop boundaries. Desktop reads use no-follow open handles, fstat, and a
  bounded sentinel read. The read loops require the final fstat size to match
  the opened handle and reject short or growth-mutated reads. Trusted clipboard
  file URLs may traverse parent symlinks for legitimate macOS `/var` paths;
  the final component is opened with no-follow, then size and signature checks
  provide the security boundary. Renderer trust is limited to the exact
  packaged entry or an approved loopback dev origin; navigation, redirects,
  window opens, and image IPC sender frames are checked. The focused Electron
  harness exercises the same trust seam and asserts rejection of an unexpected
  origin and packaged navigation.
- Signature validation is intentionally the current portable contract: it
  checks supported container signatures and declared size/MIME agreement, not
  full image decoding. The renderer's bounded decode and rich image
  presentation are covered separately by the completed message/image surface.
- Provider history mapping accepts bounded canonical raw base64 and data URIs.
  Claude, Pi, and Codex payloads normalize to canonical raw base64 with a
  signature-inferred MIME when the provider omits it. Explicit unsupported or
  mismatched MIME values, malformed payloads, and oversized payloads are
  dropped before Chat presentation. The app remains backward compatible with
  either raw base64 or data URI history values.
- The daemon applies the shared derived WebSocket payload ceiling before
  parsing requests. An oversized frame is handled per socket with a controlled
  `1009` close, and a separate client remains healthy. Plugin identifiers are
  validated as bounded path components; resolved plugin cache/version paths
  must remain under the resolved cache root, including command and skill
  subdirectories after realpath resolution, and malformed plugin metadata is
  skipped without invalidating the catalog. `respond_chat.answers` is bounded
  by key, scalar, array, item, and aggregate character/byte budgets. The
  global WebSocket bound is derived as the maximum of the worst-case send and
  bounded response envelopes.
- Every daemon response and subscription event passes through one validated
  outbound serialization/send seam. It validates `serverMessageSchema`,
  measures UTF-8 bytes against `CHAT_MAX_WIRE_BYTES` before `ws.send`, and
  emits a bounded `daemon_error` with response/request/session context when a
  response is invalid, cannot be serialized, or exceeds the wire ceiling.
  Test-only lower limits are normalized inside that same production ceiling.
  Existing Chat-page and slash-catalog bounds remain the first defense; this is
  the final transport guard and does not fabricate a replacement response.
- The Chat controller matches daemon errors to the active generation, session,
  request type, and slash request ID. It accepts a missing response type from
  an otherwise matching invalid-response envelope, while rejecting explicit
  response-type, session, request-ID, or generation mismatches.
- Slash discovery returns honest `truncated` metadata when its 1,000-command
  response ceiling or filesystem budgets limit discovery. Exact catalogs at the
  ceiling remain untruncated; when discovery is incomplete, the composer shows
  “Command discovery limit reached — some commands may be unavailable.” This
  describes the limit without claiming that a particular unseen command exists.
  Command files and settings use no-follow bounded reads with explicit caps.
  Swift command discovery is matched exactly at this boundary: the enabled
  plugin map comes from `settings.json`, plugin cache resolution chooses the
  lexicographically highest direct version directory, and hidden entries are
  skipped. Remaining-source probes use explicit `found`, `complete-none`, and
  `unknown-bound-exhausted` states; unknown bound exhaustion sets
  `truncated=true`, while truly empty sources do not. Probes follow in-root
  symlinked directories with realpath containment and cycle checks. Plugin
  identifiers split at the first `@`, matching Swift's `split(maxSplits: 1)`;
  later safe `@` characters remain in the marketplace component.
  `installed_plugins.json` is not consulted because it is not part of the
  verified Swift service contract; adding that compatibility source needs a
  separate approved contract and tests.
- Clipboard handling bounds file/item materialization and string callbacks,
  accepts mixed image clipboard shapes, validates attachment base64/length/
  signatures before storing previews, and preflights file metadata before any
  FileReader allocation. A single local image URL is read through the safe
  bridge after percent-decoded extension checks. Multi-URL or non-image text
  is never treated as an image; direct clipboard data remains available to
  normal paste handling, while asynchronous `text/plain` items are inserted
  at the active selection with the caret restored. Async string callbacks are
  resolved sequentially within the shared 256 KiB retained-text budget. If the
  session, draft, or selection changes while a callback is pending, insertion
  is canceled with a visible `Paste canceled because the composer changed.`
  message and newer edits remain intact.
- The composer enforces the shared 1,000,000 UTF-16-unit text ceiling locally
  before send, including programmatic and paste paths, with a visible
  validation message and the native text input `maxLength`.
- Terminal-backed providers additionally advertise `maxTextBytes=65,536`,
  measured in UTF-8 bytes. The native-helper serializer preflights that text
  limit and the 1,048,576-byte length-prefixed JSON frame before any socket
  write, so an over-limit send fails as one bounded recovery event rather than
  partially writing. Codex retains the global UTF-16 ceiling. The shared
  constants and their `ponytail:` guidance live in the protocol and Swift
  helper wire contracts.
- Slash command/settings reads use bounded no-follow open-handle loops with
  exact-size checks and explicit settings byte caps. The command catalog's
  `truncated` metadata reaches the composer, which surfaces an accessible
  truncation row without fabricating a count.
- Protocol, app, server, and desktop typechecks passed. The server native
  helper socket callback keeps the existing wire behavior while normalizing
  the Node `Socket.data` union for the current TypeScript definitions. The
  current protocol, daemon, renderer export, and desktop builds completed.

Phase 3 deliberately keeps scrolling and rich rendering out of the delivery
module. Streaming tail policy, virtualized history, rich Markdown and tool
presentation, provider-aware status modes, and visual review are covered by
the completed Phase 4–8 surfaces.

## Phase 3 cancellation evidence

Cancellation is advertised only when the session is still working and the
daemon can prove the exact provider route and active delivery are live:

| Provider/session route | Cancellation mechanism | `canCancel` gate |
| --- | --- | --- |
| Codex app-server | One daemon-owned `turn/interrupt` for the exact thread/session + delivery after a concrete turn ID exists | Working section, live app-server route, exact active delivery, concrete turn ID |
| Claude Code terminal | Native helper Escape through the owned Ghostty, iTerm2, or Terminal.app target | Working section, terminal target owned and live, exact active delivery, supported terminal app |
| Pi terminal | Native helper Escape through the owned Ghostty, iTerm2, or Terminal.app target | Working section, terminal target owned and live, exact active delivery, supported terminal app |
| Hook-only, read-only, ended, ready, unsupported, or unavailable route | None | Always false; the server re-checks before send/cancel |

- Codex uses a daemon-owned registry keyed by exact thread/session and
  delivery ID. A turn is cancellable only after a concrete provider turn ID
  exists, and one `turn/interrupt` is sent only for the matching delivery.
  Repeated requests are idempotent; startup gaps and missing active turns
  fail closed.
- Claude Code and Pi use the daemon-owned terminal target and the native
  helper's provider-specific Escape route. Ghostty uses its named Escape key;
  iTerm2 writes the Escape byte; Terminal.app posts key code 53.
- Read-only, ended, ready, hook-only, unsupported, unavailable-helper, and
  unowned sessions fail closed. The server rechecks the live section,
  capability, route, and delivery identity before acting. Terminal Escape is
  never sent for a delivery other than the one currently registered for that
  exact session.
- Terminal cancellation state is a record, not a session-wide boolean:
  `NativeSessionControls` binds the delivery ID to a deterministic fingerprint
  of the complete native terminal target and a send generation. Repository
  snapshots and `chatPage` reconcile that record against the authoritative
  provider session. Ready/ended/unavailable transitions, target replacement,
  session removal, failed sends, and confirmed cancellation clear it; a queued
  send cannot register after its target was replaced.
- Claude/Pi terminal sends add a second, provider-evidence gate. Before the
  paste, the repository captures the latest canonical user-entry IDs (bounded
  to 512), the normalized submitted text, and the daemon request ID. The
  control record stays pending after a successful paste. A later authoritative
  latest page must show exactly one new user entry, preferably with the matching
  request or delivery identity; otherwise the exact normalized text is a
  bounded fallback. Delayed echoes therefore keep Stop hidden, while an
  identical prompt is distinguished from an earlier prompt by its canonical
  entry ID. Ambiguous or mismatched new rows, transcript rewind, missing bound
  identity, a later same-target external turn, and non-latest paginated pages
  fail closed. The 512-entry baseline/reconciliation caps are memory and
  latency safeguards; raising them needs an explicit transcript cursor or
  sequence contract review.
- The daemon reconciles all live terminal deliveries against each
  authoritative latest page as one assignment pass. A canonical user-entry ID
  is consumed by at most one delivery; explicit request/delivery identity wins,
  while content-only fallback requires exactly one candidate delivery and one
  candidate row. Two identical pending deliveries plus one unidentified row
  therefore remain fail-closed rather than both becoming cancellable. The
  consumed-ID replay history is insertion ordered and capped at 512 IDs across
  page replays, with the same cap guidance as the baseline scan.
- Native controls and the repository admit at most 32 queued or running
  actions per session before starting evidence reads or materializing image
  files. Admission rejection is contextual and leaves the request unretained;
  every success, failure, cancellation, and session-forget path releases its
  operation reservation. Other sessions have independent lanes, and a reused
  session ID cannot inherit an old queue or stale completion. The 32-action
  bound is a latency/memory safeguard; raise it only with a coordinated
  daemon/native-helper review.
- `cancel_chat` carries request ID, session ID, generation, and delivery ID
  for a cancellable action. The daemon echoes that identity in
  `chat_action_result`; the renderer accepts only the matching result for the
  active generation and ignores stale or mismatched outcomes.
- Every window-mode terminal transaction allocates one operation ID and
  carries it through the serializer owner, tmux/process-executor children,
  AppleScript adapter calls, marker/clear steps, and the termination hook.
  Approval fallback Enter/Escape uses the same per-session lane, so it queues
  behind an in-flight Chat send or cancel and cannot terminate another action.
  Pi TTY backfill uses a bounded local ps read and fails closed on timeout,
  malformed output, or a non-zero result.
- The Chat Stop control appears only for a working page with `canCancel=true`.
  It becomes disabled and announces `Canceling agent` after the first click,
  then exposes accessible `Agent stopped` or failure/retry state.
- Approval and question actions use the exact provider approval identity shown
  in the action card (`approvalId`, with `toolUseId` as the legacy identity).
  A session may expose multiple Codex app-server approvals at once; each is
  independently actionable and can be answered out of order. The repository
  reserves an approval before awaiting provider code, coalesces exact
  duplicate responses, rejects conflicting answers, and caches one terminal
  success/error result for replay. Provider throw, timeout, generation change,
  and session removal become explicit non-actionable terminal states. Pending
  controls remain visible but disabled while responding, and the protocol
  caps the retained approval ledger at 64 records (`ponytail`). Codex derives
  each approval ID as an opaque SHA-256 digest of the exact session/thread,
  concrete turn, delivery/request ownership, app-server JSON-RPC request ID,
  and app-server process-instance ID. Prompt and tool payload content is never
  placed in the ID. This keeps identical JSON-RPC IDs in concurrent
  app-server processes routable to their original `external.respond` closure;
  incomplete owner identity fails closed rather than falling back to
  `message.id`. Keep the digest inputs and 64-record cache bounded and
  coordinated with the provider action queue (`ponytail`).

The daemon's terminal image path has its own delivery-owned lease boundary:

- `ChatImageLeaseStore` keys every materialized file by the complete
  `sessionId + generation + requestId + deliveryId` tuple. It validates every
  image and admits the complete operation before writing its first file, so a
  rejected record cannot leave a partial payload behind. The store caps
  retained leases at 256 records and 256 MiB of decoded image bytes, with a
  five-minute fallback expiry for providers that never publish canonical
  evidence. These are daemon retention safeguards, not provider limits;
  changes require a coordinated protocol/client/server review (`ponytail`).
- A canonical provider row releases only that delivery's files. Definite send
  failure, cancellation, session forget, generation replacement, and bounded
  expiry release the same exact scope; unrelated deliveries and shared-path
  owners are preserved. Normal success does not depend on a later directory
  sweep. If a filesystem delete fails, the lease remains in a bounded
  cleanup-pending state with its paths and decoded bytes accounted; an
  unref'd exponential retry is attempted rather than silently dropping the
  recovery reference.
- Terminal evidence records are independently bounded (64 live delivery
  records). Content-only reconciliation is allowed only when the latest page
  explicitly reports authoritative, complete evidence and the canonical row
  has a source timestamp at or after submission. Missing, malformed, empty,
  incomplete, or older probes disable fallback; exact provider identity may
  still reconcile without a timestamp. This keeps old/replayed identical rows
  from consuming a new delivery. The record cap and five-minute evidence
  deadline must stay aligned with the image lease lifecycle (`ponytail`).
- For identity-less image fallback, the terminal record retains an immutable,
  ordered fingerprint for every submitted image (MIME, decoded byte length,
  and SHA-256 digest). Canonical image blocks must match the full ordered
  multiset; missing, extra, reordered, or unavailable image data fails closed.
  Pi's path-bearing prompt is the provider-specific exception: an empty
  canonical image list is accepted only when its exact generated-path prompt
  matches. The fingerprint and temporary-file budgets are coordinated limits;
  changes require protocol, daemon, and renderer review (`ponytail`).

## Phase 3 delivery and recovery evidence

The delivery and recovery behavior is implemented as two deep app modules at
the controller seam. `chat-delivery.ts` owns immutable submitted snapshots,
optimistic user rows, request/delivery identity, page reconciliation, duplicate
replay protection, expiry, cancellation, and record bounds. The controller
passes `sessionId`, generation, request ID, and delivery ID through
`send_chat` and `chat_action_result`. Provider transcript items preserve
`requestId`, `deliveryId`, and `providerMessageId` only when the source exposes
those fields; the daemon does not invent provider identity.

Reconciliation uses provider/request identity first. When a provider has no
matching identity, content fallback is opt-in: the controller enables it only
after an authoritative, latest, complete baseline (including a fully loaded
empty transcript) whose canonical user rows have trustworthy timestamps. The
candidate must carry a finite canonical timestamp later than submission. A
pre-load empty pulse, truncated baseline, missing/old timestamps, earlier
pages, and unidentified rows outside that boundary remain identity-only.
Within the allowed boundary, fallback is
deliberately bounded to the ten most recent user turns and matches normalized
text one-to-one in submission order. A previously observed content-only
canonical item cannot consume another later identical submission. Identical
consecutive messages therefore remain two separate rows. If an original and
its retry have identical content, an unidentified canonical row is ambiguous
and is left pending until provider identity arrives; it never guesses which
retry succeeded. Exact identity is safe even on the first latest page after an
A-to-B-to-A reattach, so a canonical row committed while the renderer was
away can settle the correct retry. Session and generation checks reject late
pages, acknowledgements, errors, and timer work.

Content-only fallback also fails closed when more than one current delivery
matches the canonical text/images, even if one is failed and another is
pending; delivery status or insertion order is not evidence of provider
ownership. The row remains actionable until an exact provider identity arrives.

An action acknowledgement is not transcript proof. Deliveries remain
synthetic and explicitly `acknowledged` until an exact canonical row arrives.
Both acknowledgement-before-page and page-before-ack converge to one
canonical row. `CHAT_DELIVERY_TTL_MS` (30 seconds) is the bounded deadline for
both pending and acknowledged states; an unacknowledged delivery becomes a
visible failed recovery, while an acknowledged delivery without canonical
proof becomes `uncertain`, loses synthetic cancelability, and remains visible
for safe Restore/Dismiss handling. A canonical row with exact identity can
settle that uncertain lineage later. A retry acknowledgement remains
`awaiting-canonical` in its original recovery lineage rather than deleting the
Retry card early.

The hook owns one explicit expiry timer per active generation and clears it on
session switch and unmount. The delivery store expires only the explicit
`sessionId` + `generation` scope, so a stale timer from session A cannot publish
or restore a failure in active session B. Actionable pending, failed, canceled,
uncertain, and retry-lineage records survive inactive A-to-B-to-A navigation;
their timestamps are preserved and retrying records are rehydrated rather
than left permanently `retrying`. The delivery module bounds one scope to 256
retained delivery/lineage records and retains 512 canonical IDs for replay
protection. Actionable records are never silently evicted; when the record or
UTF-8 snapshot budget is full, admission fails atomically and the caller keeps
the submitted draft/recovery explanation. Only a confirmed canonical record
with no recovery lineage is reclaimable. These bounds are renderer-memory
safeguards, not provider claims.

`chat-delivery-recovery.ts` stores an immutable text-and-attachment snapshot.
On send failure, expiry, or confirmed cancellation it restores that snapshot
only when the current composer is empty or still exactly the expected
post-submit state. A newer text, attachment, or revision is never overwritten;
the failed/canceled record remains actionable. Retry reads the stored snapshot,
creates one new request/delivery identity, suppresses duplicate clicks, and
clears the composer only if it still exactly contains the recovered snapshot.
Successful retry consumes the recovery record only for its exact replacement
identity; a late exact original identity settles only the original lineage.
An unidentified row that could belong to both identities leaves recovery
actionable. Failed retry keeps it visible. Dismiss removes only its target
record. Failed cancellation does not restore,
stop the working delivery, or hide its optimistic row. Confirmed cancellation
uses the same restore guard and removes only the unconfirmed synthetic row;
canonical provider rows are never removed by recovery cleanup.

Every recovery and delivery hard bound has nearby `ponytail:` guidance in its
owning module and the shared `chat-delivery-policy.ts` contract. Recovery
records count full base64 image text, IDs, and bounded error text toward the
same admission budget; no actionable snapshot is dropped to make room. If the
confirmation SLA changes, update the TTL, acknowledged/uncertain user-facing
copy, scheduler tests, and this contract together. If provider transcripts
need a larger fallback window or replay set, add a cursor/sequence contract
before raising the renderer bounds. If canonical timestamps or a complete
latest baseline are unavailable, preserve identity-only behavior rather than
widening the content guess.

The Swift window composer now uses the app-lifetime
`ComposerRecoveryScopeStore`, keyed by exact session and provider generation.
`ComposerRecoveryLifecycleCoordinator` owns the exact pending-echo join and
expiry/canonical transitions beneath that service, so view destruction and
away/back navigation cannot pause or orphan a delivery. The service owns the
Core `ComposerSendRecoveryLedger` plus the complete text/image snapshots
needed for restoration, so A-to-B-to-A navigation preserves the exact recovery
card and pending echo. It restores only
under the post-submit revision guard and presents an accessible `Message not
sent` card with idempotent Retry and target-only Dismiss. A late canonical echo
removes only its matching recovery card. Explicit repository removal or
generation replacement forgets every old-generation request/echo identity and
migrates the exact old snapshot into a failed, restorable card in the new
generation; it never retries stale provider identities. Core bounds are 256
records, 32 scopes, and 100 MB of recovery metadata; the nearby `ponytail:`
guidance requires coordinated persistence and image-byte accounting before any
bound changes. Empty scopes are reclaimed only after their exact records and
pending IDs are gone, while actionable records are rejected rather than
silently evicted.

Compaction is an explicit non-cancelable state. The chat-level Escape policy
consumes Escape while context is compacting, and the composer repeats that
guard at its mutation seam: no terminal cancel is posted, and text or image
attachments remain untouched. The composer shows the provider-neutral,
VoiceOver-readable explanation that context compaction cannot be stopped.
Authoritative SessionStore refreshes compare PID, process-start token, normalized
TTY, and known terminal host. A same-PID token replacement advances the
generation, retires the old synthetic echo, and migrates the exact snapshot to
a restorable card under the new generation. Authoritative SessionStore removal
paths (stale-PID dedup, explicit transcript
delete, dead-session prune, empty-noise prune, and duplicate-PID prune) call the
shared recovery/echo/draft cleanup service. Away/back navigation and reversible
hide do not call it. A live PID reattachment or rediscovered replacement
advances the provider generation and preserves old content as a new-generation
recovery card; exact attachment IDs are released only when no other scope still
retains them.

The Swift terminal sender now returns a typed ordered-delivery outcome rather
than a lossy Boolean. It reports `delivered`, `failedBeforeWrite`, or
`uncertainAfterPartialWrite` with the completed step IDs. Attachment paths,
text, and the final image-only Enter step are preflighted and executed in
order; the first failed step stops the sequence, so later attachments are
never written. A definite pre-write failure follows the normal accessible
Retry/Restore recovery path. A partial/uncertain result retains the exact
snapshot and files, hides ordinary one-click Retry, and requires explicit
risk confirmation before retrying. `TerminalAttachmentDeliveryPolicy.run`
and its Core tests exercise first/middle attachment, text, Enter, and full
success ordering without depending on a live terminal.

All window-mode terminal sends, image pastes, Escape cancellation, and prompt
clearing share one `TerminalTransportSerializer` lease per session. The lease
has an explicit owner token, FIFO waiters, bounded acquisition (2 seconds by
default), and a bounded operation (30 seconds by default; cancellation clear
uses the 120-second coordinated bound). A canceled or expired waiter is
removed, and a duplicate owner fails closed rather than nesting the same lane.
Unrelated sessions retain independent lanes. AppleScript and tmux actions use
the shared process executor, which terminates and awaits the child on its
deadline before the lane advances; this prevents a timed-out child from
writing after a later action. `ponytail:` guidance beside the serializer and
process bounds requires a coordinated Core/app/helper review before changing
these limits. A transport acquisition failure is a definite pre-write
failure; an operation deadline after a compound transaction started is
reported conservatively as uncertain so normal one-click retry is not
fabricated.

Swift parity corrections use the same identity guarantees. Core
`PendingEchoLogic` consumes normalized canonical text as a one-to-one
multiset, so one canonical turn removes one identical echo while two
canonical turns remove two. `PendingEchoStore` tracks canonical item IDs so a
replayed transcript page cannot consume another identical echo. The store keeps
an insertion-ordered, session-local replay window capped at 512 canonical IDs;
new IDs append once, duplicate page rows do not move or consume the window, and
the oldest IDs are evicted first when the cap is reached. Window cancellation
stores the exact generated echo ID and evicts only that delivery; unrelated
deliveries and sessions remain visible, and canonical rows are never removed
by local echo cleanup.

The Swift pending-echo bridge admits one exact session token before mutating
any of its coordinated scope state: observed-baseline markers, fallback flags,
canonical replay IDs, echo rows, delivery/image metadata, and the app-owned
expiry/lifecycle record. The token table is bounded to 32 sessions; a full
table rejects a new echo without partial side-map insertion or actionable-data
eviction, and authoritative `forget` clears the token, every map, and its
pending lifecycle tasks before the session ID can be reused. `ponytail:`
guidance beside the bound requires any future increase to coordinate Core,
AppKit lifecycle, timer, and attachment-retention budgets.

Focused evidence on 2026-08-28:

- Protocol source suite: 21/21; server source suite: 236/236; protocol/server
  typechecks passed.
- The terminal image-lease and transcript-evidence slice passed 126/126
  across seven focused protocol/server files. It captures the pre-send
  baseline, keeps delayed echoes non-cancellable, binds exactly one matching
  new canonical row, and invalidates the prior delivery for a later
  same-target external turn before cancel.
- App cancellation controller/presentation tests: 13/13; app typecheck passed.
- Current Electron delivery-lifecycle follow-up: the focused delivery,
  recovery, controller, session-recovery, and recovery-presentation suite
  passes 124/124; the complete app source suite passes 159/159 and the app
  typecheck passes. This includes A-to-B-to-A retry rehydration with stale ACK
  rejection, ambiguous multi-delivery fallback rejection, exact canonical
  settlement on the first page after reattach,
  acknowledged-without-canonical expiry to `uncertain`, and strict
  post-submit timestamp/baseline gating for content fallback.
- Swift `NativeHelperWireProtocolTests`: 14/14.
- Swift `PendingEchoLogicTests`: 36/36, including one/two identical canonical
  turns, canonical replay, insertion-ordered 512-ID replay retention, cap
  ordering/deduplication, session isolation, target-only cancellation
  eviction, authoritative-latest reconcile-before-seed ordering, detached
  post-submit text/image rows, authoritative submission/occurrence timestamp
  gating, loaded empty-baseline handling, image-only matching, exact identity
  without a timestamp, and explicit delivery-ID mismatch fail-closed behavior.
- Swift `PendingEchoScopeAdmissionPolicyTests`: 3/3, covering full-table
  rejection without eviction, exact forget/reuse, and idempotent admission.
- Full Swift/Core package suite: 2,279/2,279 passed after the bounded Pi TTY
  local-read audit was updated to the executable fail-closed policy contract.
- Focused Electron Chat accessibility check passed in three consecutive fresh
  runs, including ready-session
  Stop absence, working-session double-click suppression, stale cancellation
  isolation after session navigation, visible failure, retry-stop, and
  confirmed-stop states.
- The same deterministic Electron Chat check passed provider failure,
  fake-clock expiry, attachment restoration, newer-draft conflict, retry
  double-click/new identity, retry failure persistence, target-only dismiss,
  confirmed-cancel restoration/synthetic-row removal, cancel-failure honesty,
  and stale session delivery isolation. It also passed the existing metadata,
  paging, image, action, approval, question, geometry, scale, and composer
  accessibility checks.
- The current cross-stack acceptance gate passed: 433 JavaScript tests across
  42 source files (protocol 21, server 236, app 159, desktop 17),
  protocol/server/app/desktop typechecks and emit builds, Expo web export and
  exported-renderer validation, and 2,279 Swift/Core tests. `AgentVisorNativeHelper`
  full wire/adapter checks and product build plus the Xcode AgentVisor Debug
  build passed. The direct Chat E2E passed in three
  consecutive fresh runs, including confirmed cancellation recovery, retry,
  stale-generation isolation, and the A-to-B startup-gap fixture: old, wrong,
  and missing delivery identities kept Stop hidden, the exact B identity
  enabled it, and the exact B cancellation succeeded. The provider matrix,
  wrong-delivery, and startup-gap fail-closed cases also passed in the
  server/controller public tests; the direct UI fixture exercises the Pi
  terminal route and its confirmed-cancellation path. The terminal
  transcript-evidence fixture passed three consecutive fresh runs: delayed
  echo and baseline-only pages kept Stop hidden, the exact new canonical
  delivery identity enabled it, and a later same-target external row removed
  Stop again.
- The deterministic Electron Chat fixture also passed the scoped-expiry
  navigation case: a pending A delivery with an attachment was switched to B,
  A's captured fake-clock timer was released after navigation, and B showed no
  A failure card, draft, or attachment. The stale timer remained harmless.
- The final server/controller regression pass also covered exact latest-versus-
  earlier page-mode matching, strict request/delivery pair reuse, operation-
  owned reservations through 513 session forgets and same-ID reuse, and native
  helper health disappearing after discovery. In each case stale or unavailable
  work failed closed without a provider write or cross-session recovery.

## Phase 4 scrolling and virtualization evidence

Focused evidence on 2026-08-29:

- The app source suite passed 174/174. The focused scrolling and paging seams
  cover the exact 80 px near-tail rule, stream growth, local sends, composer
  resize, stable earlier-page anchors, single-flight cursor requests,
  turn-aligned page expansion, replay rejection, and the latest no-overlap
  history-gap row.
- The renderer requests an initial 100 rows from the daemon. The paging window
  accepts a complete turn-aligned page above that request up to the protocol
  cap, then retains at most 4,000 rows. The renderer shows an accessible
  history-limit status when the client cap is reached.
- The Chat transcript uses FlatList with bounded visible rendering. Grouped
  turns are split into virtualized prompt, work, answer, and item cells, so a
  large grouped turn does not mount as one unbounded view. The near-tail rule
  keeps a far reader in place; a local send pins; composer resize pins only
  when the reader is within 80 px of the tail. Earlier-page insertion keeps a
  stable anchor, and a no-overlap latest response keeps existing history and
  shows one gap row.
- Tail animation frames are tracked by session and canceled on session change
  or unmount. A stale frame cannot move a newly selected session to the old
  session's tail.
- App typecheck passed. Expo web export and the desktop product build passed.
  The direct Chat E2E passed in three consecutive fresh runs, including the
  bounded initial tail, far and near streaming, stable prepend anchor,
  repeated paging, latest gap handling, local send, composer resize, and
  virtualization checks.

## Focused Phase 7 status and mode evidence

Focused evidence on 2026-08-29:

- `chatUsageGlanceFromNative` projects only the existing provider-authoritative
  Codex native-helper usage record. Missing, malformed, or unavailable usage
  remains absent; the renderer does not fabricate a Claude percentage.
- Claude permission-mode cycling is exposed only when the daemon verifies the
  Claude terminal capability and exact process identity. The client sends the
  expected mode with the active session and generation, the server rechecks
  the latest provider mode before sending Shift+Tab, and the request-scoped
  result is ignored when its identity is stale.
- The focused protocol, server, app, native-helper, and desktop tests passed;
  protocol/server/app typechecks, the Expo web export, desktop build, and one
  direct Electron Chat E2E also passed. The E2E covers Codex usage display,
  provider-mismatched usage omission, and one Claude Default → Accept Edits
  cycle.

## Phase 5, 6, and 8 completion evidence

The completed Phase 5 rich-content surface preserves canonical provider text
while presenting Markdown blocks, safe links, fenced/inline code with bounded
syntax treatment, MathML with literal fallback, tables, emphasis,
strike-through, images/placeholders, tools, plans, edit hunks, thinking,
durations, recaps, and compact boundaries. Phase 6 carries exact approval and
question identity, provider context, validation, keyboard and Escape behavior,
multiple choice/text answers, disabled/responding states, cancellation, and
exact provider responses. Phase 8 covers truthful read-only/ended controls,
focus order, labels and live announcements, light/dark theme, scaling, and
overflow-safe rail geometry.

## Focused Chat visual polish evidence

The 2026-08-30 Chat-only pass introduced a neutral white/light or neutral dark
reading canvas. Live comparison on 2026-08-31 superseded that part of the
direction: Sessions and Chat now share the same root canvas in both
appearances, while Chat keeps its quieter cards, borders, user prompt bubble,
readable 14 px/22 px prose, left-aligned subdued durations, and no decorative
assistant status dot. The existing 980 px rail and 28 px inset,
provider/status accents, Swift behavior, security rules, and all
send/cancel/draft/scroll semantics remain in scope; these are product defaults,
not pixel measurements of another product.

The focused fixture evidence is kept outside the repository in
`.scratch/agent-visor-chat-polish.uqx1lx/`: `screenshots-before/` contains the
installed-renderer baseline, while `screenshots-final/` contains the worktree
light wide, light narrow, light 250% scaled, dark wide, and read-only captures.
The same fixture exercises a compact local evidence reference with keyboard
reveal and selectable full path, plus one visible read-only reason in the
status footer. The renderer check now measures the actual mixed-list item and
table cell at wide and narrow widths, including body font/line-height
inheritance and no horizontal overflow. The isolated worktree fixture passed
the painted 250% scale and keyboard probes. The full Chat E2E remains
unresolved: the worktree invocation stopped at the local-send tail-pin check
(`scrollTop=0`, `distanceFromBottom=13024`, `scrollHeight=13586`,
`clientHeight=562`) before reaching mixed-flow, while a byte-for-byte baseline
run using the installed renderer and preload stopped earlier at near-tail
insertion (`scrollTop=10288`, `distanceFromBottom=564`, `scrollHeight=11414`,
`clientHeight=562`). These outcomes are recorded as open E2E failures, not
classified as pre-existing or timing-only.

Old coverage gap closed by this pass: the previous DOM probe could select the
whole answer instead of a table cell and had no narrow/scaled mixed Markdown
geometry assertion, so a flex-column regression could remain hidden. The
updated probe selects the real row/cell and waits for a painted 250% frame.

## Composer enclosure implementation evidence (2026-08-31)

The approved composer direction is represented in the current worktree as one
rounded enclosure containing attachment previews, the multiline textarea, and
the bottom toolbar. Add image and Send use 44 px hit targets; Send's visible
face is 32 px. Model/effort and truthful permission context stay near the
draft, while context/usage/provider/path diagnostics remain behind Details.
The read-only branch shows one reason and the supported source action without a
dead composer shell. Approval and question responses remain dedicated action
surfaces.

Current behavior boundaries:

- The local controller admits a payload only when each present part is allowed:
  `canSendText` and `canSendImages` are checked independently. No
  backend/provider additions were made; the current daemon never advertises an
  image-only capability.
- Send and Stop share the bottom-right action area. Stop is shown only for an
  identity-bound active cancellable delivery, takes the primary position when
  there is no sendable draft, and remains beside Send when both actions are
  legitimately available. Repeat cancellation is disabled without clearing a
  newer draft.
- Per-session drafts, IME-safe Enter/Shift+Enter, paste, eight visual lines,
  approval identity, and send/recovery semantics remain the governing contract.

Evidence status:

- Captured command-level red evidence is limited to the initial missing
  `composer-enclosure` check and the separate two-test controller red run,
  followed by the focused 34-test controller green run.
- Permission-capability, pending-Stop-visibility, and typography-remeasurement
  changes are source-review fixes with regression coverage; no command-level red
  run was captured before those fixes.
- Scoped current-tree checks passed: `npm run build` (protocol, server, app
  export/export-path check, and desktop), `npm run typecheck`, app 192 tests
  across 22 files, desktop 18 across 2 files, and protocol 22 across 3 files.
- The new exported composer fixture passed with exit 0 and success JSON. It
  covers keyboard/paste, approval draft text and image restoration,
  no-authority Stop absence, capability-gated permission, deferred cancellation
  without duplicate requests, newer-draft preservation, real image-only send,
  focus, growth/shrink, and light/dark/narrow/250% captures in
  `.scratch/agent-visor-composer-implementation.50yAcf/screenshots-final/`.
  The scoped visual presentation was inspected and accepted.
- Full `npm test` is not green: server 274/275, with
  `slash-commands.test.ts:359` (`marks a bounded remaining-source probe unknown
  when a symlinked directory hides a candidate`) timing out at 5,000 ms and its
  `afterEach` hook timing out at 10,000 ms. An isolated retry of that 20-test
  file reproduced the same 19/20 failure without source changes.
- One full Chat E2E run is not green. `test-chat-accessibility.mjs:833`,
  `stream growth keeps a near-tail reader pinned`, failed with
  `scrollTop=557.5`, `distanceFromBottom=576.5`, `scrollHeight=1666`, and
  `clientHeight=532`. This is a different current failing point from the prior
  caveats; keep it open and do not call it pre-existing or timing-only.
- The candidate bundle index is
  `f5ac6a3ff67e47b8117179d71520e7d9.js`. At the review checkpoint, overall
  verification remained blocked and the diff was left uncommitted; this
  section did not make a final-pass or commit-ready claim.

## Phase 9 prior gate evidence (2026-08-29)

Historical evidence from the exact 2026-08-29 gate, before the current
composer enclosure pass; it does not close current composer verification:

- Protocol passed 22 tests across 3 files, server 241 across 20, app 189
  across 22, and desktop 18 across 2: 470 tests across 47 files total.
- All four TypeScript typechecks passed, along with the protocol/server/app
  builds, Expo export, exported-renderer validation, and desktop build.
- Clean-profile, native-services, and Sessions E2E checks passed. The direct
  Chat E2E passed in three consecutive fresh runs.
- Swift/Core passed 2,280 tests. The native-helper product build and its
  wire/adapter checks passed, as did the unsigned Xcode Debug build.
- The signed 2.7.0 package passed release bundle, signature, and archive
  tests. The isolated packaged UI launched from the file renderer with a clean
  profile.
- Claude usage remains intentionally absent because the current server has no
  authoritative Claude usage source; the status surface omits it rather than
  fabricating a value. Codex usage is shown only from matching authoritative
  Codex data.

Phase 3 delivery rows do not change the Phase 4 scrolling interfaces.
