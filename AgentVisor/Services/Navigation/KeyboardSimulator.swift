//
//  KeyboardSimulator.swift
//  AgentVisor
//
//  Simulates keyboard input via CGEvent for sending text to terminal panes.
//

import AppKit
import CoreGraphics

struct KeyboardSimulator {
    /// Type a string to the frontmost application
    static func typeGlobally(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for char in text {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            let chars = Array(String(char).utf16)
            keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(3000)
        }
    }

    /// Send Return key to the frontmost application
    static func pressReturnGlobally() {
        let source = CGEventSource(stateID: .combinedSessionState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
            keyDown.post(tap: .cghidEventTap)
            usleep(10000)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
