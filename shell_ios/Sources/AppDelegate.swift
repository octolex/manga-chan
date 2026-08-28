//
//  AppDelegate.swift
//
//  Deliberately using the pre-scene UIKit lifecycle. M0 is a single full-screen
//  canvas with no multi-window story, and fewer moving parts means fewer ways
//  for the pipeline proof to fail for reasons unrelated to the pipeline.
//  Scene support arrives when multi-window editing does.
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // First thing, before anything that could plausibly crash.
        Diagnostics.bootstrap()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = CanvasViewController()
        window.makeKeyAndVisible()
        self.window = window

        Diagnostics.log("launch complete")
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Diagnostics.log("terminating")
        Diagnostics.flush()
    }
}
