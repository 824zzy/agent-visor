import XCTest
@testable import AgentVisorCore

final class ImageAttachmentAdmissionPolicyTests: XCTestCase {
    private func image(
        _ id: String = "image",
        bytes: Int = 100,
        width: Int = 100,
        height: Int = 100,
        exists: Bool = true,
        decodable: Bool = true
    ) -> ImageAttachmentAdmissionMetadata {
        ImageAttachmentAdmissionMetadata(
            id: id,
            byteCount: bytes,
            width: width,
            height: height,
            fileExists: exists,
            isDecodable: decodable
        )
    }

    func testAcceptsExactCountAndByteBoundaries() {
        let attachments = (0..<ImageAttachmentAdmissionPolicy.maxAttachments).map {
            image("image-\($0)", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes)
        }
        XCTAssertTrue(ImageAttachmentAdmissionPolicy.validate(attachments).isAccepted)

        var aggregate = attachments
        aggregate[0] = image(
            "image-0",
            bytes: ImageAttachmentAdmissionPolicy.maxAggregateBytes
                - ImageAttachmentAdmissionPolicy.maxPerFileBytes * (attachments.count - 1)
        )
        XCTAssertTrue(ImageAttachmentAdmissionPolicy.validate(aggregate).isAccepted)
    }

    func testRejectsCountAndAggregateOverflow() {
        let tooMany = (0...ImageAttachmentAdmissionPolicy.maxAttachments).map {
            image("image-\($0)")
        }
        XCTAssertTrue(ImageAttachmentAdmissionPolicy.validate(tooMany).errors.contains {
            $0.error == .tooMany(maximum: ImageAttachmentAdmissionPolicy.maxAttachments)
        })

        let aggregate = [
            image("a", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("b", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
        ]
        XCTAssertTrue(ImageAttachmentAdmissionPolicy.validate(aggregate).isAccepted)
        XCTAssertTrue(ImageAttachmentAdmissionPolicy.validate([
            image("a", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("b", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("c", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("d", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("e", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("f", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("g", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("h", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("i", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("j", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
            image("k", bytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes),
        ]).errors.contains {
            if case .aggregateTooLarge = $0.error { return true }
            return false
        })
    }

    func testRejectsInvalidFileDecodeAndDimensions() {
        let result = ImageAttachmentAdmissionPolicy.validate([
            image("missing", exists: false),
            image("broken", decodable: false),
            image("huge", width: ImageAttachmentAdmissionPolicy.maxPixelDimension + 1),
            image("negative", bytes: -1),
        ])
        XCTAssertTrue(result.errors.contains { $0.error == .missingFile })
        XCTAssertTrue(result.errors.contains { $0.error == .undecodable })
        XCTAssertTrue(result.errors.contains { $0.error == .invalidDimensions })
        XCTAssertTrue(result.errors.contains {
            $0.error == .perFileTooLarge(maximumBytes: ImageAttachmentAdmissionPolicy.maxPerFileBytes)
        })
    }
}
