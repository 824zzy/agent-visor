import XCTest
@testable import AgentVisorCore

final class NativeMenuScreenSelectionPolicyTests: XCTestCase {
    private let rectangle = NativeHelperRectangle(x: 0, y: 0, width: 1_512, height: 982)

    func testAutomaticPrefersTheBuiltInScreenThenTheMainScreen() {
        let external = screen(id: 5, name: "XZ322QU V3", isBuiltIn: false, isMain: true)
        let builtIn = screen(id: 1, name: "Built-in Retina Display", isBuiltIn: true)

        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .automatic,
                screens: [external, builtIn]
            ),
            1
        )
        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .automatic,
                screens: [external]
            ),
            5
        )
    }

    func testSpecificScreenUsesIDThenNameAndFallsBackToAutomatic() {
        let builtIn = screen(id: 1, name: "Built-in Retina Display", isBuiltIn: true)
        let external = screen(id: 5, name: "XZ322QU V3")

        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .specific(displayId: 5, name: "XZ322QU V3"),
                screens: [builtIn, external]
            ),
            5
        )
        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .specific(displayId: 99, name: "XZ322QU V3"),
                screens: [builtIn, external]
            ),
            5
        )
        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .specific(displayId: 99, name: "Missing"),
                screens: [builtIn, external]
            ),
            1
        )
    }

    private func screen(
        id: UInt32,
        name: String,
        isBuiltIn: Bool = false,
        isMain: Bool = false
    ) -> NativeHelperScreen {
        NativeHelperScreen(
            displayId: id,
            name: name,
            isBuiltIn: isBuiltIn,
            frame: rectangle,
            visibleFrame: rectangle,
            scale: 2,
            isMain: isMain
        )
    }
}
