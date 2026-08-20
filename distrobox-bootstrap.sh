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
    apt) sudo apt-get update -y ;;
    pacman) sudo pacman -Sy --noconfirm ;;
    apk) sudo apk update ;;
    dnf|zypper) ;;
  esac
}

install_pkg() {
  local mgr="$1" pkg="$2"
  case "${mgr}" in
    apt) sudo apt-get install -y "${pkg}" ;;
    dnf) sudo dnf install -y "${pkg}" ;;
    zypper) sudo zypper --non-interactive install "${pkg}" ;;
    pacman) sudo pacman -S --noconfirm "${pkg}" ;;
    apk) sudo apk add "${pkg}" ;;
  esac
}

packages_for() {
  local mgr="$1"
  case "${mgr}" in
    apt)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-venv python3-dev \
        build-essential curl jq ripgrep fzf shellcheck pandoc libreoffice libreoffice-writer graphviz gh \
        openssh-client gnupg unzip
      ;;
    dnf)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-devel \
        gcc gcc-c++ make curl jq ripgrep fzf ShellCheck pandoc libreoffice libreoffice-writer graphviz gh \
        openssh-clients gnupg2 unzip
      ;;
    zypper)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-devel \
        gcc gcc-c++ make curl jq ripgrep fzf ShellCheck pandoc libreoffice libreoffice-writer graphviz gh \
        openssh-clients gnupg2 unzip
      ;;
    pacman)
      printf '%s\n' git git-lfs nodejs npm python python-pip \
        base-devel curl jq ripgrep fzf shellcheck pandoc libreoffice-fresh graphviz github-cli \
        openssh gnupg unzip
      ;;
    apk)
      printf '%s\n' git git-lfs nodejs npm python3 py3-pip python3-dev \
        build-base curl jq ripgrep fzf shellcheck pandoc libreoffice graphviz github-cli \
        openssh-client gnupg unzip
      ;;
  esac
}

main() {
  if ! command -v sudo >/dev/null 2>&1; then
    printf 'Error: sudo not found inside the container; cannot install packages.\n' >&2
    exit 1
  fi

  local pkg_manager
  if ! pkg_manager="$(detect_pkg_manager)"; then
    printf 'Error: no supported package manager found (looked for apt-get, dnf, zypper, pacman, apk).\n' >&2
    exit 1
  fi
  printf 'Detected package manager: %s\n' "${pkg_manager}"

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

  if ! command -v npm >/dev/null 2>&1; then
    printf 'Error: npm is not available after package installation; cannot install the AI CLIs.\n' >&2
    exit 1
  fi

  local -a failed_ai_clis=()
  for pkg in "${AI_CLI_NPM_PACKAGES[@]}"; do
    printf 'Installing %s via npm...\n' "${pkg}"
    if ! sudo npm install -g "${pkg}"; then
      failed_ai_clis+=("${pkg}")
      printf 'Warning: failed to install %s.\n' "${pkg}" >&2
    fi
  done

  if (( ${#failed_packages[@]} > 0 )); then
    printf 'The following system packages could not be installed: %s\n' "${failed_packages[*]}" >&2
  fi
  if (( ${#failed_ai_clis[@]} > 0 )); then
    printf 'The following AI CLIs could not be installed: %s\n' "${failed_ai_clis[*]}" >&2
    exit 1
  fi

  printf 'Toolchain installation complete.\n'
}

main "$@"
