import Foundation

public struct SRGBColorComponents: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Int, green: Int, blue: Int) {
        self.red = Double(red) / 255
        self.green = Double(green) / 255
        self.blue = Double(blue) / 255
    }
}

public enum AccessibleLightPalette {
    public static let background = SRGBColorComponents(red: 0xEF, green: 0xF1, blue: 0xF5)
    public static let secondaryText = SRGBColorComponents(red: 0x5C, green: 0x5F, blue: 0x77)
    public static let tertiaryText = SRGBColorComponents(red: 0x62, green: 0x65, blue: 0x7A)
    public static let statusRunning = SRGBColorComponents(red: 0xB8, green: 0x42, blue: 0x00)
    public static let statusPending = SRGBColorComponents(red: 0xA0, green: 0x5A, blue: 0x00)
    public static let statusSuccess = SRGBColorComponents(red: 0x2F, green: 0x7D, blue: 0x20)
    public static let link = SRGBColorComponents(red: 0x18, green: 0x54, blue: 0xC4)
    public static let heading = SRGBColorComponents(red: 0x4B, green: 0x5F, blue: 0xC8)
}

public enum SRGBContrast {
    public static func ratio(
        _ first: SRGBColorComponents,
        _ second: SRGBColorComponents
    ) -> Double {
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private static func luminance(_ color: SRGBColorComponents) -> Double {
        0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }

    private static func linearize(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
