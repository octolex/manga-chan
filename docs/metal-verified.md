# Metal facts, verified against the specification

Things we had been assuming, now checked against Apple's published documents
with page citations. Fetch the sources with `Documentation/fetch.ps1`.

The point of this file is that we cannot attach a debugger or a frame capture
tool to the device. A wrong assumption here does not produce an error — it
produces a shader that compiles, runs, and renders subtly incorrect output,
which is the most expensive kind of bug this project can have.

---

## Programmable blending is unconditional on iPadOS

**Source:** Metal Shading Language Specification, 2026-06-04, Table 5.5, p146.

```
color(m)   [as fragment function INPUT]
  macOS:               Metal 2.3 and later
  iOS:                 Metal 1 and later
  iPadOS and visionOS: Always
```

Declaring `[[color(0)]]` as a fragment function *input* reads the current
value of that colour attachment — the destination pixel — directly from tile
memory, with no second texture and no ping-pong.

**Why this matters:** it is the mechanism the whole blend-mode design rests
on. Every non-separable blend mode, smudge, and wet-mix needs to read the
destination. Doing that by binding the destination as a texture would mean
either a copy per draw or a full ping-pong between two targets. On a
tile-based deferred renderer the destination is already sitting in on-chip
tile memory, so reading it costs essentially nothing.

**Consequence for our code:** no runtime capability check is needed. It is
listed as *Always* on iPadOS, so the code path is unconditional.

## Input and output types must match

**Source:** MSL Specification, §5.2.3.5, p153.

> If a color attachment index is used as both an input to and an output of a
> fragment function, the data types associated with the input argument and
> output declared with this color attachment index must match.

So a fragment function that reads `float4 [[color(0)]]` must also return
`float4` for attachment 0. Our canvas is `bgra8Unorm`, which reads as
`float4` — consistent, but worth pinning down before writing 26 shaders that
share a signature.

## The target device is the Apple9 family

**Source:** Metal Feature Set Tables, 2026-06-01, p2.

| Silicon | Metal | GPU family |
|---|---|---|
| M4-series | Metal 3 & 4 | **Apple9** |
| M3-series | Metal 3 & 4 | Apple9 |
| M2-series | Metal 3 & 4 | Apple8 |
| M1-series / A14 | Metal 3 & 4 | Apple7 |
| A19-series / M5 | Metal 3 & 4 | Apple10 |

The iPad Air M4 is therefore Apple9. This confirms what the roadmap had
already assumed, and sets the floor: targeting Apple7 covers everything back
to the A14 and M1.

## Programmable blending goes back to Apple2

**Source:** Metal Feature Set Tables, p2.

> Programmable blending — Metal 3 & 4 — Apple2

Available on essentially every device we would ever support, so it does not
constrain the minimum target at all.

---

## Still unverified

Written down so nobody mistakes an assumption for a checked fact.

- **`CAMetalDisplayLink` frame pacing behaviour.** No local reference — the
  framework API is only on the web. Currently working from the header and
  observed behaviour on device.
- **Imageblock and tile-shader limits** for multi-layer compositing in a
  single pass. Relevant to the under/over caching design; check the MSL spec
  §5.6 and the feature tables before relying on a specific tile memory budget.
- **Whether the simulator's Metal matches device behaviour for programmable
  blending.** The CI harness runs shaders on a simulator; if simulator results
  ever disagree with the device, this is the first thing to suspect.
