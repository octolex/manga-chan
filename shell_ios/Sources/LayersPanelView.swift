//
//  LayersPanelView.swift
//
//  Follows the interaction model in docs/ui-layers-panel.md — the one already
//  in the user's fingers from Procreate — with our own visual identity.
//
//  One deliberate divergence: the blend control is a bordered button with a
//  pressed state and a disclosure caret, not a bare letter. Procreate's "N"
//  gives no indication that it is tappable, which the user flagged as poor UX
//  and is right about.
//
//  Rows display top layer first, the reverse of the engine's bottom-to-top
//  z-order. The view reverses; the model does not.
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
private final class RestorableScrollView: UIScrollView {

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

protocol LayersPanelDelegate: AnyObject {
    func layersPanelDidRequestAdd(_ panel: LayersPanelView)
    func layersPanel(_ panel: LayersPanelView, didSelect layer: MCLayerId)
    func layersPanel(_ panel: LayersPanelView, didRequestDelete layer: MCLayerId)
    func layersPanel(_ panel: LayersPanelView, didUpdate properties: LayerProperties,
                     for layer: MCLayerId)
}

final class LayersPanelView: UIView {

    weak var delegate: LayersPanelDelegate?

    private let header = UIView()
    private let titleLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private let scrollView = RestorableScrollView()
    private let stack = UIStackView()

    /// Which layer has its detail section open. Only one at a time: two open
    /// sections push the rest off-screen on an iPad in portrait.
    private var expandedLayer: MCLayerId = MC_INVALID_LAYER

    private var rows: [LayerRowView] = []

    /// Where the expanded row's blend list was scrolled to, carried across a
    /// rebuild so picking a mode does not jump the list back to the top.
    private var blendScrollOffset: CGFloat?

    // Geometry from the spec, in points.
    private enum Metrics {
        static let width: CGFloat = 330
        static let cornerRadius: CGFloat = 14
        static let headerHeight: CGFloat = 46
        static let rowHeight: CGFloat = 60
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Metrics.width, height: UIView.noIntrinsicMetric)
    }

    private func setup() {
        backgroundColor = UIColor(white: 0.13, alpha: 0.96)
        layer.cornerRadius = Metrics.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        titleLabel.text = "Layers"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white

        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.tintColor = .white
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        // A comfortable target: the visible glyph is small but the tappable
        // area should not be.
        addButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        header.addSubview(titleLabel)
        header.addSubview(addButton)
        addSubview(header)

        stack.axis = .vertical
        stack.spacing = 0
        scrollView.addSubview(stack)
        addSubview(scrollView)

        [header, titleLabel, addButton, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // A scroll view has no intrinsic content size, so without this the
        // panel has an upper bound and nothing pushing against it, and Auto
        // Layout settles on the header alone. Below the cap this makes the
        // panel exactly as tall as its rows; above it the cap wins and the
        // rows scroll.
        let contentHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        contentHeight.priority = .defaultHigh
        contentHeight.isActive = true
    }

    @objc private func addTapped() {
        delegate?.layersPanelDidRequestAdd(self)
    }

    // Swallow touches that land on the panel rather than letting them fall
    // through the responder chain to the canvas behind it.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    // MARK: - Population

    func reload(from engine: CanvasEngine) {
        scrollView.pendingOffset = scrollView.contentOffset.y

        // Read the scroll position off the outgoing row before it is torn down.
        for row in rows where row.blendScrollOffset != nil {
            blendScrollOffset = row.blendScrollOffset
        }

        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        let active = engine.activeLayer
        // Reversed: the panel shows the topmost layer first.
        for id in engine.layerIds.reversed() {
            guard let properties = engine.properties(of: id) else { continue }

            let row = LayerRowView(layer: id,
                                   properties: properties,
                                   isActive: id == active,
                                   isExpanded: id == expandedLayer,
                                   rowHeight: Metrics.rowHeight,
                                   initialBlendScroll: blendScrollOffset)
            row.onSelect = { [weak self] in
                guard let self else { return }
                self.delegate?.layersPanel(self, didSelect: id)
            }
            row.onToggleExpanded = { [weak self] in
                guard let self else { return }
                self.expandedLayer = (self.expandedLayer == id) ? MC_INVALID_LAYER : id
                // A freshly opened section should start at its current mode,
                // not wherever a previous one happened to be scrolled.
                self.blendScrollOffset = nil
                self.reload(from: engine)
            }
            row.onUpdate = { [weak self] updated, needsReload in
                guard let self else { return }
                self.delegate?.layersPanel(self, didUpdate: updated, for: id)
                if needsReload { self.reload(from: engine) }
            }
            row.onDelete = { [weak self] in
                guard let self else { return }
                self.delegate?.layersPanel(self, didRequestDelete: id)
            }

            stack.addArrangedSubview(row)
            rows.append(row)
        }

        // Background is not a layer in the engine: it is a clear colour the
        // compositor paints behind everything, which saves a whole blending
        // pass and tells export the page has an opaque ground.
        let background = BackgroundRowView(rowHeight: Metrics.rowHeight)
        stack.addArrangedSubview(background)
        rows.append(background)
    }
}

// MARK: - Rows

private class LayerRowView: UIView {

    var onSelect: (() -> Void)?
    var onToggleExpanded: (() -> Void)?
    /// The flag says whether the panel needs rebuilding afterwards.
    /// Continuous controls pass false: rebuilding mid-drag destroys the
    /// control being dragged, which ends the gesture after a single value.
    var onUpdate: ((LayerProperties, Bool) -> Void)?
    var onDelete: (() -> Void)?

    private var properties: LayerProperties
    private let layerId: MCLayerId

    private let thumbnail = UIView()
    private let nameLabel = UILabel()
    private let blendButton = UIButton(type: .system)
    private let visibilityButton = UIButton(type: .system)
    private let detail = UIStackView()

    init(layer: MCLayerId, properties: LayerProperties, isActive: Bool,
         isExpanded: Bool, rowHeight: CGFloat, initialBlendScroll: CGFloat? = nil) {
        self.layerId = layer
        self.properties = properties
        self.initialBlendScroll = initialBlendScroll
        super.init(frame: .zero)
        build(isActive: isActive, isExpanded: isExpanded, rowHeight: rowHeight)
    }

    /// Nil unless this row's blend list is on screen.
    var blendScrollOffset: CGFloat? { blendScrollView?.contentOffset.y }

    required init?(coder: NSCoder) { fatalError("not used") }

    fileprivate init(rowHeight: CGFloat) {
        self.layerId = MC_INVALID_LAYER
        self.properties = LayerProperties()
        super.init(frame: .zero)
    }

    private func build(isActive: Bool, isExpanded: Bool, rowHeight: CGFloat) {
        let content = UIView()
        content.backgroundColor = isActive ? UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)
                                           : .clear

        thumbnail.backgroundColor = UIColor(white: 0.92, alpha: 1)
        thumbnail.layer.cornerRadius = 3
        thumbnail.layer.borderWidth = 1
        thumbnail.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor

        nameLabel.text = properties.name
        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail

        // The divergence from Procreate: a control that looks like one.
        blendButton.setTitle(abbreviated(properties.blend) + " ▾", for: .normal)
        blendButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        blendButton.setTitleColor(.white, for: .normal)
        blendButton.layer.cornerRadius = 5
        blendButton.layer.borderWidth = 1
        blendButton.layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        blendButton.contentEdgeInsets = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
        blendButton.addTarget(self, action: #selector(blendTapped), for: .touchUpInside)
        blendButton.addTarget(self, action: #selector(blendPressed), for: .touchDown)
        blendButton.addTarget(self, action: #selector(blendReleased),
                              for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let visibilityName = properties.visible ? "checkmark.square.fill" : "square"
        visibilityButton.setImage(UIImage(systemName: visibilityName), for: .normal)
        visibilityButton.tintColor = .white
        visibilityButton.addTarget(self, action: #selector(visibilityTapped), for: .touchUpInside)

        [thumbnail, nameLabel, blendButton, visibilityButton].forEach {
            content.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let separator = UIView()
        separator.backgroundColor = UIColor(white: 1, alpha: 0.08)

        detail.axis = .vertical
        detail.spacing = 10
        detail.isLayoutMarginsRelativeArrangement = true
        detail.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 14, right: 16)
        detail.isHidden = !isExpanded
        if isExpanded { buildDetail() }

        let column = UIStackView(arrangedSubviews: [content, detail, separator])
        column.axis = .vertical
        addSubview(column)

        [column, separator].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            content.heightAnchor.constraint(equalToConstant: rowHeight),
            thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            thumbnail.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 78),
            thumbnail.heightAnchor.constraint(equalToConstant: 48),

            nameLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: blendButton.leadingAnchor,
                                                constant: -8),

            blendButton.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor,
                                                  constant: -10),
            blendButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            visibilityButton.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                       constant: -12),
            visibilityButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(rowTapped))
        content.addGestureRecognizer(tap)
    }

    private func buildDetail() {
        let opacityRow = UIStackView()
        opacityRow.axis = .horizontal
        opacityRow.spacing = 10

        let opacityLabel = UILabel()
        opacityLabel.text = "Opacity"
        opacityLabel.font = .systemFont(ofSize: 13)
        opacityLabel.textColor = UIColor(white: 1, alpha: 0.75)

        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = properties.opacity
        slider.addTarget(self, action: #selector(opacityChanged(_:)), for: .valueChanged)

        let percent = UILabel()
        percent.text = "\(Int(properties.opacity * 100))%"
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        percent.textColor = .white
        percent.widthAnchor.constraint(equalToConstant: 44).isActive = true
        percent.textAlignment = .right
        percentLabel = percent

        opacityRow.addArrangedSubview(opacityLabel)
        opacityRow.addArrangedSubview(slider)
        opacityRow.addArrangedSubview(percent)
        opacityRow.heightAnchor.constraint(equalToConstant: 32).isActive = true
        detail.addArrangedSubview(opacityRow)

        // Clip-to-below earns its place in the row rather than a submenu:
        // for manga it is used constantly, with flats and tones clipped to
        // the line art.
        let clip = UIButton(type: .system)
        clip.setTitle(properties.clipToBelow ? "✓ Clipping mask" : "Clipping mask", for: .normal)
        clip.titleLabel?.font = .systemFont(ofSize: 14)
        clip.contentHorizontalAlignment = .leading
        clip.setTitleColor(.white, for: .normal)
        clip.addTarget(self, action: #selector(clipTapped), for: .touchUpInside)
        clip.heightAnchor.constraint(equalToConstant: 34).isActive = true
        detail.addArrangedSubview(clip)

        // 26 modes stacked inline would make this section taller than the
        // screen, pushing Delete out of reach. Its own scroll view keeps the
        // section a fixed, predictable height.
        let modes = UIStackView()
        modes.axis = .vertical
        modes.spacing = 0
        for mode in 0..<Int(mc_blend_mode_count()) {
            let button = UIButton(type: .system)
            let name = String(cString: mc_blend_mode_name(Int32(mode)))
            button.setTitle(name, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14)
            button.contentHorizontalAlignment = .leading
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
            let selected = Int(properties.blend) == mode
            button.setTitleColor(selected ? .white : UIColor(white: 1, alpha: 0.7), for: .normal)
            button.backgroundColor = selected
                ? UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1) : .clear
            button.layer.cornerRadius = 4
            button.tag = mode
            button.addTarget(self, action: #selector(modeTapped(_:)), for: .touchUpInside)
            // Explicit height, or the stack compresses these when space runs
            // short and the rows overlap each other instead of scrolling.
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            modes.addArrangedSubview(button)
        }

        let modeScroll = RestorableScrollView()
        modeScroll.addSubview(modes)
        modes.translatesAutoresizingMaskIntoConstraints = false
        modeScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            modes.topAnchor.constraint(equalTo: modeScroll.topAnchor),
            modes.bottomAnchor.constraint(equalTo: modeScroll.bottomAnchor),
            modes.leadingAnchor.constraint(equalTo: modeScroll.leadingAnchor),
            modes.trailingAnchor.constraint(equalTo: modeScroll.trailingAnchor),
            modes.widthAnchor.constraint(equalTo: modeScroll.widthAnchor),
            modeScroll.heightAnchor.constraint(equalToConstant: 210),
        ])
        selectedModeIndex = Int(properties.blend)
        // Restore where the list was if we are being rebuilt; otherwise open on
        // the current mode, so the selection is visible without hunting for it.
        modeScroll.pendingOffset = initialBlendScroll ?? CGFloat(selectedModeIndex) * 30
        blendScrollView = modeScroll
        detail.addArrangedSubview(modeScroll)

        let delete = UIButton(type: .system)
        delete.setTitle("Delete layer", for: .normal)
        delete.titleLabel?.font = .systemFont(ofSize: 14)
        delete.contentHorizontalAlignment = .leading
        delete.setTitleColor(UIColor(red: 1, green: 0.45, blue: 0.45, alpha: 1), for: .normal)
        delete.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        delete.heightAnchor.constraint(equalToConstant: 34).isActive = true
        detail.addArrangedSubview(delete)
    }

    private weak var blendScrollView: RestorableScrollView?
    private var selectedModeIndex = 0
    private var initialBlendScroll: CGFloat?

    private weak var percentLabel: UILabel?

    private func abbreviated(_ blend: Int32) -> String {
        let name = String(cString: mc_blend_mode_name(blend))
        // Initials for multi-word modes, first two letters otherwise: "Normal"
        // becomes N, "Color Burn" becomes CB.
        let words = name.split(separator: " ")
        if words.count > 1 {
            return words.compactMap { $0.first }.map(String.init).joined()
        }
        return String(name.prefix(1))
    }

    // MARK: - Actions

    @objc private func rowTapped() { onSelect?() }
    @objc private func blendTapped() { onToggleExpanded?() }
    @objc private func blendPressed() { blendButton.alpha = 0.5 }
    @objc private func blendReleased() { blendButton.alpha = 1.0 }
    @objc private func deleteTapped() { onDelete?() }

    @objc private func visibilityTapped() {
        properties.visible.toggle()
        onUpdate?(properties, true)
    }

    @objc private func clipTapped() {
        properties.clipToBelow.toggle()
        onUpdate?(properties, true)
    }

    @objc private func opacityChanged(_ slider: UISlider) {
        properties.opacity = slider.value
        // Updated in place rather than by rebuilding: the slider has to
        // survive its own drag.
        percentLabel?.text = "\(Int(slider.value * 100))%"
        onUpdate?(properties, false)
    }

    @objc private func modeTapped(_ button: UIButton) {
        properties.blend = Int32(button.tag)
        onUpdate?(properties, true)
    }
}

/// The paper behind everything. Pinned, not reorderable, and not a layer in
/// the engine at all.
private final class BackgroundRowView: LayerRowView {

    override init(rowHeight: CGFloat) {
        super.init(rowHeight: rowHeight)

        let swatch = UIView()
        swatch.backgroundColor = .white
        swatch.layer.cornerRadius = 3

        let label = UILabel()
        label.text = "Background"
        label.font = .systemFont(ofSize: 15)
        label.textColor = UIColor(white: 1, alpha: 0.8)

        addSubview(swatch)
        addSubview(label)
        [swatch, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: rowHeight),
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 78),
            swatch.heightAnchor.constraint(equalToConstant: 48),
            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
