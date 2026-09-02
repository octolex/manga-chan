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

    /// Both buttons in one column, so a panel can hang below the *toolbar*
    /// rather than below whichever button opened it.
    ///
    /// That distinction is the whole bug this replaced: the layers panel was
    /// anchored under the layers button, which put it exactly where the brush
    /// button sits, and the button drew on top of the panel's own header —
    /// covering "add layer" and making the panel untestable. Anchoring to the
    /// stack means a third button can never reintroduce it.
    private let toolbar = UIStackView()
    private let brushPanel = BrushPanelView()

    override func loadView() {
        view = metalView
        view.backgroundColor = .white
        view.isMultipleTouchEnabled = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            hud.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
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
            hud.addStaticLine("2f undo · 3f redo · 4f clear layer")
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

        // Procreate's conventions, because they are the ones already in the
        // user's fingers: two-finger tap undoes, three-finger tap redoes.
        addTapGesture(touches: 2, action: #selector(handleUndo))
        addTapGesture(touches: 3, action: #selector(handleRedo))
        addTapGesture(touches: 4, action: #selector(handleClear))

        setUpToolbar()
        setUpLayersPanel()
        setUpBrushPanel()

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

    private func addTapGesture(touches: Int, action: Selector) {
        let gesture = UITapGestureRecognizer(target: self, action: action)
        gesture.numberOfTouchesRequired = touches
        view.addGestureRecognizer(gesture)
    }

    @objc private func handleUndo() {
        _ = renderer?.undo()
    }

    @objc private func handleRedo() {
        _ = renderer?.redo()
    }

    @objc private func handleClear() {
        renderer?.clearActiveLayer()
    }

    // MARK: - Toolbar

    private func setUpToolbar() {
        for button in [layersButton, brushButton] {
            button.tintColor = .white
            button.backgroundColor = UIColor(white: 0.13, alpha: 0.9)
            button.layer.cornerRadius = 10
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        }
        layersButton.setImage(UIImage(systemName: "square.3.layers.3d"), for: .normal)
        layersButton.addTarget(self, action: #selector(toggleLayersPanel), for: .touchUpInside)
        brushButton.setImage(UIImage(systemName: "paintbrush.pointed"), for: .normal)
        brushButton.addTarget(self, action: #selector(toggleBrushPanel), for: .touchUpInside)

        toolbar.axis = .vertical
        toolbar.spacing = 10
        toolbar.alignment = .trailing
        toolbar.addArrangedSubview(layersButton)
        toolbar.addArrangedSubview(brushButton)

        view.addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                         constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                              constant: -12),
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
            layersPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                                  constant: -12),
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
            brushPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                                 constant: -12),
            brushPanel.widthAnchor.constraint(equalToConstant: 330),
            brushPanel.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor,
                                               multiplier: 0.75),
        ])
    }

    @objc private func toggleBrushPanel() {
        brushPanel.isHidden.toggle()
        if !brushPanel.isHidden, let renderer {
            // Only one panel at a time: together they cover most of the canvas,
            // and the point of both is to see their effect on it.
            layersPanel.isHidden = true
            let ink = renderer.inkColor
            brushPanel.sync(brush: renderer.brush,
                            color: UIColor(red: CGFloat(ink.x), green: CGFloat(ink.y),
                                           blue: CGFloat(ink.z), alpha: 1))
        }
    }

    @objc private func toggleLayersPanel() {
        layersPanel.isHidden.toggle()
        if !layersPanel.isHidden, let renderer {
            brushPanel.isHidden = true
            layersPanel.reload(from: renderer.canvas)
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
                           timestamp: touch.timestamp)
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        if let active = activeTouch {
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

        // Chrome sits above the canvas, so a touch that lands on it is not a
        // stroke — even for the Pencil, which would otherwise draw straight
        // through the panel.
        let point = touch.location(in: view)
        if !layersPanel.isHidden, layersPanel.frame.contains(point) { return }
        if !brushPanel.isHidden, brushPanel.frame.contains(point) { return }
        // The toolbar's frame, not the buttons'. Their frames are relative to
        // the stack view now, so testing them against a point in `view` would
        // silently compare two different coordinate spaces — and the Pencil
        // would draw straight through the buttons. Testing the stack also
        // covers the gap between them, which used to be a live canvas.
        if toolbar.frame.contains(point) { return }

        // Several fingers already on the glass is a gesture, not drawing.
        if touch.type != .pencil, (event?.allTouches?.count ?? 1) > 1 {
            return
        }

        activeTouch = touch
        strokeSeed &+= 1
        let path = BrushStroke(brush: renderer?.brush ?? mc_brush_ink_pen(),
                               pixelScale: pixelScale,
                               seed: strokeSeed)
        path.append([strokePoint(from: touch)])
        stroke = path
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

        // coalescedTouches carries every sample the digitiser captured since
        // the last event, not just the newest one. Using active.location alone
        // would discard most of a fast stroke.
        let coalesced = event?.coalescedTouches(for: active) ?? [active]
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

    private func cancelStroke() {
        activeTouch = nil
        stroke = nil
        renderer?.abortStroke()
    }

    private func finishStroke(_ touch: UITouch, event: UIEvent?) {
        defer {
            activeTouch = nil
            stroke = nil
        }
        guard let stroke else { return }

        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        stroke.append(coalesced.map(strokePoint(from:)))
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
