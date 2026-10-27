import AppKit
import SwiftUI
import XCTest
@testable import AgentVisorCore

final class NativeMenuOverflowTests: XCTestCase {
    func testInactiveReadyPillUsesGrayToneButKeepsReadyStatus() throws {
        let json = #"{"id":"inactive","title":"gc","phase":"history","lifecycleStatus":"ready","inactive":true,"attentionTier":"history","priority":0,"accessibilityLabel":"gc, Ready, Inactive"}"#
        let inactive = try JSONDecoder().decode(NativeHelperPill.self, from: Data(json.utf8))

        XCTAssertEqual(NativeMenuStatusPresentation.status(for: inactive), "Ready")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: inactive), .history)
    }

    func testInactiveHintCannotGrayUnopenedReadyOrActiveWorkAndQuestions() {
        let cases: [(NativeHelperLifecycleStatus, NativeHelperPillPhase, Bool?)] = [
            (.ready, .ready, true), (.working, .working, nil), (.needsYou, .needsYou, nil),
        ]
        for (status, expectedTone, unseen) in cases {
            let pill = NativeHelperPill(
                id: "active", title: "Active", phase: expectedTone,
                lifecycleStatus: status, inactive: true, completionUnseen: unseen,
                priority: 0, accessibilityLabel: "Active"
            )
            XCTAssertEqual(NativeMenuStatusPresentation.tone(for: pill), expectedTone)
        }
    }

    func testHistoryAttentionUsesRecentOverflowDisplayWithoutChangingReadyWirePhase() {
        let stale = pill("stale", title: "Old Claude", project: "agent-visor")
            .with(phase: .ready, attentionTier: .history)

        XCTAssertEqual(stale.phase, .ready)
        XCTAssertEqual(NativeMenuDisplayPhase.phase(for: stale), .history)
        XCTAssertEqual(
            NativeMenuDisplayPhase.phase(for: pill("fresh", title: "Fresh", project: "agent-visor")),
            .working
        )
    }

    func testStaleReadyOverflowKeepsReadyLabelAndTone() {
        let stale = pill(
            "stale", title: "Old Claude", project: "agent-visor",
            activityAt: "2026-08-15T10:00:00.000Z",
            attentionTier: .history, phase: .ready
        )

        XCTAssertEqual(NativeMenuDisplayPhase.phase(for: stale), .history)
        XCTAssertEqual(NativeMenuStatusPresentation.status(for: stale), "Ready")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: stale), .ready)
    }

    func testHistoryPlacementKeepsKnownReadyLifecycleStatusAndTone() {
        let historicalPlacement = pill(
            "old-ready", title: "Old Ready", project: "agent-visor",
            activityAt: "2026-08-15T10:00:00.000Z",
            attentionTier: .history, phase: .history, inspectorStatus: "Ready"
        )

        XCTAssertEqual(NativeMenuDisplayPhase.phase(for: historicalPlacement), .history)
        XCTAssertEqual(NativeMenuStatusPresentation.status(for: historicalPlacement), "Ready")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: historicalPlacement), .ready)
    }

    func testNativeFallbackUsesSharedLifecycleLabelsForWorkingAndNeedsYou() {
        let needsYou = pill("question", title: "Answer", project: "agent-visor", phase: .needsYou)
        let working = pill("working", title: "Build", project: "agent-visor", phase: .working)
        let historical = pill("historical", title: "Old", project: "agent-visor", phase: .history)

        XCTAssertEqual(NativeMenuStatusPresentation.status(for: needsYou), "Needs you")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: needsYou), .needsYou)
        XCTAssertEqual(NativeMenuStatusPresentation.status(for: working), "Working")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: working), .working)
        XCTAssertEqual(NativeMenuStatusPresentation.status(for: historical), "Historical")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: historical), .history)
    }

    func testNativeInspectorStatusOverridesPlacementPhaseForTransitionRows() {
        let questionDuringWork = pill(
            "question", title: "Answer", project: "agent-visor",
            activityAt: "2026-10-21T19:00:00.000Z",
            phase: .working, inspectorStatus: "Needs you"
        )

        XCTAssertEqual(NativeMenuStatusPresentation.status(for: questionDuringWork), "Needs you")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: questionDuringWork), .needsYou)
    }

    func testExplicitLifecycleStatusWinsOverLegacyInspectorCopy() throws {
        let json = #"{"id":"closed","title":"Closed","phase":"history","priority":0,"accessibilityLabel":"Closed, Closed","lifecycleStatus":"closed","inspector":{"status":"Recent","runtimeItems":["Claude Code"],"detailRows":[],"projectPath":"~/Codes","activityAt":"2026-10-21T18:00:00.000Z"}}"#
        let closed = try JSONDecoder().decode(NativeHelperPill.self, from: Data(json.utf8))

        XCTAssertEqual(NativeMenuStatusPresentation.status(for: closed), "Closed")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: closed), .history)
    }

    func testSavedLifecycleStatusUsesNeutralSavedLabel() {
        let saved = NativeHelperPill(
            id: "saved",
            title: "Catalog record",
            phase: .history,
            lifecycleStatus: .saved,
            priority: 0,
            accessibilityLabel: "Catalog record, Saved"
        )

        XCTAssertEqual(NativeMenuStatusPresentation.status(for: saved), "Saved")
        XCTAssertEqual(NativeMenuStatusPresentation.tone(for: saved), .history)
    }

    func testLegacyInspectorLabelsUseSharedLifecycleCopyAndTone() {
        let cases: [(String, String, NativeHelperPillPhase)] = [
            ("Needs attention", "Needs you", .needsYou),
            ("In progress", "Working", .working),
            ("Recent", "Historical", .history),
        ]

        for (legacy, expectedStatus, expectedTone) in cases {
            let pill = pill(
                "legacy-\(legacy)", title: "Legacy \(legacy)", project: "agent-visor",
                phase: expectedTone, inspectorStatus: legacy
            )

            XCTAssertEqual(NativeMenuStatusPresentation.status(for: pill), expectedStatus)
            XCTAssertEqual(NativeMenuStatusPresentation.tone(for: pill), expectedTone)
        }
    }

    func testOldUnarchivedConversationRemainsInOverflowAndSearch() {
        let old = pill(
            "old", title: "donut-feature-parity", project: "Donut",
            activityAt: "2026-01-01T00:00:00.000Z", defaultOverflowEligible: true
        )
        let snapshot = NativeMenuOverflowSnapshot(
            menuPills: [], navigatorPills: [old], visibleSessionIDs: []
        )
        XCTAssertEqual(snapshot.overflowSessionIDs, ["old"])
        XCTAssertEqual(snapshot.selection(query: "feature-parity").orderedSessionIDs, ["old"])
    }

    func testNavigatorOnlyEligibleSessionsArePartOfDefaultOverflow() {
        let visible = pill("visible", title: "Visible migration", project: "Personal")
        let navigatorOnly = pill(
            "chat",
            title: "Chat transcript",
            project: "Archive",
            defaultOverflowEligible: true
        )
        let automation = pill(
            "automation",
            title: "Codex automation · Archive",
            project: "Archive",
            defaultOverflowEligible: false
        )
        let managed = pill("managed", title: "hi", project: "Codes", defaultOverflowEligible: false)
        let retained = pill(
            "retained", title: "cc-av", project: "Codes", defaultOverflowEligible: false
        ).with(phase: .ready, attentionTier: .ready)
        let snapshot = NativeMenuOverflowSnapshot(
            menuPills: [visible],
            navigatorPills: [visible, navigatorOnly, automation, managed, retained],
            visibleSessionIDs: ["visible"]
        )

        XCTAssertEqual(snapshot.overflowSessionIDs, ["chat"])
        XCTAssertEqual(snapshot.selection(query: "cc-av").orderedSessionIDs, ["retained"])
        XCTAssertEqual(snapshot.selection(query: "").orderedSessionIDs, ["chat"])
        XCTAssertEqual(snapshot.selection(query: "hi").orderedSessionIDs.first, "managed")
    }

    func testOmittedNavigatorOnlyEligibilityPreservesLegacyOverflowBehavior() {
        let visible = pill("visible", title: "Visible migration", project: "Personal")
        let legacyNavigatorOnly = pill("legacy", title: "Legacy transcript", project: "Archive")
        let snapshot = NativeMenuOverflowSnapshot(
            menuPills: [visible],
            navigatorPills: [visible, legacyNavigatorOnly],
            visibleSessionIDs: ["visible"]
        )

        XCTAssertEqual(snapshot.overflowSessionIDs, [])
        XCTAssertEqual(snapshot.selection(query: "transcript").orderedSessionIDs, ["legacy"])
    }

    func testShowsEveryOmittedSessionUntilSearchFindsAnyPresentedSession() {
        let visible = pill("visible", title: "Visible migration", project: "Personal")
        let hidden = pill("hidden", title: "Hidden review", project: "agent-visor")
        let chatHistory = pill("chat", title: "Chat transcript", project: "Archive")
        let snapshot = NativeMenuOverflowSnapshot(
            menuPills: [visible, hidden],
            navigatorPills: [visible, hidden, chatHistory],
            visibleSessionIDs: ["visible"]
        )

        XCTAssertEqual(snapshot.selection(query: "").orderedSessionIDs, ["hidden"])
        XCTAssertEqual(snapshot.selection(query: "migration").orderedSessionIDs, ["visible"])
        XCTAssertEqual(snapshot.selection(query: "agent visor").orderedSessionIDs, ["hidden"])
        XCTAssertEqual(snapshot.selection(query: "transcript").orderedSessionIDs, ["chat"])
    }

    func testSearchUsesAuthoritativeActivityTimeForEqualMetadataMatches() {
        let snapshot = NativeMenuOverflowSnapshot(
            pills: [
                pill(
                    "older",
                    title: "First review",
                    project: "agent-visor",
                    activityAt: "2026-08-20T10:00:00.000Z"
                ),
                pill(
                    "newer",
                    title: "Second review",
                    project: "agent-visor",
                    activityAt: "2026-08-21T10:00:00.000Z"
                ),
            ],
            visibleSessionIDs: []
        )

        XCTAssertEqual(
            snapshot.selection(query: "agent visor").orderedSessionIDs,
            ["newer", "older"]
        )
    }

    @MainActor
    func testExposesSearchRowsAndFooterActionsToAccessibility() throws {
        let snapshot = NativeMenuOverflowSnapshot(
            pills: [
                pill("visible", title: "Visible migration", project: "Personal"),
                pill("hidden", title: "Hidden review", project: "agent-visor"),
            ],
            visibleSessionIDs: ["visible"]
        )
        var selectedID: String?
        var openedSessions = false
        var openedSettings = false
        let root = NSHostingView(rootView: NativeMenuOverflowView(
            snapshot: snapshot,
            onSelect: { selectedID = $0 },
            onOpenSessions: { openedSessions = true },
            onOpenSettings: { openedSettings = true }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        root.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 560, height: 420)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        root.layoutSubtreeIfNeeded()

        let views = allSubviews(of: root)
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Search recent sessions" })
        let hidden = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Hidden review, in progress"
        })
        XCTAssertFalse(views.contains { $0.accessibilityLabel() == "Visible migration, in progress" })
        let sessions = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == SessionNavigatorSummaryPolicy.openBrowserLabel
        })
        let settings = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == SessionNavigatorSummaryPolicy.settingsLabel
        })

        XCTAssertEqual(hidden.accessibilityRole(), .button)
        XCTAssertEqual(sessions.accessibilityRole(), .button)
        XCTAssertEqual(settings.accessibilityRole(), .button)

        hidden.performClick(nil)
        sessions.performClick(nil)
        settings.performClick(nil)
        XCTAssertEqual(selectedID, "hidden")
        XCTAssertTrue(openedSessions)
        XCTAssertTrue(openedSettings)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    private func pill(
        _ id: String,
        title: String,
        project: String,
        activityAt: String? = nil,
        defaultOverflowEligible: Bool? = nil,
        attentionTier: NativeHelperSessionAttentionTier? = nil,
        phase: NativeHelperPillPhase = .working,
        inspectorStatus: String? = nil
    ) -> NativeHelperPill {
        NativeHelperPill(
            id: id,
            title: title,
            source: "Pi",
            project: project,
            owner: "Ghostty",
            inspector: activityAt.map {
                NativeHelperSessionInspector(
                    status: inspectorStatus ?? defaultStatus(for: phase),
                    runtimeItems: ["Pi · Ghostty"],
                    detailRows: [],
                    projectPath: "/repo",
                    activityAt: $0,
                    context: nil
                )
            },
            phase: phase,
            attentionTier: attentionTier,
            defaultOverflowEligible: defaultOverflowEligible,
            priority: 0,
            accessibilityLabel: "\(title), in progress"
        )
    }

    private func defaultStatus(for phase: NativeHelperPillPhase) -> String {
        switch phase {
        case .needsYou: return "Needs you"
        case .ready: return "Ready"
        case .working: return "Working"
        case .history: return "Historical"
        }
    }
}

private extension NativeHelperPill {
    func with(
        phase: NativeHelperPillPhase,
        attentionTier: NativeHelperSessionAttentionTier?
    ) -> NativeHelperPill {
        NativeHelperPill(
            id: id,
            title: title,
            subtitle: subtitle,
            source: source,
            project: project,
            owner: owner,
            inspector: inspector,
            phase: phase,
            attentionTier: attentionTier,
            failureAlert: failureAlert,
            defaultOverflowEligible: defaultOverflowEligible,
            priority: priority,
            accessibilityLabel: accessibilityLabel
        )
    }
}
