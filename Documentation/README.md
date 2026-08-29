# Documentation

Third-party specifications we develop against. **Fetched, not committed** —
see below.

Our own written notes live in [`docs/`](../docs/); this folder holds only
material published by other people.

## Fetching

```powershell
pwsh Documentation/fetch.ps1
```

or on a Unix shell:

```bash
bash Documentation/fetch.sh
```

## Why these are not in git

Apple's specifications are copyrighted. Committing them to a public repository
is redistribution, which is a different thing from downloading them to read.
A fetch script gives everyone the same files with none of that question, and
keeps the repository from carrying 18 MB of binaries that Apple updates
independently of us.

## What is here

| File | Source | Why it matters |
|---|---|---|
| `apple/Metal-Shading-Language-Specification.pdf` | [developer.apple.com](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf) | The MSL language itself. 383 pages, dated 2026-06-04. |
| `apple/Metal-Feature-Set-Tables.pdf` | [developer.apple.com](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf) | Which GPU family supports what. 18 pages, dated 2026-06-01. |
| `apple/W3C-Compositing-and-Blending-1.html` | [w3.org](https://www.w3.org/TR/compositing-1/) | The blend-mode formulas `core/blend.cpp` implements. |

## What is *not* obtainable, and what we do instead

**There is no downloadable bundle of Apple's API reference.** Apple removed
offline documentation sets years ago; `developer.apple.com/documentation` is a
JavaScript application backed by a private JSON API, and Xcode's built-in
documentation requires macOS, which we do not have.

So for framework-level questions — `CAMetalDisplayLink`, `UITouch`,
`MTLRenderPipelineDescriptor` and so on — we read individual pages on the web
as questions come up, rather than working from a local mirror. Bulk-scraping
that API would be both fragile and rude.

What the two PDFs *do* cover is the part where guessing is most expensive: the
shading language and the hardware capability matrix. Those are exactly the
areas where a wrong assumption produces a shader that compiles, runs, and
renders subtly incorrect output on a device we cannot attach a debugger to.

## Reading the PDFs

`pypdf` extracts text without needing poppler, which is not readily available
on Windows:

```bash
python -m pip install pypdf
```

Findings worth keeping are written up in
[`docs/metal-verified.md`](../docs/metal-verified.md) with page citations, so
nobody has to re-derive them.
