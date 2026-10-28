import AgentVisorNativeHelper
import Carbon
import Foundation
import XCTest

final class NativeGhosttyAppleEventsTests: XCTestCase {
    func testFocusSelectsExactTerminalAfterActivationRestoresPreviousWindow() {
        var selected = "previous"
        var active = false
        let sdk = NativeGhosttyAppleEvents(pid: 42, transmit: { event in
            if event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == NativeGhosttyAppleEvents.code("Fcus") {
                selected = "exact"
                return .null()
            }
            let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
            switch direct.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue {
            case NativeGhosttyAppleEvents.code("ID  "):
                let container = direct.forKeyword(AEKeyword(keyAEContainer))!
                return .init(string: container.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue
                    == NativeGhosttyAppleEvents.code("Gtrm") ? "exact" : selected)
            case NativeGhosttyAppleEvents.code("pisf"): return .init(boolean: active)
            default: return nil
            }
        }, activate: {
            // macOS may restore the previously active window when the app activates.
            active = true
            selected = "previous"
            return true
        })

        XCTAssertTrue(sdk.focus(terminalID: "exact", expectedTitle: nil, expectedCWD: nil))
        XCTAssertEqual(selected, "exact")
    }

    func testDiscoversEveryTerminalForPreparingExactFocus() {
        let surfaces = [
            NativeGhosttyAppleEvents.Surface(id: "terminal-a", title: "First conversation", cwd: "/project/a"),
            NativeGhosttyAppleEvents.Surface(id: "terminal-b", title: "Second conversation", cwd: "/project/b"),
        ]
        let sdk = NativeGhosttyAppleEvents(pid: 42, transmit: { event in
            guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return nil }
            if direct.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == NativeGhosttyAppleEvents.code("Gtrm") {
                // Cocoa requires an absolute ordinal for "every terminal".
                // An enumeration with the same four bytes is rejected by Ghostty.
                guard direct.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == UInt32(formAbsolutePosition),
                      let selector = direct.forKeyword(AEKeyword(keyAEKeyData)),
                      selector.descriptorType == typeAbsoluteOrdinal,
                      selector.typeCodeValue == OSType(kAEAll) else { return nil }
                let list = NSAppleEventDescriptor.list()
                for (index, surface) in surfaces.enumerated() {
                    let reference = NSAppleEventDescriptor.record()
                    reference.setDescriptor(.init(typeCode: NativeGhosttyAppleEvents.code("Gtrm")), forKeyword: AEKeyword(keyAEDesiredClass))
                    reference.setDescriptor(.init(enumCode: UInt32(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
                    reference.setDescriptor(.init(string: surface.id), forKeyword: AEKeyword(keyAEKeyData))
                    reference.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
                    list.insert(reference.coerce(toDescriptorType: typeObjectSpecifier)!, at: index + 1)
                }
                return list
            }
            guard let id = direct.forKeyword(AEKeyword(keyAEContainer))?.forKeyword(AEKeyword(keyAEKeyData))?.stringValue,
                  let surface = surfaces.first(where: { $0.id == id }) else { return nil }
            switch direct.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue {
            case NativeGhosttyAppleEvents.code("ID  "): return .init(string: surface.id)
            case NativeGhosttyAppleEvents.code("pnam"): return .init(string: surface.title)
            case NativeGhosttyAppleEvents.code("Gwdr"): return .init(string: surface.cwd)
            default: return nil
            }
        })

        XCTAssertEqual(sdk.surfaces(), surfaces)
    }

    func testPreparedFocusReadsTheExactSelectionWithoutWalkingWindowProperties() {
        var selected = false
        var events = 0
        let sdk = NativeGhosttyAppleEvents(pid: 42, transmit: { event in
            events += 1
            let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
            if event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == NativeGhosttyAppleEvents.code("Fcus") {
                selected = true; return .null()
            }
            switch direct.forKeyword(AEKeyword(keyAEKeyData))!.typeCodeValue {
            case NativeGhosttyAppleEvents.code("ID  "):
                let container = direct.forKeyword(AEKeyword(keyAEContainer))!
                if container.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == NativeGhosttyAppleEvents.code("Gtrm") {
                    return .init(string: "exact")
                }
                let focused = container.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue
                let tab = container.forKeyword(AEKeyword(keyAEContainer))
                let window = tab?.forKeyword(AEKeyword(keyAEContainer))
                guard focused == NativeGhosttyAppleEvents.code("GTfT"),
                      tab?.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == NativeGhosttyAppleEvents.code("GWsT"),
                      window?.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == NativeGhosttyAppleEvents.code("GFWn") else { return nil }
                return .init(string: selected ? "exact" : "other")
            case NativeGhosttyAppleEvents.code("pisf"): return .init(boolean: selected)
            default: return nil
            }
        }, activate: { true })
        XCTAssertTrue(sdk.focus(terminalID: "exact", expectedTitle: nil, expectedCWD: nil))
        XCTAssertLessThanOrEqual(events, 5)
    }

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
