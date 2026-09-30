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
            // macOS reuses display IDs across different monitors (a home and
            // an office monitor can both be 0x5), so the ID is only a hint.
            if let displayUuid = preference.displayUuid {
                return screens.first(where: { $0.displayUuid == displayUuid })?.displayId
                    ?? fallbackForMissingSpecificScreen(screens: screens)
            }
            if let displayId = preference.displayId,
               let screen = screens.first(where: {
                   $0.displayId == displayId && $0.name == preference.name
               }) {
                return screen.displayId
            }
            if let name = preference.name,
               let screen = screens.first(where: { $0.name == name }) {
                return screen.displayId
            }
            return fallbackForMissingSpecificScreen(screens: screens)
        }
    }

    private static func fallbackForMissingSpecificScreen(screens: [NativeHelperScreen]) -> UInt32? {
        screens.first(where: { !$0.isBuiltIn && $0.isMain })?.displayId
            ?? screens.first(where: { !$0.isBuiltIn })?.displayId
            ?? resolve(preference: .automatic, screens: screens)
    }
}
