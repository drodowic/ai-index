#!/usr/bin/env bash
# Install or update the ai-index OpenCode skill and plugin from this checkout.

set -euo pipefail

log() {
  printf '[ai-index installer] %s\n' "$*"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:?HOME must be set}/.config}/opencode}"

log "Starting install/update from ${REPO_ROOT}"
log "OpenCode config directory: ${CONFIG_DIR}"

log "Checking repository contents..."
if [[ ! -d "${REPO_ROOT}/skills/ai-index" || ! -d "${REPO_ROOT}/plugins/ai-index" ]]; then
  echo "Error: expected skills/ai-index and plugins/ai-index in ${REPO_ROOT}" >&2
  exit 1
fi
log "Repository contents found."

mkdir -p "${CONFIG_DIR}"
CONFIG_DIR="$(cd "${CONFIG_DIR}" && pwd -P)"

install_component() {
  local name="$1"
  local source="$2"
  local destination="$3"
  local action="Installing"
  local completed="installed"

  if [[ -d "${destination}" ]]; then
    action="Updating"
    completed="updated"
  fi

  log "${action} ${name} from ${source} to ${destination}..."
  mkdir -p "${destination}"
  cp -a "${source}/." "${destination}/"
  log "Done: ${name} ${completed} at ${destination}."
}

install_component "skill" "${REPO_ROOT}/skills/ai-index" "${CONFIG_DIR}/skills/ai-index"
install_component "plugin" "${REPO_ROOT}/plugins/ai-index" "${CONFIG_DIR}/plugins/ai-index"

PLUGIN_DIR="${CONFIG_DIR}/plugins/ai-index"
REGISTERED=false
REGISTERED_CONFIG=""
REGISTERED_PATH=""
PLUGIN_PATHS=(
  "${PLUGIN_DIR}"
  "${PLUGIN_DIR}/"
  "./plugins/ai-index"
  "plugins/ai-index"
)
for config in "${CONFIG_DIR}/opencode.json" "${CONFIG_DIR}/opencode.jsonc"; do
  if [[ -f "${config}" ]]; then
    log "Checking plugin registration in ${config}..."
    for plugin_path in "${PLUGIN_PATHS[@]}"; do
      if grep -Fq -- "${plugin_path}" "${config}"; then
        REGISTERED=true
        REGISTERED_CONFIG="${config}"
        REGISTERED_PATH="${plugin_path}"
        break
      fi
    done
    [[ "${REGISTERED}" == true ]] && break
  else
    log "No config file at ${config}; skipping."
  fi
done

if [[ "${REGISTERED}" == true ]]; then
  log "Plugin registration already exists in ${REGISTERED_CONFIG} (${REGISTERED_PATH}); no registration snippet needed."
else
  log "Plugin registration not found; add this entry to your existing plugins array:"
  cat <<EOF
{
  "plugins": [
    { "package": "${PLUGIN_DIR}" }
  ]
}
EOF
fi

log "OpenCode config was not modified. Existing destination files were overwritten; additional files were left untouched."
log "Install/update complete."
