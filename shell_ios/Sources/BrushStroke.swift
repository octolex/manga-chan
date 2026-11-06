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

    /// The brush this stroke was begun with. The renderer takes the stroke's
    /// grain and tint from here rather than from whatever brush is current,
    /// so a slider moved mid-stroke cannot change ink already laid down.
    let brush: MCBrush

    /// Newest raw sample, used to seed the prediction path so it starts where
    /// the committed stroke currently ends.
    private(set) var lastPoint: StrokePoint?

    private(set) var sampleCount = 0

    /// - Parameter input: the app-wide Pressure and Smoothing settings. They
    ///   have to be set before the first sample, so they come in here.
    init(brush: MCBrush, pixelScale: CGFloat, seed: UInt64,
         input: MCInputSettings = mc_input_settings_default()) {
        var copy = brush
        self.handle = mc_stroke_begin(&copy, seed)
        self.pixelScale = pixelScale
        self.brush = brush
        var settings = input
        mc_stroke_set_input_settings(handle, &settings)
    }

    /// Wraps a path the engine has already built — QuickShape's.
    private init(handle: OpaquePointer?, brush: MCBrush, pixelScale: CGFloat) {
        self.handle = handle
        self.brush = brush
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
                                 point.timestamp,
                                 point.fromPressureDevice ? 1 : 0)
            lastPoint = point
            sampleCount += 1
        }
    }

    func finish() {
        mc_stroke_finish(handle)
    }

    var dabCount: Int { Int(mc_stroke_dab_count(handle)) }

    var isEmpty: Bool { dabCount == 0 }

    /// The first dab the end taper revised after it was emitted, or
    /// `dabCount` when none was. See `Renderer.encodeCoverage`.
    var firstRevisedDab: Int { Int(mc_stroke_first_revised_dab(handle)) }

    // MARK: - QuickShape

    /// Fits a shape to the stroke drawn so far, in canvas pixels. Nil when the
    /// stroke is not clearly a shape, and should be left as drawn.
    func detectShape() -> MCQuickShape? {
        var shape = MCQuickShape()
        let kind = mc_quickshape_detect(handle, &shape)
        return kind == Int32(MC_SHAPE_NONE.rawValue) ? nil : shape
    }

    /// A fresh, unfinished stroke drawing `shape` with this stroke's brush.
    /// It replaces this one wholesale; it is finished on lift like any other.
    func replacing(with shape: MCQuickShape, seed: UInt64,
                   timestamp: TimeInterval) -> BrushStroke {
        var shape = shape
        var brush = self.brush
        let fromPencil: Int32 = (lastPoint?.fromPressureDevice ?? true) ? 1 : 0
        let handle = mc_quickshape_stroke(&shape, &brush, seed, timestamp, fromPencil)
        let stroke = BrushStroke(handle: handle, brush: self.brush, pixelScale: pixelScale)
        stroke.lastPoint = lastPoint
        stroke.sampleCount = sampleCount
        return stroke
    }

    /// Canvas pixels to view points, for the shell placing things over the
    /// canvas — the eyedropper loupe, the QuickShape pen position.
    var scale: CGFloat { pixelScale }

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
                           input: MCInputSettings = mc_input_settings_default(),
                           from seed: StrokePoint, through points: [StrokePoint]) -> BrushStroke? {
        guard !points.isEmpty else { return nil }
        // The same pressure curve as the stroke, or the predicted tip would be
        // a different width from the line that replaces it.
        let path = BrushStroke(brush: brush, pixelScale: pixelScale, seed: 1, input: input)
        path.append([seed] + points)
        path.finish()
        return path.isEmpty ? nil : path
    }
}
