//
//  CanvasViewController.swift
//
//  Hosts the Metal layer and the instrumentation HUD.
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

    override func loadView() {
        view = metalView
        view.backgroundColor = .black
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
        } catch {
            let message = (error as? RendererError)?.description ?? String(describing: error)
            Diagnostics.log("RENDERER INIT FAILED: \(message)")
            Diagnostics.flush()
            showFatal(message)
        }

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
        renderer?.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        renderer?.stop()
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
        renderer?.start()
    }

    // MARK: - Failure display

    private func showFatal(_ message: String) {
        let label = UILabel()
        label.text = "Renderer failed to start\n\n\(message)\n\nSee session.log in the Files app."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = UIColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
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
