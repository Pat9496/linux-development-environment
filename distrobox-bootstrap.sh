#!/usr/bin/env bash
set -euo pipefail

# AI CLI npm packages — edit here if an upstream package name changes.
readonly CLAUDE_CODE_NPM_PACKAGE="@anthropic-ai/claude-code"
readonly CODEX_NPM_PACKAGE="@openai/codex"
readonly COPILOT_CLI_NPM_PACKAGE="@github/copilot"
readonly AI_CLI_NPM_PACKAGES=(
  "${CLAUDE_CODE_NPM_PACKAGE}"
  "${CODEX_NPM_PACKAGE}"
  "${COPILOT_CLI_NPM_PACKAGE}"
)

# mise (jdx.dev) has no official package in the apt/dnf/zypper/apk repos this
# script targets (Arch's official "extra" repo does carry it, but it's still
# installed the same way here for consistency across package managers), so
# it's installed from its own official script rather than through
# packages_for()/install_pkg(), same as the AI CLIs above.
readonly MISE_INSTALL_URL="https://mise.run"
readonly MISE_INSTALL_PATH="${HOME}/.local/bin/mise"

OPT_SKIP_AI_CLIS=0
OPT_PKG_MANAGER=""
OPT_DRY_RUN=0

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
  printf 'Usage: distrobox-bootstrap.sh [OPTIONS]\n\n'
  printf 'Installs the development toolchain inside the container it runs in. Normally\n'
  printf 'invoked by install.sh via "distrobox enter", not run directly on the host.\n\n'
  printf 'Options:\n'
  printf '      --skip-ai-clis            Install the system toolchain only, skip the npm AI CLIs\n'
  printf '      --pkg-manager MGR         Use MGR instead of detecting it (apt|dnf|zypper|pacman|apk)\n'
  printf '      --dry-run                 Print planned actions, change nothing\n'
  printf '  -h, --help                    Show this help and exit\n\n'
  printf 'Options accept both "--option value" and "--option=value"; "--" ends option parsing.\n'
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
      --pkg-manager)
        if (( ! has_value )); then
          if (( $# < 2 )) || [[ "$2" == -* ]]; then
            printf 'Error: option %s requires a value.\n' "${opt}" >&2
            exit 1
          fi
          value="$2"
          shift
        fi
        case "${value}" in
          apt|dnf|zypper|pacman|apk) OPT_PKG_MANAGER="${value}" ;;
          *)
            printf 'Error: invalid --pkg-manager '"'"'%s'"'"'; expected one of apt, dnf, zypper, pacman, apk.\n' "${value}" >&2
            exit 1
            ;;
        esac
        ;;
      -h|--help|--skip-ai-clis|--dry-run|--)
        if (( has_value )); then
          printf 'Error: option %s does not take a value.\n' "${opt}" >&2
          exit 1
        fi
        case "${opt}" in
          -h|--help) usage; exit 0 ;;
          --skip-ai-clis) OPT_SKIP_AI_CLIS=1 ;;
          --dry-run) OPT_DRY_RUN=1 ;;
          --) shift; break ;;
        esac
        ;;
      -*)
        printf 'Error: unknown option '"'"'%s'"'"'. Run with --help for usage.\n' "${opt}" >&2
        exit 1
        ;;
      *)
        printf 'Error: unexpected argument '"'"'%s'"'"'. Run with --help for usage.\n' "${opt}" >&2
        exit 1
        ;;
    esac
    shift
  done
  if (( $# > 0 )); then
    printf 'Error: unexpected argument '"'"'%s'"'"'. Run with --help for usage.\n' "$1" >&2
    exit 1
  fi
}

detect_pkg_manager() {
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

refresh_index() {
  local mgr="$1"
  case "${mgr}" in
    apt) run_or_plan sudo apt-get update -y ;;
    pacman) run_or_plan sudo pacman -Sy --noconfirm ;;
    apk) run_or_plan sudo apk update ;;
    dnf|zypper) ;;
  esac
}

install_pkg() {
  local mgr="$1" pkg="$2"
  case "${mgr}" in
    apt) run_or_plan sudo apt-get install -y "${pkg}" ;;
    dnf) run_or_plan sudo dnf install -y "${pkg}" ;;
    zypper) run_or_plan sudo zypper --non-interactive install "${pkg}" ;;
    pacman) run_or_plan sudo pacman -S --noconfirm "${pkg}" ;;
    apk) run_or_plan sudo apk add "${pkg}" ;;
  esac
}

packages_for() {
  local mgr="$1"
  case "${mgr}" in
    apt)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-venv python3-dev \
        build-essential curl jq ripgrep fzf tmux direnv shellcheck pandoc libreoffice libreoffice-writer \
        graphviz gh openssh-client gnupg unzip
      ;;
    dnf)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-devel \
        gcc gcc-c++ make curl jq ripgrep fzf tmux direnv ShellCheck pandoc libreoffice libreoffice-writer \
        graphviz gh openssh-clients gnupg2 unzip
      ;;
    zypper)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-devel \
        gcc gcc-c++ make curl jq ripgrep fzf tmux direnv ShellCheck pandoc libreoffice libreoffice-writer \
        graphviz gh openssh-clients gnupg2 unzip
      ;;
    pacman)
      printf '%s\n' git git-lfs nodejs npm python python-pip \
        base-devel curl jq ripgrep fzf tmux direnv shellcheck pandoc libreoffice-fresh graphviz github-cli \
        openssh gnupg unzip
      ;;
    apk)
      printf '%s\n' git git-lfs nodejs npm python3 py3-pip python3-dev \
        build-base curl jq ripgrep fzf tmux direnv shellcheck pandoc libreoffice graphviz github-cli \
        openssh-client gnupg unzip
      ;;
  esac
}

install_mise() {
  if (( OPT_DRY_RUN )); then
    printf '[dry-run] would download %s and run it with sh\n' "${MISE_INSTALL_URL}"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf 'Error: curl not found inside the container; cannot fetch the mise installer.\n' >&2
    return 1
  fi

  local mise_installer
  mise_installer="$(mktemp)"
  # A RETURN trap outlives the function that set it; it must remove itself so
  # it cannot fire on later returns, where the local is gone (unbound under set -u).
  trap 'rm -f -- "${mise_installer}"; trap - RETURN' RETURN

  if ! curl -fsSL "${MISE_INSTALL_URL}" -o "${mise_installer}"; then
    printf 'Warning: could not download the mise installer from %s.\n' "${MISE_INSTALL_URL}" >&2
    return 1
  fi

  if ! sh "${mise_installer}"; then
    return 1
  fi
}

print_activation_notes() {
  if [[ -x "${MISE_INSTALL_PATH}" ]]; then
    printf '\nNote: mise needs a shell hook to activate automatically.\n' >&2
    # $(...) here is literal text for the user's shell rc file, not meant to expand in this script.
    # shellcheck disable=SC2016
    printf 'Add this to your shell startup file inside the container (e.g. ~/.bashrc): eval "$(%s activate bash)"\n' "${MISE_INSTALL_PATH}" >&2
  fi

  if command -v direnv >/dev/null 2>&1; then
    printf '\nNote: direnv needs a shell hook to activate automatically.\n' >&2
    # shellcheck disable=SC2016
    printf 'Add this to your shell startup file inside the container (e.g. ~/.bashrc): eval "$(direnv hook bash)"\n' >&2
  fi
}

main() {
  parse_args "$@"

  if ! command -v sudo >/dev/null 2>&1; then
    printf 'Error: sudo not found inside the container; cannot install packages.\n' >&2
    exit 1
  fi

  local pkg_manager pkg_manager_command
  if [[ -n "${OPT_PKG_MANAGER}" ]]; then
    pkg_manager="${OPT_PKG_MANAGER}"
    pkg_manager_command="${pkg_manager}"
    if [[ "${pkg_manager}" == "apt" ]]; then
      pkg_manager_command="apt-get"
    fi
    if ! command -v "${pkg_manager_command}" >/dev/null 2>&1; then
      printf 'Error: %s not found inside the container; cannot use --pkg-manager %s.\n' "${pkg_manager_command}" "${pkg_manager}" >&2
      exit 1
    fi
    printf 'Using package manager from --pkg-manager: %s\n' "${pkg_manager}"
  else
    if ! pkg_manager="$(detect_pkg_manager)"; then
      printf 'Error: no supported package manager found (looked for apt-get, dnf, zypper, pacman, apk).\n' >&2
      exit 1
    fi
    printf 'Detected package manager: %s\n' "${pkg_manager}"
  fi

  refresh_index "${pkg_manager}"

  local -a failed_packages=()
  local pkg
  while IFS= read -r pkg; do
    [[ -z "${pkg}" ]] && continue
    printf 'Installing %s...\n' "${pkg}"
    if ! install_pkg "${pkg_manager}" "${pkg}"; then
      failed_packages+=("${pkg}")
      printf 'Warning: failed to install %s, continuing.\n' "${pkg}" >&2
    fi
  done < <(packages_for "${pkg_manager}")

  local -a failed_optional_tools=()
  printf 'Installing mise...\n'
  if ! install_mise; then
    failed_optional_tools+=("mise")
    printf 'Warning: failed to install mise, continuing.\n' >&2
  fi

  local -a failed_ai_clis=()
  if (( OPT_SKIP_AI_CLIS )); then
    printf 'Skipping AI CLI installation (--skip-ai-clis).\n'
  else
    if (( ! OPT_DRY_RUN )) && ! command -v npm >/dev/null 2>&1; then
      printf 'Error: npm is not available after package installation; cannot install the AI CLIs.\n' >&2
      exit 1
    fi

    for pkg in "${AI_CLI_NPM_PACKAGES[@]}"; do
      printf 'Installing %s via npm...\n' "${pkg}"
      if ! run_or_plan sudo npm install -g "${pkg}"; then
        failed_ai_clis+=("${pkg}")
        printf 'Warning: failed to install %s.\n' "${pkg}" >&2
      fi
    done
  fi

  if (( ${#failed_packages[@]} > 0 )); then
    printf 'The following system packages could not be installed: %s\n' "${failed_packages[*]}" >&2
  fi
  if (( ${#failed_ai_clis[@]} > 0 )); then
    printf 'The following AI CLIs could not be installed: %s\n' "${failed_ai_clis[*]}" >&2
    exit 1
  fi
  if (( ${#failed_optional_tools[@]} > 0 )); then
    printf 'The following optional tools could not be installed: %s\n' "${failed_optional_tools[*]}" >&2
  fi

  if (( OPT_DRY_RUN )); then
    printf '[dry-run] Done; nothing was changed.\n'
    return 0
  fi

  print_activation_notes

  printf 'Toolchain installation complete.\n'
}

main "$@"
