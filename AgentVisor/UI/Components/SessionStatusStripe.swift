//
//  SessionStatusStripe.swift
//  AgentVisor
//
//  Thin vertical accent stripe rendered at the leading edge of a
//  sidebar row. Replaces the standalone `SessionStatusDot` for the
//  window-mode sidebar: status now lives at the row's edge so the
//  inner badge slot can carry agent identity instead.
//
//  Pulse motion (waitingForInput's brief post-transition fade)
//  reuses the same cosine math `SessionStatusDot` did, so the
//  visual cadence stays familiar. Pulse only animates while the
//  current completion is fresh and unacknowledged; otherwise the
//  stripe stays static and skips `TimelineView(.animation)`.
//

import AgentVisorCore
import SwiftUI

struct SessionStatusStripe: View {
    let session: SessionState
    /// Width of the stripe in points. 3pt reads as a clear accent
    /// without crowding the row's left padding.
    var width: CGFloat = 3
    /// Fixed stripe height. Sidebar rows are variable height (taller
    /// when a subtitle is present, shorter when not), and a stripe
    /// that stretches to row height shows up as an uneven visual
    /// jaggle down the leading edge. Pinning to a fixed height keeps
    /// the stripes uniform regardless of row content; matches the
    /// app-icon badge's size so the two leading-edge marks read as
    /// a coordinated pair.
    var height: CGFloat = 22
    @ObservedObject private var navigationRecencyStore = SessionNavigationRecencyStore.shared

    private static let pulsePeriod: TimeInterval = 1.5
    private static let pulseMinOpacity: Double = 0.35
    /// Cap the pulse tick rate; a 1.5s cosine reads smoothly at 30fps and
    /// must not relayout at a ProMotion panel's 120Hz refresh.
    private static let pulseFrameInterval: TimeInterval = 1.0 / 30.0

    var body: some View {
        let acknowledgedAt = navigationRecencyStore.readyAcknowledgedAt(for: session)
        // Resolve the status color ONCE per body evaluation — never inside the
        // per-frame TimelineView closure. Re-resolving sessionStatusColor
        // (NSColor colorspace conversions) every display refresh pinned
        // WindowServer on ProMotion panels (sample-confirmed 2026-08-04).
        // statusIdleAge fades from real conversational recency, not the
        // mtime/default-driven lastActivity. See SessionState.statusIdleAge.
        let color = sessionStatusColor(for: session.phase, idleAge: session.statusIdleAge)
        if session.phase == .ended {
            // Ended sessions get no stripe — the row already reads
            // dim via the gray timestamp + faded subtitle.
            EmptyView()
        } else if ReadyAttentionPolicy.shouldPulse(
            isReady: session.phase == .waitingForInput,
            phaseChangedAt: session.phaseChangedAt,
            acknowledgedAt: acknowledgedAt,
            now: Date()
        ) {
            // Throttled schedule + opacity-only animation over a precomputed
            // color, so each tick is a cheap layer update, not a relayout with
            // fresh color resolution.
            TimelineView(.animation(minimumInterval: Self.pulseFrameInterval)) { context in
                stripe(
                    color: color,
                    opacity: pulseOpacity(
                        at: context.date,
                        acknowledgedAt: acknowledgedAt
                    )
                )
            }
        } else {
            stripe(color: color, opacity: 1.0)
        }
    }

    private func stripe(color: Color, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: width / 2)
            .fill(color)
            .frame(width: width, height: height)
            .opacity(opacity)
    }

    private func pulseOpacity(at now: Date, acknowledgedAt: Date?) -> Double {
        guard ReadyAttentionPolicy.shouldPulse(
            isReady: session.phase == .waitingForInput,
            phaseChangedAt: session.phaseChangedAt,
            acknowledgedAt: acknowledgedAt,
            now: now
        ) else {
            return 1.0
        }
        let pulseAge = now.timeIntervalSince(session.phaseChangedAt)
        let phase01 = pulseAge.truncatingRemainder(dividingBy: Self.pulsePeriod) / Self.pulsePeriod
        let wave = 0.5 + 0.5 * cos(phase01 * 2 * .pi)
        return Self.pulseMinOpacity + (1.0 - Self.pulseMinOpacity) * wave
    }
}
