#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GIT_ROOT="${TMP_DIR}/git"
DOCS_ROOT="${TMP_DIR}/docs"
HOME_ROOT="${TMP_DIR}/home"
REPO="${GIT_ROOT}/sample"
NOTE="${DOCS_ROOT}/repos/sample/area.md"

mkdir -p "$GIT_ROOT" "$DOCS_ROOT/repos/sample" "$HOME_ROOT/.config/opencode"
cat > "${HOME_ROOT}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT="${DOCS_ROOT}"
AI_INDEX_GIT_ROOT="${GIT_ROOT}"
EOF

git init -q -b main "$REPO"
git -C "$REPO" config user.name 'ai-index test'
git -C "$REPO" config user.email 'ai-index-test@example.invalid'
printf 'before\n' > "${REPO}/tracked.txt"
git -C "$REPO" add tracked.txt
git -C "$REPO" commit -qm 'base'
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" switch -qc feature
printf 'feature source\n' > "${REPO}/feature-only.txt"
git -C "$REPO" add feature-only.txt
git -C "$REPO" commit -qm 'feature source'
FEATURE_SHA="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" switch -q main
printf 'main only\n' > "${REPO}/unrelated.txt"
git -C "$REPO" add unrelated.txt
git -C "$REPO" commit -qm 'unrelated main change'

write_note() {
    local sha="$1" source="$2"
    cat > "$NOTE" <<EOF
---
repo: sample
sha: ${sha}
sources:
  - ${source}
---
# Test note
EOF
}

write_note "$FEATURE_SHA" feature-only.txt
[[ "$(git -C "$REPO" rev-list --count "${FEATURE_SHA}..HEAD" -- feature-only.txt)" == 0 ]]

status_output="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Fq "UNVERIFIABLE: area (sha ${FEATURE_SHA:0:7} is not an ancestor of HEAD)" <<< "$status_output"

table_output="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Eq 'UNVERIFIABLE +sha is not an ancestor of HEAD' <<< "$table_output"

write_note "$BASE_SHA" tracked.txt
table_output="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Eq 'fresh +no commits to sources since recorded sha' <<< "$table_output"

printf 'after\n' > "${REPO}/tracked.txt"
git -C "$REPO" add tracked.txt
git -C "$REPO" commit -qm 'change tracked source'

status_output="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Fq 'STALE: area (1 commits since' <<< "$status_output"

table_output="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Eq 'STALE +1 commits since recorded sha' <<< "$table_output"

echo 'branch freshness checks passed'
