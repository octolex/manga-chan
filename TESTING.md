# Device test backlog

Free-account signing allows **10 App IDs per 7 days**, so installs are a
budgeted resource. Anything that can be verified in CI must be, and device
installs are batched.

**The rule:** if it needs the GPU, the Pencil, or the display, it goes on this
list. Everything else gets a unit test and never touches the iPad.

## Pending — unverified fix

| # | What | How | Expected |
|---|---|---|---|
| 48 | Coverage accumulates | Draw one very long continuous stroke, watch `gpu` | **Flat**, not climbing with stroke length. Held still, it should fall |
| 49 | Prediction still shows | Draw fast, watch the leading tip | Ink keeps up with the pencil; no stub left behind when you stop |

## Pending — UI regressions to confirm

| # | What | How | Expected |
|---|---|---|---|
| 37 | Panel scroll survives a rebuild | Scroll the layer list down, pick a blend mode | The **layer list** stays where it was |
| 38 | Blend list scroll survives a rebuild | Scroll the 26-mode list down, pick a mode | The **mode list** stays where it was |

## Known and deliberate

Not bugs; do not report these until the milestone that addresses them.

- **Square stroke ends.** Round caps arrive with dab stamping at M3.
- **No texture.** There is no brush engine yet — strokes are smooth geometry.
- **Only black, and no brush settings.** No colour picker and no brush editor,
  so opacity, size and smoothing cannot be changed on the device. This is now
  the main limit on what device testing can answer at all.
- **Tilt tops out near 86°, not 90°.** Measured on the Pencil Pro: the
  altitude reading loses precision and refresh rate as the pencil approaches
  perpendicular. Hardware behaviour, not our arithmetic — so a tilt response
  must not assume the full 0–90° range is reachable in practice.
- **Canvas is screen-sized.** Pan, zoom and a canvas larger than the screen
  come with the per-tile render restructure — see the re-scoped item in
  ROADMAP.md.

## Verified

| Date | What | Result |
|---|---|---|
| 2026-08-28 | Windows → CI → Sideloadly → iPad pipeline | Works, ~10 min push to install |
| 2026-08-28 | C++ core cross-compiles, links, callable from Swift | `core self-test: ok` |
| 2026-08-28 | Metal renders at panel rate | 60 fps, 0.14 ms CPU, 0.85 ms GPU |
| 2026-08-28 | Panel capability query | 60 Hz — iPad Air M4 has no ProMotion |
| 2026-08-28 | Finger drawing, two-finger clear | Works |
| 2026-08-28 | Sparse tile storage, copy-on-write | 99 checks green, Linux + Windows |
| 2026-08-28 | Tile compression | blank 102x, line art 41x, noise 1.0x (bounded) |
| 2026-08-28 | LRU eviction respects budget, keeps hot tiles | Green |
| 2026-08-28 | 4096x4096 line-art page memory | 64 MB dense -> 1.5 MB compressed |
| 2026-08-28 | Per-tile undo, 100 steps | 3 MB vs 6.4 GB for layer snapshots |
| 2026-08-28 | Disk spill tier, block reuse | Green, file stays proportional to working set |
| 2026-08-28 | 100-layer document under budget | 17 MB RAM, all layers readable |
| 2026-08-28 | Compression on device | 304 tiles -> 1857 KB, 42x. Matches CI |
| 2026-08-28 | Clear, then undo to recover | Works |
| 2026-08-28 | Rotation preserves drawing | Works |
| 2026-08-28 | Tile accounting climbs with coverage | Works |
| 2026-08-28 | Undo/redo of strokes | Works after two fixes (see below) |
| 2026-08-28 | Non-linear history: undo, draw, undo, redo | Consistent across repeated scenarios |
| 2026-08-28 | Redo branch invalidation | Correct |
| 2026-08-28 | Capture cost, full-canvas stroke | 6.5 ms, once per stroke. Accepted |
| 2026-08-29 | Block A: draws, panel opens, panel does not leak touches | Pass after 1 fix |
| 2026-08-29 | Block B: add, select-routes-strokes, visibility, delete | Pass after 1 fix |
| 2026-08-29 | Last-layer delete guard | Correctly refused |
| 2026-08-30 | Block C: opacity slider survives its own drag | Pass after 1 fix |
| 2026-08-30 | Block C: blend modes, clipping mask, blend button affordance | Pass |
| 2026-08-30 | Cache rebuilds bump once per selection change, never while painting | Pass |
| 2026-08-30 | Frame cost unchanged from 5 to 10 layers | Pass |
| 2026-08-30 | Live layer count: 1 normally, 2 with a clipped layer | Pass, 10 layers (2 live) |
| 2026-08-30 | Undo and redo across layers, targeting the owning layer | Pass |
| 2026-08-30 | Undo across a deleted layer, repeated undo/redo | Pass, no crash |
| 2026-09-01 | Dab stamping: draws, round caps, curve smoothness at speed | Pass |
| 2026-09-01 | Even weight along a long stroke, no beading | Pass |
| 2026-09-01 | Undo and redo of a dab stroke, identical on return | Pass — seeded jitter holds |
| 2026-09-01 | Tile capture and readback track stroke length, not canvas size | Pass |
| 2026-09-01 | Pencil Pro: pressure, azimuth, roll, hover, squeeze, double-tap | Pass, all channels live |
| 2026-09-01 | Pressure drives width end to end | Pass |
| 2026-09-01 | `peak/fr` reads 4 | Pass — 240 Hz sampling into a 60 Hz frame |
| 2026-09-01 | Self-crossing does not darken (max vs buildup) | Pass, in CI on the simulator |

Bugs found on device, all invisible to CI because
they lived in the Swift shell rather than the engine:

1. **Strokes were never bracketed.** `beginStroke` was never called, so no
   stroke entered the undo history at all. Undo was unwinding earlier `clear`
   operations, which looked like random cells reverting.
2. **Gestures committed phantom strokes.** A two-finger tap still delivers
   touches to the view, so the tap started a stroke, which committed an undo
   action and cleared the redo stack. Undo appeared to work once and then
   stop; redo never worked.
3. **The layers panel collapsed to its header.** A scroll view has no
   intrinsic content size, so the panel had an upper bound and nothing pushing
   against it. Rows laid out into zero height.
4. **The layer detail section overlapped itself.** Buttons without explicit
   heights let UIStackView compress them, and 26 inline blend modes made the
   section taller than the screen. Delete was unreachable.
5. **The panel rebuilt itself mid-drag.** Every property change fired
   `onLayersChanged`, which destroyed the very slider the user was dragging.
   Opacity moved one step and then stopped.
6. **Rebuilding lost scroll position.** Restoring an offset from the parent
   view reads a `contentSize` of zero: Auto Layout computes it during the
   scroll view's *own* layout pass, which runs afterwards. The panel survived
   this by accident — it is laid out repeatedly, so its retry eventually
   landed — while a row inside a stack view got one pass and no second chance.
   Both now restore from inside the scroll view.

The engine was correct throughout. Every one of these lived in how the shell
drove it — layout and view lifecycle, not logic — which is the argument for
pushing more behind the C ABI where CI can reach it. Note the shape they share:
none are arithmetic, all are UIKit rebuilding or sizing something at the wrong
moment.
