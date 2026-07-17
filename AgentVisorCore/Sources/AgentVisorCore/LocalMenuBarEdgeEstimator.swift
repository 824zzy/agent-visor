import CoreGraphics
import Foundation

public enum LocalMenuBarEdgeEstimator {
    public static func estimate(
        titleWidths: [CGFloat],
        systemMenuWidth: CGFloat = 44,
        itemHorizontalChrome: CGFloat = 20
    ) -> CGFloat? {
        guard !titleWidths.isEmpty else { return nil }
        let titleWidth = titleWidths.reduce(0) { $0 + max(0, $1) }
        let itemChrome = CGFloat(titleWidths.count) * itemHorizontalChrome
        return ceil(systemMenuWidth + titleWidth + itemChrome)
    }
}
