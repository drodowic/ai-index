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

fm_set() {
    local file="$1" key="$2" value="$3"
    yq --front-matter=process -i ".${key} = \"${value}\"" "$file"
}
