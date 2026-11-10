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

if [[ "$repo" == */* || "$repo" == "." || "$repo" == ".." ]]; then
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
fi

configured_path="${GIT_ROOT}/${repo}"
if [ ! -d "$configured_path" ]; then
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
fi
configured_checkout="$(cd "$configured_path" 2>/dev/null && pwd -P)" || {
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
}
# Git accepts paths inside a checkout; require the configured path itself to be
# the worktree root so checks cannot silently use a parent repository.
git_toplevel="$(git -C "$configured_path" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ai-index: no repo named '${repo}' under ${GIT_ROOT}" >&2
    exit 1
}
git_toplevel="$(cd "$git_toplevel" 2>/dev/null && pwd -P)" || {
    echo "ai-index: Git check failed while resolving configured checkout '${configured_checkout}'" >&2
    exit 1
}
if [ "$git_toplevel" != "$configured_checkout" ]; then
    echo "ai-index: configured path '${configured_checkout}' is not a Git worktree root (Git top-level is '${git_toplevel}')" >&2
    exit 1
fi
toplevel="$git_toplevel"

if ! branch="$(git -C "$toplevel" rev-parse --abbrev-ref HEAD 2>/dev/null)" || \
   ! head_sha="$(git -C "$toplevel" rev-parse --short HEAD 2>/dev/null)"; then
    echo "ai-index: Git check failed while resolving repository HEAD for ${toplevel}" >&2
    exit 1
fi
printf '[ai-index] repo=%s @ %s %s (configured checkout: %s)\n' \
    "$repo" "$branch" "$head_sha" "$toplevel"

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

    if fm_validate_source_list "$note"; then
        source_list_valid=true
        mapfile -t sources < <(fm_list "$note" sources)
    else
        source_list_valid=false
        sources=()
    fi
    fm_check_sources "$toplevel" "${sources[@]}"
    unverifiable_details=()
    if [ "${#FM_EXTERNAL_SOURCES[@]}" -gt 0 ]; then
        unverifiable_details+=("external sources: $(fm_format_paths "${FM_EXTERNAL_SOURCES[@]}")")
    fi
    if [ "${#FM_MATCHED_IGNORED_PATHS[@]}" -gt 0 ]; then
        unverifiable_details+=("ignored paths: $(fm_format_paths "${FM_MATCHED_IGNORED_PATHS[@]}")")
    fi
    if [ "${#FM_MATCHED_FLAGGED_PATHS[@]}" -gt 0 ]; then
        unverifiable_details+=("flagged index paths (assume-unchanged/skip-worktree): $(fm_format_paths "${FM_MATCHED_FLAGGED_PATHS[@]}")")
    fi

    if [ -z "$note_sha" ]; then
        [ "$source_list_valid" = false ] && unverifiable_details+=("${FM_SOURCE_LIST_ERROR}")
        [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ] && unverifiable_details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
        printf '%-35s %-10s %-12s %s\n' "$rel" "-" "UNVERIFIABLE" "$(fm_join_details "no sha recorded" "${unverifiable_details[@]}")"
        continue
    fi

    if ! fm_resolve_commit_hash "$toplevel" "$note_sha"; then
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "$FM_COMMIT_HASH_ERROR"
        continue
    fi
    resolved_sha="$FM_RESOLVED_COMMIT_HASH"

    if git -C "$toplevel" merge-base --is-ancestor "$resolved_sha" HEAD 2>/dev/null; then
        :
    else
        merge_base_status=$?
        if [ "$merge_base_status" -eq 1 ]; then
            printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "sha is not an ancestor of HEAD"
        else
            printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "Git check failed"
        fi
        continue
    fi

    if [ "$source_list_valid" = false ]; then
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "$FM_SOURCE_LIST_ERROR"
        continue
    fi

    if ! fm_validate_sources_at_commit "$toplevel" "$resolved_sha" "${sources[@]}"; then
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "$FM_SOURCE_VALIDATION_ERROR"
        continue
    fi

    if [ "$FM_SOURCE_IS_ROOT" = true ]; then
        if ! count="$(git -C "$toplevel" rev-list --count "${resolved_sha}..HEAD" 2>/dev/null)"; then
            count=""
        fi
    elif ! count="$(git -C "$toplevel" rev-list --count "${resolved_sha}..HEAD" -- "${FM_LITERAL_SOURCE_PATHS[@]}" 2>/dev/null)"; then
        count=""
    fi

    if [ -z "$count" ]; then
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "Git check failed"
    elif [ "${#unverifiable_details[@]}" -gt 0 ]; then
        [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ] && unverifiable_details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
        [ "$count" -gt 0 ] && unverifiable_details+=("${count} commits since recorded sha")
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "UNVERIFIABLE" "$(fm_join_details "${unverifiable_details[@]}")"
    elif [ "$count" -gt 0 ] || [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
        details=()
        [ "$count" -gt 0 ] && details+=("${count} commits since recorded sha")
        if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
            details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
        fi
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "STALE" "$(fm_join_details "${details[@]}")"
    else
        printf '%-35s %-10s %-12s %s\n' "$rel" "${note_sha:0:7}" "fresh" "no commits to sources since recorded sha"
    fi
done < <(find "$notes_dir" -type f -name '*.md' -print0 | sort -z)
