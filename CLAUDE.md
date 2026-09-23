# Working notes for Claude

Read at the start of every session in this repository. This is the durable
memory for this project — nothing else carries between conversations.

## What this is

Manga-Chan: a manga drawing app for iPad, aiming at Procreate-class painting
performance. Built with no development machine — directed from the iPad through
Claude Code, compiled by GitHub Actions. See `README.md`.

## How octolex wants to work

Stated directly, so it does not have to be restated each session.

- **Rules over ad-hoc decisions.** Conventions get written down and followed,
  not re-litigated per case. `docs/versioning.md` is the model: every rule is
  checkable against a real release. If a new area needs a convention, propose
  one and write it down rather than deciding case by case.
- **The reasoning, not just the result.** They are learning how software
  production works, from the perspective of a manager who wants to understand
  every part of the product rather than sign off on summaries. Explain *why* a
  design is the way it is, and what the alternative would have cost. Name the
  trade-off.
- **They are the only device tester, and they are thorough.** Findings come back
  precise and often correct about the cause. Take them seriously; several have
  been design errors rather than bugs.
- **Say when something is uncertain, wrong, or unverified.** They would rather
  be told "I got this wrong twice, here is the one measurement that settles it"
  than be handed a third confident guess. Distinguish *measured* from *reasoned*
  every time — this project's whole discipline rests on that line.
- **Reference test instructions inline, not by number.** They have no local copy
  of `TESTING.md` open while testing on the iPad. "#73" alone is unusable.
  Better still, publish the round as a page they can keep open beside Procreate,
  with any predicted outcome drawn rather than described — a grey swatch they
  can hold the canvas against beats a percentage they have to imagine.
- **Observation mode, except for reverse-engineering** (octolex, 2026-09-09).
  For ordinary changes they draw with the build and report what looks wrong;
  they do not work through numbered checklists. Give a short "what changed,
  what to look at" instead. Measurement scripts — published as a page, with
  drawn predictions — are for reverse-engineering Procreate only. The tables in
  `TESTING.md` stay the record; its "Next round — start here" block is the
  entry point and is what to keep short and current.
- **Controls go on the side of the hand not holding the pen** (settled on
  device, 2026-09-09). Default left, for the right-handed majority; one toolbar
  button moves the whole chrome to the other edge, and the choice persists.
  New chrome follows the same side, or it breaks the rule for the one control
  that forgot.
- **Their iPad is in English as of 2026-09-06.** Procreate's UI is English now,
  so name settings in English. `docs/procreate-brush-settings.md` keeps the
  Spanish alongside because that is what was originally observed, and losing it
  would mean re-transcribing to check anything.
- **Direct, honest communication is a stated value.** No padding, no agreeing
  for the sake of it. Disagree when there is reason to.

## How this project works

- **The engine is C++ and platform-free; the shell is Swift.** Anything
  testable belongs behind the C ABI where CI can reach it. *Every* bug that has
  reached the device lived in the Swift shell — that is the argument for pushing
  logic down, and it has held every time.
- **Anything verifiable off-device must be.** CI runs the C++ suite on Linux and
  Windows, and a simulator harness with real Metal so shaders are checked
  against a CPU reference rather than by eye. What is left for the device is
  what a test cannot answer: whether it looks right, and whether it costs a
  frame.
- **`TESTING.md` is the record.** Device findings, what passed, what is known
  broken, and every bug that has reached the device with its cause. Keep it
  accurate — an entry wrongly filed under "known and deliberate" argues the
  reader out of reporting a real fault.
- **`ROADMAP.md` records decisions and what they cost**, including the ones that
  turned out wrong. Do not quietly rewrite history when a design changes; note
  that it changed and why.
- **Check a conclusion against every number it came from, like with like.**
  Bugs 18 and 21 in `TESTING.md` were both conclusions drawn from a table that
  also held the numbers refuting them: 18 missed that every stock brush was
  Blending, and 21 matched a one-pass engine figure against a twenty-pass
  device figure while the single-pass device figures sat in the same document,
  an order of magnitude away. Before shipping a behaviour justified by a
  measurement, re-read the whole table and check the comparison matches in
  passes, pressure, brush and spacing. And ask of any test offered as evidence
  what result would have refuted it; if nothing could have, it is not evidence.
- **The completeness table is enforced by CI.** `tools/check_taxonomy.py` fails
  the build when `ROADMAP.md` disagrees with `docs/procreate-brush-settings.md`.
  When a setting becomes reachable by the artist, tick its taxonomy row first
  and let the roadmap follow.
- **Short-lived branches, merged when green.** Not per-milestone — a branch that
  lives a milestone becomes a fork. CI only builds on `main` pushes and PRs to
  `main`, so a branch is how a build gets tested before it becomes mainline.
- **Branches, pull requests and versioning are Claude's to run** (octolex,
  2026-09-08). Open the PR, drive it to green, merge it, bump the series when a
  milestone closes — without asking each time. This is delegation of the
  mechanics, not of the decisions: a design choice, a reverted behaviour, or
  anything that changes what the app does still gets explained and put to them.
  The rules in `docs/versioning.md` are what this authority is exercised
  against; if a case is not covered, add a rule rather than deciding it once.

## Releases

Every build publishes a GitHub release with the `.ipa`, and a SideStore source
so updates arrive as a tap. Rules in `docs/versioning.md`. The short version:
`0.<milestone>.<ci run>`, series bumped only when a milestone closes, build
number never chosen by hand.
