import XCTest
@testable import AgentVisorCore

final class AccessibleLightPaletteTests: XCTestCase {
    func testSmallTextTokensMeetContrastTargetOnLightCanvas() {
        let background = AccessibleLightPalette.background
        let tokens = [
            AccessibleLightPalette.secondaryText,
            AccessibleLightPalette.tertiaryText,
            AccessibleLightPalette.statusRunning,
            AccessibleLightPalette.statusPending,
            AccessibleLightPalette.statusSuccess,
            AccessibleLightPalette.link,
            AccessibleLightPalette.heading,
        ]

        for token in tokens {
            XCTAssertGreaterThanOrEqual(
                SRGBContrast.ratio(token, background),
                4.5
            )
        }
    }
}

final class AccessibleLightPaletteWiringAuditTests: XCTestCase {
    func testLightThemeUsesMeasuredSemanticTokens() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let colors = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Components/TerminalColors.swift"))
        let status = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Components/SessionStatusDot.swift"))
        let detail = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))

        for token in [
            "AccessibleLightPalette.secondaryText",
            "AccessibleLightPalette.tertiaryText",
            "AccessibleLightPalette.statusRunning",
            "AccessibleLightPalette.statusPending",
            "AccessibleLightPalette.statusSuccess",
            "AccessibleLightPalette.link",
            "AccessibleLightPalette.heading",
        ] {
            XCTAssertTrue(colors.contains(token), "Missing light semantic token: \(token)")
        }
        XCTAssertTrue(status.contains("AccessibleLightPalette.statusRunning"))
        XCTAssertTrue(status.contains("AccessibleLightPalette.statusPending"))
        XCTAssertTrue(status.contains("AccessibleLightPalette.statusSuccess"))
        XCTAssertTrue(detail.contains("ChatTheme.chipForeground(tint)"))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
