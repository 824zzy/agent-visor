public enum NativeMenuScreenSelectionPolicy {
    public static func resolve(
        preference: NativeHelperPillScreen,
        screens: [NativeHelperScreen]
    ) -> UInt32? {
        switch preference.mode {
        case .automatic:
            return screens.first(where: \.isBuiltIn)?.displayId
                ?? screens.first(where: \.isMain)?.displayId
                ?? screens.first?.displayId
        case .specific:
            if let displayId = preference.displayId,
               screens.contains(where: { $0.displayId == displayId }) {
                return displayId
            }
            if let name = preference.name,
               let screen = screens.first(where: { $0.name == name }) {
                return screen.displayId
            }
            return resolve(preference: .automatic, screens: screens)
        }
    }
}
