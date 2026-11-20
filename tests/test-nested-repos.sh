#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GIT_ROOT="${TMP_DIR}/projects"
DOCS_ROOT="${TMP_DIR}/docs"
HOME_ROOT="${TMP_DIR}/home"
REPO="${GIT_ROOT}/galaxy_ng"
NESTED_REPO="${GIT_ROOT}/ansible/galaxy_ng"
WORKTREE="${GIT_ROOT}/worktrees/galaxy_ng"
NOTE="${DOCS_ROOT}/repos/galaxy_ng/overview.md"
COLLIDING_REPO="${GIT_ROOT}/pulp/feature"
COLLIDING_WORKTREE="${GIT_ROOT}/worktrees/feature"
COLLIDING_NOTE="${DOCS_ROOT}/repos/feature/overview.md"
STATUS_SCRIPT="${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh"
STALE_SCRIPT="${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh"
TOUCH_SCRIPT="${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh"
REGISTRY_SCRIPT="${REPO_ROOT}/skills/ai-index/scripts/repo-registry.sh"

mkdir -p "$REPO" "${DOCS_ROOT}/repos/galaxy_ng" "$HOME_ROOT/.config/opencode"
cat > "${HOME_ROOT}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT="${DOCS_ROOT}"
AI_INDEX_GIT_ROOT="${GIT_ROOT}"
EOF

git init -q -b main "$REPO"
git -C "$REPO" config user.name 'ai-index test'
git -C "$REPO" config user.email 'ai-index-test@example.invalid'
mkdir -p "${REPO}/src"
printf 'base\n' > "${REPO}/src/tracked.txt"
git -C "$REPO" add src
git -C "$REPO" commit -qm 'base'
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

cat > "$NOTE" <<EOF
---
repo: galaxy_ng
kind: overview
sha: ${BASE_SHA}
verified: "2026-01-01"
sources:
  - src/tracked.txt
---
# Test note
EOF

# Moving a checkout into an organization directory preserves its repo key and
# note freshness; only the registry path changes.
mkdir -p "$(dirname "$NESTED_REPO")"
mv "$REPO" "$NESTED_REPO"
REPO="$NESTED_REPO"

status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "$REPO")"
grep -Fq "repo=galaxy_ng @ main ${BASE_SHA:0:7}" <<< "$status"
grep -Fq 'notes: overview' <<< "$status"

explicit_status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "$REPO" --repo galaxy_ng)"
grep -Fq "repo=galaxy_ng @ main ${BASE_SHA:0:7}" <<< "$explicit_status"

stale="$(HOME="$HOME_ROOT" "$STALE_SCRIPT" galaxy_ng)"
grep -Fq "configured checkout: ${REPO}" <<< "$stale"
grep -Fq 'overview' <<< "$stale"

touch_output="$(HOME="$HOME_ROOT" "$TOUCH_SCRIPT" "$NOTE")"
grep -Fq "sha=${BASE_SHA:0:7}" <<< "$touch_output"

# A nested linked worktree maps to its configured primary checkout by common dir.
git -C "$REPO" worktree add -qb feature "$WORKTREE"
worktree_status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "$WORKTREE")"
grep -Fq "repo=galaxy_ng @ feature ${BASE_SHA:0:7}" <<< "$worktree_status"
touch_output="$(cd "$WORKTREE" && HOME="$HOME_ROOT" "$TOUCH_SCRIPT" "$NOTE")"
grep -Fq "sha=${BASE_SHA:0:7}" <<< "$touch_output"

# A linked worktree name that matches a different primary checkout must not
# shadow that checkout's repo key; primary checkouts define the identity.
git init -q -b main "$COLLIDING_REPO"
git -C "$COLLIDING_REPO" config user.name 'ai-index test'
git -C "$COLLIDING_REPO" config user.email 'ai-index-test@example.invalid'
printf 'feature repo\n' > "${COLLIDING_REPO}/tracked.txt"
git -C "$COLLIDING_REPO" add tracked.txt
git -C "$COLLIDING_REPO" commit -qm 'feature repo base'
COLLIDING_SHA="$(git -C "$COLLIDING_REPO" rev-parse HEAD)"
git -C "$REPO" worktree add -qb collision-feature "$COLLIDING_WORKTREE"
mkdir -p "$(dirname "$COLLIDING_NOTE")"
cat > "$COLLIDING_NOTE" <<EOF
---
repo: feature
kind: overview
sha: ${COLLIDING_SHA}
verified: "2026-01-01"
sources:
  - tracked.txt
---
# Collision test
EOF

collision_status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "$COLLIDING_REPO")"
grep -Fq "repo=feature @ main ${COLLIDING_SHA:0:7}" <<< "$collision_status"
collision_stale="$(HOME="$HOME_ROOT" "$STALE_SCRIPT" feature)"
grep -Fq "configured checkout: ${COLLIDING_REPO}" <<< "$collision_stale"

cat > "${DOCS_ROOT}/index.md" <<'EOF'
# Registry test

<!-- BEGIN registry -->
old row
<!-- END registry -->

Keep this prose.
EOF
HOME="$HOME_ROOT" "$REGISTRY_SCRIPT" >/dev/null
grep -Fq "| galaxy_ng | \`${REPO}\` |" "${DOCS_ROOT}/index.md"
grep -Fq '| galaxy_ng |' "${DOCS_ROOT}/index.md"
grep -Fq 'Keep this prose.' "${DOCS_ROOT}/index.md"

# Duplicate basenames cannot safely share a notes directory; reject the lookup
# and registry update instead of guessing which checkout owns those notes.
DUPLICATE="${GIT_ROOT}/pulp/galaxy_ng"
git init -q -b main "$DUPLICATE"
if HOME="$HOME_ROOT" "$STALE_SCRIPT" galaxy_ng >"${TMP_DIR}/duplicate.out" 2>"${TMP_DIR}/duplicate.err"; then
    echo 'stale-check unexpectedly accepted duplicate nested repo names' >&2
    exit 1
fi
grep -Fq 'multiple repos named' "${TMP_DIR}/duplicate.err"
if HOME="$HOME_ROOT" "$REGISTRY_SCRIPT" >"${TMP_DIR}/registry.out" 2>"${TMP_DIR}/registry.err"; then
    echo 'repo-registry unexpectedly accepted duplicate nested repo names' >&2
    exit 1
fi
grep -Fq 'duplicate repo name' "${TMP_DIR}/registry.err"
grep -Fq 'Keep this prose.' "${DOCS_ROOT}/index.md"

echo 'nested repository checks passed'
