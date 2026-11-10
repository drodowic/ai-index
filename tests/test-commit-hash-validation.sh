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

assert_missing_sha() {
    local sha="$1" table status
    write_note "$sha"
    table="$(run_stale_check)"
    grep -Eq 'UNVERIFIABLE +commit hash not found in repo' <<< "$table"
    status="$(run_repo_status)"
    grep -Fq 'UNVERIFIABLE: area (commit hash not found in repo)' <<< "$status"
}

assert_invalid_sha HEAD
assert_invalid_sha main
assert_invalid_sha before-change
assert_missing_sha deadbeef
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
status="$(run_repo_status)"
grep -Fq 'notes: area' <<< "$status"
if grep -Eq '(STALE|UNVERIFIABLE): area' <<< "$status"; then
    echo 'valid full commit hash was not reported fresh by repo-status' >&2
    exit 1
fi

# Numeric-only hashes must remain strings in YAML, not be coerced to numbers.
source "${REPO_ROOT}/skills/ai-index/scripts/fm.sh"
NUMERIC_SHA='1234567890123456789012345678901234567890'
fm_set "$NOTE" sha "$NUMERIC_SHA"
grep -Fq "sha: \"${NUMERIC_SHA}\"" "$NOTE"
[[ "$(yq --front-matter=extract '.sha | type' "$NOTE")" == '!!str' ]]
[[ "$(yq --front-matter=extract '.sha' "$NOTE")" == "$NUMERIC_SHA" ]]

# A unique object ID is still invalid when it names a blob rather than a commit.
BLOB_SHA="$(printf 'not a commit\n' | git -C "$REPO" hash-object -w --stdin)"
write_note "$BLOB_SHA"
table="$(run_stale_check)"
grep -Eq 'area +[[:xdigit:]]+ +UNVERIFIABLE +object identified by sha is not a commit' <<< "$table"
status="$(run_repo_status)"
grep -Fq 'UNVERIFIABLE: area (object identified by sha is not a commit)' <<< "$status"

# Make two commits with the same four-character prefix. A branch named for the
# prefix initially points at the first commit, then moves to the second. Git's
# revision parser follows that branch, so prefix lookup must instead reject the
# ambiguous object IDs in both status scripts.
printf 'collision state A\n' > "${REPO}/tracked.txt"
git -C "$REPO" add tracked.txt
TREE_A="$(git -C "$REPO" write-tree)"
printf 'collision state B\n' > "${REPO}/tracked.txt"
git -C "$REPO" add tracked.txt
TREE_B="$(git -C "$REPO" write-tree)"

declare -A seen_prefixes=() seen_indices=()
PARENT="$(git -C "$REPO" rev-parse HEAD)"
COLLISION_PREFIX=""
COLLISION_FIRST=""
COLLISION_SECOND=""
for i in $(seq 1 5000); do
    if (( i % 2 )); then
        tree="$TREE_A"
    else
        tree="$TREE_B"
    fi
    commit="$(GIT_AUTHOR_DATE="@$((1700000000 + i))" \
        GIT_COMMITTER_DATE="@$((1700000000 + i))" \
        git -C "$REPO" commit-tree "$tree" -p "$PARENT" -m "collision fixture $i")"
    prefix="${commit:0:4}"
    if [ -n "${seen_prefixes[$prefix]:-}" ]; then
        if (( (i - seen_indices[$prefix]) % 2 )); then
            COLLISION_PREFIX="$prefix"
            COLLISION_FIRST="${seen_prefixes[$prefix]}"
            COLLISION_SECOND="$commit"
            break
        fi
    else
        seen_prefixes["$prefix"]="$commit"
        seen_indices["$prefix"]="$i"
    fi
    PARENT="$commit"
done

if [ -z "$COLLISION_PREFIX" ]; then
    echo 'could not generate commits with an ambiguous four-character prefix' >&2
    exit 1
fi

git -C "$REPO" reset --hard -q "$COLLISION_SECOND"
if git -C "$REPO" diff --quiet "$COLLISION_FIRST" "$COLLISION_SECOND" -- tracked.txt; then
    echo 'collision fixture commits must change the tracked source' >&2
    exit 1
fi
git -C "$REPO" branch "$COLLISION_PREFIX" "$COLLISION_FIRST"
git -C "$REPO" branch -f "$COLLISION_PREFIX" "$COLLISION_SECOND"
[[ "$(git -C "$REPO" rev-parse --verify "${COLLISION_PREFIX}^{commit}")" == "$COLLISION_SECOND" ]]
write_note "$COLLISION_PREFIX"

table="$(run_stale_check)"
grep -Eq 'area +[[:xdigit:]]+ +UNVERIFIABLE +commit hash is ambiguous in repo' <<< "$table"
status="$(run_repo_status)"
grep -Fq 'UNVERIFIABLE: area (commit hash is ambiguous in repo)' <<< "$status"

# Without the branch, the same ambiguous object prefix must still be rejected.
git -C "$REPO" branch -D "$COLLISION_PREFIX" >/dev/null
table="$(run_stale_check)"
grep -Eq 'area +[[:xdigit:]]+ +UNVERIFIABLE +commit hash is ambiguous in repo' <<< "$table"
status="$(run_repo_status)"
grep -Fq 'UNVERIFIABLE: area (commit hash is ambiguous in repo)' <<< "$status"

echo 'commit hash validation checks passed'
