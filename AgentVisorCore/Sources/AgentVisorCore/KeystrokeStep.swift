import Foundation

/// One step in a mixed key/text input batch sent to a terminal pane.
/// - `key` uses the host terminal's named-key vocabulary ("arrowUp",
///   "arrowDown", "enter", "tab", "space", "escape"); printable chars
///   don't work via `send key` and must go through `text` instead.
/// - `text` types literal characters via the host terminal's
///   text-injection verb (Ghostty `input text`, iTerm2 `write text`),
///   the only reliable channel for free-form Unicode.
/// - `delay` pauses the AppleScript runtime mid-batch. Required after
///   keystrokes that trigger a TUI state transition (an `enter` that
///   advances to the next question, a `tab` that toggles input mode),
///   so React/Ink can remount the next component before subsequent
///   keys arrive — without this, fast successive keystrokes get
///   delivered to a stale component or dropped.
public enum KeystrokeStep: Equatable, Sendable {
    case key(String)
    case text(String)
    case delay(Double)
}
