import AppKit
import XCTest
@testable import AgentVisorNativeHelper

final class NativeMenuOwnerProbeTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 2_056, height: 1_329)
    private let external = CGRect(x: -880, y: -1_440, width: 3_440, height: 1_440)

    func testRetainedMenuOwnsThePillMonitorAfterFocusMovesToAnotherDisplay() {
        var focusedDisplay = laptop
        let readMenu: (CGPoint) -> NativeMenuOwnerProbe.Hit? = { point in
            guard let display = [self.laptop, self.external].first(where: { $0.contains(point) })
                else { return nil }
            return .init(
                pid: display == self.laptop ? 100 : 200,
                role: display == focusedDisplay ? kAXMenuBarItemRole as String : kAXMenuBarRole as String
            )
        }

        XCTAssertEqual(NativeMenuOwnerProbe.ownerPID(on: laptop, hitTest: readMenu), 100)
        focusedDisplay = external
        XCTAssertEqual(NativeMenuOwnerProbe.ownerPID(on: laptop, hitTest: readMenu), 100)
        XCTAssertEqual(NativeMenuOwnerProbe.ownerPID(on: external, hitTest: readMenu), 200)
        focusedDisplay = laptop
        XCTAssertEqual(NativeMenuOwnerProbe.ownerPID(on: external, hitTest: readMenu), 200)
    }

    func testFocusChangeDuringMenuReadCannotAuthorizeAnOwner() {
        var reads = 0
        let owner = NativeMenuOwnerProbe.ownerPID(on: external) { _ in
            reads += 1
            return .init(pid: reads == 1 ? 100 : 200, role: kAXMenuBarRole as String)
        }
        XCTAssertNil(owner)
    }

    func testWindowAndStatusItemHitsCannotAuthorizeAMenuOwner() {
        for role in [kAXWindowRole as String, kAXButtonRole as String, "AXMenuExtra"] {
            for invalidRead in [1, 2] {
                var reads = 0
                XCTAssertNil(NativeMenuOwnerProbe.ownerPID(on: laptop) { _ in
                    reads += 1
                    return .init(pid: 100, role: reads == invalidRead ? role : kAXMenuBarRole as String)
                }, role)
            }
        }
    }

    func testMissingProcessCannotAuthorizeAMenuOwner() {
        for pid: pid_t in [0, -1] {
            XCTAssertNil(NativeMenuOwnerProbe.ownerPID(on: laptop) { _ in
                .init(pid: pid, role: kAXMenuBarRole as String)
            })
        }
    }

    func testUnreadableMenuCannotAuthorizeAnOwner() {
        for missingRead in [1, 2] {
            var reads = 0
            XCTAssertNil(NativeMenuOwnerProbe.ownerPID(on: external) { _ in
                reads += 1
                return reads == missingRead ? nil
                    : .init(pid: 100, role: kAXMenuBarRole as String)
            })
        }
    }

    func testInvalidDisplayCannotProbeAnotherDisplaysMenu() {
        for screen in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)] {
            XCTAssertNil(NativeMenuOwnerProbe.ownerPID(on: screen) { _ in
                XCTFail("invalid display geometry must not authorize any menu")
                return .init(pid: 100, role: kAXMenuBarRole as String)
            })
        }
    }
}
