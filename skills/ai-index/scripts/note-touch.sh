#!/usr/bin/env bash
# note-touch.sh - mark a note freshly verified: sets sha to the named repo's current HEAD
# and verified to today's date, but refuses sources Git cannot verify as clean. Leaves the
# rest of the note (frontmatter and body) untouched.
#
# Usage: note-touch.sh <note-path>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fm.sh
source "${SCRIPT_DIR}/fm.sh"
ai_index_load_config
fm_require_tools

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
if [ ! -d "${toplevel}/.git" ]; then
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
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
fm_check_sources "${sources[@]}"
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
