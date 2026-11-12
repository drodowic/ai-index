#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

CONFIG_DIR="${TMP_DIR}/opencode config & test"
OPENCODE_CONFIG_DIR="${CONFIG_DIR}" "${REPO_ROOT}/install.sh" >/dev/null

SKILL_DIR="${CONFIG_DIR}/skills/ai-index"
SKILL_FILE="${SKILL_DIR}/SKILL.md"
printf -v expected_script_path '%q' "${SKILL_DIR}/scripts/repo-status.sh"

if ! grep -Fq -- "${expected_script_path}" "${SKILL_FILE}"; then
  echo "Expected direct script path in installed skill: ${expected_script_path}" >&2
  exit 1
fi

if grep -Fq -- '__AI_INDEX_SKILL_DIR__' "${SKILL_FILE}"; then
  echo "Skill location placeholder was not replaced" >&2
  exit 1
fi

if grep -Fq -- '$AI_INDEX_SKILL_DIR' "${SKILL_FILE}"; then
  echo "Installed skill still depends on a shell variable for script paths" >&2
  exit 1
fi

echo "Installer writes direct absolute script paths into SKILL.md."
