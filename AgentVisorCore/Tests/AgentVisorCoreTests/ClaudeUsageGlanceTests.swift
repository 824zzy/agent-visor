import XCTest
@testable import AgentVisorCore

final class ClaudeUsageGlanceTests: XCTestCase {
    // Real shape captured from `GET /api/oauth/usage` on an enterprise plan.
    private func enterprisePayload() -> AnyCodableEquatableBox {
        AnyCodableEquatableBox([
            "five_hour": NSNull(),
            "seven_day": NSNull(),
            "extra_usage": [
                "is_enabled": true,
                "monthly_limit": 60000,
                "used_credits": 1837.0,
                "utilization": 3.0616666666666665,
                "currency": "USD",
                "decimal_places": 2,
                "spend_limit_reached": false,
            ],
            "spend": [
                "used": ["amount_minor": 1837, "currency": "USD", "exponent": 2],
                "limit": ["amount_minor": 60000, "currency": "USD", "exponent": 2],
                "percent": 3,
                "severity": "normal",
                "enabled": true,
            ],
        ])
    }

    func testResponseDecodesEnterpriseDollarSpend() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try XCTUnwrap(
            ClaudeUsageSnapshotParser.response(enterprisePayload(), observedAt: observedAt)
        )

        let spend = try XCTUnwrap(snapshot.spend)
        XCTAssertEqual(spend.usedMinor, 1837)
        XCTAssertEqual(spend.limitMinor, 60000)
        XCTAssertEqual(spend.exponent, 2)
        XCTAssertEqual(spend.currency, "USD")
        XCTAssertEqual(spend.usedPercent, 3)
        XCTAssertEqual(spend.severity, .normal)
        XCTAssertEqual(snapshot.observedAt, observedAt)
    }

    func testResponseFallsBackToExtraUsageWhenSpendBlockAbsent() throws {
        let payload = AnyCodableEquatableBox([
            "extra_usage": [
                "is_enabled": true,
                "monthly_limit": 60000,
                "used_credits": 1837.0,
                "currency": "USD",
                "decimal_places": 2,
                "spend_limit_reached": false,
            ],
        ])
        let spend = try XCTUnwrap(
            ClaudeUsageSnapshotParser.response(payload, observedAt: Date())?.spend
        )
        XCTAssertEqual(spend.usedMinor, 1837)
        XCTAssertEqual(spend.limitMinor, 60000)
        XCTAssertEqual(spend.usedPercent, 3)
    }

    func testResponseReturnsNilWhenNoSpendOrExtraUsage() {
        let payload = AnyCodableEquatableBox(["five_hour": NSNull(), "limits": []])
        XCTAssertNil(ClaudeUsageSnapshotParser.response(payload, observedAt: Date()))
    }

    func testPresentationRendersWholeDollarsAndPercent() {
        let spend = ClaudeUsageSpend(
            usedMinor: 1837, limitMinor: 60000, exponent: 2,
            currency: "USD", usedPercent: 3, severity: .normal, enabled: true
        )
        let snapshot = ClaudeUsageSnapshot(spend: spend, observedAt: Date())
        let presentation = ClaudeUsageGlancePolicy.presentation(for: snapshot)
        XCTAssertEqual(presentation.label, "$18/$600")
        XCTAssertEqual(presentation.percentText, "3%")
        XCTAssertEqual(presentation.severity, .normal)
    }

    func testMissingSnapshotKeepsAPlaceholderLabel() {
        let presentation = ClaudeUsageGlancePolicy.presentation(
            for: Optional<ClaudeUsageSnapshot>.none
        )
        XCTAssertEqual(presentation.label, "$--/$--")
        XCTAssertNil(presentation.severity)
    }

    func testSeverityMappingPrefersServerStringThenThresholds() {
        XCTAssertEqual(ClaudeUsageSeverity.fromServer("normal"), .normal)
        XCTAssertEqual(ClaudeUsageSeverity.fromServer("warning"), .warning)
        XCTAssertEqual(ClaudeUsageSeverity.fromServer("exceeded"), .critical)
        XCTAssertNil(ClaudeUsageSeverity.fromServer("mysterious"))
    }

    func testAvailabilityMirrorsCodexLifecycle() {
        let spend = ClaudeUsageSpend(
            usedMinor: 1837, limitMinor: 60000, exponent: 2,
            currency: "USD", usedPercent: 3, severity: .normal, enabled: true
        )
        let snap = ClaudeUsageSnapshot(spend: spend, observedAt: Date())

        XCTAssertEqual(ClaudeUsageGlancePolicy.availability(
            preferenceEnabled: false, snapshot: snap, isRefreshing: false,
            hasAttemptedRefresh: true, hasRefreshError: false), .disabled)
        XCTAssertEqual(ClaudeUsageGlancePolicy.availability(
            preferenceEnabled: true, snapshot: nil, isRefreshing: true,
            hasAttemptedRefresh: false, hasRefreshError: false), .checking)
        XCTAssertEqual(ClaudeUsageGlancePolicy.availability(
            preferenceEnabled: true, snapshot: snap, isRefreshing: false,
            hasAttemptedRefresh: true, hasRefreshError: false), .available)
        XCTAssertEqual(ClaudeUsageGlancePolicy.availability(
            preferenceEnabled: true, snapshot: snap, isRefreshing: false,
            hasAttemptedRefresh: true, hasRefreshError: true), .stale)
        XCTAssertEqual(ClaudeUsageGlancePolicy.availability(
            preferenceEnabled: true, snapshot: nil, isRefreshing: false,
            hasAttemptedRefresh: true, hasRefreshError: true), .unavailable)
        XCTAssertTrue(ClaudeUsageGlancePolicy.availability(
            preferenceEnabled: true, snapshot: snap, isRefreshing: false,
            hasAttemptedRefresh: true, hasRefreshError: false).showsPill)
    }

    func testDisabledSpendPoolIsNotAMeaningfulSnapshot() {
        let spend = ClaudeUsageSpend(
            usedMinor: 0, limitMinor: 60000, exponent: 2,
            currency: "USD", usedPercent: 0, severity: .normal, enabled: false
        )
        let snap = ClaudeUsageSnapshot(spend: spend, observedAt: Date())
        XCTAssertEqual(ClaudeUsageGlancePolicy.availability(
            preferenceEnabled: true, snapshot: snap, isRefreshing: false,
            hasAttemptedRefresh: true, hasRefreshError: false), .unavailable)
    }

    func testReservationChainsAfterCodexPillOnTheRight() {
        let reservation = ClaudeUsageGlancePolicy.reserveRightSide(
            usableWidth: 200, spacing: 4, enabled: true
        )
        XCTAssertTrue(reservation.showsUsage)
        XCTAssertEqual(reservation.sessionUsableWidth, 200 - ClaudeUsageGlancePolicy.fixedWidth - 4)
    }

    func testReservationHidesWhenItCannotFit() {
        let reservation = ClaudeUsageGlancePolicy.reserveRightSide(
            usableWidth: ClaudeUsageGlancePolicy.fixedWidth - 1, spacing: 4, enabled: true
        )
        XCTAssertFalse(reservation.showsUsage)
        XCTAssertEqual(reservation.sessionUsableWidth, ClaudeUsageGlancePolicy.fixedWidth - 1)
    }
}
