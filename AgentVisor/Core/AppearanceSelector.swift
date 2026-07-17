//
//  AppearanceSelector.swift
//  AgentVisor
//
//  Manages the System / Light / Dark appearance setting and propagates
//  the flavor change into SwiftUI. Source of truth is
//  `AppSettings.appearance`. Views that observe this object re-render
//  when `mode` (or the resolved system flavor) changes, which causes
//  downstream `ChatTheme.*` reads (which go through `Catppuccin.*` →
//  `CatppuccinPalette.active`) to return the new palette's tokens.
//

import AppKit
import Combine
import Foundation

@MainActor
final class AppearanceSelector: ObservableObject {
    static let shared = AppearanceSelector()

    /// Mirrors `AppSettings.appearance` so SwiftUI views can observe the
    /// flavor flip without polling. Writing here goes through `setMode`
    /// so persistence and side effects stay coupled.
    @Published var mode: AppearanceMode = AppSettings.appearance

    /// The OS-resolved flavor for `.system` mode, surfaced as a
    /// separate published value so a `@ObservedObject` view re-renders
    /// when the user toggles macOS-wide appearance even though `mode`
    /// stays `.system`. Concrete `.light` / `.dark` modes mirror their
    /// own value here for a unified `resolvedAppearance` reader.
    @Published var resolvedAppearance: ResolvedAppearance = AppSettings.appearance.resolved

    private var systemAppearanceObservation: NSKeyValueObservation?

    private init() {
        installSystemAppearanceObserver()
    }

    /// Currently-active palette. Equivalent to `CatppuccinPalette.active`
    /// — exposed here for callers that already have an
    /// `AppearanceSelector` reference handy.
    var palette: CatppuccinPalette { CatppuccinPalette.active }

    /// Persist a new mode, publish the change, and invalidate any
    /// caches whose contents bake in the old palette.
    func setMode(_ newMode: AppearanceMode) {
        guard newMode != mode else { return }
        // Persist before publishing so that any synchronous re-render
        // triggered by `@Published` already sees the new
        // `AppSettings.appearance`. `Catppuccin.*` reads UserDefaults
        // directly, so write order matters.
        AppSettings.appearance = newMode
        mode = newMode
        refreshResolved()
        // The Highlightr cache holds NSAttributedStrings with the old
        // flavor's NSColors baked in. Flush so the next render re-
        // highlights against the active palette.
        SyntaxHighlighterCache.shared.invalidate()
    }

    /// KVO `NSApp.effectiveAppearance` so users on `.system` mode see
    /// the app flip when macOS auto-switches at sunset. NSApplication
    /// publishes via KVO (it doesn't post a notification for this), so
    /// `observe(\.effectiveAppearance)` is the supported path.
    private func installSystemAppearanceObserver() {
        systemAppearanceObservation = NSApp?.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            // KVO can fire on any thread; bounce to main.
            DispatchQueue.main.async {
                self?.refreshResolved()
            }
        }
    }

    private func refreshResolved() {
        let next = mode.resolved
        guard next != resolvedAppearance else { return }
        resolvedAppearance = next
        SyntaxHighlighterCache.shared.invalidate()
    }
}
