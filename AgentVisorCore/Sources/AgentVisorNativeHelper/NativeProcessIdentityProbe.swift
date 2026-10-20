import AgentVisorCore
import Darwin
import Foundation

/// Kernel process metadata. No subprocess, terminal input, or retained argv.
/// Start times retain the whole-second precision of the existing wire token.
public enum NativeProcessIdentityProbe {
    public struct Snapshot {
        public let pid: Int32
        public let startedAt: Date
        public let token: String
        public let tty: String?
        public let cwd: String
        public let preciseStartMicros: UInt64
        public let isForeground: Bool
    }

    public static func read(pid: Int32) -> Snapshot? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size,
              bsd.pbi_pid == UInt32(pid) else { return nil }
        var vnode = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize else { return nil }
        let cwd = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard cwd.hasPrefix("/") else { return nil }
        // PID reuse between the two kernel reads must not combine instances.
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              after.pbi_start_tvsec == bsd.pbi_start_tvsec,
              after.pbi_start_tvusec == bsd.pbi_start_tvusec,
              after.e_tdev == bsd.e_tdev else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
        let tty = bsd.e_tdev == UInt32.max ? nil
            : devname(dev_t(bitPattern: bsd.e_tdev), S_IFCHR).map { String(cString: $0) }
        return Snapshot(pid: pid, startedAt: start,
            token: TerminalProcessIdentityToken.make(pid: Int(pid), startTime: start), tty: tty, cwd: cwd,
            preciseStartMicros: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec,
            isForeground: tty != nil && bsd.pbi_pgid == bsd.e_tpgid)
    }
}
