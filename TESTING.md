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
