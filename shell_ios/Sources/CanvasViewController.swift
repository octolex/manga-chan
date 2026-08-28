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

    /// Last committed sample, kept so the next batch connects to it rather
    /// than starting a fresh disconnected segment each frame.
    private var lastCommittedPoint: StrokePoint?

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
            hud.addStaticLine("two-finger tap to clear")
        } catch {
            let message = (error as? RendererError)?.description ?? String(describing: error)
            Diagnostics.log("RENDERER INIT FAILED: \(message)")
            Diagnostics.flush()
            showFatal(message)
        }

        let clearGesture = UITapGestureRecognizer(target: self, action: #selector(clearCanvas))
        clearGesture.numberOfTouchesRequired = 2
        view.addGestureRecognizer(clearGesture)

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

    @objc private func clearCanvas() {
        renderer?.clearCanvas()
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
        return StrokePoint(location: touch.location(in: view),
                           pressure: pressure,
                           timestamp: touch.timestamp)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard activeTouch == nil else { return }

        // Prefer the Pencil if both are down, so a resting hand never wins.
        let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first
        guard let touch else { return }

        activeTouch = touch
        lastCommittedPoint = strokePoint(from: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let active = activeTouch, touches.contains(active) else { return }

        let coalesced = event?.coalescedTouches(for: active) ?? [active]
        var samples: [StrokePoint] = []
        if let last = lastCommittedPoint { samples.append(last) }
        samples.append(contentsOf: coalesced.map(strokePoint(from:)))

        let committed = StrokeGeometry.ribbon(points: samples,
                                              viewSize: view.bounds.size,
                                              color: renderer?.inkColor ?? .init(0, 0, 0, 1))
        renderer?.appendCommitted(committed, sampleCount: coalesced.count)
        lastCommittedPoint = samples.last

        // Predictions extend from the newest committed sample. They go only to
        // the drawable, never to the canvas — see the note in Renderer.
        let predicted = event?.predictedTouches(for: active) ?? []
        if predicted.isEmpty {
            renderer?.setPredicted([])
        } else {
            var lookahead: [StrokePoint] = []
            if let last = lastCommittedPoint { lookahead.append(last) }
            lookahead.append(contentsOf: predicted.map(strokePoint(from:)))
            renderer?.setPredicted(StrokeGeometry.ribbon(points: lookahead,
                                                         viewSize: view.bounds.size,
                                                         color: renderer?.inkColor ?? .init(0, 0, 0, 1)))
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
        finishStroke(active, event: event)
    }

    private func finishStroke(_ touch: UITouch, event: UIEvent?) {
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        var samples: [StrokePoint] = []
        if let last = lastCommittedPoint { samples.append(last) }
        samples.append(contentsOf: coalesced.map(strokePoint(from:)))

        let committed = StrokeGeometry.ribbon(points: samples,
                                              viewSize: view.bounds.size,
                                              color: renderer?.inkColor ?? .init(0, 0, 0, 1))
        renderer?.appendCommitted(committed, sampleCount: coalesced.count)

        // Drop the prediction immediately; leaving it up would show a stub of
        // line extending past where the stroke actually stopped.
        renderer?.setPredicted([])
        activeTouch = nil
        lastCommittedPoint = nil
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
