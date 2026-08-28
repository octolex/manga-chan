//
//  Stroke.swift
//
//  Turns input samples into ribbon triangles.
//
//  This is placeholder geometry, and knowing that matters: M3 replaces it with
//  arc-length resampling and dab stamping, which is what actually gives
//  Procreate-class texture. Ribbons are here because they are ~40 lines and
//  let us prove the input path is correct before the brush engine exists.
//
//  Joins are deliberately not mitred. At 240Hz the Pencil delivers samples so
//  closely spaced that the angle between consecutive segments is tiny, so the
//  notches a naive ribbon would show on a sharp corner do not appear in
//  practice. If you ever see them, that is a signal that input samples are
//  being dropped somewhere.
//

import CoreGraphics
import Foundation
import simd

struct StrokePoint {
    var location: CGPoint      // view coordinates, in points
    var pressure: Float        // 0...1
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

enum StrokeGeometry {

    /// Width in points at full pressure.
    static let baseWidth: Float = 14.0

    /// Fraction of the base width a zero-pressure sample still draws, so a
    /// light touch tapers rather than vanishing.
    static let minWidthFraction: Float = 0.15

    static func halfWidth(for pressure: Float) -> Float {
        let t = max(0, min(1, pressure))
        return baseWidth * (minWidthFraction + (1 - minWidthFraction) * t) * 0.5
    }

    /// Converts view-space points into clip space (-1...1, y up).
    private static func toClip(_ p: CGPoint, viewSize: CGSize) -> simd_float2 {
        simd_float2(Float(p.x / viewSize.width) * 2 - 1,
                    1 - Float(p.y / viewSize.height) * 2)
    }

    /// Builds a triangle list. Geometry is computed in view space so that the
    /// ribbon keeps a constant width — doing it in clip space would stretch
    /// the stroke along whichever screen axis is longer.
    static func ribbon(points: [StrokePoint],
                       viewSize: CGSize,
                       color: simd_float4) -> [MSStrokeVertex] {

        guard points.count >= 2, viewSize.width > 0, viewSize.height > 0 else { return [] }

        var out: [MSStrokeVertex] = []
        out.reserveCapacity((points.count - 1) * 6)

        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]

            let dx = Float(b.location.x - a.location.x)
            let dy = Float(b.location.y - a.location.y)
            let length = sqrt(dx * dx + dy * dy)

            // Skip duplicate samples — normalising a zero-length vector would
            // produce NaNs and silently corrupt the whole vertex buffer.
            guard length > 0.0001 else { continue }

            let nx = -dy / length
            let ny = dx / length

            let ha = halfWidth(for: a.pressure)
            let hb = halfWidth(for: b.pressure)

            let a0 = CGPoint(x: a.location.x + CGFloat(nx * ha), y: a.location.y + CGFloat(ny * ha))
            let a1 = CGPoint(x: a.location.x - CGFloat(nx * ha), y: a.location.y - CGFloat(ny * ha))
            let b0 = CGPoint(x: b.location.x + CGFloat(nx * hb), y: b.location.y + CGFloat(ny * hb))
            let b1 = CGPoint(x: b.location.x - CGFloat(nx * hb), y: b.location.y - CGFloat(ny * hb))

            func vertex(_ p: CGPoint, _ edge: Float) -> MSStrokeVertex {
                MSStrokeVertex(position: toClip(p, viewSize: viewSize),
                               edge: edge,
                               color: color)
            }

            out.append(vertex(a0,  1))
            out.append(vertex(a1, -1))
            out.append(vertex(b0,  1))

            out.append(vertex(b0,  1))
            out.append(vertex(a1, -1))
            out.append(vertex(b1, -1))
        }

        return out
    }
}
