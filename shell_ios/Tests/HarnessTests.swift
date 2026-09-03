//
//  HarnessTests.swift
//
//  These tests are trivial on purpose.
//
//  Their job is to prove the harness itself works: that CI can build the C++
//  core for the simulator SDK, link it into a test bundle, boot a simulator,
//  get a Metal device, and run assertions — all on a machine we do not own and
//  cannot log into.
//
//  That matters more than it sounds. Every bug that has cost real time on this
//  project so far lived in the Swift shell, where CI could not see it, while
//  hundreds of C++ checks passed. This is the harness that closes that gap, and
//  it is where the blend-mode shaders get verified against the CPU reference in
//  core/blend.cpp — a shader that blends subtly wrong is nearly impossible to
//  diagnose on a device with no frame debugger attached.
//
//  Keep the trivial cases. When something more elaborate breaks, the first
//  question is always whether the harness itself is sound.
//

import XCTest
import Metal

final class HarnessTests: XCTestCase {

    func testEngineCoreIsLinkedAndWorking() {
        // Proves the simulator-SDK build of libcore linked correctly. A
        // mismatched architecture fails at link time; a broken C++ runtime
        // fails here.
        XCTAssertEqual(core_self_test(), 0, "the C++ core self-test failed")

        let version = String(cString: core_version_string())
        XCTAssertFalse(version.isEmpty)
    }

    func testMetalIsAvailableOnTheSimulator() {
        // The simulator on Apple silicon runs real Metal, which is what makes
        // shader verification in CI possible at all.
        let device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "no Metal device — shader tests cannot run here")

        guard let device else { return }
        XCTAssertNotNil(device.makeCommandQueue())
    }

    func testTheDabStructIsTheSameOnBothSidesOfTheBuffer() {
        // BrushStroke hands the engine's dab array straight to a Metal buffer
        // with no copy or conversion, so mc::Dab, MCDab and MSDab must be the
        // same bytes. brush_api.cpp static-asserts the first two against each
        // other; nothing but a comment in ShaderTypes.h held the third, which is
        // the one that reaches the GPU.
        //
        // The failure is silent — garbage geometry with no error message, the
        // one class of bug we cannot chase without a frame debugger — and it
        // arrives precisely when a field is added, which is when a comment is
        // least likely to be read.
        XCTAssertEqual(MemoryLayout<MSDab>.size, MemoryLayout<MCDab>.size,
                       "MSDab and MCDab have drifted apart in size")
        XCTAssertEqual(MemoryLayout<MSDab>.stride, MemoryLayout<MCDab>.stride)

        XCTAssertEqual(MemoryLayout<MSDab>.offset(of: \.x), MemoryLayout<MCDab>.offset(of: \.x))
        XCTAssertEqual(MemoryLayout<MSDab>.offset(of: \.y), MemoryLayout<MCDab>.offset(of: \.y))
        XCTAssertEqual(MemoryLayout<MSDab>.offset(of: \.radius),
                       MemoryLayout<MCDab>.offset(of: \.radius))
        XCTAssertEqual(MemoryLayout<MSDab>.offset(of: \.angle),
                       MemoryLayout<MCDab>.offset(of: \.angle))
        XCTAssertEqual(MemoryLayout<MSDab>.offset(of: \.flow),
                       MemoryLayout<MCDab>.offset(of: \.flow))
        XCTAssertEqual(MemoryLayout<MSDab>.offset(of: \.roundness),
                       MemoryLayout<MCDab>.offset(of: \.roundness))
        XCTAssertEqual(MemoryLayout<MSDab>.offset(of: \.hardness),
                       MemoryLayout<MCDab>.offset(of: \.hardness))
        XCTAssertEqual(MemoryLayout<MSDab>.offset(of: \.grainOffset),
                       MemoryLayout<MCDab>.offset(of: \.grainOffset))
    }

    func testTheEngineFillsTheDabsTheShellUploads() {
        // A short stroke through the C ABI, read back exactly as the renderer
        // reads it: reinterpreting the engine's array as MSDab without a copy.
        var brush = mc_brush_ink_pen()
        brush.grainDepth = 1
        guard let path = mc_stroke_begin(&brush, 1) else {
            XCTFail("mc_stroke_begin returned nil")
            return
        }
        defer { mc_stroke_end(path) }

        for i in 0...10 {
            mc_stroke_add_sample(path, Float(i) * 12, 40, 1, 1.2, 0, -1, Double(i) * 0.01)
        }
        mc_stroke_finish(path)

        let count = Int(mc_stroke_dab_count(path))
        XCTAssertGreaterThan(count, 5)

        guard let raw = mc_stroke_dabs(path) else {
            XCTFail("mc_stroke_dabs returned nil")
            return
        }
        let dabs = UnsafeRawPointer(raw).assumingMemoryBound(to: MSDab.self)

        // Through the reinterpreted pointer, so a layout mismatch shows up as
        // nonsense here rather than as unexplained geometry on the device.
        XCTAssertEqual(dabs[0].grainOffset, 0, "the first dab is at the stroke's start")
        for i in 1..<count {
            XCTAssertGreaterThan(dabs[i].grainOffset, dabs[i - 1].grainOffset,
                                 "grain offset must advance along the stroke")
            XCTAssertGreaterThan(dabs[i].radius, 0)
        }
        XCTAssertEqual(Double(dabs[count - 1].grainOffset),
                       Double(mc_stroke_length(path)), accuracy: 8.0)
    }

    func testCanvasEngineRoundTrip() {
        // The same store/load path the renderer uses at stroke end, exercised
        // without a GPU in the way.
        let tileSize = Int(mc_tile_size())
        let byteCount = tileSize * tileSize * 4

        guard let canvas = mc_canvas_create(nil) else {
            XCTFail("mc_canvas_create returned nil")
            return
        }
        defer { mc_canvas_destroy(canvas) }

        var ink = [UInt8](repeating: 0xA0, count: byteCount)
        var readBack = [UInt8](repeating: 0, count: byteCount)

        // Nothing painted yet, so the caller's buffer must be left alone.
        XCTAssertEqual(mc_canvas_load_tile(canvas, 0, 0, &readBack), 0)

        mc_canvas_begin_stroke(canvas, "Test stroke")
        mc_canvas_store_tile(canvas, 0, 0, &ink)
        mc_canvas_commit_stroke(canvas)

        XCTAssertEqual(mc_canvas_load_tile(canvas, 0, 0, &readBack), 1)
        XCTAssertEqual(readBack, ink)

        // And the history has to have recorded it. This is the exact condition
        // that was silently false on device for a whole session.
        XCTAssertEqual(mc_canvas_can_undo(canvas), 1)

        var stats = MCCanvasStats()
        mc_canvas_stats(canvas, &stats)
        XCTAssertEqual(stats.undoDepth, 1)
        XCTAssertEqual(stats.storesOutsideAction, 0,
                       "tiles were written outside a begin/commit pair")
    }

    func testUndoRestoresPreviousTile() {
        let tileSize = Int(mc_tile_size())
        let byteCount = tileSize * tileSize * 4

        guard let canvas = mc_canvas_create(nil) else {
            XCTFail("mc_canvas_create returned nil")
            return
        }
        defer { mc_canvas_destroy(canvas) }

        var first = [UInt8](repeating: 0x11, count: byteCount)
        var second = [UInt8](repeating: 0x22, count: byteCount)
        var readBack = [UInt8](repeating: 0, count: byteCount)

        mc_canvas_begin_stroke(canvas, "First")
        mc_canvas_store_tile(canvas, 0, 0, &first)
        mc_canvas_commit_stroke(canvas)

        mc_canvas_begin_stroke(canvas, "Second")
        mc_canvas_store_tile(canvas, 0, 0, &second)
        mc_canvas_commit_stroke(canvas)

        XCTAssertEqual(mc_canvas_undo(canvas), 1)
        XCTAssertEqual(mc_canvas_changed_tile_count(canvas), 1)
        XCTAssertEqual(mc_canvas_load_tile(canvas, 0, 0, &readBack), 1)
        XCTAssertEqual(readBack, first)

        XCTAssertEqual(mc_canvas_redo(canvas), 1)
        XCTAssertEqual(mc_canvas_load_tile(canvas, 0, 0, &readBack), 1)
        XCTAssertEqual(readBack, second)
    }
}
