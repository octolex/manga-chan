//
//  AppVersionTests.swift
//
//  The version readout is the only thing on the device that says which build
//  is running, and the two rules it encodes are the two that fail silently:
//  a marketing version that never got overridden, and a build number that
//  drifted away from it. Both look completely normal on screen unless the
//  readout is written to say so.
//

import Foundation
import XCTest

final class AppVersionTests: XCTestCase {

    func testAConsistentCIBuildReadsPlainly() {
        XCTAssertEqual(AppVersion.describe(marketing: "0.3.76", build: "76"),
                       "0.3.76 (76)")
    }

    func testASeriesBumpIsStillConsistent() {
        // 0.3.99 is followed by 0.4.100: the build number is global and never
        // resets across a series bump, so the last component still matches.
        XCTAssertEqual(AppVersion.describe(marketing: "0.4.100", build: "100"),
                       "0.4.100 (100)")
    }

    func testAnUnoverriddenVersionSaysSoRatherThanLookingReal() {
        // project.yml pins 0.0.1 for local builds. Internally consistent with a
        // build of 1, which is exactly why it needs naming: a version that
        // looks valid and means nothing is worse than an obvious placeholder.
        let text = AppVersion.describe(marketing: "0.0.1", build: "1")
        XCTAssertTrue(text.contains("local"),
                      "an un-overridden version must not read as a real one: \(text)")
    }

    func testADriftingBuildNumberIsCalledOut() {
        // The failure this exists for: MARKETING_VERSION lands but
        // CURRENT_PROJECT_VERSION does not, because the override is passed on
        // the xcodebuild command line where a renamed setting fails quietly.
        // The app then reports 0.3.77 while the bundle says build 1.
        let text = AppVersion.describe(marketing: "0.3.77", build: "1")
        XCTAssertTrue(text.contains("MISMATCH"),
                      "a build number that left its version behind must be visible: \(text)")
    }

    func testTheRunningBundleAgreesWithItself() {
        // Against the real Info.plist rather than a literal, so the key names
        // are checked too — a renamed key would return "?" here and pass every
        // test above.
        //
        // Weaker than it looks, and worth saying so: `xcodebuild test` does not
        // receive the version overrides, so under CI this bundle reports the
        // 0.0.1 placeholder and takes the local-build branch. The assertion
        // that a *shipped* build carries the right version lives in the
        // workflow, which reads both keys back out of the built app.
        let text = AppVersion.short
        XCTAssertFalse(text.contains("MISMATCH"),
                       "this bundle's version and build disagree: \(text)")
        XCTAssertFalse(text.contains("?"),
                       "Info.plist keys did not resolve: \(text)")
    }
}
