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
- **Short-lived branches, merged when green.** Not per-milestone — a branch that
  lives a milestone becomes a fork. CI only builds on `main` pushes and PRs to
  `main`, so a branch is how a build gets tested before it becomes mainline.

## Releases

Every build publishes a GitHub release with the `.ipa`, and a SideStore source
so updates arrive as a tap. Rules in `docs/versioning.md`. The short version:
`0.<milestone>.<ci run>`, series bumped only when a milestone closes, build
number never chosen by hand.
