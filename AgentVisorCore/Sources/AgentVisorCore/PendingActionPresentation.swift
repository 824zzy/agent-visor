import Foundation

public enum PendingActionPresentation {
    public static let genericToolName = "Needs your input"

    public static func storedToolName(_ rawValue: String?) -> String {
        contextualToolName(rawValue) ?? genericToolName
    }

    public static func contextualToolName(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        switch value.lowercased() {
        case "unknown", genericToolName.lowercased():
            return nil
        case "request_user_input", "requestuserinput", "item/tool/requestuserinput":
            return "AskUserQuestion"
        default:
            return value
        }
    }
}
