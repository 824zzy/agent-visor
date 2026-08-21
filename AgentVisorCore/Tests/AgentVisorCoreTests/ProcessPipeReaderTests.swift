import Foundation
import XCTest
@testable import AgentVisorCore

final class ProcessPipeReaderTests: XCTestCase {
    func testClosingAReadEndStopsAnActiveReaderSafely() {
        for _ in 0..<100 {
            let pipe = Pipe()
            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)

            DispatchQueue.global(qos: .utility).async {
                started.signal()
                _ = ProcessPipeReader.read(
                    fileDescriptor: pipe.fileHandleForReading.fileDescriptor
                )
                finished.signal()
            }

            XCTAssertEqual(started.wait(timeout: .now() + 0.2), .success)
            Thread.sleep(forTimeInterval: 0.001)
            pipe.fileHandleForReading.closeFile()

            XCTAssertEqual(finished.wait(timeout: .now() + 0.2), .success)
        }
    }

    func testReadsAvailableDataUntilEndOfFile() throws {
        let pipe = Pipe()
        let expected = Data("hello".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: expected)
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            ProcessPipeReader.read(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            ),
            expected
        )
    }
}
