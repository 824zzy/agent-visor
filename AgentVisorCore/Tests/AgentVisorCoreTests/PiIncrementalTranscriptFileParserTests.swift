import Foundation
import XCTest
@testable import AgentVisorCore

final class PiIncrementalTranscriptFileParserTests: XCTestCase {
    func testUnchangedFileReadsZeroBytesAndAppendReadsOnlyNewBytes() throws {
        let fixture = try TemporaryPiTranscript()
        defer { fixture.remove() }

        let initialText = [
            fixture.sessionLine,
            fixture.messageLine(id: "u1", parentID: nil, role: "user", text: "Start"),
            fixture.messageLine(id: "a-old", parentID: "u1", role: "assistant", text: "Old branch"),
        ].joined(separator: "\n") + "\n"
        let initialData = Data(initialText.utf8)
        try initialData.write(to: fixture.file)

        var parser = PiIncrementalTranscriptFileParser()
        let first = try parser.parse(path: fixture.file.path)
        XCTAssertEqual(first.change, .rebuilt)
        XCTAssertEqual(first.bytesRead, initialData.count)
        XCTAssertEqual(first.transcript.messages.map(\.blocks), [
            [.text("Start")],
            [.text("Old branch")],
        ])

        let duplicate = try parser.parse(path: fixture.file.path)
        XCTAssertEqual(duplicate.change, .unchanged)
        XCTAssertEqual(duplicate.bytesRead, 0)
        XCTAssertFalse(duplicate.didChange)

        let appendedText = fixture.messageLine(
            id: "u-new",
            parentID: "u1",
            role: "user",
            text: "Active branch"
        ) + "\n"
        let appendedData = Data(appendedText.utf8)
        try fixture.append(appendedData)

        let appended = try parser.parse(path: fixture.file.path)
        XCTAssertEqual(appended.change, .appended)
        XCTAssertEqual(appended.bytesRead, appendedData.count)
        XCTAssertTrue(appended.didChange)
        XCTAssertEqual(appended.transcript.messages.map(\.blocks), [
            [.text("Start")],
            [.text("Active branch")],
        ])
        XCTAssertEqual(appended.transcript, PiTranscriptParser.parse(
            data: initialData + appendedData
        ))
    }

    func testSplitJSONRecordIsWithheldUntilTheAppendCompletesIt() throws {
        let fixture = try TemporaryPiTranscript()
        defer { fixture.remove() }

        let initialText = [
            fixture.sessionLine,
            fixture.messageLine(id: "u1", parentID: nil, role: "user", text: "Start"),
        ].joined(separator: "\n") + "\n"
        try Data(initialText.utf8).write(to: fixture.file)

        var parser = PiIncrementalTranscriptFileParser()
        let initial = try parser.parse(path: fixture.file.path)
        let completeLine = fixture.messageLine(
            id: "a1",
            parentID: "u1",
            role: "assistant",
            text: "Done"
        )
        let midpoint = completeLine.utf8.count / 2
        let bytes = Data(completeLine.utf8)
        let firstHalf = bytes.prefix(midpoint)
        let secondHalf = bytes.suffix(from: midpoint) + Data("\n".utf8)

        try fixture.append(Data(firstHalf))
        let partial = try parser.parse(path: fixture.file.path)
        XCTAssertEqual(partial.change, .appended)
        XCTAssertEqual(partial.bytesRead, firstHalf.count)
        XCTAssertFalse(partial.didChange)
        XCTAssertEqual(partial.transcript, initial.transcript)

        try fixture.append(secondHalf)
        let completed = try parser.parse(path: fixture.file.path)
        XCTAssertEqual(completed.change, .appended)
        XCTAssertEqual(completed.bytesRead, secondHalf.count)
        XCTAssertTrue(completed.didChange)
        XCTAssertEqual(completed.transcript.messages.map(\.blocks), [
            [.text("Start")],
            [.text("Done")],
        ])
    }

    func testSameSizeAtomicReplacementRebuildsInsteadOfReturningUnchanged() throws {
        let fixture = try TemporaryPiTranscript()
        defer { fixture.remove() }

        let oldText = [
            fixture.sessionLine,
            fixture.messageLine(id: "u1", parentID: nil, role: "user", text: "Old"),
        ].joined(separator: "\n") + "\n"
        let newText = [
            fixture.sessionLine,
            fixture.messageLine(id: "u2", parentID: nil, role: "user", text: "New"),
        ].joined(separator: "\n") + "\n"
        let oldData = Data(oldText.utf8)
        let newData = Data(newText.utf8)
        XCTAssertEqual(oldData.count, newData.count)
        try oldData.write(to: fixture.file)

        var parser = PiIncrementalTranscriptFileParser()
        _ = try parser.parse(path: fixture.file.path)
        try newData.write(to: fixture.file, options: .atomic)

        let rebuilt = try parser.parse(path: fixture.file.path)
        XCTAssertEqual(rebuilt.change, .rebuilt)
        XCTAssertEqual(rebuilt.bytesRead, newData.count)
        XCTAssertEqual(rebuilt.transcript.messages.map(\.blocks), [[.text("New")]])
    }

    func testTruncationDiscardsTheOldIndexAndRebuilds() throws {
        let fixture = try TemporaryPiTranscript()
        defer { fixture.remove() }

        let initial = [
            fixture.sessionLine,
            fixture.messageLine(id: "u1", parentID: nil, role: "user", text: "Old"),
            fixture.messageLine(id: "a1", parentID: "u1", role: "assistant", text: "Old answer"),
        ].joined(separator: "\n") + "\n"
        try Data(initial.utf8).write(to: fixture.file)

        var parser = PiIncrementalTranscriptFileParser()
        _ = try parser.parse(path: fixture.file.path)

        let replacement = [
            fixture.sessionLine,
            fixture.messageLine(id: "u2", parentID: nil, role: "user", text: "Replacement"),
        ].joined(separator: "\n") + "\n"
        let replacementData = Data(replacement.utf8)
        try replacementData.write(to: fixture.file)

        let rebuilt = try parser.parse(path: fixture.file.path)
        XCTAssertEqual(rebuilt.change, .rebuilt)
        XCTAssertEqual(rebuilt.bytesRead, replacementData.count)
        XCTAssertEqual(rebuilt.transcript.messages.map(\.blocks), [[.text("Replacement")]])
    }
}

private final class TemporaryPiTranscript {
    let directory: URL
    let file: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        file = directory.appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var sessionLine: String {
        #"{"type":"session","version":3,"id":"session-1","timestamp":"2026-07-22T07:04:30.591Z","cwd":"/tmp/project"}"#
    }

    func messageLine(
        id: String,
        parentID: String?,
        role: String,
        text: String
    ) -> String {
        let parent = parentID.map { #""\#($0)""# } ?? "null"
        return #"{"type":"message","id":"\#(id)","parentId":\#(parent),"timestamp":"2026-07-22T07:04:31.000Z","message":{"role":"\#(role)","content":"\#(text)","provider":"openai","model":"gpt-5","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"stopReason":"stop"}}"#
    }

    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
