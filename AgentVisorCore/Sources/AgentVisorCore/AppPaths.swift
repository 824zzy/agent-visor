import Foundation

public enum AppPaths {
    public static let appSupportDirName = "agent-visor"
    public static let socketPath = "/tmp/agent-visor.sock"
    public static let pasteTempDirName = "agent-visor-paste"
    public static let navLogFileName = "agent-visor-nav.log"

    public static var navLogPath: String {
        NSHomeDirectory() + "/\(navLogFileName)"
    }

    public static func appSupportDirectory() -> URL {
        let support: URL
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            support = appSupport
        } else {
            support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        }
        return support.appendingPathComponent(appSupportDirName)
    }
}
