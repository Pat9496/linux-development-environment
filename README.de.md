# DEVenv

[![ShellCheck](https://github.com/Pat9496/linux-development-environment/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/Pat9496/linux-development-environment/actions/workflows/shellcheck.yml)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-blue)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English version](README.md)

## Inhaltsverzeichnis

- [Über](#über)
- [Voraussetzungen](#voraussetzungen)
- [Erste Schritte](#erste-schritte)
  - [Das Installationsskript ausführen](#das-installationsskript-ausführen)
  - [Installationseingaben](#installationseingaben)
  - [Befehlszeilenoptionen](#befehlszeilenoptionen)
  - [Den Container betreten](#den-container-betreten)
- [Host-Bereinigung](#host-bereinigung)
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
git clone https://github.com/Pat9496/linux-development-environment DEVenv
cd DEVenv
./install.sh
```

Das Skript überprüft, ob `distrobox` und `podman`/`docker` auf dem Host vorhanden sind, und führt dann durch den Konfigurationsprozess. Der Container wird immer mit dem fixen Namen `DEVenv` unter Verwendung des Images `registry.fedoraproject.org/fedora-toolbox:latest` erstellt.

### Installationseingaben

Während der Installation werden die folgenden Informationen abgefragt:

1. **Home-Verzeichnis-Modus** — Wahl zwischen der Verwendung des bestehenden Benutzer-Home oder der Erstellung eines separaten DEVenv-Home (Details in [Optionen für das Home-Verzeichnis](#optionen-für-das-home-verzeichnis) weiter unten).
2. Wird ein separates Home gewählt, kann optional die vorhandene Claude Code-, Codex- und Copilot CLI-Konfiguration vom Host in das neue Container-Home kopiert werden.

**Container-Neuanlage:** Das Skript zerstört und erstellt den Container bei jedem Lauf neu. Dies ist beabsichtigt — es verhindert, dass eine halb angewandte vorherige Installation oder abweichende Pakete stillschweigend mitgenommen werden. Existiert bereits ein Container mit dem Namen `DEVenv`, warnt das Skript und entfernt ihn vor der Erstellung eines neuen.

### Befehlszeilenoptionen

Sowohl `install.sh` als auch `distrobox-bootstrap.sh` akzeptieren Befehlszeilenoptionen, um Eingabeaufforderungen zu überspringen und unbeaufsichtigt auszuführen. Ohne Optionen ist das Verhalten unverändert und jede Wahl wird interaktiv abgefragt.

**install.sh-Optionen**

- `-y, --non-interactive` — Keine Eingabeaufforderungen. Die unten aufgeführten Standardwerte verwenden oder mit einem Fehler beenden. Ohne dieses Flag wird eine Eingabeaufforderung, die das Ende der Eingabe liest (beispielsweise `curl ... | bash`), als Fehler behandelt, anstatt stillschweigend einen Standardwert zu verwenden. Zur unbeaufsichtigten Ausführung explizite Flags übergeben oder `-y` verwenden.
- `--home-mode existing|separate` — Den Home-Verzeichnis-Modus setzen. Standardwert bei unbeaufsichtigt: `existing`.
- `--devenv-home PATH` — Pfad für das separate DEVenv-Home-Verzeichnis. Impliziert `--home-mode separate`. Akzeptiert absolute Pfade oder mit Tilde präfixierte Pfade; Standard bei unbeaufsichtigt: `~/DEVenv-home`.
- `--copy-ai-config` — Vorhandene Claude Code-, Codex- und Copilot CLI-Konfiguration vom Host in das neue DEVenv-Home kopieren (gilt nur für separaten Home-Modus).
- `--no-copy-ai-config` — AI-Konfiguration nicht kopieren. Dies ist der Standard bei unbeaufsichtigt.
- `--overwrite-existing-config` — Bestehende AI-Config-Pfade im DEVenv-Home ohne Rückfrage überschreiben. Standardmäßig fragt das Skript vor dem Überschreiben nach.
- `--no-host-cleanup` — Das Entfernen von host-seitigen Installationen von claude, codex oder copilot überspringen.
- `--no-auto-update` — Wrapper-Skripte generieren, die die npm-Update-Prüfung bei jedem Aufruf überspringen. Standardmäßig prüfen die Wrapper auf Updates jedes Mal, wenn `claude`, `codex` oder `copilot` vom Host aus ausgeführt wird.
- `--wrapper-dir DIR` — Host-Wrapper-Skripte in einem anderen Verzeichnis als `~/.local/bin` installieren. Muss ein absoluter Pfad sein.
- `--dry-run` — Geplante Aktionen ausgeben und beenden, ohne Änderungen vorzunehmen.
- `-h, --help` — Nutzungsinformationen anzeigen und beenden.

Optionen akzeptieren beide `--option value`- und `--option=value`-Syntax. Das `--`-Argument beendet das Parsen von Optionen.

**Optionsbeschränkungen**

- Das Übergeben von `--copy-ai-config` mit `--home-mode existing` ist ein Fehler (AI-Konfiguration wird nur in ein separates Home kopiert). Dies gilt auch für `-y --copy-ai-config` ohne `--home-mode separate`, da `-y` auf `existing` als Standard setzt.
- Das Übergeben von sowohl `--copy-ai-config` als auch `--no-copy-ai-config` ist ein Fehler.
- Das Übergeben von `--devenv-home PATH` mit `--home-mode existing` ist ein Fehler (ein separates Home ist für einen benutzerdefinierten Pfad erforderlich).
- Der Container-Name (`DEVenv`), das Basis-Image (`registry.fedoraproject.org/fedora-toolbox:latest`) und das Verhalten, den Container immer neu zu erstellen, sind hardcodiert und bewusst nicht konfigurierbar.

**distrobox-bootstrap.sh-Optionen**

Das Bootstrap-Skript wird normalerweise von `install.sh` innerhalb des Containers aufgerufen und ist nicht für die direkte Ausführung auf dem Host vorgesehen. Das Bootstrap-Skript akzeptiert:

- `--skip-ai-clis` — System-Entwicklungstoolchain installieren, aber npm-Pakete für claude, codex und copilot überspringen.
- `--pkg-manager apt|dnf|zypper|pacman|apk` — Bestimmten Package Manager verwenden statt Auto-Erkennung.
- `--dry-run` — Geplante Aktionen ausgeben und beenden, ohne Änderungen vorzunehmen.
- `-h, --help` — Nutzungsinformationen anzeigen und beenden.

`install.sh` übergibt `--skip-ai-clis` oder `--pkg-manager` nicht an das Bootstrap-Skript; das Bootstrap-Skript verwendet diese Optionen nur bei direktem Aufruf (was nicht der normale Arbeitsablauf ist).

**Beispiele**

Unbeaufsichtigte vollständige Installation mit separatem Home und AI-Config-Kopie:

```bash
./install.sh -y --home-mode separate --copy-ai-config
```

Dry Run zum Überprüfen geplanter Aktionen:

```bash
./install.sh --dry-run
```

### Den Container betreten

Nach Abschluss der Installation wird der Container mit folgendem Befehl betreten:

```bash
distrobox enter DEVenv
```

Alternativ können die AI-CLI-Tools direkt vom Host aus unter Verwendung der in `~/.local/bin` installierten Wrapper-Befehle ausgeführt werden – Details in [Host-Wrapper-Befehle](#host-wrapper-befehle) weiter unten.

## Host-Bereinigung

Vor der Erstellung des Containers überprüft das Installationsskript den Host auf vorhandene Installationen von `claude`, `codex` oder `copilot` und entfernt diese, damit diese Tools zukünftig nur noch innerhalb des `DEVenv`-Containers ausgeführt werden. Dieser Schritt läuft automatisch ohne Eingabeaufforderung ab und gibt eine Zusammenfassung der gefundenen und entfernten Installationen aus (oder eine Notiz, dass nichts gefunden wurde).

Es erkennt und entfernt, je Tool, wo zutreffend:

- npm-globale Installationen (`npm uninstall -g`)
- Native Distributionspakete (apt, dnf, zypper, pacman, apk)
- Homebrew Casks/Formulae (`claude-code`, `claude-code@latest`, `codex`, `copilot-cli`, `copilot-cli@prerelease`)
- Die offiziellen nativen Installer für Claude Code und Codex (`~/.local/bin/claude` / `~/.local/share/claude`, und `~/.local/bin/codex` / `~/.codex/packages/standalone`)
- Die veraltete `gh extension`-Installation von Copilot (`github/gh-copilot`)

Die AI-Assistenten-Konfiguration und Agenten—`~/.claude`, `~/.claude.json`, `~/.codex`, `~/.copilot`, `~/.config/github-copilot`—werden von diesem Schritt nicht angerührt; nur die installierten Programme selbst werden entfernt.

## Was wird installiert

Das Bootstrap-Skript innerhalb des Containers installiert die folgenden Tools und Laufzeitumgebungen:

- **Versionskontrolle:** git, git-lfs, SSH-Client, GnuPG
- **Laufzeitumgebungen:** Node.js, npm, Python
- **Build-Tools:** C/C++-Compiler-Toolchain (gcc/clang und make, Paketname variiert je nach Distribution), Python-Entwicklungsheader
- **CLI-Utilities:** curl, jq, ripgrep, fzf, unzip, ShellCheck, tmux, direnv
- **Runtime-Versionsverwaltung:** mise (installiert über das offizielle Installationsskript zu `~/.local/bin/mise` für Konsistenz über Distributionen hinweg)
- **Dokumentenverarbeitung:** pandoc, Graphviz, LibreOffice, LibreOffice Writer
- **Repository-Verwaltung:** GitHub CLI (`gh`)
- **AI-Assistenten:** Claude Code (`@anthropic-ai/claude-code`), Codex (`@openai/codex`), Copilot CLI (`@github/copilot`)

Das Skript erkennt den Package Manager des Containers (apt, dnf, zypper, pacman oder apk) und verwendet die entsprechenden Befehle für die Linux-Distribution. Falls ein Paket nicht installiert werden kann, protokolliert das Skript eine Warnung und setzt die Installation fort, wodurch der Installationsvorgang selbst dann abgeschlossen werden kann, wenn ein nicht kritisches Paket nicht verfügbar ist.

**Shell-Aktivierung für mise und direnv:** Sowohl `mise` als auch `direnv` erfordern Shell-Aktivierungshooks, um zu funktionieren. Nach Abschluss der Installation gibt das Bootstrap-Skript die exakte Aktivierungszeile für jedes Tool aus. Diese Zeilen müssen der Shell-Startdatei hinzugefügt werden (z.B. `~/.bashrc`, `~/.zshrc` oder die Entsprechung für die verwendete Shell); zum Beispiel:

```bash
eval "$(mise activate bash)"
eval "$(direnv hook bash)"
```

Das Installationsskript modifiziert die Shell-Konfiguration nicht automatisch – diese Zeilen müssen manuell hinzugefügt werden.

## Host-Wrapper-Befehle

Nach der Installation werden drei Wrapper-Skripte in `~/.local/bin` installiert: `claude`, `codex` und `copilot`. Diese ermöglichen es, die AI-CLI-Tools direkt vom Host-Terminal aus auszuführen, ohne den Container zu betreten.

**Design:** DEVenv nutzt ein No-Export-Design — alles, was im Container installiert wird, bleibt nur im Container. Es werden keine distrobox-export-Aufrufe gemacht, und es werden keine Host-Dateien oder exportierten Binärdateien für die Container-Pakete erstellt. Die einzigen Host-seitigen Artefakte sind diese drei einfachen Wrapper-Skripte für die AI-CLIs.

**Funktionsweise:** Jeder Wrapper führt den Befehl innerhalb des DEVenv-Containers über `distrobox enter "DEVenv" -- <command> "$@"` aus. Die Aufrufe können vom Host-Terminal aus erfolgen:

```bash
claude --help
codex list
copilot auth login
```

**Update-Prüfung:** Vor der Ausführung des Befehls führt jeder Wrapper `npm install -g <package>@latest` innerhalb des `DEVenv`-Containers für sein eigenes AI-CLI-Paket aus. Diese Prüfung wird bei jedem Aufruf ausgeführt. Das Update nutzt `sudo -n`, sodass der Wrapper niemals auf eine Passwortaufforderung wartet – sind keine zwischengespeicherten sudo-Anmeldedaten verfügbar, gibt er eine Warnung aus und setzt die Nutzung der aktuell installierten Version fort. Die Update-Prüfung blockiert oder beschädigt den tatsächlichen Befehl nicht, auch nicht wenn das Update selbst fehlschlägt.

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

DEVenv baut auf und ist abhängig von den folgenden vorgelagerten Projekten:

- **Distrobox** — Einstiegspunkt und Lebenszyklusverwaltung des Containers
- **Fedora Toolbox** — Container-Basis-Image (`registry.fedoraproject.org/fedora-toolbox:latest`)
- **Codex** — KI-Assistent
- **Copilot CLI** — KI-Assistent
