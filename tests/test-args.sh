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

if [ "$fails" -eq 0 ]; then
	echo "All tests passed."
	exit 0
fi
echo "$fails test(s) failed."
exit 1
