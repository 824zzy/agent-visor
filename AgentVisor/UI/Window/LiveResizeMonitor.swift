//
//  LiveResizeMonitor.swift
//  AgentVisor
//
//  Window-level live-resize signal so heavy SwiftUI subtrees
//  (LazyVStack-backed chat lists) can detach during a drag. Without
//  this gate, the LazyVStack pumps `LazySubviewPlacements.placeSubviews`
//  → `LazyHVStack.lengthAndSpacing` → `UnaryLayoutEngine.sizeThatFits`
//  recursively over every realized row at NSWindow resize tracker
//  rate (60-120 events/sec). On a 154k-row session sample showed
//  100% CPU pin, 1.3 GB RSS, app freezes for the entire drag.
//
//  Strategy: the chat container binds on `isLiveResizing` and swaps
//  to a thin VStack-of-tail-rows view while a drag is in progress.
//  No LazyVStack means O(visible-tail-rows) layout per tick instead
//  of O(pagination-cap). After `didEndLiveResize`, the flag drops
//  and the real chat re-mounts in a single layout pass at the
//  released size. The user sees the most-recent messages during the
//  drag — the part they care about — and the full scroll-back
//  appears the moment they let go.
//

import AppKit
import Combine
import Foundation

@MainActor
final class LiveResizeMonitor: ObservableObject {
    static let shared = LiveResizeMonitor()

    /// True between AppKit's `willStartLiveResize` and
    /// `didEndLiveResize` notifications.
    @Published private(set) var isLiveResizing: Bool = false

    private var observers: [NSObjectProtocol] = []

    /// `NSSplitView` divider drags are NOT NSWindow live-resize
    /// events — they fire `_doConstraintBasedPresentDividerDragResult:`
    /// directly without `willStartLiveResizeNotification`. We track
    /// the divider drag separately by hooking the `NSSplitView`
    /// notifications and OR-merge with window-resize state.
    @Published private(set) var isSplitterResizing: Bool = false

    /// True when EITHER the window edge is being dragged OR a split
    /// view divider is. Either case triggers the same LazyVStack
    /// relayout cascade, so the chat collapses to its placeholder
    /// for both.
    var isResizing: Bool { isLiveResizing || isSplitterResizing }

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLiveResizing = true
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLiveResizing = false
            }
        })
        // NSSplitView posts its own willResize / didResize
        // notifications on each subview-resize event during a
        // divider drag. AppKit also fires `willStartLiveResize` on
        // the split view itself (NOT the window) — listening for
        // that gives us a clean willStart/didEnd pair without
        // tracking individual mouse moves.
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in /* discard, only here so the observer set isn't empty if Apple changes the API */ })
        observers.append(center.addObserver(
            forName: NSSplitView.willResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSplitterResizing = true
            }
        })
        observers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification fires on every drag tick (mouseMoved),
            // not just at gesture-end. Defer the "no longer resizing"
            // flip to the next runloop tick — if another willResize
            // fires within that window we're still mid-drag, so we
            // keep the placeholder up. This matches AppKit's own
            // NSWindow.didEndLiveResize semantics (one event at gesture
            // release, not per-tick).
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let stamp = self.splitterResizeStamp &+ 1
                self.splitterResizeStamp = stamp
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if self.splitterResizeStamp == stamp {
                        self.isSplitterResizing = false
                    }
                }
            }
        })
    }

    private var splitterResizeStamp: UInt64 = 0

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
