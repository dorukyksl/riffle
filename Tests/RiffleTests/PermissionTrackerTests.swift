import XCTest
@testable import Riffle

/// Permissions coming and going while Riffle runs.
final class PermissionTrackerTests: XCTestCase {
    private func tracker(_ accessibility: Bool, _ screenRecording: Bool) -> PermissionTracker {
        PermissionTracker(accessibility: accessibility, screenRecording: screenRecording)
    }

    func testAtLaunch() {
        let both = tracker(true, true)
        XCTAssertEqual(both.accessibility, .granted)
        XCTAssertEqual(both.screenRecording, .granted)
        XCTAssertFalse(both.needsAccessibility)
        XCTAssertFalse(both.needsRestart)
        let none = tracker(false, false)
        XCTAssertEqual(none.accessibility, .waiting)
        XCTAssertEqual(none.screenRecording, .missing)
        XCTAssertTrue(none.needsAccessibility)
        XCTAssertFalse(none.needsRestart, "nothing to restart for")
    }

    func testNothingHappensWhileNothingChanges() {
        for (accessibility, screenRecording) in [(true, true), (true, false), (false, true), (false, false)] {
            var tracker = tracker(accessibility, screenRecording)
            let before = tracker
            for _ in 0..<3 { XCTAssertEqual(tracker.update(accessibility: accessibility, screenRecording: screenRecording), []) }
            XCTAssertEqual(tracker, before)
        }
    }

    func testAccessibilityGivenAfterLaunchStartsTheEngineOnce() {
        var tracker = tracker(false, true)
        XCTAssertEqual(tracker.update(accessibility: false, screenRecording: true), [])
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: true), [.startEngine])
        XCTAssertEqual(tracker.accessibility, .granted)
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: true), [])
    }

    func testAccessibilityTakenAwayStopsTheEngineUntilItsBack() {
        var tracker = tracker(true, true)
        XCTAssertEqual(tracker.update(accessibility: false, screenRecording: true), [.stopEngine])
        XCTAssertEqual(tracker.accessibility, .revoked)
        XCTAssertTrue(tracker.needsAccessibility)
        // Noticed again on the next look (a summon, the timer): nothing more to do.
        XCTAssertEqual(tracker.update(accessibility: false, screenRecording: true), [])
        // Given again: the engine and the event tap start again, without a relaunch.
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: true), [.startEngine])
        XCTAssertFalse(tracker.needsAccessibility)
        // And it can go and come back as often as it likes.
        XCTAssertEqual(tracker.update(accessibility: false, screenRecording: true), [.stopEngine])
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: true), [.startEngine])
    }

    func testScreenRecordingTakenAwayStopsPreviews() {
        var tracker = tracker(true, true)
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: false), [.stopPreviews])
        XCTAssertEqual(tracker.screenRecording, .revoked)
        XCTAssertFalse(tracker.needsRestart)
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: false), [])
        // Given back: capturing only starts with a new process.
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: true), [.offerRestart])
        XCTAssertTrue(tracker.needsRestart)
    }

    func testScreenRecordingGivenWhileRunningNeedsARestart() {
        var tracker = tracker(true, false)
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: true), [.offerRestart])
        XCTAssertEqual(tracker.screenRecording, .needsRestart)
        XCTAssertTrue(tracker.needsRestart)
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: true), [], "offered once")
        // Taken back before the restart: nothing to restart for any more.
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: false), [])
        XCTAssertEqual(tracker.screenRecording, .missing)
        XCTAssertFalse(tracker.needsRestart)
    }

    func testScreenRecordingHadAtLaunchTakenBackBeforeTheRestart() {
        var tracker = tracker(true, true)
        _ = tracker.update(accessibility: true, screenRecording: false)
        _ = tracker.update(accessibility: true, screenRecording: true)
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: false), [])
        XCTAssertEqual(tracker.screenRecording, .revoked, "its previews already stopped")
    }

    func testBothChangingAtOnce() {
        var tracker = tracker(true, true)
        XCTAssertEqual(tracker.update(accessibility: false, screenRecording: false), [.stopEngine, .stopPreviews])
        XCTAssertEqual(tracker.update(accessibility: true, screenRecording: true), [.startEngine, .offerRestart])
    }
}

/// When the welcome window opens at launch, now that previews can be declined.
final class WelcomeWindowTests: XCTestCase {
    func testItComesBackUntilEverythingItAsksForIsSettled() {
        // The owner's setup: everything granted, done long ago.
        XCTAssertFalse(OnboardingWindow.isNeeded(accessibility: true, screenRecording: true, completed: true, withoutPreviews: false))
        // Not done yet, or Accessibility missing: always.
        XCTAssertTrue(OnboardingWindow.isNeeded(accessibility: true, screenRecording: true, completed: false, withoutPreviews: false))
        XCTAssertTrue(OnboardingWindow.isNeeded(accessibility: false, screenRecording: true, completed: true, withoutPreviews: false))
        XCTAssertTrue(OnboardingWindow.isNeeded(accessibility: false, screenRecording: false, completed: true, withoutPreviews: true))
        // No previews: asked again at every launch, until declined.
        XCTAssertTrue(OnboardingWindow.isNeeded(accessibility: true, screenRecording: false, completed: true, withoutPreviews: false))
        XCTAssertFalse(OnboardingWindow.isNeeded(accessibility: true, screenRecording: false, completed: true, withoutPreviews: true))
    }

    func testClosingItCountsAsDoneOnceSettled() {
        XCTAssertTrue(OnboardingWindow.isDone(accessibility: true, screenRecording: true, withoutPreviews: false))
        XCTAssertTrue(OnboardingWindow.isDone(accessibility: true, screenRecording: false, withoutPreviews: true))
        XCTAssertFalse(OnboardingWindow.isDone(accessibility: true, screenRecording: false, withoutPreviews: false))
        XCTAssertFalse(OnboardingWindow.isDone(accessibility: false, screenRecording: true, withoutPreviews: true))
    }
}
