import XCTest
@testable import AgentVisorCore

final class MenuBarOwnerResolverTests: XCTestCase {
    private func owner(
        frontmost: pid_t? = 100,
        frontmostHasWindow: Bool = true,
        topmost: pid_t? = 200,
        separateSpaces: Bool = true,
        single: Bool = false
    ) -> pid_t? {
        MenuBarOwnerResolver.owner(
            frontmostPid: frontmost,
            frontmostHasWindowOnTargetScreen: frontmostHasWindow,
            topmostOnTargetPid: topmost,
            separateSpaces: separateSpaces,
            isSingleScreen: single
        )
    }

    func testSingleScreenAlwaysFrontmost() {
        XCTAssertEqual(owner(frontmost: 100, topmost: 200, single: true), 100)
    }

    func testSharedMenuBarAlwaysFrontmost() {
        // separate spaces off → one shared menu bar follows frontmost.
        XCTAssertEqual(owner(frontmost: 100, topmost: 200, separateSpaces: false), 100)
    }

    func testFrontmostWithWindowOnTargetScreenOwnsMenu() {
        // The regression case: Chrome (frontmost, has a window on the target
        // screen) owns the menu — NOT Obsidian (topmost background window).
        XCTAssertEqual(owner(frontmost: 100, frontmostHasWindow: true, topmost: 200), 100)
    }

    func testFrontmostOnOtherDisplayFallsBackToTopmost() {
        // Frontmost app has no window on the target screen (it's active on an
        // external display) → target menu belongs to the topmost-on-target app.
        XCTAssertEqual(owner(frontmost: 100, frontmostHasWindow: false, topmost: 200), 200)
    }

    func testTopmostOnTargetScreenIsAConfidentResolution() {
        let resolution = MenuBarOwnerResolver.resolve(
            frontmostPid: 100,
            frontmostHasWindowOnTargetScreen: false,
            topmostOnTargetPid: 200,
            separateSpaces: true,
            isSingleScreen: false
        )

        XCTAssertEqual(resolution.ownerPid, 200)
        XCTAssertEqual(resolution.source, .topmostOnTargetScreen)
        XCTAssertTrue(resolution.isConfident)
    }

    func testFrontmostOnOtherDisplayNoTopmostFallsBackToFrontmost() {
        XCTAssertEqual(owner(frontmost: 100, frontmostHasWindow: false, topmost: nil), 100)
    }

    func testFrontmostFallbackIsMarkedUnresolved() {
        let resolution = MenuBarOwnerResolver.resolve(
            frontmostPid: 100,
            frontmostHasWindowOnTargetScreen: false,
            topmostOnTargetPid: nil,
            separateSpaces: true,
            isSingleScreen: false
        )

        XCTAssertEqual(resolution.ownerPid, 100)
        XCTAssertEqual(resolution.source, .fallbackFrontmost)
        XCTAssertFalse(resolution.isConfident)
    }

    func testNilFrontmostWithWindowFlagFalseUsesTopmost() {
        XCTAssertEqual(owner(frontmost: nil, frontmostHasWindow: false, topmost: 200), 200)
    }
}
