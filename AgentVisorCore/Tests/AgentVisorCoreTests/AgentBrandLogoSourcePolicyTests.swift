import AgentVisorCore
import XCTest

final class AgentBrandLogoSourcePolicyTests: XCTestCase {
    func testEveryAgentHasABundledBrandAsset() {
        let assets = Dictionary(uniqueKeysWithValues: AgentID.allCases.map {
            ($0, AgentBrandLogoSourcePolicy.source(for: $0).assetName)
        })

        XCTAssertEqual(assets[.claudeCode], "AgentClaude")
        XCTAssertEqual(assets[.auggie], "AgentAuggie")
        XCTAssertEqual(assets[.codex], "AgentCodex")
        XCTAssertEqual(assets[.cursor], "AgentCursor")
    }

    func testInstalledAppBrandsPreferTheirNativeHighResolutionIcons() {
        XCTAssertEqual(
            AgentBrandLogoSourcePolicy.source(for: .claudeCode).runtimeBundleIdentifier,
            "com.anthropic.claudefordesktop"
        )
        XCTAssertEqual(
            AgentBrandLogoSourcePolicy.source(for: .codex).runtimeBundleIdentifier,
            "com.openai.codex"
        )
        XCTAssertEqual(
            AgentBrandLogoSourcePolicy.source(for: .cursor).runtimeBundleIdentifier,
            "com.todesktop.230313mzl4w4u92"
        )
        XCTAssertNil(AgentBrandLogoSourcePolicy.source(for: .auggie).runtimeBundleIdentifier)
    }
}
