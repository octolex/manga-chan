# Device test backlog

Installs are **no longer budgeted**. The 10-App-IDs-per-7-days limit on free
signing applies to *registering new* App IDs, and the pipeline reuses one
static ID (`com.octolex.mangachan`) for every build, so reinstalling costs
nothing. The 7-day certificate expiry still applies, and SideStore refreshes it
on device over WiFi.

Current pipeline, no computer in the loop: every build publishes a GitHub
release, and the **SideStore** source picks it up, so an update arrives as a tap
(since 2026-09-08; before that the `.ipa` was downloaded from the CI artifact by
hand). Check the HUD's `app 0.3.n (n)` line before anything else in a round.

**The rule stands anyway,** for a different reason: CI is faster and cheaper
than a person with an iPad, and it does not get bored. If it needs the GPU, the
Pencil, or the display, it goes on this list. Everything else gets a unit test
and never touches the iPad.

## Next round — start here

Written 2026-09-23 for **observation mode**: draw, and say what looks wrong.
The long tables below are the record, not a checklist. Five things matter more
than the rest, because they change what the app *does* and none has been seen
on a device:

1. **Grain** — tests 81–83. Set Contrast to about **+70%** first; at Contrast 0
   our map is 90.1% mid-grey and reads as a veil for a reason already measured.
   Canvas grain should survive twenty passes; rolling grain should fill in.
2. **Opacity builds now, and it builds far too fast.** Expect a single stroke
   at 25% to look almost solid. That is bug 21, found on review, and it is not
   what Procreate does — its single pass at 10% measured 3–9% ink, ours gives
   41–99%. No need to report it; *do* say whether it makes the app unusable
   before the fix, because that decides the order of the next work.
3. **The side swap** — controls on the left by default, the arrow button moves
   everything, and it survives a relaunch.
4. **Sliders on a white canvas** — visible now, or not.
5. **The measurement for bug 21**, whenever there are ten minutes for Procreate.
   It is at the end of `docs/procreate-experiments.md`: read the Studio Pen's
   pressure settings, then four single strokes at 10 / 25 / 50 / 100% and one
   light-pressure stroke at 25%, eyedropper B on each. Five numbers.

## Pending — colour and brush controls

| # | What | How | Expected |
|---|---|---|---|
| 51 | Colour | Drag in the square, then the hue strip, then draw | Ink matches the swatch; both drags track continuously |
| 51a | Brightness axis | Look at the square: top edge against bottom | Top is **bright**, bottom is dark. Was upside down |
| 51b | Drags are not scrolls | Drag across the square, then the hue strip, without lifting | Colour tracks the whole way; the panel does **not** scroll under the finger |
| 51c | Hue strip is smooth | Look along the strip | A continuous spectrum, not twelve flat bands |
| 52 | Size | Drag Size, draw | Stroke weight follows. 1 px stays a visible line |
| ~~53~~ | ~~Opacity~~ | — | **Withdrawn 2026-09-23.** It expected a crossing that does not darken, which is Glaze behaviour; the default became Blending on 2026-09-09 and crossings now darken on purpose. Left standing, it would have reported the fix as a fault. #95 covers Glaze |
| 55 | Hardness | Take it to 0%, draw | Soft airbrushed edge rather than a hard rim |
| 56 | Stabilization | 0% then ~60%, draw the same shaky line | Visibly steadier, at the cost of lag behind the pencil |
| 57 | Spacing | Raise toward 50%, draw slowly | Dabs separate into a chain — confirms spacing is real |
| 58 | Panel does not leak touches | Draw a stroke starting on the panel | Nothing appears underneath it |
| 59 | Sliders survive their drag | Drag each one edge to edge without lifting | Tracks the whole way, value updates live |

## Pending — grain

**Set Contrast to about +70% before running any of these.** Measured
2026-09-10: 90.1% of our grain map sits between 0.2 and 0.8, so at Contrast 0 it
multiplies coverage by a near-uniform mid-grey and reads as a wash rather than
as tooth — which is exactly the complaint that killed the first grain attempt,
and it was the map rather than the mechanism. Full contrast takes that 90.1% to
14.3%. Running these at Contrast 0 would burn a round on a cause we have already
found.

CI already pins the grain arithmetic against the engine's CPU sampler, so what
is left here is only what a test cannot see: whether it looks like paper, and
whether it costs a frame.

| # | What | How | Expected |
|---|---|---|---|
| 60 | Depth off is off | Grain Depth at 0, draw | Identical to a stroke before grain existed — flat, no lightening |
| 61 | Depth reads as tooth | Depth ~70%, Flow 100%, draw slowly | Tooth showing through the **body** of the stroke, not only its edges. Rewritten 2026-09-08: grain is now a cap on coverage, so it no longer depends on Flow being below 100% |
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
| 74 | Grain reads as tooth | Depth ~70%, **Contrast +70%**, draw at a few Flow values | Texture in the stroke that still leaves a coherent line, at **every** Flow. Reimplemented 2026-09-08 as a coverage cap and **still never seen on a device** — v0.3.80 was never tested, so this carries forward unchanged |
| 81 | Canvas grain never fills in | Grain Behaviour **Texture**, Depth 100%, **Contrast +70%**, scrub one patch ~20 times | Texture survives however hard it is worked. Matches Procreate |
| 82 | Rolling grain does fill in | Grain Behaviour **Movement**, same Depth and Contrast, same scrub | Goes solid. The only difference from #81 is arc-length offset, and one mechanism produces both |
| 83 | Depth only changes the gaps | **Contrast +70%**, then Depth 50% and 100%, one stroke each | Gaps darker at 50%, lighter at 100%. The pattern must not move, rescale or change shape |
| 84 | The build says which build it is | Open the HUD | `app 0.3.<n> (<n>)` with the two numbers **equal** — that is the whole check. Never `MISMATCH`, never `local build`. Check it before anything else in a round: every finding below is worthless if it came from the wrong build |
| ~~76~~ | ~~How opaque is a Flow-50% pass?~~ | — | **Answered 2026-09-03: effectively solid.** Only ~10% was visibly translucent. That is bug 15, and it is why every grain attempt failed |
| 77 | Flow means what it says | Depth 0. Draw single non-crossing strokes at Flow 25%, 50%, 75% | Three clearly different strengths, roughly a quarter, half and three quarters. Before this change 50% and 75% were both solid black |
| 78 | Flow no longer moves with Spacing | Flow 50%, draw. Set Spacing to about half what it was, draw again | The two strokes are the same darkness. Previously halving the spacing made the same brush markedly darker |
| 79 | Crossings still build | Flow 25%, draw a loop that crosses itself once | The crossing is clearly darker than either line through it — the behaviour the 10% panel showed, kept |
| 80 | Full flow is unchanged | Flow 100%, draw and cross | Solid, and the crossing exactly as dark as the line. This is the default inking brush and it must not have moved |

## Pending — the 2026-09-09 round (sliders, quick bar, panel)

New controls, so these are first sightings rather than regressions. #85–#87 are
the ones worth care: the scrubbing arithmetic is tested off-device, but whether
it *feels* like Procreate's is the part no test can answer.

| # | What | How | Expected |
|---|---|---|---|
| 85 | A slider drags 1:1 on the track | Any slider. Drag along it with your finger roughly on the track | The thumb stays under the finger. Nothing feels heavy or laggy — within 24 pt of the track the rate is exactly 1:1, and if ordinary dragging feels slowed, that is a bug |
| 86 | Moving away buys precision | Press a slider, then slide your finger **sideways off** the track — about a thumb's width — and keep dragging along | The value moves about **half** as fast. Two thumb-widths out, a quarter. The thumb no longer tracks the finger, which is correct: the finger has travelled further than the value has |
| 87 | The precision is not thrown away on the way back | Do #86, land on a value you want, then bring the finger back toward the track before lifting | The value **stays**. The thumb must not snap back under the finger — snapping would discard exactly the precision the detour bought. Then lifting must not move it either: that finger-roll problem is the whole reason this exists |
| 88 | Tapping a slider does nothing | Tap a slider anywhere away from the thumb | Nothing moves. Deliberate: at these sizes a jump-to-tap would throw the value across the range on first contact. If you want jump-to-tap back, say so — it is a one-line policy, not a rebuild |
| 89 | Scrubbing survives inside the panel | Open the brush panel, scroll it, then drag a slider **sideways** out of the track | The panel must not steal the gesture and cancel the drag. A sideways drag inside a scrolling panel looks exactly like a scroll, and this is bug 8's shape |
| 90 | The quick bar sits where a hand can use it | Draw normally for a few minutes with the bar on the right | Honest answer wanted, not a pass: does your palm cover it? Procreate puts these on the **left** for right-handers for that reason. The side is a property (`BrushQuickBar.edge`), so switching the default costs one line — but which default is right is your call, not a code question |
| 91 | Size runs fine at the small end | Quick bar, set size near the bottom of the track, then near the top | The bottom half of the track covers roughly 1–100 px and the top half 100–400. Deliberate: the curve is squared so 1–20 px, where every pixel shows, gets most of the travel instead of a few millimetres |
| ~~92~~ | ~~Opacity is a ceiling, not a per-dab strength~~ | — | **Withdrawn 2026-09-09 before it was run.** It predicted a crossing that does not darken at Opacity 50%, which was our behaviour and not Procreate's. See bug 18; replaced by 94–96 |
| 93 | The panel shows everything | Open the brush panel | Folding sections, Shape open and the rest closed. Every parameter the engine has is reachable. **Pressure response is the exception** — the curve exists and is tested, but there is no graph widget to draw it with yet, so it shows as a plain control |

## Pending — the 2026-09-09 fixes (opacity, handedness, contrast)

Four device reports came back on v0.3.88 and all four were right. These check
the fixes, and #94 is the one that matters: it is a change to what the app
*does*, not to how it looks.

| # | What | How | Expected |
|---|---|---|---|
| 94 | Opacity builds, like Procreate's | Opacity **25%**, Flow 100%, Blending. First **one single stroke**. Then scribble a patch ~20 times without lifting | The scribble reaches solid — no ceiling, which is the family fix. **The single stroke will also look nearly solid, and that is wrong**: bug 21. Rewritten 2026-09-23 — as first written this test only checked the scribble, which ours saturates in one pass, so it could not have failed |
| 95 | Glaze still settles | Brush panel → Rendering → **Glaze**. Same 25%, same 20-pass scribble | It stops well short of solid and stays there. Then lift and lay five more strokes over it: *those* go darker. That is the other family, kept, and it is what Procreate's Light Glaze measured at (0.16 ink, then 0.60 after five more) |
| 96 | Full opacity is unchanged | Opacity **100%**, draw and cross. Then switch Blending/Glaze and repeat | Identical in both, and identical to v0.3.88. At 100% the two families are the same brush — asserted in CI, checked here because it is what made the default change safe for every existing brush |
| 97 | Opacity goes properly low | Quick bar, drag Opacity to the bottom | It reaches **1%**, and the readout shows a decimal below 10% (`3.5%`, not `3%`). A very light stroke should be visible but faint. The old floor was 2%, set when Opacity was a ceiling and anything under a few percent was invisible |
| 98 | The sliders are visible on white | Clear to a white canvas. Look at the quick bar | Track, fill and thumb all clearly visible. Then draw a solid black patch behind them and look again — **both** must work. Every layer is a light fill with a dark outline for exactly this reason |
| 99 | Controls default to the left | Fresh launch | Toolbar, quick bar and panels all on the **left**; the HUD moves to the right to stay out of their way |
| 100 | The swap moves everything | Tap the arrow button under the brush button | The whole chrome crosses to the other edge — toolbar, quick bar, and the panels open the other way — and the HUD swaps with it. Kill the app and relaunch: it stays where you put it |
| 101 | Drawing still stops at the chrome | With the controls on the left, drag the Pencil across the quick bar and the toolbar | No stroke is drawn under them. This is bug 12's shape and the frames all moved, so it is worth thirty seconds |

## Pending — the 2026-09-10 round (grain brightness and contrast)

New controls, in the brush panel under Grain. They exist because of one
measurement: **90.1% of our grain map sits between 0.2 and 0.8**, and full
contrast takes that to 14.3%.

| # | What | How | Expected |
|---|---|---|---|
| 102 | Contrast turns the wash into tooth | Depth 100%, Contrast **none**, one stroke. Then Contrast **+100%**, one stroke beside it | The first is an even grey veil over the whole stroke. The second has distinct pits with ink between them. **If the first one already looks like tooth, say so** — it would mean the map is better than the measurement suggests and these controls are less urgent than I think |
| 103 | Contrast keeps the pattern, only harder | The two strokes from #102, side by side | A speck that is dark in one is dark in the other. Contrast must open the *same* pattern out, never move or rescale it — that is the same property Depth has to have (#83), and for the same reason: anything that changes the sampling coordinate is a different bug |
| 104 | Brightness shifts without changing the texture | Contrast **+70%**, Depth 100%. One stroke at Brightness **none**, one at **+40%**, one at **−40%** | More ink at +40% (the tooth is higher, so more of the stroke is allowed through) and less at −40%. The *grain* should look the same in all three — same pit positions, same crispness. Brightness moves the whole map, it does not re-texture it |
| 105 | Neutral is genuinely nothing | Depth 100%, both controls at **none** | Identical to what v0.3.92 drew. Both readouts say `none`, not `0%`. CI asserts this to the pixel on both sides of the ABI, so a visible difference here is a real finding |
| 106 | Grain still costs no frame | Depth 100%, Contrast +100%, long fast stroke, watch `gpu` | Flat, and level with a Contrast-none stroke. The levels are four instructions on a value already fetched, so this should not be measurable — if it is, that is worth knowing |

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
  there is nothing to switch between until the brush library exists. Depth,
  Scale, Brightness and Contrast are the whole of the control surface.
- ~~**Grain does not currently work.**~~ Struck out 2026-09-09, and kept here
  rather than deleted because the entry itself was the fault. It said grain was
  thresholded per dab and told the reader to leave Depth at 0 — which is exactly
  how a wrong "deliberate" entry does its damage: it argues someone out of
  reporting the thing it describes. Grain was rewritten on 2026-09-08 as a
  coverage **cap** rather than a threshold, and has never been seen on a device
  since. **Do not leave Depth at 0.** Tests 74 and 81–83 are the ones that
  settle whether the rewrite worked; nothing here predicts their outcome.
- **No Maximum/Buildup switch.** Flow is the control: at 100% a pass saturates
  and crossings do not darken; below that they build. The switch made Flow and
  Opacity redundant at one end, which is what it was removed for. Since
  2026-09-09 Opacity builds too, in the default **Blending** style; **Glaze**,
  in the brush panel under Rendering, is the family that caps a stroke.
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
| 2026-09-06 | Procreate 1 — four spacings at Opacity 10%, single brush | Each stroke darker than the last, but **all four stay pale**. Neither prediction: uncompensated wanted a ramp into black |
| 2026-09-06 | Procreate 1b — eyedropper brightness of those four strokes | **B = 98, 95, 93, 92.** Ink alpha 0.02 / 0.05 / 0.07 / 0.08. **Both models refuted**: compensated needs alpha constant (varies 4x), uncompensated needs alpha-per-dab constant (varies 2.8x) |
| 2026-09-06 | Procreate 1b — implication | At Opacity 10% the darkest stroke reaches 8% ink. Either the slider is far from literal or the eyedropper dilutes thin strokes. Test 0 settles which |
| 2026-09-08 | Procreate 0 — eyedropper on solid black | Reads **B = 1, not 0**. A fixed +1 offset, not area averaging: a large flat blob reads 1 too. Re-picking and repainting drifts +1 per round trip |
| 2026-09-08 | Procreate 5 — Intense Blending, Opacity 25% | Continuous scribble **B = 1** (solid). Five separate strokes **B = 0**. No ceiling: a stroke saturates against itself |
| 2026-09-08 | Procreate 5 — Uniform Blending, Opacity 25% | Continuous **B = 5**, separate **B = 1**. Same family, gentler |
| 2026-09-08 | Procreate 5 — **Light Glaze, Opacity 25%** | Continuous **B = 85** (0.16 ink) — twenty passes cannot exceed it. Separate strokes **B = 41** (0.60 ink). Six strokes of 0.16 composited predict 0.65. **Per-stroke ceiling confirmed** |
| 2026-09-08 | Procreate 1 — reinterpreted with a spacing floor | Correct for a minimum dab spacing and per-dab alpha is 0.0051 / 0.0056 / 0.0042 / 0.0047 — constant. **Uncompensated**, and bug 15's fix was wrong |
| 2026-09-06 | Procreate 2 — grain scrub, Texture mode, single brush | Texture survives any amount of scrubbing. Never solid. **Confirms round 3 without the double brush** |
| 2026-09-06 | Procreate 2 — grain scrub, Movement mode | Fills in to a solid stroke |
| 2026-09-06 | Procreate 2 — Depth 50% vs 100% | Only how darkly the gaps are masked. Pattern static: no change of shape, scale or position |
| 2026-09-06 | Procreate 3 — Load at 1% vs 100%, long strokes | **Neither fades along its length.** Load is a per-dab ceiling scaled by pressure, not a depleting reservoir |
| 2026-09-05 | Procreate A — does one stroke accumulate against itself? | **Yes.** A single crossing darkens; many crossings go solid. Our model is right on this axis |
| 2026-09-05 | Procreate B — Renderizado→Flujo at 100% vs 0% | Both strokes clearly present, second lighter and softer. Not a coverage alpha; do not map it to our Flow |
| 2026-09-05 | Procreate C — does darkness move with Spacing? | **Invalid test, my design fault.** Ran from no-overlap to some-overlap, where both models predict the same thing. See C-redo |
| 2026-09-05 | Procreate D — grain under repeated scrubbing | **Rolling fills in solid; Canvas persists forever.** Depth controls body coverage. Low opacity does **not** show more texture. ⚠️ Run on a **double brush** — repeat on a single before acting |
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
    **Status 2026-09-23:** the threshold reading here was wrong — see 14. The
    multiply this entry rejects was right. What looked like a veil was the map:
    90.1% of it sits between 0.2 and 0.8 (measured 2026-09-10), and grain
    Contrast now exists to open it out. Awaiting device confirmation (81–83).
11. **Flow and Opacity are redundant under Maximum accumulation.** Both end up
    scaling the same final alpha, so only their product matters, and reaching
    build-up behaviour needs an explicit mode switch that Photoshop and
    Procreate both manage without. Procreate expresses accumulation as a
    six-value *rendering style* with Flow as a ceiling. Not yet fixed.
    **Status 2026-09-23: fixed.** The switch was removed when density got its
    own channel, which made Flow and Opacity independent, and rendering style
    arrived as a brush field on 2026-09-09 (bug 18).
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
    the map rather than the maths — **measured 2026-09-10: 90.1% of the map sits
    between 0.2 and 0.8**, where this once said "most likely". Our four-octave
    fractal noise
    sits near mid-grey and reads as a wash. Procreate exposes Brightness and
    Contrast on the grain for exactly this reason.
    **Fixed 2026-09-06**, after the same three findings were reproduced on a
    single brush — the round 3 results came off a double brush, which stacks two
    grain sources into one stamp and could have produced them artificially. The
    tooth now multiplies a dab's coverage into the geometry channel, where the
    maximum blend makes canvas grain permanent and lets rolling grain fill in,
    and `grain_threshold` is gone. Awaiting device confirmation.

15. **Flow saturates in one pass, and the fix committed for it was wrong.**
    ~~Flow was a per-dab alpha, not what the stroke is worth.~~ **Reverted
    2026-09-08.** The symptom was real and the diagnosis was not.
    What was measured: at the default 6% spacing about seventeen dabs cover
    every pixel, so a per-dab alpha of 0.5 accumulates to 1 - 0.5^17, and Flow
    50% draws solid black. All true. The conclusion drawn — that Flow should be
    inverted so a stroke finishes at the value asked for — matched neither
    reference. Photoshop's Flow is an uncompensated per-dab alpha, and so is
    Procreate's: four strokes at one Opacity across an eight-fold range of
    Spacing came out at 0.03, 0.06, 0.08 and 0.09 ink, where compensation
    requires them to be equal.
    The real gap was that `opacity` **already** does the job and was not being
    treated as the control that does it. It multiplies the finished stroke once
    at composite, so it caps what a stroke reaches however much it overlaps
    itself. Flow is the build rate; Opacity is the strength. Procreate agrees
    loudly by putting Opacity on the main screen and Flow inside Brush Studio.
    Flow's useful range really is the bottom fifth of its slider. That is a
    property of the medium, not a bug, and if it proves awkward the fix is a
    curve on the slider rather than a change to the meaning of the number.
    Two rounds of device testing went into a symptom whose cause was a control
    we already had.

16. **SideStore kept offering an old version.** Reported on 2026-09-08 with
    v0.3.78 already published: the source loaded and the app appeared, but at a
    stale version. The origin was correct — the same URL fetched from CI's
    network returned 0.3.78 — so nothing was wrong with what we published.
    Measured cause: a GitHub **release asset sends no `Cache-Control` and no
    `Expires`**. With neither header a client cannot know how long the file
    stays fresh, so it applies *heuristic* freshness instead, and how long a
    stale copy survives becomes unpredictable and can run to hours. The
    response also came back `X-Cache: HIT` with an `Age` of 2984 seconds,
    confirming a caching layer in the path. A release asset is built to be
    immutable; using one as a file that changes every build was the error.
    Fixed by publishing the source to `raw.githubusercontent.com`, measured the
    same day as sending `cache-control: max-age=300` and an ETag. Bounded and
    predictable. The release asset is still written so the old URL does not
    start 404ing, but it is no longer what anything advertises.
    **Requires one action: re-add the source in SideStore at the new URL.**

17. ~~**Flow was a per-dab alpha, not what the stroke is worth.**~~ Dabs land a
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

18. **Opacity was a Glaze, and every stock brush should have been Blending.**
    Reported 2026-09-09, in one line, after drawing with it: *"opacity
    basically acts like flow in procreate"*. Correct, and the measurement that
    said so had been in `docs/procreate-experiments.md` since 2026-09-08.
    Procreate expresses accumulation as a **rendering style** with six named
    values, and they are not decoration on one behaviour — they select between
    two. Measured at Opacity 25%, one twenty-pass scribble: Intense Blending
    B 1 and Uniform Blending B 5, both solid; Light Glaze B 85, settling at
    0.16 ink and staying there. Our engine applied Opacity once at composite
    for *every* brush, which is a Glaze, and Procreate's stock brushes are
    Blending. So the always-visible slider capped a stroke where Procreate's
    builds it, and no setting in our brush panel could make it do otherwise.
    **The error was not arithmetic and is worth keeping visible.** The question
    asked of the data was "can our two sliders express both families", and the
    answer really was yes — Opacity 100% with a low Flow *is* Blending. The
    question that decides whether the app is right is "does the control the
    hand lands on do what the hand expects", and it was never asked. A spanning
    set is not a user interface. Round 5's conclusion is corrected in place
    rather than rewritten, under the table it got wrong.
    Fixed with `Brush::renderingStyle`, two values, defaulting to Blending: the
    dab carries `flow * opacity` in a Blending style and `flow` alone in a
    Glaze. ~~One pass at Opacity 25% now measures 0.992 ink in the engine's own
    test, against the device's B 1.~~ **Wrong comparison, corrected
    2026-09-23:** B 1 came from twenty passes, and both saturate under twenty.
    The single-pass figures disagree by eleven to fourteen times; see 21.
    Four tests in `test_stroke.cpp`, one of
    which asserts the two families are the same brush at Opacity 100% — which
    is why changing the default was safe for every existing brush.

19. **The sliders were white on a white canvas.** Reported 2026-09-09 with a
    screenshot: the quick bar's thumbs read as faint smudges and the track was
    not there at all. The track was white at 18% alpha, the fill white at 85%,
    the thumb solid white, and the only relief was a drop shadow.
    A drop shadow cannot fix this. It is a dark blur — it disappears over dark
    paint and is too soft to define a 6-point track over light. The general
    fault is that **a control floating over the canvas has no known
    background**, so no single colour can be relied on, and the palette was
    chosen against a canvas that happened to be dark in every screenshot taken
    of it.
    Fixed with contrast in both directions rather than a darker palette: every
    layer is now a light fill carrying a dark outline, so the outline holds it
    against white and the fill holds it against black. The rule generalises to
    any chrome drawn over artwork, which is most of what this app will draw.

20. **The controls were on the wrong side.** Asked for on the right and built
    there, with the handedness concern — Procreate defaults to the left because
    a right-handed palm rests on the right edge — recorded beside the code and
    raised at the time. Drawing with it showed the palm resting over them.
    *Reframed 2026-09-23:* this entry first said the concern was known and
    "shipped anyway", which misdescribes it. The placement was an explicit
    request; raising the concern and building what was asked is the process
    working, and the device settling it is what device rounds are for.
    The rule, now written down rather than rediscovered: **controls belong on
    the side of the hand that is not holding the pen.** That makes the majority
    default leading and the swap a necessity rather than a nicety, since a
    left-handed artist has the mirror-image problem exactly as badly. The whole
    chrome moves together — toolbar, quick bar, both panels, and the HUD to the
    opposite edge — from one toolbar button, and it persists.
    Kept in this register rather than only in the code, so the rule is findable.

21. **Opacity is about twenty times too strong per dab.** Found 2026-09-23 on a
    review pass, not on the device, and open. The Blending change put
    `flow * opacity` on each dab. Round 4b's single strokes at Opacity 10%
    measured 0.03 / 0.06 / 0.08 / 0.09 ink across four spacings; the engine,
    replaying the same settings, gives 0.410 / 0.686 / 0.891 / 0.995. Per dab
    that is 0.10 against Procreate's ~0.005.
    Missed when 18 shipped because the only comparison made was against the
    twenty-pass scribble, where both saturate — see 18 and the category note
    below. The family (no ceiling) is right; the scale is not.
    **Not fixed yet, deliberately.** Three explanations fit the one data point —
    a non-linear slider in Procreate, the Studio Pen's own pressure dynamics,
    or something per-dab we do not model — and they prescribe different fixes.
    This topic has produced five confident models already. The measurement is
    at the end of `docs/procreate-experiments.md`, and it is five numbers.

1–9 and 12 lived in how the shell drove the engine — layout and view
lifecycle, not logic — which is the argument for pushing more behind the C ABI
where CI can reach it. Note the shape they share: none are arithmetic, all are
UIKit rebuilding, sizing or re-orienting something at the wrong moment. (This
once said "every one of these but 15 and 18", which stopped being true as the
register grew; 16 is release infrastructure, 19 is a palette, 20 a placement.)

12 is the same shape as the rest — a frame computed against the wrong thing.
10, 11, 13, 14, 15, 17, 18 and 21 are not: they are design errors in what the
brush *means*, which is a category this project had not hit before and which no
amount of UIKit discipline would have caught.

18 and 21 are a third category, and naming it is the point of listing them:
**the data to get it right was already in the same table as the conclusion.**
18 concluded "two sliders span the space" from a table that also showed every
stock brush was Blending. 21 confirmed a single-pass engine figure against a
twenty-pass device figure, when the same document held the single-pass device
figures and they disagreed by an order of magnitude. Neither needed new
information. What they needed was for the conclusion to be checked against
*every* number it came from, comparing like with like — passes, pressure,
brush — before it shipped. That step is now written into CLAUDE.md.
(First written 2026-09-09 as "19 and 20". 19 was never on file — nobody had
written anything about the palette — and 20 is reframed above.)

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
