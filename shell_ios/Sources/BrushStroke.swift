//
//  BrushStroke.swift
//
//  A thin Swift skin over the engine's stroke path.
//
//  Deliberately thin. Everything that could be got wrong — resampling,
//  spacing, dynamics, taper, which tiles were touched — lives in C++ where the
//  test suite can reach it. Every bug that has reached the device so far lived
//  in this shell, so the goal here is to have as little to get wrong as
//  possible: convert coordinates, forward samples, hand back a pointer.
//
//  Coordinates: touches arrive in view points, the engine works in canvas
//  pixels. The conversion happens once, here, on the way in. Dabs come back in
//  canvas pixels and the vertex shader takes them in that space, so points
//  exist nowhere past this file.
//

import CoreGraphics
import Foundation

final class BrushStroke {

    private let handle: OpaquePointer?
    private let pixelScale: CGFloat

    /// Newest raw sample, used to seed the prediction path so it starts where
    /// the committed stroke currently ends.
    private(set) var lastPoint: StrokePoint?

    private(set) var sampleCount = 0

    init(brush: MCBrush, pixelScale: CGFloat, seed: UInt64) {
        var brush = brush
        self.handle = mc_stroke_begin(&brush, seed)
        self.pixelScale = pixelScale
    }

    deinit {
        mc_stroke_end(handle)
    }

    func append(_ points: [StrokePoint]) {
        for point in points {
            mc_stroke_add_sample(handle,
                                 Float(point.location.x * pixelScale),
                                 Float(point.location.y * pixelScale),
                                 point.pressure,
                                 point.tilt,
                                 point.azimuth,
                                 point.roll,
                                 point.timestamp)
            lastPoint = point
            sampleCount += 1
        }
    }

    func finish() {
        mc_stroke_finish(handle)
    }

    var dabCount: Int { Int(mc_stroke_dab_count(handle)) }

    var isEmpty: Bool { dabCount == 0 }

    /// The dab array, owned by the engine. Valid until the next `append`.
    ///
    /// Handed straight to a Metal buffer rather than copied into a Swift array
    /// first: MSDab and the engine's dab are the same bytes, and a long stroke
    /// is tens of thousands of them.
    var dabs: UnsafePointer<MSDab>? {
        guard let raw = mc_stroke_dabs(handle) else { return nil }
        return UnsafeRawPointer(raw).assumingMemoryBound(to: MSDab.self)
    }

    /// Exactly the tiles the stroke covers, not its bounding box. A diagonal
    /// stroke's bounding box is most of the canvas, and capturing by rectangle
    /// would push several times as many tiles into undo history as the stroke
    /// actually changed.
    var touchedTiles: Set<EngineTile> {
        let count = Int(mc_stroke_tile_count(handle))
        guard count > 0 else { return [] }

        var pairs = [Int32](repeating: 0, count: count * 2)
        let written = pairs.withUnsafeMutableBufferPointer { buffer in
            Int(mc_stroke_copy_tiles(handle, buffer.baseAddress, size_t(count)))
        }

        var tiles = Set<EngineTile>(minimumCapacity: written)
        for i in 0..<written {
            tiles.insert(EngineTile(x: pairs[i * 2], y: pairs[i * 2 + 1]))
        }
        return tiles
    }

    /// A throwaway path over the predicted touches, for the lookahead overlay.
    ///
    /// Built fresh each frame rather than branched off the live stroke: a
    /// prediction is discarded within a frame or two, so it never needs to
    /// agree exactly with what the committed stroke will do — and keeping it
    /// separate means a wrong prediction can never contaminate the real path.
    static func prediction(brush: MCBrush, pixelScale: CGFloat,
                           from seed: StrokePoint, through points: [StrokePoint]) -> BrushStroke? {
        guard !points.isEmpty else { return nil }
        let path = BrushStroke(brush: brush, pixelScale: pixelScale, seed: 1)
        path.append([seed] + points)
        path.finish()
        return path.isEmpty ? nil : path
    }
}
