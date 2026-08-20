#!/usr/bin/env bash
set -euo pipefail

# Design choice: nothing installed inside the DEVenv container is ever
# exported to the host (no `distrobox-export`, no host-side .desktop entries
# or exported binaries for arbitrary container packages). The only host-side
# artifacts this script creates are the three thin wrapper scripts below for
# the AI CLIs, which simply shell out to `distrobox enter` at run time.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly SCRIPT_DIR
readonly BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/distrobox-bootstrap.sh"

readonly CONTAINER_NAME="DEVenv"
readonly BASE_IMAGE="registry.fedoraproject.org/fedora-toolbox:latest"
readonly DEFAULT_DEVENV_HOME="${HOME}/DEVenv-home"
readonly HOST_BIN_DIR="${HOME}/.local/bin"
readonly AI_CLI_WRAPPER_COMMANDS=(
  "claude"
  "codex"
  "copilot"
)

readonly AI_CONFIG_PATHS=(
  ".claude"
  ".codex"
  ".copilot"
  ".config/github-copilot"
)

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on host. Install it before running this script."
}

check_host_prerequisites() {
  require_cmd distrobox
  if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    die "neither podman nor docker found on host. Distrobox needs one of them."
  fi
  [[ -f "${BOOTSTRAP_SCRIPT}" ]] || die "bootstrap script not found at ${BOOTSTRAP_SCRIPT}"
}

container_exists() {
  local name="$1"
  distrobox list --no-color 2>/dev/null | awk -F'|' -v name="${name}" '
    NR > 1 {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      if ($2 == name) { found = 1 }
    }
    END { exit !found }
  '
}

prompt_yes_no() {
  local prompt="$1" default="$2" reply suffix
  suffix="y/N"
  [[ "${default}" == "y" ]] && suffix="Y/n"
  while true; do
    read -r -p "${prompt} [${suffix}]: " reply
    reply="${reply:-${default}}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf 'Please answer y or n.\n' >&2 ;;
    esac
  done
}

prompt_home_mode() {
  local name="$1" choice
  printf 'Choose the home directory for the "%s" container:\n' "${name}" >&2
  printf '  1) Use the existing user home\n' >&2
  printf '  2) Create a new, separate DEVenv home\n' >&2
  while true; do
    read -r -p "Selection [1]: " choice
    choice="${choice:-1}"
    case "${choice}" in
      1) printf 'existing\n'; return 0 ;;
      2) printf 'separate\n'; return 0 ;;
      *) printf 'Please enter 1 or 2.\n' >&2 ;;
    esac
  done
}

prompt_devenv_home_path() {
  local path
  read -r -p "Path for the new DEVenv home [${DEFAULT_DEVENV_HOME}]: " path
  path="${path:-${DEFAULT_DEVENV_HOME}}"
  path="${path/#\~/${HOME}}"
  if [[ -z "${path}" || "${path}" == "/" || "${path}" == "${HOME}" ]]; then
    die "refusing to use '${path}' as the DEVenv home; choose a dedicated path that is not '/' or your real home."
  fi
  printf '%s\n' "${path}"
}

copy_ai_configs() {
  local dest_home="$1" src source_path dest_path
  for src in "${AI_CONFIG_PATHS[@]}"; do
    source_path="${HOME}/${src}"
    dest_path="${dest_home}/${src}"
    [[ -e "${source_path}" ]] || continue
    if [[ -e "${dest_path}" ]]; then
      if ! prompt_yes_no "'${dest_path}' already exists. Overwrite it from '${source_path}'?" "n"; then
        printf 'Skipping %s (already present in DEVenv home).\n' "${src}"
        continue
      fi
      rm -rf -- "${dest_path}"
    fi
    mkdir -p -- "$(dirname -- "${dest_path}")"
    cp -a -- "${source_path}" "${dest_path}"
    printf 'Copied %s\n' "${src}"
  done
}

create_container() {
  local name="$1" image="$2" home_mode="$3" devenv_home="$4"
  local -a create_args=(--name "${name}" --image "${image}" --yes)
  if [[ "${home_mode}" == "separate" ]]; then
    create_args+=(--home "${devenv_home}")
  fi
  printf 'Creating distrobox container "%s" from image "%s"...\n' "${name}" "${image}"
  distrobox create "${create_args[@]}"
}

run_bootstrap_in_container() {
  local name="$1"
  printf 'Installing the development toolchain inside "%s"...\n' "${name}"
  distrobox enter --name "${name}" -- bash "${BOOTSTRAP_SCRIPT}"
}

install_host_wrappers() {
  local name="$1" cmd wrapper_path tmp_path=""
  mkdir -p -- "${HOST_BIN_DIR}"

  trap '[[ -n "${tmp_path}" ]] && rm -f -- "${tmp_path}"' EXIT

  for cmd in "${AI_CLI_WRAPPER_COMMANDS[@]}"; do
    wrapper_path="${HOST_BIN_DIR}/${cmd}"
    tmp_path="$(mktemp -- "${HOST_BIN_DIR}/.${cmd}.XXXXXX")"
    cat > "${tmp_path}" <<WRAPPER_EOF
#!/usr/bin/env bash
# Distrobox shares the host filesystem so deeply that generic container
# markers like /run/.containerenv and /.dockerenv don't reliably show up
# inside it; distrobox's own docs recommend checking \$CONTAINER_ID instead.
# Compare against this wrapper's own container name, since \$CONTAINER_ID is
# also set (to some other container's name) when running inside a different
# distrobox container that happens to share this same ~/.local/bin wrapper.
if [[ "\${CONTAINER_ID:-}" == "${name}" ]]; then
  IFS=':' read -r -a path_parts <<< "\${PATH}"
  filtered_path=""
  for path_part in "\${path_parts[@]}"; do
    if [[ "\${path_part}" != "${HOST_BIN_DIR}" ]]; then
      filtered_path="\${filtered_path:+\${filtered_path}:}\${path_part}"
    fi
  done
  PATH="\${filtered_path}" exec "${cmd}" "\$@"
else
  exec distrobox enter "${name}" -- ${cmd} "\$@"
fi
WRAPPER_EOF
    chmod +x -- "${tmp_path}"
    mv -f -- "${tmp_path}" "${wrapper_path}"
    tmp_path=""
    printf 'Installed host wrapper: %s\n' "${wrapper_path}"
  done

  trap - EXIT
}

check_host_bin_on_path() {
  case ":${PATH}:" in
    *":${HOST_BIN_DIR}:"*) ;;
    *)
      printf '\nNote: %s is not on your PATH.\n' "${HOST_BIN_DIR}" >&2
      # $PATH here is literal text for the user's ~/.bashrc, not meant to expand in this script.
      # shellcheck disable=SC2016
      printf 'Add it to your shell startup file (e.g. export PATH="%s:$PATH" in ~/.bashrc) so the claude, codex, and copilot wrappers are found.\n' "${HOST_BIN_DIR}" >&2
      ;;
  esac
}

main() {
  check_host_prerequisites

  # Always recreate rather than reuse: a reused container can silently carry
  # over a half-applied prior install or drifted packages, so install.sh
  # treats every run as a from-scratch (re-)install instead of an incremental
  # update. Only the container itself is destroyed here; the home-mode choice
  # and the AI-config copy step below are unrelated and still run every time.
  if container_exists "${CONTAINER_NAME}"; then
    printf 'Warning: container "%s" already exists; it and everything inside it will be destroyed and recreated from scratch.\n' "${CONTAINER_NAME}" >&2
    distrobox rm -f "${CONTAINER_NAME}"
  fi

  local home_mode devenv_home=""
  home_mode="$(prompt_home_mode "${CONTAINER_NAME}")"

  if [[ "${home_mode}" == "separate" ]]; then
    devenv_home="$(prompt_devenv_home_path)"
    mkdir -p -- "${devenv_home}"
    if prompt_yes_no "Copy existing Claude Code, Codex, and Copilot CLI config into the new DEVenv home?" "n"; then
      copy_ai_configs "${devenv_home}"
    fi
  fi

  create_container "${CONTAINER_NAME}" "${BASE_IMAGE}" "${home_mode}" "${devenv_home}"

  run_bootstrap_in_container "${CONTAINER_NAME}"

  install_host_wrappers "${CONTAINER_NAME}"
  check_host_bin_on_path

  printf '\nDEVenv container "%s" is ready. Enter it with: distrobox enter %s\n' "${CONTAINER_NAME}" "${CONTAINER_NAME}"
  printf 'claude, codex, and copilot are also available directly from the host terminal via %s.\n' "${HOST_BIN_DIR}"
}

main "$@"
