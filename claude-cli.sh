#!/bin/sh

NOTIFY_ERROR_ICON="${NOTIFY_ERROR_ICON:-$XDG_CONFIG_HOME/dunst/critical.png}"
CLAUDE_IMAGE="${CLAUDE_IMAGE:-claude-cli:latest}"
USE_FZF=0

show_help() {
	printf '%s\n' \
		"Usage: $(basename "$0") [-b] [-c] [-f] [-h]" \
		"" \
		"Run Claude Code (claude-cli:latest) inside a Docker container." \
		"" \
		"Options:" \
		"  -b    Build the Docker image (rebuilds if it already exists)" \
		"  -c    Clean up: remove all claude-cli containers and optionally the image" \
		"  -f    Use fzf instead of dmenu to select the run mode" \
		"  -h    Show this help message" \
		"" \
		"If no option is given, a dmenu prompt lets you choose a run mode:" \
		"  no-dir       Run Claude without mounting any project directories" \
		"  current-dir  Mount the current working directory as the working dir" \
		"  single-dir   Select one directory via fzf and mount it as the working dir" \
		"  multi-dir    Select multiple directories via fzf, then pick the working dir" \
		"" \
		"Claude config (~/.claude and ~/.claude.json) is persisted across runs via" \
		"bind mounts from \$XDG_CONFIG_HOME/claude or \$HOME." \
		"" \
		"Prerequisites: docker, docker buildx, dmenu, fzf, user in the docker group"
	exit 0
}

cleanup() {
	docker ps -aq --filter "name=claude-cli-" | xargs -r docker rm -f

	if docker image inspect "$CLAUDE_IMAGE" >/dev/null 2>&1; then
		printf "Remove $CLAUDE_IMAGE image? [y/N] "
		read -r answer

		if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
			docker image rm "$CLAUDE_IMAGE"
		fi
	fi
}

send_notification() {
	notify-send -i "$NOTIFY_ERROR_ICON" \
		"claude-cli" "$1"
}

check_prerequisite() {
	if ! eval "$1" >/dev/null 2>&1; then
		msg="$(printf "Error: prerequisite failed: %s" "$1")"
		printf "%s\n" "$msg" >&2
		command -v notify-send && send_notification "$msg"
		exit 127
	fi
}

build_image() {
	if docker image inspect "$CLAUDE_IMAGE" >/dev/null 2>&1; then
		docker image rm "$CLAUDE_IMAGE"
	fi

	# Dockerfile selection, in order of precedence:
	#   1. Custom Dockerfile path (CLAUDE_CLI_DOCKERFILE)
	#   2. Dockerfile next to the script (claude-cli-dockerfile)
	#   3. Inline Dockerfile baked into this script, written to /tmp
	# The inline fallback keeps the script self-contained, so it can be
	# fetched and run on its own with no extra files alongside it.
	dir="$(dirname "$(realpath "$0")")"
	cleanup_tmp=0
	if [ -n "${CLAUDE_CLI_DOCKERFILE:-}" ]; then
		dockerfile="$CLAUDE_CLI_DOCKERFILE"
	elif [ -f "$dir/claude-cli-dockerfile" ]; then
		dockerfile="$dir/claude-cli-dockerfile"
	else
		mkdir -p /tmp/.claude-cli-dockerfile
		dockerfile=/tmp/.claude-cli-dockerfile/Dockerfile
		cat > "$dockerfile" <<'EOF'
FROM node:lts
ARG uid=1000
ARG gid=1000
ENV NPM_CONFIG_PREFIX=/home/claude/.npm
ENV PATH=/home/claude/.npm/bin:$PATH
RUN groupmod -g $gid -n claude node && \
    usermod -u $uid -l claude -d /home/claude -m node
USER claude
RUN npm install -g @anthropic-ai/claude-code
ENTRYPOINT ["claude"]
EOF
		cleanup_tmp=1
	fi
	if [ ! -f "$dockerfile" ]; then
		msg="$(printf "Error: Dockerfile not found: %s" "$dockerfile")"
		printf "%s\n" "$msg" >&2
		command -v notify-send && send_notification "$msg"
		exit 1
	fi

	if ! docker buildx build \
		--build-arg uid="$(id -u)" \
		--build-arg gid="$(id -g)" \
		-t "$CLAUDE_IMAGE" -f "$dockerfile" "$(dirname "$dockerfile")"; then
		msg="$(printf "Error: image build error!")"
		printf "%s\n" "$msg" >&2
		command -v notify-send && send_notification "$msg"
		[ "$cleanup_tmp" = "1" ] && rm -rf /tmp/.claude-cli-dockerfile
		cleanup
		exit 1
	fi

	[ "$cleanup_tmp" = "1" ] && rm -rf /tmp/.claude-cli-dockerfile
}

# Parse options and directory arguments, setting: action, USE_FZF, mode, DIR,
# DIRS, WORKDIR. Returns non-zero (and prints to stderr) on a usage error.
parse_args() {
	USE_FZF=0
	action=""
	mode=""
	DIR=""
	DIRS=""
	WORKDIR=""
	OPTIND=1

	while getopts "bhcf" opt; do
		case "$opt" in
			b) action=build_image ;;
			h) action=show_help ;;
			c) action=cleanup ;;
			f) USE_FZF=1 ;;
			*) return 1 ;;
		esac
	done
	shift $((OPTIND - 1))

	# -h always wins and prints help, even with extra arguments. -b/-c are
	# standalone actions and reject stray directory arguments.
	if [ -n "$action" ]; then
		if [ "$action" != "show_help" ] && [ "$#" -gt 0 ]; then
			echo "Error: -b and -c take no directory arguments" >&2
			return 1
		fi
		return 0
	fi

	# DIR args bypass the menu: one => single-dir, several => multi-dir (first = workdir).
	[ "$#" -eq 1 ] && { mode=single-dir; DIR=$1; }
	[ "$#" -gt 1 ] && { mode=multi-dir; DIRS=$(printf '%s\n' "$@"); WORKDIR=$1; }
	return 0
}

# Build --mount arguments from CLAUDE_CLI_MOUNTS, a colon-separated list of
# Docker --mount specifications that are passed through verbatim. Each
# colon-separated entry becomes one `--mount <spec>` flag, e.g.
#
#   CLAUDE_CLI_MOUNTS='type=bind,src=/home,dst=/home/claude/user_home,readonly'
#   CLAUDE_CLI_MOUNTS='type=bind,src=./cfg,dst=/tmp/cfg:type=bind,src=/x,dst=/x'
#
# ":" is safe as the list separator because Docker's --mount syntax is a set of
# comma-separated key=value pairs and never contains a colon. Field notes:
#   - src=/source= may be relative to the current directory (e.g. ./foo); "~"
#     is NOT expanded, so spell paths out in full.
#   - dst=/destination=/target= must be an absolute path.
# Specs go straight to `docker run`, which validates them and errors on, say, a
# missing bind source. Result is left in CLAUDE_MOUNTS.
build_mounts() {
	CLAUDE_MOUNTS=""
	[ -z "${CLAUDE_CLI_MOUNTS:-}" ] && return 0

	OLDIFS=$IFS
	IFS=':'
	for spec in $CLAUDE_CLI_MOUNTS; do
		[ -z "$spec" ] && continue
		CLAUDE_MOUNTS="$CLAUDE_MOUNTS --mount $spec"
	done
	IFS=$OLDIFS
}

# When sourced for testing, expose the functions above and skip execution.
[ -n "${CLAUDE_CLI_SOURCE_ONLY:-}" ] && return 0

parse_args "$@" || exit 1

if [ -n "$action" ]; then
	"$action"
	exit 0
fi

check_prerequisite "id -nG | grep -qw docker"
check_prerequisite "command -v docker"
if [ -z "$mode" ]; then
	[ "$USE_FZF" = "0" ] && check_prerequisite "command -v dmenu"
	check_prerequisite "command -v fzf"
fi
check_prerequisite "docker buildx version"

if ! docker image inspect "$CLAUDE_IMAGE" >/dev/null 2>&1; then
	echo "Claude image does not exist!"
	echo "Building now..."
	build_image
fi

if [ -z "$mode" ]; then
	if [ "$USE_FZF" = "1" ]; then
		mode=$(printf "no-dir\ncurrent-dir\nsingle-dir\nmulti-dir" | fzf --prompt "Run claude-cli: ")
	else
		mode=$(printf "no-dir\ncurrent-dir\nsingle-dir\nmulti-dir" | dmenu -i -c -l 4 -p "Run claude-cli:")
	fi
	[ -z "$mode" ] && exit 0
fi

if [ -n "$XDG_CONFIG_HOME" ]; then
	base="$XDG_CONFIG_HOME/claude"
	[ -f "$base/.claude.json" ] || { mkdir -p "$base" && touch "$base/.claude.json"; }
	[ -d "$base/.claude" ] || mkdir -p "$base/.claude"
	CLAUDE_BASEDIR="$base"
else
	[ -f "$HOME/.claude.json" ] || touch "$HOME/.claude.json"
	[ -d "$HOME/.claude" ] || mkdir -p "$HOME/.claude"
	CLAUDE_BASEDIR="$HOME"
fi

build_mounts

case "$mode" in
	no-dir)
		docker run \
			-it \
			--rm \
			-v "$CLAUDE_BASEDIR/.claude:/home/claude/.claude" \
			-v "$CLAUDE_BASEDIR/.claude.json:/home/claude/.claude.json" \
			$CLAUDE_MOUNTS \
			-w "/home/claude" \
			--name "claude-cli-$(date +%Y%m%d-%H%M%S)" \
			"$CLAUDE_IMAGE" $CLAUDE_CLI_FLAGS
		;;
	current-dir)
		case "$PWD" in
			"$HOME"/*)
				RELDIR="${PWD#$HOME/}"
				;;
			*)
				RELDIR="$(basename "$PWD")"
				;;
		esac
		docker run \
			-it \
			--rm \
			-v "$CLAUDE_BASEDIR/.claude:/home/claude/.claude" \
			-v "$CLAUDE_BASEDIR/.claude.json:/home/claude/.claude.json" \
			-v "$PWD:/home/claude/$RELDIR" \
			$CLAUDE_MOUNTS \
			-w "/home/claude/$RELDIR" \
			--name "claude-cli-$(date +%Y%m%d-%H%M%S)" \
			"$CLAUDE_IMAGE" $CLAUDE_CLI_FLAGS
		;;
	single-dir)
		[ -z "$DIR" ] && DIR=$(find "$HOME" -mindepth 1 -maxdepth 3 -type d | fzf --prompt "Select directory: ")
		[ -z "$DIR" ] && exit 0
		case "$DIR" in /*) ;; *) DIR="$PWD/$DIR" ;; esac
		RELDIR="${DIR#$HOME/}"
		docker run \
			-it \
			--rm \
			-v "$CLAUDE_BASEDIR/.claude:/home/claude/.claude" \
			-v "$CLAUDE_BASEDIR/.claude.json:/home/claude/.claude.json" \
			-v "$DIR:/home/claude/$RELDIR" \
			$CLAUDE_MOUNTS \
			-w "/home/claude/$RELDIR" \
			--name "claude-cli-$(date +%Y%m%d-%H%M%S)" \
			"$CLAUDE_IMAGE" $CLAUDE_CLI_FLAGS
		;;
	multi-dir)
		[ -z "$DIRS" ] && DIRS=$(find "$HOME" -mindepth 1 -maxdepth 3 -type d | fzf --prompt "Select directories: " --multi)
		[ -z "$DIRS" ] && exit 0

		[ -z "$WORKDIR" ] && WORKDIR=$(printf "%s" "$DIRS" | fzf --prompt "Select working directory: ")
		[ -z "$WORKDIR" ] && exit 0

		VOLUMES=""
		while IFS= read -r dir; do
			case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac
			RELDIR="${dir#$HOME/}"
			VOLUMES="$VOLUMES -v $dir:/home/claude/$RELDIR"
		done <<EOF
$DIRS
EOF
		case "$WORKDIR" in /*) ;; *) WORKDIR="$PWD/$WORKDIR" ;; esac
		RELWORK="${WORKDIR#$HOME/}"
		docker run \
			-it \
			--rm \
			-v "$CLAUDE_BASEDIR/.claude:/home/claude/.claude" \
			-v "$CLAUDE_BASEDIR/.claude.json:/home/claude/.claude.json" \
			$VOLUMES \
			$CLAUDE_MOUNTS \
			-w "/home/claude/$RELWORK" \
			--name "claude-cli-$(date +%Y%m%d-%H%M%S)" \
			"$CLAUDE_IMAGE" $CLAUDE_CLI_FLAGS
		;;
	*)
		exit 0
		;;
esac

