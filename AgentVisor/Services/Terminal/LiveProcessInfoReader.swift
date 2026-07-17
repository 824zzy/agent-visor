//
//  LiveProcessInfoReader.swift
//  AgentVisor
//
//  Production implementation of AgentVisorCore.ProcessInfoReader. Walks
//  the process tree via libproc and looks up bundle IDs through
//  NSRunningApplication. Pure logic (the walking, bundle-ID matching)
//  lives in AgentVisorCore where it's unit-tested.
//

import AppKit
import AgentVisorCore
import Darwin

final class LiveProcessInfoReader: @unchecked Sendable, ProcessInfoReader {
    nonisolated static let shared = LiveProcessInfoReader()

    nonisolated func parentPID(of pid: pid_t) -> pid_t? {
        // Fast path: proc_pidinfo via libproc. Works for processes the
        // caller owns and most regular processes.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if result == size {
            return pid_t(info.pbi_ppid)
        }

        // Fallback: macOS denies proc_pidinfo against processes in a
        // different security context (notably `login`, which is setuid
        // root and sits between a shell and the terminal app — the
        // exact spot we need to traverse). `ps` reads kern.proc via a
        // permitted path and answers for any pid.
        return parentPIDViaPS(pid: pid)
    }

    nonisolated func bundleID(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    nonisolated private func parentPIDViaPS(pid: pid_t) -> pid_t? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "ppid="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let trimmed = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return pid_t(trimmed)
        } catch {
            return nil
        }
    }
}
