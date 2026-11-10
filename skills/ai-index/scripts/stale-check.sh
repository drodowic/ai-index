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

INDEX_ROOT="${AI_INDEX_DOCS_ROOT}"
GIT_ROOT="${AI_INDEX_GIT_ROOT}"

repo="${1:-}"
if [ -z "$repo" ]; then
    echo "usage: stale-check.sh <repo-name>" >&2
    exit 1
fi

toplevel="${GIT_ROOT}/${repo}"
if [ ! -d "${toplevel}/.git" ]; then
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
fi

notes_dir="${INDEX_ROOT}/repos/${repo}"
if [ ! -d "$notes_dir" ] || [ -z "$(find "$notes_dir" -type f -name '*.md' 2>/dev/null)" ]; then
    echo "ai-index: repo=${repo} - no index notes yet."
    exit 0
fi

printf '%-35s %-10s %-12s %s\n' "note" "sha" "status" "detail"
fm_collect_status "$toplevel"
while IFS= read -r -d '' note; do
    rel="${note#"${notes_dir}"/}"
    rel="${rel%.md}"
    note_sha="$(fm_get "$note" sha)"

    mapfile -t sources < <(fm_list "$note" sources)
    fm_check_sources "${sources[@]}"
    unverifiable_details=()
    if [ "${#FM_EXTERNAL_SOURCES[@]}" -gt 0 ]; then
        unverifiable_details+=("external sources: $(fm_format_paths "${FM_EXTERNAL_SOURCES[@]}")")
    fi
    if [ "${#FM_MATCHED_IGNORED_PATHS[@]}" -gt 0 ]; then
        unverifiable_details+=("ignored paths: $(fm_format_paths "${FM_MATCHED_IGNORED_PATHS[@]}")")
    fi

    if [ -z "$note_sha" ]; then
        if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ] || [ "${#unverifiable_details[@]}" -gt 0 ]; then
            [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ] && unverifiable_details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
            printf '%-35s %-10s %-12s %s\n' "$rel" "-" "UNVERIFIABLE" "$(fm_join_details "no sha recorded" "${unverifiable_details[@]}")"
        else
            printf '%-35s %-10s %-12s %s\n' "$rel" "-" "n/a" "no sha recorded (group/reference note?)"
        fi
        continue
    fi

    if ! resolved_sha="$(git -C "$toplevel" rev-parse --verify --quiet "${note_sha}^{commit}" 2>/dev/null)"; then
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "sha not found in repo"
        continue
    fi

    if ! git -C "$toplevel" merge-base --is-ancestor "$resolved_sha" HEAD 2>/dev/null; then
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "sha is not an ancestor of HEAD"
        continue
    fi

    if [ "${#sources[@]}" -eq 0 ]; then
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "fresh" "no sources declared"
        continue
    fi

    count="$(git -C "$toplevel" rev-list --count "${resolved_sha}..HEAD" -- "${sources[@]}" 2>/dev/null || echo 0)"
    if [ "${#unverifiable_details[@]}" -gt 0 ]; then
        [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ] && unverifiable_details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
        [ "${count:-0}" -gt 0 ] && unverifiable_details+=("${count} commits since recorded sha")
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "$(fm_join_details "${unverifiable_details[@]}")"
    elif [ "${count:-0}" -gt 0 ] || [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
        details=()
        [ "${count:-0}" -gt 0 ] && details+=("${count} commits since recorded sha")
        if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
            details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
        fi
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "STALE" "$(fm_join_details "${details[@]}")"
    else
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "fresh" "no commits to sources since recorded sha"
    fi
done < <(find "$notes_dir" -type f -name '*.md' -print0 | sort -z)
