# claude-cli

A lightweight shell wrapper that runs [Claude Code](https://github.com/anthropics/claude-code) inside a Docker container, keeping your host system clean while persisting your Claude configuration across sessions.

## Requirements

- [Docker](https://docs.docker.com/get-docker/) with [Buildx](https://docs.docker.com/reference/cli/docker/buildx/) plugin
- [dmenu](https://tools.suckless.org/dmenu/) — mode selection prompt (not required when using `-f`)
- [fzf](https://github.com/junegunn/fzf) — directory picker; also used for mode selection with `-f`
- Current user must be a member of the `docker` group

## Installation

```sh
git clone https://github.com/shirozuki/claude-cli
chmod +x claude-cli/claude-cli.sh
ln -s "$PWD/claude-cli/claude-cli.sh" ~/.local/bin/claude-cli
```

## Usage

```
claude-cli [-b] [-c] [-f] [-h]
```

| Option | Description |
|--------|-------------|
| `-b`   | Build (or rebuild) the `claude-cli:latest` Docker image |
| `-c`   | Remove all `claude-cli` containers; optionally remove the image |
| `-f`   | Use `fzf` instead of `dmenu` for the mode selection prompt |
| `-h`   | Show help |

Running without any option launches a `dmenu` prompt to choose a mode. Pass `-f` to use `fzf` instead — useful on setups without dmenu or when you prefer a terminal picker.

## Modes

### `no-dir`
Launches Claude without mounting any project directories. Useful for general questions, quick tasks, or exploring Claude's capabilities without exposing local files.

### `single-dir`
Opens an `fzf` picker to select one directory from your home tree (up to 3 levels deep). The selected directory is mounted and set as the working directory inside the container.

### `multi-dir`
Opens `fzf` in multi-select mode to pick several directories (use `Tab` to select), then asks you to designate one of them as the working directory. All selected directories are mounted simultaneously — useful when working across multiple repos or sharing common config directories.

## Configuration persistence

Claude's configuration (`~/.claude/` and `~/.claude.json`) is bind-mounted into the container on every run, so your account, settings, and session history survive container restarts.

The mount source is resolved in this order:

1. `$XDG_CONFIG_HOME/claude/` — if `$XDG_CONFIG_HOME` is set
2. `$HOME/` — fallback

## Configuration variables

The following environment variables can be set to override defaults without editing the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_IMAGE` | `claude-cli:latest` | Docker image name to use |
| `NOTIFY_ERROR_ICON` | `$XDG_CONFIG_HOME/dunst/critical.png` | Icon used in desktop error notifications |

Example:

```sh
CLAUDE_IMAGE=my-claude:dev claude-cli
```

## How it works

On first run (or after `-b`), the script builds a Docker image based on `node:lts` with `@anthropic-ai/claude-code` installed globally. The container user is created with the same UID/GID as the host user to avoid file permission issues on bind-mounted volumes.

The image is tagged `claude-cli:latest` and reused on subsequent runs until you explicitly rebuild with `-b`.
