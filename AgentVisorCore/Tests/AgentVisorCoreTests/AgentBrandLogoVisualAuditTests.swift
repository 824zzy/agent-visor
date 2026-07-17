import XCTest

final class AgentBrandLogoVisualAuditTests: XCTestCase {
    func testEveryLogoUsesTheSharedHighResolutionSourcePolicy() throws {
        let source = try String(contentsOf: appSourceURL(
            "AgentVisor/UI/Components/AgentBrandLogo.swift"
        ))

        XCTAssertTrue(source.contains("AgentBrandLogoSourcePolicy.source(for: agent)"))
        XCTAssertTrue(source.contains("AgentBrandIconCache.image(for: source)"))
        XCTAssertTrue(source.contains("Image(source.assetName)"))
        XCTAssertFalse(source.contains("assetName(for: agent)"))
        XCTAssertFalse(source.contains("AuggieMonogramShape"))
    }

    func testEveryBundledBrandAssetSupportsLargeInspectorRendering() throws {
        let assetsRoot = appSourceURL("AgentVisor/Assets.xcassets/AgentBrand")
        let brands = ["AgentClaude", "AgentAuggie", "AgentCodex", "AgentCursor"]
        let variants = [("", 128), ("@2x", 256), ("@3x", 384)]

        for brand in brands {
            for (suffix, minimumEdge) in variants {
                let imageURL = assetsRoot
                    .appendingPathComponent("\(brand).imageset")
                    .appendingPathComponent("\(brand)\(suffix).png")
                let dimensions = try pngDimensions(at: imageURL)
                XCTAssertGreaterThanOrEqual(
                    min(dimensions.width, dimensions.height),
                    minimumEdge,
                    "\(brand)\(suffix) is too small for the inspector header"
                )
            }
        }
    }

    func testAgentIdentitySurfacesUseBrandLogosInsteadOfPlaceholderSymbols() throws {
        let splitSource = try String(contentsOf: appSourceURL(
            "AgentVisor/UI/Window/MainSplitView.swift"
        ))
        let settingsSource = try String(contentsOf: appSourceURL(
            "AgentVisor/UI/Window/SettingsWindowView.swift"
        ))

        XCTAssertTrue(splitSource.contains("AgentBrandLogo(agent: item.agentID, size: 28)"))
        XCTAssertTrue(settingsSource.contains("AgentBrandLogo(agent: agentIcon, size: 16)"))
        XCTAssertFalse(splitSource.contains("AgentBrand.symbolName"))
        XCTAssertFalse(settingsSource.contains("AgentBrand.symbolName"))
    }

    private func appSourceURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    private func pngDimensions(at url: URL) throws -> (width: Int, height: Int) {
        let data = try Data(contentsOf: url)
        guard data.count >= 24 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func value(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        return (value(at: 16), value(at: 20))
    }
}
