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

# Python libraries for document conversion (XLSX <-> Markdown tables, PDF
# text/table extraction). They live in a dedicated venv instead of the system
# site-packages, since apt/pacman/apk mark the system Python as externally
# managed (PEP 668) and distro package names for these differ too much.
readonly DEVENV_DATA_DIR="${HOME}/.local/share/devenv"
readonly DOC_TOOLS_VENV="${DEVENV_DATA_DIR}/doc-tools"
readonly DOC_TOOLS_PIP_PACKAGES=(
  openpyxl
  pandas
  tabulate
  pdfplumber
  pymupdf
  pypdf
  pymupdf4llm
  "markitdown[xlsx,pdf]"
  python-docx
)

# Tools without a distro-agnostic package. PowerShell and draw.io desktop come
# from their GitHub releases (checked against the sha256 digest GitHub publishes
# for every release asset); Azure CLI comes from PyPI into its own venv.
readonly POWERSHELL_RELEASES_API="https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
readonly DRAWIO_RELEASES_API="https://api.github.com/repos/jgraph/drawio-desktop/releases/latest"
readonly CONTAINER_BIN_DIR="/usr/local/bin"
readonly POWERSHELL_INSTALL_DIR="${DEVENV_DATA_DIR}/powershell"
readonly DRAWIO_INSTALL_DIR="${DEVENV_DATA_DIR}/drawio"
readonly AZURE_CLI_VENV="${DEVENV_DATA_DIR}/azure-cli"

OPT_SKIP_AI_CLIS=0
OPT_PKG_MANAGER=""
OPT_DRY_RUN=0
STAGING_DIR=""

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
    pacman) run_or_plan sudo pacman -Syu --noconfirm ;;
    apk) run_or_plan sudo apk update ;;
    dnf|zypper) ;;
  esac
}

install_pkg() {
  local mgr="$1"
  shift
  case "${mgr}" in
    apt) run_or_plan sudo apt-get install -y "$@" ;;
    dnf) run_or_plan sudo dnf install -y "$@" ;;
    zypper) run_or_plan sudo zypper --non-interactive install "$@" ;;
    pacman) run_or_plan sudo pacman -S --needed --noconfirm "$@" ;;
    apk) run_or_plan sudo apk add "$@" ;;
  esac
}

packages_for() {
  local mgr="$1"
  case "${mgr}" in
    apt)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-venv python3-dev \
        build-essential curl jq ripgrep fzf tmux direnv shellcheck pandoc libreoffice libreoffice-writer \
        graphviz gh openssh-client gnupg unzip \
        poppler-utils qpdf ghostscript tesseract-ocr tesseract-ocr-eng tesseract-ocr-deu ocrmypdf \
        texlive-xetex texlive-latex-recommended texlive-fonts-recommended lmodern \
        fonts-crosextra-carlito fonts-liberation \
        xvfb xauth libgtk-3-0 libnss3 libgbm1 libasound2t64 libicu-dev
      ;;
    dnf)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-devel \
        gcc gcc-c++ make curl jq ripgrep fzf tmux direnv ShellCheck pandoc libreoffice libreoffice-writer \
        graphviz gh openssh-clients gnupg2 unzip \
        poppler-utils qpdf ghostscript tesseract tesseract-langpack-eng tesseract-langpack-deu ocrmypdf \
        texlive-xetex texlive-collection-latexrecommended texlive-collection-fontsrecommended \
        google-carlito-fonts liberation-fonts \
        xorg-x11-server-Xvfb xorg-x11-xauth gtk3 nss mesa-libgbm alsa-lib libicu
      ;;
    zypper)
      printf '%s\n' git git-lfs nodejs npm python3 python3-pip python3-devel \
        gcc gcc-c++ make curl jq ripgrep fzf tmux direnv ShellCheck pandoc libreoffice libreoffice-writer \
        graphviz gh openssh-clients gpg2 unzip \
        poppler-tools qpdf ghostscript tesseract-ocr tesseract-ocr-traineddata-english \
        tesseract-ocr-traineddata-german texlive-xetex texlive-collection-latexrecommended \
        texlive-collection-fontsrecommended typst \
        google-carlito-fonts liberation-fonts \
        xvfb-run xauth libgtk-3-0 mozilla-nss libgbm1 alsa libicu
      ;;
    pacman)
      printf '%s\n' git git-lfs nodejs npm python python-pip \
        base-devel curl jq ripgrep fzf tmux direnv shellcheck pandoc libreoffice-fresh graphviz github-cli \
        openssh gnupg unzip poppler qpdf ghostscript tesseract tesseract-data-eng tesseract-data-deu \
        texlive-xetex texlive-latexrecommended texlive-fontsrecommended typst ttf-carlito ttf-liberation \
        xorg-server-xvfb xorg-xauth gtk3 nss mesa alsa-lib icu
      ;;
    apk)
      printf '%s\n' git git-lfs nodejs npm python3 py3-pip python3-dev \
        build-base curl jq ripgrep fzf tmux direnv shellcheck pandoc libreoffice graphviz github-cli \
        openssh-client gnupg unzip poppler-utils qpdf ghostscript tesseract-ocr \
        tesseract-ocr-data-eng tesseract-ocr-data-deu ocrmypdf texlive-xetex typst font-carlito font-liberation icu-libs
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

  if ! curl -fsSL --proto '=https' "${MISE_INSTALL_URL}" -o "${mise_installer}"; then
    printf 'Warning: could not download the mise installer from %s.\n' "${MISE_INSTALL_URL}" >&2
    return 1
  fi

  if ! sh "${mise_installer}"; then
    return 1
  fi
}

install_doc_tools() {
  if (( OPT_DRY_RUN )); then
    printf '[dry-run] would create venv %s and pip install: %s\n' "${DOC_TOOLS_VENV}" "${DOC_TOOLS_PIP_PACKAGES[*]}"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'Error: python3 not found inside the container; cannot create the document-tools venv.\n' >&2
    return 1
  fi

  mkdir -p -- "${DEVENV_DATA_DIR}" || return 1
  if ! python3 -m venv "${DOC_TOOLS_VENV}"; then
    return 1
  fi
  "${DOC_TOOLS_VENV}/bin/python" -m pip install --upgrade "${DOC_TOOLS_PIP_PACKAGES[@]}"
}

# Downloads the first release asset of the latest GitHub release whose name
# matches the given regex to the given path, and verifies GitHub's published
# sha256 digest. Refuses to continue if the digest is missing or does not match.
download_github_asset() {
  local api_url="$1" name_regex="$2" dest="$3"
  local release_json asset_url asset_digest actual_digest tool

  for tool in curl jq sha256sum; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      printf 'Error: %s not found inside the container; cannot download from GitHub releases.\n' "${tool}" >&2
      return 1
    fi
  done

  if ! release_json="$(curl -fsSL --proto '=https' "${api_url}")"; then
    printf 'Warning: could not query %s.\n' "${api_url}" >&2
    return 1
  fi

  asset_url="$(jq -r --arg re "${name_regex}" '[.assets[] | select(.name | test($re))][0].browser_download_url // empty' <<<"${release_json}")"
  asset_digest="$(jq -r --arg re "${name_regex}" '[.assets[] | select(.name | test($re))][0].digest // empty' <<<"${release_json}")"
  if [[ -z "${asset_url}" || "${asset_digest}" != sha256:* ]]; then
    printf 'Warning: no release asset matching %s with a sha256 digest found at %s.\n' "${name_regex}" "${api_url}" >&2
    return 1
  fi

  if ! curl -fsSL --proto '=https' "${asset_url}" -o "${dest}"; then
    printf 'Warning: could not download %s.\n' "${asset_url}" >&2
    return 1
  fi

  if ! actual_digest="$(sha256sum < "${dest}")"; then
    printf 'Error: could not compute the sha256 digest of %s.\n' "${dest}" >&2
    return 1
  fi
  actual_digest="sha256:${actual_digest%% *}"
  if [[ "${actual_digest}" != "${asset_digest}" ]]; then
    printf 'Error: checksum mismatch for %s (expected %s, got %s).\n' "${asset_url}" "${asset_digest}" "${actual_digest}" >&2
    return 1
  fi
}

new_staging_dir() {
  mkdir -p -- "${DEVENV_DATA_DIR}" || return 1
  STAGING_DIR="$(mktemp -d -- "${DEVENV_DATA_DIR}/.staging.XXXXXX")" || return 1
}

remove_staging_dir() {
  [[ -z "${STAGING_DIR}" ]] || rm -rf -- "${STAGING_DIR}"
  STAGING_DIR=""
}

replace_dir() {
  local staged="$1" target="$2"
  if [[ -e "${target}" || -L "${target}" ]]; then
    mv -- "${target}" "${STAGING_DIR}/previous" || return 1
  fi
  mv -- "${staged}" "${target}"
}

# Replaces any previous install by extracting into a fresh directory first.
install_powershell() {
  local mgr="$1"
  local arch libc_suffix=""
  case "$(uname -m)" in
    x86_64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) printf 'Error: unsupported CPU architecture %s for PowerShell.\n' "$(uname -m)" >&2; return 1 ;;
  esac
  if [[ "${mgr}" == "apk" ]]; then
    if [[ "${arch}" != "x64" ]]; then
      printf 'Error: no PowerShell build for musl on %s.\n' "${arch}" >&2
      return 1
    fi
    libc_suffix="musl-"
  fi

  if (( OPT_DRY_RUN )); then
    printf '[dry-run] would download the latest PowerShell release from GitHub into %s and link %s/pwsh to it\n' "${POWERSHELL_INSTALL_DIR}" "${CONTAINER_BIN_DIR}"
    return 0
  fi

  new_staging_dir || return 1
  trap 'remove_staging_dir; trap - RETURN' RETURN

  download_github_asset "${POWERSHELL_RELEASES_API}" "^powershell-[0-9.]+-linux-${libc_suffix}${arch}\\.tar\\.gz$" "${STAGING_DIR}/powershell.tar.gz" || return 1

  mkdir -- "${STAGING_DIR}/extracted" || return 1
  tar -xzf "${STAGING_DIR}/powershell.tar.gz" -C "${STAGING_DIR}/extracted" || return 1
  chmod +x -- "${STAGING_DIR}/extracted/pwsh" || return 1
  replace_dir "${STAGING_DIR}/extracted" "${POWERSHELL_INSTALL_DIR}" || return 1
  sudo ln -sfn -- "${POWERSHELL_INSTALL_DIR}/pwsh" "${CONTAINER_BIN_DIR}/pwsh"
}

# The AppImage is extracted instead of run, since containers usually lack FUSE.
# The wrapper runs it under xvfb so the CLI export (drawio -x ...) works headless.
install_drawio() {
  local mgr="$1"
  if [[ "${mgr}" == "apk" ]]; then
    printf 'Error: the draw.io desktop AppImage needs glibc, which Alpine does not provide.\n' >&2
    return 1
  fi

  local arch
  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) printf 'Error: unsupported CPU architecture %s for draw.io desktop.\n' "$(uname -m)" >&2; return 1 ;;
  esac

  if (( OPT_DRY_RUN )); then
    printf '[dry-run] would download the latest draw.io desktop AppImage from GitHub into %s and write the %s/drawio wrapper\n' "${DRAWIO_INSTALL_DIR}" "${CONTAINER_BIN_DIR}"
    return 0
  fi

  if ! command -v xvfb-run >/dev/null 2>&1; then
    printf 'Error: xvfb-run not found; draw.io desktop cannot run headless without it.\n' >&2
    return 1
  fi

  new_staging_dir || return 1
  trap 'remove_staging_dir; trap - RETURN' RETURN

  download_github_asset "${DRAWIO_RELEASES_API}" "^drawio-${arch}-[0-9.]+\\.AppImage$" "${STAGING_DIR}/drawio.AppImage" || return 1
  chmod +x -- "${STAGING_DIR}/drawio.AppImage" || return 1
  (cd -- "${STAGING_DIR}" && ./drawio.AppImage --appimage-extract >/dev/null) || return 1
  replace_dir "${STAGING_DIR}/squashfs-root" "${DRAWIO_INSTALL_DIR}" || return 1

  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec xvfb-run -a %q --no-sandbox "$@"\n' "${DRAWIO_INSTALL_DIR}/AppRun"
  } > "${STAGING_DIR}/drawio" || return 1
  sudo install -m 0755 -- "${STAGING_DIR}/drawio" "${CONTAINER_BIN_DIR}/drawio"
}

install_azure_cli() {
  if (( OPT_DRY_RUN )); then
    printf '[dry-run] would create venv %s, pip install azure-cli and link %s/az to it\n' "${AZURE_CLI_VENV}" "${CONTAINER_BIN_DIR}"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'Error: python3 not found inside the container; cannot create the Azure CLI venv.\n' >&2
    return 1
  fi

  mkdir -p -- "${DEVENV_DATA_DIR}" || return 1
  python3 -m venv "${AZURE_CLI_VENV}" || return 1
  "${AZURE_CLI_VENV}/bin/python" -m pip install --upgrade azure-cli || return 1
  sudo ln -sfn -- "${AZURE_CLI_VENV}/bin/az" "${CONTAINER_BIN_DIR}/az"
}

print_activation_notes() {
  if [[ -x "${DOC_TOOLS_VENV}/bin/python" ]]; then
    printf '\nNote: Python document-conversion libraries (openpyxl, pandas, pdfplumber, pymupdf, ...) are in %s.\n' "${DOC_TOOLS_VENV}" >&2
    printf 'Use %s/bin/python to run scripts that need them.\n' "${DOC_TOOLS_VENV}" >&2
  fi

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
  trap remove_staging_dir EXIT

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

  local -a packages=() failed_packages=()
  local pkg
  mapfile -t packages < <(packages_for "${pkg_manager}")
  printf 'Installing %d system packages in one transaction...\n' "${#packages[@]}"
  if ! install_pkg "${pkg_manager}" "${packages[@]}"; then
    printf 'Warning: the combined package install failed; retrying one package at a time.\n' >&2
    for pkg in "${packages[@]}"; do
      printf 'Installing %s...\n' "${pkg}"
      if ! install_pkg "${pkg_manager}" "${pkg}"; then
        failed_packages+=("${pkg}")
        printf 'Warning: failed to install %s, continuing.\n' "${pkg}" >&2
      fi
    done
  fi

  local -a failed_optional_tools=()
  printf 'Installing mise...\n'
  if ! install_mise; then
    failed_optional_tools+=("mise")
    printf 'Warning: failed to install mise, continuing.\n' >&2
  fi

  printf 'Installing Python document-conversion libraries...\n'
  if ! install_doc_tools; then
    failed_optional_tools+=("doc-tools venv")
    printf 'Warning: failed to install the Python document-conversion libraries, continuing.\n' >&2
  fi

  local tool
  for tool in powershell drawio azure_cli; do
    printf 'Installing %s...\n' "${tool}"
    if ! "install_${tool}" "${pkg_manager}"; then
      failed_optional_tools+=("${tool}")
      printf 'Warning: failed to install %s, continuing.\n' "${tool}" >&2
    fi
  done

  local -a failed_ai_clis=()
  if (( OPT_SKIP_AI_CLIS )); then
    printf 'Skipping AI CLI installation (--skip-ai-clis).\n'
  elif (( ! OPT_DRY_RUN )) && ! command -v npm >/dev/null 2>&1; then
    printf 'Error: npm is not available after package installation; cannot install the AI CLIs.\n' >&2
    failed_ai_clis=("${AI_CLI_NPM_PACKAGES[@]}")
  else
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
  if (( ${#failed_optional_tools[@]} > 0 )); then
    printf 'The following optional tools could not be installed: %s\n' "${failed_optional_tools[*]}" >&2
  fi
  if (( ${#failed_ai_clis[@]} > 0 )); then
    printf 'The following AI CLIs could not be installed: %s\n' "${failed_ai_clis[*]}" >&2
    exit 1
  fi

  if (( OPT_DRY_RUN )); then
    printf '[dry-run] Done; nothing was changed.\n'
    return 0
  fi

  print_activation_notes

  printf 'Toolchain installation complete.\n'
}

main "$@"
