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
# shellcheck source=status-lib.sh
source "${SCRIPT_DIR}/status-lib.sh"

INDEX_ROOT="${AI_INDEX_DOCS_ROOT}"
TARGET="${1:-$PWD}"

if ! toplevel="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)"; then
    # Preserve silent behavior for ordinary non-repo paths, but do not hide Git failures
    # when a repository marker identifies the intended checkout/worktree.
    probe="$(cd "$TARGET" 2>/dev/null && pwd -P || true)"
    marker_root=""
    while [ -n "$probe" ]; do
        if [ -e "${probe}/.git" ]; then
            marker_root="$probe"
            break
        fi
        parent="$(dirname "$probe")"
        [ "$parent" = "$probe" ] && break
        probe="$parent"
    done
    [ -z "$marker_root" ] && exit 0

    repo="$(basename "$marker_root")"
    notes_dir="${INDEX_ROOT}/repos/${repo}"
    if [ ! -d "$notes_dir" ] || [ -z "$(find "$notes_dir" -type f -name '*.md' 2>/dev/null)" ]; then
        echo "[ai-index] repo=${repo} UNVERIFIED: Git could not resolve repository status"
        exit 0
    fi
    mapfile -t failed_notes < <(find "$notes_dir" -type f -name '*.md' -printf '%P\n' | sed 's/\.md$//' | sort)
    echo "[ai-index] repo=${repo}"
    echo "  notes: $(IFS=,; echo "${failed_notes[*]}")"
    echo "  freshness: 0 fresh, ${#failed_notes[@]} needing review"
    echo "  UNVERIFIED: all notes (Git could not resolve repository status)"
    exit 0
fi

repo_fallback="$(basename "$toplevel")"
if ! ai_index_resolve_repo_key "$toplevel" "$AI_INDEX_GIT_ROOT" "$repo_fallback"; then
    echo "[ai-index] repo=${repo_fallback} UNVERIFIED: Git could not identify the configured worktree"
    exit 0
fi
repo="$AI_INDEX_REPO_KEY"
branch="$(git -C "$toplevel" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
head_sha="$(git -C "$toplevel" rev-parse --short HEAD 2>/dev/null || echo "?")"
notes_dir="${INDEX_ROOT}/repos/${repo}"

if [ ! -d "$notes_dir" ] || [ -z "$(find "$notes_dir" -type f -name '*.md' 2>/dev/null)" ]; then
    echo "[ai-index] repo=${repo} - no index notes yet. Capture findings with skill \`ai-index\`."
    exit 0
fi

mapfile -d '' -t note_paths < <(find "$notes_dir" -type f -name '*.md' -print0 | sort -z)
notes=()
status_lines=()
related_from_notes=()
fresh_count=0
worker_count=1
if [ "${#note_paths[@]}" -ge 8 ]; then worker_count=4; fi
worker_pids=()
worker_ok=()
scratch_ready=no

cleanup_status() {
    local pid
    for pid in "${worker_pids[@]:-}"; do
        # Workers have separate process groups so a timeout also stops their Git children.
        [ -z "$pid" ] || kill -- "-${pid}" 2>/dev/null || true
    done
    for pid in "${worker_pids[@]:-}"; do
        [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
    done
    ai_index_cleanup_scratch
}
trap cleanup_status EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Each worker processes a disjoint set of notes and owns its Git/metadata scratch file.
run_status_worker() {
    local worker="$1" i note
    AI_INDEX_SCRATCH="${AI_INDEX_SCRATCH_DIR}/scratch-${worker}"
    for ((i=worker; i<${#note_paths[@]}; i+=worker_count)); do
        note="${note_paths[i]}"
        ai_index_check_note "$toplevel" "$note" "$repo"
        if [ "$AI_NOTE_RELATED_LOADED" != yes ]; then
            mapfile -t AI_NOTE_RELATED < <(fm_list "$note" related)
        fi
        printf '%s\0' "$AI_NOTE_STATUS" "$AI_NOTE_DETAIL" "${AI_NOTE_RELATED[@]}" end >"${AI_INDEX_SCRATCH_DIR}/note-${i}" || return 1
    done
}

AI_INDEX_SNAPSHOT_HEAD="$(git -C "$toplevel" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
if ai_index_init_scratch; then scratch_ready=yes; fi
if [ "$scratch_ready" = yes ] && [ -n "$AI_INDEX_SNAPSHOT_HEAD" ]; then
    # Job control gives each worker a process group for cancellation cleanup.
    set -m
    for ((worker=0; worker<worker_count; worker++)); do
        (run_status_worker "$worker") &
        worker_pids[worker]=$!
    done
    for ((worker=0; worker<worker_count; worker++)); do
        if wait "${worker_pids[worker]}"; then worker_ok[worker]=yes; else worker_ok[worker]=no; fi
        worker_pids[worker]=""
    done
    set +m
fi

final_head="$(git -C "$toplevel" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
for ((i=0; i<${#note_paths[@]}; i++)); do
    note="${note_paths[i]}"
    rel="${note#"${notes_dir}"/}"
    rel="${rel%.md}"
    notes+=("$rel")
    result=()
    worker=$((i % worker_count))
    if [ "${worker_ok[worker]:-no}" = yes ] && [ -r "${AI_INDEX_SCRATCH_DIR}/note-${i}" ]; then
        if ! mapfile -d '' -t result <"${AI_INDEX_SCRATCH_DIR}/note-${i}"; then result=(); fi
    fi
    note_related=()
    if [ "${#result[@]}" -ge 3 ] && [ "${result[-1]}" = end ] && \
        [[ "${result[0]}" =~ ^(fresh|STALE|DIRTY|STALE\+DIRTY|UNVERIFIED|UNVERIFIABLE)$ ]]; then
        note_status="${result[0]}"
        note_detail="${result[1]}"
        note_related=("${result[@]:2:${#result[@]}-3}")
    else
        note_status=UNVERIFIED
        note_detail='status worker failed or returned incomplete output'
        mapfile -t note_related < <(fm_list "$note" related)
    fi
    related_from_notes+=("${note_related[@]}")
    if [ -z "$AI_INDEX_SNAPSHOT_HEAD" ] || [ "$AI_INDEX_SNAPSHOT_HEAD" != "$final_head" ]; then
        note_status=UNVERIFIED
        note_detail='HEAD changed or could not be verified during status scan'
    fi
    if [ "$note_status" = fresh ]; then
        fresh_count=$((fresh_count + 1))
    else
        status_lines+=("  ${note_status}: ${rel} (${note_detail})")
    fi
done

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
echo "  freshness: ${fresh_count} fresh, ${#status_lines[@]} needing review"
for line in "${status_lines[@]:-}"; do
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
