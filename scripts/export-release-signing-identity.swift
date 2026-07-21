#!/usr/bin/env swift

import CryptoKit
import Foundation
import Security

enum ExportFailure: Error, CustomStringConvertible {
    case usage
    case security(String, OSStatus)
    case missingCertificate(String)
    case fingerprintMismatch(expected: String, actual: String)
    case missingIdentity(String)
    case emptyExport

    var description: String {
        switch self {
        case .usage:
            return "usage: export-release-signing-identity.swift <identity> <sha1> <output.p12> <password-file>"
        case let .security(operation, status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "\(operation) failed: \(detail)"
        case let .missingCertificate(label):
            return "certificate not found in the login keychain: \(label)"
        case let .fingerprintMismatch(expected, actual):
            return "certificate fingerprint mismatch (expected \(expected), found \(actual))"
        case let .missingIdentity(label):
            return "private key not found for certificate: \(label)"
        case .emptyExport:
            return "PKCS12 export returned no data"
        }
    }
}

func normalizedSHA1(_ value: String) -> String {
    value.filter(\.isHexDigit).uppercased()
}

func certificateSHA1(_ certificate: SecCertificate) -> String {
    let data = SecCertificateCopyData(certificate) as Data
    return Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

func exportIdentity(
    label: String,
    expectedSHA1: String,
    outputURL: URL,
    password: String
) throws {
    let query: [CFString: Any] = [
        kSecClass: kSecClassCertificate,
        kSecAttrLabel: label,
        kSecReturnRef: true,
        kSecMatchLimit: kSecMatchLimitOne,
    ]
    var certificateItem: CFTypeRef?
    let certificateStatus = SecItemCopyMatching(query as CFDictionary, &certificateItem)
    guard certificateStatus == errSecSuccess else {
        if certificateStatus == errSecItemNotFound {
            throw ExportFailure.missingCertificate(label)
        }
        throw ExportFailure.security("certificate lookup", certificateStatus)
    }
    guard let certificateItem else {
        throw ExportFailure.missingCertificate(label)
    }
    let certificate = certificateItem as! SecCertificate

    let actualSHA1 = certificateSHA1(certificate)
    let expected = normalizedSHA1(expectedSHA1)
    guard actualSHA1 == expected else {
        throw ExportFailure.fingerprintMismatch(expected: expected, actual: actualSHA1)
    }

    var identity: SecIdentity?
    let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &identity)
    guard identityStatus == errSecSuccess, let identity else {
        if identityStatus == errSecItemNotFound {
            throw ExportFailure.missingIdentity(label)
        }
        throw ExportFailure.security("identity lookup", identityStatus)
    }

    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passUnretained(password as CFString)

    var exportedData: CFData?
    let exportStatus = SecItemExport(
        identity,
        .formatPKCS12,
        [],
        &parameters,
        &exportedData
    )
    guard exportStatus == errSecSuccess else {
        throw ExportFailure.security("PKCS12 export", exportStatus)
    }
    guard let exportedData, CFDataGetLength(exportedData) > 0 else {
        throw ExportFailure.emptyExport
    }

    try (exportedData as Data).write(to: outputURL, options: .atomic)
}

do {
    guard CommandLine.arguments.count == 5 else {
        throw ExportFailure.usage
    }
    let password = try String(
        contentsOfFile: CommandLine.arguments[4],
        encoding: .utf8
    ).trimmingCharacters(in: .newlines)
    guard !password.isEmpty else {
        throw ExportFailure.usage
    }
    try exportIdentity(
        label: CommandLine.arguments[1],
        expectedSHA1: CommandLine.arguments[2],
        outputURL: URL(fileURLWithPath: CommandLine.arguments[3]),
        password: password
    )
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}
