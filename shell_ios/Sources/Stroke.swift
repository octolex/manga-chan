//
//  Stroke.swift
//
//  Input types only.
//
//  The geometry that used to live here — resampling, ribbon quads, tile
//  capture — moved into core/stroke.cpp at M3. It is pure arithmetic over
//  plain numbers, and every bug that has reached the device so far lived in
//  this shell where the test suite cannot see it. What remains is the shape of
//  a hardware sample and the HUD readout of one.
//

import CoreGraphics
import Foundation

/// One input sample, carrying every channel the hardware can report.
///
/// Every channel is forwarded to the engine whether or not the current brush
/// consumes it. Which ones matter is the brush's business, not the shell's —
/// a brush keyed to tilt should start working when it is authored, not when
/// somebody remembers to widen a struct here.
struct StrokePoint {
    var location: CGPoint      // view coordinates, in points
    var pressure: Float        // 0...1

    /// Angle from the screen plane, in radians. π/2 is upright, 0 is flat.
    var tilt: Float = .pi / 2

    /// Direction the barrel points, in radians.
    var azimuth: Float = 0

    /// Barrel rotation, in radians. Negative means the hardware cannot
    /// report it — a Pencil Pro can, earlier models cannot, and a brush that
    /// keys off roll needs to know the difference rather than reading zero.
    var roll: Float = -1

    var timestamp: TimeInterval
}

/// Live readout of every input channel the Pencil exposes.
///
/// This exists to answer one question quickly: is each channel actually
/// arriving, or is it silently reading zero? Without a debugger on the device,
/// a value on screen is the only way to tell "tilt is flat" from "tilt is not
/// being delivered at all".
struct InputStats {
    var touchType: String = "—"
    var pressure: Float = 0
    var altitudeDegrees: Float = 0   // 90° = perpendicular to the screen
    var azimuthDegrees: Float = 0    // direction the pencil points, 0...360
    var rollDegrees: Float = -1      // barrel roll; -1 means unsupported
    var hoverOffset: Float = -1      // distance above the glass; -1 means not hovering
    var squeezeCount: Int = 0
    var doubleTapCount: Int = 0
    var peakSamplesPerFrame: Int = 0
}

