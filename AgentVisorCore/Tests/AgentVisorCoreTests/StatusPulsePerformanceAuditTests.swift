import Foundation
import XCTest

/// Guards the Ready-pulse indicators against the per-frame relayout that
/// pinned WindowServer on 2026-08-04: `sessionStatusColor` (NSColor colorspace
/// conversions) was re-resolved inside a raw display-rate `TimelineView`
/// closure. The pulse must resolve its color once per state change and animate
/// only opacity on a throttled schedule.
final class StatusPulsePerformanceAuditTests: XCTestCase {
    func testSessionStatusDotResolvesColorOncePerStateNotPerFrame() throws {
        try assertPulseIsFrameCheap(
            file: "AgentVisor/UI/Components/SessionStatusDot.swift",
            builderSignature: "private func dot(color: Color"
        )
    }

    func testSessionStatusStripeResolvesColorOncePerStateNotPerFrame() throws {
        try assertPulseIsFrameCheap(
            file: "AgentVisor/UI/Components/SessionStatusStripe.swift",
            builderSignature: "private func stripe(color: Color"
        )
    }

    private func assertPulseIsFrameCheap(file: String, builderSignature: String) throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent(file))

        XCTAssertTrue(
            source.contains("TimelineView(.animation(minimumInterval:"),
            "\(file): the pulse must use a throttled TimelineView schedule."
        )
        XCTAssertFalse(
            source.contains("TimelineView(.animation) {"),
            "\(file): the pulse must not tick at the raw display refresh."
        )
        XCTAssertTrue(
            source.contains(builderSignature),
            "\(file): the per-frame builder must accept a precomputed color."
        )

        guard let builderStart = source.range(of: builderSignature)?.lowerBound,
              let builderEnd = source.range(
                of: "private func pulseOpacity",
                range: builderStart..<source.endIndex
              )?.lowerBound else {
            return XCTFail("\(file): could not isolate the per-frame builder.")
        }
        let builder = String(source[builderStart..<builderEnd])
        XCTAssertFalse(
            builder.contains("sessionStatusColor("),
            "\(file): the per-frame builder must not re-resolve sessionStatusColor."
        )

        guard let bodyStart = source.range(of: "var body: some View {")?.upperBound,
              let bodyEnd = source.range(
                of: builderSignature,
                range: bodyStart..<source.endIndex
              )?.lowerBound else {
            return XCTFail("\(file): could not isolate body.")
        }
        let body = String(source[bodyStart..<bodyEnd])
        XCTAssertTrue(
            body.contains("sessionStatusColor("),
            "\(file): body must resolve the status color once before animating."
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
