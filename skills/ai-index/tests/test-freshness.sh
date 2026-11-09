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
  - "new area"
  - "deleted source.txt"
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

mkdir -p 'new area'
printf 'untracked\n' >'new area/untracked file.txt'
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
git add 'new area/untracked file.txt'
git commit -qm 'add source-area file'
write_note "$(git rev-parse HEAD)"
printf 'deletable\n' >'deleted source.txt'
git add 'deleted source.txt'
git commit -qm 'add source file'
write_note "$(git rev-parse HEAD)"
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

# Plugin reminder stays short and preserves the key workflow guardrails.
GUIDANCE="$(sed -n '/const AI_INDEX_GUIDANCE = \[/,/\].join/p' "$PLUGIN" | tr -d '\n')"
[[ ${#GUIDANCE} -lt 700 ]] || fail "plugin guidance is not concise (${#GUIDANCE} chars)"
grep -q 'fresh means no detected source changes' "$PLUGIN" || fail 'plugin omits freshness limitation'
grep -q 'note-touch.sh refuses dirty sources' "$PLUGIN" || fail 'plugin omits dirty-source guard'

echo 'PASS: freshness scripts, note-touch, worktrees, and plugin guidance'
