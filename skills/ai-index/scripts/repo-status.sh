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
TARGET="${1:-$PWD}"

toplevel="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$toplevel" ] && exit 0   # not a git repo - silent, not an error

repo="$(basename "$toplevel")"
branch="$(git -C "$toplevel" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
head_sha="$(git -C "$toplevel" rev-parse --short HEAD 2>/dev/null || echo "?")"
notes_dir="${INDEX_ROOT}/repos/${repo}"

if [ ! -d "$notes_dir" ] || [ -z "$(find "$notes_dir" -type f -name '*.md' 2>/dev/null)" ]; then
    echo "[ai-index] repo=${repo} - no index notes yet. Capture findings with skill \`ai-index\`."
    exit 0
fi

notes=()
stale_lines=()
related_from_notes=()
fm_collect_status "$toplevel"

while IFS= read -r -d '' note; do
    rel="${note#"${notes_dir}"/}"
    rel="${rel%.md}"
    notes+=("$rel")

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
        if [ "${#unverifiable_details[@]}" -gt 0 ]; then
            [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ] && unverifiable_details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
            stale_lines+=("  UNVERIFIABLE: ${rel} (no sha recorded; $(fm_join_details "${unverifiable_details[@]}"))")
        elif [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
            stale_lines+=("  STALE: ${rel} (working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}"); no sha recorded)")
        fi
    else
        if resolved_sha="$(git -C "$toplevel" rev-parse --verify --quiet "${note_sha}^{commit}" 2>/dev/null)"; then
            if git -C "$toplevel" merge-base --is-ancestor "$resolved_sha" HEAD 2>/dev/null; then
                count=0
                if [ "${#sources[@]}" -gt 0 ]; then
                    count="$(git -C "$toplevel" rev-list --count "${resolved_sha}..HEAD" -- "${sources[@]}" 2>/dev/null || echo 0)"
                fi
                if [ "${#unverifiable_details[@]}" -gt 0 ]; then
                    if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
                        unverifiable_details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
                    fi
                    [ "${count:-0}" -gt 0 ] && unverifiable_details+=("${count} commits since ${note_sha:0:7}")
                    stale_lines+=("  UNVERIFIABLE: ${rel} ($(fm_join_details "${unverifiable_details[@]}"))")
                elif [ "${count:-0}" -gt 0 ] || [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
                    details=()
                    [ "${count:-0}" -gt 0 ] && details+=("${count} commits since ${note_sha:0:7}")
                    if [ "${#FM_MATCHED_DIRTY_PATHS[@]}" -gt 0 ]; then
                        details+=("working-tree changes: $(fm_format_paths "${FM_MATCHED_DIRTY_PATHS[@]}")")
                    fi
                    stale_lines+=("  STALE: ${rel} ($(fm_join_details "${details[@]}"))")
                fi
            else
                stale_lines+=("  UNVERIFIABLE: ${rel} (sha ${note_sha:0:7} is not an ancestor of HEAD)")
            fi
        else
            stale_lines+=("  UNVERIFIABLE: ${rel} (sha ${note_sha:0:7} not found - force-push or shallow clone?)")
        fi
    fi

    mapfile -t note_related < <(fm_list "$note" related)
    related_from_notes+=("${note_related[@]}")
done < <(find "$notes_dir" -type f -name '*.md' -print0 | sort -z)

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

echo "[ai-index] repo=${repo} @ ${branch} ${head_sha}"
echo "  notes: $(IFS=,; echo "${notes[*]}")"
for line in "${stale_lines[@]:-}"; do
    [ -n "$line" ] && echo "$line"
done

mapfile -t related_repos < <(printf '%s\n' "${related_from_notes[@]:-}" "${related_from_groups[@]:-}" | grep -v '^$' | sort -u)
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
