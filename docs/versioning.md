# Versioning and release rules

Written down so both of us follow the same rules rather than deciding each time.
Every rule here is checkable — you can look at a release and say whether it was
followed.

## The version number

```
0 . 3 . 72
│   │   └── build: the CI run number
│   └────── series: the milestone being worked on
└────────── major: 0 until 1.0
```

**`0.3.72` means: pre-1.0, working on milestone M3, built by CI run 72.**

The version tells you where on the roadmap a build sits. That is the whole point
of it before 1.0 — a build's number should answer "what is in this?" without
opening anything.

### Series — the middle number

Equal to the milestone in progress. `0.3.x` is M3, `0.4.x` is M4.

It lives in the `VERSION` file at the repository root and changes **only** when
a milestone is marked done in `ROADMAP.md`. Bumping it is a deliberate edit that
shows up in a diff and in the release notes, never a side effect of a build.

### Build — the last number

The CI run number. Global, monotonic, never reset, never chosen by hand. It
carries across series bumps: `0.3.99` is followed by `0.4.100`, not `0.4.0`.

That matters because it makes every version unique and strictly increasing
across the whole history of the project, which is what an installer needs to
tell a new build from an installed one.

`CFBundleVersion` is this number on its own, as a plain integer.

### After 1.0

The meaning changes, because the promise changes. From 1.0 the version describes
**compatibility**, in the standard [Semantic Versioning](https://semver.org)
sense:

| Part | Bumped when |
|---|---|
| **MAJOR** | Something breaks — a document written by an older version no longer opens, or a feature is removed |
| **MINOR** | Something is added, and everything that worked before still works |
| **PATCH** | Something is fixed, nothing is added |

Reaching 1.0.0 requires two things, not one:

1. Every milestone in `ROADMAP.md` is done, **and**
2. One real piece of work has been made in the app, start to finish

The second condition is there on purpose. A ticked checklist is not evidence
that the thing is usable for its purpose, and 1.0 should mean the latter.

## Stages

The stage is a claim about *stability*, written in the release title and set as
GitHub's pre-release flag.

| Stage | Means | Version |
|---|---|---|
| **internal pre-alpha** | Incomplete. Known-broken things are documented, not fixed. Author's device only. | `0.x.y` while milestones remain |
| **internal alpha** | Feature-complete against the roadmap. Still author-only. Expect bugs. | `0.x.y` after the last milestone |
| **beta** | Stable enough for people who are not the author | `1.0.0-beta.n`, if it ever goes wider |
| **release** | No longer pre-release | `1.0.0` |

Everything so far is internal pre-alpha, and none of it is a public build.

## The rules

1. **One version, three places, always identical.** The git tag, the release
   title and `Info.plist` agree. CI reads the built `Info.plist` back and fails
   if it disagrees — the override is passed on the `xcodebuild` command line,
   where a renamed build setting would otherwise fail silently.
2. **The build number is never chosen by hand.** It is the CI run number.
3. **The series changes only when a milestone closes**, in the same commit that
   marks it done in `ROADMAP.md`.
4. **Every build that passes CI gets a release.** No build reaches the device
   without a version and an entry describing it.
5. **Release notes say what changed and what is known broken**, and link the
   roadmap and the test backlog. A release nobody can interpret six months later
   is not documentation.
6. **A release tag points at a commit that is reachable from a branch.** On a
   `pull_request` event `github.sha` is a merge commit GitHub invents to test the
   PR and then discards, so tagging it produces a release whose target no branch
   can reach — you cannot check it out, and "what changed since the last
   release" cannot be computed against it. CI tags the PR head instead, and the
   notes say the build came from that head merged into its base, because that is
   what was compiled. Checkable: `git merge-base --is-ancestor <tag> origin/main`
   succeeds for every release tag once its work is merged — except `v0.1.72` and
   `v0.3.73`, which predate the rule and will always fail it. They are left
   alone rather than retagged: moving a published tag breaks the download anyone
   already has, and the record of the mistake is worth more than a tidy list.
7. **"Since the previous release" means the previous release, in any series.**
   The tag search matches every `vX.Y.Z`, sorted by version rather than by name
   so a two-digit series orders correctly, and excludes the tag being written so
   a re-run does not diff a build against itself. A glob pinned to one series
   silently outlives that series: `v0.1.*` kept selecting `v0.1.72` for two
   releases after the series moved to 0.3, and both shipped changelogs listing a
   single commit.
8. **Pre-1.0 versions promise nothing about compatibility.** Documents may break
   between builds, and that is allowed until 1.0 — but a release that does break
   them must say so at the top of its notes.
9. **1.0.0 is not declared from a checklist.** See the two conditions above.

## Why not date-based, or just a build number

A date tells you when, not what. A bare build number tells you neither. The
series number is the only part that carries meaning, and it costs one file to
maintain.
