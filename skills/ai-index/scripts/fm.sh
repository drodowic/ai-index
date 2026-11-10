#!/usr/bin/env bash
# fm.sh - frontmatter helpers for ai-index notes. Source this file; do not execute directly.
#
# Requires: yq (mikefarah/yq, Go build, v4+) for --front-matter support, jq (used by callers).
#
# Functions:
#   ai_index_load_config      - load configured docs and Git roots
#   fm_require_tools          - exit 1 with a clear message if yq/jq are missing
#   fm_get   <file> <key>     - print a scalar frontmatter value ("" if absent/null)
#   fm_list  <file> <key>     - print each item of a list frontmatter value, one per line
#   fm_set   <file> <key> <value> - set a scalar frontmatter value in place (body untouched)

ai_index_load_config() {
    local config_file="${HOME}/.config/opencode/ai-index.env"
    if [ ! -r "$config_file" ]; then
        echo "ai-index: config file not readable: ${config_file}" >&2
        return 1
    fi

    # shellcheck source=/dev/null
    source "$config_file"

    : "${AI_INDEX_DOCS_ROOT:?ai-index: AI_INDEX_DOCS_ROOT is not set in ${config_file}}"
    : "${AI_INDEX_GIT_ROOT:?ai-index: AI_INDEX_GIT_ROOT is not set in ${config_file}}"
    AI_INDEX_DOCS_ROOT="${AI_INDEX_DOCS_ROOT%/}"
    AI_INDEX_GIT_ROOT="${AI_INDEX_GIT_ROOT%/}"
}

fm_require_tools() {
    local missing=()
    command -v yq >/dev/null 2>&1 || missing+=("yq")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ai-index: missing required tool(s): ${missing[*]}" >&2
        exit 1
    fi
}

fm_get() {
    local file="$1" key="$2"
    yq --front-matter=extract ".${key} // \"\"" "$file" 2>/dev/null
}

fm_list() {
    local file="$1" key="$2"
    yq --front-matter=extract "(.${key} // [])[]" "$file" 2>/dev/null
}

# Working-tree state shared by the status scripts. Collect once per run, then
# compare these repository-relative paths against each note's declared sources.
FM_DIRTY_PATHS=()
FM_IGNORED_PATHS=()
FM_MATCHED_DIRTY_PATHS=()
FM_MATCHED_IGNORED_PATHS=()
FM_EXTERNAL_SOURCES=()

fm_collect_status() {
    local toplevel="$1" entry status path previous_path status_file
    FM_DIRTY_PATHS=()
    FM_IGNORED_PATHS=()

    status_file="$(mktemp)"
    if ! git -C "$toplevel" status --porcelain=v1 -z --untracked-files=all --ignored=matching > "$status_file"; then
        rm -f -- "$status_file"
        echo "ai-index: unable to read Git working-tree status for ${toplevel}" >&2
        return 1
    fi

    while IFS= read -r -d '' entry; do
        status="${entry:0:2}"
        path="${entry:3}"
        if [ "$status" = "!!" ]; then
            FM_IGNORED_PATHS+=("$path")
        else
            FM_DIRTY_PATHS+=("$path")
        fi

        # With -z, rename/copy records contain the destination followed by
        # the original path as a second NUL-delimited field.
        if [[ "$status" == *R* || "$status" == *C* ]]; then
            if IFS= read -r -d '' previous_path; then
                FM_DIRTY_PATHS+=("$previous_path")
            fi
        fi
    done < "$status_file"
    rm -f -- "$status_file"
}

fm_source_is_external() {
    local source="$1" rest component depth=0
    local -a components=()
    [[ "$source" == /* ]] && return 0

    # Sources are repository-relative paths. Reject paths that lexically escape
    # the checkout; Git cannot establish freshness for external files.
    rest="$source"
    while [[ "$rest" == ./* ]]; do rest="${rest#./}"; done
    IFS='/' read -r -a components <<< "$rest"
    for component in "${components[@]}"; do
        case "$component" in
            ""|.) ;;
            ..)
                depth=$((depth - 1))
                [ "$depth" -lt 0 ] && return 0
                ;;
            *) depth=$((depth + 1)) ;;
        esac
    done
    return 1
}

fm_paths_overlap() {
    local source="$1" path="$2" component
    local -a components=() normalized=()
    while [[ "$source" == ./* ]]; do source="${source#./}"; done
    IFS='/' read -r -a components <<< "$source"
    for component in "${components[@]}"; do
        case "$component" in
            ""|.) ;;
            ..)
                if [ "${#normalized[@]}" -gt 0 ]; then
                    normalized=("${normalized[@]:0:${#normalized[@]}-1}")
                fi
                ;;
            *) normalized+=("$component") ;;
        esac
    done
    local IFS='/'
    source="${normalized[*]}"
    while [[ "$path" == */ ]]; do path="${path%/}"; done

    [ -z "$source" ] && return 0
    [[ "$path" == "$source" || "$path" == "$source/"* || "$source" == "$path/"* ]]
}

fm_check_sources() {
    local source path
    FM_MATCHED_DIRTY_PATHS=()
    FM_MATCHED_IGNORED_PATHS=()
    FM_EXTERNAL_SOURCES=()

    for source in "$@"; do
        if fm_source_is_external "$source"; then
            FM_EXTERNAL_SOURCES+=("$source")
            continue
        fi
        for path in "${FM_DIRTY_PATHS[@]}"; do
            if fm_paths_overlap "$source" "$path"; then
                FM_MATCHED_DIRTY_PATHS+=("$path")
            fi
        done
        for path in "${FM_IGNORED_PATHS[@]}"; do
            if fm_paths_overlap "$source" "$path"; then
                FM_MATCHED_IGNORED_PATHS+=("$path")
            fi
        done
    done
}

fm_format_paths() {
    local formatted="" path quoted
    for path in "$@"; do
        printf -v quoted '%q' "$path"
        formatted+="${formatted:+, }${quoted}"
    done
    printf '%s' "$formatted"
}

fm_join_details() {
    local separator="" detail
    for detail in "$@"; do
        printf '%s%s' "$separator" "$detail"
        separator="; "
    done
}

fm_set() {
    local file="$1" key="$2" value="$3"
    yq --front-matter=process -i ".${key} = \"${value}\"" "$file"
}
