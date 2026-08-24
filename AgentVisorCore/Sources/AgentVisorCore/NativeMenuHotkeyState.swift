import Foundation

public struct NativeMenuHotkeyState {
    private var trigger = NativeHelperHotkeyTrigger.shift
    private var customCombo: KeyCombo?
    private var detector = HotkeyDoubleTapDetector(config: .standard)

    public init() {}

    public mutating func configure(
        trigger: NativeHelperHotkeyTrigger,
        customCombo: KeyCombo?
    ) {
        guard trigger != self.trigger || customCombo != self.customCombo else { return }
        self.trigger = trigger
        self.customCombo = customCombo
        detector = HotkeyDoubleTapDetector(config: .standard)
    }

    public mutating func modifierFlagsChanged(
        _ pressed: ModifierMask,
        at date: Date
    ) -> Bool {
        guard let modifier = triggerModifier else { return false }
        let input: HotkeyDoubleTapDetector.Input
        if pressed == modifier {
            input = .triggerDown(at: date)
        } else if !pressed.contains(modifier) {
            input = .triggerUp(at: date)
        } else {
            input = .foreignModifierHeld(at: date)
        }
        return detector.handle(input) == .fired
    }

    public mutating func keyDown(
        keyCode: UInt16,
        modifiers: ModifierMask,
        at date: Date
    ) -> Bool {
        if trigger == .custom {
            return customCombo == KeyCombo(keyCode: keyCode, modifiers: modifiers)
        }
        _ = detector.handle(.nonModifierKeyDown(at: date))
        return false
    }

    private var triggerModifier: ModifierMask? {
        switch trigger {
        case .off, .custom: nil
        case .cmd: .command
        case .ctrl: .control
        case .option: .option
        case .shift: .shift
        }
    }
}
