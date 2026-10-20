import AgentVisorNativeHelper
import Carbon
import Foundation
import XCTest

final class NativeGhosttyAppleEventsTests: XCTestCase {
    func testFocusesExactTerminalUsingTheSupportedScriptingDictionary() {
        var selected: String?
        var active = false
        let sdk = NativeGhosttyAppleEvents(pid: 42, transmit: { event in
            let command = event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue
            let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
            if command == NativeGhosttyAppleEvents.code("Fcus") {
                selected = direct.forKeyword( AEKeyword(keyAEKeyData))?.stringValue
                return NSAppleEventDescriptor.null()
            }
            let property = direct.forKeyword( AEKeyword(keyAEKeyData))!.typeCodeValue
            switch property {
            case NativeGhosttyAppleEvents.code("pnam"): return NSAppleEventDescriptor(string: "◐ conversation")
            case NativeGhosttyAppleEvents.code("Gwdr"): return NSAppleEventDescriptor(string: "/project")
            case NativeGhosttyAppleEvents.code("GFWn"): return NSAppleEventDescriptor(string: "window-object")
            case NativeGhosttyAppleEvents.code("GWsT"): return NSAppleEventDescriptor(string: "tab-object")
            case NativeGhosttyAppleEvents.code("GTfT"): return NSAppleEventDescriptor(string: "terminal-object")
            case NativeGhosttyAppleEvents.code("ID  "): return NSAppleEventDescriptor(string: selected ?? "other")
            case NativeGhosttyAppleEvents.code("pisf"): return NSAppleEventDescriptor(boolean: active)
            default: return nil
            }
        }, activate: { active = true; return true })

        XCTAssertTrue(sdk.focus(terminalID: "terminal-a", expectedTitle: "✳ conversation", expectedCWD: "/project"))
        XCTAssertEqual(selected, "terminal-a")
        XCTAssertTrue(active)
    }

    func testRejectsChangedPropertiesWrongSurfaceAndActivationFailure() {
        for failure in ["title-before", "cwd-before", "title-after", "wrong-surface", "activation", "not-frontmost", "missing-reply"] {
            var selected = false
            let sdk = NativeGhosttyAppleEvents(pid: 42, transmit: { event in
                if failure == "missing-reply" { return nil }
                if event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == NativeGhosttyAppleEvents.code("Fcus") {
                    selected = true; return .null()
                }
                let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
                switch direct.forKeyword(AEKeyword(keyAEKeyData))!.typeCodeValue {
                case NativeGhosttyAppleEvents.code("pnam"):
                    return .init(string: failure == "title-before" || (selected && failure == "title-after") ? "other" : "conversation")
                case NativeGhosttyAppleEvents.code("Gwdr"): return .init(string: failure == "cwd-before" ? "/other" : "/project")
                case NativeGhosttyAppleEvents.code("GFWn"), NativeGhosttyAppleEvents.code("GWsT"), NativeGhosttyAppleEvents.code("GTfT"):
                    return .init(string: "object")
                case NativeGhosttyAppleEvents.code("ID  "): return .init(string: failure == "wrong-surface" ? "other" : "exact")
                case NativeGhosttyAppleEvents.code("pisf"): return .init(boolean: failure != "not-frontmost")
                default: return nil
                }
            }, activate: { failure != "activation" })
            XCTAssertFalse(sdk.focus(terminalID: "exact", expectedTitle: "conversation", expectedCWD: "/project"), failure)
            if ["title-before", "cwd-before", "missing-reply"].contains(failure) { XCTAssertFalse(selected, failure) }
        }
    }
}
