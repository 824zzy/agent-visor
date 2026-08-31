import Foundation
import CryptoKit

/// The process instance identity that a direct terminal route must verify
/// immediately before writing.  PID and TTY values are reusable; the token
/// binds them to one launch of the provider process.
public struct TerminalProcessIdentity: Equatable, Sendable {
    public let pid: Int
    public let processStartToken: String
    public let tty: String

    public init(pid: Int, processStartToken: String, tty: String) {
        self.pid = pid
        self.processStartToken = processStartToken
        self.tty = Self.normalizeTTY(tty)
    }

    public static func normalizeTTY(_ value: String) -> String {
        value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
    }
}

public enum TerminalProcessIdentityPolicy {
    /// Fail closed unless every identity field supplied by discovery matches
    /// the fresh action-bound observation. A missing token is not a wildcard.
    public static func matches(
        expected: TerminalProcessIdentity?,
        live: TerminalProcessIdentity?
    ) -> Bool {
        guard let expected, let live else { return false }
        return expected == live
    }
}

/// Shared token format for the Swift app and native helper.  Keep this here
/// so process identity cannot drift between direct AppKit and helper routes.
public enum TerminalProcessIdentityToken {
    public static func make(pid: Int, startTime: Date) -> String {
        let millis = Int64((startTime.timeIntervalSince1970 * 1_000).rounded(.down))
        let canonical = "\(pid)|\(millis)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "v1:\(pid):\(millis):\(digest)"
    }
}
