import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import XCTest
@testable import Hermes

/// Runs the transition's scheduled steps on demand, in order.
@MainActor
private final class StepScheduler {
    private(set) var delays: [TimeInterval] = []
    private var steps: [(delay: TimeInterval, run: @MainActor () -> Void)] = []

    func install(on transition: CantripTabBackTransition) {
        // Strong: the transition owns its scheduler, and nothing points back.
        transition.schedule = { delay, step in
            self.delays.append(delay)
            self.steps.append((delay, step))
        }
    }

    var isEmpty: Bool { steps.isEmpty }

    /// Runs everything queued so far; steps they schedule wait for the next call.
    func runPending() {
        let queued = steps
        steps = []
        queued.forEach { $0.run() }
    }

    /// Runs only the queued steps with this delay, as if that much time had passed for them.
    func run(delay: TimeInterval) {
        let due = steps.filter { $0.delay == delay }
        steps.removeAll { $0.delay == delay }
        due.forEach { $0.run() }
    }
}

@MainActor
final class CantripTabBackTransitionTests: XCTestCase {
    private func snapshot(width: CGFloat = 400) -> CantripScreenSnapshot {
        #if os(iOS)
        CantripScreenSnapshot(windowSize: CGSize(width: width, height: 860), colorScheme: .dark, view: UIView())
        #else
        CantripScreenSnapshot(windowSize: CGSize(width: width, height: 860), colorScheme: .dark)
        #endif
    }

    private func transition(snapshot: CantripScreenSnapshot? = nil) -> (CantripTabBackTransition, StepScheduler) {
        let transition = CantripTabBackTransition()
        let scheduler = StepScheduler()
        scheduler.install(on: transition)
        transition.snapshotFits = { snapshot, scheme in snapshot.colorScheme == scheme }
        transition.width = 400
        transition.keepHomeSnapshot(snapshot)
        return (transition, scheduler)
    }

    func testOnlyASidewaysDragFromTheLeadingEdgeStartsTheBackSwipe() {
        XCTAssertTrue(CantripBackSwipe.begins(start: CGPoint(x: 6, y: 300), translation: CGSize(width: 14, height: 3)))
        XCTAssertTrue(CantripBackSwipe.begins(start: CGPoint(x: 24, y: 300), translation: CGSize(width: 30, height: -12)))
        XCTAssertFalse(CantripBackSwipe.begins(start: CGPoint(x: 40, y: 300), translation: CGSize(width: 60, height: 0)),
                       "Away from the edge the drag belongs to the transcript")
        XCTAssertFalse(CantripBackSwipe.begins(start: CGPoint(x: 4, y: 300), translation: CGSize(width: 12, height: 20)),
                       "Mostly vertical: a scroll")
        XCTAssertFalse(CantripBackSwipe.begins(start: CGPoint(x: 4, y: 300), translation: CGSize(width: -20, height: 0)))
    }

    func testReleaseFinishesPastAThirdOrOnAFlick() {
        XCTAssertFalse(CantripBackSwipe.completes(offset: 120, predictedOffset: 150, width: 400))
        XCTAssertTrue(CantripBackSwipe.completes(offset: 140, predictedOffset: 140, width: 400))
        XCTAssertTrue(CantripBackSwipe.completes(offset: 60, predictedOffset: 260, width: 400), "A flick carries past halfway")
        XCTAssertFalse(CantripBackSwipe.completes(offset: 10, predictedOffset: 300, width: 400),
                       "A twitch at the edge is not a swipe")
        XCTAssertFalse(CantripBackSwipe.completes(offset: 300, predictedOffset: 300, width: 0))
    }

    func testHomeCatchesUpUnderTheTabAndTheFinishIsBrisk() {
        XCTAssertEqual(CantripBackSwipe.underlayOffset(progress: 0, width: 400), -120)
        XCTAssertEqual(CantripBackSwipe.underlayOffset(progress: 0.5, width: 400), -60)
        XCTAssertEqual(CantripBackSwipe.underlayOffset(progress: 1, width: 400), 0)
        XCTAssertEqual(CantripBackSwipe.progress(offset: 500, width: 400), 1)
        XCTAssertEqual(CantripBackSwipe.progress(offset: -20, width: 400), 0)
        let slow = CantripBackSwipe.finishDuration(offset: 200, width: 400, velocity: 0)
        let flick = CantripBackSwipe.finishDuration(offset: 200, width: 400, velocity: 2000)
        XCTAssertEqual(slow, CantripBackSwipe.buttonDuration / 2, accuracy: 0.001)
        XCTAssertEqual(flick, 0.12, accuracy: 0.001, "Never faster than 120 ms")
        XCTAssertLessThanOrEqual(CantripBackSwipe.finishDuration(offset: 0, width: 400, velocity: 0),
                                 CantripBackSwipe.buttonDuration)
        XCTAssertEqual(CantripBackSwipe.finishDuration(offset: 400, width: 400, velocity: 0), 0)
    }

    func testTheTabFollowsTheFingerAndSpringsBackWhenReleasedEarly() {
        let (transition, scheduler) = transition(snapshot: snapshot())
        var popped = 0
        transition.track(30)
        transition.track(110)
        XCTAssertEqual(transition.phase, .tracking)
        XCTAssertEqual(transition.offset, 110)
        XCTAssertTrue(transition.showsUnderlay)
        transition.track(-40)
        XCTAssertEqual(transition.offset, 0, "The tab never moves past its resting place")
        transition.track(100)
        transition.release(predictedOffset: 120, velocity: 40, colorScheme: .dark) { popped += 1 }
        XCTAssertEqual(transition.phase, .settling)
        XCTAssertEqual(transition.offset, 0)
        XCTAssertFalse(transition.acceptsGesture)
        scheduler.runPending()
        XCTAssertEqual(transition.phase, .idle)
        XCTAssertEqual(popped, 0)
        XCTAssertNotNil(transition.homeSnapshot, "A cancelled swipe keeps Home's picture for the next one")
    }

    func testAFinishedSwipeShowsHomesPictureUntilTheLiveConversationLoads() {
        let (transition, scheduler) = transition(snapshot: snapshot())
        var popped = 0
        transition.track(220)
        transition.release(predictedOffset: 260, velocity: 300, colorScheme: .dark) { popped += 1 }
        XCTAssertEqual(transition.phase, .finishing)
        XCTAssertGreaterThan(transition.offset, 400, "The tab slides all the way off")
        XCTAssertEqual(popped, 0, "Home is selected only once the tab is gone")
        scheduler.runPending()
        XCTAssertEqual(popped, 1)
        XCTAssertEqual(transition.phase, .covering)
        XCTAssertFalse(transition.isSliding, "By the time the lane change is observed, the pop has moved on")
        XCTAssertEqual(transition.offset, 0, "The live view returns to place under the picture")
        XCTAssertEqual(transition.coverOpacity, 1)
        XCTAssertFalse(transition.acceptsGesture, "Taps wait until the real Home shows")

        transition.homeBecameReady()
        scheduler.run(delay: 0.12)
        XCTAssertEqual(transition.coverOpacity, 0, "The picture fades out over the reloaded Home")
        XCTAssertEqual(transition.phase, .covering)
        scheduler.run(delay: CantripTabBackTransition.revealDuration)
        XCTAssertEqual(transition.phase, .idle)
        XCTAssertNotNil(transition.homeSnapshot, "The picture stays as Home's latest view until a fresh one replaces it")
        XCTAssertEqual(transition.coverOpacity, 1)
        scheduler.run(delay: CantripTabBackTransition.coverTimeout)
        XCTAssertTrue(scheduler.isEmpty)
        XCTAssertEqual(transition.phase, .idle, "The cover timeout is void once Home showed")
        XCTAssertEqual(popped, 1)
    }

    func testThePictureStepsAsideIfHomeIsSlowToLoad() {
        let (transition, scheduler) = transition(snapshot: snapshot())
        transition.track(300)
        transition.release(predictedOffset: 300, velocity: 0, colorScheme: .dark) {}
        scheduler.runPending()
        XCTAssertEqual(transition.phase, .covering)
        XCTAssertEqual(scheduler.delays.last, CantripTabBackTransition.coverTimeout)
        scheduler.runPending()
        XCTAssertEqual(transition.coverOpacity, 0)
        scheduler.runPending()
        XCTAssertEqual(transition.phase, .idle)
    }

    func testWithoutAPictureHomeFadesIn() {
        for hasPicture in [true, false] {
            let (transition, scheduler) = transition(snapshot: hasPicture ? snapshot() : nil)
            transition.snapshotFits = { _, _ in false }
            var popped = false
            transition.track(300)
            transition.release(predictedOffset: 300, velocity: 0, colorScheme: .dark) { popped = true }
            XCTAssertNil(transition.homeSnapshot, "A picture from another size or appearance is not shown")
            scheduler.runPending()
            XCTAssertTrue(popped)
            XCTAssertEqual(transition.phase, .entering)
            XCTAssertEqual(transition.contentOpacity, 1)
            scheduler.runPending()
            XCTAssertEqual(transition.phase, .idle)
        }
    }

    func testTheHomeButtonSlidesTheTabAwayUnlessMotionIsReduced() {
        let (sliding, scheduler) = transition(snapshot: snapshot())
        var popped = 0
        sliding.popFromButton(colorScheme: .dark, reduceMotion: false) { popped += 1 }
        XCTAssertEqual(sliding.phase, .finishing)
        XCTAssertEqual(scheduler.delays.last, CantripBackSwipe.buttonDuration)
        sliding.popFromButton(colorScheme: .dark, reduceMotion: false) { popped += 1 }
        scheduler.runPending()
        XCTAssertEqual(popped, 1, "A second tap during the slide does nothing")
        XCTAssertEqual(sliding.phase, .covering)

        let (still, _) = transition(snapshot: snapshot())
        var stillPopped = false
        still.popFromButton(colorScheme: .dark, reduceMotion: true) { stillPopped = true }
        XCTAssertTrue(stillPopped, "Reduce Motion goes straight to Home")
        XCTAssertEqual(still.phase, .covering)
        XCTAssertEqual(still.offset, 0)
    }

    func testTheLatestPictureOfHomeIsKeptButNeverSwappedMidTransition() {
        let (transition, scheduler) = transition()
        transition.keepHomeSnapshot(nil)
        XCTAssertNil(transition.homeSnapshot, "A failed capture keeps whatever there was")
        transition.keepHomeSnapshot(snapshot(width: 400))
        transition.keepHomeSnapshot(nil)
        XCTAssertNotNil(transition.homeSnapshot)
        transition.track(50)
        transition.keepHomeSnapshot(snapshot(width: 390))
        XCTAssertEqual(transition.homeSnapshot?.windowSize.width, 400, "The screen shows the swipe, not Home")
        transition.release(predictedOffset: 50, velocity: 0, colorScheme: .dark) {}
        scheduler.runPending()
        transition.keepHomeSnapshot(snapshot(width: 390))
        XCTAssertEqual(transition.homeSnapshot?.windowSize.width, 390)
    }

    func testResetAbandonsAPopInProgress() {
        let (transition, scheduler) = transition(snapshot: snapshot())
        var popped = false
        transition.track(300)
        XCTAssertTrue(transition.isSliding)
        transition.release(predictedOffset: 300, velocity: 0, colorScheme: .dark) { popped = true }
        XCTAssertTrue(transition.isSliding, "Still sliding until the lane switches")
        transition.keepHomeSnapshot(snapshot(width: 390))
        XCTAssertEqual(transition.homeSnapshot?.windowSize.width, 400, "No new picture mid-transition")
        transition.reset()
        XCTAssertEqual(transition.phase, .idle)
        XCTAssertEqual(transition.offset, 0)
        scheduler.runPending()
        XCTAssertFalse(popped, "Another tab opened mid-swipe; Home must not be selected late")
        XCTAssertEqual(transition.phase, .idle)
        transition.cancelTracking()
        XCTAssertEqual(transition.phase, .idle, "Nothing to cancel")
    }
}
