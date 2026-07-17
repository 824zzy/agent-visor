import Foundation

public enum SidebarSessionVisibilityPolicy {
    public static func shouldHideInWindow(
        isEnded: Bool,
        isTitleless: Bool
    ) -> Bool {
        if isEnded { return true }
        return isTitleless
    }

    public static func shouldHideInPills(
        isEnded: Bool,
        isTitleless: Bool,
        isIdle: Bool = false
    ) -> Bool {
        if isEnded { return true }
        if isIdle { return true }
        return isTitleless
    }

    public static func shouldHide(
        isEnded: Bool,
        isTitleless: Bool,
        isIdle: Bool = false
    ) -> Bool {
        shouldHideInPills(
            isEnded: isEnded,
            isTitleless: isTitleless,
            isIdle: isIdle
        )
    }
}
