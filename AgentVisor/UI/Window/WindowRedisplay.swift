//
//  WindowRedisplay.swift
//  AgentVisor
//
//  Forces an immediate, complete redraw of every view in `window`.
//  Three things in order, because each handles a different layer-cache
//  surface that NSHostingView leaves stale on a `display: false`
//  initial layout:
//
//  - Walk the view tree and assign `layer.contentsScale = backingScale`
//    (and the same on every sublayer — NSHostingView creates nested
//    layers lazily as SwiftUI renders text).
//  - Mark every view dirty so AppKit doesn't short-circuit display
//    when nothing's flagged.
//  - `window.display()` synchronously redraws the whole hierarchy,
//    which is what an interactive resize does when the user drags
//    the corner — that's the path observed actually fixing the
//    blurry first paint.
//
//  Used by `PillsStripWindowController` to drive scale-walk + redraw
//  on the strip panel from window-level notifications
//  (didChangeBackingProperties / didChangeScreen). Both notch surfaces
//  need the same protection: external-monitor reconfiguration mid-
//  session leaves layers rasterized at the old `contentsScale`, and a
//  click anywhere fixes it because that's what forces the redraw this
//  function does deterministically.
//

import AppKit

func forceWindowRedisplay(_ window: NSWindow) {
    let scale = window.backingScaleFactor
    func walk(_ view: NSView) {
        if let layer = view.layer {
            applyScale(scale, to: layer)
        }
        view.needsDisplay = true
        for sub in view.subviews { walk(sub) }
    }
    func applyScale(_ scale: CGFloat, to layer: CALayer) {
        if layer.contentsScale != scale { layer.contentsScale = scale }
        for sub in layer.sublayers ?? [] { applyScale(scale, to: sub) }
    }
    if let root = window.contentView { walk(root) }
    window.viewsNeedDisplay = true
    window.display()
}
