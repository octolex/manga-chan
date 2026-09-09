//
//  PrecisionSlider.swift
//
//  The app's only slider. Horizontal or vertical, finger-sized, and scrubbing
//  slows down as the finger moves away from the track — see SliderScrubbing,
//  which holds all the arithmetic and all the tests.
//
//  It replaces UISlider rather than wrapping it. UISlider gives no way to
//  intercept its tracking and rewrite the value: `beginTracking` is overridable
//  but the thumb has already been placed by then, so the value would fight the
//  drag rather than follow it. It also cannot draw vertically without a
//  transform, and a rotated control has rotated hit-testing, which is exactly
//  the class of bug this project keeps finding in the Swift shell.
//
//  Drawn in layers rather than images so a size change is a property write.
//

import UIKit

/// `ScrollDragImmune` is not decoration here, and not a precaution against a
/// UIKit default that happens to be favourable today.
///
/// The whole feature is dragging *perpendicular* to the track. Inside a
/// vertically scrolling panel that is exactly what a scroll looks like, so a
/// scroll view that decided to claim the gesture would cancel the touch
/// mid-drag and silently remove precision scrubbing — leaving a slider that
/// works, feels normal, and simply never gets fine. That is bug 8 in
/// TESTING.md, which cost a device round: a UIScrollView cancelling content
/// touches on a control whose drag *is* the interaction.
///
/// UIScrollView's documented default already exempts UIControl subclasses, so
/// this is belt and braces. It is worth the one line because the failure is
/// invisible and the default is not ours to rely on.
final class PrecisionSlider: UIControl, ScrollDragImmune {

    enum Axis {
        case horizontal
        /// Minimum at the bottom, which is how a vertical slider is read even
        /// though the y axis runs the other way.
        case vertical
    }

    // MARK: - Value

    /// Clamped to `range`. Setting it never sends an action — actions come
    /// from the user, not from code, or a panel rebuild would look like a
    /// hundred edits.
    var value: Float {
        get { _value }
        set { setValue(newValue, notify: false) }
    }

    var range: ClosedRange<Float> = 0...1 {
        didSet { setValue(_value, notify: false) }
    }

    /// How the drag slows as the finger leaves the track.
    var scrubbing = SliderScrubbing()

    /// Called continuously while dragging, and once at the end. `isFinal` lets
    /// a caller commit expensive work only when the finger lifts.
    var onChange: ((Float, _ isFinal: Bool) -> Void)?

    /// Live rate multiplier, for a caller that wants to show "1/4" while the
    /// finger is out — so the slowdown reads as deliberate rather than as the
    /// app struggling.
    private(set) var currentGain: CGFloat = 1

    private var _value: Float = 0

    // MARK: - Appearance

    var trackColor: UIColor = UIColor.white.withAlphaComponent(0.18) { didSet { restyle() } }
    var fillColor: UIColor = UIColor.white.withAlphaComponent(0.85) { didSet { restyle() } }
    var thumbColor: UIColor = .white { didSet { restyle() } }

    private let axis: Axis
    private let trackThickness: CGFloat
    private let thumbDiameter: CGFloat

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let thumbLayer = CALayer()

    private var drag: SliderDrag?

    // MARK: - Init

    /// The track is drawn thin and the *touch* area is generous. Drawing a
    /// fat bar to make a control finger-friendly wastes screen and still misses
    /// the finger; widening the hit area costs nothing and always works.
    init(axis: Axis, trackThickness: CGFloat = 6, thumbDiameter: CGFloat = 28) {
        self.axis = axis
        self.trackThickness = trackThickness
        self.thumbDiameter = thumbDiameter
        super.init(frame: .zero)

        // The layers are decoration; the control does its own hit-testing over
        // the whole bounds, so a finger never has to find the thumb.
        for layer in [trackLayer, fillLayer, thumbLayer] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(),
                             "backgroundColor": NSNull(), "cornerRadius": NSNull()]
            self.layer.addSublayer(layer)
        }
        thumbLayer.shadowColor = UIColor.black.cgColor
        thumbLayer.shadowOpacity = 0.35
        thumbLayer.shadowRadius = 3
        thumbLayer.shadowOffset = CGSize(width: 0, height: 1)
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("PrecisionSlider is created in code")
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        switch axis {
        case .horizontal: return CGSize(width: UIView.noIntrinsicMetric, height: max(trackThickness, thumbDiameter) + 8)
        case .vertical:   return CGSize(width: max(trackThickness, thumbDiameter) + 8, height: UIView.noIntrinsicMetric)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers()
    }

    /// Distance the thumb can travel, in points.
    private var trackLength: CGFloat {
        let span = (axis == .horizontal) ? bounds.width : bounds.height
        return max(span - thumbDiameter, 1)
    }

    private var normalised: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((_value - range.lowerBound) / span)
    }

    private func layoutLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radius = trackThickness / 2
        let travel = trackLength * normalised

        switch axis {
        case .horizontal:
            let y = bounds.midY - trackThickness / 2
            trackLayer.frame = CGRect(x: 0, y: y, width: bounds.width, height: trackThickness)
            fillLayer.frame = CGRect(x: 0, y: y,
                                     width: travel + thumbDiameter / 2, height: trackThickness)
            thumbLayer.frame = CGRect(x: travel, y: bounds.midY - thumbDiameter / 2,
                                      width: thumbDiameter, height: thumbDiameter)
        case .vertical:
            // Minimum at the bottom: travel grows upward, so it is measured
            // down from the bottom edge rather than from the origin.
            let x = bounds.midX - trackThickness / 2
            let thumbY = bounds.height - thumbDiameter - travel
            trackLayer.frame = CGRect(x: x, y: 0, width: trackThickness, height: bounds.height)
            fillLayer.frame = CGRect(x: x, y: thumbY,
                                     width: trackThickness,
                                     height: bounds.height - thumbY)
            thumbLayer.frame = CGRect(x: bounds.midX - thumbDiameter / 2, y: thumbY,
                                      width: thumbDiameter, height: thumbDiameter)
        }
        trackLayer.cornerRadius = radius
        fillLayer.cornerRadius = radius
        thumbLayer.cornerRadius = thumbDiameter / 2
    }

    private func restyle() {
        trackLayer.backgroundColor = trackColor.cgColor
        fillLayer.backgroundColor = fillColor.cgColor
        thumbLayer.backgroundColor = thumbColor.cgColor
    }

    // MARK: - Value plumbing

    private func setValue(_ new: Float, notify: Bool, isFinal: Bool = false) {
        let clamped = min(max(new, range.lowerBound), range.upperBound)
        let changed = clamped != _value
        _value = clamped
        layoutLayers()
        if notify && (changed || isFinal) {
            onChange?(_value, isFinal)
            sendActions(for: .valueChanged)
        }
    }

    private func value(forPosition position: CGFloat) -> Float {
        range.lowerBound + Float(position) * (range.upperBound - range.lowerBound)
    }

    // MARK: - Tracking

    /// Coordinates in the control's own frame, resolved per axis so the model
    /// never learns which way the slider runs.
    private func components(of point: CGPoint) -> (along: CGFloat, perpendicular: CGFloat) {
        switch axis {
        case .horizontal:
            return (point.x, point.y - bounds.midY)
        case .vertical:
            // Negated: dragging *up* must raise the value.
            return (-point.y, point.x - bounds.midX)
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        let parts = components(of: point)

        // Deliberately no jump-to-tap. A slider that leaps to wherever it is
        // touched is unusable at the sizes this one is meant for: the first
        // contact of a drag would throw the value across the range before the
        // finger had moved at all. Tapping does nothing; dragging adjusts.
        drag = SliderDrag(startingAt: normalised,
                          alongTrack: parts.along,
                          trackLength: trackLength,
                          scrubbing: scrubbing)
        currentGain = 1
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard var active = drag else { return false }
        let parts = components(of: touch.location(in: self))
        let position = active.update(alongTrack: parts.along, perpendicular: parts.perpendicular)
        currentGain = active.currentGain
        drag = active
        setValue(value(forPosition: position), notify: true)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        finishTracking()
    }

    override func cancelTracking(with event: UIEvent?) {
        finishTracking()
    }

    private func finishTracking() {
        drag = nil
        currentGain = 1
        setValue(_value, notify: true, isFinal: true)
    }

    // MARK: - Hit testing

    /// The whole control is draggable, not just the thumb, and the touch area
    /// is widened past the drawn track so a finger does not have to be precise
    /// to start being precise.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let slop: CGFloat = 12
        return bounds.insetBy(dx: -slop, dy: -slop).contains(point)
    }
}
