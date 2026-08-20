# DEVenv

[![ShellCheck](https://github.com/Pat9496/linux-development-environment/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/Pat9496/linux-development-environment/actions/workflows/shellcheck.yml)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-blue)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[English version](README.md)

## Inhaltsverzeichnis

- [Über](#über)
- [Voraussetzungen](#voraussetzungen)
- [Erste Schritte](#erste-schritte)
  - [Das Installationsskript ausführen](#das-installationsskript-ausführen)
  - [Installationseingaben](#installationseingaben)
  - [Den Container betreten](#den-container-betreten)
- [Was wird installiert](#was-wird-installiert)
- [Host-Wrapper-Befehle](#host-wrapper-befehle)
- [Optionen für das Home-Verzeichnis](#optionen-für-das-home-verzeichnis)
  - [Das bestehende Home verwenden](#das-bestehende-home-verwenden)
  - [Ein separates DEVenv-Home erstellen](#ein-separates-devenv-home-erstellen)
- [Mitwirkung](#mitwirkung)
- [Danksagung](#danksagung)

## Über

DEVenv ist ein automatisiertes Installationsskript für einen Distrobox-Entwicklungscontainer. Es konfiguriert eine vollständige Entwicklungstoolchain, die für die Softwareentwicklung mit Claude Code, Codex und Copilot CLI optimiert ist. Das Installationsskript wird auf dem Host ausgeführt, und es erstellt und stellt einen Container mit allen erforderlichen Tools bereit.

## Voraussetzungen

Auf dem Host-System müssen folgende Komponenten vorhanden sein:

- Ein Linux-System (jede Distribution)
- `distrobox` installiert
- Entweder `podman` oder `docker` als Container-Runtime verfügbar

Das Installationsskript selbst ist eigenständig und richtet alles weitere innerhalb des Containers ein.

## Erste Schritte

### Das Installationsskript ausführen

Das Repository auf dem Host klonen und dann das Installationsskript ausführen:

```bash
git clone <repository-url>
cd DEVenv
./install.sh
```

Das Skript überprüft, ob `distrobox` und `podman`/`docker` auf dem Host vorhanden sind, und führt dann durch den Konfigurationsprozess. Der Container wird immer mit dem fixen Namen `DEVenv` unter Verwendung des Images `registry.fedoraproject.org/fedora-toolbox:latest` erstellt.

### Installationseingaben

Während der Installation werden die folgenden Informationen abgefragt:

1. **Home-Verzeichnis-Modus** — Wahl zwischen der Verwendung des bestehenden Benutzer-Home oder der Erstellung eines separaten DEVenv-Home (Details in [Optionen für das Home-Verzeichnis](#optionen-für-das-home-verzeichnis) weiter unten).
2. Wird ein separates Home gewählt, kann optional die vorhandene Claude Code-, Codex- und Copilot CLI-Konfiguration vom Host in das neue Container-Home kopiert werden.

**Container-Neuanlage:** Das Skript zerstört und erstellt den Container bei jedem Lauf neu. Dies ist beabsichtigt — es verhindert, dass eine halb angewandte vorherige Installation oder abweichende Pakete stillschweigend mitgenommen werden. Existiert bereits ein Container mit dem Namen `DEVenv`, warnt das Skript und entfernt ihn vor der Erstellung eines neuen.

### Den Container betreten

Nach Abschluss der Installation wird der Container mit folgendem Befehl betreten:

```bash
distrobox enter DEVenv
```

Alternativ können die AI-CLI-Tools direkt vom Host aus unter Verwendung der in `~/.local/bin` installierten Wrapper-Befehle ausgeführt werden – Details in [Host-Wrapper-Befehle](#host-wrapper-befehle) weiter unten.

## Was wird installiert

Das Bootstrap-Skript innerhalb des Containers installiert die folgenden Tools und Laufzeitumgebungen:

- **Versionskontrolle:** git, git-lfs, SSH-Client, GnuPG
- **Laufzeitumgebungen:** Node.js, npm, Python
- **Build-Tools:** C/C++-Compiler-Toolchain (gcc/clang und make, Paketname variiert je nach Distribution), Python-Entwicklungsheader
- **CLI-Utilities:** curl, jq, ripgrep, fzf, unzip, ShellCheck
- **Dokumentenverarbeitung:** pandoc, Graphviz, LibreOffice, LibreOffice Writer
- **Repository-Verwaltung:** GitHub CLI (`gh`)
- **AI-Assistenten:** Claude Code (`@anthropic-ai/claude-code`), Codex (`@openai/codex`), Copilot CLI (`@github/copilot`)

Das Skript erkennt den Package Manager des Containers (apt, dnf, zypper, pacman oder apk) und verwendet die entsprechenden Befehle für die Linux-Distribution. Falls ein Paket nicht installiert werden kann, protokolliert das Skript eine Warnung und setzt die Installation fort, wodurch der Installationsvorgang selbst dann abgeschlossen werden kann, wenn ein nicht kritisches Paket nicht verfügbar ist.

## Host-Wrapper-Befehle

Nach der Installation werden drei Wrapper-Skripte in `~/.local/bin` installiert: `claude`, `codex` und `copilot`. Diese ermöglichen es, die AI-CLI-Tools direkt vom Host-Terminal aus auszuführen, ohne den Container zu betreten.

**Design:** DEVenv nutzt ein No-Export-Design — alles, was im Container installiert wird, bleibt nur im Container. Es werden keine distrobox-export-Aufrufe gemacht, und es werden keine Host-Dateien oder exportierten Binärdateien für die Container-Pakete erstellt. Die einzigen Host-seitigen Artefakte sind diese drei einfachen Wrapper-Skripte für die AI-CLIs.

**Funktionsweise:** Jeder Wrapper führt den Befehl innerhalb des DEVenv-Containers über `distrobox enter "DEVenv" -- <command> "$@"` aus. Die Aufrufe können vom Host-Terminal aus erfolgen:

```bash
claude --help
codex list
copilot auth login
```

**PATH-Konfiguration:** Damit die Wrapper von jedem Verzeichnis aus gefunden werden, muss `~/.local/bin` in der PATH-Variable der Shell enthalten sein. Das Installationsskript überprüft dies nach der Erstellung der Wrapper. Falls `~/.local/bin` nicht in PATH enthalten ist, gibt das Skript eine Erinnerung aus, die vorschlägt, es in die Shell-Startdatei hinzuzufügen. Hierzu ist folgende Zeile in `~/.bashrc`, `~/.zshrc` oder in der entsprechenden Startdatei der Shell einzufügen:

```bash
export PATH="${HOME}/.local/bin:$PATH"
```

## Optionen für das Home-Verzeichnis

Das Installationsskript bietet zwei Modi, wie der Container das Home-Verzeichnis verwaltet.

### Das bestehende Home verwenden

Wird „Bestehendes Home verwenden" ausgewählt, bindet der Container das aktuelle Benutzer-Home-Verzeichnis ein. Dieser Modus gibt dem Container vollständigen Zugriff auf bestehende Dateien, Repositories und Konfigurationen.

### Ein separates DEVenv-Home erstellen

Wird „Ein separates DEVenv-Home erstellen" ausgewählt, erstellt das Skript ein neues, isoliertes Home-Verzeichnis (Standard: `~/DEVenv-home`) auf dem Host. Der Container verwendet dieses dedizierte Verzeichnis als sein Home-Verzeichnis, wodurch Entwicklungsarbeit und Container-spezifische Konfiguration vom Host-System getrennt bleiben.

Wird zum ersten Mal ein separates Home erstellt, bietet das Skript an, die vorhandene AI-Assistenten-Konfiguration vom Host in das neue Container-Home zu kopieren:

- `~/.claude` — Claude Code-Konfiguration und Agent-Dateien
- `~/.codex` — Codex-Konfiguration
- `~/.copilot` — Copilot CLI-Konfiguration
- `~/.config/github-copilot` — GitHub Copilot-Konfiguration

Dies ermöglicht es, das bestehende AI-Assistenten-Setup innerhalb des Containers ohne manuelle Neukonfiguration zu nutzen. Existieren diese Verzeichnisse bereits im separaten Home bei einem nachfolgenden Lauf, fragt das Skript vor dem Überschreiben jedes einzelnen Verzeichnisses nach.

## Mitwirkung

Beiträge sind willkommen. Ein Issue sollte erstellt werden, um Ideen vor der Einreichung von Code-Änderungen zu diskutieren.

## Danksagung

Das DEVenv-Installationsskript baut auf etablierten, quelloffenen Werkzeugen und Plattformen auf. Danke an die Maintainer und Beitragende der folgenden Projekte:

- **Distrobox** – für die containerisierte Entwicklungsumgebung
- **Fedora Toolbox** – für das stabile Basis-Container-Image
- **Claude Code** (Anthropic) – für die integrierte KI-Entwicklungsassistenz
- **Codex** (OpenAI) – für zusätzliche Code-Intelligenz
- **Copilot CLI** (GitHub) – für die GitHub-integrierte KI-Unterstützung
