#!/bin/sh
# Regression tests for claude-cli.sh argument parsing.
#
# Sources the real script (CLAUDE_CLI_SOURCE_ONLY) and calls parse_args()
# directly, so behavior is asserted against the actual code with no duplicated
# parsing logic. parse_args() only sets variables and never touches Docker.
#
# Usage: sh tests/test-args.sh

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
CLAUDE_CLI_SOURCE_ONLY=1
. "$ROOT/claude-cli.sh"
set -u

fails=0
errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT

# run <args...>: invoke parse_args, capturing RC and ERR (its globals persist).
run() {
	parse_args "$@" 2>"$errfile" >/dev/null
	RC=$?
	ERR=$(cat "$errfile")
}

# eq <label> <actual> <expected>
eq() {
	if [ "$2" = "$3" ]; then
		printf 'PASS  %s\n' "$1"
	else
		printf 'FAIL  %s: got [%s] want [%s]\n' "$1" "$2" "$3"
		fails=$((fails + 1))
	fi
}

# contains <label> <haystack> <needle>
contains() {
	case "$2" in
		*"$3"*) printf 'PASS  %s\n' "$1" ;;
		*) printf 'FAIL  %s: [%s] missing [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)) ;;
	esac
}

# action flags reject directory arguments
run -b /tmp
eq       "-b /tmp rc"  "$RC" "1"
contains "-b /tmp err" "$ERR" "take no directory arguments"

run -c /tmp
eq "-c /tmp rc" "$RC" "1"

# -h requests help and wins even with extra arguments (dispatch happens in main)
run -h
eq "-h rc"     "$RC" "0"
eq "-h action" "$action" "show_help"

run -h foo
eq "-h foo rc"     "$RC" "0"
eq "-h foo action" "$action" "show_help"

# unknown option
run -z
eq "-z rc" "$RC" "1"

# single directory argument => single-dir mode
run /home/user/app
eq "single mode" "$mode" "single-dir"
eq "single DIR"  "$DIR"  "/home/user/app"

# multiple directory arguments => multi-dir, first is the working dir
run /a /b /c
eq "multi mode"    "$mode"    "multi-dir"
eq "multi WORKDIR" "$WORKDIR" "/a"

# -f sets fzf and still parses the trailing directory
run -f /home/user/app
eq "-f USE_FZF" "$USE_FZF" "1"
eq "-f mode"    "$mode"    "single-dir"

# --- build_mounts ------------------------------------------------------------
# CLAUDE_CLI_MOUNTS is a colon-separated list of verbatim Docker --mount specs.

# unset variable => no mounts
unset CLAUDE_CLI_MOUNTS
build_mounts
eq "no var => empty" "$CLAUDE_MOUNTS" ""

# a single spec becomes one --mount flag, passed through verbatim
CLAUDE_CLI_MOUNTS="type=bind,src=/home,dst=/home/claude/user_home,readonly"
build_mounts
eq "single spec" "$CLAUDE_MOUNTS" " --mount type=bind,src=/home,dst=/home/claude/user_home,readonly"

# colon separates multiple specs; each becomes its own --mount flag
CLAUDE_CLI_MOUNTS="type=bind,src=./cfg,dst=/tmp/cfg:type=bind,src=/opt/x,dst=/opt/x"
build_mounts
contains "multi spec a" "$CLAUDE_MOUNTS" "--mount type=bind,src=./cfg,dst=/tmp/cfg"
contains "multi spec b" "$CLAUDE_MOUNTS" "--mount type=bind,src=/opt/x,dst=/opt/x"

# empty entries (e.g. a trailing colon) are skipped
CLAUDE_CLI_MOUNTS="type=bind,src=/a,dst=/a:"
build_mounts
eq "trailing colon skipped" "$CLAUDE_MOUNTS" " --mount type=bind,src=/a,dst=/a"

# --- build_image / CLAUDE_CLI_PULL -------------------------------------------
# build_image only passes --pull to buildx when CLAUDE_CLI_PULL is non-empty.
# A stub docker on PATH records its arguments so no daemon is needed.

stubdir=$(mktemp -d)
trap 'rm -f "$errfile"; rm -rf "$stubdir"' EXIT
cat > "$stubdir/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
# "docker image inspect" reports the image as missing; everything else succeeds.
[ "$1" = "image" ] && exit 1
exit 0
EOF
chmod +x "$stubdir/docker"
printf 'FROM scratch\n' > "$stubdir/Dockerfile"
PATH="$stubdir:$PATH"
CLAUDE_CLI_DOCKERFILE="$stubdir/Dockerfile"
export DOCKER_LOG

# buildx_has_pull: run build_image with a fresh log, set to 1 if --pull was
# passed to "docker buildx build".
buildx_has_pull() {
	DOCKER_LOG="$stubdir/docker.log"
	: > "$DOCKER_LOG"
	build_image >/dev/null 2>&1
	case "$(grep '^buildx build' "$DOCKER_LOG")" in
		*--pull*) buildx_has_pull=1 ;;
		*) buildx_has_pull=0 ;;
	esac
}

unset CLAUDE_CLI_PULL
buildx_has_pull
eq "unset CLAUDE_CLI_PULL => no --pull" "$buildx_has_pull" "0"

CLAUDE_CLI_PULL=""
buildx_has_pull
eq "empty CLAUDE_CLI_PULL => no --pull" "$buildx_has_pull" "0"

CLAUDE_CLI_PULL=1
buildx_has_pull
eq "CLAUDE_CLI_PULL=1 => --pull" "$buildx_has_pull" "1"

if [ "$fails" -eq 0 ]; then
	echo "All tests passed."
	exit 0
fi
echo "$fails test(s) failed."
exit 1
