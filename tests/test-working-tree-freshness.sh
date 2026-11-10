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
mkdir -p "${REPO}/src/dir"
printf 'original\n' > "${REPO}/src/tracked.txt"
printf 'directory baseline\n' > "${REPO}/src/dir/tracked.txt"
printf 'src/dir/cache/\n' > "${REPO}/.gitignore"
git -C "$REPO" add .gitignore src
git -C "$REPO" commit -qm 'base'
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

write_note() {
    local source="$1"
    cat > "$NOTE" <<EOF
---
repo: sample
sha: ${HEAD_SHA}
verified: "2026-01-01"
sources:
  - ${source}
---
# Test note
EOF
}

write_note_without_sha() {
    local source="$1"
    cat > "$NOTE" <<EOF
---
repo: sample
sources:
  - ${source}
---
# Test note
EOF
}

touch_note_must_fail() {
    local expected_path="$1"
    if HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh" "$NOTE" >"${TMP_DIR}/touch.out" 2>"${TMP_DIR}/touch.err"; then
        echo 'note-touch unexpectedly succeeded' >&2
        exit 1
    fi
    grep -Fq 'refusing to stamp' "${TMP_DIR}/touch.err"
    grep -Fq "$expected_path" "${TMP_DIR}/touch.err"
    grep -Fq "$HEAD_SHA" "$NOTE"
}

write_note src/tracked.txt
touch_output="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh" "$NOTE")"
grep -Fq 'verified=' <<< "$touch_output"
grep -Fq "$HEAD_SHA" "$NOTE"

# Unrelated untracked paths do not stale this note.
printf 'unrelated\n' > "${REPO}/unrelated.txt"
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Eq 'area +[[:xdigit:]]+ +fresh +no commits to sources' <<< "$table"
rm "${REPO}/unrelated.txt"

# assume-unchanged can hide an edit to a declared file from git status.
write_note src/tracked.txt
git -C "$REPO" update-index --assume-unchanged -- src/tracked.txt
printf 'hidden edit\n' > "${REPO}/src/tracked.txt"
if [ -n "$(git -C "$REPO" status --porcelain -- src/tracked.txt)" ]; then
    echo 'assume-unchanged edit was expected to be hidden from git status' >&2
    exit 1
fi
status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Fq 'UNVERIFIABLE: area' <<< "$status"
grep -Fq 'flagged index paths (assume-unchanged/skip-worktree): src/tracked.txt' <<< "$status"
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Fq 'UNVERIFIABLE' <<< "$table"
grep -Fq 'src/tracked.txt' <<< "$table"
touch_note_must_fail src/tracked.txt
git -C "$REPO" update-index --no-assume-unchanged -- src/tracked.txt
printf 'original\n' > "${REPO}/src/tracked.txt"

# A flagged descendant makes a declared directory unverifiable.
write_note src/dir/
git -C "$REPO" update-index --skip-worktree -- src/dir/tracked.txt
printf 'hidden directory edit\n' > "${REPO}/src/dir/tracked.txt"
if [ -n "$(git -C "$REPO" status --porcelain -- src/dir/tracked.txt)" ]; then
    echo 'skip-worktree edit was expected to be hidden from git status' >&2
    exit 1
fi
status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Fq 'UNVERIFIABLE: area' <<< "$status"
grep -Fq 'src/dir/tracked.txt' <<< "$status"
touch_note_must_fail src/dir/tracked.txt
git -C "$REPO" update-index --no-skip-worktree -- src/dir/tracked.txt
printf 'directory baseline\n' > "${REPO}/src/dir/tracked.txt"

# A flagged file outside the note's sources is irrelevant and does not block stamping.
write_note src/tracked.txt
git -C "$REPO" update-index --assume-unchanged -- src/dir/tracked.txt
status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
if grep -Eq '(STALE|UNVERIFIABLE): area' <<< "$status"; then
    echo 'unrelated flagged file affected source freshness' >&2
    exit 1
fi
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Eq 'area +[[:xdigit:]]+ +fresh +no commits to sources' <<< "$table"
touch_output="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh" "$NOTE")"
grep -Fq 'verified=' <<< "$touch_output"
git -C "$REPO" update-index --no-assume-unchanged -- src/dir/tracked.txt

# Unstaged and staged edits to a declared file are stale and cannot be stamped.
printf 'unstaged edit\n' > "${REPO}/src/tracked.txt"
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Fq 'STALE' <<< "$table"
grep -Fq 'src/tracked.txt' <<< "$table"
status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Fq 'STALE: area' <<< "$status"
touch_note_must_fail src/tracked.txt

# Without a recorded baseline, source edits are still reported as unverifiable/stale.
write_note_without_sha src/tracked.txt
printf 'missing baseline edit\n' > "${REPO}/src/tracked.txt"
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Fq 'UNVERIFIABLE' <<< "$table"
grep -Fq 'src/tracked.txt' <<< "$table"
status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Fq 'UNVERIFIABLE: area (no sha recorded' <<< "$status"
printf 'original\n' > "${REPO}/src/tracked.txt"
write_note src/tracked.txt
printf 'staged edit\n' > "${REPO}/src/tracked.txt"
git -C "$REPO" add src/tracked.txt
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Fq 'STALE' <<< "$table"
touch_note_must_fail src/tracked.txt

git -C "$REPO" reset -q -- src/tracked.txt
printf 'original\n' > "${REPO}/src/tracked.txt"

# Directory sources include non-ignored untracked descendants.
write_note src/dir/
printf 'new source\n' > "${REPO}/src/dir/new.txt"
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Fq 'STALE' <<< "$table"
grep -Fq 'src/dir/new.txt' <<< "$table"
touch_note_must_fail src/dir/new.txt
rm "${REPO}/src/dir/new.txt"

# Ignored generated descendants do not affect a directory source.
mkdir -p "${REPO}/src/dir/cache"
printf 'ignored source\n' > "${REPO}/src/dir/cache/data.txt"
write_note src/dir/
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Eq 'area +[[:xdigit:]]+ +fresh +no commits to sources' <<< "$table"
if grep -Eq '(STALE|UNVERIFIABLE): area' <<< "$status"; then
    echo 'ignored cache made a clean directory source stale or unverifiable' >&2
    exit 1
fi
touch_output="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh" "$NOTE")"
grep -Fq 'verified=' <<< "$touch_output"

# An explicitly declared ignored file has no tracked baseline and stays unverifiable.
write_note src/dir/cache/data.txt
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Fq 'UNVERIFIABLE' <<< "$table"
grep -Fq 'src/dir/cache/data.txt' <<< "$table"
status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Fq 'UNVERIFIABLE: area' <<< "$status"
grep -Fq 'src/dir/cache/data.txt' <<< "$status"
touch_note_must_fail src/dir/cache/data.txt

rm -rf "${REPO}/src/dir/cache"
write_note ../external.txt
table="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/stale-check.sh" sample)"
grep -Fq 'UNVERIFIABLE' <<< "$table"
grep -Fq '../external.txt' <<< "$table"
status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$REPO")"
grep -Fq 'UNVERIFIABLE: area' <<< "$status"
grep -Fq '../external.txt' <<< "$status"
touch_note_must_fail ../external.txt

echo 'working-tree freshness checks passed'
