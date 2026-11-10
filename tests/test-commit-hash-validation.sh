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

mkdir -p "$GIT_ROOT" "${DOCS_ROOT}/repos/sample" "$HOME_ROOT/.config/opencode"
cat > "${HOME_ROOT}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT="${DOCS_ROOT}"
AI_INDEX_GIT_ROOT="${GIT_ROOT}"
EOF

git init -q -b main "$REPO"
git -C "$REPO" config user.name 'ai-index test'
git -C "$REPO" config user.email 'ai-index-test@example.invalid'
printf 'before\n' > "${REPO}/tracked.txt"
git -C "$REPO" add tracked.txt
git -C "$REPO" commit -qm base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" branch before-change
git -C "$REPO" branch deadbeef

write_note() {
    local sha="$1"
    cat > "$NOTE" <<EOF
---
repo: sample
sha: "${sha}"
sources:
  - tracked.txt
---
# Test note
EOF
}

run_stale_check() {
    HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample
}

run_repo_status() {
    HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO"
}

# A symbolic HEAD must not follow later commits and falsely appear fresh.
write_note HEAD
printf 'after\n' > "${REPO}/tracked.txt"
git -C "$REPO" add tracked.txt
git -C "$REPO" commit -qm 'change source'

assert_invalid_sha() {
    local sha="$1" table status
    write_note "$sha"
    table="$(run_stale_check)"
    grep -Eq 'UNVERIFIABLE +invalid commit hash' <<< "$table"
    status="$(run_repo_status)"
    grep -Fq 'UNVERIFIABLE: area (invalid commit hash)' <<< "$status"
}

assert_invalid_sha HEAD
assert_invalid_sha main
assert_invalid_sha before-change
assert_invalid_sha deadbeef
assert_invalid_sha 'HEAD~1'

# Git resolves an unambiguous abbreviated object ID to the recorded commit.
SHORT_SHA="$(git -C "$REPO" rev-parse --short=12 "$BASE_SHA")"
write_note "$SHORT_SHA"
table="$(run_stale_check)"
grep -Eq 'area +[[:xdigit:]]+ +STALE +1 commits since recorded sha' <<< "$table"
status="$(run_repo_status)"
grep -Fq 'STALE: area (1 commits since' <<< "$status"

# A full commit hash from note-touch remains accepted and is stored as YAML text.
write_note "$BASE_SHA"
HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh" "$NOTE" >/dev/null
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
grep -Eq '^sha: "[[:xdigit:]]{40,64}"$' "$NOTE"
[[ "$(yq --front-matter=extract '.sha | type' "$NOTE")" == '!!str' ]]
[[ "$(yq --front-matter=extract '.sha' "$NOTE")" == "$HEAD_SHA" ]]
table="$(run_stale_check)"
grep -Eq 'area +[[:xdigit:]]+ +fresh +no commits to sources' <<< "$table"

# Numeric-only hashes must remain strings in YAML, not be coerced to numbers.
source "${REPO_ROOT}/skills/ai-index/scripts/fm.sh"
NUMERIC_SHA='1234567890123456789012345678901234567890'
fm_set "$NOTE" sha "$NUMERIC_SHA"
grep -Fq "sha: \"${NUMERIC_SHA}\"" "$NOTE"
[[ "$(yq --front-matter=extract '.sha | type' "$NOTE")" == '!!str' ]]
[[ "$(yq --front-matter=extract '.sha' "$NOTE")" == "$NUMERIC_SHA" ]]

echo 'commit hash validation checks passed'
