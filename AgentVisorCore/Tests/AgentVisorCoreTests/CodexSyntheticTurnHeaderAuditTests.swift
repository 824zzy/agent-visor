import XCTest
@testable import AgentVisorCore

final class CodexSyntheticTurnHeaderAuditTests: XCTestCase {
    func testCodexSyntheticHeadersRespectLiveFlag() throws {
        let source = try String(contentsOf: chatViewURL(from: URL(fileURLWithPath: #filePath)))
        guard let codexGrouping = source.slice(
            from: "func codexGroupedTimelineRows",
            to: "private func codexTurnCategory"
        ) else {
            return XCTFail("Could not locate codexGroupedTimelineRows implementation.")
        }

        XCTAssertTrue(
            codexGrouping.contains("row.isLive ? ClaudeLiveTurnSentinel.seconds : 0"),
            "Marker-less aborted Codex turns must synthesize a static Worked header, not the live Working sentinel."
        )
    }

    func testPromptAfterMarkerlessWorkKeepsPriorTurnStatic() {
        typealias Cat = CodexTurnGrouper.ItemCategory
        typealias Item = CodexTurnGrouper.ItemDescriptor

        let rows = CodexTurnGrouper.group([
            Item(id: "u1", category: Cat.prompt),
            Item(id: "work1", category: Cat.work(hasError: false)),
            Item(id: "answer1", category: Cat.assistantText),
            Item(id: "u2", category: Cat.prompt),
        ], sessionIsProcessing: true)

        let header = rows.first { !$0.childIds.isEmpty }
        XCTAssertEqual(header?.parentId, "work1" + CodexTurnGrouper.abortedHeaderSuffix)
        XCTAssertEqual(header?.childIds, ["work1"])
        XCTAssertFalse(header?.isLive ?? true)
    }

    private func chatViewURL(from testFile: URL) -> URL {
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("ChatView.swift")
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker)?.lowerBound,
              let end = self[start...].range(of: endMarker)?.lowerBound else {
            return nil
        }
        return String(self[start..<end])
    }
}
