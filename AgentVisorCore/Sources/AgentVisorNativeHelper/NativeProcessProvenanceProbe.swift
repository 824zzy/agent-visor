import AgentVisorCore
import Darwin
import Foundation

/// Bounded native process provenance reader.
public enum NativeProcessProvenanceProbe {
    private static let maxKernelProcargsBytes = 256 * 1024
    private static let maxArgumentCount: UInt32 = 256
    private static let maxCStringBytes = 16 * 1024
    private static let maxEnvironmentEntries = 1024

    /// Reads and validates one process instance, then parses only the
    /// allowlisted provenance selectors. The raw kernel buffer exists only
    /// for the duration of this call.
    public static func read(
        pid: Int32,
        expected: NativeProcessProvenanceProvider,
        processStartToken: String,
        homeDirectory: String = NSHomeDirectory(),
        observedAt: Date = Date()
    ) -> NativeProcessProvenanceResult {
        guard pid > 0 else { return .unavailable(.processMissing) }
        guard !processStartToken.isEmpty else { return .unavailable(.argvAmbiguous) }
        guard identityMatches(pid: pid, expectedToken: processStartToken) else {
            return .unavailable(.processMissing)
        }

        var raw = readKernelProcargs2(pid: pid)
        guard raw != nil else {
            return identityMatches(pid: pid, expectedToken: processStartToken)
                ? .unavailable(.argvUnreadable)
                : .unavailable(.processMissing)
        }
        defer {
            // The kernel capture is sensitive process metadata. Clear the
            // transient bytes before releasing the buffer and never return it.
            let count = raw?.count ?? 0
            raw?.resetBytes(in: 0..<count)
        }

        let result = parse(
            raw!,
            pid: pid,
            expected: expected,
            processStartToken: processStartToken,
            homeDirectory: homeDirectory,
            observedAt: observedAt
        )
        guard identityMatches(pid: pid, expectedToken: processStartToken) else {
            return .unavailable(.processMissing)
        }
        return result
    }

    /// Parses a boundary-preserving KERN_PROCARGS2 buffer without retaining
    /// any raw token or environment value. The production reader calls this
    /// only after process identity checks; fixture tests use it directly.
    public static func parse(
        _ data: Data,
        pid: Int32,
        expected: NativeProcessProvenanceProvider,
        processStartToken: String,
        homeDirectory: String,
        observedAt: Date = Date()
    ) -> NativeProcessProvenanceResult {
        guard pid > 0 else { return .unavailable(.processMissing) }
        guard !processStartToken.isEmpty else { return .unavailable(.argvAmbiguous) }

        var cursor = ProcargsCursor(data: data)
        guard let argc = cursor.readArgumentCount(), argc > 0 else {
            return .unavailable(.argvUnreadable)
        }
        guard let kernelExecutable = cursor.readCString(),
              !kernelExecutable.isEmpty,
              isAbsolutePath(kernelExecutable),
              let executableRef = canonicalExecutablePath(kernelExecutable) else {
            return .unavailable(.executableUntrusted)
        }

        cursor.skipZeroPadding()
        var argv: [String] = []
        argv.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard let argument = cursor.readCString() else {
                return .unavailable(.argvUnreadable)
            }
            argv.append(argument)
        }

        cursor.skipZeroPadding()
        guard let environment = cursor.readEnvironment() else {
            return .unavailable(.argvUnreadable)
        }
        guard let configRootRef = configRoot(
            expected: expected,
            environment: environment,
            homeDirectory: homeDirectory
        ) else {
            return .unavailable(.configUntrusted)
        }

        let selectors: Selectors
        switch expected {
        case .claudeCode:
            guard let parsed = parseClaudeSelectors(argv) else {
                return .unavailable(.argvAmbiguous)
            }
            selectors = parsed
        case .codexCLI:
            guard let parsed = parseCodexSelectors(argv) else {
                return .unavailable(.argvAmbiguous)
            }
            selectors = parsed
        }

        let observedAt = ISO8601DateFormatter.agentVisor.string(from: observedAt)
        return .available(NativeProcessProvenance(
            pid: pid,
            processStartToken: processStartToken,
            executableRef: executableRef,
            configRootRef: configRootRef,
            profileRef: selectors.profileRef,
            profileState: selectors.profileState,
            settingsFileRef: selectors.settingsFileRef,
            settingSources: selectors.settingSources,
            overrideNames: environment.overrideNames(for: expected),
            argvState: .complete,
            observedAt: observedAt
        ))
    }

    private struct Selectors {
        let settingsFileRef: String?
        let settingSources: [NativeProcessSettingSource]?
        let profileRef: String?
        let profileState: NativeProcessProvenanceState
    }

    private struct EnvironmentCapture {
        var values: [String: [String]] = [:]
        var overrideNamesInOrder: [String] = []
        var namesWithoutValues: Set<String> = []

        func values(for name: String) -> [String] {
            values[name] ?? []
        }

        func hasMissingValue(for name: String) -> Bool {
            namesWithoutValues.contains(name)
        }

        func overrideNames(for provider: NativeProcessProvenanceProvider) -> [String] {
            var seen = Set<String>()
            return overrideNamesInOrder.filter { name in
                guard seen.insert(name).inserted else { return false }
                switch provider {
                case .claudeCode:
                    return Self.isClaudeOverride(name)
                case .codexCLI:
                    return Self.isCodexOverride(name)
                }
            }
        }

        private static func isClaudeOverride(_ name: String) -> Bool {
            name.hasPrefix("ANTHROPIC_") || name.hasPrefix("CLAUDE_CODE_")
                || name == "AWS_PROFILE" || name == "AWS_REGION" || name == "AWS_DEFAULT_REGION"
        }

        private static func isCodexOverride(_ name: String) -> Bool {
            guard name != "CODEX_HOME" else { return false }
            return name == "CODEX_API_KEY" || name == "CODEX_BASE_URL" || name == "CODEX_BACKEND"
                || name == "CODEX_MODEL" || name.hasPrefix("OPENAI_")
                || name.hasPrefix("AZURE_OPENAI_")
                || name == "AWS_PROFILE" || name == "AWS_REGION" || name == "AWS_DEFAULT_REGION"
        }
    }

    private struct ProcargsCursor {
        private let data: Data
        private(set) var offset = 0

        init(data: Data) {
            self.data = data
        }

        mutating func readArgumentCount() -> UInt32? {
            guard data.count >= 4 else { return nil }
            let little = UInt32(data[0])
                | (UInt32(data[1]) << 8)
                | (UInt32(data[2]) << 16)
                | (UInt32(data[3]) << 24)
            let big = UInt32(data[3])
                | (UInt32(data[2]) << 8)
                | (UInt32(data[1]) << 16)
                | (UInt32(data[0]) << 24)
            let count = little > 0 && little <= maxArgumentCount ? little
                : (big > 0 && big <= maxArgumentCount ? big : 0)
            guard count > 0 else { return nil }
            offset = 4
            return count
        }

        mutating func readCString() -> String? {
            guard offset < data.count else { return nil }
            let start = offset
            let upperBound = min(data.count, start + maxCStringBytes + 1)
            var end = start
            while end < upperBound && data[end] != 0 { end += 1 }
            guard end < data.count, end < upperBound else { return nil }
            offset = end + 1
            return String(bytes: data[start..<end], encoding: .utf8)
        }

        mutating func skipZeroPadding() {
            while offset < data.count && data[offset] == 0 { offset += 1 }
        }

        mutating func readEnvironment() -> EnvironmentCapture? {
            var capture = EnvironmentCapture()
            var count = 0
            while true {
                skipZeroPadding()
                guard offset < data.count else { return capture }
                guard let entry = readCString(), !entry.isEmpty else { return nil }
                count += 1
                guard count <= maxEnvironmentEntries else { return nil }
                let equals = entry.firstIndex(of: "=")
                let name: String
                let value: String?
                if let equals {
                    name = String(entry[..<equals])
                    value = String(entry[entry.index(after: equals)...])
                } else {
                    name = entry
                    value = nil
                }
                guard Self.isEnvironmentName(name) else { continue }
                if Self.isPathReferenceName(name) {
                    if let value {
                        capture.values[name, default: []].append(value)
                    } else {
                        capture.namesWithoutValues.insert(name)
                    }
                }
                capture.overrideNamesInOrder.append(name)
            }
        }

        private static func isEnvironmentName(_ name: String) -> Bool {
            guard name.count <= 128, let first = name.utf8.first,
                  first >= 65, first <= 90 else { return false }
            return name.utf8.dropFirst().allSatisfy { byte in
                (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95
            }
        }

        private static func isPathReferenceName(_ name: String) -> Bool {
            name == "HOME" || name == "CLAUDE_CONFIG_DIR" || name == "CODEX_HOME"
        }
    }

    private static func identityMatches(pid: Int32, expectedToken: String) -> Bool {
        guard let identity = NativeProcessIdentityProbe.read(pid: pid),
              identity.pid == pid,
              identity.token == expectedToken else { return false }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size,
              bsd.pbi_pid == UInt32(pid) else { return false }
        return bsd.pbi_uid == getuid()
    }

    private static func readKernelProcargs2(pid: Int32) -> Data? {
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        var size = 0
        let queried = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), nil, &size, nil, 0)
        }
        guard queried == 0, size > 0, size <= maxKernelProcargsBytes else { return nil }

        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { bytes in
            mib.withUnsafeMutableBufferPointer { mibBuffer in
                sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), bytes.baseAddress, &size, nil, 0)
            }
        }
        guard status == 0, size > 0, size <= data.count else { return nil }
        if size < data.count { data.removeSubrange(size..<data.count) }
        return data
    }

    private static func configRoot(
        expected: NativeProcessProvenanceProvider,
        environment: EnvironmentCapture,
        homeDirectory: String
    ) -> String? {
        let homeValues = environment.values(for: "HOME")
        guard homeValues.count <= 1,
              !environment.hasMissingValue(for: "HOME") else { return nil }
        let explicitHome = homeValues.first
        let home = canonicalPathReference(explicitHome ?? homeDirectory)
        guard let home else { return nil }

        let explicitName: String
        let otherName: String
        let suffix: String
        switch expected {
        case .claudeCode:
            explicitName = "CLAUDE_CONFIG_DIR"
            otherName = "CODEX_HOME"
            suffix = ".claude"
        case .codexCLI:
            explicitName = "CODEX_HOME"
            otherName = "CLAUDE_CONFIG_DIR"
            suffix = ".codex"
        }
        guard environment.values(for: otherName).isEmpty,
              !environment.hasMissingValue(for: otherName) else { return nil }
        let explicitValues = environment.values(for: explicitName)
        guard explicitValues.count <= 1,
              !environment.hasMissingValue(for: explicitName) else { return nil }
        if let explicit = explicitValues.first {
            return canonicalPathReference(explicit)
        }
        return canonicalPathReference(URL(fileURLWithPath: home).appendingPathComponent(suffix).path)
    }

    private static func parseClaudeSelectors(_ argv: [String]) -> Selectors? {
        guard !argv.isEmpty else { return nil }
        var settingsFile: String?
        var settingSources: [NativeProcessSettingSource]?
        var identitySelectorSeen = false
        var index = 1
        while index < argv.count {
            let argument = argv[index]
            if argument == "--settings" {
                index += 1
                guard index < argv.count, let path = canonicalPathArgument(argv[index]) else { return nil }
                guard settingsFile == nil else { return nil }
                settingsFile = path
            } else if argument.hasPrefix("--settings=") {
                guard let path = canonicalPathArgument(String(argument.dropFirst("--settings=".count))),
                      settingsFile == nil else { return nil }
                settingsFile = path
            } else if argument == "--setting-sources" {
                index += 1
                guard index < argv.count, let parsed = parseSettingSources(argv[index]), settingSources == nil else { return nil }
                settingSources = parsed
            } else if argument.hasPrefix("--setting-sources=") {
                guard let parsed = parseSettingSources(String(argument.dropFirst("--setting-sources=".count))),
                      settingSources == nil else { return nil }
                settingSources = parsed
            } else if argument == "--resume" || argument == "-r" || argument == "--session-id" {
                index += 1
                guard index < argv.count, isConversationIdentifier(argv[index]), !identitySelectorSeen else { return nil }
                identitySelectorSeen = true
            } else if argument.hasPrefix("--resume=") {
                guard isConversationIdentifier(String(argument.dropFirst("--resume=".count))),
                      !identitySelectorSeen else { return nil }
                identitySelectorSeen = true
            } else if argument.hasPrefix("--session-id=") {
                guard isConversationIdentifier(String(argument.dropFirst("--session-id=".count))),
                      !identitySelectorSeen else { return nil }
                identitySelectorSeen = true
            } else if argument.hasPrefix("-r"), argument.count > 2 {
                guard isConversationIdentifier(String(argument.dropFirst(2))), !identitySelectorSeen else { return nil }
                identitySelectorSeen = true
            } else {
                return nil
            }
            index += 1
        }
        if settingsFile != nil, settingSources == nil {
            settingSources = [.user, .project, .local]
        }
        return Selectors(
            settingsFileRef: settingsFile,
            settingSources: settingSources,
            profileRef: nil,
            profileState: .verifiedAbsent
        )
    }

    private static func parseCodexSelectors(_ argv: [String]) -> Selectors? {
        guard !argv.isEmpty else { return nil }
        var profile: String?
        var isResumeCommand = false
        var resumeIdentifierSeen = false
        var changeDirectorySeen = false
        var index = 1
        while index < argv.count {
            let argument = argv[index]
            if argument == "resume" {
                guard !isResumeCommand else { return nil }
                isResumeCommand = true
            } else if isResumeCommand && !resumeIdentifierSeen {
                guard isConversationIdentifier(argument) else { return nil }
                resumeIdentifierSeen = true
            } else if argument == "--cd" {
                index += 1
                guard isResumeCommand, !changeDirectorySeen, index < argv.count,
                      canonicalPathArgument(argv[index]) != nil else { return nil }
                changeDirectorySeen = true
            } else if argument.hasPrefix("--cd=") {
                guard isResumeCommand, !changeDirectorySeen,
                      canonicalPathArgument(String(argument.dropFirst("--cd=".count))) != nil else { return nil }
                changeDirectorySeen = true
            } else if argument == "--profile" || argument == "-p" {
                index += 1
                guard index < argv.count else { return nil }
                let value = argv[index]
                guard isValidProfile(value), profile == nil else { return nil }
                profile = value
            } else if argument.hasPrefix("--profile=") {
                let value = String(argument.dropFirst("--profile=".count))
                guard isValidProfile(value), profile == nil else { return nil }
                profile = value
            } else if argument.hasPrefix("-p"), argument.count > 2 {
                let value = String(argument.dropFirst(2))
                guard isValidProfile(value), profile == nil else { return nil }
                profile = value
            } else {
                return nil
            }
            index += 1
        }
        if isResumeCommand && !resumeIdentifierSeen { return nil }
        return Selectors(
            settingsFileRef: nil,
            settingSources: nil,
            profileRef: profile,
            profileState: profile == nil ? .verifiedAbsent : .present
        )
    }

    private static func parseSettingSources(_ value: String) -> [NativeProcessSettingSource]? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 3,
              !value.hasPrefix(","), !value.hasSuffix(","),
              !value.contains(",,") else { return nil }
        var result: [NativeProcessSettingSource] = []
        for part in parts {
            let source: NativeProcessSettingSource
            switch part {
            case "user": source = .user
            case "project": source = .project
            case "local": source = .local
            default: return nil
            }
            if !result.contains(source) { result.append(source) }
        }
        return result.isEmpty ? nil : result
    }

    private static func isValidProfile(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              let first = value.utf8.first,
              (first >= 65 && first <= 90) || (first >= 97 && first <= 122)
                || (first >= 48 && first <= 57) else { return false }
        return value.utf8.dropFirst().allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95 || byte == 46
        }
    }

    private static func isConversationIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
        }
    }

    private static func canonicalPathArgument(_ value: String) -> String? {
        guard isAbsolutePath(value) else { return nil }
        return canonicalPathReference(value)
    }

    private static func canonicalExecutablePath(_ value: String) -> String? {
        guard isAbsolutePath(value), value.utf8.count <= maxCStringBytes else { return nil }
        let url = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        let path = url.path
        return isAbsolutePath(path) ? path : nil
    }

    private static func canonicalPathReference(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maxCStringBytes,
              isAbsolutePath(value),
              !value.unicodeScalars.contains(where: { scalar in
                  scalar.value < 0x20 || scalar.value == 0x7f
              }) else { return nil }
        let path = URL(fileURLWithPath: value).standardizedFileURL.path
        return isAbsolutePath(path) ? path : nil
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0")
    }
}

private extension ISO8601DateFormatter {
    static let agentVisor: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
