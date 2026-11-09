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
and the source paths its claims depend on. Freshness checks detect changes to those declared
sources; they do not prove the note is semantically correct or that its source list is complete.

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
scripts/repo-status.sh [path]      # defaults to $PWD; the ai-index opencode plugin already
                                    # printed this digest into context at session start
```

This prints which notes exist, notes needing review, and related repos with notes worth
checking. It is silent if the path isn't a git repo.

- Choose the relevant note and section; do not read every note by default. Read a fresh note
  before source review, but treat `fresh` as “no detected source changes,” not as proof of
  correctness or completeness.
- For claims central to the task, check the relevant implementation and, when useful, tests
  or configuration. Prioritize security, destructive operations, and external contracts.
  Reuse evidence already gathered; do not inspect extra files just to add citations.
- For stale notes, inspect changed declared sources first. Expand to callers, tests, or other
  sources only when needed to establish the claim. A missing/invalid SHA or source list,
  Git error, missing commit, or non-ancestor commit is unverified; do not rely on it.
- Do not advance a note's verification SHA after checking only some of its claims. Verify all
  claims the note retains, or split out the verified material and leave the rest unverified.
- For cross-repo claims, check the relevant evidence in that other repo when the current task
  relies on it. Name the repo and its revision or dated evidence; `related:` alone is not proof.
- Re-run status during a long session when changes may have occurred; plugin status is cached
  context, not a live guarantee.

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

Content rules:
- State behavior: what happens, when it happens, and important exceptions or boundaries.
- Support claims with relevant implementation paths. Cite a test only when an inspected,
  relevant test clarifies behavior; do not imply test coverage you did not inspect.
- Separate fact from inference. Label inferred rationale and date observations; do not invent
  a “why.” Omit it when evidence is unavailable.
- Keep notes brief: short bullets, related-note links instead of duplicated explanations,
  and omit details easily recovered from cited code. The `overview.md` ≤150-line and
  `areas/*.md` ≤200-line limits are ceilings, not targets. Split a hard-to-navigate topic into
  its own note and put a short summary/link in the overview.
- `sources` must include every repository-relative path in this repo that supports the note's
  claims. For cross-repo facts, cite the other repo and its revision/path or dated evidence in
  the note body; this repo's freshness does not cover that evidence. `related:` is navigation,
  not verification. Do not list unrelated paths as a substitute for claim-level evidence.
- If a claim cannot be verified economically, omit it or label its uncertainty explicitly.
- Never record secrets, tokens, or customer data - the vault syncs to other devices.
- Skip capture for throwaway/one-off investigation; only record durable findings.

Example density: `Failed queue messages are retried; malformed messages are logged as
permanent failures (lambda/handler.py, tests/test_handler.py).` Cite tests only if inspected.

After writing or editing a note, verify all retained claims and ensure declared sources are
clean and committed before stamping it:

```
scripts/note-touch.sh <note-path>      # sets sha=<repo HEAD>, verified=<today>; refuses dirty sources
```

`note-touch.sh` uses the active worktree when it shares the configured checkout's Git common
directory; when invoked elsewhere, it uses the configured checkout.

`STALE` means committed changes were detected under declared sources since the recorded SHA.
`DIRTY` means staged, unstaged, or non-ignored untracked declared-source changes exist; Git-ignored
artifacts do not count. `STALE+DIRTY` can report both. `UNVERIFIABLE` means the recorded commit is
missing or is not an ancestor of HEAD. `UNVERIFIED` means metadata, a declared source path, a
declared source's `assume-unchanged`/`skip-worktree` index flags, or a Git check could not be
trusted. Declared source paths must match tracked content at the recorded commit. These labels
validate metadata and change history only; they do not establish semantic correctness or
source-list completeness.

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
