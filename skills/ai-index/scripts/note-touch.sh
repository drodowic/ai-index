#!/usr/bin/env bash
# note-touch.sh - mark a note freshly verified: sets sha to its active matching worktree HEAD,
# or the configured checkout's HEAD when no matching worktree is active.
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
if ! ai_index_init_scratch; then
    echo 'ai-index: cannot create temporary status workspace' >&2
    exit 1
fi
trap ai_index_cleanup_scratch EXIT

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

configured_root="${GIT_ROOT}/${repo}"
if ! configured_toplevel="$(git -C "$configured_root" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
fi
toplevel="$configured_toplevel"

if active_toplevel="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
    if ! configured_common="$(ai_index_git_common_dir "$configured_toplevel")" || \
        ! active_common="$(ai_index_git_common_dir "$active_toplevel")"; then
        echo "ai-index: cannot stamp ${note}: Git could not identify the active worktree" >&2
        exit 1
    fi
    if [ "$configured_common" = "$active_common" ]; then
        toplevel="$active_toplevel"
    fi
fi

if ! ai_index_load_note_metadata "$note" "$repo" no; then
    echo "ai-index: cannot verify ${note}: ${AI_NOTE_REASON}" >&2
    exit 1
fi

if ! head_sha="$(git -C "$toplevel" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
    echo "ai-index: cannot stamp ${note}: Git could not resolve HEAD" >&2
    exit 1
fi
ai_index_pathspecs

if ai_index_validate_sources_at "$toplevel" "$head_sha"; then
    :
else
    source_status=$?
    if [ "$source_status" -eq 1 ]; then
        echo "ai-index: cannot stamp ${note}: declared source matched no tracked path at HEAD: ${AI_SOURCE_MISSING}; correct the source list and review all claims" >&2
    else
        echo "ai-index: cannot stamp ${note}: ${AI_SOURCE_ERROR}" >&2
    fi
    exit 1
fi

if ! flag_result="$(ai_index_flagged_source_count "$toplevel" "${AI_NOTE_PATHS[@]}")"; then
    echo "ai-index: cannot verify ${note}: Git could not inspect declared source index flags or a declared submodule is unavailable" >&2
    exit 1
fi
read -r flagged submodule_dirty <<<"$flag_result"
if [[ ! "$flagged" =~ ^[0-9]+$ || ! "$submodule_dirty" =~ ^[0-9]+$ ]]; then
    echo "ai-index: cannot verify ${note}: Git returned invalid declared source index status" >&2
    exit 1
fi
if [ "$flagged" -gt 0 ]; then
    echo "ai-index: cannot stamp ${note}: declared sources have assume-unchanged or skip-worktree index flags (${flagged} path(s)); clear the flags and review all claims" >&2
    exit 1
fi

if ! staged="$(ai_index_staged_path_count "$toplevel" "${AI_NOTE_PATHS[@]}")" || \
    ! unstaged="$(ai_index_unstaged_path_count "$toplevel" "${AI_NOTE_PATHS[@]}")" || \
    ! untracked="$(ai_index_untracked_path_count "$toplevel" "${AI_NOTE_PATHS[@]}")"; then
    echo "ai-index: cannot verify ${note}: Git could not inspect declared sources" >&2
    exit 1
fi
if [ "$submodule_dirty" -gt 0 ] && [ "$staged" -eq 0 ] && \
    [ "$unstaged" -eq 0 ] && [ "$untracked" -eq 0 ]; then
    echo "ai-index: cannot stamp ${note}: nested declared submodule sources have uncommitted changes; commit or restore them, review all claims, then run note-touch.sh again" >&2
    exit 1
fi
if [ "$staged" -gt 0 ] || [ "$unstaged" -gt 0 ] || [ "$untracked" -gt 0 ]; then
    echo "ai-index: cannot stamp ${note}: declared sources have uncommitted changes (staged=${staged} unstaged=${unstaged} untracked=${untracked}), so HEAD cannot represent the current source state; commit them or restore a clean source state, review all claims, then run note-touch.sh again" >&2
    exit 1
fi

if ! final_head_sha="$(git -C "$toplevel" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
    echo "ai-index: cannot stamp ${note}: Git could not recheck HEAD after source verification" >&2
    exit 1
fi
if [ "$head_sha" != "$final_head_sha" ]; then
    echo "ai-index: cannot stamp ${note}: HEAD changed during source verification; no SHA was written, rerun note-touch.sh" >&2
    exit 1
fi

today="$(date +%F)"

fm_set "$note" sha "$head_sha"
fm_set "$note" verified "$today"

echo "ai-index: ${note} - sha=${head_sha:0:7} verified=${today}"
