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
readonly DEFAULT_HOST_BIN_DIR="${HOME}/.local/bin"
readonly NO_INPUT_MESSAGE="no input available on stdin (closed or exhausted); pass explicit options (see --help) or use -y/--non-interactive to accept the defaults."
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

OPT_NON_INTERACTIVE=0
OPT_HOME_MODE=""
OPT_DEVENV_HOME=""
OPT_COPY_AI_CONFIG=""
OPT_OVERWRITE_EXISTING=0
OPT_HOST_CLEANUP=1
OPT_AUTO_UPDATE=1
OPT_WRAPPER_DIR=""
OPT_DRY_RUN=0

AI_CONFIG_COPY_PLAN=()
WRAPPER_TMP_PATH=""

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

run_or_plan() {
  if (( OPT_DRY_RUN )); then
    printf '[dry-run] would run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

usage() {
  printf 'Usage: install.sh [OPTIONS]\n\n'
  printf 'Creates the "%s" Distrobox development container and installs host-side wrappers\n' "${CONTAINER_NAME}"
  printf 'for claude, codex, and copilot. With no options every choice is asked interactively.\n\n'
  printf 'Options:\n'
  printf '  -y, --non-interactive         Never prompt; use the defaults below or fail\n'
  printf '      --home-mode MODE          existing | separate (default when non-interactive: existing)\n'
  printf '      --devenv-home PATH        Path for the separate home (implies --home-mode separate;\n'
  printf '                                default when non-interactive: %s)\n' "${DEFAULT_DEVENV_HOME}"
  printf '      --copy-ai-config          Copy AI configs into the separate home\n'
  printf '      --no-copy-ai-config       Do not copy them (default when non-interactive)\n'
  printf '      --overwrite-existing-config\n'
  printf '                                Overwrite config paths already present in the DEVenv home\n'
  printf '                                without asking (default when non-interactive: keep them)\n'
  printf '      --no-host-cleanup         Skip removal of host-side claude, codex, and copilot installs\n'
  printf '      --no-auto-update          Generate wrappers that do not npm-update on every invocation\n'
  printf '      --wrapper-dir DIR         Directory for the host wrappers (default: %s)\n' "${DEFAULT_HOST_BIN_DIR}"
  printf '      --dry-run                 Print planned actions, change nothing\n'
  printf '  -h, --help                    Show this help and exit\n\n'
  printf 'Options accept both "--option value" and "--option=value"; "--" ends option parsing.\n'
  printf 'Without -y, a prompt that reads end-of-input (e.g. "curl ... | bash") is an error.\n'
}

resolve_devenv_home() {
  local path="$1"
  path="${path/#\~/${HOME}}"
  while [[ "${path}" == */ && "${path}" != "/" ]]; do
    path="${path%/}"
  done
  if [[ -z "${path}" || "${path}" == "/" || "${path}" == "${HOME}" ]]; then
    die "refusing to use '${path}' as the DEVenv home; choose a dedicated path that is not '/' or your real home."
  fi
  printf '%s\n' "${path}"
}

resolve_wrapper_dir() {
  local path="$1"
  path="${path/#\~/${HOME}}"
  while [[ "${path}" == */ && "${path}" != "/" ]]; do
    path="${path%/}"
  done
  [[ "${path}" == /* ]] || die "--wrapper-dir must be an absolute path (got '${path}')."
  # The path is embedded in double quotes in the generated wrapper scripts.
  if [[ "${path}" == *[\"\$\`\\]* ]]; then
    die "--wrapper-dir must not contain double quotes, dollar signs, backticks, or backslashes (got '${path}')."
  fi
  printf '%s\n' "${path}"
}

parse_args() {
  local opt value has_value
  while (( $# > 0 )); do
    opt="$1"
    value=""
    has_value=0
    if [[ "${opt}" == --*=* ]]; then
      value="${opt#*=}"
      opt="${opt%%=*}"
      has_value=1
    fi

    case "${opt}" in
      --home-mode|--devenv-home|--wrapper-dir)
        if (( ! has_value )); then
          (( $# >= 2 )) && [[ "$2" != -* ]] || die "option '${opt}' requires a value."
          value="$2"
          shift
        fi
        [[ -n "${value}" ]] || die "option '${opt}' requires a non-empty value."
        ;;
      -h|--help|-y|--non-interactive|--copy-ai-config|--no-copy-ai-config|--overwrite-existing-config|--no-host-cleanup|--no-auto-update|--dry-run|--)
        (( ! has_value )) || die "option '${opt}' does not take a value."
        ;;
    esac

    case "${opt}" in
      -h|--help) usage; exit 0 ;;
      -y|--non-interactive) OPT_NON_INTERACTIVE=1 ;;
      --home-mode)
        case "${value}" in
          existing|separate) OPT_HOME_MODE="${value}" ;;
          *) die "invalid --home-mode '${value}'; expected 'existing' or 'separate'." ;;
        esac
        ;;
      --devenv-home) OPT_DEVENV_HOME="${value}" ;;
      --copy-ai-config)
        [[ "${OPT_COPY_AI_CONFIG}" != "no" ]] || die "--copy-ai-config and --no-copy-ai-config cannot be combined."
        OPT_COPY_AI_CONFIG="yes"
        ;;
      --no-copy-ai-config)
        [[ "${OPT_COPY_AI_CONFIG}" != "yes" ]] || die "--copy-ai-config and --no-copy-ai-config cannot be combined."
        OPT_COPY_AI_CONFIG="no"
        ;;
      --overwrite-existing-config) OPT_OVERWRITE_EXISTING=1 ;;
      --no-host-cleanup) OPT_HOST_CLEANUP=0 ;;
      --no-auto-update) OPT_AUTO_UPDATE=0 ;;
      --wrapper-dir) OPT_WRAPPER_DIR="${value}" ;;
      --dry-run) OPT_DRY_RUN=1 ;;
      --) shift; break ;;
      -*) die "unknown option '${opt}'. Run with --help for usage." ;;
      *) die "unexpected argument '${opt}'. Run with --help for usage." ;;
    esac
    shift
  done
  (( $# == 0 )) || die "unexpected argument '$1'. Run with --help for usage."

  if [[ -n "${OPT_DEVENV_HOME}" ]]; then
    [[ "${OPT_HOME_MODE:-separate}" == "separate" ]] || die "--devenv-home cannot be combined with --home-mode existing."
    OPT_HOME_MODE="separate"
    OPT_DEVENV_HOME="$(resolve_devenv_home "${OPT_DEVENV_HOME}")"
  fi

  if [[ "${OPT_COPY_AI_CONFIG}" == "yes" ]]; then
    if [[ "${OPT_HOME_MODE}" == "existing" ]] || { (( OPT_NON_INTERACTIVE )) && [[ -z "${OPT_HOME_MODE}" ]]; }; then
      die "--copy-ai-config only applies to a separate home; pass --home-mode separate or --devenv-home PATH (with --non-interactive the home mode defaults to 'existing')."
    fi
  fi

  if [[ -n "${OPT_WRAPPER_DIR}" ]]; then
    OPT_WRAPPER_DIR="$(resolve_wrapper_dir "${OPT_WRAPPER_DIR}")"
  fi
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
    apt) run_or_plan sudo apt-get remove -y "${pkg}" ;;
    dnf) run_or_plan sudo dnf remove -y "${pkg}" ;;
    zypper) run_or_plan sudo zypper --non-interactive remove "${pkg}" ;;
    pacman) run_or_plan sudo pacman -R --noconfirm "${pkg}" ;;
    apk) run_or_plan sudo apk del "${pkg}" ;;
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
  if run_or_plan npm uninstall -g "${pkg}"; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi
  run_or_plan sudo npm uninstall -g "${pkg}"
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
  # The vendor installer always links into the default dir, not --wrapper-dir.
  local bin_path="${DEFAULT_HOST_BIN_DIR}/claude" ok=0
  if wrapper_owns_host_bin "${bin_path}"; then
    printf 'Warning: %s looks like install.sh'"'"'s own wrapper, not the Claude Code native installer'"'"'s symlink; leaving it in place.\n' "${bin_path}" >&2
  elif ! run_or_plan rm -f -- "${bin_path}"; then
    ok=1
  fi
  run_or_plan rm -rf -- "${CLAUDE_NATIVE_STATE_DIR}" || ok=1
  return "${ok}"
}

codex_native_install_present() {
  [[ -d "${CODEX_NATIVE_STATE_DIR}" ]]
}

remove_codex_native_install() {
  # The vendor installer always installs into the default dir, not --wrapper-dir.
  local bin_path="${DEFAULT_HOST_BIN_DIR}/codex" ok=0
  if wrapper_owns_host_bin "${bin_path}"; then
    printf 'Warning: %s looks like install.sh'"'"'s own wrapper, not the Codex native installer'"'"'s binary; leaving it in place.\n' "${bin_path}" >&2
  elif ! run_or_plan rm -f -- "${bin_path}"; then
    ok=1
  fi
  run_or_plan rm -rf -- "${CODEX_NATIVE_STATE_DIR}" || ok=1
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
          if run_or_plan brew uninstall --cask "${candidate}"; then
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
          if run_or_plan brew uninstall "${candidate}"; then
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
      if run_or_plan gh extension remove "${GH_COPILOT_EXTENSION}"; then
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
  if (( OPT_DRY_RUN )); then
    printf 'Host cleanup (dry-run): would remove [%s].\n' "${removed_str}"
    return 0
  fi
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

read_reply() {
  local -n reply_ref="$1"
  read -r -p "$2" reply_ref || [[ -n "${reply_ref}" ]] || die "${NO_INPUT_MESSAGE}"
}

prompt_yes_no() {
  local prompt="$1" default="$2" reply suffix
  if (( OPT_NON_INTERACTIVE )); then
    [[ "${default}" == "y" ]] && return 0
    return 1
  fi
  suffix="y/N"
  [[ "${default}" == "y" ]] && suffix="Y/n"
  while true; do
    read_reply reply "${prompt} [${suffix}]: "
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
  if (( OPT_NON_INTERACTIVE )); then
    printf 'existing\n'
    return 0
  fi
  printf 'Choose the home directory for the "%s" container:\n' "${name}" >&2
  printf '  1) Use the existing user home\n' >&2
  printf '  2) Create a new, separate DEVenv home\n' >&2
  while true; do
    read_reply choice "Selection [1]: "
    choice="${choice:-1}"
    case "${choice}" in
      1) printf 'existing\n'; return 0 ;;
      2) printf 'separate\n'; return 0 ;;
      *) printf 'Please enter 1 or 2.\n' >&2 ;;
    esac
  done
}

prompt_devenv_home_path() {
  local path="${DEFAULT_DEVENV_HOME}"
  if (( ! OPT_NON_INTERACTIVE )); then
    read_reply path "Path for the new DEVenv home [${DEFAULT_DEVENV_HOME}]: "
    path="${path:-${DEFAULT_DEVENV_HOME}}"
  fi
  resolve_devenv_home "${path}"
}

plan_ai_config_copies() {
  local dest_home="$1" src source_path dest_path
  AI_CONFIG_COPY_PLAN=()
  for src in "${AI_CONFIG_PATHS[@]}"; do
    source_path="${HOME}/${src}"
    dest_path="${dest_home}/${src}"
    [[ -e "${source_path}" ]] || continue
    if [[ -e "${dest_path}" ]]; then
      if (( ! OPT_OVERWRITE_EXISTING )) && ! prompt_yes_no "'${dest_path}' already exists. Overwrite it from '${source_path}'?" "n"; then
        printf 'Skipping %s (already present in DEVenv home).\n' "${src}"
        continue
      fi
    fi
    AI_CONFIG_COPY_PLAN+=("${src}")
  done
}

copy_ai_configs() {
  local dest_home="$1" src source_path dest_path
  for src in "${AI_CONFIG_COPY_PLAN[@]}"; do
    source_path="${HOME}/${src}"
    dest_path="${dest_home}/${src}"
    if [[ -e "${dest_path}" ]]; then
      run_or_plan rm -rf -- "${dest_path}"
    fi
    run_or_plan mkdir -p -- "$(dirname -- "${dest_path}")"
    run_or_plan cp -a -- "${source_path}" "${dest_path}"
    (( OPT_DRY_RUN )) || printf 'Copied %s\n' "${src}"
  done
}

create_container() {
  local name="$1" image="$2" home_mode="$3" devenv_home="$4"
  local -a create_args=(--name "${name}" --image "${image}" --yes)
  if [[ "${home_mode}" == "separate" ]]; then
    create_args+=(--home "${devenv_home}")
  fi
  printf 'Creating distrobox container "%s" from image "%s"...\n' "${name}" "${image}"
  run_or_plan distrobox create "${create_args[@]}"
}

# A dry run never creates the container, so there is nothing to enter and
# the bootstrap script cannot run (not even in its own --dry-run mode); the
# command a real run would execute is printed instead.
run_bootstrap_in_container() {
  local name="$1"
  printf 'Installing the development toolchain inside "%s"...\n' "${name}"
  run_or_plan distrobox enter --name "${name}" -- bash "${BOOTSTRAP_SCRIPT}"
}

install_host_wrappers() {
  local name="$1" i cmd npm_pkg wrapper_path update_block="" update_state="on"

  if (( OPT_DRY_RUN )); then
    (( OPT_AUTO_UPDATE )) || update_state="off"
    for cmd in "${AI_CLI_WRAPPER_COMMANDS[@]}"; do
      printf '[dry-run] would write host wrapper: %s/%s (auto-update: %s)\n' "${HOST_BIN_DIR}" "${cmd}" "${update_state}"
    done
    return 0
  fi

  mkdir -p -- "${HOST_BIN_DIR}"

  trap '[[ -z "${WRAPPER_TMP_PATH}" ]] || rm -f -- "${WRAPPER_TMP_PATH}"' EXIT

  for i in "${!AI_CLI_WRAPPER_COMMANDS[@]}"; do
    cmd="${AI_CLI_WRAPPER_COMMANDS[$i]}"
    npm_pkg="${AI_CLI_NPM_PACKAGES[$i]}"
    wrapper_path="${HOST_BIN_DIR}/${cmd}"
    WRAPPER_TMP_PATH="$(mktemp -- "${HOST_BIN_DIR}/.${cmd}.XXXXXX")"
    update_block=""
    if (( OPT_AUTO_UPDATE )); then
      IFS= read -r -d '' update_block <<UPDATE_EOF || true
  if ! distrobox enter "${name}" -- sudo -n npm install -g ${npm_pkg}@latest; then
    printf 'Warning: update check for ${cmd} failed (may need interactive sudo inside the container); continuing with the currently installed version.\n' >&2
  fi
UPDATE_EOF
    fi
    cat > "${WRAPPER_TMP_PATH}" <<WRAPPER_EOF
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
${update_block}  exec distrobox enter "${name}" -- ${cmd} "\$@"
fi
WRAPPER_EOF
    chmod +x -- "${WRAPPER_TMP_PATH}"
    mv -f -- "${WRAPPER_TMP_PATH}" "${wrapper_path}"
    WRAPPER_TMP_PATH=""
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
  parse_args "$@"

  HOST_BIN_DIR="${OPT_WRAPPER_DIR:-${DEFAULT_HOST_BIN_DIR}}"
  readonly HOST_BIN_DIR

  if (( OPT_DRY_RUN )); then
    printf '[dry-run] No changes will be made; planned actions are printed instead.\n'
  fi

  check_host_prerequisites

  # Every interactive prompt (home mode, DEVenv home path, AI-config copy, and
  # per-path overwrite decisions) runs before the first destructive action, so
  # a prompt that hits end-of-input aborts while the host and the existing
  # container are still untouched. The filesystem work for those decisions
  # happens after the container removal below.
  local home_mode devenv_home="" copy_ai_config="${OPT_COPY_AI_CONFIG}"
  home_mode="${OPT_HOME_MODE:-$(prompt_home_mode "${CONTAINER_NAME}")}"

  if [[ "${home_mode}" == "separate" ]]; then
    devenv_home="${OPT_DEVENV_HOME:-$(prompt_devenv_home_path)}"
    if [[ -z "${copy_ai_config}" ]]; then
      copy_ai_config="no"
      if prompt_yes_no "Copy existing Claude Code, Codex, and Copilot CLI config into the new DEVenv home?" "n"; then
        copy_ai_config="yes"
      fi
    fi
    if [[ "${copy_ai_config}" == "yes" ]]; then
      plan_ai_config_copies "${devenv_home}"
    fi
  elif [[ "${copy_ai_config}" == "yes" ]]; then
    printf 'Warning: --copy-ai-config ignored; AI config is only copied into a separate DEVenv home.\n' >&2
  fi

  if (( OPT_HOST_CLEANUP )); then
    cleanup_host_ai_clis
  else
    printf 'Skipping host cleanup (--no-host-cleanup).\n'
  fi

  # Always recreate rather than reuse: a reused container can silently carry
  # over a half-applied prior install or drifted packages, so install.sh
  # treats every run as a from-scratch (re-)install instead of an incremental
  # update. Only the container itself is destroyed here; the home-mode choice
  # and the AI-config copy step below are unrelated and still run every time.
  if container_exists "${CONTAINER_NAME}"; then
    printf 'Warning: container "%s" already exists; it and everything inside it will be destroyed and recreated from scratch.\n' "${CONTAINER_NAME}" >&2
    run_or_plan distrobox rm -f "${CONTAINER_NAME}"
  fi

  if [[ "${home_mode}" == "separate" ]]; then
    run_or_plan mkdir -p -- "${devenv_home}"
    if [[ "${copy_ai_config}" == "yes" ]]; then
      copy_ai_configs "${devenv_home}"
    fi
  fi

  create_container "${CONTAINER_NAME}" "${BASE_IMAGE}" "${home_mode}" "${devenv_home}"

  run_bootstrap_in_container "${CONTAINER_NAME}"

  install_host_wrappers "${CONTAINER_NAME}"
  check_host_bin_on_path

  if (( OPT_DRY_RUN )); then
    printf '\n[dry-run] Done; nothing was changed.\n'
    return 0
  fi

  printf '\nDEVenv container "%s" is ready. Enter it with: distrobox enter %s\n' "${CONTAINER_NAME}" "${CONTAINER_NAME}"
  printf 'claude, codex, and copilot are also available directly from the host terminal via %s.\n' "${HOST_BIN_DIR}"
}

main "$@"
