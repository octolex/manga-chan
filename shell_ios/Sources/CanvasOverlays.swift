//
//  CanvasOverlays.swift
//
//  The small things drawn over the canvas for Procreate's gestures: the
//  eyedropper's loupe, the QuickShape notice, and the three-finger scrub
//  recogniser. Kept apart from the view controller, which is already the
//  largest file in the shell — and the shell is where every device bug so far
//  has lived.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The ring the eyedropper shows while held: the colour under the finger in
/// the top half, the current colour in the bottom, as Procreate does, so the
/// pick can be judged against what it replaces before letting go.
final class EyedropperLoupe: UIView {

    private let picked = CAShapeLayer()
    private let current = CAShapeLayer()
    private let diameter: CGFloat = 96
    private let ring: CGFloat = 18

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        isUserInteractionEnabled = false
        isHidden = true
        for half in [picked, current] {
            half.fillColor = nil
            half.lineWidth = ring
            layer.addSublayer(half)
        }
        // A thin dark and light outline, so the ring reads on any canvas.
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.5, alpha: 0.8).cgColor
        layer.cornerRadius = diameter / 2
    }

    required init?(coder: NSCoder) {
        fatalError("EyedropperLoupe is created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = (diameter - ring) / 2
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        picked.path = UIBezierPath(arcCenter: centre, radius: radius,
                                   startAngle: .pi, endAngle: 0, clockwise: true).cgPath
        current.path = UIBezierPath(arcCenter: centre, radius: radius,
                                    startAngle: 0, endAngle: .pi, clockwise: true).cgPath
    }

    /// Fingertip clearance: the ring's centre stays this far from the finger,
    /// whichever side it is on, so the fingertip can never cover it.
    private let distance: CGFloat = 88

    /// The angle the ring currently sits at around the finger. Nil while
    /// hidden, so the next appearance starts where it fits instead of gliding
    /// in from wherever the last pick left it.
    private var angle: CGFloat?

    /// - Parameter bounds: where the ring may go, in the superview's
    ///   coordinates — the visible canvas less its safe-area insets.
    func show(at point: CGPoint, within bounds: CGRect,
              picked pickedColor: UIColor, current currentColor: UIColor) {
        let radius = diameter / 2
        let target = LoupePlacement.angle(finger: point, bounds: bounds,
                                          radius: radius, distance: distance)
        let eased = angle.map { LoupePlacement.ease(from: $0, to: target, fraction: 0.35) }
            ?? target
        angle = eased

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picked.strokeColor = pickedColor.cgColor
        current.strokeColor = currentColor.cgColor
        let centre = LoupePlacement.center(finger: point, angle: eased, distance: distance)
        center = LoupePlacement.clamped(centre, bounds: bounds, radius: radius)
        isHidden = false
        CATransaction.commit()
    }

    func hide() {
        isHidden = true
        angle = nil
    }
}

/// A short notice at the top of the canvas — "Ellipse", "Line, 15°" — that
/// fades on its own. Procreate names the shape QuickShape made; without it a
/// snap is easy to mistake for the stroke jumping.
final class CanvasToast: UILabel {

    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 15, weight: .semibold)
        textColor = .white
        textAlignment = .center
        backgroundColor = UIColor(white: 0.13, alpha: 0.9)
        layer.cornerRadius = 10
        layer.masksToBounds = true
        isUserInteractionEnabled = false
        alpha = 0
    }

    required init?(coder: NSCoder) {
        fatalError("CanvasToast is created in code")
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 28, height: size.height + 14)
    }

    func show(_ message: String) {
        text = message
        hideWork?.cancel()
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}

/// Three fingers brushed back and forth: Procreate's Clear Layer.
///
/// A pan that counts reversals along x. It fires once, on the second
/// reversal — across, back, and across again — and then ignores the rest of
/// the gesture, so an enthusiastic scrub cannot clear twice and lose an undo
/// step to an empty clear.
final class ScrubGestureRecognizer: UIPanGestureRecognizer {

    /// How far the fingers must travel the other way for it to count as a
    /// reversal rather than jitter, in points.
    var reversalDistance: CGFloat = 30

    /// Reversals needed: two is across, back, across.
    var reversalsRequired = 2

    private(set) var didScrub = false
    private var extreme: CGFloat = 0
    private var direction: CGFloat = 0
    private var reversals = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        minimumNumberOfTouches = 3
        maximumNumberOfTouches = 3
    }

    override func reset() {
        super.reset()
        didScrub = false
        extreme = 0
        direction = 0
        reversals = 0
    }

    /// Feed the gesture's translation; returns true exactly once, when the
    /// scrub completes.
    func track(_ x: CGFloat) -> Bool {
        guard !didScrub else { return false }
        if direction == 0 {
            if abs(x - extreme) > reversalDistance { direction = x > extreme ? 1 : -1; extreme = x }
            return false
        }
        if (x - extreme) * direction > 0 {
            extreme = x   // still going the same way
        } else if abs(x - extreme) > reversalDistance {
            reversals += 1
            direction = -direction
            extreme = x
            if reversals >= reversalsRequired {
                didScrub = true
                return true
            }
        }
        return false
    }
}
