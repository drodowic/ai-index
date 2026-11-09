#!/usr/bin/env bash
# Shared conservative note-freshness checks for repo-status.sh and stale-check.sh.

AI_INDEX_SCRATCH_DIR=""
AI_INDEX_SCRATCH=""
AI_INDEX_SNAPSHOT_HEAD=""

# Each caller or worker owns its scratch file. Never share it between concurrent checks.
ai_index_init_scratch() {
    AI_INDEX_SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-index-status.XXXXXX")" || return 1
    AI_INDEX_SCRATCH="${AI_INDEX_SCRATCH_DIR}/output"
}

ai_index_cleanup_scratch() {
    [ -n "${AI_INDEX_SCRATCH_DIR:-}" ] || return 0
    rm -f "${AI_INDEX_SCRATCH_DIR}"/*
    rmdir "$AI_INDEX_SCRATCH_DIR" 2>/dev/null || true
}

ai_index_git_common_dir() {
    local repo_root="$1" common_dir
    if ! common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)"; then
        return 1
    fi
    if [[ "$common_dir" != /* ]]; then
        common_dir="${repo_root}/${common_dir}"
    fi
    (cd "$common_dir" 2>/dev/null && pwd -P)
}

ai_index_resolve_repo_key() {
    local repo_root="$1" git_root="$2" fallback="$3"
    local configured_top configured_real target_real git_root_real worktrees line worktree_path worktree_real relative
    AI_INDEX_REPO_KEY="$fallback"

    # The common case is the configured checkout itself; avoid listing worktrees.
    if [ -d "${git_root}/${fallback}/.git" ] && \
        configured_top="$(git -C "${git_root}/${fallback}" rev-parse --show-toplevel 2>/dev/null)"; then
        if configured_real="$(cd "$configured_top" 2>/dev/null && pwd -P)" && \
            target_real="$(cd "$repo_root" 2>/dev/null && pwd -P)" && \
            [ "$configured_real" = "$target_real" ]; then
            return 0
        fi
    fi

    if ! git_root_real="$(cd "$git_root" 2>/dev/null && pwd -P)" || \
        ! worktrees="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null)"; then
        return 1
    fi

    while IFS= read -r line; do
        case "$line" in
            "worktree "*) worktree_path="${line#worktree }" ;;
            *) continue ;;
        esac
        [ -d "$worktree_path" ] || continue
        worktree_real="$(cd "$worktree_path" 2>/dev/null && pwd -P || true)"
        case "$worktree_real" in
            "${git_root_real}"/*) relative="${worktree_real#"${git_root_real}"/}" ;;
            *) continue ;;
        esac
        if [ -n "$relative" ] && [[ "$relative" != */* ]]; then
            AI_INDEX_REPO_KEY="$relative"
            return 0
        fi
    done <<<"$worktrees"
    return 0
}

declare -A AI_INDEX_HISTORY_CACHE=()

ai_index_load_note_metadata() {
    local note="$1" expected_repo="$2" require_sha="${3:-yes}" metadata required_fields="repo, sources"
    local -a fields=()
    local related_count source_count
    [ "$require_sha" = yes ] && required_fields+=", sha"

    AI_NOTE_REPO=""
    AI_NOTE_SHA=""
    AI_NOTE_SOURCES=()
    AI_NOTE_REASON=""
    AI_NOTE_RELATED=()
    AI_NOTE_RELATED_LOADED=no

    if ! metadata="$(yq --front-matter=extract -o=json '.' "$note" 2>/dev/null)" || \
        ! jq -j --arg repo "$expected_repo" --arg require_sha "$require_sha" '
            def valid:
                type == "object" and .repo == $repo and
                (if $require_sha == "yes" then (.sha | type == "string" and length > 0) else true end) and
                (.sources | type == "array" and length > 0) and
                all(.sources[];
                    type == "string" and length > 0 and
                    (contains("\u0000") | not) and (startswith("/") | not) and
                    (((if endswith("/") then .[0:-1] else . end) | split("/") | any(. == ".." or . == "")) | not)
                );
            def simple_related:
                type == "object" and
                ((.related == null) or (.related | type == "array" and
                    all(.[]; type == "string" and (contains("\u0000") | not) and (contains("\n") | not))));
            (if simple_related then
                "related\u0000", ((.related // []) | length | tostring), "\u0000",
                ((.related // [])[] | ., "\u0000")
             else "fallback\u0000", "0\u0000" end),
            (if valid then
                "valid\u0000", (if $require_sha == "yes" then .sha else "" end), "\u0000",
                (.sources | length | tostring), "\u0000", (.sources[] | ., "\u0000")
             else "invalid\u0000" end), "end\u0000"
        ' >"$AI_INDEX_SCRATCH" 2>/dev/null <<<"$metadata"; then
        AI_NOTE_REASON="invalid or incomplete frontmatter (${required_fields})"
        return 1
    fi

    if ! mapfile -d '' -t fields <"$AI_INDEX_SCRATCH"; then
        AI_NOTE_REASON="could not read parsed frontmatter"
        return 1
    fi
    if [ "${#fields[@]}" -lt 4 ] || [ "${fields[-1]}" != end ] || [[ ! "${fields[1]}" =~ ^[0-9]+$ ]]; then
        AI_NOTE_REASON="invalid or incomplete frontmatter (${required_fields})"
        return 1
    fi
    related_count="${fields[1]}"
    if [ "${fields[0]}" = related ]; then
        AI_NOTE_RELATED=("${fields[@]:2:related_count}")
        AI_NOTE_RELATED_LOADED=yes
    fi
    fields=("${fields[@]:2+related_count}")
    if [ "${fields[0]:-}" != valid ] || [ "${#fields[@]}" -lt 4 ] || [[ ! "${fields[2]}" =~ ^[0-9]+$ ]]; then
        AI_NOTE_REASON="invalid or incomplete frontmatter (${required_fields})"
        return 1
    fi
    source_count="${fields[2]}"
    if [ "${#fields[@]}" -ne "$((source_count + 4))" ]; then
        AI_NOTE_REASON="invalid or incomplete frontmatter (${required_fields})"
        return 1
    fi
    AI_NOTE_REPO="$expected_repo"
    AI_NOTE_SHA="${fields[1]}"
    AI_NOTE_SOURCES=("${fields[@]:3:source_count}")

    if [ "$require_sha" = yes ] && [[ ! "$AI_NOTE_SHA" =~ ^[[:xdigit:]]{4,64}$ ]]; then
        AI_NOTE_REASON="missing or invalid recorded commit SHA"
        return 1
    fi
    return 0
}

ai_index_pathspecs() {
    AI_NOTE_PATHS=()
    local source
    for source in "${AI_NOTE_SOURCES[@]}"; do
        source="${source%/}"
        AI_NOTE_PATHS+=(":(literal)${source}")
    done
}

# Count NUL-terminated path output without breaking on spaces or unusual filenames.
ai_index_git_path_count() {
    local repo_root="$1"; shift
    local path count=0
    if ! git -C "$repo_root" "$@" >"$AI_INDEX_SCRATCH" 2>/dev/null; then return 1; fi
    if ! while IFS= read -r -d '' path; do count=$((count + 1)); done <"$AI_INDEX_SCRATCH"; then
        return 1
    fi
    printf '%s\n' "$count"
}

ai_index_staged_path_count() {
    local repo_root="$1"; shift
    ai_index_git_path_count "$repo_root" diff --cached --ignore-submodules=none --name-only -z -- "$@"
}

ai_index_unstaged_path_count() {
    local repo_root="$1"; shift
    ai_index_git_path_count "$repo_root" diff --ignore-submodules=none --name-only -z -- "$@"
}

ai_index_untracked_path_count() {
    local repo_root="$1"; shift
    ai_index_git_path_count "$repo_root" ls-files --others --exclude-standard -z -- "$@"
}

ai_index_flagged_source_count() {
    local repo_root="$1"; shift
    local record tag count=0
    if ! git -C "$repo_root" ls-files -v -z -- "$@" >"$AI_INDEX_SCRATCH" 2>/dev/null; then
        return 1
    fi
    while IFS= read -r -d '' record; do
        tag="${record:0:1}"
        case "$tag" in
            [[:lower:]]|S) count=$((count + 1)) ;;
        esac
    done <"$AI_INDEX_SCRATCH"
    printf '%s\n' "$count"
}

ai_index_validate_sources_at() {
    local repo_root="$1" treeish="$2" i count
    AI_SOURCE_MISSING=""
    AI_SOURCE_ERROR=""

    for i in "${!AI_NOTE_PATHS[@]}"; do
        if ! count="$(ai_index_git_path_count "$repo_root" ls-tree -r --full-tree -z --name-only "$treeish" -- "${AI_NOTE_PATHS[$i]}")"; then
            AI_SOURCE_ERROR="Git could not inspect declared sources"
            return 2
        fi
        if [ "$count" -eq 0 ]; then
            AI_SOURCE_MISSING="${AI_NOTE_SOURCES[$i]}"
            return 1
        fi
    done
    return 0
}

ai_index_check_note() {
    local repo_root="$1" note="$2" expected_repo="$3"
    local head_sha ancestor_status committed staged unstaged untracked flagged detail source_status
    AI_NOTE_STATUS="UNVERIFIED"
    AI_NOTE_DETAIL=""

    if ! ai_index_load_note_metadata "$note" "$expected_repo" yes; then
        AI_NOTE_DETAIL="$AI_NOTE_REASON"
        return 0
    fi

    if [ -n "${AI_INDEX_SNAPSHOT_HEAD:-}" ]; then
        head_sha="$AI_INDEX_SNAPSHOT_HEAD"
    elif ! head_sha="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
        AI_NOTE_DETAIL="Git could not resolve HEAD"
        return 0
    fi
    local resolved_sha resolve_status
    resolved_sha="${AI_INDEX_HISTORY_CACHE[$AI_NOTE_SHA]:-}"
    if [ -z "$resolved_sha" ]; then
        if resolved_sha="$(git -C "$repo_root" rev-parse --verify --quiet "${AI_NOTE_SHA}^{commit}" 2>/dev/null)"; then
            :
        else
            resolve_status=$?
            if [ "$resolve_status" -eq 1 ]; then
                AI_NOTE_STATUS="UNVERIFIABLE"
                AI_NOTE_DETAIL="recorded commit not found"
            else
                AI_NOTE_DETAIL="Git could not resolve the recorded commit"
            fi
            return 0
        fi

        if git -C "$repo_root" merge-base --is-ancestor "$resolved_sha" "$head_sha" 2>/dev/null; then
            ancestor_status=0
        else
            ancestor_status=$?
        fi
        if [ "$ancestor_status" -eq 1 ]; then
            AI_NOTE_STATUS="UNVERIFIABLE"
            AI_NOTE_DETAIL="recorded commit is not an ancestor of HEAD"
            return 0
        elif [ "$ancestor_status" -ne 0 ]; then
            AI_NOTE_DETAIL="Git could not check commit ancestry"
            return 0
        fi
        if [ -n "${AI_INDEX_SNAPSHOT_HEAD:-}" ]; then
            AI_INDEX_HISTORY_CACHE[$AI_NOTE_SHA]="$resolved_sha"
        fi
    fi

    ai_index_pathspecs
    if ai_index_validate_sources_at "$repo_root" "$resolved_sha"; then
        :
    else
        source_status=$?
        if [ "$source_status" -eq 1 ]; then
            AI_NOTE_DETAIL="declared source matched no tracked path at recorded commit: ${AI_SOURCE_MISSING}"
        else
            AI_NOTE_DETAIL="$AI_SOURCE_ERROR"
        fi
        return 0
    fi

    if ! flagged="$(ai_index_flagged_source_count "$repo_root" "${AI_NOTE_PATHS[@]}")" || \
        [[ ! "$flagged" =~ ^[0-9]+$ ]]; then
        AI_NOTE_DETAIL="Git could not inspect declared source index flags"
        return 0
    fi
    if [ "$flagged" -gt 0 ]; then
        AI_NOTE_DETAIL="declared sources have assume-unchanged or skip-worktree index flags (${flagged} path(s))"
        return 0
    fi

    # Default path history can simplify away a merge whose tree differs from the
    # recorded commit. Keep all merge parents so merged source changes are counted.
    if ! committed="$(git -C "$repo_root" rev-list --full-history --count "${resolved_sha}..${head_sha}" -- "${AI_NOTE_PATHS[@]}" 2>/dev/null)" || \
        [[ ! "$committed" =~ ^[0-9]+$ ]]; then
        AI_NOTE_DETAIL="Git could not inspect committed source changes"
        return 0
    fi

    if ! staged="$(ai_index_staged_path_count "$repo_root" "${AI_NOTE_PATHS[@]}")" || \
        ! unstaged="$(ai_index_unstaged_path_count "$repo_root" "${AI_NOTE_PATHS[@]}")" || \
        ! untracked="$(ai_index_untracked_path_count "$repo_root" "${AI_NOTE_PATHS[@]}")"; then
        AI_NOTE_DETAIL="Git could not inspect uncommitted source changes"
        return 0
    fi

    detail=""
    if [ "$committed" -gt 0 ]; then
        AI_NOTE_STATUS="STALE"
        detail="${committed} committed source change(s)"
    else
        AI_NOTE_STATUS="fresh"
        detail="no detected source changes"
    fi

    if [ "$staged" -gt 0 ] || [ "$unstaged" -gt 0 ] || [ "$untracked" -gt 0 ]; then
        if [ "$AI_NOTE_STATUS" = fresh ]; then AI_NOTE_STATUS="DIRTY"; else AI_NOTE_STATUS="STALE+DIRTY"; fi
        if [ "$committed" -eq 0 ]; then detail="0 committed source changes"; fi
        detail+="; staged=${staged} unstaged=${unstaged} untracked=${untracked}"
    fi
    AI_NOTE_DETAIL="$detail"
}
