import XCTest
@testable import AgentVisorCore

final class MenuBarPackingEfficiencyTests: XCTestCase {
    func testSingleWindowUsageFreesOneMoreMeasuredLayoutSession() {
        let leftSessionWidth = 515.0 - 8.0
        let rightUsageWidth = 383.0 - 8.0
        let expandedUsage = MenuBarUsageSlotPolicy.layout(
            usableWidth: rightUsageWidth,
            spacing: 4,
            codexWidth: 114,
            claudeWidth: 84
        )
        let compactUsage = MenuBarUsageSlotPolicy.layout(
            usableWidth: rightUsageWidth,
            spacing: 4,
            codexWidth: 64,
            claudeWidth: 84
        )
        let candidates: [PillBarPacker.Candidate] = [
            .init(id: "s1", pillWidth: 107),
            .init(id: "s2", pillWidth: 90),
            .init(id: "s3", pillWidth: 64),
            .init(id: "s4", pillWidth: 102),
            .init(id: "s5", pillWidth: 69),
            .init(id: "s6", pillWidth: 101),
            .init(id: "s7", pillWidth: 70),
            .init(id: "s8", pillWidth: 80),
            .init(id: "s9", pillWidth: 80),
            .init(id: "s10", pillWidth: 80),
            .init(id: "s11", pillWidth: 80),
            .init(id: "s12", pillWidth: 80),
            .init(id: "s13", pillWidth: 80),
        ]
        let standard = PillBarPacker.PackingProfile(
            density: .standard,
            pillSpacing: 4,
            widthReduction: 0
        )
        let pressure = PillBarPacker.PackingProfile(
            density: .pressure,
            pillSpacing: 3,
            widthReduction: 4
        )

        let expanded = PillBarPacker.pack(
            candidates: candidates,
            leftMax: leftSessionWidth,
            rightMax: expandedUsage.sessionUsableWidth,
            standardProfile: standard,
            pressureProfile: pressure,
            overflowPillWidthFor: { _ in 28 }
        )
        let compact = PillBarPacker.pack(
            candidates: candidates,
            leftMax: leftSessionWidth,
            rightMax: compactUsage.sessionUsableWidth,
            standardProfile: standard,
            pressureProfile: pressure,
            overflowPillWidthFor: { _ in 28 }
        )

        XCTAssertEqual(expanded.hiddenCount, 7)
        XCTAssertEqual(compact.hiddenCount, 6)
        XCTAssertEqual(
            compact.leftVisibleIds + compact.rightVisibleIds,
            Array(candidates.prefix(7).map(\.id))
        )
        XCTAssertEqual(compact.hiddenIds, Array(candidates.dropFirst(7).map(\.id)))
    }
}
