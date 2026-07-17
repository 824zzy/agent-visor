//
//  CommandKeyMonitor.swift
//  AgentVisor
//
//  Publishes a Bool tracking whether the ⌘ modifier is currently held
//  down. Used by the sidebar to fade in ⌘1..⌘9 hotkey badges only
//  while the user is in "shortcut hunt" mode (Sketch / Figma idiom),
//  saving permanent visual chrome on each row.
//
//  Local NSEvent monitor (.flagsChanged + .keyDown/.keyUp) so the
//  monitor only updates while agent-visor is the key window — no
//  global hooks, no privacy implications, no battery drain when the
//  app is backgrounded.
//

import AppKit
import Combine

@MainActor
final class CommandKeyMonitor: ObservableObject {
    static let shared = CommandKeyMonitor()

    @Published private(set) var isCommandHeld: Bool = false

    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    private init() {
        installMonitors()
    }

    private func installMonitors() {
        // `.flagsChanged` fires when modifier-only keys are pressed
        // or released. `.keyDown` and `.keyUp` carry the modifier
        // state as well — we observe both so we don't miss a Cmd
        // press that arrived while a regular key was held (rare, but
        // possible during typing).
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags)
            return event
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.update(from: event.modifierFlags)
            return event
        }
        // Cmd-Tab away pulls Cmd-up out of our app's event loop —
        // the local monitors never see the release, so isCommandHeld
        // stays true forever and the ⌘N badges remain frozen on
        // every sidebar row until the next Cmd press-and-release.
        // `didResignActiveNotification` fires whenever agent-visor
        // loses focus, including the Cmd-Tab path; force-clear here.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.isCommandHeld { self.isCommandHeld = false }
            }
        }
    }

    private func update(from flags: NSEvent.ModifierFlags) {
        let isHeld = flags.contains(.command)
        if isHeld != isCommandHeld {
            isCommandHeld = isHeld
        }
    }
}
