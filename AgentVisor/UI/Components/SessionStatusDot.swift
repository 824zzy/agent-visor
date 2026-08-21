//
//  SessionStatusDot.swift
//  AgentVisor
//
//  Shared session-status indicator used by the left-side pill buttons and
//  the session-list rows in the notch. Keeps color and pulse behavior in
//  one place so the two surfaces can't drift apart.
//

import Foundation
import AgentVisorCore
import SwiftUI

// MARK: - Color scheme

/// Which palette the dot draws from.
///
/// `darkChrome` always uses Mocha. The pills sit in the macOS menu bar
/// against a dark capsule that doesn't theme, so a Latte-tinted dot
/// would have poor contrast there. `adaptive` follows the user's
/// chosen flavor, including menu-bar pills where the surface
/// colors flip with the theme.
enum DotColorScheme {
    case darkChrome
    case adaptive
}

// MARK: - Color

/// Color for a session's status indicator. For `waitingForInput`/`idle`,
/// fades from green toward the palette overlay over ~42 minutes using a
/// linear curve on `idleAge` (seconds since `session.lastActivity`).
/// Linear (not sqrt) because the sqrt variant concentrated the dim into
/// the first ~5 minutes, making a 1-minute-old session already read as
/// half-stale.
func sessionStatusColor(
    for phase: SessionPhase,
    idleAge: TimeInterval = 0,
    scheme: DotColorScheme = .adaptive
) -> Color {
    let palette: CatppuccinPalette = (scheme == .darkChrome) ? .mocha : .active
    let accessibleLight = scheme == .adaptive && AppSettings.appearance.resolved == .light
    switch phase {
    case .processing, .compacting:
        return accessibleLight
            ? Color(accessible: AccessibleLightPalette.statusRunning)
            : BrandColors.claudeOrange
    case .waitingForApproval:
        // BrandColors.statusYellow (not palette.yellow) — Catppuccin
        // Latte's #df8e1d "yellow" reads as orange on an 8pt dot,
        // making it indistinguishable from claudeOrange. We use a
        // brighter chromatic yellow specifically for this status
        // role. See BrandColors.statusYellow's docstring.
        return accessibleLight
            ? Color(accessible: AccessibleLightPalette.statusPending)
            : BrandColors.statusYellow
    case .waitingForInput, .idle:
        // Lerp from "fresh green" to "stale overlay gray" over the
        // ~42-minute idle window. Both endpoints come from the
        // active palette so the dot stays readable on its surface.
        let fresh = accessibleLight
            ? Color(accessible: AccessibleLightPalette.statusSuccess)
            : palette.green
        let stale = accessibleLight
            ? Color(accessible: AccessibleLightPalette.tertiaryText)
            : palette.overlay
        return fresh.mix(with: stale, by: min(1.0, max(0.0, idleAge / 2520)))
    case .ended:
        return palette.overlay.opacity(0.3)
    }
}

// MARK: - Color mixing helper

private extension Color {
    /// Linear interpolation between two SwiftUI Colors in sRGB. SwiftUI
    /// 16+ has `Color.mix(with:by:)` natively, but we rebuild it here
    /// against the older deployment targets used by this app.
    func mix(with other: Color, by t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB)
        let b = NSColor(other).usingColorSpace(.sRGB)
        guard let ac = a, let bc = b else { return self }
        let clamped = min(max(t, 0), 1)
        let r = ac.redComponent   + (bc.redComponent   - ac.redComponent)   * clamped
        let g = ac.greenComponent + (bc.greenComponent - ac.greenComponent) * clamped
        let bl = ac.blueComponent + (bc.blueComponent  - ac.blueComponent)  * clamped
        let al = ac.alphaComponent + (bc.alphaComponent - ac.alphaComponent) * clamped
        return Color(.sRGB, red: r, green: g, blue: bl, opacity: al)
    }
}

// MARK: - Dot View

/// Drop-in status dot used by pills and the notch session list.
///
/// The pulse is computed directly from `(context.date, session.phaseChangedAt)`
/// inside a display-rate `TimelineView` rather than driven by a
/// `withAnimation(...repeatForever...)` started in `.onAppear`. The
/// latter approach worked for the always-mounted menu-bar pill but
/// silently failed in the notch session list, which is re-mounted on
/// every hover: the `repeatForever` animation started from `.onAppear`
/// inside a `TimelineView` inside a `LazyVStack` inside an animating
/// window gets cancelled before it takes hold. Computing opacity as a
/// pure function of time sidesteps the whole lifecycle dance.
struct SessionStatusDot: View {
    let session: SessionState
    var diameter: CGFloat = 6
    /// Defaults to `.adaptive` (panel surfaces). Pill call sites pass
    /// `.darkChrome` so the dot stays readable on the always-dark
    /// menu-bar capsule.
    var colorScheme: DotColorScheme = .adaptive
    @ObservedObject private var navigationRecencyStore = SessionNavigationRecencyStore.shared

    /// Full pulse cycle duration. Matches the feel of the previous
    /// easeInOut-0.75s-autoreverses configuration (1.5s round trip).
    private static let pulsePeriod: TimeInterval = 1.5

    /// Minimum opacity at the bottom of the pulse curve. Same floor as
    /// the previous animation (0.35).
    private static let pulseMinOpacity: Double = 0.35

    /// Cap the pulse tick rate. A 1.5s cosine reads smoothly at 30fps, so
    /// there is no reason to relayout at a ProMotion panel's 120Hz refresh.
    private static let pulseFrameInterval: TimeInterval = 1.0 / 30.0

    /// Mount the animated timeline only for a fresh, unacknowledged
    /// completion. The common static path avoids display-rate updates
    /// across every visible session indicator.
    var body: some View {
        let acknowledgedAt = navigationRecencyStore.readyAcknowledgedAt(for: session)
        // Resolve the status color ONCE per body evaluation. It is constant
        // for the duration of a pulse (phase stays waitingForInput; idleAge
        // moves on the order of seconds), so it must NOT be re-resolved inside
        // the per-frame TimelineView closure — doing so re-ran NSColor
        // colorspace conversions every display refresh and pinned WindowServer
        // on ProMotion panels (sample-confirmed 2026-08-04). See
        // SessionState.statusIdleAge: fade off conversational recency, not the
        // mtime/default-driven lastActivity, so stale or empty GUI-spawned
        // sessions don't read as fresh green.
        let color = sessionStatusColor(
            for: session.phase,
            idleAge: session.statusIdleAge,
            scheme: colorScheme
        )
        if ReadyAttentionPolicy.shouldPulse(
            isReady: session.phase == .waitingForInput,
            phaseChangedAt: session.phaseChangedAt,
            acknowledgedAt: acknowledgedAt,
            now: Date()
        ) {
            // Throttle to `pulseFrameInterval` instead of the raw display
            // refresh, and animate only opacity (a cheap layer property) over
            // the precomputed color.
            TimelineView(.animation(minimumInterval: Self.pulseFrameInterval)) { context in
                dot(
                    color: color,
                    pulseOpacity: pulseOpacity(
                        at: context.date,
                        acknowledgedAt: acknowledgedAt
                    )
                )
            }
        } else {
            // Common case: phase is .processing / .idle / .ended / etc.
            // Drop the TimelineView so SwiftUI doesn't tick the dot at
            // display refresh for no benefit.
            dot(color: color, pulseOpacity: 1.0)
        }
    }

    private func dot(color: Color, pulseOpacity: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .opacity(pulseOpacity)
    }

    /// Current dot opacity. 1.0 unless the session just entered
    /// `waitingForInput` and is within the pulse window, in which case
    /// this returns a smooth cosine-shaped pulse between
    /// `pulseMinOpacity` and 1.0.
    private func pulseOpacity(at now: Date, acknowledgedAt: Date?) -> Double {
        guard ReadyAttentionPolicy.shouldPulse(
            isReady: session.phase == .waitingForInput,
            phaseChangedAt: session.phaseChangedAt,
            acknowledgedAt: acknowledgedAt,
            now: now
        ) else {
            return 1.0
        }
        // `0.5 + 0.5 * cos(...)` (not `0.5 - 0.5 * cos(...)`) so the wave
        // peaks at pulseAge = 0, i.e. the dot is at full brightness the
        // moment the session enters waitingForInput. The inverted form
        // started the pulse at the trough, so the "fresh" signal read as
        // dim at the exact moment it should have read as bright.
        let pulseAge = now.timeIntervalSince(session.phaseChangedAt)
        let phase01 = pulseAge.truncatingRemainder(dividingBy: Self.pulsePeriod) / Self.pulsePeriod
        let wave = 0.5 + 0.5 * cos(phase01 * 2 * .pi)
        return Self.pulseMinOpacity + (1.0 - Self.pulseMinOpacity) * wave
    }
}
