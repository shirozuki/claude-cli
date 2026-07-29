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
claude-cli [-b] [-c] [-f] [-h] [DIR...]
```

| Option | Description |
|--------|-------------|
| `-b`   | Build (or rebuild) the `claude-cli:latest` Docker image |
| `-c`   | Remove all `claude-cli` containers; optionally remove the image |
| `-f`   | Use `fzf` instead of `dmenu` for the mode selection prompt |
| `-h`   | Show help |

Running without any option or argument launches a `dmenu` prompt to choose a mode. Pass `-f` to use `fzf` instead — useful on setups without dmenu or when you prefer a terminal picker.

### Passing directories as arguments

You can skip the menu and pickers entirely by passing directories directly on the command line:

```sh
claude-cli ~/projects/app            # single-dir mode
claude-cli ~/projects/app ~/shared   # multi-dir mode (first arg is the working dir)
```

- One argument runs `single-dir` mode with that directory.
- Two or more arguments run `multi-dir` mode, mounting every directory and using the **first** as the working directory.

Relative paths are resolved against the current working directory, so `claude-cli .` mounts `$PWD`. When directories are passed this way, `dmenu` and `fzf` are not required.

## Modes

### `no-dir`
Launches Claude without mounting any project directories. Useful for general questions, quick tasks, or exploring Claude's capabilities without exposing local files.

### `current-dir`
Mounts the current working directory $PWD directly.

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
| `CLAUDE_CLI_FLAGS` | (none) | Extra flags passed through to the `claude` binary inside the container |
| `CLAUDE_CLI_DOCKERFILE` | (see below) | Path to a custom Dockerfile used to build the image (highest precedence). |
| `CLAUDE_CLI_MOUNTS` | (none) | Colon-separated Docker `--mount` specs to add to the container (see below). |
| `CLAUDE_CLI_PULL` | (off) | If set to a non-empty value, `-b` re-pulls the base image of every `FROM` line before building, instead of using locally cached bases. |

Examples:

```sh
CLAUDE_IMAGE=my-claude:dev claude-cli

# Pass flags through to Claude Code itself
CLAUDE_CLI_FLAGS="--resume $session_id --dangerously-skip-permissions" claude-cli

# Build the image from a custom Dockerfile
CLAUDE_CLI_DOCKERFILE=~/my-claude.dockerfile claude-cli -b

# Mount extra config into the container (e.g. the GitHub CLI's config)
CLAUDE_CLI_MOUNTS="type=bind,src=$HOME/.config/gh,dst=/home/claude/.config/gh" claude-cli

# Rebuild the image with freshly pulled base images
CLAUDE_CLI_PULL=1 claude-cli -b
```

### Mounting additional paths

`CLAUDE_CLI_MOUNTS` is a colon-separated list of Docker
[`--mount`](https://docs.docker.com/engine/storage/bind-mounts/) specifications.
Each colon-separated entry is passed through to `docker run` verbatim as one
`--mount <spec>`, giving you the full `--mount` syntax (bind mounts, `readonly`,
etc.). This is handy for tools that read their own config from your home
directory — for example, mounting `$HOME/.config/gh` (see below: avoid `~`)
This will allow for features like `/install-github-app` to work inside the container.

A colon is a safe separator between entries because Docker's `--mount` syntax is
a set of comma-separated `key=value` pairs and never contains a colon. Notes on
the fields:

- `src=` / `source=` may be relative to the current directory (e.g. `./foo`).
  `~` is **not** expanded by Docker, so spell out full paths (use `$HOME/...`).
- `dst=` / `destination=` / `target=` must be an **absolute** path.

Specs are handed straight to `docker run`, which validates them and fails the
run if, for example, a bind source does not exist. The variable is entirely
optional.

Examples:

```sh
# Mount your host home read-only for reference
CLAUDE_CLI_MOUNTS='type=bind,src=/home,dst=/home/claude/user_home,readonly' claude-cli

# Mount a config directory using a path relative to the current directory
CLAUDE_CLI_MOUNTS='type=bind,src=./.config/waybar,dst=/tmp/waybar' claude-cli

# Multiple mounts, separated by a colon. The first mount is relative and read only (,ro)
CLAUDE_CLI_MOUNTS='type=bind,src=../repos/ref,dst=/home/claude/ref,ro:type=bind,src=/opt/file,dst=/opt/file' claude-cli
```

`CLAUDE_CLI_FLAGS` is word-split, so each space-separated token becomes a
separate argument. Quote arguments that contain spaces is not supported — pass
only flags whose values have no spaces.

## How it works

On first run (or after `-b`), the script builds a Docker image based on `node:lts` with `@anthropic-ai/claude-code` installed globally. The container user is created with the same UID/GID as the host user to avoid file permission issues on bind-mounted volumes.

The Dockerfile is selected in order of precedence:

1. Custom Dockerfile path (`CLAUDE_CLI_DOCKERFILE`)
2. Dockerfile next to the script (`claude-cli-dockerfile`)
3. Inline Dockerfile baked into the script (the default)

The customization is purely additive: with none of the above set, the script writes its built-in Dockerfile to `/tmp` and builds from that, so `claude-cli.sh` stays self-contained and can be fetched and run entirely on its own.

To customize the image, drop a `claude-cli-dockerfile` next to the script and it will be preferred when present:

```sh
# create claude-cli-dockerfile to taste, then rebuild
claude-cli -b
```

Alternatively, point `CLAUDE_CLI_DOCKERFILE` at a Dockerfile anywhere on disk.

The image is tagged `claude-cli:latest` and reused on subsequent runs until you explicitly rebuild with `-b`.
