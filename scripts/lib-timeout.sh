#!/bin/bash
# Sourced by the signing scripts. run_t <seconds> <command...> runs the command with a hard time limit (perl alarm, because
# macOS has no `timeout`). On a timeout it prints "TIMEOUT after Ns: <command> <subcommand>" (never the arguments, which may
# hold passwords) and returns 124, so a keychain prompt that nobody can answer fails loudly instead of hanging.
run_t() {
  local secs="$1"; shift
  local rc=0
  perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@" || rc=$?
  if [ "$rc" -eq 142 ] || [ "$rc" -eq 124 ]; then
    echo "TIMEOUT after ${secs}s: ${1##*/} ${2:-}" >&2
    return 124
  fi
  return "$rc"
}
