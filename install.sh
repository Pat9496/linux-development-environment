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

readonly CLAUDE_CODE_NPM_PACKAGE="@anthropic-ai/claude-code"
readonly CODEX_NPM_PACKAGE="@openai/codex"
readonly COPILOT_CLI_NPM_PACKAGE="@github/copilot"
readonly AI_CLI_NPM_PACKAGES=(
  "${CLAUDE_CODE_NPM_PACKAGE}"
  "${CODEX_NPM_PACKAGE}"
  "${COPILOT_CLI_NPM_PACKAGE}"
)

readonly CLAUDE_NATIVE_STATE_DIR="${HOME}/.local/share/claude"
readonly CODEX_NATIVE_STATE_DIR="${HOME}/.codex/packages/standalone"
readonly GH_COPILOT_EXTENSION="github/gh-copilot"

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

detect_host_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' apt
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s\n' dnf
  elif command -v zypper >/dev/null 2>&1; then
    printf '%s\n' zypper
  elif command -v pacman >/dev/null 2>&1; then
    printf '%s\n' pacman
  elif command -v apk >/dev/null 2>&1; then
    printf '%s\n' apk
  else
    return 1
  fi
}

host_pkg_query() {
  local mgr="$1" pkg="$2"
  case "${mgr}" in
    apt) dpkg -s "${pkg}" >/dev/null 2>&1 ;;
    dnf|zypper) rpm -q "${pkg}" >/dev/null 2>&1 ;;
    pacman) pacman -Q "${pkg}" >/dev/null 2>&1 ;;
    apk) apk info -e "${pkg}" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

host_pkg_remove() {
  local mgr="$1" pkg="$2"
  case "${mgr}" in
    apt) sudo apt-get remove -y "${pkg}" ;;
    dnf) sudo dnf remove -y "${pkg}" ;;
    zypper) sudo zypper --non-interactive remove "${pkg}" ;;
    pacman) sudo pacman -R --noconfirm "${pkg}" ;;
    apk) sudo apk del "${pkg}" ;;
  esac
}

native_package_candidates_for() {
  local cmd="$1"
  case "${cmd}" in
    claude) printf '%s\n' "claude-code" ;;
    codex) printf '%s\n' "codex" ;;
    copilot) printf '%s\n' "copilot" "gh-copilot" "github-copilot-cli" ;;
  esac
}

npm_global_pkg_installed() {
  local pkg="$1" root
  root="$(npm root -g 2>/dev/null)" || return 1
  [[ -n "${root}" && -d "${root}/${pkg}" ]]
}

npm_global_pkg_uninstall() {
  local pkg="$1"
  if npm uninstall -g "${pkg}"; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi
  sudo npm uninstall -g "${pkg}"
}

brew_cask_candidates_for() {
  local cmd="$1"
  case "${cmd}" in
    claude) printf '%s\n' "claude-code" "claude-code@latest" ;;
    codex) printf '%s\n' "codex" ;;
  esac
}

brew_formula_candidates_for() {
  local cmd="$1"
  case "${cmd}" in
    copilot) printf '%s\n' "copilot-cli" "copilot-cli@prerelease" ;;
  esac
}

brew_cask_installed() {
  local name="$1"
  brew list --cask --versions "${name}" >/dev/null 2>&1
}

brew_formula_installed() {
  local name="$1"
  brew list --versions "${name}" >/dev/null 2>&1
}

# install_host_wrappers (below) writes its own wrapper scripts to these same
# host-bin paths. On a later run of this script, a marker directory existing
# does not by itself prove the file at the host-bin path is still the vendor's
# native binary/symlink: it could already be install.sh's own wrapper from a
# prior run. Every wrapper this script generates execs "distrobox enter", a
# string that never appears in a vendor-shipped binary or install symlink
# target, so grep for it before ever deleting one of these two paths.
wrapper_owns_host_bin() {
  local path="$1"
  grep -q -- 'distrobox enter' "${path}" 2>/dev/null
}

claude_native_install_present() {
  [[ -d "${CLAUDE_NATIVE_STATE_DIR}" ]]
}

remove_claude_native_install() {
  local bin_path="${HOST_BIN_DIR}/claude" ok=0
  if wrapper_owns_host_bin "${bin_path}"; then
    printf 'Warning: %s looks like install.sh'"'"'s own wrapper, not the Claude Code native installer'"'"'s symlink; leaving it in place.\n' "${bin_path}" >&2
  elif ! rm -f -- "${bin_path}"; then
    ok=1
  fi
  rm -rf -- "${CLAUDE_NATIVE_STATE_DIR}" || ok=1
  return "${ok}"
}

codex_native_install_present() {
  [[ -d "${CODEX_NATIVE_STATE_DIR}" ]]
}

remove_codex_native_install() {
  local bin_path="${HOST_BIN_DIR}/codex" ok=0
  if wrapper_owns_host_bin "${bin_path}"; then
    printf 'Warning: %s looks like install.sh'"'"'s own wrapper, not the Codex native installer'"'"'s binary; leaving it in place.\n' "${bin_path}" >&2
  elif ! rm -f -- "${bin_path}"; then
    ok=1
  fi
  rm -rf -- "${CODEX_NATIVE_STATE_DIR}" || ok=1
  return "${ok}"
}

gh_copilot_extension_installed() {
  local output
  output="$(gh extension list 2>/dev/null)" || return 2
  grep -Fq -- "${GH_COPILOT_EXTENSION}" <<< "${output}"
}

cleanup_host_ai_clis() {
  local -a removed=() failed=()
  local i cmd npm_pkg mgr candidate removed_str failed_str gh_status

  if command -v npm >/dev/null 2>&1; then
    for i in "${!AI_CLI_WRAPPER_COMMANDS[@]}"; do
      cmd="${AI_CLI_WRAPPER_COMMANDS[$i]}"
      npm_pkg="${AI_CLI_NPM_PACKAGES[$i]}"
      if npm_global_pkg_installed "${npm_pkg}"; then
        printf 'Found host npm-global install of %s (%s); uninstalling...\n' "${cmd}" "${npm_pkg}"
        if npm_global_pkg_uninstall "${npm_pkg}"; then
          removed+=("${npm_pkg} (npm)")
        else
          failed+=("${npm_pkg} (npm)")
          printf 'Warning: failed to uninstall %s via npm; leaving it in place.\n' "${npm_pkg}" >&2
        fi
      fi
    done
  else
    printf 'npm not found on host; skipping host npm-global check for claude, codex, copilot.\n' >&2
  fi

  if mgr="$(detect_host_pkg_manager)"; then
    for cmd in "${AI_CLI_WRAPPER_COMMANDS[@]}"; do
      while IFS= read -r candidate; do
        [[ -z "${candidate}" ]] && continue
        if host_pkg_query "${mgr}" "${candidate}"; then
          printf 'Found host %s package "%s" for %s; removing...\n' "${mgr}" "${candidate}" "${cmd}"
          if host_pkg_remove "${mgr}" "${candidate}"; then
            removed+=("${candidate} (${mgr})")
          else
            failed+=("${candidate} (${mgr})")
            printf 'Warning: failed to remove %s via %s; leaving it in place.\n' "${candidate}" "${mgr}" >&2
          fi
        fi
      done < <(native_package_candidates_for "${cmd}")
    done
  else
    printf 'No supported host package manager found (looked for apt-get, dnf, zypper, pacman, apk); skipping native-package check.\n' >&2
  fi

  if command -v brew >/dev/null 2>&1; then
    for cmd in "${AI_CLI_WRAPPER_COMMANDS[@]}"; do
      while IFS= read -r candidate; do
        [[ -z "${candidate}" ]] && continue
        if brew_cask_installed "${candidate}"; then
          printf 'Found host Homebrew cask "%s" for %s; uninstalling...\n' "${candidate}" "${cmd}"
          if brew uninstall --cask "${candidate}"; then
            removed+=("${candidate} (brew cask)")
          else
            failed+=("${candidate} (brew cask)")
            printf 'Warning: failed to uninstall Homebrew cask %s; leaving it in place.\n' "${candidate}" >&2
          fi
        fi
      done < <(brew_cask_candidates_for "${cmd}")

      while IFS= read -r candidate; do
        [[ -z "${candidate}" ]] && continue
        if brew_formula_installed "${candidate}"; then
          printf 'Found host Homebrew formula "%s" for %s; uninstalling...\n' "${candidate}" "${cmd}"
          if brew uninstall "${candidate}"; then
            removed+=("${candidate} (brew formula)")
          else
            failed+=("${candidate} (brew formula)")
            printf 'Warning: failed to uninstall Homebrew formula %s; leaving it in place.\n' "${candidate}" >&2
          fi
        fi
      done < <(brew_formula_candidates_for "${cmd}")
    done
  else
    printf 'Homebrew (brew) not found on host; skipping Homebrew check for claude, codex, copilot.\n' >&2
  fi

  if claude_native_install_present; then
    printf 'Found Claude Code native installer state (%s); removing...\n' "${CLAUDE_NATIVE_STATE_DIR}"
    if remove_claude_native_install; then
      removed+=("claude (native installer)")
    else
      failed+=("claude (native installer)")
      printf 'Warning: failed to fully remove the Claude Code native installer; some files may remain.\n' >&2
    fi
  fi

  if codex_native_install_present; then
    printf 'Found Codex native installer state (%s); removing...\n' "${CODEX_NATIVE_STATE_DIR}"
    if remove_codex_native_install; then
      removed+=("codex (native installer)")
    else
      failed+=("codex (native installer)")
      printf 'Warning: failed to fully remove the Codex native installer; some files may remain.\n' >&2
    fi
  fi

  if command -v gh >/dev/null 2>&1; then
    gh_status=0
    gh_copilot_extension_installed || gh_status=$?
    if (( gh_status == 0 )); then
      printf 'Found deprecated gh extension "%s"; removing...\n' "${GH_COPILOT_EXTENSION}"
      if gh extension remove "${GH_COPILOT_EXTENSION}"; then
        removed+=("${GH_COPILOT_EXTENSION} (gh extension)")
      else
        failed+=("${GH_COPILOT_EXTENSION} (gh extension)")
        printf 'Warning: failed to remove gh extension %s; leaving it in place.\n' "${GH_COPILOT_EXTENSION}" >&2
      fi
    elif (( gh_status == 2 )); then
      printf 'Warning: could not query gh extensions (gh extension list failed, possibly not authenticated); skipping gh-copilot extension check.\n' >&2
    fi
  else
    printf 'gh not found on host; skipping deprecated gh-copilot extension check.\n' >&2
  fi

  if (( ${#removed[@]} == 0 && ${#failed[@]} == 0 )); then
    printf 'Host cleanup: no host-side install of claude, codex, or copilot found; nothing to uninstall.\n'
    return 0
  fi

  removed_str="none"
  failed_str="none"
  (( ${#removed[@]} > 0 )) && removed_str="$(IFS=', '; printf '%s' "${removed[*]}")"
  (( ${#failed[@]} > 0 )) && failed_str="$(IFS=', '; printf '%s' "${failed[*]}")"
  printf 'Host cleanup: removed [%s]; failed to remove [%s].\n' "${removed_str}" "${failed_str}"
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

  cleanup_host_ai_clis

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
