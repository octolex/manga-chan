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

**The route has since changed.** This milestone is kept as it was proven, but
Windows and Sideloadly are no longer in it: there is no development machine at
all now. Work is directed from the iPad through Claude Code, and the `.ipa` is
downloaded and installed on the iPad with SideStore. See [README.md](README.md).
What M0 actually established survives the change — that code written somewhere
without a Mac reaches the device, signed by a free Apple ID, with no
certificates in CI.

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

## ✅ M2 — Compositor

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
| ✅ | Layers and the composite plan across the C ABI |
| ✅ | Executing the plan in Metal |
| ✅ | Layers panel in the app |
| ✅ | Blend-mode shaders verified against the CPU reference in CI |
| ↪️ | Tile buffers backed by GPU-visible memory — **re-scoped, see below** |

991 checks green on Linux and Windows, plus 6 on an iPad simulator.

### The GPU-memory item, re-scoped

It was listed here as "remove the 6.5 ms capture by backing tile buffers with
GPU-visible memory". That framing does not survive contact with the design.

The cost is not the memory being unshared — layer textures already use shared
storage, so the CPU reads them without a transfer. The cost is that a layer is
one screen-sized texture while storage is 256x256 tiles, so committing a stroke
copies between two different shapes. Removing the copy means rendering into
per-tile textures instead, which is the same restructure that pan, zoom and a
canvas larger than the screen need.

So it belongs with that work, not here. It is once per stroke rather than per
frame, and the user's own reaction to measuring it was that 6.5 ms for a
full-canvas commit is already very low.

**200 layers, 1 live per frame, 0 cache rebuilds over 100 painted frames.**
That is the claim the whole milestone rests on: a deep document costs what a
shallow one costs while the pen is down.

**Verified on device, 2026-08-30.** Cache rebuilds tick up once when the
selection moves — correct, since that changes which layers sit above and
below — and then stay frozen for every stroke afterwards. Painting cannot
dirty either cache, because the active layer is not part of either signature.
Frame cost was unchanged going from five layers to ten. Live layer count read
1 normally and 2 with a layer clipped to the active one, which is the clip
group refusing to be pre-flattened, exactly as designed.

Undo and redo were confirmed to target the layer that *owns* the edit rather
than whichever is selected, including undoing across a layer that was then
deleted — the case the stable `LayerId` design exists for.

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

## 🔨 M3 — Brush engine

Dab stamping, not ribbons. Round stroke caps arrive here, because a dab is a
disc.

| | |
|---|---|
| ✅ | Brush parameter model: shape, ink, dynamics, jitter, taper, path |
| ✅ | Stroke path in the engine: smoothing, Catmull-Rom, arc-length dab emission |
| ✅ | Dynamics: pressure, tilt and velocity onto size and flow |
| ✅ | Exact per-dab tile capture, replacing per-sample bounding boxes |
| ✅ | Brush and dabs across the C ABI, zero-copy into a Metal buffer |
| ✅ | Instanced dab stamping in Metal, procedural shape |
| ↪️ | Maximum and Buildup accumulation — **replaced by the ink model, see below** |
| ✅ | Colour picker — blocking several kinds of test, not just a feature |
| ✅ | Grain: a seamless procedural map, anchored to the canvas or to the stroke |
| ↪️ | ~~Grain as a threshold, not a multiply~~ — **wrong, reverted.** Grain is a cap on where ink may sit; see the grain section below |
| ✅ | Grain measured against Procreate and re-implemented as a coverage cap |
| ✅ | Accumulation re-cut as one Flow control, with the mode switch removed |
| ⬜ | Textured dab shapes on the same sampler |
| ⬜ | **Close the structural taxonomy gaps** — see *How complete is the brush definition* below. These change the shape of the data and get more expensive the later they land |
| ⬜ | Brush editor UI, and a starter set of manga brushes |
| ⬜ | Additive taxonomy gaps: the settings that are only more fields |
| ⬜ | Per-tile dab culling once the canvas is larger than the screen |

**Verified on device, 2026-09-01.** Round caps, curve smoothness at speed,
even weight along a long stroke, and undo returning a stroke identically — the
last confirming that seeded jitter does what it was designed for. Every Apple
Pencil Pro channel is live: pressure, tilt, azimuth, roll, hover, squeeze and
double-tap. Pressure drives width end to end, and `peak/fr` reads 4, which is
240 Hz sampling landing in a 60 Hz frame exactly as expected.

One hardware fact worth recording: **tilt tops out near 86°, not 90°**, and
loses both precision and refresh rate as the pencil approaches perpendicular.
A tilt response must not assume the full range is reachable.

**Stroke geometry moved out of Swift and into the engine.** Every bug that has
reached the device so far lived in the shell, invisible to the C++ suite, and
stroke geometry is pure arithmetic over plain numbers — there was no reason
for it to sit anywhere untestable. The Swift side now converts points to
pixels, forwards samples, and hands the dab array to a Metal buffer.

That move immediately paid for itself. **Curve smoothness used to be an
eyeball test on the device**; it is now four assertions. A quarter circle
described by nine samples — what a fast flick actually delivers — must produce
no turn sharper than 0.05 rad and no dab further than 2 px off the true arc.
The faceting bug from M0 could not survive that, and neither could a
regression in it.

**21,002 checks** across the engine suite, on Linux and Windows, in ~40 s.

### Grain

The grain map is **generated, not loaded**. That defers the asset-format
question to the brush editor, where it belongs, and it buys something an asset
file could not: the map is a pure function of a seed, so bit-identical grain
exists in the C++ suite, in the simulator harness, and on the device with
nothing crossing between them. It is what lets the Metal sampler be pinned
against the engine's own CPU sampler pixel by pixel.

Seamlessness is the part that had to be built in rather than tested for
afterwards: every octave's lattice is indexed modulo its own period, so the map
tiles by construction. Measured across the join, the step is **0.34** against
**3.16** for an average step inside the map — a seam smoother than the texture
around it. Butting two *different* grains together, which is what a
non-wrapping generator effectively produces at every tile boundary, gives
**55.6**. The test asserts both, so it cannot pass by having no teeth.

The two anchoring modes are not two textures, they are the question of what the
grain belongs to:

- **Canvas** anchors to the pixel, so every dab covering a pixel finds the same
  grain there. Under `Maximum` accumulation the grain is then exactly invariant
  to overlap, since max(g·c₁, g·c₂) = g·max(c₁, c₂). That identity is why it
  reads as paper the stroke is drawn on rather than as a pattern printed onto
  the stroke, and it is asserted directly in CI.
- **Rolling** anchors to the dab, scrolled by the arc length the engine records
  per dab, so the texture travels with the brush. It deliberately gives up that
  invariance — two dabs at one pixel are at different arc lengths — which is
  correct for dry media and wrong for paper.

**Verified in CI, not yet on device.** The shader's grain is compared against
`mc_grain_sample` over ~600 pixels of a dab's interior, worst difference within
3 of 255 — quantisation and the sampler's 8-bit sub-texel weights, not
disagreement. A flipped V or a missing half-texel misses by far more, and
neither is visible in a screenshot, which is the entire argument for testing it
this way.

### What the device found, and what Procreate says about it

Grain shipped and was tested on device the same day. It works, costs nothing
measurable — ~5 ms peak either way, indistinguishable from a Depth-0 stroke —
and tiles without a seam at every scale from 24 to 600 px. The maths held.

The *model* did not. Two findings, both from drawing with it rather than from
any test:

**Grain veils rather than bites.** Coverage is multiplied by the grain, so a
solid stroke becomes a uniformly mottled wash: the whole stroke goes lighter
instead of its edges going broken.

That observation was accurate and is left standing. ~~Real media does the
opposite — pigment catches the high points of the paper and misses the low ones,
which is a *threshold* against the grain, not a scaling by it.~~ **The inference
was wrong**, and it cost three implementations. Procreate was measured on
2026-09-08: canvas-anchored grain keeps its texture across the whole inked area,
permanently, however hard it is scrubbed — it veils, deliberately. The multiply
was the right mechanism and the objection to it was a mis-expectation. What
probably looked wrong was the *map*: fractal noise clustered near mid-grey reads
as a wash rather than as tooth, which is what Procreate's grain Brightness and
Contrast exist to fix, and which we still do not have.

**Flow and Opacity are redundant under Maximum.** Both scale the same final
alpha, so only their product matters, and getting build-up needs a mode switch
that neither Photoshop nor Procreate asks for.

[docs/procreate-brush-settings.md](docs/procreate-brush-settings.md) — a
transcription of Procreate's brush studio — confirms both, and names the
mechanisms:

- Grain composites through a **blend mode**, with brightness, contrast and a
  minimum depth. Multiply is one mode of many.
- ~~**Umbral alfa** (alpha threshold) with a threshold amount, in the Rendering
  section. That is the tooth-versus-veil control.~~ **Misread.** It is a toggle
  under Rendering, *off by default* in the very brush these settings were
  transcribed from, and it is not the grain mechanism at all. Building on this
  reading produced bug 14. Grain composites through the blend mode in its own
  section.
- There is **no Maximum/Buildup toggle**. Accumulation is a **rendering style**
  with six named values, and Flow is a "maximum level" rather than a slider.
- Our two grain anchoring modes match Procreate's exactly
  (Movimiento/Texturizado), which is the one part of the taxonomy that came out
  right — though Movement is also an *amount* there, where ours is locked 1:1
  to arc length.

The same document settles a question already open in this file: **Procreate's
pressure response is a graph widget**, so the exponent has to become a spline
before a brush editor exposes it. It is no longer a maybe.

### The ink model, after the device found the old one wrong

Both findings from the 2026-09-02 round are fixed, and the fix for the second
was not the obvious one.

**Flow is the build rate; Opacity is the strength.** The Maximum/Buildup switch
is gone, and it is not coming back — but the reasoning recorded here when it was
removed was only half right, so both halves are kept.

Right: the switch made Flow and Opacity redundant at one end, since both scaled
the same final alpha and only their product mattered. Wrong: ~~neither Photoshop
nor Procreate asks for a mode here.~~ Procreate asks for six — Light, Uniform,
Intense and Heavy **Glaze**, plus Uniform and Intense **Blending** — and
measurement on 2026-09-08 showed the distinction is real and large. At Opacity
25%, Light Glaze settles at 0.16 ink under twenty passes without lifting and
cannot be pushed past it, while both Blending styles saturate to solid black
against themselves.

What saves the decision is that **two independent sliders already span that
space.** Opacity multiplies the finished stroke once at composite, which is a
per-stroke ceiling — a Glaze. Flow accumulates per dab with no ceiling — a
Blending. So the switch really was redundant, for a reason that had not been
found yet when it was deleted.

**The obvious implementation of that destroys the antialiasing.** Simply always
accumulating means a pixel just outside the stroke's true edge picks up partial
coverage from every dab that passes near it; at 6% spacing that is roughly two
dabs per pixel, so it saturates to 1. The stroke bloats by a pixel and its rim
goes hard. Maximum existed precisely to prevent that, and deleting it takes the
antialiasing with it.

The fix is to stop conflating two things in one number:

| Channel | Blend | Carries |
|---|---|---|
| RGB | alpha-over | **Ink density** — how much pigment landed, so flow works |
| A | max | **Geometry** — the true antialiased silhouette |

Composited as `min(density, geometry)`, each property comes from the channel
that can express it. Metal splits blend state at the RGB/alpha boundary, so
this costs one pass and one texture exactly as the single-channel version did —
the coverage target goes from `r8Unorm` to `rgba8Unorm` and nothing else
changes. A CI test drives a dense row of dabs and asserts the edge is still
soft, because that regression would look like a slightly bolder brush rather
than like a bug.

**Grain thresholds rather than multiplies.** ~~Ink sticks where it has more to
give than the tooth takes: `(coverage − tooth) / (1 − tooth)`, clamped.~~
**Superseded 2026-09-03**, and the way it failed is the most useful thing in
this section, so it stays.

The paragraph that stood here ended: *"at Flow 100% the body is fully covered
and no tooth shows, so grain lives in the edges until Flow comes down… it makes
Flow the control that decides how much surface shows."* That reasoning was
right. It rested on one assumption nobody wrote down or checked — that Flow
**could** come down.

It could not. Flow was a per-dab alpha, and about seventeen dabs cover every
pixel at the default spacing, so Flow 50% accumulated to 0.99999 and Flow 75%
was indistinguishable from 100%. The stroke body was 1 for every setting a
person would actually use. A threshold against a coverage of 1 returns 1, which
is precisely the "no effect at 100%" the device reported — except it was no
effect at nearly *every* value, and the one place the tooth did bite was where
it punched permanent holes.

So all three grain attempts — multiply, per-dab threshold, and the geometry
channel that was next in line — failed for one reason that was never about
grain: **there was no partial coverage anywhere for a tooth to bite into.**
Bug 15 in TESTING.md is the fix; grain is now unblocked rather than solved, and
the third attempt waits on device confirmation that Flow means something first.

Two lessons, both cheap to state and expensive to have learned:

- The engine's tests all checked *geometry* — where dabs land, how large they
  are, which tiles they touch. None checked what a stroke was **worth**. Three
  device rounds went into the visible symptom while the cause sat in four lines
  of arithmetic that no test looked at.
- A design can be correct and still unreachable because a different component
  quietly forecloses it. The reasoning above was not wrong; it was written
  against a Flow control that did not exist.

~~Procreate's `Umbral alfa` is the same mechanism~~ — **wrong**, it is a
Rendering toggle, off by default in the brush the settings were transcribed
from. Grain there composites through a **blend mode** in its own section, and
that mode, plus brightness, contrast and minimum depth, is still ahead of us.

**Flow is what the finished stroke is worth.** A dab deposits
`1 − (1−flow)^overlap`, where overlap is one over the number of dabs covering a
point, so *n* dabs compose back to exactly `flow`. The alternative — leaving
Flow as a per-dab alpha and telling people to use small numbers — fails on the
second half of the bug: the accumulated result depends on Spacing, so the same
brush at 3% spacing came out about twice as dark as at 6%. Two controls that
look independent must not secretly multiply, or no brush preset survives being
edited. Flow 100% still yields alpha 1, so the default inking brush is
bit-identical to before.

### How complete is the brush definition

The goal is a brush definition that can express what Procreate's can. This
section exists because that goal was previously implied by one checklist line —
"brush editor UI, and a starter set of manga brushes" — which gives no sense of
the distance involved.

Measured against
[docs/procreate-brush-settings.md](docs/procreate-brush-settings.md), which is a
transcription of one real brush's studio:

| Section | Have | Partial | Missing | Total |
|---|---:|---:|---:|---:|
| Stroke path | 2 | 0 | 3 | 5 |
| Stabilization | 0 | 1 | 3 | 4 |
| Taper | 0 | 2 | 7 | 9 |
| Shape | 2 | 0 | 11 | 13 |
| Grain | 2 | 2 | 10 | 14 |
| Rendering | 0 | 1 | 8 | 9 |
| Dynamics | 3 | 1 | 1 | 5 |
| Apple Pencil | 1 | 1 | 7 | 9 |
| Properties | 1 | 1 | 3 | 5 |
| **Total** | **11** | **9** | **53** | **73** |

**15% complete, 12% partial, 73% missing.**

Read that number carefully, because it flatters us in one direction and is
unfair in another. Unfair: what exists is the load-bearing half — dab emission,
spacing, dynamics, jitter, the ink model and grain are the parts everything else
attaches to, and a brush with none of the missing settings still draws. Flatters
us: the count excludes **Wet mix** and **Colour dynamics** entirely, because
neither was tabulated, and together they are two whole subsystems we have not
started. And it is one brush — Procreate shows settings conditionally, so the
real surface is larger than 73.

#### Structural gaps versus additive ones

The distinction that matters for sequencing, and the reason this section is not
just a list. `core/include/core/brush.h` already says the taxonomy is the
expensive thing to change and the individual fields are cheap. So:

**Structural — these change the shape of the data or the pipeline, and every
one of them is cheaper before the brush editor exists than after, because an
editor is a UI built on top of whatever shape the data has:**

| Gap | Why it is structural |
|---|---|
| Pressure response as a **spline**, not an exponent | Procreate's is a graph widget. Four bytes of exponent cannot express a graph, and an editor exposing a curve control needs the real thing underneath |
| **Taper as a Vector2D**, split pressure versus touch | We have three scalars and no touch/pressure split. Two axes where we assumed one |
| Shape **Count** — N stamps per dab | Changes dab emission itself, not a field on a dab |
| **Per-dab colour**, for colour dynamics | `MCDab` carries no colour. Adding it is an ABI change and widens the GPU vertex struct |
| **Wet mix** — colour pickup | The dab must *read* the canvas under it. Nothing in the pipeline does that today; see docs/wet-mix-references.md |
| Grain **blend mode** | Grain currently caps coverage. A mode enum means the compositing step becomes a choice rather than a constant |

**Additive — more fields on structures that already exist, safe to land any
time, including after the editor:** spacing jitter, linear jitter, fade, the two
stabilisation mechanisms beyond StreamLine, grain brightness / contrast /
minimum depth / zoom / rotation, roundness by pressure and by tilt, speed →
spacing, and maximum / minimum opacity.

Grain brightness and contrast are additive but wanted early for a different
reason: the grain mechanism is now correct and the map probably is not, and
those two controls are how that gets judged at all.

#### The rule

**Structural gaps close before the brush editor ships. Additive ones may land
after it.** An editor is a view onto the data model; building it against a model
we already know is the wrong shape means building it twice, and the second time
is worse because presets will exist by then.

Checkable: re-run the count against `docs/procreate-brush-settings.md` and the
table above must match. When a setting lands, its marker moves there first and
this table follows.

### Decisions worth revisiting

- **Spacing is a fraction of dab diameter**, not an absolute distance, so a
  brush keeps its character when resized. Absolute spacing is the classic
  mistake: it turns a smooth small brush into a dotted line when scaled up.
- **Jitter is seeded and deterministic.** Undo re-runs a stroke, so jitter that
  differed between runs would make undo lossy.
- **Dynamics are named fields rather than a source/target matrix.** A matrix is
  more expressive on paper but evaluates a loop of mostly-disabled entries per
  dab and is harder to lay out in a UI, not easier.
- **The dab shape is procedural.** A textured dab slots into the same place
  later; a procedural disc has no sampling error at any size, which makes it
  the right thing to pin the engine against while the geometry is being proven.
  The sampler that shape textures will use now exists, built for grain — what
  is left is the shape map itself and the tile capture, which has to widen from
  the dab's radius to its corner once a stamp can put ink outside the disc.
- **Grain caps coverage per dab, not the finished stroke.** ~~Thresholds~~ —
  corrected 2026-09-08; the tooth multiplies a dab's coverage into the geometry
  channel and the maximum blend does the rest. Tinting the whole stroke once
  would be cheaper, but it cannot express rolling grain at all, and per-dab is
  the general mechanism a shape texture needs anyway. The per-dab choice was
  right throughout; only what it computed was wrong.
- **Coverage is two channels, not one.** Ink density and stroke geometry
  accumulate differently and cannot share a number — see below.
- **The response curve is an exponent, not a spline.** It covers ease-in,
  linear and ease-out in four bytes with no allocation, and every call site
  survives the swap. But a brush editor that exposes a curve control needs the
  spline, so this has to change before that ships rather than after.

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

- **No development machine at all.** No Mac, no PC, no local toolchain — the
  iPad running the app is the one it is written from. CI compiles; it cannot
  run Instruments or the Metal debugger.
  Compensated by keeping the engine platform-agnostic and testable off-device,
  by the in-app HUD, and by on-device logs.
- **~~10 App IDs per 7 days.~~** Resolved: the limit applies to registering
  *new* App IDs, and the pipeline reuses one static ID, so reinstalling is
  free. Installs now go straight onto the iPad with SideStore, no computer in
  the loop. Device tests are still batched, but because a person's attention is
  the scarce thing now, not the install — see [TESTING.md](TESTING.md).
- **60 Hz panel.** A 120 Hz latency target can only ever be validated on an
  iPad Pro.
