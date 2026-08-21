import Darwin
import Foundation

/// Reads a pipe without Foundation exceptions when another thread closes it.
public enum ProcessPipeReader {
    public nonisolated static func read(fileDescriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return data
            }
        }
    }
}
