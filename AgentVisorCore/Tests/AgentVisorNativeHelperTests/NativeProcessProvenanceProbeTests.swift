import AgentVisorCore
import AgentVisorNativeHelper
import Foundation
import XCTest

final class NativeProcessProvenanceProbeTests: XCTestCase {
    func testReadsKernelProcargsFromOwnDisposableSleepFixture() throws {
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
        fixture.arguments = ["30"]
        fixture.environment = [
            "HOME": "/tmp/agent-visor-native-provenance-fixture",
            "PATH": "/usr/bin:/bin",
            "ANTHROPIC_API_KEY": "fixture-only-value",
            "UNRELATED_SECRET": "fixture-only-unrelated-value",
        ]
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate() }
            fixture.waitUntilExit()
        }

        let pid = fixture.processIdentifier
        let identity = try XCTUnwrap(NativeProcessIdentityProbe.read(pid: pid))
        let result = NativeProcessProvenanceProbe.read(
            pid: pid,
            expected: .claudeCode,
            processStartToken: identity.token,
            homeDirectory: "/tmp/agent-visor-native-provenance-fallback"
        )

        guard case .unavailable(.argvAmbiguous) = result else {
            return XCTFail("expected the complete sleep argv to be rejected as an unsupported selector")
        }
    }

    func testReadsAvailableProvenanceFromOwnCatFixture() throws {
        let fixture = Process()
        let input = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/bin/cat")
        fixture.arguments = []
        fixture.standardInput = input
        fixture.standardOutput = Pipe()
        fixture.environment = [
            "HOME": "/tmp/agent-visor-native-provenance-fallback",
            "PATH": "/usr/bin:/bin",
            "ANTHROPIC_API_KEY": "fixture-only-cat-value",
            "UNRELATED_SECRET": "fixture-only-cat-unrelated-value",
        ]
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate() }
            fixture.waitUntilExit()
        }

        let identity = try XCTUnwrap(NativeProcessIdentityProbe.read(pid: fixture.processIdentifier))
        let result = NativeProcessProvenanceProbe.read(
            pid: fixture.processIdentifier,
            expected: .claudeCode,
            processStartToken: identity.token,
            homeDirectory: "/tmp/agent-visor-native-provenance-fallback"
        )

        guard case .available(let value) = result else {
            return XCTFail("expected available cat provenance, got \(result)")
        }
        XCTAssertEqual(value.pid, fixture.processIdentifier)
        XCTAssertEqual(value.processStartToken, identity.token)
        XCTAssertEqual(
            value.executableRef,
            URL(fileURLWithPath: "/bin/cat").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(value.configRootRef, "/tmp/agent-visor-native-provenance-fallback/.claude")
        XCTAssertEqual(value.profileState, .verifiedAbsent)
        XCTAssertEqual(value.argvState, .complete)
        XCTAssertFalse(String(describing: result).contains("fixture-only-cat-value"))
        XCTAssertFalse(String(describing: result).contains("fixture-only-cat-unrelated-value"))
    }

    func testRejectsOwnFixtureWhenStartTokenDoesNotMatch() throws {
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
        fixture.arguments = ["30"]
        fixture.environment = [
            "HOME": "/tmp/agent-visor-native-provenance-identity-fixture",
            "PATH": "/usr/bin:/bin",
        ]
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate() }
            fixture.waitUntilExit()
        }

        let identity = try XCTUnwrap(NativeProcessIdentityProbe.read(pid: fixture.processIdentifier))
        let result = NativeProcessProvenanceProbe.read(
            pid: fixture.processIdentifier,
            expected: .codexCLI,
            processStartToken: identity.token + ":different-instance",
            homeDirectory: "/tmp/agent-visor-native-provenance-fallback"
        )

        XCTAssertEqual(result, .unavailable(.processMissing))
    }

    func testParsesClaudeSettingsFileWithImplicitDefaultSettingSources() throws {
        let data = makeKernelProcargs(
            executablePath: "/bin/sleep",
            argv: ["/bin/sleep", "--settings", "/tmp/claude-settings.json"],
            environment: [
                "HOME=/tmp/agent-visor-provenance-home",
                "CLAUDE_CONFIG_DIR=/tmp/agent-visor-explicit-config",
                "ANTHROPIC_API_KEY=redacted-fixture-value",
                "UNRELATED_SECRET=must-not-appear",
            ]
        )

        let result = NativeProcessProvenanceProbe.parse(
            data,
            pid: 42,
            expected: .claudeCode,
            processStartToken: "v1:42:fixture",
            homeDirectory: "/Users/fixture",
            observedAt: Date(timeIntervalSince1970: 1_792_518_000)
        )

        guard case .available(let value) = result else {
            return XCTFail("expected sanitized provenance, got \(result)")
        }
        XCTAssertEqual(value.version, 1)
        XCTAssertEqual(value.pid, 42)
        XCTAssertEqual(value.processStartToken, "v1:42:fixture")
        XCTAssertEqual(value.executableRef, URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath().path)
        XCTAssertEqual(value.settingsFileRef, "/tmp/claude-settings.json")
        XCTAssertEqual(value.settingSources, [.user, .project, .local])
        XCTAssertEqual(value.configRootRef, "/tmp/agent-visor-explicit-config")
        XCTAssertEqual(value.profileState, .verifiedAbsent)
        XCTAssertEqual(value.overrideNames, ["ANTHROPIC_API_KEY"])
        XCTAssertEqual(value.argvState, .complete)
        XCTAssertFalse(String(describing: result).contains("redacted-fixture-value"))
        XCTAssertFalse(String(describing: result).contains("UNRELATED_SECRET"))
    }

    func testParsesCodexProfileAndUsesProcessHomeForDefaultConfigRoot() throws {
        let data = makeKernelProcargs(
            executablePath: "/usr/bin/codex",
            argv: ["codex", "--profile", "team-profile"],
            environment: ["HOME=/tmp/agent-visor-codex-home"]
        )

        let result = NativeProcessProvenanceProbe.parse(
            data,
            pid: 43,
            expected: .codexCLI,
            processStartToken: "v1:43:fixture",
            homeDirectory: "/Users/fixture"
        )

        guard case .available(let value) = result else {
            return XCTFail("expected Codex profile provenance, got \(result)")
        }
        XCTAssertEqual(value.profileRef, "team-profile")
        XCTAssertEqual(value.profileState, .present)
        XCTAssertEqual(value.configRootRef, "/tmp/agent-visor-codex-home/.codex")
        XCTAssertNil(value.settingsFileRef)
        XCTAssertNil(value.settingSources)
        XCTAssertEqual(value.overrideNames, [])
    }

    func testRejectsUnsupportedProviderFlagsWithoutRetainingTheirValues() throws {
        let data = makeKernelProcargs(
            executablePath: "/usr/bin/claude",
            argv: ["claude", "--model", "secret-model-name"],
            environment: ["HOME=/tmp/agent-visor-unsupported-flag-home"]
        )

        let result = NativeProcessProvenanceProbe.parse(
            data,
            pid: 44,
            expected: .claudeCode,
            processStartToken: "v1:44:fixture",
            homeDirectory: "/Users/fixture"
        )

        XCTAssertEqual(result, .unavailable(.argvAmbiguous))
        XCTAssertFalse(String(describing: result).contains("secret-model-name"))
    }

    func testAcceptsClaudeResumeIdentitySelectorWithoutRetainingItsValue() throws {
        let data = makeKernelProcargs(
            executablePath: "/usr/bin/claude",
            argv: ["claude", "--resume", "123e4567-e89b-12d3-a456-426614174000"],
            environment: ["HOME=/tmp/agent-visor-resume-selector-home"]
        )

        let result = NativeProcessProvenanceProbe.parse(
            data,
            pid: 47,
            expected: .claudeCode,
            processStartToken: "v1:47:fixture",
            homeDirectory: "/Users/fixture"
        )

        guard case .available(let value) = result else {
            return XCTFail("expected safe Claude resume selector, got \(result)")
        }
        XCTAssertNil(value.profileRef)
        XCTAssertEqual(value.profileState, .verifiedAbsent)
        XCTAssertFalse(String(describing: result).contains("123e4567-e89b-12d3-a456-426614174000"))
    }

    func testAcceptsCodexResumeIdentityAndAbsoluteDirectorySelectors() throws {
        let data = makeKernelProcargs(
            executablePath: "/usr/bin/codex",
            argv: ["codex", "resume", "123e4567-e89b-12d3-a456-426614174000", "--cd", "/tmp/agent-visor-project"],
            environment: ["HOME=/tmp/agent-visor-codex-resume-home"]
        )

        let result = NativeProcessProvenanceProbe.parse(
            data,
            pid: 48,
            expected: .codexCLI,
            processStartToken: "v1:48:fixture",
            homeDirectory: "/Users/fixture"
        )

        guard case .available(let value) = result else {
            return XCTFail("expected safe Codex resume selectors, got \(result)")
        }
        XCTAssertNil(value.profileRef)
        XCTAssertEqual(value.profileState, .verifiedAbsent)
        XCTAssertFalse(String(describing: result).contains("123e4567-e89b-12d3-a456-426614174000"))
        XCTAssertFalse(String(describing: result).contains("/tmp/agent-visor-project"))
    }

    func testCodableUnavailableResultUsesSanitizedReasonEnvelope() throws {
        let result = NativeProcessProvenanceResult.unavailable(.configUntrusted)
        let encoded = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(object["state"] as? String, "unavailable")
        XCTAssertEqual(object["reason"] as? String, "config_untrusted")
        XCTAssertNil(object["value"])
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("raw") ?? true)
    }

    func testRejectsTruncatedKernelProcargsBuffer() throws {
        var data = makeKernelProcargs(
            executablePath: "/usr/bin/claude",
            argv: ["claude"],
            environment: ["HOME=/tmp/agent-visor-truncated-home"]
        )
        data.removeLast(2)

        let result = NativeProcessProvenanceProbe.parse(
            data,
            pid: 45,
            expected: .claudeCode,
            processStartToken: "v1:45:fixture",
            homeDirectory: "/Users/fixture"
        )

        XCTAssertEqual(result, .unavailable(.argvUnreadable))
    }

    func testRejectsInvalidAllowlistedHomeReference() throws {
        let data = makeKernelProcargs(
            executablePath: "/usr/bin/claude",
            argv: ["claude"],
            environment: ["HOME=relative-home"]
        )

        let result = NativeProcessProvenanceProbe.parse(
            data,
            pid: 46,
            expected: .claudeCode,
            processStartToken: "v1:46:fixture",
            homeDirectory: "/Users/fixture"
        )

        XCTAssertEqual(result, .unavailable(.configUntrusted))
    }

    private func makeKernelProcargs(
        executablePath: String,
        argv: [String],
        environment: [String]
    ) -> Data {
        var data = Data()
        appendUInt32LE(UInt32(argv.count), to: &data)
        appendCString(executablePath, to: &data)
        data.append(0)
        for value in argv { appendCString(value, to: &data) }
        data.append(0)
        for value in environment { appendCString(value, to: &data) }
        data.append(0)
        return data
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private func appendCString(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
        data.append(0)
    }
}
