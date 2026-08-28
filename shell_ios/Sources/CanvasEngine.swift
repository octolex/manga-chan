//
//  CanvasEngine.swift
//
//  Swift wrapper over the C ABI in core/canvas_api.h.
//
//  The division of labour: the GPU owns painting, the engine owns storage.
//  Pixels cross between them once per stroke, never per frame. That is what
//  lets undo, compression and paging see real data without a readback in the
//  frame loop.
//

import Foundation

struct EngineTile: Hashable {
    let x: Int32
    let y: Int32
}

final class CanvasEngine {

    private let handle: OpaquePointer

    /// Tile edge in pixels, taken from the engine so the two sides can never
    /// disagree about it.
    let tileSize: Int

    var tileByteCount: Int { tileSize * tileSize * 4 }

    init?() {
        // Caches, not Documents: the spill file is rebuildable scratch and
        // must not be backed up or synced.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let scratch = caches?.appendingPathComponent("manga-chan-tiles.scratch").path

        guard let handle = scratch.withUnsafeNullableCString({ mc_canvas_create($0) }) else {
            Diagnostics.log("ENGINE: mc_canvas_create failed")
            return nil
        }
        self.handle = handle
        self.tileSize = Int(mc_tile_size())
        Diagnostics.log("engine created, tile size \(tileSize), scratch \(scratch ?? "none")")
    }

    deinit {
        mc_canvas_destroy(handle)
    }

    // MARK: - Budgets

    func setBudgets(residentBytes: UInt64, compressedBytes: UInt64) {
        mc_canvas_set_budgets(handle, residentBytes, compressedBytes)
    }

    /// Call at a frame boundary, never mid-stroke.
    func evict() {
        mc_canvas_evict(handle)
    }

    // MARK: - Editing

    func beginStroke(_ name: String) {
        mc_canvas_begin_stroke(handle, name)
    }

    func storeTile(_ tile: EngineTile, bytes: UnsafePointer<UInt8>) {
        mc_canvas_store_tile(handle, tile.x, tile.y, bytes)
    }

    func commitStroke() {
        mc_canvas_commit_stroke(handle)
    }

    func abortStroke() {
        mc_canvas_abort_stroke(handle)
    }

    /// Returns false when the tile has never been painted, in which case
    /// `bytes` is untouched and the caller should render the region as empty
    /// rather than uploading anything.
    func loadTile(_ tile: EngineTile, into bytes: UnsafeMutablePointer<UInt8>) -> Bool {
        mc_canvas_load_tile(handle, tile.x, tile.y, bytes) != 0
    }

    // MARK: - History

    var canUndo: Bool { mc_canvas_can_undo(handle) != 0 }
    var canRedo: Bool { mc_canvas_can_redo(handle) != 0 }

    /// Returns the tiles that changed, or nil if there was nothing to undo.
    func undo() -> [EngineTile]? {
        guard mc_canvas_undo(handle) != 0 else { return nil }
        return changedTiles()
    }

    func redo() -> [EngineTile]? {
        guard mc_canvas_redo(handle) != 0 else { return nil }
        return changedTiles()
    }

    /// Recorded as a normal undoable action.
    func clear() -> [EngineTile] {
        mc_canvas_clear(handle)
        return changedTiles()
    }

    private func changedTiles() -> [EngineTile] {
        let count = Int(mc_canvas_changed_tile_count(handle))
        var tiles: [EngineTile] = []
        tiles.reserveCapacity(count)
        for index in 0..<count {
            var x: Int32 = 0
            var y: Int32 = 0
            mc_canvas_changed_tile_at(handle, Int32(index), &x, &y)
            tiles.append(EngineTile(x: x, y: y))
        }
        return tiles
    }

    // MARK: - Instrumentation

    var stats: MCCanvasStats {
        var stats = MCCanvasStats()
        mc_canvas_stats(handle, &stats)
        return stats
    }
}

private extension Optional where Wrapped == String {
    /// Passes a String? through as a C string, or NULL when nil.
    func withUnsafeNullableCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        guard let value = self else { return body(nil) }
        return value.withCString { body($0) }
    }
}
