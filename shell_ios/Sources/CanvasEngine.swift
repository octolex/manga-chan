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
import simd

struct EngineTile: Hashable {
    let x: Int32
    let y: Int32
}

/// One frame's answer to "what has to be redrawn".
struct CompositePlanSnapshot {
    var under: [MCLayerId] = []
    var live: [MCLayerId] = []
    var over: [MCLayerId] = []
    var activeLayer: MCLayerId = MC_INVALID_LAYER
    var underDirty = true
    var overDirty = true

    var layerCount: Int { under.count + live.count + over.count }
}

/// Mirrors MCLayerInfo with Swift types.
struct LayerProperties {
    var name: String = ""
    var opacity: Float = 1
    var blend: Int32 = 0
    var visible: Bool = true
    var locked: Bool = false
    var clipToBelow: Bool = false
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

    // MARK: - Layers

    var layerCount: Int { Int(mc_canvas_layer_count(handle)) }

    /// Bottom to top. A layers panel displays these reversed.
    func layer(at index: Int) -> MCLayerId {
        mc_canvas_layer_at(handle, Int32(index))
    }

    func index(of layer: MCLayerId) -> Int {
        Int(mc_canvas_layer_index(handle, layer))
    }

    var layerIds: [MCLayerId] {
        (0..<layerCount).map { layer(at: $0) }
    }

    var activeLayer: MCLayerId { mc_canvas_active_layer(handle) }

    @discardableResult
    func setActiveLayer(_ layer: MCLayerId) -> Bool {
        mc_canvas_set_active_layer(handle, layer) != 0
    }

    @discardableResult
    func addLayer(named name: String) -> MCLayerId {
        name.withCString { mc_canvas_add_layer(handle, $0) }
    }

    @discardableResult
    func duplicateLayer(_ layer: MCLayerId) -> MCLayerId {
        mc_canvas_duplicate_layer(handle, layer)
    }

    /// Fails when only one layer remains: the next stroke needs somewhere to go.
    @discardableResult
    func removeLayer(_ layer: MCLayerId) -> Bool {
        mc_canvas_remove_layer(handle, layer) != 0
    }

    @discardableResult
    func moveLayer(_ layer: MCLayerId, to index: Int) -> Bool {
        mc_canvas_move_layer(handle, layer, Int32(index)) != 0
    }

    func properties(of layer: MCLayerId) -> LayerProperties? {
        var info = MCLayerInfo()
        guard mc_canvas_layer_info(handle, layer, &info) != 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: 128)
        mc_canvas_layer_name(handle, layer, &buffer, Int32(buffer.count))

        return LayerProperties(name: String(cString: buffer),
                               opacity: info.opacity,
                               blend: info.blend,
                               visible: info.visible != 0,
                               locked: info.locked != 0,
                               clipToBelow: info.clipToBelow != 0)
    }

    func setProperties(_ properties: LayerProperties, of layer: MCLayerId) {
        var info = MCLayerInfo(opacity: properties.opacity,
                               blend: properties.blend,
                               visible: properties.visible ? 1 : 0,
                               locked: properties.locked ? 1 : 0,
                               clipToBelow: properties.clipToBelow ? 1 : 0)
        mc_canvas_set_layer_info(handle, layer, &info)
        properties.name.withCString { mc_canvas_set_layer_name(handle, layer, $0) }
    }

    // MARK: - Editing

    func beginStroke(_ name: String) {
        mc_canvas_begin_stroke(handle, name)
    }

    func storeTile(_ tile: EngineTile, in layer: MCLayerId, bytes: UnsafePointer<UInt8>) {
        mc_canvas_store_tile_in(handle, layer, tile.x, tile.y, bytes)
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
    func loadTile(_ tile: EngineTile, from layer: MCLayerId,
                  into bytes: UnsafeMutablePointer<UInt8>) -> Bool {
        mc_canvas_load_tile_from(handle, layer, tile.x, tile.y, bytes) != 0
    }

    // MARK: - Composite plan

    func refreshPlan() -> CompositePlanSnapshot {
        var raw = MCCompositePlan()
        mc_canvas_refresh_plan(handle, &raw)

        func section(_ which: MCCompositeSection, _ count: Int32) -> [MCLayerId] {
            (0..<Int(count)).map { mc_canvas_plan_layer(handle, Int32(which.rawValue), Int32($0)) }
        }

        return CompositePlanSnapshot(
            under: section(MCCompositeSectionUnder, raw.underCount),
            live: section(MCCompositeSectionLive, raw.liveCount),
            over: section(MCCompositeSectionOver, raw.overCount),
            activeLayer: raw.activeLayer,
            underDirty: raw.underDirty != 0,
            overDirty: raw.overDirty != 0)
    }

    func invalidateCaches() {
        mc_canvas_invalidate_caches(handle)
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

    /// Clears the active layer. Recorded as a normal undoable action.
    func clearActiveLayer() -> [EngineTile] {
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
