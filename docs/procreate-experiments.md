# Procreate experiments — what to draw, and what each result would mean

Written for octolex to run on the iPad, in Procreate, with this page open
alongside. Every step says what to look for *and what the answer would tell us*,
because a test whose outcomes all mean the same thing is not worth the time it
takes to draw.

**My prediction is stated for each one before the result is in.** That is the
point. If I am right, we learn the model. If I am wrong, we learn something
better, and we learn not to trust the reasoning that got me there — which has
now been wrong three times about grain.

## Why we are doing this instead of writing code

Three attempts at grain have failed. The device round on 2026-09-03 showed why:
Flow was a per-dab alpha, so with about seventeen dabs covering every pixel, a
Flow of 50% accumulated to 0.99999 and the stroke body was solid at every
setting anyone would use. A tooth can only bite into coverage below 1, and there
was none.

That is now fixed in the engine — but fixing it exposed a question the fix
cannot answer: **what should a stroke do when it crosses itself?** Our answer is
currently "darken, always". Procreate's answer appears to be "it depends which
of six rendering styles you picked", and its Flow is typed as a *maximum level*
rather than a plain amount. Those are different models, and building grain on
the wrong one is how we get a fourth failure.

`docs/procreate-brush-settings.md` is the taxonomy. This is the behaviour.

## How to record it

One canvas per lettered group, strokes left to right in the order listed, on a
white background with black ink unless a step says otherwise. Tell me the order
you drew them in and which brush you used — I would rather have four labelled
strokes than twelve I have to guess at.

Keep everything not named in a step at its default, and say if a control named
here is missing on the brush you picked: *which* settings a brush exposes is
itself information.

---

## A — Does a stroke accumulate against itself?

Use a plain round brush with no grain and no wet mix. **Inking → Studio Pen** is
the cleanest. Note which Rendering style it is set to before changing anything.

**A1.** Set the top-level **Opacity slider to 30%**. In one continuous motion,
without lifting the pencil, draw a loop that crosses over itself once.

> Look at the crossing. Is it darker than the two lines running through it, or
> exactly the same tone?

**A2.** Now draw two **separate** strokes that cross, still at 30%, lifting the
pencil between them.

> Same question at that crossing.

**What the pair means.** A1 flat and A2 darker is the Photoshop split: the
Opacity slider is a *ceiling on one stroke*, and a stroke cannot exceed it no
matter how much it overlaps itself, but a second stroke composites on top. Both
darker means dabs simply accumulate and Opacity is a per-dab amount. Both flat
would be surprising and would mean something I have not thought of.

**My prediction:** A1 flat, A2 darker.

**A3.** Repeat A1 once for each of the six Rendering styles — Brush Studio →
Renderizado → Estilo de renderizado: Light Glaze, Uniform Glaze, Intense Glaze,
Heavy Glaze, Uniform Blending, Intense Blending. Six loops, in that order.

> Which of them darken at the crossing, and roughly how much? Is it a step
> change between Glaze and Blending, or a gradual ramp through all six?

**What it means.** This maps the entire enum onto one axis and tells us what our
single Flow control has to be able to express. If Glaze never darkens and
Blending always does, the six values are two behaviours with four intensities,
and we need one control plus a mode — which is exactly the switch I removed for
being redundant, and I would have removed it wrongly.

**My prediction:** the four Glaze styles do not darken at the crossing and
differ only in how strong one pass is; the two Blending styles darken.

---

## B — Opacity versus Flow

The observation that prompted this: the always-visible slider is Opacity, but it
behaves like flow, while Brush Studio has its own Flow that multiplies alpha.

**B1.** Top Opacity **100%**. Brush Studio → Renderizado → **Flujo 50%**. One
self-crossing loop.

**B2.** Top Opacity **50%**. Flujo back to **100%**. One self-crossing loop.

> Are B1 and B2 the same darkness as each other? Does either crossing darken
> while the other stays flat?

**What it means.** If B1 darkens at the crossing and B2 does not, they are
genuinely different controls: Flow deposits per dab, Opacity caps the finished
stroke. That is the Photoshop model, it is what "maximum level" in the settings
list implies, and it means our two controls should stay independent. If they are
indistinguishable, one of them is redundant in Procreate too and we can stop
worrying about which we have.

**My prediction:** B1 darkens at the crossing, B2 does not, and B2 is the
cleaner-looking line.

---

## C — Does Spacing change how dark a stroke is?

This one tests a change I have already pushed, so it is the one most likely to
tell me I was wrong.

**C1.** Opacity 50%, Flujo 100%. Note the current **Espaciado** value. Draw a
straight stroke.

**C2.** Halve the Espaciado. Draw an identical stroke next to it.

> Are the two the same darkness, or is the second one noticeably darker?

**What it means.** Same darkness means Procreate compensates for how many dabs
overlap, which is exactly the fix now in the engine, and it is independent
confirmation from a shipping product. Darker means they do not compensate — and
that their model avoids the problem another way, most likely by capping the
stroke as a unit, in which case the compensation is the wrong shape of fix even
though the coupling it removes is real.

**My prediction:** the same darkness. If they are visibly different, tell me and
I will stop and rethink before writing any more of this.

---

## D — Grain

Use a heavily grained brush: **Sketching → 6B Pencil**, or a Charcoal.

**D1.** Top Opacity **100%**. One firm stroke.

> Look at the middle of the stroke, not the edges. Is the paper texture visible
> right through the body, or is the body solid with the texture only breaking up
> the edges?

**D2.** Same brush and settings. Scrub back and forth over one small patch
fifteen or twenty times, as if shading it in hard.

> Does the texture eventually fill in and go solid black, or does it persist no
> matter how much you work it?

**D3.** Opacity **20%**, one light stroke. Then Opacity **100%**, one firm
stroke beside it.

> Is the grain the *same pattern* in both, one simply lighter — or does the
> light one show visibly more broken, more granular texture than the firm one?

**What they mean, together.** These three separate the only models left:

- Texture visible in the body (D1), persists forever (D2), same pattern at both
  opacities (D3) → grain is a **hard cap on coverage**. Ink never fills the
  tooth. This is arithmetically what our first attempt did, and what you called
  a uniform veil — which would mean the veil was the right mechanism and wrong
  in its contrast or scale, not in its concept.
- Solid body (D1), fills in (D2), more texture at low opacity (D3) → grain
  **competes with accumulated coverage**, and enough ink covers the paper. Then
  the threshold belongs at composite time against the accumulated stroke.
- Fills in (D2) but texture still visible in the body at 100% (D1) → both: grain
  caps a single pass but repeated passes overcome it, which needs the tooth
  applied per pass rather than per dab or per stroke.

**My prediction:** D1 solid-ish body with a broken edge, D2 fills in, D3 more
texture at low opacity. I have been wrong about grain three times, so treat this
prediction as the least reliable one on the page.

---

## E — Wet mix

The hypothesis worth testing: that what we read as a grain problem is really the
absence of a paint-and-surface simulation, and that Mezcla húmeda is where
Procreate puts it.

**E1.** Fill an area with a solid mid-tone colour. Pick a brush that has wet mix
settings — **Painting → Nikko Rull** or similar. Choose a clearly *different*
colour and draw across the filled area.

> Does the stroke stay the colour you picked, or does it drag the underlying
> colour into itself and blend along the way?

**E2.** Brush Studio → Mezcla húmeda → **Dilución** high. One long stroke.

> Does the stroke fade along its length, as if the brush is running out of paint?

**E3.** With wet mix active, does the brush's grain still show at all?

**What it means.** If E1 smears the underlying colour, wet mix is a **colour**
feature — the dab samples the canvas and mixes — and it does not answer the
coverage question, though it is a large and separate thing we do not have. If E2
fades along the stroke, there is a **load** model: paint depletes with distance,
which is a third axis alongside flow and grain and would explain a lot about why
Procreate's dry media reads the way it does. E3 tells us whether the two systems
are independent or one overrides the other.

**My prediction:** E1 smears — wet mix is colour, not coverage. E2 does fade,
and that load model is real and missing from our engine. Which would make the
hypothesis half right in a more interesting way than if it were simply right:
not the answer to grain, but a real gap we had not named.

---

## What I will do with the answers

A and B decide whether Flow stays one control or becomes a control plus a
rendering style, and that decision governs what grain is even allowed to modulate.
C says whether the compensation already pushed is the right shape. D picks the
grain model from three candidates rather than from my reasoning, which has a
three-for-three losing record here. E tells us whether there is a whole
mechanism missing that we have been trying to fake with the two we have.

None of this needs to be done in one sitting, and A, C and D are worth more than
B and E if the time is short.

---

# Results — 2026-09-05

Run by octolex. Screenshots in the session; not committed. Read by eye from the
images, not measured off pixel values — the images were not saved to disk, and
calling that a measurement would be exactly the confusion this project exists to
avoid.

## A — a stroke DOES accumulate against itself. Prediction wrong.

One continuous self-crossing loop shows visible darkening at the crossing; a
loop crossed several times at one point goes solid black there.

So the Glaze hypothesis is dead for this brush: Procreate's default behaviour is
dab-by-dab accumulation within a single stroke, which is what we already do.
**The six rendering styles were not tested** — A3 was not run — so what the
Glaze styles change is still unknown, and it is no longer the urgent question.

Our current model is right on this axis. The Maximum/Buildup switch was correctly
removed after all, for a reason different from the one given at the time.

## B — Renderizado → Flujo is not our Flow. Inconclusive.

At Flujo 100% and Flujo **0%**, both strokes are clearly present; the second is
lighter and softer, not absent. A control that leaves a strong visible stroke at
zero is not a coverage alpha. It reads as a density or edge-softness modifier
with a floor.

Whatever "maximum level" means in that settings list, it does not mean what
`Brush::flow` means here. **Do not map the two onto each other.** Needs a
better-designed test before it informs anything.

## C — INVALID TEST. Not a result, and the design fault was mine.

The spacing was widened until individual dabs were visible, then halved. That
crosses from *no overlap* to *some overlap*, and overlap compensation does
nothing until dabs overlap. Both models predict the second stroke is darker
there:

| spacing | compensated | uncompensated |
|---|---|---|
| 1.5 diameters | isolated dabs at 0.34, white gaps | isolated dabs at 0.50, white gaps |
| 0.75 diameters | continuous 0.50 | continuous 0.60 |

Which is what the picture shows, under either model. The test could not
distinguish them and must be rerun in the regime where they diverge:

**C-redo.** Top Opacity **10%** — low, so the uncompensated model does not
saturate and hide the difference. Set Espaciado to about **10%** and draw a
straight stroke. Set it to about **5%** and draw another beside it.

> Are the two the same light grey, or is the second markedly darker?

Compensated predicts **0.10 and 0.10** — indistinguishable. Uncompensated
predicts **0.65 and 0.88** — both far darker than the 10% asked for, and clearly
different from each other. There is no regime where these two look alike, which
is what the first version of this test lacked.

## D — the decisive result. Grain is a cap on coverage, not a threshold.

Three findings, and together they pick the model:

1. **Profundidad controls how much the body is affected.** Turn it up and the
   texture appears through the body of the stroke, not only at its edges.
2. **Movimiento (Rolling): scrubbing repeatedly fills in to a completely solid
   line.** Texturizado (Canvas): the texture persists in inked areas no matter
   how many times you scrub over them.
3. **Lower opacity does not show more texture.**

Finding 3 kills thresholding against accumulated coverage outright — that model
predicts grain gets dramatically stronger as opacity falls, and it does not.

Findings 1 and 2 are the useful part, because **one mechanism produces both**
with no mode-specific code. If the tooth multiplies the dab's coverage *before*
the maximum blend that builds the stroke's silhouette:

- **Canvas**: the tooth is identical for every dab at a given pixel, so
  `max(tooth x shape)` is `tooth x geometry`. The pits never receive ink however
  many passes go over them. Persists forever. ✓
- **Rolling**: the tooth shifts with arc length, so each pass puts its pits
  somewhere else and the maximum climbs toward 1. Fills in to solid. ✓

That is **exactly what attempt #1 did** — the version rejected on device as "a
uniform veil". The mechanism was right and it was abandoned on an aesthetic
objection that this experiment has now falsified: Procreate's canvas-anchored
grain genuinely does keep texture across the whole inked area, forever. What was
wrong was most likely the *map*, not the maths — our grain is smooth four-octave
fractal noise with most of its mass near mid-grey, which reads as a flat wash
rather than as tooth. Procreate exposes **Brillo** and **Contraste** on the grain
for precisely this.

## E — wet mix is colour pickup, and Procreate appears to mix in RGB.

Green drawn across magenta drags magenta into itself, and a green blob painted
inside the magenta stays contaminated. So the brush carries a colour that is
updated from the canvas as it travels — a smudge or pickup model, not a fluid
solver.

One detail in the screenshot is worth more than the confirmation: **where the two
colours mix, the result reads grey/olive.** Green and magenta are complementary
in RGB and average to grey; real pigments would go dark and muddy, not neutral.
So Procreate's wet mix looks like straightforward RGB interpolation, which means
matching it needs no pigment model at all — and that beating it is available
cheaply if we ever want it.

See `docs/wet-mix-references.md` for the algorithms and papers.
