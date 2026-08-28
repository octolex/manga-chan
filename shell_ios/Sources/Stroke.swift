//
//  Stroke.swift
//
//  Turns raw input samples into smooth ribbon geometry.
//
//  Two stages, both of which are stage 1 and 2 of the real brush pipeline:
//
//    1. Catmull-Rom interpolation through the samples, walked at a fixed
//       arc-length spacing. Raw samples are far too sparse to draw directly —
//       a finger emits ~60 samples/sec, so a fast stroke can put 30+ points
//       between consecutive samples. Drawing segment-per-sample produces
//       visible faceting on curves.
//
//    2. Ribbon quads between consecutive resampled points. Because the
//       resampled spacing is ~1pt, the angle between consecutive quads is
//       tiny and unmitred joins are invisible. The overlap between them is
//       what fills the corners — which only works because the renderer
//       accumulates coverage with a max operation rather than alpha-over.
//       Alpha-over would darken every overlap into a visible bead.
//
//  What this still is not: a brush engine. M3 replaces the ribbon with
//  textured dab stamping. The resampling and the max-coverage accumulation
//  below carry over unchanged.
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

enum StrokeStyle {
    /// Width in points at full pressure.
    static let baseWidth: Float = 14.0

    /// Fraction of the base width a zero-pressure sample still draws, so a
    /// light touch tapers rather than vanishing.
    static let minWidthFraction: Float = 0.15

    /// Arc-length gap between resampled points, in view points. Small enough
    /// that consecutive quads overlap and hide their own joins.
    static let resampleSpacing: CGFloat = 1.0

    static func halfWidth(for pressure: Float) -> Float {
        let t = max(0, min(1, pressure))
        return baseWidth * (minWidthFraction + (1 - minWidthFraction) * t) * 0.5
    }
}

enum StrokeGeometry {

    /// Straight quads between consecutive points, with no interpolation.
    ///
    /// Only for predicted touches. A prediction covers one or two frames and
    /// is discarded before it can be committed, so its faceting is never on
    /// screen long enough to see — and running it through the full resampler
    /// would spend real work on geometry that is about to be thrown away.
    static func simpleRibbon(points: [StrokePoint],
                             viewSize: CGSize,
                             color: simd_float4) -> [MSStrokeVertex] {
        guard points.count >= 2, viewSize.width > 0, viewSize.height > 0 else { return [] }

        func toClip(_ p: CGPoint) -> simd_float2 {
            simd_float2(Float(p.x / viewSize.width) * 2 - 1,
                        1 - Float(p.y / viewSize.height) * 2)
        }

        var out: [MSStrokeVertex] = []
        out.reserveCapacity((points.count - 1) * 6)

        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let dx = Float(b.location.x - a.location.x)
            let dy = Float(b.location.y - a.location.y)
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0.0001 else { continue }

            let nx = -dy / length, ny = dx / length
            let ha = StrokeStyle.halfWidth(for: a.pressure)
            let hb = StrokeStyle.halfWidth(for: b.pressure)

            func corner(_ p: CGPoint, _ side: Float, _ half: Float) -> MSStrokeVertex {
                MSStrokeVertex(position: toClip(CGPoint(x: p.x + CGFloat(nx * half * side),
                                                        y: p.y + CGFloat(ny * half * side))),
                               edge: side,
                               color: color)
            }

            let a0 = corner(a.location,  1, ha)
            let a1 = corner(a.location, -1, ha)
            let b0 = corner(b.location,  1, hb)
            let b1 = corner(b.location, -1, hb)
            out.append(contentsOf: [a0, a1, b0, b0, a1, b1])
        }
        return out
    }
}

/// Incrementally converts a growing list of input samples into ribbon vertices.
///
/// Incremental matters: rebuilding the whole stroke on every touch event would
/// be O(n²) over the stroke and would stutter on long strokes. Each raw sample
/// is converted exactly once.
final class StrokeBuilder {

    private(set) var vertices: [MSStrokeVertex] = []

    /// Newest raw sample, used to seed the prediction ribbon so it starts
    /// exactly where the committed stroke currently ends.
    var lastRawPoint: StrokePoint? { raw.last }

    /// Area the stroke touched, in view points, already widened by the brush
    /// radius. The renderer reads back exactly these tiles at commit time
    /// rather than the whole canvas.
    private(set) var bounds: CGRect = .null

    private var raw: [StrokePoint] = []
    private var nextSegment = 0
    private var lastResampled: StrokePoint?

    private let viewSize: CGSize
    private let color: simd_float4

    init(viewSize: CGSize, color: simd_float4) {
        self.viewSize = viewSize
        self.color = color
    }

    func append(_ points: [StrokePoint]) {
        for point in points {
            // Duplicate samples would produce a zero-length tangent and NaN
            // its way through the whole vertex buffer.
            if let last = raw.last,
               abs(last.location.x - point.location.x) < 0.0001,
               abs(last.location.y - point.location.y) < 0.0001 {
                continue
            }
            raw.append(point)

            // Widen by the brush radius plus a pixel for the antialiased edge,
            // or the outermost ink would fall outside the captured region.
            let reach = CGFloat(StrokeStyle.halfWidth(for: point.pressure)) + 2
            let touched = CGRect(x: point.location.x - reach,
                                 y: point.location.y - reach,
                                 width: reach * 2,
                                 height: reach * 2)
            bounds = bounds.isNull ? touched : bounds.union(touched)
        }
        // A Catmull-Rom segment between raw[k] and raw[k+1] needs raw[k+2] as
        // its outgoing tangent, so a segment can only be emitted once two more
        // samples have arrived behind it.
        emitSegments(while: { $0 + 2 < self.raw.count })
    }

    /// Flushes the trailing segments that were waiting on a lookahead sample
    /// which will now never arrive.
    func finish() {
        emitSegments(while: { $0 + 1 < self.raw.count })
    }

    private func emitSegments(while condition: (Int) -> Bool) {
        while condition(nextSegment) {
            emitSegment(nextSegment)
            nextSegment += 1
        }
    }

    private func emitSegment(_ k: Int) {
        let p0 = raw[max(0, k - 1)]
        let p1 = raw[k]
        let p2 = raw[k + 1]
        let p3 = raw[min(raw.count - 1, k + 2)]

        // Walk the curve in small steps and drop a point every `spacing` of
        // accumulated arc length. Sampling uniformly in t instead would bunch
        // points up on tight curves and spread them on straight runs.
        let substeps = 24
        var previous = lastResampled ?? p1
        var carried: CGFloat = 0

        for step in 1...substeps {
            let t = CGFloat(step) / CGFloat(substeps)
            let position = catmullRom(p0.location, p1.location, p2.location, p3.location, t)
            let pressure = p1.pressure + (p2.pressure - p1.pressure) * Float(t)

            let dx = position.x - previous.location.x
            let dy = position.y - previous.location.y
            let distance = (dx * dx + dy * dy).squareRoot()
            carried += distance

            if carried >= StrokeStyle.resampleSpacing {
                let point = StrokePoint(location: position, pressure: pressure, timestamp: p2.timestamp)
                if let last = lastResampled {
                    appendQuad(from: last, to: point)
                }
                lastResampled = point
                carried = 0
            }
            previous = StrokePoint(location: position, pressure: pressure, timestamp: p2.timestamp)
        }

        // Seed the very first point of the stroke so the next segment has
        // something to connect back to.
        if lastResampled == nil {
            lastResampled = p1
        }
    }

    private func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                            _ t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b)
                   + (-a + c) * t
                   + (2 * a - 5 * b + 4 * c - d) * t2
                   + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x),
                       y: axis(p0.y, p1.y, p2.y, p3.y))
    }

    private func toClip(_ p: CGPoint) -> simd_float2 {
        simd_float2(Float(p.x / viewSize.width) * 2 - 1,
                    1 - Float(p.y / viewSize.height) * 2)
    }

    private func appendQuad(from a: StrokePoint, to b: StrokePoint) {
        let dx = Float(b.location.x - a.location.x)
        let dy = Float(b.location.y - a.location.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.0001 else { return }

        let nx = -dy / length
        let ny = dx / length
        let ha = StrokeStyle.halfWidth(for: a.pressure)
        let hb = StrokeStyle.halfWidth(for: b.pressure)

        func corner(_ p: CGPoint, _ n: Float, _ half: Float, _ edge: Float) -> MSStrokeVertex {
            let offset = CGPoint(x: p.x + CGFloat(nx * half * n),
                                 y: p.y + CGFloat(ny * half * n))
            return MSStrokeVertex(position: toClip(offset), edge: edge, color: color)
        }

        let a0 = corner(a.location,  1, ha,  1)
        let a1 = corner(a.location, -1, ha, -1)
        let b0 = corner(b.location,  1, hb,  1)
        let b1 = corner(b.location, -1, hb, -1)

        vertices.append(contentsOf: [a0, a1, b0, b0, a1, b1])
    }
}
