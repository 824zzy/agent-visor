import AppKit
import SwiftUI

/// A custom floating scroll indicator that overlays an `NSScrollView`
/// without using `NSScroller` at all.
///
/// ## Why not subclass NSScroller?
///
/// Two earlier attempts subclassed NSScroller:
///   1. AppKit's `rect(for: .knob)` honors a built-in slot width tied
///      to the default scroller dimensions, ignoring custom
///      `scrollerWidth(for:scrollerStyle:)` overrides. The knob ended
///      up clipped to a narrow strip on one edge of our wider gutter.
///   2. NSScroller's overlay/legacy modes have opaque internal
///      rendering paths that can paint a system slot under our knob,
///      and switch between styles based on user system prefs.
///
/// Both routes produced visually wrong shapes: rectangular, mis-aligned,
/// or clipped knobs. This implementation sidesteps NSScroller entirely
/// — we hide the system scroller and draw our own pill as an overlay
/// subview that floats over the scroll content.
///
/// ## Geometry
///
///   ┌─ NSScrollView ──────────────────┐
///   │ content + clip view             │
///   │ ┌─────────────────────────┐ ◀▶ track gutter (transparent at rest)
///   │ │                         │ ┃ │
///   │ │   document              │ ┃ │  ┃ = pill knob (rounded capsule)
///   │ │                         │ ┃ │
///   │ └─────────────────────────┘   │
///   └─────────────────────────────────┘
///
/// The pill is centered horizontally in a thin gutter on the right
/// edge. Its height tracks the visible/document ratio. Its Y position
/// tracks scroll position. Both update on every clip view bounds
/// change.
final class FloatingScrollIndicator: NSView {
    /// Hover state. Brightens the knob and shows the track tint.
    private var isHovering: Bool = false {
        didSet {
            guard oldValue != isHovering else { return }
            needsDisplay = true
        }
    }
    /// Track is the full vertical column. Knob is a sub-rect inside
    /// it. We compute the knob rect on every redraw based on the
    /// owning scroll view's metrics.
    private weak var owningScrollView: NSScrollView?
    private var hoverTracking: NSTrackingArea?

    /// Visible thickness of the pill. Wide enough to be a clear hover
    /// target and to make the rounded ends read.
    static let knobThickness: CGFloat = 6
    /// Width of the gutter (clickable hover zone). Wider than the
    /// pill so users have margin around it.
    static let gutterWidth: CGFloat = 12
    /// Inset from the top, bottom, and right edges of the scroll
    /// view's bounds. Keeps the pill from butting up against window
    /// chrome.
    private static let edgeInset: CGFloat = 4
    /// Floor on knob length: even a tiny overflow shows a knob that's
    /// long enough to read as a pill. No upper cap — the knob length
    /// IS the visible/total ratio, which is the user-facing meaning of
    /// a scroll indicator. (A short pill on a near-fitting document
    /// would lie about how much content is hidden.)
    private static let minKnobLength: CGFloat = 32

    init(scrollView: NSScrollView) {
        self.owningScrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        autoresizingMask = []  // we'll explicitly position
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    /// Reposition self inside the scroll view's bounds.
    func reposition() {
        guard let scroll = owningScrollView else { return }
        let bounds = scroll.bounds
        let inset = Self.edgeInset
        let frame = NSRect(
            x: bounds.maxX - Self.gutterWidth - inset,
            y: inset,
            width: Self.gutterWidth,
            height: bounds.height - inset * 2
        )
        if self.frame != frame {
            self.frame = frame
        }
        needsDisplay = true
    }

    /// Compute the knob rect in our local coordinate space, or nil
    /// if there's nothing to scroll.
    private func computeKnobRect() -> NSRect? {
        guard let scroll = owningScrollView,
              let docView = scroll.documentView else { return nil }
        let trackHeight = bounds.height
        let visibleHeight = scroll.contentView.bounds.height
        let docHeight = docView.bounds.height
        guard docHeight > 0, visibleHeight > 0, trackHeight > 0 else {
            return nil
        }
        // No overflow → no knob.
        guard docHeight > visibleHeight + 1 else { return nil }

        let proportion = max(0, min(1, visibleHeight / docHeight))
        let proportionalLength = trackHeight * proportion
        let knobLength = max(Self.minKnobLength, proportionalLength)

        let scrollableDistance = max(0, docHeight - visibleHeight)
        let scrolled = max(0, scroll.contentView.bounds.origin.y)
        let scrollFraction = scrollableDistance > 0
            ? min(1, scrolled / scrollableDistance)
            : 0
        let availableTravel = max(0, trackHeight - knobLength)
        let knobY = availableTravel * scrollFraction

        let thickness = Self.knobThickness
        let knobX = (bounds.width - thickness) / 2
        return NSRect(x: knobX, y: knobY, width: thickness, height: knobLength)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let knobRect = computeKnobRect() else { return }

        // Optional: faint track tint on hover, so the user has a
        // visible hover affordance beyond just the knob brightness.
        if isHovering {
            let trackInset = bounds.insetBy(dx: 3, dy: 0)
            let trackPath = NSBezierPath(
                roundedRect: trackInset,
                xRadius: 3, yRadius: 3
            )
            NSColor(white: 0.5, alpha: 0.10).setFill()
            trackPath.fill()
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat
        let white: CGFloat
        switch (isDark, isHovering) {
        case (true, false):  white = 1.0; alpha = 0.30
        case (true, true):   white = 1.0; alpha = 0.65
        case (false, false): white = 0.0; alpha = 0.30
        case (false, true):  white = 0.0; alpha = 0.55
        }
        let radius = knobRect.width / 2  // exactly capsule end
        let path = NSBezierPath(
            roundedRect: knobRect,
            xRadius: radius, yRadius: radius
        )
        NSColor(white: white, alpha: alpha).setFill()
        path.fill()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// Hit-test forwards through to the document EXCEPT when the
    /// pointer is on the knob itself. That way clicks on the chat
    /// content still select text and clicks on the knob start a
    /// scroll drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let knob = computeKnobRect() else { return nil }
        // Inflate the knob hit area horizontally so it's easy to
        // grab — full gutter width is fine.
        let hit = NSRect(x: 0, y: knob.minY, width: bounds.width, height: knob.height)
        return hit.contains(local) ? self : nil
    }

    // MARK: - Drag to scroll

    /// Y-offset (in our local coords) of the click within the knob,
    /// so the knob doesn't jump under the cursor on drag start.
    private var dragGrabOffset: CGFloat = 0
    private var isDragging: Bool = false

    override func mouseDown(with event: NSEvent) {
        guard let knob = computeKnobRect() else { return }
        let local = convert(event.locationInWindow, from: nil)
        if knob.contains(local) {
            // Drag from where we grabbed: keep the offset between
            // mouse and knob top constant.
            dragGrabOffset = local.y - knob.minY
            isDragging = true
            isHovering = true
        } else {
            // Page jump: clicking the track above/below the knob
            // scrolls one viewport in that direction.
            pageScroll(towards: local.y < knob.minY ? -1 : 1)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging,
              let scroll = owningScrollView,
              let docView = scroll.documentView else { return }
        let local = convert(event.locationInWindow, from: nil)
        let trackHeight = bounds.height
        let visibleHeight = scroll.contentView.bounds.height
        let docHeight = docView.bounds.height
        guard docHeight > visibleHeight else { return }

        guard let knob = computeKnobRect() else { return }
        let knobHeight = knob.height
        let availableTravel = max(1, trackHeight - knobHeight)
        let proposedKnobTop = max(0, min(availableTravel, local.y - dragGrabOffset))
        let scrollFraction = proposedKnobTop / availableTravel
        let scrollableDistance = max(0, docHeight - visibleHeight)
        let targetY = scrollableDistance * scrollFraction
        scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scroll.reflectScrolledClipView(scroll.contentView)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        // Recompute hover from current pointer position.
        let local = convert(event.locationInWindow, from: nil)
        isHovering = bounds.contains(local)
    }

    private func pageScroll(towards direction: CGFloat) {
        guard let scroll = owningScrollView else { return }
        let visibleHeight = scroll.contentView.bounds.height
        let delta = visibleHeight * direction
        let current = scroll.contentView.bounds.origin.y
        let target = max(0, current + delta)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

// MARK: - Install / track

/// Owner that installs a `FloatingScrollIndicator` over an
/// `NSScrollView` and keeps it in sync with bounds changes and live
/// scrolling.
@MainActor
final class FloatingScrollerInstaller: NSObject {
    private weak var scrollView: NSScrollView?
    private weak var indicator: FloatingScrollIndicator?
    private var observers: [NSObjectProtocol] = []

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init()

        // Hide the system scroller every way we can. SwiftUI's
        // ScrollView is aggressive about reasserting its own scroller
        // config; both `hasVerticalScroller=false` and a transparent
        // `verticalScroller` together actually keep the system from
        // painting.
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.alphaValue = 0
        scrollView.verticalScroller?.isHidden = true

        let indicator = FloatingScrollIndicator(scrollView: scrollView)
        // Install as a subview at the highest z-order so it floats
        // over the document. The scroll view's own subviews are the
        // clip view and (formerly) the scroller; appending our
        // indicator after them keeps it on top during hit-testing
        // and drawing.
        scrollView.addSubview(indicator, positioned: .above, relativeTo: nil)
        self.indicator = indicator
        indicator.reposition()

        // Re-assert hidden state on every frame change, since
        // SwiftUI's ScrollView re-applies its scroller config on
        // every layout pass.
        scrollView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak scrollView] _ in
            scrollView?.hasVerticalScroller = false
            scrollView?.verticalScroller?.alphaValue = 0
            scrollView?.verticalScroller?.isHidden = true
        })

        // Track scroll position changes (live scrolling).
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak indicator] _ in
            indicator?.needsDisplay = true
        })

        // Track scroll-view resize.
        scrollView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak indicator] _ in
            indicator?.reposition()
        })

        // Track document-view height changes (e.g. content streaming).
        if let doc = scrollView.documentView {
            doc.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: doc,
                queue: .main
            ) { [weak indicator] _ in
                indicator?.needsDisplay = true
            })
        }
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - Public API

/// Per-NSScrollView installer registry. Keyed by ObjectIdentifier so
/// we don't double-install on the same scroll view.
@MainActor
private var installerRegistry: [ObjectIdentifier: FloatingScrollerInstaller] = [:]

enum DimmedScroller {
    /// Install the floating indicator on `scrollView`. Idempotent.
    @MainActor
    static func install(on scrollView: NSScrollView) {
        let key = ObjectIdentifier(scrollView)
        guard installerRegistry[key] == nil else { return }
        installerRegistry[key] = FloatingScrollerInstaller(scrollView: scrollView)
    }
}

// MARK: - SwiftUI bridge

struct DimmedScrollerInjector: NSViewRepresentable {
    func makeNSView(context: Context) -> InjectorView {
        InjectorView()
    }

    func updateNSView(_ nsView: InjectorView, context: Context) {
        nsView.installIfNeeded()
    }

    final class InjectorView: NSView {
        private var didInstall = false
        private var retriesLeft = 12

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installIfNeeded()
        }

        override func layout() {
            super.layout()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard !didInstall else { return }
            if let scroll = locateScrollView() {
                DimmedScroller.install(on: scroll)
                didInstall = true
                return
            }
            guard retriesLeft > 0 else { return }
            retriesLeft -= 1
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        private func locateScrollView() -> NSScrollView? {
            var cur: NSView? = superview
            while let v = cur {
                if let scroll = v as? NSScrollView { return scroll }
                cur = v.superview
            }
            guard let root = window?.contentView else { return nil }
            let originInRoot = convert(NSPoint.zero, to: root)
            var found: NSScrollView?
            var bestArea: CGFloat = .greatestFiniteMagnitude
            descend(root) { v in
                guard let scroll = v as? NSScrollView else { return }
                let frameInRoot = scroll.convert(scroll.bounds, to: root)
                guard frameInRoot.contains(originInRoot) else { return }
                let area = frameInRoot.width * frameInRoot.height
                if area < bestArea {
                    bestArea = area
                    found = scroll
                }
            }
            return found
        }

        private func descend(_ view: NSView, _ visit: (NSView) -> Void) {
            visit(view)
            for sub in view.subviews { descend(sub, visit) }
        }
    }
}

extension View {
    func dimmedScroller() -> some View {
        background(DimmedScrollerInjector().frame(width: 0, height: 0))
    }
}
