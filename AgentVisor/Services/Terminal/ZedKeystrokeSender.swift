//
//  ZedKeystrokeSender.swift
//  AgentVisor
//
//  Executes a [[ZedThreadRevealPlanner]] plan against a frontmost Zed.
//
//  Zed's agent threads have no deeplink and no accessible UI tree (GPUI
//  publishes only window chrome — probed on 1.14: three buttons, no
//  rows), so the only way to select a thread from outside is to drive
//  Zed's own keyboard path. That means synthetic key events, which have
//  exactly two safety requirements:
//
//   1. Zed must be frontmost before anything is posted. Otherwise the
//      chord and the typed title land in whatever app owns the keyboard.
//      The caller verifies this and this type re-checks per step.
//   2. Every keystroke must map to a documented default Zed binding, so
//      what we send is what a user would press by hand.
//
//  Bindings driven here (Zed's `default-macos.json`):
//    cmd-shift-p command_palette::Toggle
//    palette    multi_workspace::FocusWorkspaceSidebar
//    cmd-f      agents_sidebar::FocusSidebarFilter
//    cmd-a      editor::SelectAll
//    delete     editor::Backspace
//    down       menu::SelectNext
//    enter      menu::Confirm
//

import AgentVisorCore
import AppKit
import CoreGraphics
import Foundation
import os.log

enum ZedKeystrokeSender {
    private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "ZedKeystrokeSender"
    )

    /// Carbon virtual keycodes for the keys Zed's defaults use.
    private enum VirtualKey {
        static let p: CGKeyCode = 0x23
        static let f: CGKeyCode = 0x03
        static let a: CGKeyCode = 0x00
        static let delete: CGKeyCode = 0x33
        static let downArrow: CGKeyCode = 0x7D
        static let returnKey: CGKeyCode = 0x24
    }

    /// Runs `plan` while `app` stays frontmost. Returns false as soon as
    /// focus is lost, so a half-typed title never leaks into another app.
    @discardableResult
    static func run(plan: [ZedRevealStep], app: NSRunningApplication) -> Bool {
        guard !plan.isEmpty else { return false }
        for step in plan {
            guard TerminalHostActivator.isFrontmost(app) else {
                logger.error("run: aborted — Zed lost focus mid-plan")
                return false
            }
            switch step {
            case .delay(let seconds):
                usleep(useconds_t(max(0, seconds) * 1_000_000))
            case .text(let text):
                KeyboardSimulator.typeGlobally(text)
            case .key(let key):
                guard post(key: key) else { return false }
            }
        }
        return true
    }

    private static func post(key: ZedRevealKey) -> Bool {
        switch key {
        case .openCommandPalette:
            return post(keyCode: VirtualKey.p, flags: [.maskCommand, .maskShift])
        case .focusSidebarFilter:
            return post(keyCode: VirtualKey.f, flags: [.maskCommand])
        case .selectAll:
            return post(keyCode: VirtualKey.a, flags: [.maskCommand])
        case .deleteBackward:
            return post(keyCode: VirtualKey.delete, flags: [])
        case .selectNext:
            return post(keyCode: VirtualKey.downArrow, flags: [])
        case .confirm:
            return post(keyCode: VirtualKey.returnKey, flags: [])
        }
    }

    private static func post(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        usleep(12_000)
        keyUp.post(tap: .cghidEventTap)
        usleep(12_000)
        return true
    }
}
