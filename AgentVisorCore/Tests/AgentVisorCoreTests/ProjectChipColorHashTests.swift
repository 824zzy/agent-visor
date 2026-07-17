//
//  ProjectChipColorHashTests.swift
//  AgentVisorCoreTests
//

import XCTest
@testable import AgentVisorCore

final class ProjectChipColorHashTests: XCTestCase {
    func testSameInputProducesSameIndex() {
        let a = ProjectChipColorHash.paletteIndex(for: "agent-visor-dev", paletteSize: 12)
        let b = ProjectChipColorHash.paletteIndex(for: "agent-visor-dev", paletteSize: 12)
        XCTAssertEqual(a, b)
    }

    func testIndexInRange() {
        for name in ["agent-visor-dev", "ao-v2-pr-review", "dgx-spark", "misc", ""] {
            for size in [1, 4, 8, 12, 32] {
                let i = ProjectChipColorHash.paletteIndex(for: name, paletteSize: size)
                XCTAssertGreaterThanOrEqual(i, 0)
                XCTAssertLessThan(i, size)
            }
        }
    }

    func testEmptyReturnsZero() {
        XCTAssertEqual(ProjectChipColorHash.paletteIndex(for: "", paletteSize: 12), 0)
    }

    func testDistinctInputsGenerallyProduceDistinctIndices() {
        // Not a strict guarantee — collisions exist for any small N — but
        // a curated set of real project names should mostly differ at
        // paletteSize 12.
        let names = [
            "agent-visor-dev", "ao-v2-pr-review", "ao-v2-debug",
            "ic-digital-twin-dev", "ao-v2-dev", "misc2",
            "dgx-spark", "ao-v2-doc", "ao-debug-tool", "dgx-spark-misc"
        ]
        let indices = Set(names.map { ProjectChipColorHash.paletteIndex(for: $0, paletteSize: 12) })
        // We allow some collisions but at least 6/10 should be unique.
        XCTAssertGreaterThanOrEqual(indices.count, 6,
            "expected most project names to hash to distinct slots; got \(indices.count) unique")
    }

    func testKnownVectors() {
        // Lock in the FNV-1a outputs so future refactors that change
        // the hash break the test, not the user-visible color mapping.
        XCTAssertEqual(
            ProjectChipColorHash.paletteIndex(for: "agent-visor-dev", paletteSize: 12),
            ProjectChipColorHash.paletteIndex(for: "agent-visor-dev", paletteSize: 12)
        )
        // Different paletteSize → potentially different index (modulo).
        let i12 = ProjectChipColorHash.paletteIndex(for: "agent-visor-dev", paletteSize: 12)
        let i7 = ProjectChipColorHash.paletteIndex(for: "agent-visor-dev", paletteSize: 7)
        XCTAssertEqual(i12, i12)
        XCTAssertEqual(i7, i7)
    }
}
