import Foundation

/// The provider whose bounded process launch provenance is being observed.
///
/// This contract lives in the core target so the native helper and the wire
/// layer share the same Codable shape without making Core depend on an
/// executable target.
public enum NativeProcessProvenanceProvider: String, Codable, Equatable, Sendable {
    case claudeCode = "claude_code"
    case codexCLI = "codex_cli"
}

public enum NativeProcessProvenanceState: String, Codable, Equatable, Sendable {
    case present
    case verifiedAbsent = "verified_absent"
    case unknown
}

public enum NativeProcessProvenanceArgvState: String, Codable, Equatable, Sendable {
    case complete
    case unknown
}

public enum NativeProcessProvenanceUnavailableReason: String, Codable, Equatable, Sendable {
    case processMissing = "process_missing"
    case argvUnreadable = "argv_unreadable"
    case argvAmbiguous = "argv_ambiguous"
    case executableUntrusted = "executable_untrusted"
    case configUntrusted = "config_untrusted"
}

public enum NativeProcessSettingSource: String, Codable, Equatable, Sendable {
    case user
    case project
    case local
}

/// Sanitized process provenance compatible with the server's ProcessProvenance
/// contract. Raw argv, environment values, prompts and transcript content are
/// deliberately absent from this type.
public struct NativeProcessProvenance: Codable, Equatable, Sendable {
    public let version: Int
    public let pid: Int32
    public let processStartToken: String
    public let executableRef: String
    public let executableVersion: String?
    public let configRootRef: String?
    public let profileRef: String?
    public let profileState: NativeProcessProvenanceState
    public let settingsFileRef: String?
    public let settingSources: [NativeProcessSettingSource]?
    /// Allowlisted environment names only. Values are never retained.
    public let overrideNames: [String]
    /// One-shot launch correlation evidence. This is intentionally transient
    /// and is never copied into retained history capabilities.
    public let resumeNonce: String?
    public let argvState: NativeProcessProvenanceArgvState
    public let observedAt: String

    public init(
        version: Int = 1,
        pid: Int32,
        processStartToken: String,
        executableRef: String,
        executableVersion: String? = nil,
        configRootRef: String? = nil,
        profileRef: String? = nil,
        profileState: NativeProcessProvenanceState,
        settingsFileRef: String? = nil,
        settingSources: [NativeProcessSettingSource]? = nil,
        overrideNames: [String],
        resumeNonce: String? = nil,
        argvState: NativeProcessProvenanceArgvState,
        observedAt: String
    ) {
        self.version = version
        self.pid = pid
        self.processStartToken = processStartToken
        self.executableRef = executableRef
        self.executableVersion = executableVersion
        self.configRootRef = configRootRef
        self.profileRef = profileRef
        self.profileState = profileState
        self.settingsFileRef = settingsFileRef
        self.settingSources = settingSources
        self.overrideNames = overrideNames
        self.resumeNonce = resumeNonce
        self.argvState = argvState
        self.observedAt = observedAt
    }
}

/// The result envelope mirrors the server's discriminated result while
/// omitting the inactive value/reason field during Codable encoding.
public enum NativeProcessProvenanceResult: Codable, Equatable, Sendable {
    case available(NativeProcessProvenance)
    case unavailable(NativeProcessProvenanceUnavailableReason)

    private enum CodingKeys: String, CodingKey {
        case state
        case value
        case reason
    }

    private enum State: String, Codable {
        case available
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .available:
            self = .available(try container.decode(NativeProcessProvenance.self, forKey: .value))
        case .unavailable:
            self = .unavailable(try container.decode(NativeProcessProvenanceUnavailableReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let value):
            try container.encode(State.available, forKey: .state)
            try container.encode(value, forKey: .value)
        case .unavailable(let reason):
            try container.encode(State.unavailable, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }
}
