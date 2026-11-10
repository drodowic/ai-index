---
name: ai-index
description: >
  Cross-repo knowledge index stored in the Obsidian vault under
  ai-index/. Use this before analyzing any repo under $AI_INDEX_GIT_ROOT to check for
  existing notes on what a repo does, how it does it, or why - and to record findings after
  non-trivial investigation so future sessions (in this repo or a related one) don't
  re-derive the same analysis. Triggers on questions like "what does this repo do", "how
  does X work here", "why is this built this way", "record what we found", "update the
  index", or explicit "/ai-index" invocation.
---

# ai-index

A durable, cross-repo reference index. Configure `AI_INDEX_DOCS_ROOT` and
`AI_INDEX_GIT_ROOT` in `~/.config/opencode/ai-index.env`. `AI_INDEX_DOCS_ROOT` points
directly to the `ai-index/` directory inside the Obsidian vault; `AI_INDEX_GIT_ROOT`
contains the Git project checkouts.
Scripts live alongside this file in `scripts/` and require `jq` and `yq` (mikefarah/yq v4+,
supports `--front-matter`).

Every note carries YAML frontmatter recording the repo, the git SHA it was verified against,
and the source paths its claims depend on - so staleness is computed exactly rather than
guessed, whether the code changed via your own commits or via upstream pulls.

## Layout

```
${AI_INDEX_DOCS_ROOT}/
├── index.md              registry of every repo under $AI_INDEX_GIT_ROOT (path, remotes, branch)
├── how-to-use.md          content/style rules for notes
├── coverage.base          Obsidian Bases view: notes grouped by repo (human-facing only)
├── groups/<name>.md       ownership & coupling between repos (e.g. shared team, shared product)
└── repos/<repo>/
    ├── overview.md        what it does, stack, entry points, how to run/test
    ├── architecture.md    how it does it - layers, data flow, key modules
    ├── decisions.md       why - constraints, rationale, gotchas, dead ends
    ├── integrations.md    contracts with other repos (APIs, schemas, deploy coupling)
    ├── glossary.md         domain terms specific to this repo
    └── areas/<slug>.md    deep dive on one subsystem
```

Only create the files that have real content. An empty `repos/<repo>/` is fine and expected
for a repo you haven't worked in yet - registry rows exist for all repos, deep notes accrete
lazily.

## Operations

### 1. Read (do this first, before analyzing code)

```
scripts/repo-status.sh [path]      # defaults to $PWD; the plugin refreshes status before
                                    # each primary model request
```

This prints: which notes exist, which are `STALE` or `UNVERIFIABLE`, and which related repos
have notes worth checking. It is silent if the path isn't a git repo.

Freshness checks include staged and unstaged changes, plus non-ignored untracked files under
declared sources. Ignored paths and sources outside the repository are `UNVERIFIABLE`: Git
cannot reliably verify their contents, so use a different verification method for those notes.

- Read fresh notes directly - trust them, cite them (`per repos/<repo>/overview.md`) instead
  of re-reading the source they summarize.
- For a `STALE` note: re-read only the `sources` paths listed in its frontmatter (not the
  whole repo), update the note's prose to match, then run `note-touch.sh` (see Capture).
- For `UNVERIFIABLE` (recorded sha not found, or not an ancestor of the current checkout):
  treat as stale and re-verify from scratch. The latter can mean the note came from another
  branch.
- Missing SHAs, empty or invalid source lists, sources not tracked at the recorded SHA, and
  Git check failures are also `UNVERIFIABLE`. A source deleted after its recorded SHA is
  `STALE`. Source paths are treated literally, not as Git pathspec patterns.

### 2. Cross-repo lookup

Given a repo name (from `related:` in the digest, a `groups/*.md` note, or user mention):

```
scripts/stale-check.sh <repo-name>     # per-note staleness table, works from any cwd
```

Then read `repos/<repo-name>/*.md` directly. Never repeat a stale note's claim without
re-verifying against its `sources` first. `groups/*.md` notes explain *why* two repos are
related (shared team, shared product, API contract) - read those to know which related-repo
notes are actually relevant to the current task.

### 3. Capture (after non-trivial investigation)

Write or extend the appropriate note under `repos/<repo>/` (see Layout). Frontmatter:

```yaml
---
repo: app-frontend
kind: area                  # overview | architecture | decisions | integrations | glossary | area
sha: <will be set by note-touch.sh>
verified: <will be set by note-touch.sh>
sources:
  - src/api/queries.ts
  - src/components/Chart/
related:
  - app-backend
---
```

`sources` is a list of files/directories the note's claims depend on - this is what drives
staleness detection, so list every path a claim actually rests on. `related` names other
repos whose notes are relevant here (e.g. a shared API contract) - this is what makes the
note reachable from those other repos too.

Content rules (full detail in `how-to-use.md`):
- Cite `path` or `path:line` for non-obvious claims; don't paste more than ~10 lines of code.
- Record *why*, not just *what* - the why is what can't be cheaply re-derived by reading code.
- Keep `overview.md` ≤150 lines and `areas/*.md` ≤200 lines; split into a new area note
  rather than growing one past the cap.
- Never record secrets, tokens, or customer data - the vault syncs to other devices.
- Skip capture for throwaway/one-off investigation; only record durable findings.

After writing or editing a note:

```
scripts/note-touch.sh <note-path>      # sets sha=<repo HEAD>, verified=<today>
```

`note-touch.sh` refuses to stamp notes without valid tracked sources, or whose sources have
working-tree changes, ignored paths, or paths outside the repository. Resolve those changes or
verify the source another way first.

### 4. Registry maintenance

```
scripts/repo-registry.sh               # after cloning or removing a repo under $AI_INDEX_GIT_ROOT
```

Regenerates the table in `index.md` between its marker comments; idempotent, preserves any
hand-written prose elsewhere in the file.

## Why this exists

Analyzing the same repo from scratch every session wastes tokens and time, and repos that
are split across services (frontend/backend/docs owned by the same team) otherwise can't
share what's already been learned. This index makes that knowledge durable, staleness-
checked, and reachable from any repo - not just the one it was written in.
