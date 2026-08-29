# Layers panel — interaction spec

Derived from Procreate's layer panel, which is the interaction model the user
already has in their fingers. **Interaction model only.** Icons, palette,
typography and naming are ours; nothing here should be traced from screenshots.

Measurements are estimated from a screenshot of an 11" iPad Air (1180×820 pt)
and are starting points to adjust by eye on device, not exact values.

---

## Structure

```
┌──────────────────────────────┐
│  Layers                   +  │   header
├──────────────────────────────┤
│ ▢ thumb │ Capa 3    │ N │ ☑ │   topmost layer first
│ ▢ thumb │ Capa 2    │ N │ ☑ │ ← selected, highlighted
│ ▢ thumb │ Capa 1    │ N │ ☑ │
├──────────────────────────────┤
│ ▢ colour │ Background    │ ☑ │   pinned, not reorderable
└──────────────────────────────┘
```

Note the **inverted order**: the panel lists topmost first, while
`LayerStack` indexes bottom-first. The view reverses; the model does not.

## Approximate geometry (points)

| Element | Value |
|---|---|
| Panel width | ~330 |
| Panel corner radius | ~14 |
| Row height | ~60 |
| Thumbnail | ~78 × 48, inset ~6 from the row edge |
| Header height | ~46 |
| Blend indicator | right-aligned, ~30 in from the visibility toggle |
| Visibility toggle | ~36 from the right edge |
| Row gap | 0 — rows are contiguous, separated by a hairline |

## Behaviour

| Action | Result |
|---|---|
| Tap a row | Select it as the active layer |
| Tap `+` | Add a layer above the active one, and select it |
| Tap the blend indicator | Expand the blend list inline, directly under that row |
| Drag a row | Reorder |
| Toggle the checkbox | Show/hide, without changing selection |

**Opacity slider** appears with the expanded blend list, above it, showing a
percentage.

### The background layer

Pinned to the bottom, cannot be reordered or deleted, and holds a flat colour
rather than pixels. Tapping its swatch opens a colour picker.

Worth modelling explicitly rather than as "just another layer": the compositor
can treat it as a clear colour and skip a whole layer of blending, and export
needs to know whether the page has an opaque ground or transparency.

### Where we deliberately diverge

Procreate's blend indicator is a bare letter — `N` for Normal — with no button
affordance and no press feedback. The user flagged this as poor UX, and they
are right: nothing about it says it is tappable.

Ours should read as a control: a bordered pill showing the abbreviated mode
name, with a pressed state and a disclosure indicator when expanded. Better for
users, and incidentally more distinctly ours.

## Blend modes

Grouped as Procreate groups them, which follows Photoshop's grouping. Spanish
names are the user's reference from their device.

| Group | Modes |
|---|---|
| Darken | Multiply, Darken, Color Burn, Linear Burn, Darker Color |
| — | Normal |
| Lighten | Lighten, Screen, Color Dodge, Add, Lighter Color |
| Contrast | Overlay, Soft Light, Hard Light, Vivid Light, Linear Light, Pin Light, Hard Mix |
| Inversion | Difference, Exclusion, Subtract, Divide |
| Component | Hue, Saturation, Color, Luminosity |

**One open question.** The user's list contains 27 entries, including
`Sombreado` between `Oscurecer` (Darken) and `Subexponer color` (Color Burn).
The standard set is 26 without Photoshop's `Dissolve`, so `Sombreado` is one
more than expected and does not map cleanly onto a known mode. Confirm on
device what it does before implementing it — guessing at blend maths produces
results that look plausible and are wrong.
