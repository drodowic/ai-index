#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GIT_ROOT="${TMP_DIR}/git"
DOCS_ROOT="${TMP_DIR}/docs"
HOME_ROOT="${TMP_DIR}/home"
FRONTEND="${GIT_ROOT}/frontend"
BACKEND="${GIT_ROOT}/backend"
PORTAL="${GIT_ROOT}/portal"

mkdir -p "$GIT_ROOT" "$DOCS_ROOT/groups" "${DOCS_ROOT}/repos/backend" "${DOCS_ROOT}/repos/portal" "$HOME_ROOT/.config/opencode"
cat > "${HOME_ROOT}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT="${DOCS_ROOT}"
AI_INDEX_GIT_ROOT="${GIT_ROOT}"
EOF

init_repo() {
    local path="$1"
    mkdir -p "$path"
    git init -q -b main "$path"
    git -C "$path" config user.name 'ai-index test'
    git -C "$path" config user.email 'ai-index-test@example.invalid'
    printf 'contract\n' > "${path}/contract.txt"
    git -C "$path" add contract.txt
    git -C "$path" commit -qm base
}

init_repo "$FRONTEND"
init_repo "$BACKEND"
init_repo "$PORTAL"

cat > "${DOCS_ROOT}/groups/product.md" <<'EOF'
---
kind: group
repos:
  - frontend
  - backend
---
# Product
EOF

cat > "${DOCS_ROOT}/repos/backend/contract.md" <<EOF
---
repo: backend
sha: $(git -C "$BACKEND" rev-parse HEAD)
sources:
  - contract.txt
---
# Backend contract
EOF

cat > "${DOCS_ROOT}/repos/portal/contract.md" <<EOF
---
repo: portal
sha: $(git -C "$PORTAL" rev-parse HEAD)
sources:
  - contract.txt
related:
  - frontend
---
# Frontend integration
EOF

status="$(HOME="$HOME_ROOT" "${REPO_ROOT}/skills/ai-index/scripts/repo-status.sh" "$FRONTEND")"
grep -Fq 'repo=frontend - no index notes yet' <<< "$status"
grep -Fq 'related: backend (1 notes), portal (1 notes)' <<< "$status"

echo 'cross-repo discovery checks passed'
