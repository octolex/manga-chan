#!/usr/bin/env python3
"""Check the completeness table in ROADMAP.md against the taxonomy it counts.

`docs/procreate-brush-settings.md` is the transcription of one real Procreate
brush's studio, one row per setting, each marked complete, partial or missing.
`ROADMAP.md` carries a table of those same counts, per section and in total.

The rule that the roadmap must match the taxonomy has been written down since
2026-09-08 and described as "checkable by recounting". It was in fact recounted
by hand, twice, in two different sessions, with an ad-hoc awk one-liner — which
is not a check, it is a habit, and habits are exactly what stops happening on
the day the count is wrong.

Two ways it silently drifts, both already survivable-looking:

  * A setting is implemented and its taxonomy row is ticked, and the roadmap
    total is not updated. The project then under-reports its own progress,
    which sounds harmless and is how a completeness figure stops being read.
  * A roadmap row is edited to a number nobody recounted. The figure is then a
    claim about the taxonomy that the taxonomy does not make, and the one
    document that exists to be checkable stops being checkable.

Exits non-zero with a diff on any mismatch.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAXONOMY = ROOT / "docs" / "procreate-brush-settings.md"
ROADMAP = ROOT / "ROADMAP.md"

COMPLETE, PARTIAL, MISSING = "✅", "🔶", "⬜"

# The taxonomy's section headings, in the order the roadmap lists them. Keyed by
# the roadmap's own name for each, because the two documents use different
# words: the taxonomy keeps the Spanish alongside, which is what was originally
# observed on the device and is not worth re-transcribing to check anything.
SECTIONS = {
    "Stroke path": "Trayectoria del trazo — Stroke path",
    "Stabilization": "Estabilización — Stabilization",
    "Taper": "Ahusamiento — Taper",
    "Shape": "Forma — Shape",
    "Grain": "Grano — Grain",
    "Rendering": "Renderizado — Rendering",
    "Dynamics": "Dinámica — Dynamics",
    "Apple Pencil": "Apple Pencil",
    "Properties": "Propiedades — Properties",
}


def count_taxonomy():
    """Count marks per section, following the document's own headings."""
    text = TAXONOMY.read_text(encoding="utf-8")
    counts = {}
    section = None
    for line in text.splitlines():
        if line.startswith("## "):
            heading = line[3:].strip()
            section = next((name for name, h in SECTIONS.items() if h == heading), None)
            if section is not None:
                counts.setdefault(section, [0, 0, 0])
            continue
        if section is None or not line.startswith("|"):
            continue
        mark = line.split("|")[1].strip()
        if mark == COMPLETE:
            counts[section][0] += 1
        elif mark == PARTIAL:
            counts[section][1] += 1
        elif mark == MISSING:
            counts[section][2] += 1
    return counts


def read_roadmap():
    """Read the completeness table, including its stated total."""
    text = ROADMAP.read_text(encoding="utf-8")
    rows = {}
    total = None
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != 5:
            continue
        name = cells[0].strip("*").strip()
        try:
            numbers = [int(c.strip("*")) for c in cells[1:]]
        except ValueError:
            continue
        if name == "Total":
            total = numbers
        elif name in SECTIONS:
            rows[name] = numbers
    return rows, total


def main():
    taxonomy = count_taxonomy()
    roadmap, stated_total = read_roadmap()

    problems = []

    missing_sections = set(SECTIONS) - set(taxonomy)
    if missing_sections:
        problems.append(
            "these sections are named in this script but not found as headings in "
            f"{TAXONOMY.name}: {sorted(missing_sections)}. Either a heading was "
            "renamed, or a section was added and SECTIONS here was not updated."
        )

    for name in SECTIONS:
        counted = taxonomy.get(name)
        claimed = roadmap.get(name)
        if counted is None:
            continue
        if claimed is None:
            problems.append(f"{name}: no row in the roadmap table")
            continue
        expected = counted + [sum(counted)]
        if claimed != expected:
            problems.append(
                f"{name}: roadmap says {claimed}, taxonomy counts {expected} "
                "(have / partial / missing / total)"
            )

    if taxonomy:
        totals = [sum(v[i] for v in taxonomy.values()) for i in range(3)]
        expected_total = totals + [sum(totals)]
        if stated_total is None:
            problems.append("the roadmap table has no Total row")
        elif stated_total != expected_total:
            problems.append(
                f"Total: roadmap says {stated_total}, taxonomy counts {expected_total}"
            )

        # The percentages in the prose under the table, which are what actually
        # gets quoted, and so are the numbers most worth keeping honest.
        grand = sum(totals)
        if grand:
            want = tuple(round(n * 100 / grand) for n in totals)
            prose = re.search(
                r"\*\*(\d+)% complete, (\d+)% partial, (\d+)% missing\.\*\*",
                ROADMAP.read_text(encoding="utf-8"),
            )
            if prose is None:
                problems.append(
                    "could not find the '**N% complete, N% partial, N% missing.**' "
                    "line under the table"
                )
            else:
                got = tuple(int(g) for g in prose.groups())
                if got != want:
                    problems.append(
                        f"the prose says {got[0]}% / {got[1]}% / {got[2]}%, "
                        f"the counts give {want[0]}% / {want[1]}% / {want[2]}%"
                    )

    if problems:
        print("Completeness table does not match the taxonomy:\n", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print(
            "\nBoth documents are hand-maintained and one of them is now wrong.\n"
            "Recount docs/procreate-brush-settings.md and fix ROADMAP.md, or tick\n"
            "the taxonomy row the implementation just earned.",
            file=sys.stderr,
        )
        return 1

    totals = [sum(v[i] for v in taxonomy.values()) for i in range(3)]
    print(
        f"completeness table matches the taxonomy: "
        f"{totals[0]} complete, {totals[1]} partial, {totals[2]} missing "
        f"of {sum(totals)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
