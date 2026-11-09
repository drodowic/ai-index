#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATUS="${ROOT}/skills/ai-index/scripts/repo-status.sh"
STALE="${ROOT}/skills/ai-index/scripts/stale-check.sh"
TOUCH="${ROOT}/skills/ai-index/scripts/note-touch.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-index-parallel-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="${TMP}/home"
export TMPDIR="${TMP}/scratch"
mkdir -p "${HOME}/.config/opencode" "$TMPDIR" "${TMP}/repos/demo/src" "${TMP}/vault/repos/demo"
cat >"${HOME}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT='${TMP}/vault'
AI_INDEX_GIT_ROOT='${TMP}/repos'
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }
check_scratch_empty() {
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] || fail 'temporary status files were not cleaned up'
}

cd "${TMP}/repos/demo"
git init -q
git config user.name 'ai-index tests'
git config user.email 'ai-index-tests@example.invalid'
for i in $(seq -w 1 12); do printf 'source\n' >"src/source-${i}.txt"; done
printf 'unusual\n' >$'src/newline\nsource.txt'
git add .
git commit -qm initial
BASE_SHA="$(git rev-parse HEAD)"

for i in $(seq -w 1 12); do
    cat >"${TMP}/vault/repos/demo/note-${i}.md" <<EOF
---
repo: demo
sha: "$BASE_SHA"
sources:
  - "src/source-${i}.txt"
related:
  - related-repo
---
EOF
done
printf 'changed\n' >>src/source-01.txt
git add src/source-01.txt
git commit -qm 'change source'
printf 'staged\n' >>src/source-02.txt
git add src/source-02.txt
printf 'unstaged\n' >>src/source-03.txt

# The related repo remains discoverable even when its note metadata is invalid.
cat >"${TMP}/vault/repos/demo/note-12.md" <<'EOF'
---
repo: demo
sources: []
related:
  - invalid-note-related
---
EOF
cat >"${TMP}/vault/repos/demo/unusual.md" <<EOF
---
repo: demo
sha: "$BASE_SHA"
sources:
  - "src/newline\\nsource.txt"
---
EOF
printf 'changed\n' >>$'src/newline\nsource.txt'

output="$(bash "$STATUS" "${TMP}/repos/demo")"
expect_contains "$output" 'STALE: note-01'
expect_contains "$output" 'DIRTY: note-02'
expect_contains "$output" 'staged=1'
expect_contains "$output" 'DIRTY: note-03'
expect_contains "$output" 'unstaged=1'
expect_contains "$output" 'UNVERIFIED: note-12'
expect_contains "$output" 'DIRTY: unusual'
expect_contains "$output" 'invalid-note-related (0 notes)'
expect_contains "$output" 'related-repo (0 notes)'
[[ "$output" == "$(bash "$STATUS" "${TMP}/repos/demo")" ]] || fail 'parallel output was not deterministic'
expect_contains "$(bash "$STALE" demo)" 'DIRTY'
if bash "$TOUCH" "${TMP}/vault/repos/demo/unusual.md" >"${TMP}/touch.out" 2>&1; then
    fail 'note-touch accepted a dirty newline-containing source path'
fi
check_scratch_empty

REAL_GIT="$(command -v git)"
REAL_JQ="$(command -v jq)"
REAL_MKTEMP="$(command -v mktemp)"
mkdir -p "${TMP}/fake-bin"
cat >"${TMP}/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' rev-parse --verify HEAD^{commit} '*)
        if [[ "${AI_INDEX_TEST_HEAD_CHANGE:-0}" == 1 ]]; then
            if mkdir "$AI_INDEX_TEST_HEAD_MARKER" 2>/dev/null; then
                exec "$AI_INDEX_TEST_REAL_GIT" "$@"
            fi
            printf '%040d\n' 0
            exit 0
        fi
        ;;
    *' ls-tree '*)
        if [[ "${AI_INDEX_TEST_LS_TREE_FAIL:-0}" == 1 ]]; then exit 77; fi
        if [[ "${AI_INDEX_TEST_DELAY:-0}" == 1 ]]; then
            printf '%s\n' "$$" >>"$AI_INDEX_TEST_DELAY_PIDS"
            exec sleep 30
        fi
        ;;
    *' merge-base --is-ancestor '*)
        if [[ -n "${AI_INDEX_TEST_MERGE_LOG:-}" ]]; then printf '.' >>"$AI_INDEX_TEST_MERGE_LOG"; fi
        ;;
esac
exec "$AI_INDEX_TEST_REAL_GIT" "$@"
EOF
cat >"${TMP}/fake-bin/jq" <<'EOF'
#!/usr/bin/env bash
if [[ "${AI_INDEX_TEST_KILL_WORKER:-0}" == 1 ]] && mkdir "$AI_INDEX_TEST_KILL_MARKER" 2>/dev/null; then
    kill -TERM "$PPID"
    exit 1
fi
if [[ "${AI_INDEX_TEST_JQ_FAIL:-0}" == 1 ]]; then exit 77; fi
exec "$AI_INDEX_TEST_REAL_JQ" "$@"
EOF
cat >"${TMP}/fake-bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ "${AI_INDEX_TEST_TMP_FAIL:-0}" == 1 ]]; then exit 1; fi
exec "$AI_INDEX_TEST_REAL_MKTEMP" "$@"
EOF
chmod +x "${TMP}/fake-bin/git" "${TMP}/fake-bin/jq" "${TMP}/fake-bin/mktemp"

# Successful ancestry checks are reused within each worker, not across runs.
AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_REAL_JQ="$REAL_JQ" \
    AI_INDEX_TEST_REAL_MKTEMP="$REAL_MKTEMP" AI_INDEX_TEST_MERGE_LOG="${TMP}/merge-log" \
    PATH="${TMP}/fake-bin:$PATH" bash "$STATUS" "${TMP}/repos/demo" >"${TMP}/cached.out"
[[ "$(wc -c <"${TMP}/merge-log")" -eq 4 ]] || fail 'ancestry checks were not reused per worker'
check_scratch_empty

# Changed HEAD invalidates even results already produced by workers.
output="$(AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_REAL_JQ="$REAL_JQ" AI_INDEX_TEST_REAL_MKTEMP="$REAL_MKTEMP" \
    AI_INDEX_TEST_HEAD_CHANGE=1 AI_INDEX_TEST_HEAD_MARKER="${TMP}/head-marker" \
    PATH="${TMP}/fake-bin:$PATH" bash "$STATUS" "${TMP}/repos/demo")"
expect_contains "$output" '0 fresh, 13 needing review'
expect_contains "$output" 'HEAD changed or could not be verified'
check_scratch_empty

# Failed Git and jq commands cannot turn source checks into fresh results.
output="$(AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_REAL_JQ="$REAL_JQ" AI_INDEX_TEST_REAL_MKTEMP="$REAL_MKTEMP" \
    AI_INDEX_TEST_LS_TREE_FAIL=1 PATH="${TMP}/fake-bin:$PATH" bash "$STATUS" "${TMP}/repos/demo")"
expect_contains "$output" '0 fresh, 13 needing review'
expect_contains "$output" 'Git could not inspect declared sources'
if AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_REAL_JQ="$REAL_JQ" AI_INDEX_TEST_REAL_MKTEMP="$REAL_MKTEMP" \
    AI_INDEX_TEST_LS_TREE_FAIL=1 PATH="${TMP}/fake-bin:$PATH" bash "$TOUCH" "${TMP}/vault/repos/demo/unusual.md" >"${TMP}/touch-git-failure.out" 2>&1; then
    fail 'note-touch accepted a failed source check'
fi
expect_contains "$(cat "${TMP}/touch-git-failure.out")" 'Git could not inspect declared sources'
output="$(AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_REAL_JQ="$REAL_JQ" AI_INDEX_TEST_REAL_MKTEMP="$REAL_MKTEMP" \
    AI_INDEX_TEST_JQ_FAIL=1 PATH="${TMP}/fake-bin:$PATH" bash "$STATUS" "${TMP}/repos/demo")"
expect_contains "$output" '0 fresh, 13 needing review'
expect_contains "$output" 'UNVERIFIED'
check_scratch_empty

# A temporary workspace failure cannot suppress the digest or mark notes fresh.
output="$(AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_REAL_JQ="$REAL_JQ" AI_INDEX_TEST_REAL_MKTEMP="$REAL_MKTEMP" \
    AI_INDEX_TEST_TMP_FAIL=1 PATH="${TMP}/fake-bin:$PATH" bash "$STATUS" "${TMP}/repos/demo")"
expect_contains "$output" '0 fresh, 13 needing review'
expect_contains "$output" 'UNVERIFIED'
check_scratch_empty

# A killed worker marks its entire batch unverified rather than omitting notes.
output="$(AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_REAL_JQ="$REAL_JQ" AI_INDEX_TEST_REAL_MKTEMP="$REAL_MKTEMP" \
    AI_INDEX_TEST_KILL_WORKER=1 AI_INDEX_TEST_KILL_MARKER="${TMP}/kill-marker" \
    PATH="${TMP}/fake-bin:$PATH" bash "$STATUS" "${TMP}/repos/demo")"
expect_contains "$output" 'status worker failed or returned incomplete output'
expect_contains "$output" 'note-01'
expect_contains "$output" 'note-12'
check_scratch_empty

# Cancelling the digest stops its workers and their in-flight Git commands.
AI_INDEX_TEST_REAL_GIT="$REAL_GIT" AI_INDEX_TEST_REAL_JQ="$REAL_JQ" AI_INDEX_TEST_REAL_MKTEMP="$REAL_MKTEMP" \
    AI_INDEX_TEST_DELAY=1 AI_INDEX_TEST_DELAY_PIDS="${TMP}/delay-pids" \
    PATH="${TMP}/fake-bin:$PATH" bash "$STATUS" "${TMP}/repos/demo" >"${TMP}/cancel.out" 2>&1 &
status_pid=$!
for _ in $(seq 1 200); do
    [ -s "${TMP}/delay-pids" ] && break
    sleep 0.02
done
[ -s "${TMP}/delay-pids" ] || fail 'worker did not reach the delayed Git command'
kill -TERM "$status_pid"
if wait "$status_pid"; then fail 'cancelled status command exited successfully'; fi
while IFS= read -r pid; do
    state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [[ -z "$state" || "$state" == Z* ]] || fail "Git child ${pid} survived cancellation"
done <"${TMP}/delay-pids"
check_scratch_empty

echo 'PASS: parallel status, conservative failures, unusual paths, and cleanup'
