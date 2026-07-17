import XCTest
@testable import AgentVisorCore

final class CodexUsageGlanceTests: XCTestCase {
    func testUsagePillStaysHiddenWhileCapabilityIsChecking() {
        let availability = CodexUsageGlancePolicy.availability(
            preferenceEnabled: true,
            snapshot: nil,
            isRefreshing: true,
            hasAttemptedRefresh: false,
            hasRefreshError: false
        )

        XCTAssertEqual(availability, .checking)
        XCTAssertFalse(availability.showsPill)
    }

    func testUsagePillShowsAfterMeaningfulSnapshotArrives() {
        let snapshot = CodexUsageSnapshot(
            primary: CodexUsageWindow(
                usedPercent: 44,
                windowDurationMinutes: 300,
                resetsAt: nil
            ),
            secondary: nil,
            resetCreditsAvailable: nil,
            observedAt: Date()
        )

        let availability = CodexUsageGlancePolicy.availability(
            preferenceEnabled: true,
            snapshot: snapshot,
            isRefreshing: false,
            hasAttemptedRefresh: true,
            hasRefreshError: false
        )

        XCTAssertEqual(availability, .available)
        XCTAssertTrue(availability.showsPill)
    }

    func testUsagePillHidesWhenAccountExposesNoRecognizedWindow() {
        let snapshot = CodexUsageSnapshot(
            primary: CodexUsageWindow(
                usedPercent: 20,
                windowDurationMinutes: 60,
                resetsAt: nil
            ),
            secondary: nil,
            resetCreditsAvailable: nil,
            observedAt: Date()
        )

        let availability = CodexUsageGlancePolicy.availability(
            preferenceEnabled: true,
            snapshot: snapshot,
            isRefreshing: false,
            hasAttemptedRefresh: true,
            hasRefreshError: false
        )

        XCTAssertEqual(availability, .unavailable)
        XCTAssertFalse(availability.showsPill)
    }

    func testUsagePillKeepsLastMeaningfulSnapshotAfterRefreshFailure() {
        let snapshot = CodexUsageSnapshot(
            primary: nil,
            secondary: CodexUsageWindow(
                usedPercent: 13,
                windowDurationMinutes: 10_080,
                resetsAt: nil
            ),
            resetCreditsAvailable: nil,
            observedAt: Date()
        )

        let availability = CodexUsageGlancePolicy.availability(
            preferenceEnabled: true,
            snapshot: snapshot,
            isRefreshing: false,
            hasAttemptedRefresh: true,
            hasRefreshError: true
        )

        XCTAssertEqual(availability, .stale)
        XCTAssertTrue(availability.showsPill)
    }

    func testUsagePillHidesAfterFailedFirstProbe() {
        let availability = CodexUsageGlancePolicy.availability(
            preferenceEnabled: true,
            snapshot: nil,
            isRefreshing: false,
            hasAttemptedRefresh: true,
            hasRefreshError: true
        )

        XCTAssertEqual(availability, .unavailable)
        XCTAssertFalse(availability.showsPill)
    }

    func testUsagePreferenceOffHidesAnAvailableSnapshot() {
        let snapshot = CodexUsageSnapshot(
            primary: CodexUsageWindow(
                usedPercent: 44,
                windowDurationMinutes: 300,
                resetsAt: nil
            ),
            secondary: nil,
            resetCreditsAvailable: nil,
            observedAt: Date()
        )

        let availability = CodexUsageGlancePolicy.availability(
            preferenceEnabled: false,
            snapshot: snapshot,
            isRefreshing: false,
            hasAttemptedRefresh: true,
            hasRefreshError: false
        )

        XCTAssertEqual(availability, .disabled)
        XCTAssertFalse(availability.showsPill)
    }

    func testProtocolPositionFallbackCountsAsMeaningfulWithoutDurationMetadata() {
        let snapshot = CodexUsageSnapshot(
            primary: CodexUsageWindow(
                usedPercent: 44,
                windowDurationMinutes: nil,
                resetsAt: nil
            ),
            secondary: nil,
            resetCreditsAvailable: nil,
            observedAt: Date()
        )

        let availability = CodexUsageGlancePolicy.availability(
            preferenceEnabled: true,
            snapshot: snapshot,
            isRefreshing: false,
            hasAttemptedRefresh: true,
            hasRefreshError: false
        )

        XCTAssertEqual(availability, .available)
        XCTAssertTrue(availability.showsPill)
    }

    func testResponseDecodesPrimarySecondaryAndResetCredits() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = AnyCodableEquatableBox([
            "rateLimits": [
                "primary": [
                    "usedPercent": 44,
                    "windowDurationMins": 300,
                    "resetsAt": 1_700_001_800,
                ],
                "secondary": [
                    "usedPercent": 13,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_700_604_800,
                ],
            ],
            "rateLimitResetCredits": ["availableCount": 3],
        ])

        let snapshot = try XCTUnwrap(
            CodexUsageSnapshotParser.response(payload, observedAt: observedAt)
        )

        XCTAssertEqual(snapshot.primary?.usedPercent, 44)
        XCTAssertEqual(snapshot.primary?.remainingPercent, 56)
        XCTAssertEqual(snapshot.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.primary?.resetsAt, Date(timeIntervalSince1970: 1_700_001_800))
        XCTAssertEqual(snapshot.secondary?.usedPercent, 13)
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 87)
        XCTAssertEqual(snapshot.secondary?.windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.resetCreditsAvailable, 3)
        XCTAssertEqual(snapshot.observedAt, observedAt)
    }

    func testPresentationShowsBothWindowsAndUsesCompoundFixedWidth() throws {
        let snapshot = CodexUsageSnapshot(
            primary: CodexUsageWindow(
                usedPercent: 44,
                windowDurationMinutes: 300,
                resetsAt: nil
            ),
            secondary: CodexUsageWindow(
                usedPercent: 80,
                windowDurationMinutes: 10_080,
                resetsAt: nil
            ),
            resetCreditsAvailable: nil,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let presentation = try XCTUnwrap(CodexUsageGlancePolicy.presentation(for: snapshot))

        XCTAssertEqual(presentation.label, "5h 56% | 7d 20%")
        XCTAssertEqual(CodexUsageGlancePolicy.fixedWidth, 114)
    }

    func testPresentationKeepsFiveHourThenSevenDayWhenServerWindowsSwap() throws {
        let snapshot = CodexUsageSnapshot(
            primary: CodexUsageWindow(
                usedPercent: 80,
                windowDurationMinutes: 10_080,
                resetsAt: nil
            ),
            secondary: CodexUsageWindow(
                usedPercent: 5,
                windowDurationMinutes: 300,
                resetsAt: nil
            ),
            resetCreditsAvailable: nil,
            observedAt: Date()
        )

        let presentation = try XCTUnwrap(CodexUsageGlancePolicy.presentation(for: snapshot))

        XCTAssertEqual(presentation.label, "5h 95% | 7d 20%")
        XCTAssertEqual(presentation.fiveHour.remainingPercent, 95)
        XCTAssertEqual(presentation.fiveHour.tone, .normal)
        XCTAssertEqual(presentation.fiveHour.source, .secondary)
        XCTAssertEqual(presentation.sevenDay.remainingPercent, 20)
        XCTAssertEqual(presentation.sevenDay.tone, .warning)
        XCTAssertEqual(presentation.sevenDay.source, .primary)
    }

    func testToneThresholdsUseRemainingPercentage() {
        XCTAssertEqual(CodexUsageGlancePolicy.tone(remainingPercent: 26), .normal)
        XCTAssertEqual(CodexUsageGlancePolicy.tone(remainingPercent: 25), .warning)
        XCTAssertEqual(CodexUsageGlancePolicy.tone(remainingPercent: 11), .warning)
        XCTAssertEqual(CodexUsageGlancePolicy.tone(remainingPercent: 10), .critical)
        XCTAssertEqual(CodexUsageGlancePolicy.tone(remainingPercent: 0), .critical)
    }

    func testMissingSnapshotKeepsBothFixedOrderPlaceholdersVisible() {
        let presentation = CodexUsageGlancePolicy.presentation(
            for: Optional<CodexUsageSnapshot>.none
        )

        XCTAssertEqual(presentation.label, "5h --% | 7d --%")
        XCTAssertNil(presentation.fiveHour.remainingPercent)
        XCTAssertNil(presentation.fiveHour.tone)
        XCTAssertNil(presentation.sevenDay.remainingPercent)
        XCTAssertNil(presentation.sevenDay.tone)
    }

    func testUsagePillReservesRightSideBeforeSessionPacking() {
        let reservation = CodexUsageGlancePolicy.reserveRightSide(
            usableWidth: 200,
            spacing: 4,
            enabled: true
        )

        XCTAssertTrue(reservation.showsUsage)
        XCTAssertEqual(reservation.sessionUsableWidth, 82)
    }

    func testUsagePillHidesInsteadOfOverlappingWhenItCannotFit() {
        let reservation = CodexUsageGlancePolicy.reserveRightSide(
            usableWidth: 113,
            spacing: 4,
            enabled: true
        )

        XCTAssertFalse(reservation.showsUsage)
        XCTAssertEqual(reservation.sessionUsableWidth, 113)
    }

    func testSparseNotificationMergesWithoutClearingExistingValues() throws {
        let original = CodexUsageSnapshot(
            primary: CodexUsageWindow(
                usedPercent: 44,
                windowDurationMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_700_001_800)
            ),
            secondary: CodexUsageWindow(
                usedPercent: 13,
                windowDurationMinutes: 10_080,
                resetsAt: Date(timeIntervalSince1970: 1_700_604_800)
            ),
            resetCreditsAvailable: 3,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let updateTime = Date(timeIntervalSince1970: 1_700_000_100)
        let payload = AnyCodableEquatableBox([
            "rateLimits": [
                "primary": [
                    "usedPercent": 46,
                    "windowDurationMins": 300,
                    "resetsAt": 1_700_001_800,
                ],
            ],
        ])

        let update = try XCTUnwrap(
            CodexUsageSnapshotParser.notification(payload, observedAt: updateTime)
        )
        let merged = original.merging(update)

        XCTAssertEqual(merged.primary?.usedPercent, 46)
        XCTAssertEqual(merged.secondary, original.secondary)
        XCTAssertEqual(merged.resetCreditsAvailable, 3)
        XCTAssertEqual(merged.observedAt, updateTime)
    }
}
