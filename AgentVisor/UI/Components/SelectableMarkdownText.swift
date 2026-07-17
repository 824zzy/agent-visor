//
//  SelectableMarkdownText.swift
//  AgentVisor
//
//  NSTextView-backed replacement for `MarkdownPiecesText` that gives
//  the chat bubble native AppKit text selection without the SwiftUI
//  `.textSelection(.enabled)` cascade.
//
//  Why not SwiftUI textSelection: SwiftUI's Text+textSelection wraps
//  every `Text(AttributedString)` in an NSTextField+SelectionOverlay
//  pair under the hood. NSTextField has constraint-based intrinsic
//  size; when SwiftUI graph dirties (any scroll tick, streamTick
//  bump, session-meta refresh, etc.) SelectionOverlay's updateNSView
//  re-runs `setFont:` on every visible NSTextField → fires
//  `invalidateIntrinsicContentSize` → posts
//  `_postWindowNeedsUpdateConstraints`, which dirties the graph
//  again. Sample-confirmed feedback loop pinning the main thread at
//  100% CPU + 800MB+ RSS during scroll on big sessions
//  (2026-05-30). Hoisting the modifier to a single LazyVStack
//  reduces the storm but doesn't kill it.
//
//  NSTextView, by contrast, owns its own NSLayoutManager /
//  NSTextStorage stack. Its intrinsic-size invalidations don't feed
//  back through the SwiftUI graph because we (a) eagerly compute the
//  fitted size in `updateNSView` and report it via SwiftUI's
//  `sizeThatFits`, and (b) `isVerticallyResizable = true` lets
//  AppKit-internal layout settle without re-asking SwiftUI. Selection,
//  copy (Cmd+C), and right-click → Copy all work natively.
//
//  Caveats:
//  - NSTextView doesn't support inline NSImage as a Text(Image) piece
//    the way `Text(Image(nsImage:))` does. We resolve that here by
//    wrapping each `.image` piece in an `NSTextAttachment` and
//    appending it into the layout manager's text storage. The math
//    rendering pipeline already produces correctly-baselined raster
//    images, so this is a 1-line conversion.
//  - We trade the SwiftUI graph cascade for one NSTextView per
//    bubble. Big — but each NSTextView's per-frame layout is
//    self-contained, doesn't propagate dirty into parent SwiftUI
//    graph, and is what every native macOS chat app uses.
//

import AppKit
import SwiftUI

struct SelectableMarkdownText: NSViewRepresentable {
    let pieces: [MarkdownInlinePiece]
    /// Line spacing baked into the SwiftUI rendering path
    /// (`.lineSpacing(4)` on MarkdownPiecesText). Mirroring it here
    /// keeps the chat layout visually identical to the prior version.
    let lineSpacing: CGFloat

    init(pieces: [MarkdownInlinePiece], lineSpacing: CGFloat = 4) {
        self.pieces = pieces
        self.lineSpacing = lineSpacing
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Per-instance cache. SwiftUI calls `updateNSView` and
    /// `sizeThatFits` on every layout pass — 60-120Hz during
    /// NSSplitView divider drags or window resize. Without aggressive
    /// caching, every tick re-runs `setAttributedString` and
    /// `ensureLayout` on the NSTextView's layout manager, which is
    /// the dominant cost in `LazySubviewPlacements.placeSubviews`
    /// → `sizeThatFits`. Coordinator memoizes:
    ///   - assembled NSAttributedString by content fingerprint
    ///   - measured height by (fingerprint, width) — so identical
    ///     queries during a layout-pass storm are O(1) lookups.
    final class Coordinator {
        var lastFingerprint: String = ""
        var cachedAttrString: NSAttributedString?
        var lastAppliedWidth: CGFloat = -1
        /// Memoized height. SwiftUI calls `sizeThatFits` repeatedly
        /// at the same (pieces, width) during a single layout pass;
        /// returning a cached scalar instead of re-running the
        /// NSLayoutManager `ensureLayout` collapses the per-row
        /// cost from milliseconds to nanoseconds.
        var heightCacheKey: String = ""
        var heightCacheValue: CGFloat = 0
    }

    func makeNSView(context: Context) -> SelectableTextNSView {
        let view = SelectableTextNSView()
        view.setUp()
        return view
    }

    func updateNSView(_ nsView: SelectableTextNSView, context: Context) {
        let attrString = ensureAttrString(in: context.coordinator)
        let width = nsView.bounds.width > 0
            ? nsView.bounds.width
            : nsView.frame.width
        if width > 0, width != context.coordinator.lastAppliedWidth {
            nsView.applyAttributedString(attrString, width: width)
            context.coordinator.lastAppliedWidth = width
        } else if nsView.isEmpty {
            nsView.applyAttributedString(attrString, width: width)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextNSView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else {
            return nil
        }
        let coord = context.coordinator
        let attrString = ensureAttrString(in: coord)
        // Height cache: SwiftUI hammers `sizeThatFits` during resize
        // with the same (pieces, width). Return the cached scalar
        // without touching the NSLayoutManager.
        let cacheKey = "\(coord.lastFingerprint)|\(Int(width.rounded()))"
        if cacheKey == coord.heightCacheKey {
            return CGSize(width: width, height: coord.heightCacheValue)
        }
        if width != coord.lastAppliedWidth || nsView.isEmpty {
            nsView.applyAttributedString(attrString, width: width)
            coord.lastAppliedWidth = width
        }
        let h = nsView.measuredHeight(for: width)
        coord.heightCacheKey = cacheKey
        coord.heightCacheValue = h
        return CGSize(width: width, height: h)
    }

    /// Build (and cache) the assembled NSAttributedString. Cache
    /// key is a structural fingerprint over the pieces — SwiftUI
    /// re-creates the SelectableMarkdownText struct on every body
    /// pass, but during a drag the pieces don't change, so we hit
    /// the cache and skip the expensive `setAttributedString`.
    private func ensureAttrString(in coord: Coordinator) -> NSAttributedString {
        let fp = Self.fingerprint(pieces: pieces, lineSpacing: lineSpacing)
        if coord.lastFingerprint == fp, let cached = coord.cachedAttrString {
            return cached
        }
        let assembled = Self.assemble(pieces: pieces, lineSpacing: lineSpacing)
        coord.lastFingerprint = fp
        coord.cachedAttrString = assembled
        // Pieces changed → invalidate height memo too.
        coord.heightCacheKey = ""
        coord.heightCacheValue = 0
        return assembled
    }

    /// Lightweight content-derived key. Counts + per-piece
    /// (kind, length) avoid touching the AttributedString heavy
    /// internals while still detecting any meaningful change in
    /// the pieces. Cheap enough to call on every drag tick.
    private static func fingerprint(pieces: [MarkdownInlinePiece], lineSpacing: CGFloat) -> String {
        var s = "\(lineSpacing)|"
        s.reserveCapacity(pieces.count * 8)
        for piece in pieces {
            switch piece {
            case .text(let attr):
                s.append("t")
                s.append(String(attr.characters.count))
            case .image(let img):
                s.append("i")
                s.append(String(Int(img.size.width)))
                s.append("x")
                s.append(String(Int(img.size.height)))
            }
            s.append(",")
        }
        return s
    }

    /// Concatenate the inline pieces into a single NSAttributedString.
    /// Each piece's `asNSAttributedString` projection (defined on
    /// `MarkdownInlinePiece` in MarkdownRenderer.swift) handles the
    /// SwiftUI→AppKit attribute translation; the builder also writes
    /// AppKit-keyed attributes (`appKit.font`, `appKit.foregroundColor`,
    /// …) on every emitted run so the formatting is preserved.
    private static func assemble(
        pieces: [MarkdownInlinePiece],
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString()
        for piece in pieces {
            mutable.append(piece.asNSAttributedString)
        }
        // Apply line spacing as a paragraph attribute so wrapped
        // paragraphs match `MarkdownPiecesText.lineSpacing(4)`.
        if mutable.length > 0 {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = lineSpacing
            mutable.addAttribute(
                .paragraphStyle,
                value: para,
                range: NSRange(location: 0, length: mutable.length)
            )
        }
        return mutable
    }
}

/// NSTextView wrapper sized to fit its content at a given width. The
/// layout manager / text storage stack is created once and reused so
/// streaming-rate text updates don't churn AppKit object allocation.
///
/// CRITICAL — frame-based layout, NOT Auto Layout. NSTextView under
/// Auto Layout (with `widthTracksTextView=true` + intrinsic content
/// size) feeds intrinsic size invalidations back into the parent
/// NSHostingView's constraint solver. SwiftUI then re-runs layout,
/// which re-proposes a width to the NSTextView, which posts another
/// intrinsic-size invalidation, → recursive `_layoutSubtreeWithOldSize:`
/// 12+ levels deep → 100% CPU pin during window resize
/// (sample-confirmed 2026-05-30). Frame-based layout breaks the
/// feedback because the text container sizes itself once per
/// `applyAttributedString` call without the constraint round-trip.
/// NSTextView subclass that forwards scroll-wheel events up the
/// responder chain instead of consuming them. We host this view inline
/// (no enclosing NSScrollView), so AppKit's default "the text view
/// handles its own scroll" behavior turns into "scrolling stalls
/// whenever the cursor hovers over a chat bubble." Forwarding restores
/// the chat-list-wide scroll behavior the user expects.
private final class PassThroughScrollTextView: NSTextView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

final class SelectableTextNSView: NSView {
    private let textView: NSTextView = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // widthTracksTextView=false: we explicitly set container.size
        // in applyAttributedString. With it true, every parent frame
        // change retriggers layout via the NSTextView's autoresize
        // path, compounding with SwiftUI's own size proposals.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let tv = PassThroughScrollTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        // Frame-based: we explicitly set the frame in `layout()`.
        // No autoresize, no AL.
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.translatesAutoresizingMaskIntoConstraints = true
        tv.textContainerInset = .zero
        tv.allowsUndo = false
        tv.isRichText = true
        tv.usesFontPanel = false
        tv.isFieldEditor = false
        return tv
    }()

    var isEmpty: Bool {
        (textView.textStorage?.length ?? 0) == 0
    }

    /// The width the layout manager was last sized for. Skipping
    /// redundant container.size assignments here avoids the
    /// intrinsic-size invalidation that triggers AppKit's recursive
    /// layoutSubtreeWithOldSize cascade.
    private var lastAppliedWidth: CGFloat = -1

    func setUp() {
        translatesAutoresizingMaskIntoConstraints = true
        addSubview(textView)
    }

    override func layout() {
        super.layout()
        // Frame-based: NSTextView fills our bounds. Setting the frame
        // here (instead of via AL) means there's no constraint
        // round-trip when our bounds change — bounds change → frame
        // assigned → done.
        textView.frame = bounds
    }

    /// Replace the displayed attributed string. Cheap because we're
    /// editing the existing NSTextStorage in place.
    func applyAttributedString(_ attr: NSAttributedString, width: CGFloat) {
        let resolvedWidth = max(0, width)
        if resolvedWidth != lastAppliedWidth, let container = textView.textContainer {
            container.size = NSSize(width: resolvedWidth, height: .greatestFiniteMagnitude)
            lastAppliedWidth = resolvedWidth
        }
        textView.textStorage?.setAttributedString(attr)
    }

    /// Measure the fitted height for the given width.
    func measuredHeight(for width: CGFloat) -> CGFloat {
        guard let layout = textView.layoutManager,
              let container = textView.textContainer else {
            return 0
        }
        let resolvedWidth = max(0, width)
        if resolvedWidth != lastAppliedWidth {
            container.size = NSSize(width: resolvedWidth, height: .greatestFiniteMagnitude)
            lastAppliedWidth = resolvedWidth
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return ceil(used.height)
    }
}
