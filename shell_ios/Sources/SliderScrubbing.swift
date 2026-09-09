//
//  SliderScrubbing.swift
//
//  Variable-gain scrubbing: the further your finger is from the track, the
//  slower the value moves.
//
//  The problem it solves is specific and, once seen, impossible to unsee. You
//  drag a slider to exactly the value you want, and then lifting your finger
//  moves it — because a finger does not leave the glass straight up, it rolls
//  slightly as it goes. On a 1:1 slider that roll is worth several units, so
//  the last thing that happens before you get what you asked for is that you
//  stop getting it.
//
//  Dragging away from the track scales the gain down, so near the end of a
//  precise adjustment a millimetre of finger roll is worth a fraction of a
//  unit. Apple's media scrubber does this in discrete named steps; here it is
//  continuous, and the rule is one sentence: **every `halvingDistance` points
//  away from the track halves the rate.** That is learnable — after a few
//  minutes a person knows roughly how far to move for the precision they want,
//  which a curve nobody can state never becomes.
//
//  Two consequences worth stating rather than discovering:
//
//  **The thumb stops following the finger.** Below a gain of 1 it must: the
//  finger has moved further than the value has. That is not a defect, it is
//  the feature — and it is why the offset *persists* when the finger comes
//  back toward the track rather than the thumb snapping under it. Snapping
//  back would throw away the precision the detour just bought.
//
//  **It accumulates deltas, never a total.** Gain applies to the movement
//  since the last touch event, at the gain in force for that event. Scaling a
//  total translation instead would make the value jump the moment the gain
//  changed, because the same total would suddenly be worth something else.
//  That is the bug this type exists to make untestable-by-eye rather than
//  merely unlikely, and it is why the arithmetic lives here as plain values
//  instead of inside a gesture recogniser.
//

import CoreGraphics
import Foundation

/// How perpendicular distance turns into a rate multiplier.
struct SliderScrubbing: Equatable {

    /// Within this distance of the track, dragging is exactly 1:1. Without a
    /// dead zone every ordinary drag would be slightly slowed, because no one
    /// holds a finger perfectly on a line.
    var deadZone: CGFloat = 24

    /// Every this many points beyond the dead zone halves the rate. 50 puts
    /// quarter speed about a thumb's width away and 1/16th at arm's reach
    /// across an iPad, which covers "a bit finer" through "hair-splitting"
    /// without needing a second gesture.
    var halvingDistance: CGFloat = 50

    /// The rate never reaches zero, so the control can always still be moved.
    /// At 1/64 a full-width drag still crosses about 1.5% of the range, which
    /// is slow enough to place a single unit and fast enough not to feel stuck.
    var minimumGain: CGFloat = 1.0 / 64.0

    /// Rate multiplier at a given perpendicular distance from the track.
    func gain(atDistance distance: CGFloat) -> CGFloat {
        let d = abs(distance)
        guard d > deadZone else { return 1 }
        guard halvingDistance > 0 else { return minimumGain }

        let halvings = (d - deadZone) / halvingDistance
        return max(minimumGain, CGFloat(pow(2.0, Double(-halvings))))
    }
}

/// One in-progress drag. A value type so the arithmetic can be tested without
/// a view, a touch, or a run loop.
struct SliderDrag {

    /// 0...1. The control maps this onto its own range.
    private(set) var position: CGFloat

    private let scrubbing: SliderScrubbing
    private let trackLength: CGFloat
    private var lastAlongTrack: CGFloat

    /// Largest gain used so far this drag, purely for the readout — a control
    /// that says "fine" while the finger is far out tells the user the slowdown
    /// is deliberate rather than the app struggling.
    private(set) var currentGain: CGFloat = 1

    init(startingAt position: CGFloat,
         alongTrack: CGFloat,
         trackLength: CGFloat,
         scrubbing: SliderScrubbing = SliderScrubbing()) {
        self.position = min(max(position, 0), 1)
        self.lastAlongTrack = alongTrack
        // A zero-length track would divide by zero on the first move. Clamping
        // to 1 makes the drag inert rather than infinite, which is the right
        // failure for a control that has not been laid out yet.
        self.trackLength = max(trackLength, 1)
        self.scrubbing = scrubbing
    }

    /// Feed one touch position. Returns the new normalised position.
    ///
    /// `alongTrack` and `perpendicular` are in the control's own coordinates,
    /// so a vertical slider passes y and x and everything below is unchanged.
    @discardableResult
    mutating func update(alongTrack: CGFloat, perpendicular: CGFloat) -> CGFloat {
        let gain = scrubbing.gain(atDistance: perpendicular)
        currentGain = gain

        let delta = alongTrack - lastAlongTrack
        lastAlongTrack = alongTrack

        position = min(max(position + (delta * gain) / trackLength, 0), 1)
        return position
    }
}
