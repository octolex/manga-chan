# Device test backlog

Free-account signing allows **10 App IDs per 7 days**, so installs are a
budgeted resource. Anything that can be verified in CI must be, and device
installs are batched.

**The rule:** if it needs the GPU, the Pencil, or the display, it goes on this
list. Everything else gets a unit test and never touches the iPad.

## Pending — needs a Pencil Pro

Accumulated since the last install. One install should clear all of these.

| # | What | How | Expected |
|---|---|---|---|
| 1 | Pressure → width | Draw pressing hard, then light | Line visibly thickens and thins |
| 2 | `pressure` readout | Watch HUD while pressing | 0.000 → ~1.000 |
| 3 | `tilt` readout | Hold upright, then angle it | ~90° upright, falls as you tilt |
| 4 | `azimuth` readout | Swing the pencil around a fixed point | Sweeps 0–360° |
| 5 | `roll` readout | Twist the barrel | **A number**, not `—`, and it changes |
| 6 | `hover` readout | Hold just above the glass | A number appears, `—` when far |
| 7 | `squeeze` counter | Squeeze the barrel | Increments |
| 8 | `dbl-tap` counter | Double-tap the barrel | Increments |
| 9 | `peak/fr` | Draw a fast stroke | Climbs toward ~4 |

## Pending — engine integration (finger is fine)

| # | What | How | Expected |
|---|---|---|---|
| 14 | Undo | Two-finger tap after a stroke | Last stroke disappears |
| 15 | Redo | Three-finger tap after undoing | Stroke comes back |
| 16 | Deep undo | Draw 10 strokes, undo all 10 | Unwinds one stroke at a time, in order |
| 17 | Clear is undoable | Four-finger tap, then two-finger tap | Drawing comes back |
| 18 | Tile accounting | Watch `tiles` while drawing | Climbs as you cover more canvas |
| 19 | History cost | Watch `history` after 10 strokes | Shows steps and retained tiles |
| 20 | Capture cost | Watch `capture` at stroke end | Should be a couple of ms, not tens |
| 21 | Rotation | Draw, then rotate the iPad | Drawing survives, repainted from tiles |
| 22 | Paging | Draw across the whole screen | `zip`/`disk` counts become non-zero |

## Pending — testable with a finger

| # | What | How | Expected |
|---|---|---|---|
| 10 | Curve smoothness | Fast loops and spirals | No faceting, no visible rectangles |
| 11 | Self-crossing | Cross a stroke over itself | Crossing is **not** darker than the rest |
| 12 | Clear | Two-finger tap | Canvas goes white |
| 13 | Prediction artefacts | Sharp direction reversals at speed | No stray spur left behind at the turn |

## Known and deliberate

Not bugs; do not report these until the milestone that addresses them.

- **Square stroke ends.** Round caps arrive with dab stamping at M3.
- **No texture.** There is no brush engine yet — strokes are smooth geometry.
- **Canvas is screen-sized and lost on rotate.** The real tiled canvas is M1;
  the renderer has not been connected to it yet.
- **No undo.** M1.

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
| 2026-08-28 | **Undo of strokes** | **BROKEN** - strokes never bracketed. Fixed, awaiting retest |
