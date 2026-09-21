import XCTest
@testable import nib

/// What the status panel says about each part of nib.
///
/// Only the rows driven purely by injected state are asserted on. Rewrite,
/// dictation and speech read the file system, so their verdict depends on what
/// this machine has downloaded and a test that asserted one would pass or fail
/// by accident.
final class HealthTests: XCTestCase {
    private func context(
        trusted: Bool = true, grammar: Bool = true, live: Bool = true,
        hotkeys: [(name: String, combo: String?)] = [("Check Selection", "⌃⌘N")],
        failures: [Feature: String] = [:]
    ) -> HealthContext {
        HealthContext(accessibilityTrusted: trusted, grammarRunning: grammar,
                      rewriterLoaded: false, liveCheckingEnabled: live,
                      hotkeys: hotkeys, lastFailures: failures)
    }

    func testEveryFeatureGetsARow() {
        XCTAssertEqual(Health.report(context()).count, Feature.allCases.count)
    }

    /// The point of the panel. A broken row must say why and what to do, or it
    /// is just a red dot -- which is what the menu bar already was.
    func testABrokenRowAlwaysSaysWhyAndHowToFix() {
        for row in Health.report(context(trusted: false, grammar: false))
        where row.state == .broken {
            XCTAssertNotNil(row.reason, "\(row.feature) is broken with no reason")
            XCTAssertNotNil(row.fix, "\(row.feature) is broken with no fix")
            XCTAssertFalse(row.reason?.isEmpty ?? true)
            XCTAssertFalse(row.fix?.isEmpty ?? true)
        }
    }

    func testWithoutAccessibilityBothItAndUnderliningAreBroken() {
        let rows = Health.report(context(trusted: false))
        let byFeature = Dictionary(uniqueKeysWithValues: rows.map { ($0.feature, $0) })
        XCTAssertEqual(byFeature[.accessibility]?.state, .broken)
        XCTAssertEqual(byFeature[.liveChecking]?.state, .broken)
    }

    /// Off is a choice. Reporting something the user switched off as broken is
    /// how a status panel stops being believed.
    func testUnderliningSwitchedOffIsNotBroken() {
        let row = Health.row(for: .liveChecking, context: context(live: false))
        XCTAssertEqual(row.state, .degraded)
        XCTAssertNil(row.reason)
    }

    /// A recorded failure outranks the inference. harper being constructed says
    /// it could work; the error says it did not.
    func testARecordedFailureBeatsTheInferredState() {
        let row = Health.row(for: .grammar,
                             context: context(failures: [.grammar: "pipe closed"]))
        XCTAssertEqual(row.state, .broken)
        XCTAssertEqual(row.reason, "pipe closed")
        XCTAssertTrue(row.restartable)
    }

    /// A shortcut held by another app is the common cause and is invisible:
    /// macOS gives a combination to one app and tells the loser nothing.
    func testAnUnregisteredShortcutIsDegradedAndNamesTheCulprit() {
        let row = Health.row(for: .hotkeys, context: context(
            hotkeys: [("Check Selection", "⌃⌘N"), ("Dictate", nil)]))
        XCTAssertEqual(row.state, .degraded)
        XCTAssertTrue(row.reason?.contains("Dictate") ?? false, row.reason ?? "")
        XCTAssertTrue(row.detail.contains("1 of 2"), row.detail)
    }

    func testAllShortcutsRegisteredReadsAsWorking() {
        let row = Health.row(for: .hotkeys, context: context(
            hotkeys: [("Check Selection", "⌃⌘N"), ("Dictate", "⌃⌥D")]))
        XCTAssertEqual(row.state, .working)
        XCTAssertNil(row.reason)
    }

    /// Degraded is not broken. A missing optional shortcut is not a reason to
    /// tell someone their app is not working.
    func testDegradedDoesNotCountAsBroken() {
        let rows = [
            Health.row(for: .hotkeys,
                       context: context(hotkeys: [("Dictate", nil)])),
            Health.row(for: .liveChecking, context: context(live: false)),
        ]
        XCTAssertTrue(Health.allWorking(rows))
    }

    func testAnAccessibilityFailureCountsAsNotWorking() {
        XCTAssertFalse(Health.allWorking(Health.report(context(trusted: false))))
    }

    /// Every row says what it is for, working or not: someone opening this is
    /// looking for the feature by what it does, not by its internal name.
    func testEveryRowExplainsWhatTheFeatureIsFor() {
        for feature in Feature.allCases {
            XCTAssertFalse(feature.purpose.isEmpty, "\(feature) has no purpose")
            XCTAssertFalse(feature.title.isEmpty, "\(feature) has no title")
        }
    }
}
