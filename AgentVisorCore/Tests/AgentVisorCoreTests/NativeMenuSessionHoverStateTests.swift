import XCTest
@testable import AgentVisorCore

final class NativeMenuSessionHoverStateTests: XCTestCase {
    func testShowsSourceAndProfileAtTheTopOfTheExistingHoverDetails() throws {
        let json = #"{"version":1,"id":"hover-source","method":"present_pills","params":{"pills":[{"id":"paseo-work","title":"Copilot work","phase":"working","priority":0,"accessibilityLabel":"Copilot work, in progress","inspector":{"status":"Working","runtimeItems":["Claude Code · Paseo"],"detailRows":[{"label":"Profile","value":"claude-copilot"}],"projectPath":"~/Codes","activityAt":"2026-10-12T21:00:00.000Z"}}]}}"#
        let request = try NativeHelperRequest.decode(Data(json.utf8))
        guard case .presentPills(_, let pills, _, _, _, _, _, _, _) = request else {
            return XCTFail("Expected a pill presentation")
        }
        let pill = try XCTUnwrap(pills.first)
        var state = NativeMenuSessionHoverState()
        state.pointerEntered(pill.id, at: 10)
        let date = try XCTUnwrap(NativeHelperTimestamp.parse("2026-10-12T21:00:12.000Z"))
        let presentation = try XCTUnwrap(state.presentation(pills: [pill.id: pill], at: 10.35, date: date))

        XCTAssertEqual(presentation.title, "Copilot work")
        XCTAssertEqual(presentation.phase, .working)
        XCTAssertEqual(presentation.rows, [
            .init(label: "Source", value: "Claude Code · Paseo"),
            .init(label: "Profile", value: "claude-copilot"),
            .init(label: "Project", value: "~/Codes"),
            .init(label: "Activity", value: "12s ago"),
        ])
    }

    func testShowsSessionDetailsAfterDelayAndDismissesOnExit() {
        let pill = NativeHelperPill(
            id: "session-1",
            title: "Review migration",
            subtitle: "Ready to continue",
            source: "Pi",
            project: "agent-visor",
            owner: "Ghostty",
            phase: .ready,
            priority: 0,
            accessibilityLabel: "Review migration, ready"
        )
        var state = NativeMenuSessionHoverState()

        state.pointerEntered("session-1", at: 10)
        XCTAssertNil(state.presentation(pills: ["session-1": pill], at: 10.34))
        XCTAssertEqual(
            state.presentation(pills: ["session-1": pill], at: 10.35),
            NativeMenuSessionDetailPresentation(
                id: "session-1",
                title: "Review migration",
                status: "Ready",
                phase: .ready,
                rows: [
                    .init(label: "Source", value: "Pi"),
                    .init(label: "Project", value: "agent-visor"),
                    .init(label: "Opens in", value: "Ghostty"),
                ]
            )
        )

        state.pointerExited("session-1")
        XCTAssertNil(state.presentation(pills: ["session-1": pill], at: 11))
    }

    func testLegacyHoverWithoutInspectorUsesSharedLifecycleStatus() {
        let pill = NativeHelperPill(
            id: "legacy-ready",
            title: "Review migration",
            subtitle: "Ready to continue",
            source: "Pi",
            project: "agent-visor",
            owner: "Ghostty",
            phase: .ready,
            priority: 0,
            accessibilityLabel: "Review migration, Ready, Pi, agent-visor"
        )
        var state = NativeMenuSessionHoverState()

        state.pointerEntered(pill.id, at: 10)

        XCTAssertEqual(
            state.presentation(pills: [pill.id: pill], at: 10.35)?.status,
            "Ready"
        )
    }

    func testPresentsEveryAvailableSwiftInspectorElement() throws {
        let inspector = NativeHelperSessionInspector(
            status: "Ready",
            runtimeItems: ["Pi · Ghostty", "Claude Sonnet 4"],
            detailRows: [.init(label: "Reasoning", value: "High")],
            projectPath: "~/Codes/agent-visor",
            activityAt: "2026-08-22T21:02:18.000Z",
            context: .init(usedLabel: "84k", windowLabel: "200k", percentage: 42)
        )
        let pill = NativeHelperPill(
            id: "session-1",
            title: "Review migration",
            inspector: inspector,
            phase: .ready,
            priority: 0,
            accessibilityLabel: "Review migration, ready"
        )
        var state = NativeMenuSessionHoverState()
        state.pointerEntered("session-1", at: 10)
        let date = try XCTUnwrap(
            NativeHelperTimestamp.parse("2026-08-22T21:02:30.000Z")
        )

        XCTAssertEqual(
            state.presentation(
                pills: ["session-1": pill],
                at: 10.35,
                date: date,
                shortcutLabel: "⌥⌘3"
            ),
            NativeMenuSessionDetailPresentation(
                id: "session-1",
                title: "Review migration",
                status: "Ready",
                phase: .ready,
                rows: [
                    .init(label: "Source", value: "Pi · Ghostty · Claude Sonnet 4"),
                    .init(label: "Reasoning", value: "High"),
                    .init(label: "Project", value: "~/Codes/agent-visor"),
                    .init(label: "Activity", value: "12s ago"),
                ],
                context: .init(usedLabel: "84k", windowLabel: "200k", percentage: 42),
                shortcutLabel: "⌥⌘3"
            )
        )
    }

    func testHoverUsesExplicitLifecycleStatusInsteadOfLegacyInspectorCopy() throws {
        let json = #"{"id":"unknown","title":"Unverified","phase":"ready","priority":0,"accessibilityLabel":"Unverified, Status unavailable","lifecycleStatus":"unavailable","inspector":{"status":"Recent","runtimeItems":["Claude Code"],"detailRows":[],"projectPath":"~/Codes","activityAt":"2026-10-21T18:00:00.000Z"}}"#
        let pill = try JSONDecoder().decode(NativeHelperPill.self, from: Data(json.utf8))
        var state = NativeMenuSessionHoverState()
        state.pointerEntered(pill.id, at: 10)

        let presentation = state.presentation(pills: [pill.id: pill], at: 10.35)
        XCTAssertEqual(presentation?.status, "Status unavailable")
        XCTAssertEqual(presentation?.phase, .history)
    }
}
