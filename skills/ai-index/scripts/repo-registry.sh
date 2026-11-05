#!/usr/bin/env bash
# repo-registry.sh - regenerate the repo table in ai-index/index.md.
#
# Walks $AI_INDEX_GIT_ROOT for git repos and rewrites only the
# region between the BEGIN/END registry markers in index.md, so hand-written prose in that
# file survives repeated runs. Cheap: no code analysis, just `git remote`/`git branch`.
#
# Usage: repo-registry.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fm.sh
source "${SCRIPT_DIR}/fm.sh"
ai_index_load_config
fm_require_tools

INDEX_ROOT="${AI_INDEX_DOCS_ROOT}"
GIT_ROOT="${AI_INDEX_GIT_ROOT}"
INDEX_FILE="${INDEX_ROOT}/index.md"
BEGIN_MARKER="<!-- BEGIN registry -->"
END_MARKER="<!-- END registry -->"

shorten_remote() {
    local url="$1"
    [ -z "$url" ] && { echo "-"; return; }
    url="${url%.git}"
    url="${url/git@github.com:/gh:}"
    url="${url/git@gitlab.com:/gl:}"
    url="${url/https:\/\/github.com\//gh:}"
    url="${url/https:\/\/gitlab.com\//gl:}"
    echo "$url"
}

rows=""
while IFS= read -r -d '' gitdir; do
    repo_path="$(dirname "$gitdir")"
    repo="$(basename "$repo_path")"

    origin_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
    fork_url="$(git -C "$repo_path" remote get-url fork 2>/dev/null || true)"
    branch="$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"

    notes_dir="${INDEX_ROOT}/repos/${repo}"
    note_count=0
    if [ -d "$notes_dir" ]; then
        note_count="$(find "$notes_dir" -type f -name '*.md' | wc -l | tr -d ' ')"
    fi

    fork_flag="-"
    [ -n "$fork_url" ] && fork_flag="Y"

    rows="${rows}| ${repo} | \`${repo_path}\` | $(shorten_remote "$origin_url") | ${fork_flag} | ${branch} | ${note_count} |
"
done < <(find "$GIT_ROOT" -mindepth 2 -maxdepth 2 -type d -name '.git' -print0 | sort -z)

table="${BEGIN_MARKER}
| repo | path | origin | fork | branch | notes |
|---|---|---|---|---|---|
${rows}${END_MARKER}"

if [ ! -f "$INDEX_FILE" ]; then
    cat > "$INDEX_FILE" << EOF
# ai-index registry

Registry of all repos under \`${GIT_ROOT}\`. Regenerate with \`repo-registry.sh\` after
cloning or removing a repo. Rows are cheap (remotes/branch only, no code analysis); deep
notes live under \`repos/<name>/\` and accrete separately.

${table}
EOF
    echo "ai-index: created ${INDEX_FILE}"
    exit 0
fi

if grep -q "$BEGIN_MARKER" "$INDEX_FILE" && grep -q "$END_MARKER" "$INDEX_FILE"; then
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v table="$table" '
        $0 == begin { print table; skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip       { print }
    ' "$INDEX_FILE" > "${INDEX_FILE}.tmp"
    mv "${INDEX_FILE}.tmp" "$INDEX_FILE"
else
    printf '\n%s\n' "$table" >> "$INDEX_FILE"
fi

echo "ai-index: registry updated ($(echo -n "$rows" | grep -c '^|') repos) in ${INDEX_FILE}"
