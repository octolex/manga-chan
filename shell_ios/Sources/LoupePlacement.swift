//
//  LoupePlacement.swift
//
//  Where the eyedropper's ring goes, as plain geometry so it is tested in CI.
//
//  Found on the device, 2026-11-07 (B4): the ring sat a fixed distance above
//  the finger, so picking a colour near the top edge or a corner pushed it off
//  the screen. Procreate does the same. octolex asked for it to avoid every
//  edge smoothly, without ever moving under the finger, where the finger would
//  cover it.
//
//  So the ring orbits the finger at a fixed distance rather than sliding
//  toward it. Above is preferred, because the hand comes from below. When
//  above does not fit, it turns by the smallest angle that does, toward the
//  middle of the screen first. The distance never shrinks, so the finger can
//  never cover it.
//

import CoreGraphics
import Foundation

enum LoupePlacement {

    /// Straight up, in view coordinates where y grows downward.
    static let up: CGFloat = -.pi / 2

    /// The angle, around the finger, at which a ring of `radius` sits
    /// `distance` away and lies fully inside `bounds` less `margin`.
    ///
    /// Searches outward from `preferred` in steps of 2.5°, trying the side
    /// toward the middle of the screen first at each step. Returns `preferred`
    /// when nothing fits, which only a bounds smaller than the ring can cause.
    static func angle(finger: CGPoint, bounds: CGRect, radius: CGFloat, distance: CGFloat,
                      margin: CGFloat = 8, preferred: CGFloat = up) -> CGFloat {
        let safe = bounds.insetBy(dx: radius + margin, dy: radius + margin)
        guard !safe.isNull, safe.width >= 0, safe.height >= 0 else { return preferred }
        func fits(_ a: CGFloat) -> Bool {
            let c = center(finger: finger, angle: a, distance: distance)
            return c.x >= safe.minX && c.x <= safe.maxX && c.y >= safe.minY && c.y <= safe.maxY
        }
        if fits(preferred) { return preferred }

        // A positive turn from straight up swings the ring to the right.
        let towardMiddle: CGFloat = finger.x < bounds.midX ? 1 : -1
        let step = CGFloat.pi / 72
        var turn = step
        while turn <= .pi + step / 2 {
            for sign in [towardMiddle, -towardMiddle] {
                let a = preferred + sign * turn
                if fits(a) { return a }
            }
            turn += step
        }
        return preferred
    }

    static func center(finger: CGPoint, angle: CGFloat, distance: CGFloat) -> CGPoint {
        CGPoint(x: finger.x + cos(angle) * distance, y: finger.y + sin(angle) * distance)
    }

    /// Moves `current` a `fraction` of the way to `target`, the short way
    /// round. Called once per touch update, it glides the ring to a new side
    /// instead of jumping there.
    static func ease(from current: CGFloat, to target: CGFloat, fraction: CGFloat) -> CGFloat {
        let difference = atan2(sin(target - current), cos(target - current))
        return current + difference * fraction
    }

    /// Keeps a centre inside `bounds` less `radius + margin`. A safety net
    /// for the frames in which an eased angle has not yet reached one that
    /// fits.
    static func clamped(_ point: CGPoint, bounds: CGRect, radius: CGFloat,
                        margin: CGFloat = 8) -> CGPoint {
        let safe = bounds.insetBy(dx: radius + margin, dy: radius + margin)
        guard !safe.isNull, safe.width >= 0, safe.height >= 0 else { return point }
        return CGPoint(x: min(max(point.x, safe.minX), safe.maxX),
                       y: min(max(point.y, safe.minY), safe.maxY))
    }
}
