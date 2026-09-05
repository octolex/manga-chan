# Wet mix — what the algorithms actually are

Collected because the request was explicit: find the real thing rather than
invent one. Where this document is confident, it says so; where it is inference
from a screenshot, it says that instead.

## What the device test showed

Green drawn across magenta drags magenta into itself, and a green blob painted
inside the magenta area stays contaminated with it. The brush carries a colour
that is continuously updated from what it passes over.

That is a **smudge / colour-pickup model**, not a fluid solver. Nothing in the
result requires simulating a liquid: there is no flow after the stroke stops, no
pooling, no diffusion at rest. A running colour buffer reproduces all of it.

**One detail is worth more than the confirmation.** Where the two colours mix,
the result reads grey-olive. Green and magenta are complementary; averaging them
in RGB gives grey, while real pigments give a dark muddy brown. So Procreate's
wet mix appears to interpolate in **RGB**, not in a pigment space. Matching it
therefore needs no pigment model at all. This is read off a JPEG by eye and is
the least certain claim here — a colour-picker reading of the mixed region would
settle it.

## The mechanism: libmypaint's smudge

The reference implementation is `libmypaint`, which is open source, in C, and
has been shipping in MyPaint and Krita for years. It is roughly ten lines of
state.

The brush holds a **smudge bucket** — one RGBA colour carried along the stroke.
Per dab:

1. Sample the canvas under the dab, over a radius of
   `radius * exp(smudge_radius_log)`, clamped.
2. Update the bucket toward that sample:
   `bucket = fac_old * bucket + fac_new * sampled`, where `fac_old` is the
   `smudge_length` parameter and `fac_new = (1 - smudge_length) * alpha`.
3. Mix the bucket into the brush colour by the `smudge` amount, and draw the dab
   in the result.

`smudge_length` is the memory of the stroke: near 1 the bucket changes slowly and
colour is carried a long way; near 0 it takes the canvas colour immediately and
smears only locally. It also controls how often the canvas is resampled, which is
where the performance comes from — sampling is the expensive part, not mixing.

Map onto Procreate's Mezcla húmeda, per the Procreate Handbook and community
documentation:

| Procreate | Likely equivalent |
|---|---|
| **Dilución** — Dilution | How much water thins the paint; raises transparency |
| **Carga** — Charge | How much paint the brush starts a stroke with |
| **Ataque** — Attack | Pressure changes how much of the brush shape is applied |
| **Arrastre** — Pull | Works with Dilution; how much paint gets dragged around — this is `smudge` |
| **Grado** — Grade | Chunkiness and contrast of the brush's texture |

~~Charge plus Dilution together are a **load model**: the brush holds a finite
amount of paint and the trail weakens as it is used up.~~ **Measured on device
2026-09-06 and it is not true.** Long strokes at Charge 1% and at Charge 100%
are both even from end to end — neither fades, over distances where a reservoir
would have emptied repeatedly. Charge behaves as a **ceiling** that pressure
scales toward, which is much closer to our existing `flowDynamics` maximum than
to anything new.

The claim above came from the community documentation cited below, which says
"as the brush runs out of paint, the trail of colour it leaves will become less
intense". Either that describes a different setting, or it is simply wrong. It
is quoted here rather than deleted because it is exactly the kind of plausible
secondary source that would otherwise get believed twice.

## If we ever want mixing better than Procreate's

Only relevant if the RGB reading above is right and we decide to beat it rather
than match it. Not needed for parity.

- **Practical Pigment Mixing for Digital Painting**, Sochorová & Jamriška,
  ACM TOG / SIGGRAPH Asia 2021. Maps RGB into a small latent space where
  Kubelka-Munk-style mixing is a weighted sum, then back. Designed to be a
  drop-in replacement for `lerp` in an existing engine, which is exactly the
  shape we would need. Published as *Mixbox*.
- **IMPaSTo: A Realistic, Interactive Model for Paint**, Baxter, Wendt & Lin,
  NPAR 2004. Kubelka-Munk over a basis of eleven measured oil paints, with paint
  volume and pigment concentration per pixel. The thorough version, and far more
  than a manga app needs.
- Baxter's dissertation, *Physically-Based Modeling Techniques for Interactive
  Digital Painting* (2004), is the long-form background for both.

The distinction that matters: **pickup is about where colour comes from, pigment
models are about how two colours combine once you have them.** They are separate
choices and the first one is what the screenshot demonstrates.

## Sources

- [libmypaint `mypaint-brush.c`](https://github.com/mypaint/libmypaint/blob/master/mypaint-brush.c)
- [Krita — MyPaint Brush Engine](https://docs.krita.org/en/reference_manual/brushes/brush_engines/mypaint_engine.html)
- [Krita — Color Smudge Brush Engine](https://docs.krita.org/en/reference_manual/brushes/brush_engines/color_smudge_engine.html)
- [Procreate Handbook — Brush Studio settings](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings)
- [Practical Pigment Mixing for Digital Painting (ACM TOG 2021)](https://dl.acm.org/doi/10.1145/3478513.3480549)
- [IMPaSTo (NPAR 2004), PDF](http://gamma.cs.unc.edu/IMPASTO/publications/Baxter-IMPaSTo_Web-NPAR04.pdf)
- [Baxter, dissertation (2004), PDF](http://gamma-web.iacs.umd.edu/papers/documents/dissertations/baxter04.pdf)
