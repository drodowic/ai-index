#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATUS="${ROOT}/skills/ai-index/scripts/repo-status.sh"
STALE="${ROOT}/skills/ai-index/scripts/stale-check.sh"
TOUCH="${ROOT}/skills/ai-index/scripts/note-touch.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-index-worktree-submodules.XXXXXX")"
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

# Build two submodule levels; the second top-level submodule is outside the declared source.
init_repo "${TMP}/leaf-source"
printf 'leaf source\n' >"${TMP}/leaf-source/leaf file.txt"
git -C "${TMP}/leaf-source" add .
git -C "${TMP}/leaf-source" commit -qm initial
init_repo "${TMP}/child-source"
printf 'child source\n' >"${TMP}/child-source/child file.txt"
git -C "${TMP}/child-source" add .
git -C "${TMP}/child-source" commit -qm initial
git -C "${TMP}/child-source" -c protocol.file.allow=always submodule add -q \
    "${TMP}/leaf-source" 'nested module'
git -C "${TMP}/child-source" commit -qm 'add nested submodule'
init_repo "${TMP}/repos/modules"
printf 'unrelated\n' >"${TMP}/repos/modules/README.md"
git -C "${TMP}/repos/modules" -c protocol.file.allow=always submodule add -q \
    "${TMP}/child-source" 'src/child module'
git -C "${TMP}/repos/modules" -c protocol.file.allow=always submodule add -q \
    "${TMP}/child-source" 'other/child module'
git -C "${TMP}/repos/modules" add README.md
git -C "${TMP}/repos/modules" commit -qm 'add submodules'
git -C "${TMP}/repos/modules" -c protocol.file.allow=always submodule update --init --recursive -q -- 'src/child module'
MODULE_SHA="$(git -C "${TMP}/repos/modules" rev-parse HEAD)"
write_note modules "$MODULE_SHA" src/
MODULE_NOTE="${TMP}/vault/repos/modules/overview.md"
CHILD="${TMP}/repos/modules/src/child module"
LEAF="${CHILD}/nested module"
expect_contains "$(bash "$STATUS" "${TMP}/repos/modules")" '1 fresh, 0 needing review'

expect_flagged() {
    local before
    expect_contains "$(bash "$STATUS" "${TMP}/repos/modules")" 'UNVERIFIED: overview'
    expect_contains "$(bash "$STALE" modules)" 'assume-unchanged or skip-worktree index flags'
    before="$(sha256sum "$MODULE_NOTE")"
    if bash "$TOUCH" "$MODULE_NOTE" >"${TMP}/touch-error" 2>&1; then
        fail 'note-touch accepted a flagged submodule source'
    fi
    expect_contains "$(cat "${TMP}/touch-error")" 'assume-unchanged or skip-worktree index flags'
    [[ "$(sha256sum "$MODULE_NOTE")" == "$before" ]] || fail 'note-touch modified a flagged note'
}

# Declaring the gitlink directly must inspect its contents as well as a parent directory does.
write_note modules "$MODULE_SHA" 'src/child module'
git -C "$CHILD" update-index --assume-unchanged -- 'child file.txt'
printf 'hidden edit\n' >>"${CHILD}/child file.txt"
expect_flagged
git -C "$CHILD" update-index --no-assume-unchanged -- 'child file.txt'
git -C "$CHILD" show 'HEAD:child file.txt' >"${CHILD}/child file.txt"
write_note modules "$MODULE_SHA" src/

for flag in assume-unchanged skip-worktree; do
    git -C "$CHILD" update-index "--${flag}" -- 'child file.txt'
    printf 'hidden edit\n' >>"${CHILD}/child file.txt"
    git -C "${TMP}/repos/modules" diff --ignore-submodules=none --quiet -- src || fail 'child edit is not hidden'
    expect_flagged
    git -C "$CHILD" update-index "--no-${flag}" -- 'child file.txt'
    git -C "$CHILD" show 'HEAD:child file.txt' >"${CHILD}/child file.txt"

    git -C "$LEAF" update-index "--${flag}" -- 'leaf file.txt'
    printf 'hidden edit\n' >>"${LEAF}/leaf file.txt"
    git -C "${TMP}/repos/modules" diff --ignore-submodules=none --quiet -- src || fail 'nested edit is not hidden'
    expect_flagged
    git -C "$LEAF" update-index "--no-${flag}" -- 'leaf file.txt'
    git -C "$LEAF" show 'HEAD:leaf file.txt' >"${LEAF}/leaf file.txt"
done

# The top-level gitlink itself must remain visible to the flag check.
git -C "${TMP}/repos/modules" update-index --assume-unchanged -- 'src/child module'
printf 'hidden child edit\n' >>"${CHILD}/child file.txt"
expect_flagged
git -C "${TMP}/repos/modules" update-index --no-assume-unchanged -- 'src/child module'
git -C "$CHILD" show 'HEAD:child file.txt' >"${CHILD}/child file.txt"

# A flag on an intermediate gitlink is omitted by recursive ls-files, but must be checked.
for flag in assume-unchanged skip-worktree; do
    git -C "$CHILD" update-index "--${flag}" -- 'nested module'
    printf 'hidden nested edit\n' >>"${LEAF}/leaf file.txt"
    expect_flagged
    git -C "$CHILD" update-index "--no-${flag}" -- 'nested module'
    git -C "$LEAF" show 'HEAD:leaf file.txt' >"${LEAF}/leaf file.txt"
done

# A Git failure in a child index cannot be mistaken for a clean source.
REAL_GIT="$(command -v git)"
mkdir -p "${TMP}/fake-bin"
cat >"${TMP}/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -C && "${2:-}" == "${AI_INDEX_TEST_FAIL_ROOT:-}" && "${3:-}" == ls-files ]]; then
    exit 77
fi
if [[ "${3:-}" == worktree && "${AI_INDEX_TEST_FAIL_WORKTREES:-0}" == 1 ]]; then
    exit 78
fi
exec "$AI_INDEX_TEST_REAL_GIT" "$@"
EOF
chmod +x "${TMP}/fake-bin/git"
output="$(AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_FAIL_WORKTREES=1 PATH="${TMP}/fake-bin:$PATH" \
    bash "$STATUS" "${TMP}/repos/modules")"
expect_contains "$output" 'UNVERIFIED: Git could not identify the configured worktree'
output="$(AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_FAIL_ROOT="$CHILD" PATH="${TMP}/fake-bin:$PATH" \
    bash "$STATUS" "${TMP}/repos/modules")"
expect_contains "$output" 'UNVERIFIED: overview'
expect_contains "$output" 'could not inspect declared source index flags'
if AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_FAIL_ROOT="$CHILD" PATH="${TMP}/fake-bin:$PATH" \
    bash "$TOUCH" "$MODULE_NOTE" >"${TMP}/touch-error" 2>&1; then
    fail 'note-touch accepted a failed submodule index check'
fi
expect_contains "$(cat "${TMP}/touch-error")" 'could not inspect declared source index flags'

# Flags and uninitialized nested submodules outside the declared sources do not matter.
git -C "${TMP}/repos/modules/other/child module" update-index --assume-unchanged -- 'child file.txt'
printf 'unrelated hidden edit\n' >>"${TMP}/repos/modules/other/child module/child file.txt"
expect_contains "$(bash "$STATUS" "${TMP}/repos/modules")" '1 fresh, 0 needing review'
bash "$TOUCH" "$MODULE_NOTE" >/dev/null

# Uninitialized submodules inside a source cannot be verified; unrelated ones are ignored.
git clone -q --no-local "${TMP}/repos/modules" "${TMP}/repos/modules-copy"
write_note modules-copy "$MODULE_SHA" README.md
expect_contains "$(bash "$STATUS" "${TMP}/repos/modules-copy")" '1 fresh, 0 needing review'
bash "$TOUCH" "${TMP}/vault/repos/modules-copy/overview.md" >/dev/null
write_note modules-copy "$MODULE_SHA" src/
expect_contains "$(bash "$STATUS" "${TMP}/repos/modules-copy")" 'declared submodule is unavailable'
expect_contains "$(bash "$STALE" modules-copy)" 'UNVERIFIED'
BEFORE_UNAVAILABLE_TOUCH="$(sha256sum "${TMP}/vault/repos/modules-copy/overview.md")"
if bash "$TOUCH" "${TMP}/vault/repos/modules-copy/overview.md" >"${TMP}/touch-error" 2>&1; then
    fail 'note-touch accepted an unavailable declared submodule'
fi
expect_contains "$(cat "${TMP}/touch-error")" 'declared submodule is unavailable'
[[ "$(sha256sum "${TMP}/vault/repos/modules-copy/overview.md")" == "$BEFORE_UNAVAILABLE_TOUCH" ]] || \
    fail 'note-touch modified a note with an unavailable submodule'
git -C "${TMP}/repos/modules-copy" -c protocol.file.allow=always submodule update --init -q -- 'src/child module'
expect_contains "$(bash "$STATUS" "${TMP}/repos/modules-copy")" 'declared submodule is unavailable'
git -C "${TMP}/repos/modules-copy" -c protocol.file.allow=always submodule update --init --recursive -q -- 'src/child module'
expect_contains "$(bash "$STATUS" "${TMP}/repos/modules-copy")" '1 fresh, 0 needing review'

echo 'PASS: linked-worktree identity and recursive submodule flags'
