#!/usr/bin/env bash
# note-touch.sh - mark a note freshly verified: sets sha to the named repo's current HEAD
# (or the active linked worktree's HEAD) and verified to today's date, but refuses sources
# Git cannot verify as clean. Leaves the rest of the note untouched.
#
# Usage: note-touch.sh <note-path> [--worktree <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fm.sh
source "${SCRIPT_DIR}/fm.sh"
ai_index_load_config
fm_require_tools

GIT_ROOT="${AI_INDEX_GIT_ROOT}"

note="${1:-}"
if [ -z "$note" ] || [ ! -f "$note" ]; then
    echo "usage: note-touch.sh <note-path> [--worktree <path>]" >&2
    exit 1
fi
shift

WORKTREE_TARGET=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--worktree" ] && [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$WORKTREE_TARGET" ]; then
        WORKTREE_TARGET="$2"
        shift 2
    else
        echo "usage: note-touch.sh <note-path> [--worktree <path>]" >&2
        exit 1
    fi
done

repo="$(fm_get "$note" repo)"
if [ -z "$repo" ]; then
    echo "ai-index: note ${note} has no 'repo' frontmatter field - cannot resolve HEAD" >&2
    exit 1
fi
if [[ "$repo" == */* || "$repo" == "." || "$repo" == ".." ]]; then
    echo "ai-index: note ${note} has invalid 'repo' frontmatter - cannot resolve HEAD" >&2
    exit 1
fi

configured_path="${GIT_ROOT}/${repo}"
if ! configured_toplevel="$(git -C "$configured_path" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
fi
if ! repo_common_dir="$(fm_git_common_dir "$configured_toplevel")"; then
    echo "ai-index: Git check failed while resolving common directory for repo '${repo}'" >&2
    exit 1
fi

fm_configured_repo_keys_for_common_dir "$repo_common_dir"
if [ "${#FM_CONFIGURED_REPO_KEYS[@]}" -gt 1 ]; then
    repo_is_match=false
    for configured_repo in "${FM_CONFIGURED_REPO_KEYS[@]}"; do
        [ "$configured_repo" = "$repo" ] && repo_is_match=true
    done
    if [ "$repo_is_match" = false ]; then
        matches="$(IFS=,; printf '%s' "${FM_CONFIGURED_REPO_KEYS[*]}")"
        echo "ai-index: note repo '${repo}' conflicts with configured identities sharing its Git common directory: ${matches}" >&2
        exit 1
    fi
    if [ -z "$WORKTREE_TARGET" ]; then
        matches="$(IFS=,; printf '%s' "${FM_CONFIGURED_REPO_KEYS[*]}")"
        echo "ai-index: ambiguous repository identity for '${repo}'; common Git directory matches: ${matches}. Rerun with --worktree <path> to confirm the intended worktree." >&2
        exit 1
    fi
elif [ "${#FM_CONFIGURED_REPO_KEYS[@]}" -eq 1 ] && [ "${FM_CONFIGURED_REPO_KEYS[0]}" != "$repo" ]; then
    echo "ai-index: note repo '${repo}' resolves to configured identity '${FM_CONFIGURED_REPO_KEYS[0]}'; refusing to stamp under the wrong identity" >&2
    exit 1
fi

if [ -n "$WORKTREE_TARGET" ]; then
    if ! toplevel="$(git -C "$WORKTREE_TARGET" rev-parse --show-toplevel 2>/dev/null)"; then
        echo "ai-index: --worktree target is not a Git worktree: ${WORKTREE_TARGET}" >&2
        exit 1
    fi
    if ! target_common_dir="$(fm_git_common_dir "$toplevel")" || [ "$target_common_dir" != "$repo_common_dir" ]; then
        echo "ai-index: worktree '${WORKTREE_TARGET}' does not belong to configured repo '${repo}'" >&2
        exit 1
    fi
else
    toplevel="$configured_toplevel"
    if active_toplevel="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" && \
       active_common_dir="$(fm_git_common_dir "$active_toplevel")" && \
       [ "$active_common_dir" = "$repo_common_dir" ]; then
        toplevel="$active_toplevel"
    fi
fi

if ! fm_validate_source_list "$note"; then
    echo "ai-index: refusing to stamp ${note}; ${FM_SOURCE_LIST_ERROR}." >&2
    exit 1
fi
mapfile -t sources < <(fm_list "$note" sources)
if ! head_sha="$(git -C "$toplevel" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
    echo "ai-index: refusing to stamp ${note}; Git check failed while resolving HEAD." >&2
    exit 1
fi
if ! fm_validate_sources_at_commit "$toplevel" "$head_sha" "${sources[@]}"; then
    echo "ai-index: refusing to stamp ${note}; ${FM_SOURCE_VALIDATION_ERROR}." >&2
    exit 1
fi

fm_collect_status "$toplevel"
fm_check_sources "$toplevel" "${sources[@]}"
if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ] || [ "${#FM_MATCHED_IGNORED_PATHS[@]}" -gt 0 ] || [ "${#FM_EXTERNAL_SOURCES[@]}" -gt 0 ]; then
    echo "ai-index: refusing to stamp ${note}; verify these sources first." >&2
    if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
        echo "  working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")" >&2
    fi
    if [ "${#FM_MATCHED_IGNORED_PATHS[@]}" -gt 0 ]; then
        echo "  ignored paths (Git cannot verify these): $(fm_format_paths "${FM_MATCHED_IGNORED_PATHS[@]}")" >&2
    fi
    if [ "${#FM_EXTERNAL_SOURCES[@]}" -gt 0 ]; then
        echo "  external sources (Git cannot verify these): $(fm_format_paths "${FM_EXTERNAL_SOURCES[@]}")" >&2
    fi
    exit 1
fi

today="$(date +%F)"

fm_set "$note" sha "$head_sha"
fm_set "$note" verified "$today"

echo "ai-index: ${note} - sha=${head_sha:0:7} verified=${today}"
