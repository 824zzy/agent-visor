//
//  SelectionColorOverride.swift
//  AgentVisor
//
//  Replaces the system selection-background color used by AppKit text views
//  (and SwiftUI's Text(AttributedString) with .textSelection(.enabled), which
//  hands off to AppKit text rendering on macOS) with a Catppuccin-friendly
//  muted gray-blue. The default `NSColor.selectedTextBackgroundColor` is the
//  bright system accent, which is too high-contrast against dark text and
//  washes out the selected content. This swap is process-wide.
//

import AppKit
import ObjectiveC.runtime
import SwiftUI

enum SelectionColorOverride {
    /// Install once. Idempotent.
    static func install() {
        guard !installed else { return }
        installed = true

        let cls: AnyClass = object_getClass(NSColor.self)!  // metaclass for class methods
        let originalSelector = NSSelectorFromString("selectedTextBackgroundColor")
        let swizzledSelector = #selector(NSColor.av_selectedTextBackgroundColor)

        guard let original = class_getClassMethod(NSColor.self, originalSelector),
              let swizzled = class_getClassMethod(NSColor.self, swizzledSelector) else {
            return
        }

        // Try to add first (in case the metaclass doesn't have its own copy),
        // otherwise exchange implementations.
        let didAdd = class_addMethod(cls,
                                     originalSelector,
                                     method_getImplementation(swizzled),
                                     method_getTypeEncoding(swizzled))
        if didAdd {
            class_replaceMethod(cls,
                                swizzledSelector,
                                method_getImplementation(original),
                                method_getTypeEncoding(original))
        } else {
            method_exchangeImplementations(original, swizzled)
        }
    }

    private static var installed = false
}

extension NSColor {
    /// Active Catppuccin flavor's `overlay2` at 25% alpha. Matches the
    /// style guide's "Selection Background" role (Overlay 2 at 20-30%
    /// opacity). Reads `AppSettings.appearance` directly rather than
    /// going through `AppearanceSelector.shared` because AppKit's text
    /// layout calls this off the main thread, and the selector is
    /// `@MainActor`. `AppSettings` wraps UserDefaults, which is
    /// thread-safe.
    @objc class func av_selectedTextBackgroundColor() -> NSColor {
        return NSColor(CatppuccinPalette.active.overlay2).withAlphaComponent(0.25)
    }
}
