//
//  CanvasViewController.swift
//
//  Hosts the Metal layer, the HUD, and the touch pipeline.
//
//  The input handling is the substance here. Apple Pencil samples at ~240Hz
//  while this panel refreshes at 60Hz, so UIKit hands us roughly four
//  coalesced samples per frame. Using only `touch.location` would discard
//  three quarters of the stroke and produce visibly faceted curves at speed.
//
//  Note the failure handling: if the renderer cannot start, the reason is
//  painted onto the screen in large text. On a device we cannot attach a
//  debugger to, a black screen tells us nothing and an on-screen error tells
//  us everything.
//
//  **Gestures follow Procreate's, because they are already in the user's
//  fingers** (2026-11-06). Two-finger tap undoes and three-finger tap redoes;
//  holding either repeats it. A three-finger scrub clears the layer. A
//  four-finger tap hides the interface. Touch and hold picks a colour. Draw
//  and hold snaps the stroke to a shape. Until that date a four-finger tap
//  *cleared the layer* here — the gesture a Procreate user makes to hide the
//  interface, which turned their muscle memory into deleting work.
//

import UIKit
import Metal
import simd

final class MetalLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

final class CanvasViewController: UIViewController {

    private let metalView = MetalLayerView()
    private let hud = HUDView()
    private var renderer: Renderer?

    /// The touch currently drawing. Any other concurrent touch is ignored, so
    /// a resting palm cannot start a second stroke.
    private var activeTouch: UITouch?

    /// Accumulates the stroke in progress. Nil when nothing is being drawn.
    private var stroke: BrushStroke?

    /// Seeds the jitter for the next stroke. Incremented rather than taken
    /// from the clock so a session replays identically, and so that two
    /// strokes in a row never land on the same random sequence.
    private var strokeSeed: UInt64 = 1

    private var inputStats = InputStats()
    private let layersPanel = LayersPanelView()
    private let layersButton = UIButton(type: .system)
    private let brushButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let swapSideButton = UIButton(type: .system)

    /// Which edge the whole control chrome lives on — toolbar, quick bar and
    /// every panel together, not just the sliders.
    ///
    /// **The rule this encodes:** the controls belong on the side of the hand
    /// that is *not* holding the pen. That came off the device: built on the
    /// right as asked for, a right-handed artist's palm rests over them, which
    /// is the reason Procreate defaults to the left and not a style choice.
    ///
    /// So leading is the default and the swap is a necessity rather than a
    /// nicety — a left-handed artist has the mirror-image problem, exactly as
    /// badly. It persists, because being asked every launch would be worse
    /// than being wrong once.
    private var controlSide: BrushQuickBar.Edge = .leading {
        didSet { applyControlSide() }
    }

    private static let controlSideKey = "controlSideIsTrailing"

    /// The two constraint sets, both built once and toggled. Rebuilding
    /// constraints on a swap is how a layout ends up with two of them fighting;
    /// activating one set and deactivating the other cannot drift.
    private var leadingSideConstraints: [NSLayoutConstraint] = []
    private var trailingSideConstraints: [NSLayoutConstraint] = []

    /// Every button in one column, so a panel can hang below the *toolbar*
    /// rather than below whichever button opened it.
    ///
    /// That distinction is the whole bug this replaced: the layers panel was
    /// anchored under the layers button, which put it exactly where the brush
    /// button sits, and the button drew on top of the panel's own header —
    /// covering "add layer" and making the panel untestable. Anchoring to the
    /// stack means a further button can never reintroduce it.
    private let toolbar = UIStackView()

    /// Size and Opacity, always visible on the canvas edge. See BrushQuickBar
    /// for why those two and not others, and for the note on handedness.
    private let quickBar = BrushQuickBar()
    private let brushPanel = BrushPanelView()

    /// Procreate's Preferences → Pressure and Smoothing. Belongs to the person,
    /// not the brush, so it is in the toolbar rather than in the brush panel.
    private let pressurePanel = PressureSmoothingPanel()
    private var inputSettings = PressureSmoothingSettings.load()

    // MARK: Full screen

    /// Four-finger tap, as in Procreate: every piece of chrome slides away and
    /// one small button stays to bring it back.
    private var isFullScreen = false
    private let restoreButton = UIButton(type: .system)

    // MARK: QuickShape

    /// How long the pen must rest at the end of a stroke before it snaps.
    /// **Our guess, not a measurement** — Procreate lets the delay be set and
    /// its default has not been read off a device.
    private static let quickShapeDelay: TimeInterval = 0.6

    /// How far, in points, the pen may drift and still be holding. A Pencil
    /// held "still" wanders by a fraction of a point at 240 Hz.
    private static let quickShapeHoldTolerance: CGFloat = 4

    private var quickShapeTimer: Timer?
    private var holdAnchor: CGPoint = .zero
    /// The fitted shape once the stroke has snapped; nil before then.
    private var snappedShape: MCQuickShape?
    private var shapeConstrained = false
    private let toast = CanvasToast()

    // MARK: Gestures

    private var undoTap: UITapGestureRecognizer?
    private var redoTap: UITapGestureRecognizer?
    private var rapidHistoryTimer: Timer?
    private let eyedropperLoupe = EyedropperLoupe()
    private var eyedropperGesture: UILongPressGestureRecognizer?

    /// Procreate's Rapid Undo Delay. **Our guess, not a measurement**, like
    /// the QuickShape delay; Procreate's default has not been read off a device.
    private static let rapidHistoryDelay: TimeInterval = 0.65
    private static let rapidHistoryInterval: TimeInterval = 0.1

    /// Procreate's touch-and-hold delay for the eyedropper. Also our guess.
    private static let eyedropperDelay: TimeInterval = 0.5

    // MARK: Estimated force

    /// Pencil force UIKit marked as an estimate, keyed by the touch's
    /// `estimationUpdateIndex`, so the real value can be compared with it when
    /// it arrives. Instrumentation only, for now — see
    /// `touchesEstimatedPropertiesUpdated`.
    private var forceEstimates: [Int: Float] = [:]

    override func loadView() {
        view = metalView
        view.backgroundColor = .white
        view.isMultipleTouchEnabled = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        // Pinned to the top only here. Which *side* it takes is decided with
        // the controls: the HUD goes to whichever edge they are not on, or it
        // would sit under the quick bar the moment the controls moved left.
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])

        // Run the engine self-test before touching Metal. If the C++ core did
        // not link correctly, we want to know that here and not from a
        // confusing failure three layers deeper.
        let selfTest = core_self_test()
        Diagnostics.log("core_self_test() -> \(selfTest)")
        hud.addStaticLine(selfTest == 0 ? "core self-test: ok" : "core self-test: FAILED (\(selfTest))")

        do {
            let renderer = try Renderer(layer: metalView.metalLayer)
            renderer.onStats = { [weak self] stats in
                self?.hud.update(with: stats)
            }
            self.renderer = renderer
            hud.addStaticLine(MTLCreateSystemDefaultDevice()?.name ?? "unknown GPU")
            hud.addStaticLine("2f undo · 3f redo · hold repeats")
            hud.addStaticLine("3f scrub clear · 4f full screen")
            renderer.onLayersChanged = { [weak self] in
                guard let self else { return }
                self.layersPanel.reload(from: renderer.canvas)
            }
        } catch {
            let message = (error as? RendererError)?.description ?? String(describing: error)
            Diagnostics.log("RENDERER INIT FAILED: \(message)")
            Diagnostics.flush()
            showFatal(message)
        }

        setUpGestures()
        setUpToolbar()
        setUpLayersPanel()
        setUpBrushPanel()
        setUpPressurePanel()
        setUpOverlays()
        // Last, because the sets span every one of the above and some are
        // anchored to the quick bar rather than to the view.
        buildSideConstraints()

        // Squeeze (Pencil Pro) and double-tap (Pencil 2 and later). Both are
        // only wired to counters for now — the point is to confirm they arrive
        // before we decide what they should do.
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)

        // Hover requires an M-series iPad and a Pencil that supports it.
        let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        view.addGestureRecognizer(hoverGesture)

        registerLifecycleObservers()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalView.metalLayer.contentsScale = scale
        renderer?.resize(to: CGSize(width: view.bounds.width * scale,
                                    height: view.bounds.height * scale))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Query the panel rather than assuming: iPad Air is 60Hz, iPad Pro is
        // 120Hz, and a hardcoded value is wrong on one of them.
        let maxFPS = view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
        hud.addStaticLine("panel max \(maxFPS) Hz")
        renderer?.start(maxFramesPerSecond: maxFPS)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        renderer?.stop()
    }

    // MARK: - Gestures

    /// Every canvas gesture is fingers only. A Pencil resting on the glass
    /// while a finger taps must not turn a one-finger tap into a two-finger
    /// undo; before 2026-11-06 the recognisers counted Pencil touches too.
    private static let fingersOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

    private func setUpGestures() {
        // Procreate's conventions, because they are the ones already in the
        // user's fingers.
        let undoTap = tap(touches: 2, action: #selector(handleUndo))
        let redoTap = tap(touches: 3, action: #selector(handleRedo))
        tap(touches: 4, action: #selector(toggleFullScreen))
        self.undoTap = undoTap
        self.redoTap = redoTap

        // Hold two or three fingers: undo or redo repeatedly, after a delay.
        let holdUndo = hold(touches: 2, delay: Self.rapidHistoryDelay,
                            action: #selector(handleRapidUndo(_:)))
        let holdRedo = hold(touches: 3, delay: Self.rapidHistoryDelay,
                            action: #selector(handleRapidRedo(_:)))
        // A tap waits for the hold to fail — which it does the instant the
        // fingers lift short of the delay, so a tap costs no visible latency,
        // and a hold can never also fire the tap it began as.
        undoTap.require(toFail: holdUndo)
        redoTap.require(toFail: holdRedo)

        // Three fingers brushed back and forth: clear the layer.
        let scrub = ScrubGestureRecognizer(target: self, action: #selector(handleScrub(_:)))
        scrub.allowedTouchTypes = Self.fingersOnly
        view.addGestureRecognizer(scrub)
        redoTap.require(toFail: scrub)

        // Touch and hold with one finger: the eyedropper.
        let eyedropper = hold(touches: 1, delay: Self.eyedropperDelay,
                              action: #selector(handleEyedropper(_:)))
        eyedropper.delegate = self
        eyedropperGesture = eyedropper
    }

    @discardableResult
    private func tap(touches: Int, action: Selector) -> UITapGestureRecognizer {
        let gesture = UITapGestureRecognizer(target: self, action: action)
        gesture.numberOfTouchesRequired = touches
        gesture.allowedTouchTypes = Self.fingersOnly
        view.addGestureRecognizer(gesture)
        return gesture
    }

    private func hold(touches: Int, delay: TimeInterval,
                      action: Selector) -> UILongPressGestureRecognizer {
        let gesture = UILongPressGestureRecognizer(target: self, action: action)
        gesture.numberOfTouchesRequired = touches
        gesture.minimumPressDuration = delay
        gesture.allowedTouchTypes = Self.fingersOnly
        view.addGestureRecognizer(gesture)
        return gesture
    }

    @objc private func handleUndo() {
        _ = renderer?.undo()
    }

    @objc private func handleRedo() {
        _ = renderer?.redo()
    }

    @objc private func handleRapidUndo(_ gesture: UILongPressGestureRecognizer) {
        repeatWhileHeld(gesture) { [weak self] in self?.renderer?.undo() ?? false }
    }

    @objc private func handleRapidRedo(_ gesture: UILongPressGestureRecognizer) {
        repeatWhileHeld(gesture) { [weak self] in self?.renderer?.redo() ?? false }
    }

    /// Steps once when the hold is recognised, then every interval until the
    /// fingers lift or there is nothing left to step through.
    private func repeatWhileHeld(_ gesture: UILongPressGestureRecognizer,
                                 step: @escaping () -> Bool) {
        switch gesture.state {
        case .began:
            rapidHistoryTimer?.invalidate()
            guard step() else { return }
            rapidHistoryTimer = Timer.scheduledTimer(withTimeInterval: Self.rapidHistoryInterval,
                                                     repeats: true) { [weak self] timer in
                if !step() {
                    timer.invalidate()
                    self?.rapidHistoryTimer = nil
                }
            }
        case .ended, .cancelled, .failed:
            rapidHistoryTimer?.invalidate()
            rapidHistoryTimer = nil
        default:
            break
        }
    }

    @objc private func handleScrub(_ gesture: ScrubGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else { return }
        if gesture.track(gesture.translation(in: view).x) {
            renderer?.clearActiveLayer()
            toast.show("Layer cleared")
        }
    }

    // MARK: Eyedropper

    @objc private func handleEyedropper(_ gesture: UILongPressGestureRecognizer) {
        guard let renderer else { return }
        let point = gesture.location(in: view)
        let scale = pixelScale
        let sampled = renderer.compositeColor(atPixelX: Int((point.x * scale).rounded(.down)),
                                              y: Int((point.y * scale).rounded(.down)))
        let pickedColor = UIColor(red: CGFloat(sampled.x), green: CGFloat(sampled.y),
                                  blue: CGFloat(sampled.z), alpha: 1)
        switch gesture.state {
        case .began, .changed:
            let ink = renderer.inkColor
            eyedropperLoupe.show(at: point, within: view.bounds.inset(by: view.safeAreaInsets),
                                 picked: pickedColor,
                                 current: UIColor(red: CGFloat(ink.x), green: CGFloat(ink.y),
                                                  blue: CGFloat(ink.z), alpha: 1))
        case .ended:
            eyedropperLoupe.hide()
            renderer.setInkRGB(sampled)
            if !brushPanel.isHidden {
                brushPanel.sync(brush: renderer.brush, color: pickedColor)
            }
        default:
            eyedropperLoupe.hide()
        }
    }

    // MARK: Full screen

    @objc private func toggleFullScreen() {
        isFullScreen.toggle()
        if isFullScreen {
            layersPanel.isHidden = true
            brushPanel.isHidden = true
            pressurePanel.isHidden = true
        }
        let chrome: [UIView] = [toolbar, quickBar, hud]
        UIView.animate(withDuration: 0.2) {
            for view in chrome { view.alpha = self.isFullScreen ? 0 : 1 }
            self.restoreButton.alpha = self.isFullScreen ? 1 : 0
        }
        for view in chrome { view.isUserInteractionEnabled = !isFullScreen }
        restoreButton.isUserInteractionEnabled = isFullScreen
    }

    // MARK: - Toolbar

    private func setUpToolbar() {
        for button in [layersButton, brushButton, settingsButton, swapSideButton] {
            styleChromeButton(button)
        }
        layersButton.setImage(UIImage(systemName: "square.3.layers.3d"), for: .normal)
        layersButton.addTarget(self, action: #selector(toggleLayersPanel), for: .touchUpInside)
        brushButton.setImage(UIImage(systemName: "paintbrush.pointed"), for: .normal)
        brushButton.addTarget(self, action: #selector(toggleBrushPanel), for: .touchUpInside)
        settingsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settingsButton.addTarget(self, action: #selector(togglePressurePanel), for: .touchUpInside)
        settingsButton.accessibilityLabel = "Pressure and Smoothing"
        // A button rather than a gesture, because handedness is not something
        // to discover. It is in the toolbar and not in the brush panel because
        // it is a property of the person, not of the brush.
        swapSideButton.setImage(UIImage(systemName: "arrow.left.arrow.right"), for: .normal)
        swapSideButton.addTarget(self, action: #selector(swapControlSide), for: .touchUpInside)
        swapSideButton.accessibilityLabel = "Move controls to the other side"

        toolbar.axis = .vertical
        toolbar.spacing = 10
        toolbar.addArrangedSubview(layersButton)
        toolbar.addArrangedSubview(brushButton)
        toolbar.addArrangedSubview(settingsButton)
        toolbar.addArrangedSubview(swapSideButton)

        view.addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                         constant: 12),
        ])

        setUpQuickBar()
    }

    private func styleChromeButton(_ button: UIButton) {
        button.tintColor = .white
        button.backgroundColor = UIColor(white: 0.13, alpha: 0.9)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    }

    // MARK: - Handedness

    @objc private func swapControlSide() {
        controlSide = (controlSide == .leading) ? .trailing : .leading
        UserDefaults.standard.set(controlSide == .trailing,
                                  forKey: Self.controlSideKey)
    }

    /// Build both constraint sets once, then let `applyControlSide` pick one.
    ///
    /// Called after every control exists, because each set spans every piece
    /// of chrome and the panels are anchored to the quick bar rather than to
    /// the view.
    private func buildSideConstraints() {
        let guide = view.safeAreaLayoutGuide
        let inset: CGFloat = 12
        let gap: CGFloat = 10

        leadingSideConstraints = [
            toolbar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset),
            quickBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: gap),
            layersPanel.leadingAnchor.constraint(equalTo: quickBar.trailingAnchor, constant: gap),
            brushPanel.leadingAnchor.constraint(equalTo: quickBar.trailingAnchor, constant: gap),
            pressurePanel.leadingAnchor.constraint(equalTo: quickBar.trailingAnchor, constant: gap),
            restoreButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset),
            hud.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset),
        ]
        trailingSideConstraints = [
            toolbar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset),
            quickBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -gap),
            layersPanel.trailingAnchor.constraint(equalTo: quickBar.leadingAnchor, constant: -gap),
            brushPanel.trailingAnchor.constraint(equalTo: quickBar.leadingAnchor, constant: -gap),
            pressurePanel.trailingAnchor.constraint(equalTo: quickBar.leadingAnchor, constant: -gap),
            restoreButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset),
            hud.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset),
        ]

        controlSide = UserDefaults.standard.bool(forKey: Self.controlSideKey)
            ? .trailing : .leading
    }

    private func applyControlSide() {
        let onLeading = controlSide == .leading
        // Deactivate first, always. Both sets active for even one layout pass
        // is an unsatisfiable constraint and a console full of breakage.
        NSLayoutConstraint.deactivate(onLeading ? trailingSideConstraints
                                                : leadingSideConstraints)
        NSLayoutConstraint.activate(onLeading ? leadingSideConstraints
                                              : trailingSideConstraints)

        toolbar.alignment = onLeading ? .leading : .trailing
        // Points at where the controls would go, not at where they are, so the
        // button says what tapping it does.
        swapSideButton.setImage(
            UIImage(systemName: onLeading ? "arrow.right.to.line" : "arrow.left.to.line"),
            for: .normal)
    }

    /// The quick bar takes one edge and the panels open inboard of it rather
    /// than on top. Both fit side by side on an iPad: the panel is 330 points
    /// and the bar about 60. Which edge is `controlSide`'s to say.
    private func setUpQuickBar() {
        quickBar.delegate = self
        view.addSubview(quickBar)
        quickBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Centred rather than hung from the toolbar: these are reached for
            // mid-stroke, and the middle of the edge is where the hand already
            // is.
            quickBar.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Layers panel

    private func setUpLayersPanel() {
        layersPanel.delegate = self
        layersPanel.isHidden = true

        view.addSubview(layersPanel)
        layersPanel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            layersPanel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            // The side it opens toward is in buildSideConstraints, inboard of
            // the quick bar either way.
            layersPanel.widthAnchor.constraint(equalToConstant: 330),
            // Capped rather than pinned to the bottom: a long stack scrolls
            // inside the panel instead of the panel swallowing the canvas.
            layersPanel.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor,
                                                multiplier: 0.7),
        ])
    }

    // MARK: - Brush panel

    private func setUpBrushPanel() {
        brushPanel.delegate = self
        brushPanel.isHidden = true

        view.addSubview(brushPanel)
        brushPanel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Below the whole toolbar, exactly as the layers panel is. Only one
            // panel is ever visible, so they can share the position.
            brushPanel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            // As the layers panel: the side is buildSideConstraints' to set.
            brushPanel.widthAnchor.constraint(equalToConstant: 330),
            brushPanel.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor,
                                               multiplier: 0.75),
        ])
    }

    // MARK: - Pressure and Smoothing panel

    private func setUpPressurePanel() {
        pressurePanel.isHidden = true
        pressurePanel.sync(inputSettings)
        pressurePanel.onChange = { [weak self] settings in
            guard let self else { return }
            // Takes effect on the next stroke: the filters are fixed when a
            // stroke begins, so one cannot kink part-way through.
            inputSettings = settings
            settings.save()
        }

        view.addSubview(pressurePanel)
        pressurePanel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pressurePanel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            pressurePanel.widthAnchor.constraint(equalToConstant: 330),
            // Capped, and it scrolls inside: the curve is square, and on an
            // 11-inch iPad in landscape the whole panel would not fit.
            pressurePanel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                  constant: -12),
        ])
    }

    // MARK: - Overlays

    private func setUpOverlays() {
        styleChromeButton(restoreButton)
        restoreButton.setImage(UIImage(systemName: "arrow.down.right.and.arrow.up.left"),
                               for: .normal)
        restoreButton.accessibilityLabel = "Show the interface"
        restoreButton.addTarget(self, action: #selector(toggleFullScreen), for: .touchUpInside)
        restoreButton.alpha = 0
        restoreButton.isUserInteractionEnabled = false
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(restoreButton)

        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)

        view.addSubview(eyedropperLoupe)

        NSLayoutConstraint.activate([
            restoreButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                               constant: 12),
            toast.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    /// Only one panel at a time: together they cover most of the canvas, and
    /// the point of each is to see its effect on it.
    private func showOnly(_ panel: UIView?) {
        for candidate in [layersPanel, brushPanel, pressurePanel] as [UIView] where candidate !== panel {
            candidate.isHidden = true
        }
    }

    @objc private func toggleBrushPanel() {
        brushPanel.isHidden.toggle()
        if !brushPanel.isHidden, let renderer {
            showOnly(brushPanel)
            let ink = renderer.inkColor
            brushPanel.sync(brush: renderer.brush,
                            color: UIColor(red: CGFloat(ink.x), green: CGFloat(ink.y),
                                           blue: CGFloat(ink.z), alpha: 1))
        }
    }

    @objc private func toggleLayersPanel() {
        layersPanel.isHidden.toggle()
        if !layersPanel.isHidden, let renderer {
            showOnly(layersPanel)
            layersPanel.reload(from: renderer.canvas)
        }
    }

    @objc private func togglePressurePanel() {
        pressurePanel.isHidden.toggle()
        if !pressurePanel.isHidden {
            showOnly(pressurePanel)
            pressurePanel.sync(inputSettings)
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            inputStats.hoverOffset = Float(gesture.zOffset)
        default:
            inputStats.hoverOffset = -1
        }
        hud.update(input: inputStats)
    }

    // MARK: - Touch handling

    private func strokePoint(from touch: UITouch) -> StrokePoint {
        let pressure: Float
        if touch.type == .pencil, touch.maximumPossibleForce > 0 {
            pressure = Float(touch.force / touch.maximumPossibleForce)
        } else {
            // Fingers report no usable force on iPad, so draw at a constant
            // mid weight rather than a stroke that tapers to nothing.
            pressure = 0.5
        }
        var roll: Float = -1
        if #available(iOS 17.5, *), touch.type == .pencil {
            roll = Float(touch.rollAngle)
        }

        return StrokePoint(location: touch.location(in: view),
                           pressure: pressure,
                           tilt: Float(touch.altitudeAngle),
                           azimuth: Float(touch.azimuthAngle(in: view)),
                           roll: roll,
                           timestamp: touch.timestamp,
                           fromPressureDevice: touch.type == .pencil)
    }

    /// Mirrors every Pencil channel into the HUD. Reading a live value on
    /// screen is the only way, without a debugger, to tell a channel that is
    /// genuinely flat from one that is not being delivered at all.
    private func recordInput(from touch: UITouch, samplesThisEvent: Int) {
        switch touch.type {
        case .pencil: inputStats.touchType = "pencil"
        case .direct: inputStats.touchType = "finger"
        default:      inputStats.touchType = "other"
        }

        if touch.maximumPossibleForce > 0 {
            inputStats.pressure = Float(touch.force / touch.maximumPossibleForce)
        } else {
            inputStats.pressure = 0
        }

        // altitudeAngle is 0 when the pencil lies flat and π/2 when upright.
        inputStats.altitudeDegrees = Float(touch.altitudeAngle * 180 / .pi)

        var azimuth = Float(touch.azimuthAngle(in: view) * 180 / .pi)
        if azimuth < 0 { azimuth += 360 }
        inputStats.azimuthDegrees = azimuth

        // Barrel roll is Apple Pencil Pro only, and needs iOS 17.5.
        if #available(iOS 17.5, *), touch.type == .pencil {
            var roll = Float(touch.rollAngle * 180 / .pi)
            if roll < 0 { roll += 360 }
            inputStats.rollDegrees = roll
        }

        inputStats.peakSamplesPerFrame = max(inputStats.peakSamplesPerFrame, samplesThisEvent)
        hud.update(input: inputStats)
    }

    /// True when a point in `view` lands on visible chrome. Chrome sits above
    /// the canvas, so a touch there is not a stroke — even for the Pencil,
    /// which would otherwise draw straight through a panel.
    private func isOnChrome(_ point: CGPoint) -> Bool {
        for panel in [layersPanel, brushPanel, pressurePanel] as [UIView]
            where !panel.isHidden && panel.frame.contains(point) {
            return true
        }
        if isFullScreen {
            return restoreButton.frame.contains(point)
        }
        // The toolbar's frame, not the buttons'. Their frames are relative to
        // the stack view, so testing them against a point in `view` would
        // silently compare two different coordinate spaces — and the Pencil
        // would draw straight through the buttons. Testing the stack also
        // covers the gap between them, which used to be a live canvas.
        if toolbar.frame.contains(point) { return true }
        // Always visible outside full screen, and unlike the buttons its frame
        // is already in `view` coordinates.
        return quickBar.frame.contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        if let active = activeTouch {
            // A finger landing while a Pencil holds a snapped shape constrains
            // it, as in Procreate: the line to 15° steps, the ellipse to a
            // circle.
            if active.type == .pencil, snappedShape != nil,
               touches.contains(where: { $0.type == .direct }) {
                constrainSnappedShape()
                return
            }
            // A Pencil stroke ignores extra contacts — that is palm rejection.
            // A second finger, though, means the user is starting a gesture, so
            // the finger stroke in progress must be discarded rather than
            // committed: committing it adds an undo step for a stray dot and,
            // far worse, clears the redo stack.
            if active.type != .pencil {
                cancelStroke()
            }
            return
        }

        // Prefer the Pencil if both are down, so a resting hand never wins.
        let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first
        guard let touch else { return }

        if isOnChrome(touch.location(in: view)) { return }

        // Several fingers already on the glass is a gesture, not drawing.
        if touch.type != .pencil, (event?.allTouches?.count ?? 1) > 1 {
            return
        }

        activeTouch = touch
        strokeSeed &+= 1
        let path = BrushStroke(brush: renderer?.brush ?? mc_brush_ink_pen(),
                               pixelScale: pixelScale,
                               seed: strokeSeed,
                               input: inputSettings.engineSettings)
        noteForceEstimates([touch])
        path.append([strokePoint(from: touch)])
        stroke = path
        snappedShape = nil
        shapeConstrained = false
        holdAnchor = touch.location(in: view)
        scheduleQuickShape()
    }

    /// Points to pixels. Touches arrive in view points; the engine and the dab
    /// shader both work in canvas pixels.
    private var pixelScale: CGFloat {
        view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let active = activeTouch, touches.contains(active),
              let stroke else { return }

        let location = active.location(in: view)

        // After a snap, the pen no longer draws: a line's end follows it, and
        // every other shape stays put until the pen lifts.
        if snappedShape != nil {
            moveSnappedLineEnd(to: location)
            return
        }

        // Still moving means not holding: the QuickShape clock starts over.
        let dx = location.x - holdAnchor.x, dy = location.y - holdAnchor.y
        let drift = (dx * dx + dy * dy).squareRoot()
        if drift > Self.quickShapeHoldTolerance {
            holdAnchor = location
            scheduleQuickShape()
        }

        // coalescedTouches carries every sample the digitiser captured since
        // the last event, not just the newest one. Using active.location alone
        // would discard most of a fast stroke.
        let coalesced = event?.coalescedTouches(for: active) ?? [active]
        noteForceEstimates(coalesced)
        stroke.append(coalesced.map(strokePoint(from:)))
        renderer?.setStroke(stroke, sampleCount: coalesced.count)
        recordInput(from: active, samplesThisEvent: coalesced.count)

        // Predictions extend from the newest real sample. They are drawn but
        // never committed — see the note in Renderer.
        let predicted = event?.predictedTouches(for: active) ?? []
        if let seed = stroke.lastPoint, !predicted.isEmpty {
            renderer?.setPrediction(
                BrushStroke.prediction(brush: renderer?.brush ?? mc_brush_ink_pen(),
                                       pixelScale: pixelScale,
                                       input: inputSettings.engineSettings,
                                       from: seed,
                                       through: predicted.map(strokePoint(from:))))
        } else {
            renderer?.setPrediction(nil)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let active = activeTouch, touches.contains(active) else { return }
        finishStroke(active, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let active = activeTouch, touches.contains(active) else { return }
        // UIKit cancels touches once a gesture recognises. Committing a
        // cancelled stroke is what turned every undo tap into a new undo step.
        cancelStroke()
    }

    /// Pencil force arrives as an estimate and is corrected up to ~50 ms later
    /// (Apple: "Handling input from Apple Pencil"). The stroke engine is
    /// append-only, so a correction cannot reach dabs already drawn; before
    /// building a way to revise them, this measures how often the estimate is
    /// used and how far off it is. Shown in the HUD and logged per stroke.
    private func noteForceEstimates(_ touches: [UITouch]) {
        for touch in touches where touch.type == .pencil
            && touch.estimatedPropertiesExpectingUpdates.contains(.force) {
            guard let index = touch.estimationUpdateIndex?.intValue,
                  touch.maximumPossibleForce > 0 else { continue }
            forceEstimates[index] = Float(touch.force / touch.maximumPossibleForce)
            inputStats.forceEstimated += 1
        }
        // Bounded: an update that never comes must not grow this forever.
        if forceEstimates.count > 4096 { forceEstimates.removeAll(keepingCapacity: true) }
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let index = touch.estimationUpdateIndex?.intValue,
                  let estimate = forceEstimates[index],
                  !touch.estimatedPropertiesExpectingUpdates.contains(.force),
                  touch.maximumPossibleForce > 0 else { continue }
            forceEstimates[index] = nil
            let actual = Float(touch.force / touch.maximumPossibleForce)
            inputStats.forceCorrected += 1
            inputStats.forceMaxError = max(inputStats.forceMaxError, abs(actual - estimate))
        }
        hud.update(input: inputStats)
    }

    private func cancelStroke() {
        quickShapeTimer?.invalidate()
        quickShapeTimer = nil
        snappedShape = nil
        activeTouch = nil
        stroke = nil
        renderer?.abortStroke()
    }

    private func finishStroke(_ touch: UITouch, event: UIEvent?) {
        quickShapeTimer?.invalidate()
        quickShapeTimer = nil
        let wasSnapped = snappedShape != nil
        defer {
            activeTouch = nil
            stroke = nil
            snappedShape = nil
        }
        guard let stroke else { return }

        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        // A snapped shape is already exact. The lift's own samples would add a
        // stub of freehand line to the end of it.
        if !wasSnapped {
            noteForceEstimates(coalesced)
            stroke.append(coalesced.map(strokePoint(from:)))
        }
        // Flush the trailing segments that were still waiting on a lookahead
        // sample which will now never arrive, and apply the end taper.
        stroke.finish()

        let tiles = stroke.touchedTiles
        // A stroke that put nothing down must not be committed: it would
        // record an undo step for nothing and discard the redo branch.
        guard !stroke.isEmpty, !tiles.isEmpty else {
            renderer?.abortStroke()
            return
        }

        renderer?.setStroke(stroke, sampleCount: coalesced.count)
        // Dropping the prediction here matters: leaving it up would commit a
        // stub of line extending past where the stroke actually stopped.
        renderer?.setPrediction(nil)
        renderer?.endStroke(tiles: tiles)

        if inputStats.forceEstimated > 0 {
            Diagnostics.log("force estimates: \(inputStats.forceEstimated) estimated, "
                            + "\(inputStats.forceCorrected) corrected, max error "
                            + String(format: "%.3f", inputStats.forceMaxError))
        }
    }

    // MARK: - QuickShape

    private func scheduleQuickShape() {
        quickShapeTimer?.invalidate()
        quickShapeTimer = Timer.scheduledTimer(withTimeInterval: Self.quickShapeDelay,
                                               repeats: false) { [weak self] _ in
            self?.snapToShape()
        }
    }

    /// The pen has rested long enough: fit a shape to the stroke so far, and
    /// if one fits, replace the stroke with it.
    private func snapToShape() {
        quickShapeTimer = nil
        guard activeTouch != nil, snappedShape == nil,
              let stroke, let shape = stroke.detectShape() else { return }
        snappedShape = shape
        replaceStroke(with: shape)
        toast.show(Self.name(of: shape, constrained: false))
    }

    private func constrainSnappedShape() {
        guard var shape = snappedShape, !shapeConstrained else { return }
        mc_quickshape_constrain(&shape)
        shapeConstrained = true
        snappedShape = shape
        replaceStroke(with: shape)
        toast.show(Self.name(of: shape, constrained: true))
    }

    private func moveSnappedLineEnd(to location: CGPoint) {
        guard var shape = snappedShape, shape.kind == Int32(MC_SHAPE_LINE.rawValue) else { return }
        let scale = pixelScale
        mc_quickshape_move_end(&shape, Float(location.x * scale), Float(location.y * scale),
                               shapeConstrained ? 1 : 0)
        snappedShape = shape
        replaceStroke(with: shape)
    }

    /// Swaps the stroke in progress for one drawing `shape`. The renderer sees
    /// a different stroke object and restamps its coverage from nothing, so
    /// the freehand line underneath disappears in the same frame.
    private func replaceStroke(with shape: MCQuickShape) {
        guard let current = stroke else { return }
        strokeSeed &+= 1
        let replacement = current.replacing(with: shape, seed: strokeSeed,
                                            timestamp: current.lastPoint?.timestamp ?? 0)
        stroke = replacement
        renderer?.setPrediction(nil)
        renderer?.setStroke(replacement, sampleCount: 0)
    }

    private static func name(of shape: MCQuickShape, constrained: Bool) -> String {
        switch shape.kind {
        case Int32(MC_SHAPE_LINE.rawValue): return constrained ? "Line, 15°" : "Line"
        case Int32(MC_SHAPE_ARC.rawValue): return "Arc"
        case Int32(MC_SHAPE_ELLIPSE.rawValue): return constrained ? "Circle" : "Ellipse"
        case Int32(MC_SHAPE_POLYLINE.rawValue): return shape.closed != 0 ? "Polygon" : "Polyline"
        default: return "Shape"
        }
    }

    // MARK: - Lifecycle

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        // A stroke lifted in the frame before backgrounding must not wait for
        // a frame that will not come until the app returns.
        renderer?.flushPendingCommit()
        // Presenting a drawable while backgrounded is a reliable way to get
        // the app killed by the OS.
        renderer?.stop()
        Diagnostics.flush()
    }

    @objc private func appWillEnterForeground() {
        let maxFPS = view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
        renderer?.start(maxFramesPerSecond: maxFPS)
    }

    // MARK: - Failure display

    private func showFatal(_ message: String) {
        let label = UILabel()
        label.text = "Renderer failed to start\n\n\(message)\n\nSee session.log in the Files app."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1.0)
        label.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
        ])
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

// MARK: - Gesture arbitration

extension CanvasViewController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === eyedropperGesture else { return true }
        // Never while a Pencil draws — a resting palm would pick a colour
        // mid-stroke — and only for a single finger, not the start of a
        // two-finger hold.
        if activeTouch?.type == .pencil { return false }
        if gestureRecognizer.numberOfTouches != 1 { return false }
        return !isOnChrome(gestureRecognizer.location(in: view))
    }
}

// MARK: - Layers panel

extension CanvasViewController: LayersPanelDelegate {

    func layersPanelDidRequestAdd(_ panel: LayersPanelView) {
        renderer?.addLayer()
    }

    func layersPanel(_ panel: LayersPanelView, didSelect layer: MCLayerId) {
        renderer?.selectLayer(layer)
    }

    func layersPanel(_ panel: LayersPanelView, didRequestDelete layer: MCLayerId) {
        renderer?.removeLayer(layer)
    }

    func layersPanel(_ panel: LayersPanelView, didUpdate properties: LayerProperties,
                     for layer: MCLayerId) {
        renderer?.setProperties(properties, of: layer)
    }
}

extension CanvasViewController: BrushPanelDelegate {

    func brushPanel(_ panel: BrushPanelView, didChange brush: MCBrush) {
        // Takes effect on the next stroke. A brush is copied into the stroke
        // when it begins, so a slider moved mid-stroke cannot retroactively
        // change ink already laid down.
        renderer?.brush = brush
        // Size and Opacity exist in two places now, and they are one value.
        // Pushing rather than observing, because the bar must not send the
        // change back and start a loop.
        quickBar.size = brush.size
        quickBar.opacity = brush.opacity
    }

    func brushPanel(_ panel: BrushPanelView, didChangeColor color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        renderer?.setInkRGB(simd_float3(Float(r), Float(g), Float(b)))
    }
}

// MARK: - Pencil squeeze and double-tap

extension CanvasViewController: UIPencilInteractionDelegate {

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        inputStats.squeezeCount += 1
        Diagnostics.log("pencil squeeze (\(inputStats.squeezeCount))")
        hud.update(input: inputStats)
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        inputStats.doubleTapCount += 1
        Diagnostics.log("pencil double-tap (\(inputStats.doubleTapCount))")
        hud.update(input: inputStats)
    }
}


// MARK: - Always-visible size and opacity

extension CanvasViewController: BrushQuickBarDelegate {

    func quickBar(_ bar: BrushQuickBar, didChangeSize size: Float) {
        guard var brush = renderer?.brush else { return }
        brush.size = size
        renderer?.brush = brush
        // The panel may be open on the same two values; keep them agreeing.
        brushPanel.refreshFromBrush(brush)
    }

    func quickBar(_ bar: BrushQuickBar, didChangeOpacity opacity: Float) {
        guard var brush = renderer?.brush else { return }
        brush.opacity = opacity
        renderer?.brush = brush
        brushPanel.refreshFromBrush(brush)
    }
}
