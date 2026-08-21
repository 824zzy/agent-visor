import Foundation
import XCTest

final class PiTranscriptPerformanceWiringAuditTests: XCTestCase {
    func testSessionStoreCoalescesPiRefreshesBeforeCallingProvider() throws {
        let source = try String(contentsOf: repoRoot()
            .appendingPathComponent("AgentVisor/Services/State/SessionStore.swift"))

        XCTAssertTrue(
            source.contains("TranscriptSyncCoalescer<String>"),
            "SessionStore must retain one running Pi refresh plus one latest request."
        )
        XCTAssertTrue(source.contains("schedulePiFileSync(sessionId: sessionId, cwd: cwd)"))
        XCTAssertTrue(source.contains("coalescer.request(cwd)"))
        XCTAssertTrue(source.contains("coalescer.beginPendingRun()"))
        XCTAssertTrue(source.contains("coalescer.completeRun()"))

        guard let start = source.range(of: "private func runPiFileSync")?.lowerBound,
              let end = source.range(
                of: "private func refreshCodexMetadataBeforeFullReplay",
                range: start..<source.endIndex
              )?.lowerBound else {
            return XCTFail("Could not isolate the coalesced Pi refresh path.")
        }
        let piPath = String(source[start..<end])
        XCTAssertTrue(piPath.contains("await provider.fileSync(sessionId: sessionId, cwd: cwd)"))
        XCTAssertTrue(piPath.contains("discardRunningResult"))
    }

    func testPiProviderSharesIncrementalCacheAndSkipsUnchangedReplay() throws {
        let root = repoRoot()
        let parser = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/Session/PiConversationParser.swift"))
        let provider = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/Agents/PiAgentProvider.swift"))
        let protocolSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/Agents/AgentProvider.swift"))
        let store = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/State/SessionStore.swift"))

        XCTAssertTrue(parser.contains("[String: PiIncrementalTranscriptFileParser]"))
        XCTAssertTrue(parser.contains("fileParsers.removeValue(forKey: sessionId)"))
        XCTAssertTrue(parser.contains("defer {\n            fileParsers[sessionId] = fileParser\n        }"))
        XCTAssertFalse(parser.contains("var fileParser = fileParsers[sessionId]"))
        XCTAssertTrue(parser.contains("func loadHistory("))
        XCTAssertFalse(parser.contains("FileManager.default.contents(atPath: transcriptPath)"))
        XCTAssertTrue(provider.contains("PiConversationParser.shared.loadHistory("))
        XCTAssertTrue(provider.contains("result.didChange ? .fullReplay(result.history) : .noChange"))
        XCTAssertTrue(protocolSource.contains("case noChange"))
        XCTAssertTrue(store.contains("case .noChange:"))
    }

    func testPiBootstrapSummaryIsBoundedAndSeparateFromFullHistoryParser() throws {
        let root = repoRoot()
        let provider = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/Agents/PiAgentProvider.swift"))
        let summary = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/Session/PiConversationSummary.swift"))
        let reader = try String(contentsOf: root
            .appendingPathComponent("AgentVisorCore/Sources/AgentVisorCore/PiTranscriptSummaryReader.swift"))

        guard let start = provider.range(of: "nonisolated func loadConversationInfo")?.lowerBound,
              let end = provider.range(
                of: "nonisolated func fileSync",
                range: start..<provider.endIndex
              )?.lowerBound else {
            return XCTFail("Could not isolate Pi's bootstrap summary path.")
        }
        let infoPath = String(provider[start..<end])
        XCTAssertTrue(infoPath.contains("PiConversationSummary.shared.loadConversationInfo("))
        XCTAssertFalse(infoPath.contains("loadFullHistory"))
        XCTAssertTrue(summary.contains("actor PiConversationSummary"))
        XCTAssertTrue(summary.contains("[String: CachedSummary]"))
        XCTAssertTrue(summary.contains("PiTranscriptSummaryReader.read(path: transcriptPath)"))
        XCTAssertTrue(reader.contains("JSONLHeadTailFileReader.read(path: path)"))
    }

    func testPillCoordinatorCachesFixedFontTextMeasurements() throws {
        let source = try String(contentsOf: repoRoot()
            .appendingPathComponent("AgentVisor/UI/Components/PillStripContent.swift"))

        XCTAssertTrue(source.contains("private static let textWidthCache = NSCache<NSString, NSNumber>()"))
        XCTAssertTrue(source.contains("textWidthCache.object(forKey: cacheKey)"))
        XCTAssertTrue(source.contains("textWidthCache.setObject(NSNumber(value: Double(width)), forKey: cacheKey)"))
        XCTAssertTrue(source.contains("let cacheKey = textWidthCacheKey("))
        XCTAssertTrue(source.contains("static func textWidthCacheKey("))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
