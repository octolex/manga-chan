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
