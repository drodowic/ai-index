#!/usr/bin/env bash
# Shared conservative note-freshness checks for repo-status.sh and stale-check.sh.

ai_index_load_note_metadata() {
    local note="$1" expected_repo="$2" require_sha="${3:-yes}" metadata required_fields="repo, sources"
    [ "$require_sha" = yes ] && required_fields+=", sha"

    AI_NOTE_REPO=""
    AI_NOTE_SHA=""
    AI_NOTE_SOURCES=()
    AI_NOTE_REASON=""

    if ! metadata="$(yq --front-matter=extract -o=json '.' "$note" 2>/dev/null)" || \
        ! jq -e --arg repo "$expected_repo" --arg require_sha "$require_sha" '
            type == "object" and
            .repo == $repo and
            (if $require_sha == "yes" then (.sha | type == "string" and length > 0) else true end) and
            (.sources | type == "array" and length > 0) and
            all(.sources[];
                type == "string" and length > 0 and
                (startswith("/") | not) and
                (((if endswith("/") then .[0:-1] else . end) | split("/") | any(. == ".." or . == "")) | not)
            )
        ' >/dev/null <<<"$metadata"; then
        AI_NOTE_REASON="invalid or incomplete frontmatter (${required_fields})"
        return 1
    fi

    AI_NOTE_REPO="$(jq -r '.repo' <<<"$metadata")"
    AI_NOTE_SHA="$(jq -r '.sha // ""' <<<"$metadata")"
    mapfile -t AI_NOTE_SOURCES < <(jq -r '.sources[]' <<<"$metadata")

    if [ "$require_sha" = yes ] && [[ ! "$AI_NOTE_SHA" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
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
    local output_file count
    output_file="$(mktemp "${TMPDIR:-/tmp}/ai-index-status.XXXXXX")" || return 1
    if ! git -C "$repo_root" "$@" >"$output_file" 2>/dev/null; then
        rm -f "$output_file"
        return 1
    fi
    count="$(tr -cd '\000' <"$output_file" | wc -c | tr -d '[:space:]')"
    rm -f "$output_file"
    printf '%s\n' "$count"
}

ai_index_untracked_path_count() {
    local repo_root="$1"; shift
    ai_index_git_path_count "$repo_root" ls-files --others --exclude-standard -z -- "$@"
}

ai_index_check_note() {
    local repo_root="$1" note="$2" expected_repo="$3"
    local head_sha ancestor_status committed staged unstaged untracked detail
    AI_NOTE_STATUS="UNVERIFIED"
    AI_NOTE_DETAIL=""

    if ! ai_index_load_note_metadata "$note" "$expected_repo" yes; then
        AI_NOTE_DETAIL="$AI_NOTE_REASON"
        return 0
    fi

    if ! head_sha="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
        AI_NOTE_DETAIL="Git could not resolve HEAD"
        return 0
    fi
    local resolved_sha resolve_status
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

    if git -C "$repo_root" merge-base --is-ancestor "$AI_NOTE_SHA" "$head_sha" 2>/dev/null; then
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

    ai_index_pathspecs
    if ! committed="$(git -C "$repo_root" rev-list --count "${AI_NOTE_SHA}..${head_sha}" -- "${AI_NOTE_PATHS[@]}" 2>/dev/null)" || \
        [[ ! "$committed" =~ ^[0-9]+$ ]]; then
        AI_NOTE_DETAIL="Git could not inspect committed source changes"
        return 0
    fi

    if ! staged="$(ai_index_git_path_count "$repo_root" diff --cached --name-only -z -- "${AI_NOTE_PATHS[@]}")" || \
        ! unstaged="$(ai_index_git_path_count "$repo_root" diff --name-only -z -- "${AI_NOTE_PATHS[@]}")" || \
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
