//
//  LoupePlacementTests.swift
//
//  The eyedropper ring must stay fully on screen wherever the finger is, and
//  never move under the finger to get there (B4, 2026-11-07).
//

import CoreGraphics
import XCTest

final class LoupePlacementTests: XCTestCase {

    // The shipping ring: 96 pt across, its centre 88 pt from the finger.
    private let radius: CGFloat = 48
    private let distance: CGFloat = 88
    private let margin: CGFloat = 8
    private let screen = CGRect(x: 0, y: 0, width: 1024, height: 1366)

    private func centre(for finger: CGPoint, in bounds: CGRect? = nil) -> CGPoint {
        let bounds = bounds ?? screen
        let a = LoupePlacement.angle(finger: finger, bounds: bounds,
                                     radius: radius, distance: distance, margin: margin)
        return LoupePlacement.center(finger: finger, angle: a, distance: distance)
    }

    func testAwayFromTheEdgesTheRingSitsStraightAbove() {
        let finger = CGPoint(x: 400, y: 700)
        let c = centre(for: finger)
        XCTAssertEqual(c.x, finger.x, accuracy: 0.001)
        XCTAssertEqual(c.y, finger.y - distance, accuracy: 0.001)
    }

    /// The whole screen, edges and corners included, in both orientations:
    /// every placement keeps the ring fully visible.
    func testTheRingIsFullyOnScreenWhereverTheFingerIs() {
        for bounds in [screen, CGRect(x: 0, y: 0, width: 1366, height: 1024)] {
            let safe = bounds.insetBy(dx: radius + margin, dy: radius + margin)
            var y: CGFloat = 0
            while y <= bounds.maxY {
                var x: CGFloat = 0
                while x <= bounds.maxX {
                    let c = centre(for: CGPoint(x: x, y: y), in: bounds)
                    XCTAssertTrue(c.x >= safe.minX - 0.001 && c.x <= safe.maxX + 0.001
                                  && c.y >= safe.minY - 0.001 && c.y <= safe.maxY + 0.001,
                                  "ring off screen for a finger at (\(x), \(y))")
                    x += 16
                }
                y += 16
            }
        }
    }

    /// The finger can never cover the ring: it orbits at a fixed distance,
    /// it never slides in toward the finger.
    func testTheRingNeverMovesUnderTheFinger() {
        for finger in [CGPoint(x: 2, y: 2), CGPoint(x: 1020, y: 4), CGPoint(x: 512, y: 1360),
                       CGPoint(x: 3, y: 700)] {
            let c = centre(for: finger)
            let gap = ((c.x - finger.x) * (c.x - finger.x)
                       + (c.y - finger.y) * (c.y - finger.y)).squareRoot()
            XCTAssertEqual(gap, distance, accuracy: 0.001)
            // A fingertip is about 22 pt across its middle; the ring's inner
            // edge stays well clear of it.
            XCTAssertGreaterThan(gap - radius, 22)
        }
    }

    /// Near the left edge it turns right, toward the middle, and by no more
    /// than it has to.
    func testItTurnsByTheSmallestAngleTowardTheMiddle() {
        let finger = CGPoint(x: 20, y: 700)
        let a = LoupePlacement.angle(finger: finger, bounds: screen,
                                     radius: radius, distance: distance, margin: margin)
        XCTAssertGreaterThan(a, LoupePlacement.up, "should swing toward the middle")
        XCTAssertLessThan(a - LoupePlacement.up, .pi / 6, "turned further than it needed to")

        let right = CGPoint(x: 1004, y: 700)
        let b = LoupePlacement.angle(finger: right, bounds: screen,
                                     radius: radius, distance: distance, margin: margin)
        XCTAssertLessThan(b, LoupePlacement.up)
    }

    /// The glide goes the short way round, and gets there.
    func testEasingTakesTheShortWayAndArrives() {
        let from: CGFloat = .pi * 0.95
        let to: CGFloat = -.pi * 0.95
        let step = LoupePlacement.ease(from: from, to: to, fraction: 0.5)
        XCTAssertGreaterThan(step, from, "went the long way round")
        var a = from
        for _ in 0..<40 { a = LoupePlacement.ease(from: a, to: to, fraction: 0.35) }
        XCTAssertEqual(cos(a), cos(to), accuracy: 1e-3)
        XCTAssertEqual(sin(a), sin(to), accuracy: 1e-3)
    }
}
