import XCTest
@testable import AgentVisorCore

/// Product names must describe the job a type does now. The physical notch and
/// Claude-only rules keep their precise names; cross-agent and display-wide code
/// must not inherit names from the retired panel or the first supported agent.
final class ProductVocabularyWiringAuditTests: XCTestCase {
    func testOnlyPhysicalNotchTypesKeepNotchFilenames() throws {
        let names = try productionSwiftFiles()
            .map(\.lastPathComponent)
            .filter { $0.contains("Notch") }
            .sorted()
        XCTAssertEqual(
            names,
            ["NotchGeometry.swift", "NotchShape.swift"],
            "Only the physical cutout's geometry and decoration should use Notch in a filename."
        )
    }

    func testRetiredPanelAndCrossAgentNamesDoNotReturn() throws {
        let source = try productionSwiftFiles()
            .map { try String(contentsOf: $0) }
            .joined(separator: "\n")
        for retired in [
            "NotchActivityCoordinator",
            "NotchMenuLayoutPolicy",
            "NotchPanelRedirect",
            "NotchPillBar",
            "NotchSideContent",
            "NotchUserDriver",
            "NotchViewModel",
            "ClaudeSessionMonitor",
            "WindowModeFlag"
        ] {
            XCTAssertFalse(source.contains(retired), "Retired product name returned: \(retired)")
        }
        for current in [
            "PillStripView",
            "PillStripViewModel",
            "PillBar",
            "MenuBarLayoutPolicy",
            "MenuBarOwnerResolver",
            "SessionBrowserRedirect",
            "SessionMonitor",
            "UpdateUserDriver"
        ] {
            XCTAssertTrue(source.contains(current), "Current product name is missing: \(current)")
        }
    }

    func testClaudeOnlyTypesKeepTheirProviderName() throws {
        let names = Set(try productionSwiftFiles().map(\.lastPathComponent))
        for name in [
            "ClaudeCodeAgentProvider.swift",
            "ClaudeSessionPidRebinder.swift",
            "ClaudeCodeSessionMetadataPolicy.swift",
            "ClaudeProjectPathEncoder.swift"
        ] {
            XCTAssertTrue(names.contains(name), "A Claude-only rule lost its provider name: \(name)")
        }
    }

    func testDeletedRolloutAndNavigationChainsStayDeleted() throws {
        let names = Set(try productionSwiftFiles().map(\.lastPathComponent))
        for name in [
            "WindowModeFlag.swift",
            "NotchActivityCoordinator.swift",
            "TmuxSessionMatcher.swift",
            "TmuxController.swift",
            "YabaiController.swift"
        ] {
            XCTAssertFalse(names.contains(name), "Unused legacy file returned: \(name)")
        }
    }

    private func productionSwiftFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = [
            root.appendingPathComponent("AgentVisor"),
            root.appendingPathComponent("AgentVisorCore/Sources")
        ]
        return roots.flatMap { directory in
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            return (enumerator?.allObjects as? [URL] ?? []).filter {
                $0.pathExtension == "swift"
            }
        }
    }
}
