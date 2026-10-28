import AgentVisorCore
import AgentVisorNativeHelper
import Carbon
import XCTest

final class NativeGhosttyMetadataNavigationTests: XCTestCase {
    private final class Wire {
        var rows: [NativeGhosttyAppleEvents.Surface]
        var missingCWD = false
        var selected: String?
        var active = false
        init(_ rows: [NativeGhosttyAppleEvents.Surface]) { self.rows = rows }
        lazy var sdk = NativeGhosttyAppleEvents(pid: 7, transmit: { [unowned self] event in
            guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return nil }
            if event.attributeDescriptor(forKeyword: AEKeyword(keyEventIDAttr))?.typeCodeValue == NativeGhosttyAppleEvents.code("Fcus") {
                self.selected = direct.forKeyword(AEKeyword(keyAEKeyData))?.stringValue
                return .null()
            }
            if direct.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == NativeGhosttyAppleEvents.code("Gtrm") {
                let list = NSAppleEventDescriptor.list()
                for (index, row) in self.rows.enumerated() {
                    let reference = NSAppleEventDescriptor.record()
                    reference.setDescriptor(.init(typeCode: NativeGhosttyAppleEvents.code("Gtrm")), forKeyword: AEKeyword(keyAEDesiredClass))
                    reference.setDescriptor(.init(enumCode: UInt32(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
                    reference.setDescriptor(.init(string: row.id), forKeyword: AEKeyword(keyAEKeyData))
                    reference.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
                    list.insert(reference.coerce(toDescriptorType: typeObjectSpecifier)!, at: index + 1)
                }
                return list
            }
            let key = direct.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue
            let id = direct.forKeyword(AEKeyword(keyAEContainer))?.forKeyword(AEKeyword(keyAEKeyData))?.stringValue
            if key == NativeGhosttyAppleEvents.code("pisf") { return .init(boolean: self.active) }
            if key == NativeGhosttyAppleEvents.code("ID  "), id == nil { return .init(string: self.selected ?? "other") }
            guard let row = self.rows.first(where: { $0.id == id }) else { return nil }
            switch key {
            case NativeGhosttyAppleEvents.code("ID  "): return .init(string: row.id)
            case NativeGhosttyAppleEvents.code("pnam"): return .init(string: row.title)
            case NativeGhosttyAppleEvents.code("Gwdr"): return self.missingCWD ? nil : .init(string: row.cwd)
            default: return nil
            }
        }, activate: { [unowned self] in self.active = true; return true })
    }

    func testHerdrBindingWithEmptyDirectoryKeepsExactProcessAndNonceGuards() throws {
        let nonce = String(repeating: "a", count: 32)
        let wire = Wire([.init(id: "herdr", title: "AVB:" + nonce, cwd: "")])
        let target = NativeHelperGhosttyBinding(applicationPID: 7, processStartToken: "app-one",
            windowId: "window", tabId: "tab", terminalId: "herdr", nonce: nonce)
        var processIdentity = "client-one"
        let controller = NativeGhosttyBindingController(resolveApplication: { .init(pid: 7, token: "app-one") },
            execute: { _ in XCTFail("Unexpected fallback"); return nil }, permission: { true },
            isFrontmost: { _ in wire.active }, surface: { wire.sdk.surface(id: $0) },
            focusSurface: { wire.sdk.focus(terminalID: $0, expectedTitle: nil, expectedCWD: nil) },
            processIdentity: { _ in processIdentity })
        let processes = [NativeHelperProcessIdentity(pid: 42, processStartToken: "client-one")]
        XCTAssertTrue(controller.prepare(target, processes: processes))
        wire.rows[0] = .init(id: "herdr", title: "Herdr", cwd: "")
        try controller.focus(target)
        XCTAssertEqual(wire.selected, "herdr")
        processIdentity = "replaced-client"; wire.selected = nil
        XCTAssertThrowsError(try controller.focus(target)); XCTAssertNil(wire.selected)
        XCTAssertFalse(controller.prepare(target, processes: processes), "Released nonce cannot mint a new capability")
    }

    func testMixedInventoryDoesNotLoseExactTerminalPreparation() {
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: "process-one", tty: "ttys001", cwd: "/project")
        let wire = Wire([.init(id: "herdr", title: "Herdr", cwd: ""),
                         .init(id: "conversation", title: "Conversation", cwd: "/project")])
        XCTAssertEqual(wire.sdk.surfaces()?.map(\.id), ["herdr", "conversation"])
        let routes = NativeGhosttyPreparedRoutes(environment: .init(
            application: { .init(pid: 7, token: "app-one") }, verify: { $0 == target },
            surfaces: { wire.sdk.surfaces() }, surface: { wire.sdk.surface(id: $0) },
            focus: { wire.sdk.focus(terminalID: $0, expectedTitle: $1, expectedCWD: $2) },
            viewMode: { _, _ in .conversation }, writeMetadata: { cwd, actual in
                guard actual == target else { return false }
                wire.rows[1] = .init(id: "conversation", title: "Conversation", cwd: cwd); return true
            }, pause: {}))
        XCTAssertTrue(routes.prepare(target)); XCTAssertNil(wire.selected)
        XCTAssertEqual(routes.focus(target), true); XCTAssertEqual(wire.selected, "conversation")
    }

    func testMissingDirectoryCannotSatisfyAnExplicitDirectoryGuard() {
        let wire = Wire([.init(id: "exact", title: "Conversation", cwd: "")])
        XCTAssertFalse(wire.sdk.focus(terminalID: "exact", expectedTitle: "Conversation", expectedCWD: "/project"))
        XCTAssertNil(wire.selected)
    }

    func testUnreadableOrMalformedDirectoryRemainsRejected() {
        let wire = Wire([.init(id: "exact", title: "Conversation", cwd: "/project")])
        wire.missingCWD = true; XCTAssertNil(wire.sdk.surface(id: "exact"))
        wire.missingCWD = false
        for cwd in ["relative", String(repeating: "/", count: 4097)] {
            wire.rows[0] = .init(id: "exact", title: "Conversation", cwd: cwd)
            XCTAssertNil(wire.sdk.surface(id: "exact"))
        }
    }
}
