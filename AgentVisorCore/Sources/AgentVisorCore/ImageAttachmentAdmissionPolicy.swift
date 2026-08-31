import Foundation

/// Metadata collected before an attachment enters the composer or a
/// provider transport.  Core deliberately carries no AppKit image values;
/// the app adapter supplies the decoded dimensions and file facts.
public struct ImageAttachmentAdmissionMetadata: Equatable, Sendable {
    public let id: String
    public let byteCount: Int
    public let width: Int
    public let height: Int
    public let fileExists: Bool
    public let isDecodable: Bool

    public init(
        id: String,
        byteCount: Int,
        width: Int,
        height: Int,
        fileExists: Bool,
        isDecodable: Bool
    ) {
        self.id = id
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.fileExists = fileExists
        self.isDecodable = isDecodable
    }
}

public enum ImageAttachmentAdmissionError: Equatable, Sendable {
    case tooMany(maximum: Int)
    case emptyID
    case missingFile
    case undecodable
    case invalidDimensions
    case perFileTooLarge(maximumBytes: Int)
    case aggregateTooLarge(maximumBytes: Int)
}

public struct ImageAttachmentAdmissionIssue: Equatable, Sendable {
    public let id: String
    public let error: ImageAttachmentAdmissionError

    public init(id: String, error: ImageAttachmentAdmissionError) {
        self.id = id
        self.error = error
    }
}

public struct ImageAttachmentAdmissionResult: Equatable, Sendable {
    public let errors: [ImageAttachmentAdmissionIssue]

    public init(errors: [ImageAttachmentAdmissionIssue]) {
        self.errors = errors
    }

    public var isAccepted: Bool { errors.isEmpty }
}

/// Shared native/renderer attachment admission contract.
///
/// The values match the protocol's image limits: ten images, 10,000,000
/// bytes per file, and 100,000,000 bytes per message.  Dimensions and decode
/// state are checked here because a valid MIME header alone is not a usable
/// image.  The app must call this before clearing the composer.
public enum ImageAttachmentAdmissionPolicy {
    public static let maxAttachments = 10
    public static let maxPerFileBytes = 10_000_000
    public static let maxAggregateBytes = 100_000_000
    public static let maxPixelDimension = 32_768

    // ponytail: keep count, per-file, aggregate, decode, and dimension limits
    // coordinated with protocol CHAT_IMAGE_* constants and RN validation.
    // Raise any bound only with a wire-budget, retention, and accessibility
    // review; rejection must preserve the complete composer snapshot.
    public static func validate(
        _ attachments: [ImageAttachmentAdmissionMetadata]
    ) -> ImageAttachmentAdmissionResult {
        var errors: [ImageAttachmentAdmissionIssue] = []
        var aggregateBytes = 0

        if attachments.count > maxAttachments {
            errors.append(ImageAttachmentAdmissionIssue(id: "", error: .tooMany(maximum: maxAttachments)))
        }

        for attachment in attachments {
            if attachment.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(ImageAttachmentAdmissionIssue(id: attachment.id, error: .emptyID))
            }
            if !attachment.fileExists {
                errors.append(ImageAttachmentAdmissionIssue(id: attachment.id, error: .missingFile))
            }
            if !attachment.isDecodable {
                errors.append(ImageAttachmentAdmissionIssue(id: attachment.id, error: .undecodable))
            }
            if attachment.width <= 0 || attachment.height <= 0
                || attachment.width > maxPixelDimension
                || attachment.height > maxPixelDimension {
                errors.append(ImageAttachmentAdmissionIssue(id: attachment.id, error: .invalidDimensions))
            }
            if attachment.byteCount < 0 || attachment.byteCount > maxPerFileBytes {
                errors.append(ImageAttachmentAdmissionIssue(
                    id: attachment.id,
                    error: .perFileTooLarge(maximumBytes: maxPerFileBytes)
                ))
            }
            aggregateBytes += max(0, attachment.byteCount)
        }

        if aggregateBytes > maxAggregateBytes {
            errors.append(ImageAttachmentAdmissionIssue(
                id: "",
                error: .aggregateTooLarge(maximumBytes: maxAggregateBytes)
            ))
        }
        return ImageAttachmentAdmissionResult(errors: errors)
    }
}
