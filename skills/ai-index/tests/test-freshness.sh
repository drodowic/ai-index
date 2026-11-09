#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATUS_SCRIPT="${ROOT}/skills/ai-index/scripts/repo-status.sh"
STALE_SCRIPT="${ROOT}/skills/ai-index/scripts/stale-check.sh"
TOUCH_SCRIPT="${ROOT}/skills/ai-index/scripts/note-touch.sh"
PLUGIN="${ROOT}/plugins/ai-index/plugin.js"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-index-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="${TMP}/home"
mkdir -p "${HOME}/.config/opencode" "${TMP}/vault/repos/demo" "${TMP}/repos/demo"
export AI_INDEX_DOCS_ROOT="${TMP}/vault"
export AI_INDEX_GIT_ROOT="${TMP}/repos"
cat >"${HOME}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT='${AI_INDEX_DOCS_ROOT}'
AI_INDEX_GIT_ROOT='${AI_INDEX_GIT_ROOT}'
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }
expect_status() {
    local expected="$1" status_output stale_output
    status_output="$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo")"
    stale_output="$(bash "$STALE_SCRIPT" demo)"
    expect_contains "$status_output" "$expected"
    expect_contains "$stale_output" "$expected"
    [[ ${#status_output} -lt 1600 ]] || fail "plugin status digest grew unexpectedly (${#status_output} chars)"
}

cd "${TMP}/repos/demo"
git init -q
git config user.name 'ai-index tests'
git config user.email 'ai-index-tests@example.invalid'
mkdir -p src
printf 'initial\n' >'src/path with spaces.txt'
printf '/src/node_modules/\n' >.gitignore
printf 'unrelated\n' >README.md
git add .
git commit -qm 'initial'
BASE_SHA="$(git rev-parse HEAD)"
NOTE="${TMP}/vault/repos/demo/overview.md"

write_note() {
    local sha="$1"
    cat >"$NOTE" <<EOF
---
repo: demo
sha: "${sha}"
sources:
  - "src/path with spaces.txt"
  - "src/"
---

Test note.
EOF
}

write_directory_note() {
    cat >"$NOTE" <<EOF
---
repo: demo
sha: "${1}"
sources:
  - "src/"
---

Directory-source note.
EOF
}

write_submodule_note() {
    cat >"$NOTE" <<EOF
---
repo: demo
sha: "${1}"
sources:
  - "src/ignored-submodule/"
---

Submodule-source note.
EOF
}

write_typo_note() {
    cat >"$NOTE" <<EOF
---
repo: demo
sha: "${1}"
sources:
  - "src/typo.js"
---

Misspelled-source note.
EOF
}

write_deleted_note() {
    cat >"$NOTE" <<EOF
---
repo: demo
sha: "${1}"
sources:
  - "deleted source.txt"
---

Deleted-source note.
EOF
}

write_note "$BASE_SHA"
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo")" '1 fresh, 0 needing review'
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'fresh'

# Unrelated commits do not stale a note.
printf 'unrelated update\n' >>README.md
git add README.md
git commit -qm 'unrelated change'
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo")" '1 fresh, 0 needing review'

# A declared source change is stale; both scripts share the same result.
printf 'committed change\n' >>'src/path with spaces.txt'
git add 'src/path with spaces.txt'
git commit -qm 'declared source change'
expect_status STALE
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'committed source change(s)'
printf 'staged while stale\n' >>'src/path with spaces.txt'
git add 'src/path with spaces.txt'
expect_status 'STALE+DIRTY'
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'staged=1'
git commit -qm 'another declared source change'

# note-touch works on clean sources and records the current commit.
write_note ''
bash "$TOUCH_SCRIPT" "$NOTE" >/dev/null
TOUCHED_SHA="$(yq --front-matter=extract '.sha' "$NOTE")"
[[ "$TOUCHED_SHA" == "$(git rev-parse HEAD)" ]] || fail 'note-touch did not stamp HEAD'
yq --front-matter=extract '.verified' "$NOTE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || fail 'note-touch did not set verified date'

# Staged, unstaged, and untracked source edits are distinct and never fresh.
printf 'staged\n' >>'src/path with spaces.txt'
git add 'src/path with spaces.txt'
expect_status DIRTY
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'staged=1'
git commit -qm 'staged source change'
write_note "$(git rev-parse HEAD)"

printf 'unstaged\n' >>'src/path with spaces.txt'
expect_status DIRTY
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'unstaged=1'
git add 'src/path with spaces.txt'
git commit -qm 'unstaged source change'
write_note "$(git rev-parse HEAD)"

mkdir -p 'src/new area'
printf 'untracked\n' >'src/new area/untracked file.txt'
expect_status DIRTY
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'untracked=1'

# note-touch refuses to stamp a dirty declared source and leaves metadata unchanged.
BEFORE_DIRTY_TOUCH="$(yq --front-matter=extract '.sha' "$NOTE")"
BEFORE_DIRTY_NOTE="$(sha256sum "$NOTE")"
if bash "$TOUCH_SCRIPT" "$NOTE" >"${TMP}/touch.out" 2>&1; then fail 'note-touch accepted dirty sources'; fi
expect_contains "$(cat "${TMP}/touch.out")" 'uncommitted changes'
expect_contains "$(cat "${TMP}/touch.out")" 'HEAD cannot represent the current source state'
[[ "$(yq --front-matter=extract '.sha' "$NOTE")" == "$BEFORE_DIRTY_TOUCH" ]] || fail 'note-touch changed SHA on dirty sources'
[[ "$(sha256sum "$NOTE")" == "$BEFORE_DIRTY_NOTE" ]] || fail 'note-touch modified note metadata on dirty sources'

# Deleted declared sources remain detectable as committed changes.
git add 'src/new area/untracked file.txt'
git commit -qm 'add source-area file'
write_note "$(git rev-parse HEAD)"
printf 'deletable\n' >'deleted source.txt'
git add 'deleted source.txt'
git commit -qm 'add source file'
write_deleted_note "$(git rev-parse HEAD)"
git rm -q 'deleted source.txt'
git commit -qm 'delete declared source'
expect_status STALE

# Missing SHA, missing sources, malformed YAML, missing commit, and non-ancestor SHA.
cat >"$NOTE" <<'EOF'
---
repo: demo
sources:
  - README.md
---
EOF
expect_status UNVERIFIED

cat >"$NOTE" <<EOF
---
repo: demo
sha: $(git rev-parse HEAD)
---
EOF
expect_status UNVERIFIED

cat >"$NOTE" <<'EOF'
---
repo: demo
sha: [not: valid
sources: []
---
EOF
expect_status UNVERIFIED

write_note "$(printf '%40s' '' | tr ' ' f)"
expect_status UNVERIFIABLE

# Git-valid abbreviated commit SHAs remain accepted; malformed short values do not.
SHORT_SHA="$(git rev-parse --short HEAD)"
write_note "$SHORT_SHA"
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo")" '1 fresh, 0 needing review'
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'fresh'
printf 'abbreviated SHA source change\n' >>'src/path with spaces.txt'
git add 'src/path with spaces.txt'
git commit -qm 'change source after abbreviated note SHA'
expect_status STALE
write_note abc
expect_status UNVERIFIED

ORPHAN_TREE="$(git mktree </dev/null)"
ORPHAN_SHA="$(printf 'orphan commit\n' | git commit-tree "$ORPHAN_TREE")"
write_note "$ORPHAN_SHA"
expect_status UNVERIFIABLE
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'not an ancestor'

# A syntactically valid but nonexistent source path is unverified, never stampable.
write_typo_note "$(git rev-parse HEAD)"
expect_status UNVERIFIED
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'src/typo.js'
BEFORE_TYPO_NOTE="$(sha256sum "$NOTE")"
if bash "$TOUCH_SCRIPT" "$NOTE" >"${TMP}/typo-touch.out" 2>&1; then fail 'note-touch accepted a nonexistent source path'; fi
expect_contains "$(cat "${TMP}/typo-touch.out")" 'matched no tracked path at HEAD: src/typo.js'
[[ "$(sha256sum "$NOTE")" == "$BEFORE_TYPO_NOTE" ]] || fail 'note-touch modified note with nonexistent sources'

# A trailing slash denotes a valid directory source and works for status and stamping.
write_directory_note "$(git rev-parse HEAD)"
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo")" '1 fresh, 0 needing review'
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'fresh'
bash "$TOUCH_SCRIPT" "$NOTE" >/dev/null
mkdir -p src/node_modules/generated
printf 'ignored artifact\n' >src/node_modules/generated/index.js
git check-ignore -q src/node_modules/generated/index.js || fail 'node_modules fixture is not ignored'
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo")" '1 fresh, 0 needing review'
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'fresh'
bash "$TOUCH_SCRIPT" "$NOTE" >/dev/null

printf 'directory source\n' >>'src/path with spaces.txt'
git add 'src/path with spaces.txt'
expect_status DIRTY
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'staged=1'
git commit -qm 'directory source change'
write_directory_note "$(git rev-parse HEAD)"

# assume-unchanged can hide edits from diff; flagged sources must be unverified and unstampable.
git update-index --assume-unchanged -- 'src/path with spaces.txt'
printf 'assume-unchanged edit\n' >>'src/path with spaces.txt'
if git diff --quiet -- 'src/path with spaces.txt'; then
    : # Ensure the fixture reproduces Git's index-flag behavior.
else
    fail 'assume-unchanged fixture is visible to git diff'
fi
expect_status UNVERIFIED
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'assume-unchanged or skip-worktree index flags'
BEFORE_ASSUME_TOUCH="$(sha256sum "$NOTE")"
if bash "$TOUCH_SCRIPT" "$NOTE" >"${TMP}/assume-touch.out" 2>&1; then
    fail 'note-touch accepted an assume-unchanged source'
fi
expect_contains "$(cat "${TMP}/assume-touch.out")" 'assume-unchanged or skip-worktree index flags'
[[ "$(sha256sum "$NOTE")" == "$BEFORE_ASSUME_TOUCH" ]] || fail 'note-touch modified note with assume-unchanged source'
git update-index --no-assume-unchanged -- 'src/path with spaces.txt'
git add 'src/path with spaces.txt'
git commit -qm 'commit assume-unchanged source edit'
write_directory_note "$(git rev-parse HEAD)"

# skip-worktree also hides edits and must receive the same treatment.
git update-index --skip-worktree -- 'src/path with spaces.txt'
printf 'skip-worktree edit\n' >>'src/path with spaces.txt'
if git diff --quiet -- 'src/path with spaces.txt'; then
    : # Ensure the fixture reproduces Git's index-flag behavior.
else
    fail 'skip-worktree fixture is visible to git diff'
fi
expect_status UNVERIFIED
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'assume-unchanged or skip-worktree index flags'
BEFORE_SKIP_TOUCH="$(sha256sum "$NOTE")"
if bash "$TOUCH_SCRIPT" "$NOTE" >"${TMP}/skip-touch.out" 2>&1; then
    fail 'note-touch accepted a skip-worktree source'
fi
expect_contains "$(cat "${TMP}/skip-touch.out")" 'assume-unchanged or skip-worktree index flags'
[[ "$(sha256sum "$NOTE")" == "$BEFORE_SKIP_TOUCH" ]] || fail 'note-touch modified note with skip-worktree source'
git update-index --no-skip-worktree -- 'src/path with spaces.txt'
git add 'src/path with spaces.txt'
git commit -qm 'commit skip-worktree source edit'
write_directory_note "$(git rev-parse HEAD)"

# Git failures do not collapse to a zero-change/fresh result.
REAL_GIT="$(command -v git)"
mkdir -p "${TMP}/fake-bin"
cat >"${TMP}/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' rev-parse --show-toplevel '*)
        if [[ "${AI_INDEX_FAIL_REPO_ROOT:-0}" == 1 ]]; then exit 78; fi
        ;;
    *' merge-base --is-ancestor '*) exit 77 ;;
esac
exec "$AI_INDEX_TEST_REAL_GIT" "$@"
EOF
chmod +x "${TMP}/fake-bin/git"
write_directory_note "$(git rev-parse HEAD)"
AI_INDEX_TEST_REAL_GIT="$REAL_GIT" PATH="${TMP}/fake-bin:$PATH" \
    bash "$STATUS_SCRIPT" "${TMP}/repos/demo" >"${TMP}/git-failure.out"
expect_contains "$(cat "${TMP}/git-failure.out")" 'UNVERIFIED'
AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_FAIL_REPO_ROOT=1 PATH="${TMP}/fake-bin:$PATH" \
    bash "$STATUS_SCRIPT" "${TMP}/repos/demo" >"${TMP}/git-root-failure.out"
expect_contains "$(cat "${TMP}/git-root-failure.out")" 'UNVERIFIED'
AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_FAIL_REPO_ROOT=1 PATH="${TMP}/fake-bin:$PATH" \
    bash "$STALE_SCRIPT" demo >"${TMP}/git-root-stale-failure.out"
expect_contains "$(cat "${TMP}/git-root-stale-failure.out")" 'UNVERIFIED'

# A normal .git-file worktree is accepted by both status entry points.
mkdir -p "${TMP}/worktree-roots"
git worktree add -q "${TMP}/worktree-roots/wt-demo" -b ai-index-test-worktree
cat >"${HOME}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT='${AI_INDEX_DOCS_ROOT}'
AI_INDEX_GIT_ROOT='${TMP}/worktree-roots'
EOF
mkdir -p "${TMP}/vault/repos/wt-demo"
cat >"${TMP}/vault/repos/wt-demo/overview.md" <<EOF
---
repo: wt-demo
sha: "$(git -C "${TMP}/worktree-roots/wt-demo" rev-parse HEAD)"
sources:
  - "src/path with spaces.txt"
---
EOF
git -C "${TMP}/worktree-roots/wt-demo" config user.name 'ai-index tests'
git -C "${TMP}/worktree-roots/wt-demo" config user.email 'ai-index-tests@example.invalid'
printf 'worktree change\n' >>"${TMP}/worktree-roots/wt-demo/src/path with spaces.txt"
git -C "${TMP}/worktree-roots/wt-demo" add 'src/path with spaces.txt'
git -C "${TMP}/worktree-roots/wt-demo" commit -qm 'worktree source change'
bash "$STALE_SCRIPT" wt-demo >"${TMP}/worktree-stale.out"
expect_contains "$(cat "${TMP}/worktree-stale.out")" 'STALE'
bash "$STATUS_SCRIPT" "${TMP}/worktree-roots/wt-demo" >"${TMP}/worktree-status.out"
expect_contains "$(cat "${TMP}/worktree-status.out")" 'STALE'

# note-touch prefers the active worktree when it shares the configured checkout's Git common dir.
git -C "${TMP}/worktree-roots/wt-demo" worktree add -q \
    "${TMP}/worktree-roots/wt-active" -b ai-index-test-active
git -C "${TMP}/worktree-roots/wt-active" config user.name 'ai-index tests'
git -C "${TMP}/worktree-roots/wt-active" config user.email 'ai-index-tests@example.invalid'
printf 'active worktree change\n' >>"${TMP}/worktree-roots/wt-active/src/path with spaces.txt"
git -C "${TMP}/worktree-roots/wt-active" add 'src/path with spaces.txt'
git -C "${TMP}/worktree-roots/wt-active" commit -qm 'active worktree change'
CONFIGURED_SHA="$(git -C "${TMP}/worktree-roots/wt-demo" rev-parse HEAD)"
ACTIVE_SHA="$(git -C "${TMP}/worktree-roots/wt-active" rev-parse HEAD)"
[[ "$CONFIGURED_SHA" != "$ACTIVE_SHA" ]] || fail 'worktree fixture did not create different HEADs'
(
    cd "${TMP}/worktree-roots/wt-active"
    bash "$TOUCH_SCRIPT" "${TMP}/vault/repos/wt-demo/overview.md" >/dev/null
)
TOUCHED_WORKTREE_SHA="$(yq --front-matter=extract '.sha' "${TMP}/vault/repos/wt-demo/overview.md")"
[[ "$TOUCHED_WORKTREE_SHA" == "$ACTIVE_SHA" ]] || fail 'note-touch stamped configured checkout instead of active worktree'
write_directory_note "$ACTIVE_SHA"
cat >"${HOME}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT='${AI_INDEX_DOCS_ROOT}'
AI_INDEX_GIT_ROOT='${TMP}/repos'
EOF
ACTIVE_STATUS="$(bash "$STATUS_SCRIPT" "${TMP}/worktree-roots/wt-active")"
expect_contains "$ACTIVE_STATUS" 'repo=demo'
expect_contains "$ACTIVE_STATUS" 'notes: overview'
expect_contains "$ACTIVE_STATUS" '1 fresh, 0 needing review'

# A sibling linked worktree under AI_INDEX_GIT_ROOT must use the original checkout's note key.
SIBLING_SHA="$(git -C "${TMP}/repos/demo" rev-parse HEAD)"
write_directory_note "$SIBLING_SHA"
git -C "${TMP}/repos/demo" worktree add -q \
    "${TMP}/repos/demo-feature" -b ai-index-sibling-worktree "$SIBLING_SHA"
[[ -f "${TMP}/repos/demo-feature/.git" ]] || fail 'sibling fixture is not a linked worktree'
SIBLING_STATUS="$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo-feature")"
expect_contains "$SIBLING_STATUS" 'repo=demo'
expect_contains "$SIBLING_STATUS" 'notes: overview'
expect_contains "$SIBLING_STATUS" '1 fresh, 0 needing review'

# Nested submodule ignore=all must not hide edits under a declared parent-submodule source.
mkdir -p "${TMP}/submodule-source"
git -C "${TMP}/submodule-source" init -q
git -C "${TMP}/submodule-source" config user.name 'ai-index tests'
git -C "${TMP}/submodule-source" config user.email 'ai-index-tests@example.invalid'
printf 'submodule source\n' >"${TMP}/submodule-source/source.txt"
git -C "${TMP}/submodule-source" add .
git -C "${TMP}/submodule-source" commit -qm 'initial submodule source'
mkdir -p "${TMP}/nested-submodule-source"
git -C "${TMP}/nested-submodule-source" init -q
git -C "${TMP}/nested-submodule-source" config user.name 'ai-index tests'
git -C "${TMP}/nested-submodule-source" config user.email 'ai-index-tests@example.invalid'
printf 'nested source\n' >"${TMP}/nested-submodule-source/source.txt"
git -C "${TMP}/nested-submodule-source" add .
git -C "${TMP}/nested-submodule-source" commit -qm 'initial nested source'
git -C "${TMP}/submodule-source" -c protocol.file.allow=always submodule add -q \
    "${TMP}/nested-submodule-source" nested
git -C "${TMP}/submodule-source" config -f .gitmodules submodule.nested.ignore all
git -C "${TMP}/submodule-source" add .gitmodules nested
git -C "${TMP}/submodule-source" commit -qm 'add ignored nested submodule'
git -C "${TMP}/repos/demo" -c protocol.file.allow=always submodule add -q \
    "${TMP}/submodule-source" src/ignored-submodule
git -C "${TMP}/repos/demo/src/ignored-submodule" -c protocol.file.allow=always \
    submodule update --init --recursive -q
git -C "${TMP}/repos/demo" config -f .gitmodules submodule.src/ignored-submodule.ignore all
git -C "${TMP}/repos/demo" add .gitmodules src/ignored-submodule
git -C "${TMP}/repos/demo" commit -qm 'add ignored submodule source'
write_submodule_note "$(git -C "${TMP}/repos/demo" rev-parse HEAD)"
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo")" '1 fresh, 0 needing review'
NESTED_ROOT="${TMP}/repos/demo/src/ignored-submodule/nested"
NESTED_SOURCE="${TMP}/repos/demo/src/ignored-submodule/nested/source.txt"
printf 'modified tracked nested source\n' >>"$NESTED_SOURCE"
if git -C "${TMP}/repos/demo" diff --ignore-submodules=none --quiet -- src/ignored-submodule; then
    : # Ensure the fixture reproduces Git's ignore=all behavior.
else
    fail 'top-level diff unexpectedly detected the nested ignored edit'
fi
expect_status DIRTY
expect_contains "$(bash "$STALE_SCRIPT" demo)" 'nested submodule changes detected'
BEFORE_NESTED_TRACKED_TOUCH="$(sha256sum "$NOTE")"
if bash "$TOUCH_SCRIPT" "$NOTE" >"${TMP}/nested-tracked-touch.out" 2>&1; then
    fail 'note-touch accepted a modified nested submodule source'
fi
expect_contains "$(cat "${TMP}/nested-tracked-touch.out")" 'nested declared submodule sources have uncommitted changes'
[[ "$(sha256sum "$NOTE")" == "$BEFORE_NESTED_TRACKED_TOUCH" ]] || \
    fail 'note-touch modified metadata for a dirty nested submodule'

git -C "$NESTED_ROOT" add source.txt
expect_status DIRTY
BEFORE_NESTED_STAGED_TOUCH="$(sha256sum "$NOTE")"
if bash "$TOUCH_SCRIPT" "$NOTE" >"${TMP}/nested-staged-touch.out" 2>&1; then
    fail 'note-touch accepted a staged nested submodule edit'
fi
expect_contains "$(cat "${TMP}/nested-staged-touch.out")" 'nested declared submodule sources have uncommitted changes'
[[ "$(sha256sum "$NOTE")" == "$BEFORE_NESTED_STAGED_TOUCH" ]] || \
    fail 'note-touch modified metadata for a staged nested submodule edit'

git -C "$NESTED_ROOT" restore --staged source.txt
git -C "$NESTED_ROOT" restore source.txt
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/demo")" '1 fresh, 0 needing review'
printf 'untracked nested source\n' >"$NESTED_ROOT/untracked.txt"
if git -C "${TMP}/repos/demo" diff --ignore-submodules=none --quiet -- src/ignored-submodule; then
    : # Ensure nested untracked content is hidden by the intermediate ignore=all.
else
    fail 'top-level diff unexpectedly detected nested untracked content'
fi
expect_status DIRTY
BEFORE_NESTED_UNTRACKED_TOUCH="$(sha256sum "$NOTE")"
if bash "$TOUCH_SCRIPT" "$NOTE" >"${TMP}/nested-untracked-touch.out" 2>&1; then
    fail 'note-touch accepted untracked nested submodule content'
fi
expect_contains "$(cat "${TMP}/nested-untracked-touch.out")" 'nested declared submodule sources have uncommitted changes'
[[ "$(sha256sum "$NOTE")" == "$BEFORE_NESTED_UNTRACKED_TOUCH" ]] || \
    fail 'note-touch modified metadata for untracked nested submodule content'

# Full history must retain a source-changing merge omitted by default path simplification.
mkdir -p "${TMP}/repos/merge-demo/src" "${TMP}/vault/repos/merge-demo"
git -C "${TMP}/repos/merge-demo" init -q
git -C "${TMP}/repos/merge-demo" config user.name 'ai-index tests'
git -C "${TMP}/repos/merge-demo" config user.email 'ai-index-tests@example.invalid'
printf 'base source\n' >"${TMP}/repos/merge-demo/src/contract.txt"
git -C "${TMP}/repos/merge-demo" add .
git -C "${TMP}/repos/merge-demo" commit -qm 'merge test base'
MERGE_BASE="$(git -C "${TMP}/repos/merge-demo" rev-parse HEAD)"
git -C "${TMP}/repos/merge-demo" checkout -qb recorded-source
printf 'recorded source\n' >"${TMP}/repos/merge-demo/src/contract.txt"
git -C "${TMP}/repos/merge-demo" commit -qam 'recorded source state'
RECORDED_SHA="$(git -C "${TMP}/repos/merge-demo" rev-parse HEAD)"
git -C "${TMP}/repos/merge-demo" checkout -q --detach "$MERGE_BASE"
printf 'side branch\n' >"${TMP}/repos/merge-demo/README.md"
git -C "${TMP}/repos/merge-demo" add README.md
git -C "${TMP}/repos/merge-demo" commit -qm 'side branch without source change'
SIDE_SHA="$(git -C "${TMP}/repos/merge-demo" rev-parse HEAD)"
MERGE_TREE="$(git -C "${TMP}/repos/merge-demo" rev-parse "${SIDE_SHA}^{tree}")"
MERGE_SHA="$(printf 'merge tree selects side source\n' | git -C "${TMP}/repos/merge-demo" commit-tree "$MERGE_TREE" -p "$RECORDED_SHA" -p "$SIDE_SHA")"
git -C "${TMP}/repos/merge-demo" update-ref refs/heads/main "$MERGE_SHA"
git -C "${TMP}/repos/merge-demo" symbolic-ref HEAD refs/heads/main
DEFAULT_MERGE_COUNT="$(git -C "${TMP}/repos/merge-demo" rev-list --count \
    "${RECORDED_SHA}..${MERGE_SHA}" -- ':(literal)src/contract.txt')"
FULL_MERGE_COUNT="$(git -C "${TMP}/repos/merge-demo" rev-list --full-history --count \
    "${RECORDED_SHA}..${MERGE_SHA}" -- ':(literal)src/contract.txt')"
[[ "$DEFAULT_MERGE_COUNT" == 0 && "$FULL_MERGE_COUNT" -gt 0 ]] || \
    fail 'merge fixture does not reproduce path-limited history simplification'
cat >"${TMP}/vault/repos/merge-demo/overview.md" <<EOF
---
repo: merge-demo
sha: "${RECORDED_SHA}"
sources:
  - "src/contract.txt"
---
EOF
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/merge-demo")" 'STALE'
expect_contains "$(bash "$STALE_SCRIPT" merge-demo)" 'STALE'

# Conservative full history can also mark a source stale when the merge kept its recorded state.
mkdir -p "${TMP}/repos/conservative-merge" "${TMP}/vault/repos/conservative-merge"
git -C "${TMP}/repos/conservative-merge" init -q
git -C "${TMP}/repos/conservative-merge" config user.name 'ai-index tests'
git -C "${TMP}/repos/conservative-merge" config user.email 'ai-index-tests@example.invalid'
printf 'base\n' >"${TMP}/repos/conservative-merge/source.txt"
git -C "${TMP}/repos/conservative-merge" add .
git -C "${TMP}/repos/conservative-merge" commit -qm base
git -C "${TMP}/repos/conservative-merge" branch side
git -C "${TMP}/repos/conservative-merge" checkout -qb recorded
printf 'recorded\n' >"${TMP}/repos/conservative-merge/source.txt"
git -C "${TMP}/repos/conservative-merge" commit -qam 'recorded source'
CONSERVATIVE_SHA="$(git -C "${TMP}/repos/conservative-merge" rev-parse HEAD)"
git -C "${TMP}/repos/conservative-merge" checkout -q side
printf 'unrelated\n' >"${TMP}/repos/conservative-merge/README.md"
git -C "${TMP}/repos/conservative-merge" add README.md
git -C "${TMP}/repos/conservative-merge" commit -qm 'unrelated side change'
git -C "${TMP}/repos/conservative-merge" checkout -q recorded
git -C "${TMP}/repos/conservative-merge" merge --no-ff -qm 'merge unchanged source' side
git -C "${TMP}/repos/conservative-merge" diff --quiet "$CONSERVATIVE_SHA" HEAD -- source.txt || \
    fail 'conservative merge changed the recorded source'
cat >"${TMP}/vault/repos/conservative-merge/overview.md" <<EOF
---
repo: conservative-merge
sha: "${CONSERVATIVE_SHA}"
sources:
  - source.txt
---
EOF
expect_contains "$(bash "$STATUS_SCRIPT" "${TMP}/repos/conservative-merge")" 'STALE'
expect_contains "$(bash "$STALE_SCRIPT" conservative-merge)" 'STALE'

# A commit during stale-check must invalidate results computed against the earlier HEAD.
mkdir -p "${TMP}/repos/race-stale/src" "${TMP}/vault/repos/race-stale"
git -C "${TMP}/repos/race-stale" init -q
git -C "${TMP}/repos/race-stale" config user.name 'ai-index tests'
git -C "${TMP}/repos/race-stale" config user.email 'ai-index-tests@example.invalid'
printf 'initial\n' >"${TMP}/repos/race-stale/src/source.txt"
git -C "${TMP}/repos/race-stale" add .
git -C "${TMP}/repos/race-stale" commit -qm 'race stale initial'
RACE_STALE_SHA="$(git -C "${TMP}/repos/race-stale" rev-parse HEAD)"
cat >"${TMP}/vault/repos/race-stale/overview.md" <<EOF
---
repo: race-stale
sha: "${RACE_STALE_SHA}"
sources:
  - src/source.txt
---
EOF

# A commit after note-touch captures HEAD must prevent it from stamping that old SHA.
mkdir -p "${TMP}/repos/race-touch/src" "${TMP}/vault/repos/race-touch" "${TMP}/race-bin"
git -C "${TMP}/repos/race-touch" init -q
git -C "${TMP}/repos/race-touch" config user.name 'ai-index tests'
git -C "${TMP}/repos/race-touch" config user.email 'ai-index-tests@example.invalid'
printf 'initial\n' >"${TMP}/repos/race-touch/src/source.txt"
git -C "${TMP}/repos/race-touch" add .
git -C "${TMP}/repos/race-touch" commit -qm 'race touch initial'
RACE_TOUCH_SHA="$(git -C "${TMP}/repos/race-touch" rev-parse HEAD)"
cat >"${TMP}/vault/repos/race-touch/overview.md" <<EOF
---
repo: race-touch
sha: "${RACE_TOUCH_SHA}"
sources:
  - src/source.txt
---
EOF

RACE_REAL_GIT="$(command -v git)"
cat >"${TMP}/race-bin/git" <<'EOF'
#!/usr/bin/env bash
case "${AI_INDEX_RACE_KIND:-}" in
    stale)
        case " $* " in
            *' rev-list --full-history --count '*)
                if [ ! -e "$AI_INDEX_RACE_MARKER" ]; then
                    : >"$AI_INDEX_RACE_MARKER"
                    printf 'concurrent source change\n' >>"${AI_INDEX_RACE_REPO}/${AI_INDEX_RACE_SOURCE}"
                    "$AI_INDEX_TEST_REAL_GIT" -C "$AI_INDEX_RACE_REPO" add "$AI_INDEX_RACE_SOURCE"
                    "$AI_INDEX_TEST_REAL_GIT" -C "$AI_INDEX_RACE_REPO" commit -qm 'concurrent stale-check source change'
                fi
                ;;
        esac
        ;;
    touch)
        case " $* " in
            *' ls-files -v --stage -z '*)
                if [ ! -e "$AI_INDEX_RACE_MARKER" ]; then
                    : >"$AI_INDEX_RACE_MARKER"
                    printf 'concurrent source change\n' >>"${AI_INDEX_RACE_REPO}/${AI_INDEX_RACE_SOURCE}"
                    "$AI_INDEX_TEST_REAL_GIT" -C "$AI_INDEX_RACE_REPO" add "$AI_INDEX_RACE_SOURCE"
                    "$AI_INDEX_TEST_REAL_GIT" -C "$AI_INDEX_RACE_REPO" commit -qm 'concurrent note-touch source change'
                fi
                ;;
        esac
        ;;
esac
exec "$AI_INDEX_TEST_REAL_GIT" "$@"
EOF
chmod +x "${TMP}/race-bin/git"
AI_INDEX_TEST_REAL_GIT="$RACE_REAL_GIT" AI_INDEX_RACE_KIND=stale \
    AI_INDEX_RACE_REPO="${TMP}/repos/race-stale" AI_INDEX_RACE_SOURCE=src/source.txt \
    AI_INDEX_RACE_MARKER="${TMP}/race-stale-fired" PATH="${TMP}/race-bin:$PATH" \
    bash "$STALE_SCRIPT" race-stale >"${TMP}/race-stale.out"
expect_contains "$(cat "${TMP}/race-stale.out")" 'UNVERIFIED'
expect_contains "$(cat "${TMP}/race-stale.out")" 'HEAD changed or could not be verified during status scan'
[[ "$(git -C "${TMP}/repos/race-stale" rev-parse HEAD)" != "$RACE_STALE_SHA" ]] || \
    fail 'stale-check race fixture did not commit during the scan'

BEFORE_RACE_TOUCH="$(sha256sum "${TMP}/vault/repos/race-touch/overview.md")"
if AI_INDEX_TEST_REAL_GIT="$RACE_REAL_GIT" AI_INDEX_RACE_KIND=touch \
    AI_INDEX_RACE_REPO="${TMP}/repos/race-touch" AI_INDEX_RACE_SOURCE=src/source.txt \
    AI_INDEX_RACE_MARKER="${TMP}/race-touch-fired" PATH="${TMP}/race-bin:$PATH" \
    bash "$TOUCH_SCRIPT" "${TMP}/vault/repos/race-touch/overview.md" >"${TMP}/race-touch.out" 2>&1; then
    fail 'note-touch accepted a concurrent source commit'
fi
expect_contains "$(cat "${TMP}/race-touch.out")" 'HEAD changed during source verification'
[[ "$(sha256sum "${TMP}/vault/repos/race-touch/overview.md")" == "$BEFORE_RACE_TOUCH" ]] || \
    fail 'note-touch stamped a SHA after HEAD moved'
[[ "$(git -C "${TMP}/repos/race-touch" rev-parse HEAD)" != "$RACE_TOUCH_SHA" ]] || \
    fail 'note-touch race fixture did not commit during verification'

# Plugin reminder stays short and preserves the key workflow guardrails.
GUIDANCE="$(sed -n '/const AI_INDEX_GUIDANCE = \[/,/\].join/p' "$PLUGIN" | tr -d '\n')"
[[ ${#GUIDANCE} -lt 700 ]] || fail "plugin guidance is not concise (${#GUIDANCE} chars)"
grep -q 'fresh means no detected source changes' "$PLUGIN" || fail 'plugin omits freshness limitation'
grep -q 'note-touch.sh refuses dirty sources' "$PLUGIN" || fail 'plugin omits dirty-source guard'

echo 'PASS: freshness scripts, note-touch, worktrees, and plugin guidance'
