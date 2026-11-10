#!/usr/bin/env bash
# repo-status.sh - print the ai-index digest for a repo (notes present, staleness, related repos).
#
# Used both interactively and by the SessionStart hook. Exits 0 with no output when the given
# path is not inside a git repo, so the hook can call it unconditionally.
#
# Usage: repo-status.sh [path]   (default: $PWD)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fm.sh
source "${SCRIPT_DIR}/fm.sh"
ai_index_load_config
fm_require_tools

INDEX_ROOT="${AI_INDEX_DOCS_ROOT}"
GIT_ROOT="${AI_INDEX_GIT_ROOT}"
TARGET="$PWD"
EXPLICIT_REPO=""
TARGET_SET=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            if [ "$#" -lt 2 ] || [ -z "$2" ] || [ -n "$EXPLICIT_REPO" ]; then
                echo "usage: repo-status.sh [path] [--repo <repo-name>]" >&2
                exit 1
            fi
            EXPLICIT_REPO="$2"
            shift 2
            ;;
        *)
            if [ "$TARGET_SET" = true ]; then
                echo "usage: repo-status.sh [path] [--repo <repo-name>]" >&2
                exit 1
            fi
            TARGET="$1"
            TARGET_SET=true
            shift
            ;;
    esac
done

toplevel="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$toplevel" ] && {
    [ -z "$EXPLICIT_REPO" ] && exit 0   # not a git repo - silent, not an error
    echo "ai-index: ${TARGET} is not a Git worktree; cannot resolve --repo ${EXPLICIT_REPO}" >&2
    exit 1
}

if ! target_common_dir="$(fm_git_common_dir "$toplevel")"; then
    echo "ai-index: Git check failed while resolving common directory for ${toplevel}" >&2
    exit 1
fi

if [ -n "$EXPLICIT_REPO" ]; then
    if [[ "$EXPLICIT_REPO" == */* || "$EXPLICIT_REPO" == "." || "$EXPLICIT_REPO" == ".." ]] || \
       ! configured_common_dir="$(fm_git_common_dir "${GIT_ROOT}/${EXPLICIT_REPO}")"; then
        echo "ai-index: no configured repo named '${EXPLICIT_REPO}' under ${GIT_ROOT}" >&2
        exit 1
    fi
    if [ "$configured_common_dir" != "$target_common_dir" ]; then
        echo "ai-index: ${TARGET} does not belong to configured repo '${EXPLICIT_REPO}'" >&2
        exit 1
    fi
    repo="$EXPLICIT_REPO"
else
    fm_configured_repo_keys_for_common_dir "$target_common_dir"
    if [ "${#FM_CONFIGURED_REPO_KEYS[@]}" -gt 1 ]; then
        matches="$(IFS=,; printf '%s' "${FM_CONFIGURED_REPO_KEYS[*]}")"
        echo "ai-index: ambiguous repository identity for ${toplevel}; common Git directory matches configured repos: ${matches}. Rerun with --repo <repo-name>." >&2
        exit 1
    elif [ "${#FM_CONFIGURED_REPO_KEYS[@]}" -eq 1 ]; then
        repo="${FM_CONFIGURED_REPO_KEYS[0]}"
    else
        # Preserve basename identities for repositories outside the configured root.
        repo="$(basename "$toplevel")"
    fi
fi

if ! branch="$(git -C "$toplevel" rev-parse --abbrev-ref HEAD 2>/dev/null)" || \
   ! head_sha="$(git -C "$toplevel" rev-parse --short HEAD 2>/dev/null)"; then
    echo "ai-index: Git check failed while resolving repository HEAD for ${toplevel}" >&2
    exit 1
fi
notes_dir="${INDEX_ROOT}/repos/${repo}"

has_notes=true
if [ ! -d "$notes_dir" ] || [ -z "$(find "$notes_dir" -type f -name '*.md' 2>/dev/null)" ]; then
    has_notes=false
fi

notes=()
stale_lines=()
related_from_notes=()
if [ "$has_notes" = true ]; then
    fm_collect_status "$toplevel"
fi

while IFS= read -r -d '' note; do
    rel="${note#"${notes_dir}"/}"
    rel="${rel%.md}"
    notes+=("$rel")

    note_sha="$(fm_get "$note" sha)"
    if fm_validate_source_list "$note"; then
        source_list_valid=true
        mapfile -t sources < <(fm_list "$note" sources)
    else
        source_list_valid=false
        sources=()
    fi
    fm_check_sources "${sources[@]}"
    unverifiable_details=()
    if [ "${#FM_EXTERNAL_SOURCES[@]}" -gt 0 ]; then
        unverifiable_details+=("external sources: $(fm_format_paths "${FM_EXTERNAL_SOURCES[@]}")")
    fi
    if [ "${#FM_MATCHED_IGNORED_PATHS[@]}" -gt 0 ]; then
        unverifiable_details+=("ignored paths: $(fm_format_paths "${FM_MATCHED_IGNORED_PATHS[@]}")")
    fi

    if [ -z "$note_sha" ]; then
        [ "$source_list_valid" = false ] && unverifiable_details+=("${FM_SOURCE_LIST_ERROR}")
        [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ] && unverifiable_details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
        stale_lines+=("  UNVERIFIABLE: ${rel} ($(fm_join_details "no sha recorded" "${unverifiable_details[@]}"))")
    else
        if fm_resolve_commit_hash "$toplevel" "$note_sha"; then
            resolved_sha="$FM_RESOLVED_COMMIT_HASH"
            if git -C "$toplevel" merge-base --is-ancestor "$resolved_sha" HEAD 2>/dev/null; then
                if [ "$source_list_valid" = false ]; then
                    stale_lines+=("  UNVERIFIABLE: ${rel} (${FM_SOURCE_LIST_ERROR})")
                elif ! fm_validate_sources_at_commit "$toplevel" "$resolved_sha" "${sources[@]}"; then
                    stale_lines+=("  UNVERIFIABLE: ${rel} (${FM_SOURCE_VALIDATION_ERROR})")
                else
                    count=""
                    if [ "$FM_SOURCE_IS_ROOT" = true ]; then
                        if ! count="$(git -C "$toplevel" rev-list --count "${resolved_sha}..HEAD" 2>/dev/null)"; then
                            count=""
                        fi
                    elif ! count="$(git -C "$toplevel" rev-list --count "${resolved_sha}..HEAD" -- "${FM_LITERAL_SOURCE_PATHS[@]}" 2>/dev/null)"; then
                        count=""
                    fi

                    if [ -z "$count" ]; then
                        stale_lines+=("  UNVERIFIABLE: ${rel} (Git check failed)")
                    elif [ "${#unverifiable_details[@]}" -gt 0 ]; then
                        if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
                            unverifiable_details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
                        fi
                        [ "$count" -gt 0 ] && unverifiable_details+=("${count} commits since ${note_sha:0:7}")
                        stale_lines+=("  UNVERIFIABLE: ${rel} ($(fm_join_details "${unverifiable_details[@]}"))")
                    elif [ "$count" -gt 0 ] || [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
                        details=()
                        [ "$count" -gt 0 ] && details+=("${count} commits since ${note_sha:0:7}")
                        if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
                            details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
                        fi
                        stale_lines+=("  STALE: ${rel} ($(fm_join_details "${details[@]}"))")
                    fi
                fi
            else
                merge_base_status=$?
                if [ "$merge_base_status" -eq 1 ]; then
                    stale_lines+=("  UNVERIFIABLE: ${rel} (sha ${note_sha:0:7} is not an ancestor of HEAD)")
                else
                    stale_lines+=("  UNVERIFIABLE: ${rel} (Git check failed)")
                fi
            fi
        else
            stale_lines+=("  UNVERIFIABLE: ${rel} (${FM_COMMIT_HASH_ERROR})")
        fi
    fi

    mapfile -t note_related < <(fm_list "$note" related)
    related_from_notes+=("${note_related[@]}")
done < <(find "$notes_dir" -type f -name '*.md' -print0 2>/dev/null | sort -z)

# A related link is a relationship, not a one-way dependency. Include repos
# whose notes point at this repo so those notes can be discovered from either side.
related_from_reverse_links=()
repos_dir="${INDEX_ROOT}/repos"
if [ -d "$repos_dir" ]; then
    while IFS= read -r -d '' note; do
        relative_note="${note#"${repos_dir}"/}"
        note_repo="${relative_note%%/*}"
        [ "$note_repo" = "$repo" ] && continue
        mapfile -t note_related < <(fm_list "$note" related)
        if printf '%s\n' "${note_related[@]:-}" | grep -qxF "$repo"; then
            related_from_reverse_links+=("$note_repo")
        fi
    done < <(find "$repos_dir" -type f -name '*.md' -print0 2>/dev/null)
fi

# Group notes that list this repo also count as "related to" every other repo they list.
related_from_groups=()
if [ -d "${INDEX_ROOT}/groups" ]; then
    while IFS= read -r -d '' group; do
        mapfile -t group_repos < <(fm_list "$group" repos)
        if printf '%s\n' "${group_repos[@]}" | grep -qxF "$repo"; then
            for r in "${group_repos[@]}"; do
                [ "$r" != "$repo" ] && related_from_groups+=("$r")
            done
        fi
    done < <(find "${INDEX_ROOT}/groups" -type f -name '*.md' -print0 2>/dev/null)
fi

if [ "$has_notes" = true ]; then
    echo "[ai-index] repo=${repo} @ ${branch} ${head_sha}"
    echo "  notes: $(IFS=,; echo "${notes[*]}")"
else
    echo "[ai-index] repo=${repo} - no index notes yet. Capture findings with skill \`ai-index\`."
fi
for line in "${stale_lines[@]:-}"; do
    [ -n "$line" ] && echo "$line"
done

mapfile -t related_repos < <(
    printf '%s\n' \
        "${related_from_notes[@]:-}" \
        "${related_from_reverse_links[@]:-}" \
        "${related_from_groups[@]:-}" |
        grep -v '^$' | sort -u
)
if [ "${#related_repos[@]}" -gt 0 ]; then
    related_summary=()
    for r in "${related_repos[@]}"; do
        r_notes_dir="${INDEX_ROOT}/repos/${r}"
        r_count=0
        [ -d "$r_notes_dir" ] && r_count="$(find "$r_notes_dir" -type f -name '*.md' | wc -l | tr -d ' ')"
        related_summary+=("${r} (${r_count} notes)")
    done
    echo "  related: $(IFS=,; echo "${related_summary[*]}" | sed 's/,/, /g')"
fi

echo "  root: ${INDEX_ROOT}"
echo "  protocol: skill \`ai-index\`"
