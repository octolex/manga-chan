//
//  AppVersion.swift
//
//  Which build is this.
//
//  Not cosmetic. A device round on 2026-09-02 came back with findings that
//  were actually from the *previous* build — identical prose and a
//  pixel-identical screenshot — and the only reason it was caught was that a
//  visual discriminator happened to exist between the two. There is one
//  device tester and no TestFlight build list to check against, so the build
//  has to say what it is on screen.
//
//  The string also carries the two consistency checks that `docs/versioning.md`
//  makes rules: the build number is the CI run number, and it is the last
//  component of the marketing version. If those ever disagree on a device, the
//  version override in CI has silently stopped landing, which is exactly the
//  failure that would otherwise show up as SideStore never offering an update.
//

import Foundation

enum AppVersion {

    /// What `project.yml` pins for a build made outside CI. A version of 0.0.1
    /// is therefore not a version at all, and saying so beats showing a number
    /// that looks real and means nothing.
    private static let placeholder = "0.0.1"

    /// e.g. "0.3.76" — CFBundleShortVersionString.
    static var marketing: String { string(for: "CFBundleShortVersionString") }

    /// e.g. "76" — CFBundleVersion, which is the CI run number.
    static var build: String { string(for: "CFBundleVersion") }

    /// The full readout, for the HUD and the crash-log header.
    static var short: String { describe(marketing: marketing, build: build) }

    /// Pure, so the formatting is testable without a bundle to read.
    static func describe(marketing: String, build: String) -> String {
        if marketing == placeholder {
            return "\(marketing) (\(build)) — local build, not from CI"
        }
        // Rule 1 of docs/versioning.md: one version, and the parts agree.
        let tail = marketing.split(separator: ".").last.map(String.init)
        if tail != build {
            return "\(marketing) (\(build)) — MISMATCH"
        }
        return "\(marketing) (\(build))"
    }

    private static func string(for key: String) -> String {
        (Bundle.main.infoDictionary?[key] as? String) ?? "?"
    }
}
