import AppKit
import Carbon
import Foundation

/// Ghostty's installed SDEF: Ghst/Fcus and stable Gtrm IDs. No interpreter,
/// input events, subprocesses, or title/cwd-based terminal selection.
public final class NativeGhosttyAppleEvents {
    public struct Surface: Equatable {
        public let id: String
        public let title: String
        public let cwd: String
        public init(id: String, title: String, cwd: String) {
            self.id = id; self.title = title; self.cwd = cwd
        }
    }
    public typealias Transmit = (NSAppleEventDescriptor) -> NSAppleEventDescriptor?
    private let pid: Int32
    private let transmit: Transmit
    private let activate: () -> Bool

    public init(pid: Int32, transmit: Transmit? = nil, activate: (() -> Bool)? = nil) {
        self.pid = pid
        self.transmit = transmit ?? { event in
            // Permission is checked without prompting before sending any event.
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr else { return nil }
            // A cold macOS scripting reply can exceed 100ms. This is a failure
            // deadline, not a delay: fast replies still return immediately.
            guard let reply = try? event.sendEvent(options: [.waitForReply], timeout: 0.5),
                  reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0 == 0 else { return nil }
            return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
        }
        self.activate = activate ?? { NSRunningApplication(processIdentifier: pid)?.activate() ?? false }
    }

    public static func code(_ value: String) -> UInt32 {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func object(_ kind: String, form: UInt32, value: NSAppleEventDescriptor,
                               container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: code(kind)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(value, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    }

    private func request(_ eventClass: String, _ eventID: String, direct: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: Self.code(eventClass), eventID: Self.code(eventID),
            targetDescriptor: .init(processIdentifier: pid), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(direct, forKeyword: AEKeyword(keyDirectObject))
        return transmit(event)
    }

    private func property(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor? {
        guard let specifier = propertySpecifier(name, of: container) else { return nil }
        return request("core", "getd", direct: specifier)
    }

    private func propertySpecifier(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor? {
        Self.object("prop", form: UInt32(formPropertyID), value: .init(typeCode: Self.code(name)), container: container)
    }

    private func focusedTerminalID() -> String? {
        guard let window = propertySpecifier("GFWn"), let tab = propertySpecifier("GWsT", of: window),
              let terminal = propertySpecifier("GTfT", of: tab) else { return nil }
        // Ask the app to resolve the property chain in one round trip.
        return property("ID  ", of: terminal)?.stringValue
    }

    private func terminal(_ id: String) -> NSAppleEventDescriptor? {
        guard !id.isEmpty, id.utf16.count <= 128, !id.contains("\0") else { return nil }
        return Self.object("Gtrm", form: UInt32(formUniqueID), value: .init(string: id))
    }

    public func surface(id: String) -> Surface? {
        guard let terminal = terminal(id),
              let title = property("pnam", of: terminal)?.stringValue,
              let cwd = property("Gwdr", of: terminal)?.stringValue,
              !title.isEmpty, title.utf16.count <= 512, cwd.hasPrefix("/"), cwd.utf16.count <= 4096 else { return nil }
        return Surface(id: id, title: title, cwd: cwd)
    }

    public func surfaces() -> [Surface]? {
        // "all" is an absolute ordinal; an enum descriptor causes errAECoercionFail.
        let ordinal = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal,
            data: NSAppleEventDescriptor(enumCode: OSType(kAEAll)).data)
        guard let ordinal,
              let all = Self.object("Gtrm", form: UInt32(formAbsolutePosition), value: ordinal),
              let terminals = request("core", "getd", direct: all), terminals.descriptorType == typeAEList,
              terminals.numberOfItems <= 128 else { return nil }
        var result: [Surface] = []
        for index in 1..<(terminals.numberOfItems + 1) {
            guard let terminal = terminals.atIndex(index), let id = property("ID  ", of: terminal)?.stringValue,
                  let value = surface(id: id), !result.contains(where: { $0.id == id }) else { return nil }
            result.append(value)
        }
        return result
    }

    public func focus(terminalID: String, expectedTitle: String?, expectedCWD: String?) -> Bool {
        func matches() -> Bool {
            if expectedTitle == nil && expectedCWD == nil {
                guard let target = terminal(terminalID) else { return false }
                return property("ID  ", of: target)?.stringValue == terminalID
            }
            guard let surface = surface(id: terminalID) else { return false }
            let normalized: (String) -> String = { value in
                value.range(of: #"^[✳◐◑] "#, options: .regularExpression) == nil ? value : String(value.dropFirst(2))
            }
            return (expectedTitle.map { normalized($0) == normalized(surface.title) } ?? true)
                && (expectedCWD.map { $0 == surface.cwd } ?? true)
        }
        guard let target = terminal(terminalID), matches(),
              activate(), request("Ghst", "Fcus", direct: target) != nil,
              focusedTerminalID() == terminalID,
              property("pisf")?.booleanValue == true, matches() else { return false }
        return true
    }
}
