# Device test backlog

Installs are **no longer budgeted**. The 10-App-IDs-per-7-days limit on free
signing applies to *registering new* App IDs, and the pipeline reuses one
static ID (`com.octolex.mangachan`) for every build, so reinstalling costs
nothing. The 7-day certificate expiry still applies, and SideStore refreshes it
on device over WiFi.

Current pipeline, no computer in the loop: download the `.ipa` from the CI
artifact on the iPad, install with **SideStore + LocalDevVPN** against the
existing App ID.

**The rule stands anyway,** for a different reason: CI is faster and cheaper
than a person with an iPad, and it does not get bored. If it needs the GPU, the
Pencil, or the display, it goes on this list. Everything else gets a unit test
and never touches the iPad.

## Pending — colour and brush controls

| # | What | How | Expected |
|---|---|---|---|
| 51 | Colour | Drag in the square, then the hue strip, then draw | Ink matches the swatch; both drags track continuously |
| 51a | Brightness axis | Look at the square: top edge against bottom | Top is **bright**, bottom is dark. Was upside down |
| 51b | Drags are not scrolls | Drag across the square, then the hue strip, without lifting | Colour tracks the whole way; the panel does **not** scroll under the finger |
| 51c | Hue strip is smooth | Look along the strip | A continuous spectrum, not twelve flat bands |
| 52 | Size | Drag Size, draw | Stroke weight follows. 1 px stays a visible line |
| 53 | Opacity | Set ~30%, Flow 100%, draw a stroke that crosses itself | Translucent, and the crossing is **not** darker |
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
| 61 | Depth reads as tooth | Depth ~70%, **Flow ~50%**, draw slowly | Tooth showing through the body of the stroke, and a broken edge. At Flow 100% only the edges break — see #74 |
| 62 | Scale | Scale from 24 px to 600 px, draw at each | Fine tooth through to coarse blotches. No repeating grid at any setting |
| 63 | Canvas grain ignores the stroke | Canvas mode, cross a stroke back over itself | The texture in the crossing matches its surroundings — it belongs to the paper |
| 64 | Rolling grain follows the stroke | Rolling mode, same crossing | The crossing **does** show. Both directions carry their own grain |
| 65 | Grain costs no frame budget | Depth 100%, long fast stroke, watch `gpu` | Flat, and level with a Depth-0 stroke |
| 66 | Grain survives commit and undo | Draw grained, lift, undo, redo | Returns identical — the map is seeded, not random |
| 67 | Prediction is grained too | Depth 100%, draw fast, watch the leading tip | The tip ahead of the pen is textured, not a smooth lead-in that turns rough |

## Pending — from the 2026-09-02 round

| # | What | How | Expected |
|---|---|---|---|
| 68 | 1 px stroke is visible | Size to 1 px, draw; then 2 px | A visible line at 1 px. Was invisible at 1, barely visible at 2. Density now accumulates across the ~2 dabs that land per pixel, which may resolve it with no special case |
| 74 | Grain reads as tooth | Depth ~70%, draw at a few Flow values | Texture in the stroke that still leaves a coherent line. **Failing** — see bug 14. Blocked behind #77: there is nothing for a tooth to bite into until Flow leaves a stroke partly transparent |
| ~~76~~ | ~~How opaque is a Flow-50% pass?~~ | — | **Answered 2026-09-03: effectively solid.** Only ~10% was visibly translucent. That is bug 15, and it is why every grain attempt failed |
| 77 | Flow means what it says | Depth 0. Draw single non-crossing strokes at Flow 25%, 50%, 75% | Three clearly different strengths, roughly a quarter, half and three quarters. Before this change 50% and 75% were both solid black |
| 78 | Flow no longer moves with Spacing | Flow 50%, draw. Set Spacing to about half what it was, draw again | The two strokes are the same darkness. Previously halving the spacing made the same brush markedly darker |
| 79 | Crossings still build | Flow 25%, draw a loop that crosses itself once | The crossing is clearly darker than either line through it — the behaviour the 10% panel showed, kept |
| 80 | Full flow is unchanged | Flow 100%, draw and cross | Solid, and the crossing exactly as dark as the line. This is the default inking brush and it must not have moved |

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
- **Grain does not currently work.** It is thresholded per dab, which at Flow
  100% does nothing and at 50% masks the stroke away. This *was* listed here as
  deliberate; it is not, it is bug 14. #76 has now answered why, and the answer
  was not what the entry assumed: the fault is not only *where* the threshold
  is applied but that Flow left nothing partly transparent to threshold. See
  bug 15. Leave Depth at 0; nothing else is affected.
- **No Maximum/Buildup switch.** Flow is the control: at 100% a pass saturates
  and crossings do not darken; below that they build. The switch made Flow and
  Opacity redundant at one end, which is what it was removed for.
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
| 2026-09-02 | Grain tiles seamlessly, Metal sampler matches the reference | Pass, in CI |
| 2026-09-02 | Install straight onto the iPad, no computer in the loop | Works. Method not yet recorded — the budgeting rule at the top of this file may be stale |
| 2026-09-02 | #50 Brush panel opens | Pass, but with three rendering/gesture bugs — see 7-9 |
| 2026-09-02 | #58 Panel does not leak touches to the canvas | Pass |
| 2026-09-05 | Procreate A — does one stroke accumulate against itself? | **Yes.** A single crossing darkens; many crossings go solid. Our model is right on this axis |
| 2026-09-05 | Procreate B — Renderizado→Flujo at 100% vs 0% | Both strokes clearly present, second lighter and softer. Not a coverage alpha; do not map it to our Flow |
| 2026-09-05 | Procreate C — does darkness move with Spacing? | **Invalid test, my design fault.** Ran from no-overlap to some-overlap, where both models predict the same thing. See C-redo |
| 2026-09-05 | Procreate D — grain under repeated scrubbing | **Rolling fills in solid; Canvas persists forever.** Depth controls body coverage. Low opacity does **not** show more texture |
| 2026-09-05 | Procreate E — wet mix across a contrasting colour | Drags the underlying colour along. Mixed region reads grey, so the mixing looks like plain RGB |
| 2026-09-03 | #76 Flow 50% with Depth 0 — is one pass half strength or solid? | **Solid.** Only ~10% reads as translucent. Answers bug 14 and opens bug 15 |
| 2026-09-03 | #76 Flow 10%, self-crossing stroke | Translucent, and the crossing visibly darker — build-up works, the scale does not |
| 2026-09-02 | #60 Grain Depth at 0 is indistinguishable from before grain | Pass |
| 2026-09-02 | #61 Depth ~70% textures the stroke and lightens it | Pass, but see bug 10 — it veils rather than bites |
| 2026-09-02 | #62 Scale sweep 24-600 px, no repeating grid at any setting | Pass — the seam maths holds on device |
| 2026-09-02 | #63/#64 Canvas vs Rolling grain across a self-crossing | Pass |
| 2026-09-02 | #65 Grain costs no frame budget | Pass — ~5 ms peak with and without, difference lost in noise |
| 2026-09-02 | #66 Grain survives commit and undo | Inconclusive by eye; deterministic by construction |
| 2026-09-02 | #53 Opacity 30%, self-crossing not darker | Pass, but see bug 11 |
| 2026-09-02 | #54 Buildup darkens the crossing, Maximum stops it | Pass |
| 2026-09-02 | #55 Hardness 0% gives a soft edge | Pass |
| 2026-09-02 | #56 Stabilization 0% vs 60% | Pass |
| 2026-09-02 | #57 Spacing toward 50% separates the dabs | Pass |
| 2026-09-02 | #59 Every slider survives its own drag | Pass |
| 2026-09-02 | #38 Blend list scroll survives a rebuild | Pass |
| 2026-09-02 | #37 Layer list scroll survives a rebuild | Pass, once bug 12 was fixed |
| 2026-09-02 | #69 Both panels clear the toolbar, add-layer reachable | Pass |
| 2026-09-02 | #70 Toolbar swallows its own touches, gap included | Pass — the coordinate-space change held |
| 2026-09-02 | #71 Flow 100% does not self-darken | Pass |
| 2026-09-02 | #72 Flow ~40% builds up on a crossing | Pass — no mode switch needed |
| 2026-09-02 | #73 The stroke edge stays soft under density accumulation | Pass — the two-channel split holds on device |
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

7. **The brightness axis was drawn upside down.** A `drawRect` context is
   y-flipped relative to Core Graphics, so a CGImage drawn through
   `context.draw(_:in:)` renders inverted. The touch mapping was never wrong,
   so the picker returned the colour you asked for and displayed a different
   one — the worst way for a colour picker to fail, because the swatch and the
   square disagreed and only the square was being read.
8. **The scroll view ate the picker's drags.** A UIScrollView cancels content
   touches the moment it decides a finger is panning. That is right for a list
   of rows and exactly wrong for a colour square, where the drag *is* the
   interaction: the control got a touch, one move, then `touchesCancelled`, so
   the colour ticked once and the panel slid away underneath.
9. **The hue strip was twelve flat rectangles.** The code claimed the eye
   could not resolve banding on a 26pt strip. It plainly could. Worse, each
   band painted the hue at its own left edge while a tap anywhere inside it
   selected the hue under the finger, so the strip could be up to a twelfth of
   the spectrum away from what it would actually give you.

10. **Grain veils the stroke instead of biting into it.** Coverage is
    multiplied by the grain, so a solid stroke becomes a uniformly mottled
    wash — the whole stroke goes lighter rather than the *edges* going broken.
    Real media does not work that way: pigment catches on the high points of
    the paper and misses the low ones, which is a *threshold* against the
    grain, not a scaling by it. Procreate has this as an explicit control
    (Umbral alfa / alpha threshold) — see docs/procreate-brush-settings.md.
    Not yet fixed; it is a taxonomy change, not a patch.
11. **Flow and Opacity are redundant under Maximum accumulation.** Both end up
    scaling the same final alpha, so only their product matters, and reaching
    build-up behaviour needs an explicit mode switch that Photoshop and
    Procreate both manage without. Procreate expresses accumulation as a
    six-value *rendering style* with Flow as a ceiling. Not yet fixed.
12. **The layers panel opened underneath the brush button.** Each panel was
    anchored below the button that opened it, and the brush button sits below
    the layers button — so it drew on top of the layers panel's own header and
    covered "add layer". Both panels now hang below the toolbar as a whole,
    which also means a third button cannot reintroduce it.
13. **A 1 px stroke is invisible.** At that size the dab is smaller than the
    antialiased edge that draws it, so almost all of its coverage is falloff.
    Not yet fixed.

14. **Grain thresholding was the wrong fix.** Replacing the multiply with
    `(coverage - tooth) / (1 - tooth)` made it worse, not better: at Flow 100%
    it does nothing, and at 50% it masks the stroke away. The reason is that
    the threshold is applied per dab, so a pixel whose tooth stands higher than
    the flow is punched to zero by *every* dab and can never fill — permanent
    holes, where real paper fills in as you work over it.
    The reading that led there was also wrong. Procreate's **Umbral alfa** is a
    toggle in Rendering, not the grain mechanism, and it is *off* by default;
    grain there composites through a blend mode in the Grano section. That was
    a misread of docs/procreate-brush-settings.md, not a subtlety.
    **#76 answered this on 2026-09-03**, and the Procreate experiments on
    2026-09-05 answered the rest. The threshold is wrong at every level: grain
    does not vary with opacity in Procreate at all, which a threshold against
    accumulated coverage would make it do dramatically.
    What grain actually is: the tooth **multiplies** a dab's coverage before the
    maximum blend that builds the silhouette. Canvas-anchored, the tooth is the
    same for every dab, so the pits never fill however many passes cross them.
    Rolling, it shifts with arc length, so each pass puts its pits elsewhere and
    the stroke fills to solid. Both behaviours were observed in Procreate, and
    one mechanism gives both with no mode-specific code.
    That is what **attempt #1 already did**. It was rejected on device as "a
    uniform veil", and that objection is now falsified: Procreate's canvas grain
    does keep texture across the whole inked area, permanently. The fault was
    most likely the map rather than the maths — our four-octave fractal noise
    sits near mid-grey and reads as a wash. Procreate exposes Brightness and
    Contrast on the grain for exactly this reason. Not yet fixed.

15. **Flow was a per-dab alpha, not what the stroke is worth.** Dabs land a
    fraction of a diameter apart, so at the default 6% spacing about seventeen
    of them cover every pixel. A per-dab alpha of 0.5 therefore accumulated to
    `1 - 0.5^17` — 0.99999, solid black. Measured on device: Flow 50% and 75%
    are indistinguishable from 100%, and only around 10% is visibly
    translucent. The slider was a switch with a very short throw.
    Worse, its meaning moved with Spacing. The same brush at 3% spacing was
    about twice as dark, so two settings that look independent secretly
    multiplied, and no brush preset could survive a spacing change.
    Fixed by inverting the accumulation: a dab deposits
    `1 - (1-flow)^overlap`, where overlap is one over the number of dabs
    covering a point, so *n* of them compose to exactly `flow`. Flow 100% still
    gives alpha 1, so the default inking brush is untouched. Crossings still
    darken, which the device round explicitly asked to keep.
    Pinned by four tests in `test_stroke.cpp`, including one that holds the
    result flat across an eight-fold spread of spacings.
    **This is also the whole reason grain never worked.** Bugs 10 and 14 were
    both read as grain problems and neither was: a tooth can only bite into
    coverage that is less than 1, and Flow was not producing any.

Every one of these but 15 lived in how the shell drove the engine — layout and view lifecycle, not logic — which is the argument for
pushing more behind the C ABI where CI can reach it. Note the shape they share:
none are arithmetic, all are UIKit rebuilding, sizing or re-orienting something
at the wrong moment.

12 is the same shape as the rest — a frame computed against the wrong thing.
10, 11, 13 and 15 are not: they are design errors in what the brush *means*,
which is a category this project had not hit before and which no amount of
UIKit discipline would have caught.

15 breaks the pattern in a way worth keeping visible, because the old claim
here was that the engine had been correct throughout and every device bug had
lived in the Swift shell. That is no longer true. It is also the least
surprising place for it to stop being true: the engine's tests all checked
*geometry* — where dabs land, how big they are, which tiles they touch — and
none of them checked what a stroke was worth once the dabs were composited.
A property no test asserts is a property nobody is defending, and the
arithmetic that broke it is four lines long and was never wrong on its own
terms. It answered a question nobody had asked out loud.

7 and 9 are now assertions in `ColorPickerTests`: the picker is rendered into a
bitmap and read back, so an inverted axis or a banded strip fails in CI. 8 is
not, and cannot easily be — it needs a real gesture recogniser arbitrating a
real touch sequence, so it stays a device test (#51b).
