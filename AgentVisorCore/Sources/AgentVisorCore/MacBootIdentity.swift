import Darwin
import Foundation

/// Stable identity for the current macOS boot session.
public enum MacBootIdentity {
    public static func current() -> String? {
        current(readRawValue: readBootSessionUUID)
    }

    /// Injection seam for deterministic validation and failure testing.
    public static func current(readRawValue: () -> String?) -> String? {
        guard let rawValue = readRawValue() else { return nil }
        return canonicalize(rawValue)
    }

    /// The sole parser for boot-session authority, shared by live discovery
    /// and persisted snapshot loading.
    static func canonicalize(_ rawValue: String) -> String? {
        UUID(uuidString: rawValue)?.uuidString
    }

    private static func readBootSessionUUID() -> String? {
        let name = "kern.bootsessionuuid"
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0,
              size > 1 else {
            return nil
        }

        // Keep an extra terminator so a kernel value without one is still safe
        // to decode. The second sysctl updates `size` to the bytes actually used.
        var buffer = [CChar](repeating: 0, count: size + 1)
        let status = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname(name, bytes.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > 0, size <= buffer.count else {
            return nil
        }

        let bytes = buffer.prefix(size).prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        guard !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}
