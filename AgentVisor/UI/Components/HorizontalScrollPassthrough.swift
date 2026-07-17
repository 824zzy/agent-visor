//
//  HorizontalScrollPassthrough.swift
//  AgentVisor
//
//  An `NSScrollView`-backed horizontal scroll container that *forwards*
//  vertical wheel events up the responder chain. SwiftUI's
//  `ScrollView(.horizontal, …)` doesn't do this: it consumes any wheel
//  event whose hit-test landed on it, including pure-vertical scrolls,
//  so a markdown table embedded in the chat list will eat the user's
//  scroll if they happen to hover their cursor inside the table.
//
//  The rule we want — and that native macOS apps use — is "consume
//  only events whose dominant axis matches our scroll direction." A
//  trackpad two-finger swipe-up has a tiny horizontal component plus
//  a large vertical component; we want it to pass through.
//
//  AppKit's `NSScrollView` doesn't expose a flag for this, so we
//  subclass `scrollWheel(with:)` and forward when the vertical
//  component dominates.
//

import AppKit
import SwiftUI

struct HorizontalScrollPassthrough<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> ForwardingHorizontalScrollView {
        let scroll = ForwardingHorizontalScrollView()
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
        scroll.documentView = host
        scroll.contentView.postsBoundsChangedNotifications = false

        // Match the document view's height to the clip view's height so
        // SwiftUI lays out the table at its natural width (>= clip width
        // when overflowing).
        if let docView = scroll.documentView {
            NSLayoutConstraint.activate([
                docView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                docView.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
                docView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            ])
            docView.translatesAutoresizingMaskIntoConstraints = false
        }

        return scroll
    }

    func updateNSView(_ scroll: ForwardingHorizontalScrollView, context: Context) {
        if let host = scroll.documentView as? NSHostingView<Content> {
            host.rootView = content
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ForwardingHorizontalScrollView, context: Context) -> CGSize? {
        guard let host = nsView.documentView as? NSHostingView<Content> else { return nil }
        let proposed = NSSize(
            width: proposal.width ?? .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        let fitting = host.fittingSize
        // Width: clamp to proposed (so the scroll view is as wide as
        // the chat row gives us), height: take the document's natural
        // height (a single table row's height).
        let width = min(fitting.width, proposed.width)
        return CGSize(width: width, height: fitting.height)
    }
}

final class ForwardingHorizontalScrollView: NSScrollView {
    /// Forward wheel events whose dominant axis is vertical so the
    /// enclosing chat-list scroll view receives them. Native macOS
    /// behavior — Mail's message-with-table view, Xcode's organizer,
    /// etc. all treat vertical wheel-over-horizontal-list this way.
    override func scrollWheel(with event: NSEvent) {
        let absX = abs(event.scrollingDeltaX)
        let absY = abs(event.scrollingDeltaY)
        if absY > absX {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}
