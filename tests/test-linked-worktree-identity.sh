#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GIT_ROOT="${TMP_DIR}/git"
DOCS_ROOT="${TMP_DIR}/docs"
HOME_ROOT="${TMP_DIR}/home"
REPO="${GIT_ROOT}/sample"
WORKTREE="${TMP_DIR}/worktrees/sample-feature"
NOTE="${DOCS_ROOT}/repos/sample/area.md"
STATUS_SCRIPT="${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh"
STALE_SCRIPT="${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh"
TOUCH_SCRIPT="${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh"

mkdir -p "$GIT_ROOT" "$DOCS_ROOT/repos/sample" "$HOME_ROOT/.config/opencode"
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

git -C "$REPO" worktree add -qb feature "$WORKTREE"
printf 'feature\n' >> "${WORKTREE}/src/tracked.txt"
git -C "$WORKTREE" add src/tracked.txt
git -C "$WORKTREE" commit -qm 'feature source change'
FEATURE_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"

write_note() {
    cat > "$NOTE" <<EOF
---
repo: sample
sha: ${1}
verified: "2026-01-01"
sources:
  - src/tracked.txt
---
# Test note
EOF
}

write_note "$BASE_SHA"
status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "$WORKTREE")"
grep -Fq "repo=sample @ feature ${FEATURE_SHA:0:7}" <<< "$status"
grep -Fq 'STALE: area (1 commits since' <<< "$status"

# Touching from a linked worktree records that worktree's HEAD, not the primary checkout's.
touch_output="$(cd "$WORKTREE" && HOME="$HOME_ROOT" "$TOUCH_SCRIPT" "$NOTE")"
grep -Fq "$FEATURE_SHA" "$NOTE"
grep -Fq "sha=${FEATURE_SHA:0:7}" <<< "$touch_output"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$BASE_SHA" ]]
primary_status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "$REPO")"
grep -Fq "UNVERIFIABLE: area (sha ${FEATURE_SHA:0:7} is not an ancestor of HEAD)" <<< "$primary_status"

# A separate clone has a different common directory and keeps its own identity.
git clone -q "$REPO" "${GIT_ROOT}/sample-copy"
copy_status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "${GIT_ROOT}/sample-copy")"
grep -Fq 'repo=sample-copy' <<< "$copy_status"

# A configured worktree with no primary checkout under the Git root still has a
# unique configured identity; unrelated external clones are not searched.
EXTERNAL_BASE="${TMP_DIR}/external-base"
git init -q -b main "$EXTERNAL_BASE"
git -C "$EXTERNAL_BASE" config user.name 'ai-index test'
git -C "$EXTERNAL_BASE" config user.email 'ai-index-test@example.invalid'
printf 'external base\n' > "${EXTERNAL_BASE}/tracked.txt"
git -C "$EXTERNAL_BASE" add tracked.txt
git -C "$EXTERNAL_BASE" commit -qm 'external base'
EXTERNAL_SHA="$(git -C "$EXTERNAL_BASE" rev-parse HEAD)"
git -C "$EXTERNAL_BASE" worktree add -qb configured-worktree "${GIT_ROOT}/standalone-feature"
mkdir -p "${DOCS_ROOT}/repos/standalone-feature"
cat > "${DOCS_ROOT}/repos/standalone-feature/area.md" <<EOF
---
repo: standalone-feature
sha: ${EXTERNAL_SHA}
verified: "2026-01-01"
sources:
  - tracked.txt
---
# Test note
EOF
worktree_status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "${GIT_ROOT}/standalone-feature")"
grep -Fq 'repo=standalone-feature @ configured-worktree' <<< "$worktree_status"
worktree_stale="$(HOME="$HOME_ROOT" "$STALE_SCRIPT" standalone-feature)"
grep -Fq "repo=standalone-feature" <<< "$worktree_stale"
grep -Fq "configured checkout: ${GIT_ROOT}/standalone-feature" <<< "$worktree_stale"
grep -Fq 'area' <<< "$worktree_stale"

# A configured subdirectory inside a parent repository is not itself a worktree.
# Do not let Git's upward discovery check the parent checkout instead.
PARENT_ROOT="${TMP_DIR}/parent-checkout"
mkdir -p "${PARENT_ROOT}/nested"
git init -q -b main "$PARENT_ROOT"
cat > "${HOME_ROOT}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT="${DOCS_ROOT}"
AI_INDEX_GIT_ROOT="${PARENT_ROOT}"
EOF
if HOME="$HOME_ROOT" "$STALE_SCRIPT" nested >"${TMP_DIR}/nested.out" 2>"${TMP_DIR}/nested.err"; then
    echo 'stale-check unexpectedly accepted a parent repository for a nested configured path' >&2
    exit 1
fi
grep -Fq 'is not a Git worktree root' "${TMP_DIR}/nested.err"
cat > "${HOME_ROOT}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT="${DOCS_ROOT}"
AI_INDEX_GIT_ROOT="${GIT_ROOT}"
EOF

# Duplicate configured identities sharing one common directory must not be guessed.
mkdir -p "${GIT_ROOT}/sample-alias"
ln -s "${REPO}/.git" "${GIT_ROOT}/sample-alias/.git"
if HOME="$HOME_ROOT" "$STATUS_SCRIPT" "$WORKTREE" >"${TMP_DIR}/status.out" 2>"${TMP_DIR}/status.err"; then
    echo 'repo-status unexpectedly guessed an ambiguous identity' >&2
    exit 1
fi
grep -Fq 'ambiguous repository identity' "${TMP_DIR}/status.err"
status="$(HOME="$HOME_ROOT" "$STATUS_SCRIPT" "$WORKTREE" --repo sample)"
grep -Fq 'repo=sample @ feature' <<< "$status"

write_note "$BASE_SHA"
if (cd "$WORKTREE" && HOME="$HOME_ROOT" "$TOUCH_SCRIPT" "$NOTE") >"${TMP_DIR}/touch.out" 2>"${TMP_DIR}/touch.err"; then
    echo 'note-touch unexpectedly guessed an ambiguous identity' >&2
    exit 1
fi
grep -Fq 'ambiguous repository identity' "${TMP_DIR}/touch.err"
grep -Fq "$BASE_SHA" "$NOTE"

touch_output="$(HOME="$HOME_ROOT" "$TOUCH_SCRIPT" "$NOTE" --worktree "$WORKTREE")"
grep -Fq "$FEATURE_SHA" "$NOTE"
grep -Fq "sha=${FEATURE_SHA:0:7}" <<< "$touch_output"

echo 'linked worktree identity checks passed'
