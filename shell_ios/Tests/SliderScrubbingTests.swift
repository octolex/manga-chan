//
//  SliderScrubbingTests.swift
//
//  The arithmetic behind variable-gain scrubbing, tested without a view.
//
//  Every one of these is a bug that would be invisible on a screenshot and hard
//  to pin down by hand: a value that jumps when the gain changes, a drag that
//  sticks at an end and will not come back, a rate that reaches zero and traps
//  the control. They are the reason this logic is a value type instead of ten
//  lines inside a touch handler.
//

import CoreGraphics
import Foundation
import XCTest

final class SliderScrubbingTests: XCTestCase {

    // MARK: - The gain curve

    func testDraggingAlongTheTrackIsExactlyOneToOne() {
        let s = SliderScrubbing()
        // Nobody holds a finger on a line. Without a dead zone every ordinary
        // drag would be slightly slowed and the control would feel heavy.
        XCTAssertEqual(s.gain(atDistance: 0), 1)
        XCTAssertEqual(s.gain(atDistance: s.deadZone), 1)
        XCTAssertEqual(s.gain(atDistance: -s.deadZone), 1, "distance is unsigned")
    }

    func testEveryHalvingDistanceHalvesTheRate() {
        // The whole model in one assertion, and the reason it is stated as a
        // rule rather than a curve: a person can learn "one thumb-width, half
        // speed" and predict the control.
        let s = SliderScrubbing()
        let one = s.gain(atDistance: s.deadZone + s.halvingDistance)
        let two = s.gain(atDistance: s.deadZone + s.halvingDistance * 2)
        let three = s.gain(atDistance: s.deadZone + s.halvingDistance * 3)

        XCTAssertEqual(one, 0.5, accuracy: 0.001)
        XCTAssertEqual(two, 0.25, accuracy: 0.001)
        XCTAssertEqual(three, 0.125, accuracy: 0.001)
    }

    func testTheRateNeverReachesZero() {
        // A control that stops responding is broken, however far the finger is.
        let s = SliderScrubbing()
        XCTAssertEqual(s.gain(atDistance: 5000), s.minimumGain, accuracy: 1e-6)
        XCTAssertGreaterThan(s.gain(atDistance: 100_000), 0)
    }

    func testTheGainNeverExceedsOne() {
        // Above 1 the thumb would outrun the finger, which reads as the control
        // fighting you rather than helping.
        let s = SliderScrubbing()
        for d in stride(from: CGFloat(-400), through: 400, by: 7) {
            XCTAssertLessThanOrEqual(s.gain(atDistance: d), 1)
        }
    }

    // MARK: - The drag

    func testOnTheTrackTheThumbFollowsTheFinger() {
        var drag = SliderDrag(startingAt: 0, alongTrack: 0, trackLength: 200)
        drag.update(alongTrack: 100, perpendicular: 0)
        XCTAssertEqual(drag.position, 0.5, accuracy: 1e-6,
                       "half the track travelled must be half the range")
    }

    func testMovingAwaySlowsTheValueDown() {
        var near = SliderDrag(startingAt: 0.5, alongTrack: 0, trackLength: 200)
        var far = SliderDrag(startingAt: 0.5, alongTrack: 0, trackLength: 200)

        near.update(alongTrack: 40, perpendicular: 0)
        far.update(alongTrack: 40, perpendicular: 24 + 100)   // two halvings

        let nearMoved = near.position - 0.5
        let farMoved = far.position - 0.5
        XCTAssertEqual(farMoved, nearMoved * 0.25, accuracy: 1e-5)
    }

    /// The bug this type exists to prevent. Gain applies to the movement since
    /// the last event, not to the total — so changing distance mid-drag must
    /// not retroactively rescale everything already travelled.
    func testChangingDistanceMidDragDoesNotJump() {
        var drag = SliderDrag(startingAt: 0, alongTrack: 0, trackLength: 100)

        drag.update(alongTrack: 50, perpendicular: 0)          // 1:1, +0.50
        let afterFirst = drag.position
        XCTAssertEqual(afterFirst, 0.5, accuracy: 1e-6)

        // Move far away without moving along the track at all. If gain were
        // applied to a total translation, this alone would change the value.
        drag.update(alongTrack: 50, perpendicular: 300)
        XCTAssertEqual(drag.position, afterFirst, accuracy: 1e-9,
                       "distance alone must never move the value")
    }

    /// Coming back toward the track keeps the offset the detour bought. The
    /// thumb does not snap under the finger.
    func testTheOffsetPersistsOnReturn() {
        var drag = SliderDrag(startingAt: 0, alongTrack: 0, trackLength: 100)

        drag.update(alongTrack: 0, perpendicular: 24 + 50)     // half rate
        drag.update(alongTrack: 40, perpendicular: 24 + 50)    // +0.20, not 0.40
        XCTAssertEqual(drag.position, 0.20, accuracy: 1e-5)

        // Back on the track, and moving on again is 1:1 from where it is —
        // not a jump to where the finger happens to be.
        drag.update(alongTrack: 50, perpendicular: 0)
        XCTAssertEqual(drag.position, 0.30, accuracy: 1e-5)
    }

    func testTheValueStaysInRange() {
        var drag = SliderDrag(startingAt: 0.5, alongTrack: 0, trackLength: 100)
        drag.update(alongTrack: 10_000, perpendicular: 0)
        XCTAssertEqual(drag.position, 1)
        drag.update(alongTrack: -10_000, perpendicular: 0)
        XCTAssertEqual(drag.position, 0)
    }

    /// Overshooting an end and coming back must respond immediately. If the
    /// clamp accumulated instead, the finger would have to "unwind" all the
    /// travel it wasted past the end before anything moved — which feels
    /// exactly like a frozen control.
    func testAnOvershootDoesNotHaveToBeUnwound() {
        var drag = SliderDrag(startingAt: 0.9, alongTrack: 0, trackLength: 100)
        drag.update(alongTrack: 500, perpendicular: 0)         // far past the end
        XCTAssertEqual(drag.position, 1)

        drag.update(alongTrack: 490, perpendicular: 0)         // back 10 points
        XCTAssertEqual(drag.position, 0.9, accuracy: 1e-5,
                       "coming back must move at once, not after unwinding")
    }

    func testAZeroLengthTrackIsInertRatherThanInfinite() {
        // A control asked for its value before layout. Inert is the right
        // failure; dividing by zero is not.
        var drag = SliderDrag(startingAt: 0.5, alongTrack: 0, trackLength: 0)
        drag.update(alongTrack: 10, perpendicular: 0)
        XCTAssertTrue(drag.position.isFinite)
        XCTAssertGreaterThanOrEqual(drag.position, 0)
        XCTAssertLessThanOrEqual(drag.position, 1)
    }

    func testTheStartingPositionIsClamped() {
        XCTAssertEqual(SliderDrag(startingAt: 5, alongTrack: 0, trackLength: 100).position, 1)
        XCTAssertEqual(SliderDrag(startingAt: -5, alongTrack: 0, trackLength: 100).position, 0)
    }

    /// A vertical slider passes y as "along" and x as "perpendicular". Nothing
    /// in the model should care, and this is what says so.
    func testTheModelIsAxisAgnostic() {
        var horizontal = SliderDrag(startingAt: 0, alongTrack: 0, trackLength: 200)
        var vertical = SliderDrag(startingAt: 0, alongTrack: 0, trackLength: 200)
        horizontal.update(alongTrack: 60, perpendicular: 80)
        vertical.update(alongTrack: 60, perpendicular: 80)
        XCTAssertEqual(horizontal.position, vertical.position)
    }
}
