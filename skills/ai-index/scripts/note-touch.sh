#!/usr/bin/env bash
# note-touch.sh - mark a note freshly verified: sets sha to the named repo's current HEAD
# and verified to today's date. Leaves the rest of the note (frontmatter and body) untouched.
#
# Usage: note-touch.sh <note-path>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fm.sh
source "${SCRIPT_DIR}/fm.sh"
ai_index_load_config
fm_require_tools
# shellcheck source=status-lib.sh
source "${SCRIPT_DIR}/status-lib.sh"

GIT_ROOT="${AI_INDEX_GIT_ROOT}"

note="${1:-}"
if [ -z "$note" ] || [ ! -f "$note" ]; then
    echo "usage: note-touch.sh <note-path>" >&2
    exit 1
fi

repo="$(fm_get "$note" repo)"
if [ -z "$repo" ]; then
    echo "ai-index: note ${note} has no 'repo' frontmatter field - cannot resolve HEAD" >&2
    exit 1
fi

toplevel="${GIT_ROOT}/${repo}"
if ! toplevel="$(git -C "$toplevel" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
fi

if ! ai_index_load_note_metadata "$note" "$repo" no; then
    echo "ai-index: cannot verify ${note}: ${AI_NOTE_REASON}" >&2
    exit 1
fi
ai_index_pathspecs

if ! staged="$(ai_index_git_path_count "$toplevel" diff --cached --name-only -z -- "${AI_NOTE_PATHS[@]}")" || \
    ! unstaged="$(ai_index_git_path_count "$toplevel" diff --name-only -z -- "${AI_NOTE_PATHS[@]}")" || \
    ! untracked="$(ai_index_git_path_count "$toplevel" ls-files --others -z -- "${AI_NOTE_PATHS[@]}")"; then
    echo "ai-index: cannot verify ${note}: Git could not inspect declared sources" >&2
    exit 1
fi
if [ "$staged" -gt 0 ] || [ "$unstaged" -gt 0 ] || [ "$untracked" -gt 0 ]; then
    echo "ai-index: cannot stamp ${note}: declared sources have uncommitted changes (staged=${staged} unstaged=${unstaged} untracked=${untracked}), so HEAD cannot represent the current source state; commit them or restore a clean source state, review all claims, then run note-touch.sh again" >&2
    exit 1
fi

if ! head_sha="$(git -C "$toplevel" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
    echo "ai-index: cannot stamp ${note}: Git could not resolve HEAD" >&2
    exit 1
fi
today="$(date +%F)"

fm_set "$note" sha "$head_sha"
fm_set "$note" verified "$today"

echo "ai-index: ${note} - sha=${head_sha:0:7} verified=${today}"
