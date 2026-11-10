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
mkdir -p "${REPO}/src"
printf 'base\n' > "${REPO}/src/tracked.txt"
printf 'bracket name\n' > "${REPO}/src/[literal].txt"
printf 'single character\n' > "${REPO}/src/l.txt"
printf 'will be deleted\n' > "${REPO}/src/deleted.txt"
printf 'numeric filename\n' > "${REPO}/3"
git -C "$REPO" add src
git -C "$REPO" commit -qm base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

write_note() {
    local sha_line="$1" sources_block="$2"
    cat > "$NOTE" <<EOF
---
repo: sample
${sha_line}
${sources_block}
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

# Missing SHA is never silently omitted, even when the checkout is clean.
write_note '' 'sources:
  - src/tracked.txt'
table="$(run_stale_check)"
grep -Eq 'area +- +UNVERIFIABLE +no sha recorded' <<< "$table"
status="$(run_repo_status)"
grep -Fq 'UNVERIFIABLE: area (no sha recorded' <<< "$status"

# Empty sources and paths absent at the recorded commit are invalid metadata.
write_note "sha: ${BASE_SHA}" ''
table="$(run_stale_check)"
grep -Eq 'area +[[:xdigit:]]+ +UNVERIFIABLE +missing sources' <<< "$table"
status="$(run_repo_status)"
grep -Fq 'UNVERIFIABLE: area (missing sources)' <<< "$status"

write_note "sha: ${BASE_SHA}" 'sources:
  - src/missing.txt'
table="$(run_stale_check)"
grep -Eq 'UNVERIFIABLE +source not found at recorded SHA: src/missing.txt' <<< "$table"
status="$(run_repo_status)"
grep -Fq 'UNVERIFIABLE: area (source not found at recorded SHA: src/missing.txt)' <<< "$status"

# Non-string YAML values are not source paths, even if a matching filename exists.
write_note "sha: ${BASE_SHA}" 'sources:
  - 3'
table="$(run_stale_check)"
grep -Eq 'UNVERIFIABLE +invalid sources metadata' <<< "$table"

# Literal Git pathspec characters name literal files, not wildcard patterns.
write_note "sha: ${BASE_SHA}" "sources:
  - 'src/[literal].txt'"
printf 'changed unrelated match\n' > "${REPO}/src/l.txt"
git -C "$REPO" add src/l.txt
git -C "$REPO" commit -qm 'change literal wildcard match'
table="$(run_stale_check)"
grep -Eq 'area +[[:xdigit:]]+ +fresh +no commits to sources' <<< "$table"

# A declared source that existed at the baseline but was subsequently deleted is stale.
write_note "sha: ${BASE_SHA}" 'sources:
  - src/deleted.txt'
git -C "$REPO" rm -q src/deleted.txt
git -C "$REPO" commit -qm 'delete declared source'
table="$(run_stale_check)"
grep -Eq 'area +[[:xdigit:]]+ +STALE +[0-9]+ commits since recorded sha' <<< "$table"

# Git failures must not be interpreted as zero changed commits.
write_note "sha: ${BASE_SHA}" 'sources:
  - src/tracked.txt'
BIN_DIR="${TMP_DIR}/bin"
mkdir -p "$BIN_DIR"
REAL_GIT="$(command -v git)"
cat > "${BIN_DIR}/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    [ "$arg" = rev-list ] && exit 42
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "${BIN_DIR}/git"
table="$(PATH="${BIN_DIR}:$PATH" REAL_GIT="$REAL_GIT" run_stale_check)"
grep -Eq 'UNVERIFIABLE +Git check failed' <<< "$table"
status="$(PATH="${BIN_DIR}:$PATH" REAL_GIT="$REAL_GIT" run_repo_status)"
grep -Fq 'UNVERIFIABLE: area (Git check failed)' <<< "$status"

# note-touch rejects empty or nonexistent source declarations.
write_note "sha: ${BASE_SHA}" ''
if HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh" "$NOTE" >"${TMP_DIR}/touch.out" 2>"${TMP_DIR}/touch.err"; then
    echo 'note-touch unexpectedly stamped a note with no sources' >&2
    exit 1
fi
grep -Fq 'missing sources' "${TMP_DIR}/touch.err"
write_note "sha: ${BASE_SHA}" 'sources:
  - src/not-found.txt'
if HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/note-touch.sh" "$NOTE" >"${TMP_DIR}/touch.out" 2>"${TMP_DIR}/touch.err"; then
    echo 'note-touch unexpectedly stamped a note with a nonexistent source' >&2
    exit 1
fi
grep -Fq 'source not found at recorded SHA: src/not-found.txt' "${TMP_DIR}/touch.err"

echo 'metadata validation checks passed'
