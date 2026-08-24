import XCTest
@testable import AgentVisorCore

final class NativeMenuSessionHoverStateTests: XCTestCase {
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
                status: "Ready to continue",
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
        let date = try Date(
            "2026-08-22T21:02:30.000Z",
            strategy: .iso8601
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
                    .init(label: "Latest turn", value: "Pi · Ghostty · Claude Sonnet 4"),
                    .init(label: "Reasoning", value: "High"),
                    .init(label: "Project", value: "~/Codes/agent-visor"),
                    .init(label: "Activity", value: "12s ago"),
                ],
                context: .init(usedLabel: "84k", windowLabel: "200k", percentage: 42),
                shortcutLabel: "⌥⌘3"
            )
        )
    }
}
