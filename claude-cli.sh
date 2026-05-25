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

	[ -d /tmp/.claude-cli-dockerfile ] && rm -rf /tmp/.claude-cli-dockerfile
}

send_notification() {
	notify-send -i "$NOTIFY_ERROR_ICON" \
		"claude-cli" "$1"
}

check_prerequisite() {
	if ! eval "$1" >/dev/null 2>&1; then
		msg="$(printf "Error: prerequisite failed: %s" "$1")"
		printf "%s\n" "$msg" >&2
		send_notification "$msg"
		exit 127
	fi
}

build_image() {
	if docker image inspect "$CLAUDE_IMAGE" >/dev/null 2>&1; then
		docker image rm "$CLAUDE_IMAGE"
	fi

	mkdir -p /tmp/.claude-cli-dockerfile
	cat > /tmp/.claude-cli-dockerfile/Dockerfile <<'EOF'
FROM node:lts
ARG uid=1000
ARG gid=1000
RUN groupmod -g $gid -n claude node && \
    usermod -u $uid -l claude -d /home/claude -m node
RUN npm install -g @anthropic-ai/claude-code
USER claude
ENTRYPOINT ["claude"]
EOF

	if ! docker buildx build \
		--build-arg uid="$(id -u)" \
		--build-arg gid="$(id -g)" \
		-t "$CLAUDE_IMAGE" -f /tmp/.claude-cli-dockerfile/Dockerfile .; then
		msg="$(printf "Error: image build error!")"
		printf "%s\n" "$msg" >&2
		send_notification "$msg"
		cleanup
		exit 1
	fi

	[ -d /tmp/.claude-cli-dockerfile ] && rm -rf /tmp/.claude-cli-dockerfile
}

while getopts "bhcf" opt; do
	case "$opt" in
		b) build_image; exit 0 ;;
		h) show_help; exit 0 ;;
		c) cleanup; exit 0 ;;
		f) USE_FZF=1 ;;
		*) exit 1 ;;
	esac
done

check_prerequisite "id -nG | grep -qw docker"
check_prerequisite "command -v docker"
[ "$USE_FZF" = "0" ] && check_prerequisite "command -v dmenu"
check_prerequisite "command -v fzf"
check_prerequisite "docker buildx version"

if ! docker image inspect "$CLAUDE_IMAGE" >/dev/null 2>&1; then
	echo "Claude image does not exist!"
	echo "Building now..."
	build_image
fi

if [ "$USE_FZF" = "1" ]; then
	mode=$(printf "no-dir\nsingle-dir\nmulti-dir" | fzf --prompt "Run claude-cli: ")
else
	mode=$(printf "no-dir\nsingle-dir\nmulti-dir" | dmenu -i -c -l 3 -p "Run claude-cli:")
fi
[ -z "$mode" ] && exit 0

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

case "$mode" in
	no-dir)
		docker run \
			-it \
			--rm \
			-v "$CLAUDE_BASEDIR/.claude:/home/claude/.claude" \
			-v "$CLAUDE_BASEDIR/.claude.json:/home/claude/.claude.json" \
			-w "/home/claude" \
			--name "claude-cli-$(date +%Y%m%d-%H%M%S)" \
			"$CLAUDE_IMAGE"
		;;
	single-dir)
		DIR=$(find "$HOME" -mindepth 1 -maxdepth 3 -type d | fzf --prompt "Select directory: ")
		[ -z "$DIR" ] && exit 0
		RELDIR="${DIR#$HOME/}"
		docker run \
			-it \
			--rm \
			-v "$CLAUDE_BASEDIR/.claude:/home/claude/.claude" \
			-v "$CLAUDE_BASEDIR/.claude.json:/home/claude/.claude.json" \
			-v "$DIR:/home/claude/$RELDIR" \
			-w "/home/claude/$RELDIR" \
			--name "claude-cli-$(date +%Y%m%d-%H%M%S)" \
			"$CLAUDE_IMAGE"
		;;
	multi-dir)
		DIRS=$(find "$HOME" -mindepth 1 -maxdepth 3 -type d | fzf --prompt "Select directories: " --multi)
		[ -z "$DIRS" ] && exit 0

		WORKDIR=$(printf "%s" "$DIRS" | fzf --prompt "Select working directory: ")
		[ -z "$WORKDIR" ] && exit 0

		VOLUMES=""
		while IFS= read -r dir; do
			RELDIR="${dir#$HOME/}"
			VOLUMES="$VOLUMES -v $dir:/home/claude/$RELDIR"
		done <<EOF
$DIRS
EOF
		RELWORK="${WORKDIR#$HOME/}"
		docker run \
			-it \
			--rm \
			-v "$CLAUDE_BASEDIR/.claude:/home/claude/.claude" \
			-v "$CLAUDE_BASEDIR/.claude.json:/home/claude/.claude.json" \
			$VOLUMES \
			-w "/home/claude/$RELWORK" \
			--name "claude-cli-$(date +%Y%m%d-%H%M%S)" \
			"$CLAUDE_IMAGE"
		;;
	*)
		exit 0
		;;
esac

