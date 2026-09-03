//
//  GrainTexture.swift
//
//  Builds the grain map and uploads it.
//
//  The bytes come from the engine rather than from an asset, which is what lets
//  the shader, the C++ suite and the simulator harness all talk about the same
//  texture without a file crossing between them: it is a pure function of a
//  seed. The asset-format question that a real brush library needs is deferred
//  to the brush editor, where it belongs.
//
//  This file exists rather than a few lines inside Renderer because the test
//  bundle needs the identical texture to pin the Metal sampler against the
//  engine's reference — and a second, "obviously equivalent" copy of the upload
//  path in the tests would be the thing that quietly drifts.
//

import Metal

enum GrainTexture {

    /// 256 across is 64 KB and resolves a tooth fine enough to read as paper at
    /// the scales a brush uses it. Larger buys detail nobody sees through a
    /// dab; smaller starts to repeat visibly.
    static let size = 256

    /// Fixed, so the grain is the same on every launch and in every test. A
    /// per-launch seed would make a stroke unreproducible between runs, which
    /// is the same objection that made stroke jitter deterministic.
    static let defaultSeed: UInt64 = 0x4D_41_4E_47_41_43_48_41  // "MANGACHA"

    /// The raw map: `size * size` single-channel bytes, row-major. Nil if the
    /// engine refuses the request.
    ///
    /// No logging from here on purpose. This type is compiled into the test
    /// bundle so the harness can pin the Metal sampler against the very bytes
    /// the app uploads, and reaching for Diagnostics would drag signal handlers
    /// and log files in with it. Reporting the failure is the caller's job.
    static func bytes(seed: UInt64 = defaultSeed, size: Int = size) -> [UInt8]? {
        var map = [UInt8](repeating: 0, count: size * size)
        let written = map.withUnsafeMutableBufferPointer { buffer in
            mc_grain_generate(Int32(size), seed, buffer.baseAddress, buffer.count)
        }
        return written == map.count ? map : nil
    }

    /// Uploads the map as `r8Unorm`. The sampler lives in the shader, so there
    /// is no sampler state to keep in sync here — the address mode that makes
    /// the tiling seamless is declared next to the fetch that relies on it.
    static func make(device: MTLDevice,
                     seed: UInt64 = defaultSeed,
                     size: Int = size) -> MTLTexture? {
        guard let map = bytes(seed: seed, size: size) else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Brush grain"

        map.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: size)
        }
        return texture
    }
}
