# Manga-Chan roadmap

Milestone status. Each milestone ends with something that runs on the iPad.

Legend: ✅ done · 🔨 in progress · ⬜ not started

---

## ✅ M0 — Pipeline proof

Prove that code written on Windows reaches the iPad. Nothing else mattered
until this worked.

| | |
|---|---|
| ✅ | Repo, CMake, XcodeGen spec standing in for the `.xcodeproj` |
| ✅ | CI builds an unsigned `.ipa` on a free macOS runner |
| ✅ | Sideloadly signs on Windows with a free Apple ID — no certificates in CI |
| ✅ | UIKit + `CAMetalLayer` + `CAMetalDisplayLink`, rendering at panel rate |
| ✅ | C++ core cross-compiles, links, and is callable from Swift over a C ABI |
| ✅ | Instrumentation HUD, standing in for Instruments |
| ✅ | Crash handler and rotating logs in `Documents/`, our only crash reporting |
| ✅ | Apple Pencil / touch input via `coalescedTouches` |
| ✅ | Catmull-Rom resampling and max-coverage accumulation |
| ✅ | Input inspector for pressure, tilt, azimuth, roll, hover, squeeze |

**Measured:** ~40 s from push to a downloadable `.ipa` · 60 fps · 0.14 ms CPU · 0.85 ms GPU.
The iPad Air M4 is a 60 Hz panel with no ProMotion, so the frame budget on
this device is 16.6 ms rather than 8.3 ms.

---

## ✅ M1 — Tiled sparse canvas

The foundation, and the thing that genuinely beats Procreate: memory becomes
a function of what is *visible*, not of document size, which removes the
layer cap entirely.

| | |
|---|---|
| ✅ | 256×256 tiles, sparse per-layer maps, unbounded canvas in all directions |
| ✅ | Reference-counted tile store with copy-on-write |
| ✅ | Compression codec with a bounded worst case |
| ✅ | Compressed-RAM residency tier with LRU eviction and a byte budget |
| ✅ | Disk tier — scratch file with block reuse for cold tiles |
| ✅ | Per-tile undo ring with copy-on-write history |
| ✅ | Renderer backed by the tile store, with undo/redo on device |

**Measured**, all in CI on Linux and Windows in ~40 s, 245 checks:

| | |
|---|---|
| 4096×4096 page of line art | 64 MB dense → **1.5 MB** compressed (41×) |
| Diagonal stroke across that canvas | touches 16 of 256 tiles |
| 100 undo steps | **3 MB**, against 6.4 GB for layer snapshots |
| 400 tiles across 100 layers | 100 MB dense → 17 MB RAM + 235 KB disk |

The last row is the one that matters: RAM stayed pinned to its budget while
every one of the 100 layers remained instantly readable. That is the layer cap
gone.

Pixels cross between GPU and engine **once per stroke**, never per frame. Undo
and redo re-upload only the tiles that actually changed, so their cost tracks
the size of the edit rather than the size of the document.

**Verified on device.** Undo and redo confirmed across non-linear history —
undo, draw, undo, redo — including redo-branch invalidation. Full-canvas
stroke commit costs 6.5 ms, once per stroke rather than per frame.

That 6.5 ms is pixel copying, not tile selection, so M2 should back tile
buffers with GPU-visible memory and remove the copy entirely. On unified
memory it is free.

---

## 🔨 M2 — Compositor

`under_cache + active_layer + over_cache` at view resolution over the visible
region only. This is the largest single source of Procreate's perceived
speed — more than the brush engine. A 200-layer document then costs the same
per painting frame as a 3-layer one.

No Pencil dependency: none of this milestone touches input.

| | |
|---|---|
| ✅ | Layer stack: order, opacity, blend mode, visibility, clip-to-below |
| ✅ | Layer duplication sharing tiles copy-on-write |
| ✅ | Undo addressed by stable `LayerId`, safe across layer deletion |
| ✅ | All 26 blend modes, CPU reference implementation |
| ✅ | Simulator test harness in CI, with real Metal |
| ✅ | Blend-mode shaders in Metal, verified against the CPU reference |
| ✅ | under/over cache planning, clip-group aware |
| ⬜ | Executing the plan in Metal |
| ⬜ | Layer panel in the app |
| ⬜ | Tile buffers backed by GPU-visible memory, removing the 6.5 ms capture |
| ⬜ | Golden-image tests in the iOS Simulator on CI |

863 checks green on Linux and Windows, plus 6 on an iPad simulator.

**200 layers, 1 live per frame, 0 cache rebuilds over 100 painted frames.**
That is the claim the whole milestone rests on: a deep document costs what a
shallow one costs while the pen is down.

All 26 blend shaders are checked against the CPU implementation on every
push: 26 modes x 64 colour pairs x 2 opacities, worst channel difference **1**
of 2 allowed. That is rounding, not disagreement.

One limitation found and recorded rather than discovered later: **the iOS
Simulator does not support programmable blending**, rejecting it at pipeline
creation. The shader therefore has two entry points sharing one composite
function — the shipping path reads the destination from tile memory, the
tested path takes it as a texture. What CI verifies is the arithmetic, which
is where mistakes hide; what it cannot verify is one documented attribute
that fails loudly rather than subtly.

The simulator harness matters more than its four trivial tests suggest. Every
bug that has reached the device lived in the Swift shell, invisible to the C++
suite. CI can now reach Metal, which is what lets the blend shaders be checked
against the CPU reference rather than eyeballed.

---

## ⬜ M3 — Brush engine

Dab stamping, not ribbons. Arc-length resampling already exists from M0.
Scratch-buffer accumulation already exists from M0. What is missing is
textured dabs, per-tile culling, and the brush parameter model.

Round stroke caps arrive here.

---

## ⬜ M4 — Input and latency

`predictedTouches` into a transient overlay only. `maximumDrawableCount = 2`.
End-to-end latency measurement.

The milestone where having no Mac hurts most — a cloud-Mac day may be worth
~€5 here if the in-app HUD is not saying enough.

---

## ⬜ M5 — Multi-page documents and panels

The manga priority, and the one feature that is a rewrite if deferred, which
is why the document model is being built page-aware from the start.

Document as an ordered book of pages · page navigator · templates with bleed,
trim and safe area at print DPI · panels as vector quads with gutters and
panel-as-clipping-mask · versioned package format · per-page and book export.

---

## ⬜ M6+ — Vector layers, geometry kernel, text

Vector line art rasterising into the same tile format · Clipper2 boolean ops ·
perspective and symmetry rulers · text, lettering and screentones.

---

## Constraints shaping all of this

- **No Mac.** CI compiles; it cannot run Instruments or the Metal debugger.
  Compensated by keeping the engine platform-agnostic and testable off-device,
  by the in-app HUD, and by on-device logs.
- **10 App IDs per 7 days.** Device installs are budgeted, so device tests are
  batched — see [TESTING.md](TESTING.md).
- **60 Hz panel.** A 120 Hz latency target can only ever be validated on an
  iPad Pro.
