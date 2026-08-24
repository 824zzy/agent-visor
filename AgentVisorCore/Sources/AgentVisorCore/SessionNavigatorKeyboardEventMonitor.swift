import AppKit
import Combine

@MainActor
public final class SessionNavigatorKeyboardEventMonitor: ObservableObject {
    public var onEvent: ((SessionNavigatorKeyboardEvent) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?

    public init() {}

    public func start() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let keyboardEvent = SessionNavigatorKeyboardInputPolicy.event(
                    keyCode: event.keyCode,
                    modifiers: Self.modifiers(event.modifierFlags),
                    text: event.characters
                  ) else { return event }
            self.onEvent?(keyboardEvent)
            return nil
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<SessionNavigatorKeyboardEventMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let keyboardEvent = SessionNavigatorKeyboardInputPolicy.event(
            keyCode: keyCode,
            modifiers: Self.modifiers(event.flags),
            text: Self.text(from: event)
        ) else { return Unmanaged.passUnretained(event) }
        onEvent?(keyboardEvent)
        return nil
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> ModifierMask {
        var result: ModifierMask = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private static func modifiers(_ flags: CGEventFlags) -> ModifierMask {
        var result: ModifierMask = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }

    private static func text(from event: CGEvent) -> String? {
        var characters = [UniChar](repeating: 0, count: 16)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &length,
            unicodeString: &characters
        )
        return length > 0 ? String(utf16CodeUnits: characters, count: length) : nil
    }
}
