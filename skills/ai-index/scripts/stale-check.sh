#!/usr/bin/env bash
# stale-check.sh - staleness table for a repo's notes, addressable by name from anywhere.
#
# Unlike repo-status.sh (which infers the repo from $PWD), this resolves the repo by name
# under $AI_INDEX_GIT_ROOT, so it works for cross-repo lookups from a different checkout.
#
# Usage: stale-check.sh <repo-name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fm.sh
source "${SCRIPT_DIR}/fm.sh"
ai_index_load_config
fm_require_tools
# shellcheck source=status-lib.sh
source "${SCRIPT_DIR}/status-lib.sh"
if ! ai_index_init_scratch; then
    echo 'ai-index: cannot create temporary status workspace' >&2
    exit 1
fi
trap ai_index_cleanup_scratch EXIT

INDEX_ROOT="${AI_INDEX_DOCS_ROOT}"
GIT_ROOT="${AI_INDEX_GIT_ROOT}"

repo="${1:-}"
if [ -z "$repo" ]; then
    echo "usage: stale-check.sh <repo-name>" >&2
    exit 1
fi

repo_path="${GIT_ROOT}/${repo}"
if ! toplevel="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)"; then
    if [ ! -e "${repo_path}/.git" ]; then
        echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
        exit 1
    fi
    notes_dir="${INDEX_ROOT}/repos/${repo}"
    if [ ! -d "$notes_dir" ] || [ -z "$(find "$notes_dir" -type f -name '*.md' 2>/dev/null)" ]; then
        echo "ai-index: repo=${repo} - no index notes yet (Git status unavailable)."
        exit 0
    fi
    printf '%-35s %-10s %-12s %s\n' "note" "sha" "status" "detail"
    while IFS= read -r -d '' note; do
        rel="${note#"${notes_dir}"/}"
        rel="${rel%.md}"
        note_sha="$(fm_get "$note" sha)"
        note_sha="${note_sha:0:7}"
        [ -n "$note_sha" ] || note_sha="-"
        printf '%-35s %-10s %-12s %s\n' "$rel" "$note_sha" "UNVERIFIED" "Git could not resolve repository status"
    done < <(find "$notes_dir" -type f -name '*.md' -print0 | sort -z)
    exit 0
fi

notes_dir="${INDEX_ROOT}/repos/${repo}"
if [ ! -d "$notes_dir" ] || [ -z "$(find "$notes_dir" -type f -name '*.md' 2>/dev/null)" ]; then
    echo "ai-index: repo=${repo} - no index notes yet."
    exit 0
fi

printf '%-35s %-10s %-12s %s\n' "note" "sha" "status" "detail"
while IFS= read -r -d '' note; do
    rel="${note#"${notes_dir}"/}"
    rel="${rel%.md}"
    ai_index_check_note "$toplevel" "$note" "$repo"
    note_sha="${AI_NOTE_SHA:0:7}"
    [ -n "$note_sha" ] || note_sha="-"
    printf '%-35s %-10s %-12s %s\n' "$rel" "$note_sha" "$AI_NOTE_STATUS" "$AI_NOTE_DETAIL"
done < <(find "$notes_dir" -type f -name '*.md' -print0 | sort -z)
