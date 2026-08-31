import Foundation

/// The terminal transports all share one preflight boundary.  Keeping this
/// decision in Core prevents the AppleScript, PTY, and native-helper paths
/// from disagreeing about whether a prompt is writable.
public enum TerminalTextValidation: Equatable, Sendable {
    case valid
    case exceedsUTF8ByteLimit(actual: Int, maximum: Int)
}

public enum TerminalTextPolicy {
    /// ponytail: this value is the cross-stack contract.  Changes require the
    /// native-helper wire limit, server serializer, and Electron protocol
    /// limit to change together; never raise one transport in isolation.
    public static let maximumUTF8Bytes = NativeHelperWireLimits.maxTerminalTextBytes

    public static func validation(for text: String) -> TerminalTextValidation {
        let bytes = text.utf8.count
        guard bytes <= maximumUTF8Bytes else {
            return .exceedsUTF8ByteLimit(actual: bytes, maximum: maximumUTF8Bytes)
        }
        return .valid
    }

    public static func canSend(_ text: String) -> Bool {
        validation(for: text) == .valid
    }
}
