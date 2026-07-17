//
//  ChatScrollBridge.swift
//  AgentVisor
//
//  Holds weak references to the underlying NSScrollView for each chat
//  session, populated by ChatScrollBridgeRegistrar once it walks up to
//  find the enclosing scroll view. Consumed by the PgUp/PgDn keyboard
//  monitor and the "already at bottom?" check in the auto-scroll path.
//

import AppKit

@MainActor
final class ChatScrollBridge {
    static let shared = ChatScrollBridge()

    private var refs: [String: WeakScrollView] = [:]

    private init() {}

    func register(sessionId: String, scrollView: NSScrollView) {
        refs[sessionId] = WeakScrollView(value: scrollView)
    }

    func unregister(sessionId: String) {
        refs.removeValue(forKey: sessionId)
    }

    func contentOffsetY(sessionId: String) -> CGFloat? {
        refs[sessionId]?.value?.contentView.bounds.origin.y
    }

    /// Scroll the registered NSScrollView by `delta` points along Y, optionally
    /// animated. The chat is rendered with `.scaleEffect(y: -1)` so the
    /// underlying NSScrollView's `contentOffset.y = 0` corresponds to the
    /// visual *bottom* of the chat (newest message). Increasing y reveals
    /// older messages; decreasing y returns toward the newest. Callers map
    /// the visual intent (PgUp = older = +delta, PgDn = newer = -delta).
    /// Clamps to the document bounds.
    func scroll(sessionId: String, byY delta: CGFloat, animated: Bool) {
        guard let scrollView = refs[sessionId]?.value else { return }
        let viewport = scrollView.contentView.bounds.height
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, docHeight - viewport)
        let current = scrollView.contentView.bounds.origin.y
        let target = max(0, min(maxY, current + delta))
        guard abs(target - current) > 0.5 else { return }
        let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: target)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(point)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Roughly one third of the visible chat viewport. Three presses of
    /// PgUp/PgDn cover one full screen, which feels closer to a sustained
    /// trackpad swipe than a hard one-page jump.
    func pageScrollDelta(sessionId: String) -> CGFloat {
        guard let scrollView = refs[sessionId]?.value else { return 200 }
        return max(120, scrollView.contentView.bounds.height / 3)
    }
}

private final class WeakScrollView {
    weak var value: NSScrollView?
    init(value: NSScrollView) { self.value = value }
}
