//
//  RestorableScrollView.swift
//
//  Shared by the layers panel and the brush panel, both of which rebuild
//  themselves and must not lose the reader's place when they do.
//

import UIKit

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

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let wanted = pendingOffset, contentSize.height > bounds.height else { return }
        pendingOffset = nil
        let limit = contentSize.height - bounds.height
        contentOffset = CGPoint(x: 0, y: max(0, min(wanted, limit)))
    }
}
