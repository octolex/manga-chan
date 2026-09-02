//
//  RestorableScrollView.swift
//
//  Shared by the layers panel and the brush panel, both of which rebuild
//  themselves and must not lose the reader's place when they do.
//

import UIKit

/// Marks a control whose drags *are* its purpose, so an enclosing scroll view
/// must never take one for a scroll.
///
/// A UIScrollView watches touches landing on its content and, the moment it
/// decides the finger is panning, cancels them and scrolls instead. That is
/// right for a list of rows and exactly wrong for a colour square, where the
/// drag is the entire interaction — the control would receive a touch, one
/// move, then `touchesCancelled`, so the colour ticked once and the panel
/// slid away under the finger.
protocol ScrollDragImmune: UIView {}

/// A scroll view that can be told where to sit before it knows how tall its
/// content is.
///
/// Auto Layout computes `contentSize` during this view's own layout pass, which
/// runs *after* its parent's. Restoring the offset from the enclosing row was
/// therefore reading a `contentSize` of zero and doing nothing — and a row deep
/// in a stack view may get exactly one layout pass, so there was no second
/// chance. Applying it here means the size is already real.
final class RestorableScrollView: UIScrollView {

    /// Cleared once applied, so the list stays where the user leaves it.
    var pendingOffset: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Without this a control waits out the scroll view's hold before it
        // sees anything, which reads as a dead first fraction of a second on
        // every slider and picker in the panel.
        delaysContentTouches = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delaysContentTouches = false
    }

    /// Refuses to steal a drag from a control that exists to be dragged.
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is ScrollDragImmune { return false }
        return super.touchesShouldCancel(in: view)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let wanted = pendingOffset, contentSize.height > bounds.height else { return }
        pendingOffset = nil
        let limit = contentSize.height - bounds.height
        contentOffset = CGPoint(x: 0, y: max(0, min(wanted, limit)))
    }
}
