# Device test backlog

Free-account signing allows **10 App IDs per 7 days**, so installs are a
budgeted resource. Anything that can be verified in CI must be, and device
installs are batched.

**The rule:** if it needs the GPU, the Pencil, or the display, it goes on this
list. Everything else gets a unit test and never touches the iPad.

## Pending — colour and brush controls

| # | What | How | Expected |
|---|---|---|---|
| 50 | Panel opens | Tap the brush button, under the layers button | Colour square, sliders, accumulation switch |
| 51 | Colour | Drag in the square, then the hue strip, then draw | Ink matches the swatch; both drags track continuously |
| 52 | Size | Drag Size, draw | Stroke weight follows. 1 px stays a visible line |
| 53 | Opacity | Set ~30%, draw a stroke that crosses itself | Translucent, and the crossing is **not** darker |
| 54 | Buildup | Switch to Buildup, Flow ~30%, cross a stroke | The crossing **is** darker. Switch back and it stops |
| 55 | Hardness | Take it to 0%, draw | Soft airbrushed edge rather than a hard rim |
| 56 | Stabilization | 0% then ~60%, draw the same shaky line | Visibly steadier, at the cost of lag behind the pencil |
| 57 | Spacing | Raise toward 50%, draw slowly | Dabs separate into a chain — confirms spacing is real |
| 58 | Panel does not leak touches | Draw a stroke starting on the panel | Nothing appears underneath it |
| 59 | Sliders survive their drag | Drag each one edge to edge without lifting | Tracks the whole way, value updates live |

## Pending — grain

CI already pins the grain arithmetic against the engine's CPU sampler, so what
is left here is only what a test cannot see: whether it looks like paper, and
whether it costs a frame.

| # | What | How | Expected |
|---|---|---|---|
| 60 | Depth off is off | Grain Depth at 0, draw | Identical to a stroke before grain existed — flat, no lightening |
| 61 | Depth reads as tooth | Depth ~70%, draw slowly | Broken, textured edge. The stroke also gets lighter — that is the medium, not a bug |
| 62 | Scale | Scale from 24 px to 600 px, draw at each | Fine tooth through to coarse blotches. No repeating grid at any setting |
| 63 | Canvas grain ignores the stroke | Canvas mode, cross a stroke back over itself | The texture in the crossing matches its surroundings — it belongs to the paper |
| 64 | Rolling grain follows the stroke | Rolling mode, same crossing | The crossing **does** show. Both directions carry their own grain |
| 65 | Grain costs no frame budget | Depth 100%, long fast stroke, watch `gpu` | Flat, and level with a Depth-0 stroke |
| 66 | Grain survives commit and undo | Draw grained, lift, undo, redo | Returns identical — the map is seeded, not random |
| 67 | Prediction is grained too | Depth 100%, draw fast, watch the leading tip | The tip ahead of the pen is textured, not a smooth lead-in that turns rough |

## Pending — UI regressions to confirm

| # | What | How | Expected |
|---|---|---|---|
| 37 | Panel scroll survives a rebuild | Scroll the layer list down, pick a blend mode | The **layer list** stays where it was |
| 38 | Blend list scroll survives a rebuild | Scroll the 26-mode list down, pick a mode | The **mode list** stays where it was |

## Known and deliberate

Not bugs; do not report these until the milestone that addresses them.

- **Dab shapes are procedural discs.** Grain textures the *coverage*; the dab
  itself is still an analytic circle, so there is no bristle or stamp shape
  yet. A shape map goes through the same sampler the grain now uses.
- **One grain map.** It is generated from a fixed seed rather than chosen, so
  there is nothing to switch between until the brush library exists. Depth and
  Scale are the whole of the control surface.
- **No brush library.** Settings can be changed but not saved, named, or
  switched between. One brush at a time until the brush editor proper.
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
| 2026-09-01 | Coverage accumulates rather than redrawing; `gpu` flat over a long stroke | Pass |
| 2026-09-01 | Prediction survives the move onto the composited frame | Pass |
| 2026-09-02 | Grain tiles seamlessly: seam step 0.34 vs 3.16 inside the map | Pass, in CI |
| 2026-09-02 | Metal grain sampler matches the engine reference | Pass, in CI — worst 3 of 255 over ~600 px |
| 2026-09-02 | Canvas grain unchanged by overlapping dabs under Maximum | Pass, in CI |
| 2026-09-02 | Rolling grain scrolls with arc length; canvas grain ignores it | Pass, in CI |

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
