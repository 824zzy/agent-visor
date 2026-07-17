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

    var body: some View {
        let acknowledgedAt = navigationRecencyStore.readyAcknowledgedAt(for: session)
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
            TimelineView(.animation) { context in
                stripe(
                    opacity: pulseOpacity(
                        at: context.date,
                        acknowledgedAt: acknowledgedAt
                    )
                )
            }
        } else {
            stripe(opacity: 1.0)
        }
    }

    private func stripe(opacity: Double) -> some View {
        // statusIdleAge fades from real conversational recency, not the
        // mtime/default-driven lastActivity — so day-stale or empty
        // GUI-spawned sessions don't glow green. See SessionState.statusIdleAge.
        let color = sessionStatusColor(for: session.phase, idleAge: session.statusIdleAge)
        return RoundedRectangle(cornerRadius: width / 2)
            .fill(color.opacity(opacity))
            .frame(width: width, height: height)
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
