//
//  StrokeCoverage.swift
//
//  The pixel format the stroke in progress accumulates in, in one place so the
//  renderer and the shader tests cannot drift apart. The tests used to build
//  their own `.rgba8Unorm` pipeline beside the renderer's, which is how an
//  8-bit precision problem could live in both without either noticing.
//

import Metal

enum StrokeCoverage {

    /// 16 bits per channel, integer.
    ///
    /// It was `.rgba8Unorm` until 2026-11-06, and that was too coarse for the
    /// Blending opacity curve. A dab at Opacity *o* deposits `o^2.6`; at 5%
    /// that is 0.0004, about a tenth of one 8-bit step. Alpha-over blending
    /// rounds every dab back to the nearest step, so a dab worth less than
    /// half a step adds exactly nothing — and in simulation every Opacity
    /// below about 9% drew nothing at all however long it was scrubbed, while
    /// 10% came out some 60% too dark. The engine's own tests could not see
    /// it: they model density in exact floating point.
    ///
    /// Why this format and not `.rgba16Float`: half floats have their
    /// precision near zero and lose it toward 1, which is where a scrubbed
    /// patch spends its time. Simulated over 560 dabs, 16-bit integer matches
    /// exact arithmetic to the fourth decimal from Opacity 3% up; half float
    /// drifts by up to 0.01. Blending into it is supported on Apple3 and later
    /// (Metal Feature Set Tables, "RGBA16Unorm: All"), and this iPad is Apple9.
    ///
    /// The cost is memory: one screen-sized texture at 8 bytes a pixel rather
    /// than 4, about 45 MB instead of 22 on a 13-inch screen.
    ///
    /// The floor that remains: a dab under half a 16-bit step still rounds
    /// away, which is Opacity below about 1.1% in Blending. Procreate's own
    /// strokes at that setting are below one unit of its eyedropper.
    static let pixelFormat: MTLPixelFormat = .rgba16Unorm
}
