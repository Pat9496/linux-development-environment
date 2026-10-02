# DEVenv

[![ShellCheck](https://github.com/Pat9496/linux-development-environment/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/Pat9496/linux-development-environment/actions/workflows/shellcheck.yml)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-blue)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[Deutsche Version](README.de.md)

## Table of Contents

- [About](#about)
- [Requirements](#requirements)
- [Getting Started](#getting-started)
  - [Running the Installation Script](#running-the-installation-script)
  - [Installation Prompts](#installation-prompts)
  - [Entering the Container](#entering-the-container)
- [Host Cleanup](#host-cleanup)
- [What Gets Installed](#what-gets-installed)
- [Host Wrapper Commands](#host-wrapper-commands)
- [Home Directory Options](#home-directory-options)
  - [Using Your Existing Home](#using-your-existing-home)
  - [Creating a Separate DEVenv Home](#creating-a-separate-devenv-home)
- [Contributing](#contributing)
- [Credits](#credits)

## About

DEVenv is an automated setup script for a Distrobox development container. It configures a complete development toolchain tailored for software development with Claude Code, Codex, and Copilot CLI. Run the installation script on the host, and it creates and provisions a container with all necessary tools.

## Requirements

On the host system, you must have:

- A Linux system (any distribution)
- `distrobox` installed
- Either `podman` or `docker` available as the container runtime

The installation script itself is self-contained and will set up everything else inside the container.

## Getting Started

### Running the Installation Script

Clone this repository on the host system, then run the installation script:

```bash
git clone https://github.com/Pat9496/linux-development-environment DEVenv
cd DEVenv
./install.sh
```

The script will check for `distrobox` and `podman`/`docker` on the host, then guide you through the setup process. The container is always created with the fixed name `DEVenv` using the `registry.fedoraproject.org/fedora-toolbox:latest` image.

### Installation Prompts

During installation, you will be prompted for the following:

1. **Home directory mode** — Choose between using your existing user home or creating a separate DEVenv home (see [Home Directory Options](#home-directory-options) below).
2. If you choose a separate home, you may optionally copy existing Claude Code, Codex, and Copilot CLI configuration from the host into the new container home.

**Container Recreation:** The script always destroys and recreates the container from scratch on every run. This is intentional — it prevents silently carrying over a half-applied prior installation or drifted packages. If a container named `DEVenv` already exists, the script will warn you and remove it before creating a new one.

### Entering the Container

After installation completes, enter the container with:

```bash
distrobox enter DEVenv
```

Alternatively, you can run the AI CLI tools directly from the host using wrapper commands installed in `~/.local/bin`—see [Host Wrapper Commands](#host-wrapper-commands) below.

## Host Cleanup

Before creating the container, the installation script checks the host itself for existing installs of `claude`, `codex`, or `copilot` and removes them, so these tools run only inside the `DEVenv` container going forward. This step runs automatically, with no prompt, and prints a summary of what it found and removed (or a note that nothing was found).

It detects and removes, per tool where applicable:

- npm-global installs (`npm uninstall -g`)
- Native distribution packages (apt, dnf, zypper, pacman, apk)
- Homebrew casks/formulae (`claude-code`, `claude-code@latest`, `codex`, `copilot-cli`, `copilot-cli@prerelease`)
- The official native installer for Claude Code and Codex (`~/.local/bin/claude` / `~/.local/share/claude`, and `~/.local/bin/codex` / `~/.codex/packages/standalone`)
- The deprecated `gh extension` install of Copilot (`github/gh-copilot`)

Your AI assistant configuration and agents—`~/.claude`, `~/.claude.json`, `~/.codex`, `~/.copilot`, `~/.config/github-copilot`—are never touched by this step; only the installed programs themselves are removed.

## What Gets Installed

The bootstrap script inside the container installs the following tools and runtimes:

- **Version control:** git, git-lfs, SSH client, GnuPG
- **Runtimes:** Node.js, npm, Python
- **Build tools:** C/C++ compiler toolchain (gcc/clang and make, package name varies by distribution), Python development headers
- **CLI utilities:** curl, jq, ripgrep, fzf, unzip, ShellCheck, tmux, direnv
- **Runtime version manager:** mise (installed via official installer script to `~/.local/bin/mise` for consistency across distributions)
- **Document handling:** pandoc, Graphviz, LibreOffice, LibreOffice Writer
- **Repository management:** GitHub CLI (`gh`)
- **AI assistants:** Claude Code (`@anthropic-ai/claude-code`), Codex (`@openai/codex`), Copilot CLI (`@github/copilot`)

The script detects your container's package manager (apt, dnf, zypper, pacman, or apk) and uses the appropriate commands for your Linux distribution. If a package fails to install, the script logs a warning and continues, allowing the installation to complete even if a non-critical package is unavailable.

**Shell activation for mise and direnv:** Both `mise` and `direnv` require shell activation hooks to work. After installation completes, the bootstrap script prints the exact activation line required for each tool. You must add these to your shell startup file (e.g. `~/.bashrc`, `~/.zshrc`, or your shell's equivalent); for example:

```bash
eval "$(mise activate bash)"
eval "$(direnv hook bash)"
```

The installation script does not modify your shell configuration automatically—you must add these lines yourself.

## Host Wrapper Commands

After installation, three wrapper scripts are installed in `~/.local/bin`: `claude`, `codex`, and `copilot`. These let you run the AI CLI tools directly from your host terminal without entering the container.

**Design:** DEVenv uses a no-export design—everything installed inside the container stays container-only. No distrobox-export calls are made, and no host .desktop entries or exported binaries are created for any container package. The only host-side artifacts created are these three thin wrapper scripts for the AI CLIs.

**How they work:** Each wrapper runs the command inside the DEVenv container via `distrobox enter "DEVenv" -- <command> "$@"`. You can invoke them from the host terminal:

```bash
claude --help
codex list
copilot auth login
```

**Update check:** Before running your command, each wrapper runs `npm install -g <package>@latest` inside the `DEVenv` container for its own AI CLI package. This check runs on every invocation. The update uses `sudo -n`, so it never blocks waiting for a password prompt—if no cached sudo credentials are available, it prints a warning and continues with the currently installed version. The update check never blocks or fails your actual command even if the update itself fails.

**PATH configuration:** For the wrappers to be found from any directory, `~/.local/bin` must be on your shell's `PATH`. The installation script checks for this after creating the wrappers. If `~/.local/bin` is not on your PATH, the script prints a reminder suggesting you add it to your shell startup file. To do so, add this line to `~/.bashrc`, `~/.zshrc`, or your shell's equivalent startup file:

```bash
export PATH="${HOME}/.local/bin:$PATH"
```

## Home Directory Options

The installation script offers two modes for how the container manages your home directory.

### Using Your Existing Home

If you select "use existing home," the container mounts your current user home directory. This mode gives the container full access to your existing files, repositories, and configuration.

### Creating a Separate DEVenv Home

If you select "create a separate DEVenv home," the script creates a new, isolated home directory (default: `~/DEVenv-home`) on the host. The container uses this dedicated directory as its home, keeping development work and container-specific configuration separate from your host system.

When you create a separate home for the first time, the script offers to copy your existing AI assistant configuration from the host into the new container home:

- `~/.claude` — Claude Code configuration and agent files
- `~/.codex` — Codex configuration
- `~/.copilot` — Copilot CLI configuration
- `~/.config/github-copilot` — GitHub Copilot configuration

This allows you to use your existing AI assistant setup inside the container without manual reconfiguration. If these directories already exist in the separate home on a subsequent run, the script asks before overwriting each one.

## Contributing

Contributions are welcome. Please open an issue to discuss your ideas before submitting code changes.

## Credits

DEVenv builds on and depends on the following upstream projects:

- **Distrobox** — Container entry point and lifecycle management
- **Fedora Toolbox** — Base container image (`registry.fedoraproject.org/fedora-toolbox:latest`)
- **Codex** — AI assistant
- **Copilot CLI** — AI assistant

