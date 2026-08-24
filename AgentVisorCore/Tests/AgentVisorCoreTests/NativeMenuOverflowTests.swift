import AppKit
import SwiftUI
import XCTest
@testable import AgentVisorCore

final class NativeMenuOverflowTests: XCTestCase {
    func testShowsOnlyHiddenSessionsUntilSearchFindsAnyPresentedSession() {
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
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Search sessions" })
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
        activityAt: String? = nil
    ) -> NativeHelperPill {
        NativeHelperPill(
            id: id,
            title: title,
            source: "Pi",
            project: project,
            owner: "Ghostty",
            inspector: activityAt.map {
                NativeHelperSessionInspector(
                    status: "Working",
                    runtimeItems: ["Pi · Ghostty"],
                    detailRows: [],
                    projectPath: "/repo",
                    activityAt: $0,
                    context: nil
                )
            },
            phase: .working,
            priority: 0,
            accessibilityLabel: "\(title), in progress"
        )
    }
}
