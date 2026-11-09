#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATUS="${ROOT}/skills/ai-index/scripts/repo-status.sh"
STALE="${ROOT}/skills/ai-index/scripts/stale-check.sh"
TOUCH="${ROOT}/skills/ai-index/scripts/note-touch.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-index-worktree-status.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="${TMP}/home"
mkdir -p "${HOME}/.config/opencode" "${TMP}/repos" "${TMP}/vault/repos"
cat >"${HOME}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT='${TMP}/vault'
AI_INDEX_GIT_ROOT='${TMP}/repos'
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2; got: $1"; }
init_repo() {
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.name 'ai-index tests'
    git -C "$1" config user.email 'ai-index-tests@example.invalid'
}
write_note() {
    local repo="$1" sha="$2" source="$3"
    mkdir -p "${TMP}/vault/repos/${repo}"
    cat >"${TMP}/vault/repos/${repo}/overview.md" <<EOF
---
repo: ${repo}
sha: "${sha}"
sources:
  - "${source}"
---
EOF
}

# The main checkout is outside the root; both candidates inside it are linked worktrees.
init_repo "${TMP}/outside"
printf 'source\n' >"${TMP}/outside/source.txt"
git -C "${TMP}/outside" add source.txt
git -C "${TMP}/outside" commit -qm initial
BASE_SHA="$(git -C "${TMP}/outside" rev-parse HEAD)"
git -C "${TMP}/outside" worktree add -qb configured "${TMP}/repos/demo"
git -C "${TMP}/outside" worktree add -qb feature "${TMP}/repos/aaa-feature"
write_note demo "$BASE_SHA" source.txt

for path in "${TMP}/repos/demo" "${TMP}/repos/aaa-feature"; do
    output="$(bash "$STATUS" "$path")"
    expect_contains "$output" 'repo=demo'
    expect_contains "$output" '1 fresh, 0 needing review'
done

# The selected key is shared, but freshness uses the active worktree's HEAD.
printf 'feature change\n' >>"${TMP}/repos/aaa-feature/source.txt"
git -C "${TMP}/repos/aaa-feature" commit -qam 'feature change'
expect_contains "$(bash "$STATUS" "${TMP}/repos/aaa-feature")" 'STALE: overview'
expect_contains "$(bash "$STATUS" "${TMP}/repos/demo")" '1 fresh, 0 needing review'
(
    cd "${TMP}/repos/aaa-feature"
    bash "$TOUCH" "${TMP}/vault/repos/demo/overview.md" >/dev/null
)
[[ "$(yq --front-matter=extract '.sha' "${TMP}/vault/repos/demo/overview.md")" == \
    "$(git -C "${TMP}/repos/aaa-feature" rev-parse HEAD)" ]] || fail 'touch did not use active linked worktree'

# Worktree paths are NUL-delimited so a newline cannot hide a conflicting note key.
NEWLINE_KEY=$'aaa\nnewline'
git -C "${TMP}/outside" worktree add -qb newline "${TMP}/repos/${NEWLINE_KEY}"
mkdir -p "${TMP}/vault/repos/${NEWLINE_KEY}"
printf '%s\n' '---' 'repo: "aaa\nnewline"' "sha: \"$BASE_SHA\"" 'sources:' '  - source.txt' '---' \
    >"${TMP}/vault/repos/${NEWLINE_KEY}/overview.md"
expect_contains "$(bash "$STATUS" "${TMP}/repos/demo")" 'UNVERIFIED: ambiguous worktree note keys:'
rm -f "${TMP}/vault/repos/${NEWLINE_KEY}/overview.md"

# Multiple existing note keys are ambiguous even when one is the active worktree.
write_note aaa-feature "$(git -C "${TMP}/repos/aaa-feature" rev-parse HEAD)" source.txt
for path in "${TMP}/repos/demo" "${TMP}/repos/aaa-feature"; do
    output="$(bash "$STATUS" "$path")"
    expect_contains "$output" 'UNVERIFIED: ambiguous worktree note keys:'
    expect_contains "$output" 'aaa-feature'
    expect_contains "$output" 'demo'
done

# Without notes, multiple linked worktrees and no primary checkout are ambiguous too.
init_repo "${TMP}/other-outside"
printf 'source\n' >"${TMP}/other-outside/source.txt"
git -C "${TMP}/other-outside" add .
git -C "${TMP}/other-outside" commit -qm initial
git -C "${TMP}/other-outside" worktree add -qb first "${TMP}/repos/first"
git -C "${TMP}/other-outside" worktree add -qb second "${TMP}/repos/second"
expect_contains "$(bash "$STATUS" "${TMP}/repos/first")" 'UNVERIFIED: ambiguous worktrees without a note key:'

# A primary checkout resolves a no-note sibling, but conflicting note keys remain ambiguous.
init_repo "${TMP}/repos/standalone"
printf 'source\n' >"${TMP}/repos/standalone/source.txt"
git -C "${TMP}/repos/standalone" add .
git -C "${TMP}/repos/standalone" commit -qm initial
STANDALONE_SHA="$(git -C "${TMP}/repos/standalone" rev-parse HEAD)"
git -C "${TMP}/repos/standalone" worktree add -qb standalone-feature "${TMP}/repos/standalone-feature"
expect_contains "$(bash "$STATUS" "${TMP}/repos/standalone-feature")" 'repo=standalone - no index notes yet'
write_note standalone "$STANDALONE_SHA" source.txt
write_note standalone-feature "$STANDALONE_SHA" source.txt
expect_contains "$(bash "$STATUS" "${TMP}/repos/standalone")" 'UNVERIFIED: ambiguous worktree note keys:'

echo 'PASS: linked-worktree note identity'
