//
//  ChatTableView.swift
//  AgentVisor
//
//  AppKit-backed chat list. Replaces the SwiftUI LazyVStack render path
//  in window mode for stability at scale.
//
//  ── Architecture ───────────────────────────────────────────────────
//
//  NSScrollView → ChatStackDocumentView (custom flipped NSView) →
//  one persistent NSHostingView per row. The document view does its
//  own vertical layout: it walks its children, sets each child's
//  frame to the document's content width (minus horizontal padding)
//  FIRST, then asks the child for its `fittingSize.height` AFTER the
//  width is established, and sets the frame's height accordingly.
//
//  Why a custom layout instead of:
//
//    NSTableView. The table queries `heightOfRow:` (or relies on
//    automatic row heights via Auto Layout) BEFORE the cell has been
//    laid out at the column's actual width. SwiftUI text wrap depends
//    on width, so any answer at zero / fallback width is wrong, and
//    the row paints at one height while content renders at another.
//
//    NSStackView. With `alignment = .width` the stack constrains
//    children to the stack's width, but NSHostingView's
//    `sizingOptions = [.intrinsicContentSize]` publishes a height
//    computed at the host's *natural* (unconstrained) width. When
//    the constraint forces a smaller width, the published height is
//    stale — every row collapses to ~0pt at the same y, and rows
//    visually overlap.
//
//  The custom layout sidesteps both. We KNOW the width before we
//  ask for the height:
//      child.frame.size.width = self.bounds.width - 2*hPad
//      child.layoutSubtreeIfNeeded()  // pump SwiftUI at this width
//      child.frame.size.height = child.fittingSize.height
//
//  Single source of truth for height. Single SwiftUI graph (no
//  measure-vs-render gap). No constraint-solver feedback loops.
//
//  Why this is still better than SwiftUI LazyVStack:
//    - Each row is its own SwiftUI graph root inside an NSHostingView,
//      so a cascade in one row can't poison the others. The
//      LazyLayoutViewCache.updatePrefetchPhases storm we've been
//      fighting for weeks has no equivalent here — there is no
//      shared lazy layout cache.
//    - No prefetch-phase array reallocation per layout pass.
//    - Pagination caps the live row count (default 100; user can
//      expand). 100 always-alive isolated NSHostingViews is well
//      within budget on Apple Silicon.
//
//  Trade-offs:
//    - Per-bubble text selection only (no cross-bubble drag-select).
//    - All paginated rows are realized at once; we rely on the
//      pagination window to bound the cost.
//

import AppKit
import AgentVisorCore
import Combine
import os.log
import SwiftUI

// MARK: - Flat row model

/// Flattened chat row. The view-model emits `[TimelineRow]` (which
/// nests children under turn-duration parents); we flatten so each
/// row in the document view is one chat item.
///
/// Turn-duration parents render a collapsible "Worked for X" header
/// (Codex-desktop style): their child steps are omitted from the flat
/// list unless the turn is expanded. `turnChildCount` lets the parent
/// cell decide whether to draw a chevron; `isTurnExpanded` drives its
/// direction. Flattening order + child omission is decided by the pure
/// `TurnCollapsePlanner` (Core, TDD-covered).
struct FlatChatRow: Equatable, Identifiable {
    let id: String
    let item: ChatHistoryItem
    let groupingDepth: Int  // 0 = parent, 1 = child of turn-duration parent
    /// Number of collapsible child steps under this row (0 unless this
    /// is a turn-duration parent that has children). Drives the
    /// "Worked for X" chevron's presence.
    let turnChildCount: Int
    /// Whether this turn's children are currently shown. Drives the
    /// chevron direction; meaningless when `turnChildCount == 0`.
    let isTurnExpanded: Bool
    /// True when any of this turn's children is an errored/interrupted
    /// tool call — drives the warning glyph on the collapsed header so a
    /// mid-turn failure isn't buried. False for non-parent rows.
    let turnHasError: Bool
    /// Count of work steps folded under this turn (for the "· N steps"
    /// header label). 0 for non-parent rows.
    let turnStepCount: Int
    /// Content-aware summary of the turn's work ("Edited 3 files · Ran 1
    /// command"), built from the folded children's canonical tools. Empty
    /// for non-parent rows.
    let turnActivityLabel: String

    init(
        item: ChatHistoryItem,
        groupingDepth: Int = 0,
        turnChildCount: Int = 0,
        isTurnExpanded: Bool = false,
        turnHasError: Bool = false,
        turnStepCount: Int = 0,
        turnActivityLabel: String = ""
    ) {
        self.id = item.id
        self.item = item
        self.groupingDepth = groupingDepth
        self.turnChildCount = turnChildCount
        self.isTurnExpanded = isTurnExpanded
        self.turnHasError = turnHasError
        self.turnStepCount = turnStepCount
        self.turnActivityLabel = turnActivityLabel
    }

    /// Flatten `rows` into the visible row list, collapsing turn-duration
    /// turns whose id is NOT in `expanded`. The planner owns the order +
    /// omission decisions; this maps the resulting (id, depth) plan back
    /// onto the ChatHistoryItems and stamps the turn metadata.
    static func flatten(
        _ rows: [TimelineRow],
        expanded: Set<String> = [],
        agentID: AgentID? = nil
    ) -> [FlatChatRow] {
        // Index every item (parents + children) so the planner output —
        // which is id-only — can be mapped back to its ChatHistoryItem.
        var itemsById: [String: ChatHistoryItem] = [:]
        var childCountByParent: [String: Int] = [:]
        var errorByParent: [String: Bool] = [:]
        var stepsByParent: [String: Int] = [:]
        var activityLabelByParent: [String: String] = [:]
        let isCodex = agentID == .codex
        let groups: [TurnCollapsePlanner.RowGroup] = rows.map { row in
            itemsById[row.item.id] = row.item
            for child in row.children { itemsById[child.id] = child }
            childCountByParent[row.item.id] = row.children.count
            // Fold the turn's children into a header error flag, step
            // count, and a content-aware activity label. Step = any
            // foldable "work" row (tool / thinking / local output /
            // interrupted); error = an errored or interrupted tool call
            // (or a bare `.interrupted` row). The activity label is
            // agent-specific: Claude categorizes by canonical tool kind
            // ("Edited 3 files · …"); Codex classifies its Shell commands
            // explore-vs-run ("Explored 8 files · Ran 4 commands").
            var hasError = false
            var steps = 0
            var activity = ClaudeTurnActivity()        // Claude path
            var codexExplored = 0                       // Codex path
            var codexRan = 0
            for child in row.children {
                switch child.type {
                case .toolCall(let tool):
                    steps += 1
                    if tool.status == .error || tool.status == .interrupted { hasError = true }
                    if isCodex {
                        if tool.name == "Shell",
                           CodexToolActivitySummarizer.category(forCommand: tool.input["command"] ?? "") == .explore {
                            codexExplored += 1
                        } else {
                            codexRan += 1
                        }
                    } else {
                        let canonical = ToolNameMapper.canonical(for: tool.name, agent: .claudeCode)
                        ClaudeTurnActivitySummarizer.accumulate(canonical, into: &activity)
                    }
                case .thinking, .localCommandOutput:
                    steps += 1
                case .interrupted:
                    steps += 1
                    hasError = true
                default:
                    break
                }
            }
            errorByParent[row.item.id] = hasError
            stepsByParent[row.item.id] = steps
            if isCodex {
                // Empty when the turn had no Shell tools (commentary-only) →
                // header falls back to a bare "Worked" rather than the
                // summarizer's "No activity" placeholder.
                activityLabelByParent[row.item.id] = (codexExplored + codexRan) > 0
                    ? CodexToolActivity(exploredCount: codexExplored, ranCount: codexRan).summary
                    : ""
            } else {
                activityLabelByParent[row.item.id] = activity.label(maxClauses: 2)
            }
            return TurnCollapsePlanner.RowGroup(
                parentId: row.item.id,
                childIds: row.children.map(\.id)
            )
        }

        let plan = TurnCollapsePlanner.plan(groups: groups, expanded: expanded)
        var out: [FlatChatRow] = []
        out.reserveCapacity(plan.count)
        for planned in plan {
            guard let item = itemsById[planned.id] else { continue }
            let childCount = planned.depth == 0 ? (childCountByParent[planned.id] ?? 0) : 0
            out.append(FlatChatRow(
                item: item,
                groupingDepth: planned.depth,
                turnChildCount: childCount,
                isTurnExpanded: childCount > 0 && expanded.contains(planned.id),
                turnHasError: planned.depth == 0 ? (errorByParent[planned.id] ?? false) : false,
                turnStepCount: planned.depth == 0 ? (stepsByParent[planned.id] ?? 0) : 0,
                turnActivityLabel: planned.depth == 0 ? (activityLabelByParent[planned.id] ?? "") : ""
            ))
        }
        return out
    }
}

// MARK: - SwiftUI bridge

struct ChatTableView: NSViewRepresentable {
    let rows: [FlatChatRow]
    let sessionId: String
    let streamTick: Int
    /// Called after the view mounts so the host can keep the proxy
    /// for explicit re-pinning on composer-height-changed, etc.
    var onMount: ((ChatTableProxy) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionId: sessionId)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = false
        // Custom thin scroller: dim at rest, brightens on hover.
        // Always-visible (legacy style) so the user has a stable
        // grab target — overlay autohide reads as "no scrollbar" on
        // big chats. install() configures the scroller + style.
        DimmedScroller.install(on: scroll)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Custom flipped document view that owns the row layout.
        let documentView = ChatStackDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = documentView

        // Document view fills the scroll view's width; height grows
        // with content. The minimum-height anchor keeps short
        // documents from collapsing inside a tall scroll view.
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.heightAnchor.constraint(
                greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])

        context.coordinator.scrollView = scroll
        context.coordinator.documentView = documentView
        documentView.coordinator = context.coordinator
        context.coordinator.applyDiff(newRows: rows)

        // Tail-pin on first mount.
        DispatchQueue.main.async {
            context.coordinator.scrollToBottom()
        }

        if let onMount {
            onMount(ChatTableProxy(coordinator: context.coordinator))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Re-assert custom scroller config in case AppKit replaced it
        // during the document-view / constraint setup that happens
        // after makeNSView returns.
        DimmedScroller.install(on: scroll)
        context.coordinator.streamTick = streamTick
        context.coordinator.applyDiff(newRows: rows)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        let sessionId: String
        weak var scrollView: NSScrollView?
        weak var documentView: ChatStackDocumentView?
        var streamTick: Int = 0
        private var lastStreamTick: Int = 0

        /// Live row state. We keep persistent NSHostingControllers
        /// keyed by row id so we can update content in place (cheap)
        /// instead of rebuilding the SwiftUI graph (expensive).
        ///
        /// Why NSHostingController + .view (not NSHostingView):
        /// `NSHostingController.sizeThatFits(in:)` is the only public
        /// API that returns the SwiftUI content's fitted size at a
        /// proposed CGSize, synchronously and reliably. NSHostingView's
        /// `fittingSize` reads from whatever frame the host currently
        /// has and depends on SwiftUI having already updated at that
        /// frame — it's racy across rootView changes and width
        /// changes. The controller path bypasses that race.
        var controllersById: [String: NSHostingController<ChatTableCellContent>] = [:]
        var orderedIds: [String] = []
        private var rowsById: [String: FlatChatRow] = [:]

        /// Tail-pin gate: how far the user has scrolled up from the
        /// document bottom.
        private var distanceFromBottom: CGFloat = 0
        /// Distance from the top of the document to the visible top.
        /// Used internally; published to SwiftUI as a coarse
        /// "near-top" boolean so we don't churn @State on every
        /// pixel-level scroll tick.
        var distanceFromTop: CGFloat = 0
        /// Threshold below which the user counts as "near the top."
        /// Mirrored on the host side via the coarse callback.
        private static let nearTopThreshold: CGFloat = 200
        /// Last "near top?" boolean we published. We only fire the
        /// callback when this flips — at scroll-event frequency
        /// (60-120Hz) firing every tick was driving SwiftUI graph
        /// updates that visibly stuttered the scroll.
        private var lastNearTop: Bool = false
        /// Callback fired ONLY when the near-top boolean flips
        /// (false→true or true→false). Host wires this to a SwiftUI
        /// @State to gate the load-earlier button.
        var nearTopChanged: ((Bool) -> Void)?
        private var didInstallObservers = false

        /// Holds the AppearanceSelector subscription so we can re-key
        /// every cell's SwiftUI graph + force a relayout pass when the
        /// user flips Light/Dark. Without an explicit relayout, the
        /// already-mounted cells keep their stale `sizeThatFits`
        /// answers (the new palette would shift surface bounds and
        /// inline-code chip sizes), and the document height drifts
        /// from the true content height — visible as the
        /// half-themed chat the user reported in [Image #16].
        private var appearanceCancellable: AnyCancellable?

        init(sessionId: String) {
            self.sessionId = sessionId
            super.init()
            // dropFirst skips the launch-time replay (each Coordinator
            // is created fresh per ChatTableView mount, so the initial
            // value is already the right palette). We only want to
            // react to *user-driven* flips after that.
            appearanceCancellable = AppearanceSelector.shared
                .$resolvedAppearance
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.handleAppearanceFlip()
                }
        }

        /// Force every mounted cell to re-render against the new
        /// palette. The cell's body observes AppearanceSelector and
        /// is re-keyed via `.id(resolvedAppearance)`, so SwiftUI's
        /// structural diff invalidates the subtree — but the
        /// document view's cached row heights need a relayout pass
        /// to pick up the new measurements. Without this, the doc
        /// height stays stuck at the old palette's measurements
        /// until the next streamTick or row insertion.
        @MainActor
        private func handleAppearanceFlip() {
            guard let documentView else { return }
            // Reassigning rootView with the same value triggers a
            // SwiftUI invalidation cycle on each cell, which in turn
            // causes sizeThatFits to be re-queried during the next
            // layout pass.
            for (id, controller) in controllersById {
                guard let row = rowsById[id] else { continue }
                controller.rootView = ChatTableCellContent(
                    row: row, sessionId: sessionId)
            }
            documentView.needsLayout = true
            documentView.layoutSubtreeIfNeeded()
        }

        // MARK: - Diff application

        func applyDiff(newRows: [FlatChatRow]) {
            installObserversIfNeeded()
            updateDistanceFromBottom()

            let oldIds = orderedIds
            let newIds = newRows.map(\.id)
            let diff = ChatRowDiff.compute(old: oldIds, new: newIds)

            let lastIdShort = String(newIds.last?.prefix(20) ?? "nil")
            // Pure stream tick: ids unchanged, but the row payload
            // may have changed (last assistant chunk grew).
            if diff.isNoop {
                let payloadChanged = updatePayloadsIfChanged(newRows: newRows)
                if streamTick != lastStreamTick || payloadChanged {
                    lastStreamTick = streamTick
                    ChatHistoryManager.regressionLog.notice(
                        "CTV.applyDiff NOOP-redraw sid=\(self.sessionId.prefix(8), privacy: .public) count=\(newRows.count) payloadChanged=\(payloadChanged) lastId=\(lastIdShort, privacy: .public)"
                    )
                    documentView?.invalidateLayoutAndRedisplay()
                    if ChatTailAutoPinPolicy.shouldStreamPin(distanceFromBottom: distanceFromBottom) {
                        scrollToBottom()
                    }
                } else {
                    ChatHistoryManager.regressionLog.notice(
                        "CTV.applyDiff NOOP-skip sid=\(self.sessionId.prefix(8), privacy: .public) count=\(newRows.count) lastId=\(lastIdShort, privacy: .public)"
                    )
                }
                return
            }

            ChatHistoryManager.regressionLog.notice(
                "CTV.applyDiff REBUILD sid=\(self.sessionId.prefix(8), privacy: .public) old=\(oldIds.count) new=\(newRows.count) ins=\(diff.insertions.count) del=\(diff.removals.count) lastId=\(lastIdShort, privacy: .public)"
            )
            applyRebuild(newRows: newRows)
            documentView?.invalidateLayoutAndRedisplay()
            lastStreamTick = streamTick

            let insertedAtTail: Bool = {
                guard let maxInsert = diff.insertions.max() else { return false }
                return maxInsert >= newRows.count - 1
            }()

            if ChatTailAutoPinPolicy.shouldAutoPinOnInsert(
                distanceFromBottom: distanceFromBottom,
                insertedAtTail: insertedAtTail
            ) {
                scrollToBottom()
            }
        }

        /// Reconcile the document view's children to match `newRows`.
        /// Re-uses existing NSHostingControllers where possible and
        /// updates their `rootView` only when payload changed.
        private func applyRebuild(newRows: [FlatChatRow]) {
            guard let documentView else { return }
            let newIds = newRows.map(\.id)
            let newIdSet = Set(newIds)

            // 1. Remove controllers no longer present.
            for (id, controller) in controllersById where !newIdSet.contains(id) {
                controller.view.removeFromSuperview()
                controllersById.removeValue(forKey: id)
                rowsById.removeValue(forKey: id)
            }

            // 2. Build target controllers in order: reuse existing or
            //    make a fresh one. Update rootView only when content
            //    changed.
            var targetControllers: [NSHostingController<ChatTableCellContent>] = []
            targetControllers.reserveCapacity(newRows.count)
            for row in newRows {
                let controller: NSHostingController<ChatTableCellContent>
                if let existing = controllersById[row.id] {
                    controller = existing
                    // Compare the whole row (not just .item) so a turn's
                    // expand/collapse — which changes isTurnExpanded but
                    // not item — re-renders its "Worked for X" chevron.
                    if rowsById[row.id] != row {
                        controller.rootView = ChatTableCellContent(
                            row: row, sessionId: sessionId)
                    }
                } else {
                    controller = makeController(for: row)
                    controllersById[row.id] = controller
                    documentView.addSubview(controller.view)
                }
                rowsById[row.id] = row
                targetControllers.append(controller)
            }

            orderedIds = newIds
            documentView.orderedControllers = targetControllers
            documentView.orderedRows = newRows
        }

        private func updatePayloadsIfChanged(newRows: [FlatChatRow]) -> Bool {
            var changed = false
            for row in newRows {
                guard let controller = controllersById[row.id] else { continue }
                if rowsById[row.id] != row {
                    controller.rootView = ChatTableCellContent(
                        row: row, sessionId: sessionId)
                    rowsById[row.id] = row
                    changed = true
                }
            }
            return changed
        }

        private func makeController(for row: FlatChatRow) -> NSHostingController<ChatTableCellContent> {
            let content = ChatTableCellContent(row: row, sessionId: sessionId)
            let controller = NSHostingController(rootView: content)
            // Frame-based: the document view sets the controller's
            // view frame explicitly during `layout()`. No Auto Layout
            // for the SwiftUI host.
            controller.view.translatesAutoresizingMaskIntoConstraints = true
            controller.view.autoresizingMask = []
            return controller
        }

        // MARK: - Keyboard scrolling

        /// Scroll the clip view by `delta` points (positive = down,
        /// negative = up). Defers via async so the scroll happens on
        /// the next runloop tick, NOT inside the key-event handler
        /// (which can land mid-SwiftUI-graph-flush — when we then
        /// call `layoutSubtreeIfNeeded`, it can invalidate
        /// NSHostingView's constraints during the flush, which AppKit
        /// detects and aborts via `_postWindowNeedsUpdateConstraints`).
        func scrollBy(points delta: CGFloat) {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let scroll = self.scrollView,
                      let documentView = self.documentView else { return }
                documentView.layoutSubtreeIfNeeded()
                let visible = scroll.contentView.documentVisibleRect
                let docHeight = documentView.frame.height
                let visibleHeight = visible.height
                let maxY = max(0, docHeight - visibleHeight)
                let nextY = min(maxY, max(0, visible.origin.y + delta))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: nextY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        /// Scroll the clip view to the very top of the document.
        /// Deferred via async — see `scrollBy` for the rationale.
        func scrollToTop() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.scrollView else { return }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        /// Visible viewport height in points; used by the
        /// page-scroll handler to compute one full page of delta.
        var visibleHeight: CGFloat {
            scrollView?.contentView.bounds.height ?? 0
        }

        // MARK: - Auto-pin

        /// Re-pin to the bottom only if the user was already there.
        /// Used by ambient triggers (composer height change, gesture
        /// release) where yanking the chat down would interrupt a
        /// user reading older context.
        func scrollToBottomIfNearBottom() {
            updateDistanceFromBottom()
            guard ChatTailAutoPinPolicy.shouldStreamPin(distanceFromBottom: distanceFromBottom) else {
                return
            }
            scrollToBottom()
        }

        func scrollToBottom() {
            performScrollToBottom()
            // The document view runs settle layout passes on the
            // next few runloop ticks (`scheduleSettleLayouts`) to
            // catch late-arriving SwiftUI height (async images, code
            // highlight, etc.). Each settle pass can grow `docHeight`,
            // which would leave the chat scrolled to the OLD bottom
            // — i.e. with new content invisible below the viewport.
            // Re-pin after each settle tick so we always land on the
            // current bottom, not the stale one.
            for delay in [0.0, 0.05, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.performScrollToBottom()
                }
            }
        }

        private func performScrollToBottom() {
            guard let scroll = scrollView, let documentView else { return }
            documentView.layoutSubtreeIfNeeded()
            let docHeight = documentView.frame.height
            let visibleHeight = scroll.contentView.bounds.height
            let targetY = max(0, docHeight - visibleHeight)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // MARK: - Zoom invalidation

        /// Mark every row's cached height stale and re-run the
        /// document layout. Called when the chat font scale flips
        /// (Cmd-+/-/0): SwiftUI rebuilds the cell bodies at the new
        /// size, but `ChatStackDocumentView.layoutRows()` reads
        /// `controller.sizeThatFits(...)` once and caches the frame.
        /// Without an explicit re-measure, rows stay at their old
        /// heights and the layout breaks until session-switch tears
        /// the table down. Settling over several runloop ticks
        /// catches SwiftUI's measure-vs-render gap when the new
        /// font metrics propagate asynchronously.
        func invalidateRowHeights() {
            documentView?.invalidateLayoutAndRedisplay()
        }

        // MARK: - Observers

        private func installObserversIfNeeded() {
            guard !didInstallObservers, let scroll = scrollView else { return }
            didInstallObservers = true
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }

        @objc private func clipViewBoundsChanged(_ note: Notification) {
            updateDistanceFromBottom()
        }

        private func updateDistanceFromBottom() {
            guard let scroll = scrollView, let doc = scroll.documentView else { return }
            let visible = scroll.contentView.documentVisibleRect
            let docHeight = doc.frame.height
            let visibleBottom = visible.origin.y + visible.size.height
            distanceFromBottom = max(0, docHeight - visibleBottom)
            // Distance from the top is the visible rect's origin y in
            // the (flipped) document — 0 = scrolled to top, positive
            // = scrolled down.
            let nextTop = max(0, visible.origin.y)
            distanceFromTop = nextTop
            // Publish the near-top boolean ONLY on flips. SwiftUI
            // re-evaluates body on every @State mutation; firing at
            // scroll-tick frequency (60-120Hz) caused visible scroll
            // stutter on big sessions because each tick rebuilt the
            // ZStack overlay path.
            let isNearTop = nextTop < Self.nearTopThreshold
            if isNearTop != lastNearTop {
                lastNearTop = isNearTop
                nearTopChanged?(isNearTop)
            }
        }
    }
}

// MARK: - Document view (custom flipped vertical layout)

/// Flipped NSView that lays out a vertical column of NSHostingViews.
///
/// Layout algorithm:
///   1. Resolve content width = bounds.width - 2*horizontalPadding
///   2. For each ordered host, in order top→bottom:
///        a. Set host.frame.size.width to content width (this width
///           is now visible to SwiftUI inside the host).
///        b. Pump SwiftUI: `layoutSubtreeIfNeeded()` makes the host
///           recompute its fitted size at the new width.
///        c. Read `host.fittingSize.height` — the SwiftUI content's
///           true height at the constrained width.
///        d. Set host.frame.origin and full size.
///   3. Document view's height = sum of row heights + insets.
///
/// Why this works where NSStackView didn't: we set the WIDTH first,
/// THEN ask for the height. NSStackView's `.intrinsicContentSize`
/// path asks for the height before honoring an external width
/// constraint, so its answer is always at the natural width.
final class ChatStackDocumentView: NSView {
    weak var coordinator: ChatTableView.Coordinator?
    var orderedControllers: [NSHostingController<ChatTableCellContent>] = []
    /// Parallel to `orderedControllers`: the row payloads, used at
    /// layout time to vary inter-row spacing by item type so a turn's
    /// narration + the tools it triggered cluster together. Kept in
    /// sync wherever `orderedControllers` is assigned.
    var orderedRows: [FlatChatRow] = []

    /// Vertical insets at the top and bottom of the document.
    private let topInset: CGFloat = 14
    private let bottomInset: CGFloat = 14
    /// Default gap between rows (used for markers like turn-duration /
    /// local-command-output that don't start a reasoning block).
    private let interRowSpacing: CGFloat = 8
    /// Gap before a row that starts a new reasoning/turn block
    /// (assistant narration, thinking, a user message, a collapsed
    /// turn). Wider than `interRowSpacing` so consecutive turns read
    /// as distinct clusters instead of one uniform column.
    private let turnGap: CGFloat = 18
    /// Gap before a tool-call row. Tighter than `interRowSpacing` so a
    /// tool hugs the narration that triggered it (and consecutive tools
    /// in one action burst stay visually bundled).
    private let clusterGap: CGFloat = 3

    /// Leading gap to insert before the row at `idx` (0 for the first
    /// row — it uses `topInset`). Drives the turn-clustering rhythm.
    private func leadingGap(forRowAt idx: Int) -> CGFloat {
        guard idx > 0, idx < orderedRows.count else { return 0 }
        switch orderedRows[idx].item.type {
        case .assistant, .thinking, .user, .image,
             .recap, .compactBoundary, .turnDuration:
            return turnGap
        case .toolCall:
            return clusterGap
        case .interrupted, .localCommandOutput:
            return interRowSpacing
        }
    }
    /// Counter for "follow-up settle layout passes." Some SwiftUI
    /// rows realize asynchronously (LaTeX images, Highlightr code,
    /// NSImage decode); their first measure may be wrong. After
    /// every content / width change we schedule N more layout passes
    /// over the next few runloop ticks to pick up post-settle
    /// heights. Counter prevents an infinite scheduling loop.
    private var settleLayoutsRemaining: Int = 0

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.size.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            // Width changed → all row heights are stale. Schedule a
            // fresh re-measure plus a couple of follow-up settles.
            scheduleSettleLayouts(count: 2)
            needsLayout = true
        }
    }

    /// Called from a deferred main-queue block after `layoutRows()` has
    /// computed a new total height. Wrapping the actual `super.setFrameSize`
    /// call in a separate method (rather than calling it directly inside
    /// `DispatchQueue.main.async { … }`) lets us reach `super` cleanly,
    /// which an escaping closure can't capture.
    fileprivate func applyDeferredHeight(_ target: CGFloat) {
        guard abs(frame.size.height - target) > 0.5 else { return }
        var f = frame
        f.size.height = target
        super.setFrameSize(f.size)
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    /// Mark the document for re-layout after a content change.
    /// Does NOT call `layoutSubtreeIfNeeded()` synchronously: when
    /// the caller has just assigned a new `rootView` to one of the
    /// hosting views, SwiftUI hasn't actually re-rendered yet — its
    /// new fitted size isn't readable in the same runloop tick.
    /// Reading `fittingSize` synchronously here would return the
    /// OLD height, the next row would be positioned over the new
    /// (taller) content, and we'd see the streaming-tail overlap
    /// the user reported. Instead we just mark dirty and let the
    /// next runloop tick (when SwiftUI has settled) drive the
    /// actual `layout()` call.
    func invalidateLayoutAndRedisplay() {
        scheduleSettleLayouts(count: 3)
        needsLayout = true
        // Schedule one explicit async layout so we don't depend on
        // AppKit happening to schedule one before the user notices.
        DispatchQueue.main.async { [weak self] in
            self?.needsLayout = true
        }
    }

    /// Top up the settle counter. Subsequent calls increase the
    /// budget but never exceed `count`. The counter is decremented
    /// once per layout pass; while > 0 we keep scheduling another
    /// async layout for the next runloop tick.
    private func scheduleSettleLayouts(count: Int) {
        settleLayoutsRemaining = max(settleLayoutsRemaining, count)
    }

    private func layoutRows() {
        let hPad = ChatTableHorizontalPadding.value
        let contentWidth = max(0, bounds.width - hPad * 2)
        guard contentWidth > 0 else { return }

        var y: CGFloat = topInset
        let proposedSize = CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        for (idx, controller) in orderedControllers.enumerated() {
            // Variable leading gap (turn vs. cluster) so a turn's
            // narration and the tools it triggered read as one block.
            y += leadingGap(forRowAt: idx)
            // sizeThatFits(in:) is the canonical SwiftUI-into-AppKit
            // measurement primitive: pass the available area, get
            // back the SwiftUI content's fitted size. Unlike
            // NSHostingView.fittingSize (which depends on the host's
            // current frame and SwiftUI having updated at that frame
            // — racy across rootView and width changes), this call
            // measures synchronously against the controller's
            // SwiftUI graph at the proposed size.
            let fitted = controller.sizeThatFits(in: proposedSize)
            let rowHeight = max(ceil(fitted.height), 0)
            controller.view.frame = NSRect(
                x: hPad,
                y: y,
                width: contentWidth,
                height: rowHeight
            )
            // Gaps are applied as LEADING insets (top of `for`), so
            // advance by the row height only — no trailing spacing to
            // subtract back off after the loop.
            y += rowHeight
        }
        y += bottomInset

        let newHeight = max(y, 0)
        if abs(frame.size.height - newHeight) > 0.5 {
            // CRITICAL: do NOT call setFrameSize here synchronously.
            // We are inside `layout()` (called from AppKit's NSWindow
            // display cycle). Mutating self.frame during layout fires
            // KVO observers on every NSHostingController child →
            // SwiftUI's invalidateSafeAreaInsets → setNeedsUpdate →
            // setNeedsUpdateConstraints → AppKit detects layout
            // recursion and traps with `_postWindowNeedsUpdateConstraints`
            // (crash 2026-05-31-032508). Defer to the next tick so the
            // height write lands AFTER the current layout pass settles.
            let target = newHeight
            DispatchQueue.main.async { [weak self] in
                self?.applyDeferredHeight(target)
            }
        }

        // Run another layout next tick if we owe settle passes. The
        // counter strictly decreases each pass, so this terminates.
        if settleLayoutsRemaining > 0 {
            settleLayoutsRemaining -= 1
            if settleLayoutsRemaining > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.needsLayout = true
                }
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frame.size.height)
    }
}

// MARK: - Cell content + padding constant

enum ChatTableHorizontalPadding {
    /// Horizontal padding applied to each row. Originally 16pt to
    /// match the legacy SwiftUI ScrollView path; bumped to 28pt so
    /// chat content has more breathing room from the window chrome
    /// on either side.
    static let value: CGFloat = 28
}

/// SwiftUI cell content. The legacy `MessageItemView` — markdown,
/// code blocks, math, tool cards, plan cards all reuse the existing
/// renderers. Each cell is its own SwiftUI graph root inside its own
/// NSHostingView, so cascades stay local.
struct ChatTableCellContent: View {
    let row: FlatChatRow
    let sessionId: String

    private var item: ChatHistoryItem { row.item }
    /// Each row is its own SwiftUI graph (per-cell NSHostingController),
    /// so the parent's `AppearanceSelector` observation can't invalidate
    /// row bodies — when the user flips Light/Dark, the cached row
    /// graph keeps painting the old Catppuccin palette. Observing here
    /// at the cell root forces a re-render on `mode` changes so every
    /// `Catppuccin.text` / `ChatTheme.*` read picks up the new flavor.
    @ObservedObject private var appearance = AppearanceSelector.shared

    var body: some View {
        // `.id(appearance.resolvedAppearance)` tags the inner view
        // tree with the resolved Light/Dark flavor as identity. When
        // the user flips themes, SwiftUI sees the id change and
        // *rebuilds* the entire MessageItemView subtree from scratch
        // — re-evaluating every `Catppuccin.*` / `ChatTheme.*` read
        // against the new palette.
        //
        // Without this, observing `AppearanceSelector.shared` here is
        // necessary but not sufficient: the body re-runs, but
        // SwiftUI's structural diff skips rebuilding `MessageItemView`
        // because its value-type inputs (`item`, `sessionId`) haven't
        // changed. The cached SwiftUI graph keeps painting in the
        // previous palette — visible as the user's screenshot, where
        // the open session retained the old flavor while a freshly-
        // clicked session correctly mounted with the new flavor.
        // Re-keying via `.id(...)` forces SwiftUI to discard the
        // cached subtree, taking the same path a session-switch
        // would take.
        cellBody
            .id(appearance.resolvedAppearance)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Per-cell isolation makes `.textSelection(.enabled)` safe
            // again. The SelectionOverlay cascade we documented in
            // [[feedback_textselection_per_row_loop]] / its
            // post-mortem [[feedback_nstextview_chat_selection]] is a
            // SHARED-graph problem: when many rows live inside one
            // SwiftUI graph (LazyVStack), each row's setFont
            // invalidation pings the whole graph, producing the
            // 100% CPU storm. Here every row IS its own SwiftUI
            // graph (per-cell NSHostingController), so a setFont
            // invalidation in one row stops at that row's host
            // boundary — the cascade can't propagate to siblings.
            .textSelection(.enabled)
    }

    /// Turn-duration parents render the collapsible "Worked for X"
    /// header (chevron toggles `TurnExpansionStore`); every other row
    /// renders through the shared `MessageItemView`. The header is the
    /// window-table analogue of the notch's nested `TurnDurationView`,
    /// but flat: children are separate rows shown/hidden by the planner,
    /// not nested SwiftUI views, so the table stays one-row-per-cell.
    @ViewBuilder
    private var cellBody: some View {
        if case .turnDuration(let seconds) = item.type {
            CollapsibleTurnHeader(
                seconds: seconds,
                childCount: row.turnChildCount,
                isExpanded: row.isTurnExpanded,
                stepCount: row.turnStepCount,
                activityLabel: row.turnActivityLabel,
                hasError: row.turnHasError,
                onToggle: {
                    TurnExpansionStore.shared.toggle(
                        sessionId: sessionId, turnId: item.id
                    )
                }
            )
        } else {
            MessageItemView(item: item, sessionId: sessionId)
        }
    }
}

/// Flat "Worked for X" row used by the window chat table. Mirrors the
/// notch `TurnDurationView`'s header (✻ + duration + chevron) but does
/// NOT nest children — the table renders the turn's steps as separate
/// rows, shown/hidden by `TurnCollapsePlanner` via `TurnExpansionStore`.
struct CollapsibleTurnHeader: View {
    let seconds: Int
    let childCount: Int
    let isExpanded: Bool
    /// Number of work steps folded under this turn. Drives the
    /// chevron's presence; the visible label prefers `activityLabel`.
    let stepCount: Int
    /// Content-aware summary of the turn's work ("Edited 3 files · Ran 1
    /// command"). Empty for the live turn (counts still settling) or when
    /// nothing categorized — falls back to "N steps".
    let activityLabel: String
    /// True when a folded step errored/was interrupted — surfaces a
    /// warning glyph so a mid-turn failure isn't hidden by the collapse.
    let hasError: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    /// True for the in-progress turn (synthetic sentinel duration): show
    /// "Working…" + a live spinner instead of an elapsed time.
    private var isLive: Bool { seconds == ClaudeLiveTurnSentinel.seconds }
    private var hasChildren: Bool { childCount > 0 }
    /// Above this, the `turn_duration` is dominated by approval/idle wait
    /// rather than work, so we hide it (the step count carries the signal).
    private let durationDisplayCap = 600 // 10 minutes

    private var formatted: String {
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        return "\(seconds)s"
    }

    /// Primary label color: the live turn reads as "active" (brand mauve),
    /// a completed turn stays quiet (tertiary) until hovered.
    private var labelColor: Color {
        if isLive { return Catppuccin.mauve }
        return isHovered ? ChatTheme.secondary : ChatTheme.tertiary
    }

    var body: some View {
        Button {
            if hasChildren { onToggle() }
        } label: {
            HStack(spacing: 7) {
                leadingGlyph

                Text(isLive ? "Working…" : "Worked")
                    .chatScaledFont(size: 11, weight: .medium)
                    .foregroundColor(labelColor)

                // Content-aware summary ("Edited 3 files · Ran 1 command")
                // — the high-signal part. Falls back to a bare step count
                // when nothing categorized. Hidden for the live turn while
                // counts are still settling (the spinner already says
                // "active").
                if !isLive, !activityLabel.isEmpty {
                    Text("·")
                        .chatScaledFont(size: 11)
                        .foregroundColor(ChatTheme.tertiary.opacity(0.6))
                    Text(activityLabel)
                        .chatScaledFont(size: 11)
                        .foregroundColor(isHovered ? ChatTheme.secondary : ChatTheme.tertiary)
                        .lineLimit(1)
                } else if isLive, stepCount > 0 {
                    Text("\(stepCount) step\(stepCount == 1 ? "" : "s")")
                        .chatScaledFont(size: 10, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Catppuccin.surface1.opacity(isHovered ? 0.9 : 0.55))
                        )
                }

                // Duration as a quiet trailing detail — only when it's a
                // plausible per-turn work time. A turn that sat waiting on
                // an approval can log tens of minutes of wall-clock; showing
                // "107m" there is noise, so suppress it past the threshold.
                if !isLive, seconds >= 1, seconds <= durationDisplayCap {
                    Text(formatted)
                        .chatScaledFont(size: 10, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary.opacity(0.8))
                }

                if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Catppuccin.red)
                }

                if hasChildren {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ChatTheme.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(chipFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(chipStroke, lineWidth: 0.75)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasChildren)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }

    /// Brand sparkle for a finished turn; an animated spinner while live.
    @ViewBuilder
    private var leadingGlyph: some View {
        if isLive {
            TurnWorkingSpinner()
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? Catppuccin.mauve : ChatTheme.tertiary)
        }
    }

    /// Live turn gets a faint mauve wash so the in-progress group stands
    /// out. A finished, collapsed turn carries a quiet always-on surface
    /// fill so it reads as a distinct "hidden work" container (not loose
    /// prose); hover brightens it. Once expanded, the header recedes to
    /// transparent so it reads as a section label above its visible steps.
    private var chipFill: Color {
        if isLive { return Catppuccin.mauve.opacity(0.10) }
        if isExpanded { return isHovered ? Catppuccin.surface0.opacity(0.5) : Color.clear }
        return Catppuccin.surface0.opacity(isHovered ? 0.85 : 0.5)
    }

    private var chipStroke: Color {
        if isLive { return Catppuccin.mauve.opacity(0.30) }
        if isExpanded { return Color.clear }
        return isHovered ? Catppuccin.surface1 : Catppuccin.surface1.opacity(0.6)
    }
}

/// Small indeterminate spinner for the live "Working…" turn header.
/// Display-rate `TimelineView` rotation (not a `.onAppear`
/// `repeatForever`, which re-arms badly inside the chat table's
/// per-cell hosting + animating LazyVStack — see SessionStatusDot's
/// note). Kept tiny so it reads as a status glyph, not a control.
private struct TurnWorkingSpinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 1.0)) * 360
            Image(systemName: "rays")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Catppuccin.mauve)
                .rotationEffect(.degrees(angle))
        }
    }
}

// MARK: - Proxy

/// Hands the host view (`WindowChatView`) a stable handle to the
/// coordinator without leaking the NSView.
@MainActor
final class ChatTableProxy {
    weak var coordinator: ChatTableView.Coordinator?

    init(coordinator: ChatTableView.Coordinator) {
        self.coordinator = coordinator
    }

    func scrollToBottom() {
        coordinator?.scrollToBottom()
    }

    /// Like `scrollToBottom()`, but no-ops if the user has scrolled
    /// noticeably up from the document bottom. Used for ambient
    /// re-pin events (composer height change, gesture-end re-pin)
    /// where yanking the chat down out from under a user reading
    /// older context would be hostile.
    func scrollToBottomIfNearBottom() {
        coordinator?.scrollToBottomIfNearBottom()
    }

    /// Scroll up by one line (~22pt). Used by fn+↑ / arrow-up.
    func scrollLineUp() { coordinator?.scrollBy(points: -22) }
    /// Scroll down by one line (~22pt). Used by fn+↓ / arrow-down.
    func scrollLineDown() { coordinator?.scrollBy(points: 22) }
    /// Scroll up by one page (visible-viewport-height minus a little
    /// overlap so the user keeps a line of context across pages).
    func scrollPageUp() {
        guard let h = coordinator?.visibleHeight else { return }
        coordinator?.scrollBy(points: -(h - 40))
    }
    /// Scroll down by one page.
    func scrollPageDown() {
        guard let h = coordinator?.visibleHeight else { return }
        coordinator?.scrollBy(points: h - 40)
    }
    /// Jump to the top of the document.
    func scrollToTop() { coordinator?.scrollToTop() }

    /// Invalidate every cached row height and re-run the document
    /// view's vertical layout. Used by zoom (Cmd-+/-/0): SwiftUI
    /// re-renders cell content at the new font size, but the
    /// document view caches per-row frames keyed off the OLD
    /// `sizeThatFits` measurement. Without this nudge, the next
    /// layout pass reuses stale heights and rows overlap or leave
    /// gaps until the user switches sessions (which rebuilds the
    /// whole table).
    func invalidateRowHeights() {
        coordinator?.invalidateRowHeights()
    }

    /// Subscribe to "is the user near the top?" notifications. The
    /// callback fires ONLY when the boolean flips (not on every
    /// scroll tick) so it's safe to wire to a SwiftUI @State without
    /// stuttering scroll. Used by the host view to gate visibility
    /// of the "Load N earlier messages" button.
    func observeNearTop(_ handler: @escaping (Bool) -> Void) {
        coordinator?.nearTopChanged = handler
        // Push current value immediately so the host renders the
        // correct initial state.
        if let coordinator {
            handler(coordinator.distanceFromTop < 200)
        }
    }
}
