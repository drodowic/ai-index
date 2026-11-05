#!/usr/bin/env bash
# note-touch.sh - mark a note freshly verified: sets sha to the named repo's current HEAD
# and verified to today's date. Leaves the rest of the note (frontmatter and body) untouched.
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

head_sha="$(git -C "$toplevel" rev-parse HEAD)"
today="$(date +%F)"

fm_set "$note" sha "$head_sha"
fm_set "$note" verified "$today"

echo "ai-index: ${note} - sha=${head_sha:0:7} verified=${today}"
