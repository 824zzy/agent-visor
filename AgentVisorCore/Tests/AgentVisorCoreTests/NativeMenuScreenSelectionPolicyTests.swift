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

    func testLegacySpecificScreenUsesIDAndNameThenNameThenExternalFallback() {
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
            5
        )
    }

    func testSpecificScreenFollowsTheDisplayUUIDAcrossDisplayIDs() {
        let builtIn = screen(id: 1, name: "Built-in Retina Display", isBuiltIn: true)
        let home = screen(id: 7, name: "XZ322QU V3", uuid: homeUUID)
        let office = screen(id: 5, name: "DELL P3424WEB", uuid: officeUUID)

        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .specific(displayId: 5, name: "XZ322QU V3", displayUuid: homeUUID),
                screens: [builtIn, office, home]
            ),
            7
        )
    }

    func testSpecificScreenFallsBackToOtherExternalWithoutMatchingItsReusedID() {
        let builtIn = screen(id: 1, name: "Built-in Retina Display", isBuiltIn: true)
        let office = screen(id: 5, name: "DELL P3424WEB", uuid: officeUUID)

        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .specific(displayId: 5, name: "XZ322QU V3", displayUuid: homeUUID),
                screens: [builtIn, office]
            ),
            5
        )
        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .specific(displayId: 5, name: "XZ322QU V3"),
                screens: [builtIn, office]
            ),
            5
        )
    }

    func testCommutingFromOfficeToHomeUsesAvailableExternalWithoutChangingSavedOfficeIdentity() {
        let builtIn = screen(id: 1, name: "Built-in Retina Display", isBuiltIn: true)
        let home = screen(id: 5, name: "XZ322QU V3", isMain: true, uuid: homeUUID)

        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: .specific(displayId: 5, name: "DELL P3424WEB", displayUuid: officeUUID),
                screens: [builtIn, home]
            ),
            5
        )
    }

    func testMissingSelectedMonitorPrefersMainExternalThenAnyExternalThenBuiltIn() {
        let builtIn = screen(id: 1, name: "Built-in Retina Display", isBuiltIn: true, isMain: true)
        let secondary = screen(id: 7, name: "Other", uuid: homeUUID)
        let mainExternal = screen(id: 9, name: "Main", isMain: true)
        let preference = NativeHelperPillScreen.specific(
            displayId: 5, name: "DELL P3424WEB", displayUuid: officeUUID
        )

        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: preference,
                screens: [builtIn, secondary, mainExternal]
            ),
            9
        )
        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: preference,
                screens: [builtIn, secondary]
            ),
            7
        )
        XCTAssertEqual(
            NativeMenuScreenSelectionPolicy.resolve(
                preference: preference,
                screens: [builtIn]
            ),
            1
        )
    }

    private let homeUUID = "0B2C9A51-7D10-4E0B-8C55-1F2E3D4C5B6A"
    private let officeUUID = "1A108786-48D9-48F8-9611-48282BDABE1F"

    private func screen(
        id: UInt32,
        name: String,
        isBuiltIn: Bool = false,
        isMain: Bool = false,
        uuid: String? = nil
    ) -> NativeHelperScreen {
        NativeHelperScreen(
            displayId: id,
            displayUuid: uuid,
            name: name,
            isBuiltIn: isBuiltIn,
            frame: rectangle,
            visibleFrame: rectangle,
            scale: 2,
            isMain: isMain
        )
    }
}
