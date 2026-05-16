#!/usr/bin/env bash
# claude-jobbed.sh -- macOS subprocess hygiene wrapper for claude.
#
# macOS is the hard platform. It has none of the three strong primitives
# the other ports lean on:
#   - no Win32 Job Object  (Windows STRONG)
#   - no cgroup.kill       (Linux 5.14+ STRONG)
#   - no PR_SET_PDEATHSIG  (Linux)
# and no /proc, so even the parent-identity trick the Linux strong path
# uses (`stat -c %Y /proc/$$`) is unavailable.
#
# A plain setpgid + trap wrapper -- the Linux FALLBACK shape -- is only
# WEAK on macOS: bash traps never fire on SIGKILL, so an Activity Monitor
# "Force Quit" (or `kill -9`) of the wrapper orphans the whole tree.
#
# We reach MEDIUM by porting the out-of-process watchdog the Linux STRONG
# path introduced (commit cfe7479). The watchdog is a SEPARATE, disowned
# process that polls the wrapper's identity and reaps the child process
# group the instant the wrapper vanishes. Because it is a distinct process,
# a SIGKILL aimed at the wrapper alone no longer escapes cleanup.
#
# Honest ceiling (pinned by tests/macos/test-honesty.bats): a SIMULTANEOUS
# kill -9 of BOTH the wrapper AND the watchdog still leaks. macOS has no
# kernel primitive (cgroup.kill / Job Object) to cover that the way Linux
# and Windows do. MEDIUM, not STRONG -- and the install banner says so.
#
# bash 3.2-safe on purpose: stock macOS /usr/bin/env bash resolves to
# Apple's frozen 3.2.57. No arrays, no [[ =~ ]], no ${x,,}, no mapfile.
#
# Usage (matches the Windows and Linux wrappers):
#   claude-jobbed.sh               # equivalent to plain `claude`
#   claude-jobbed.sh --version     # any args forward transparently
#   claude-jobbed.sh -p "prompt"   # ditto

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=find-claude.sh
. "$here/find-claude.sh"

if ! claude_path="$(find_claude)"; then
    printf 'claude-jobbed: claude not found in PATH or any known install location\n' >&2
    printf '  install Claude Code first (see https://claude.ai/code)\n' >&2
    exit 127
fi

# `set -m` enables job control so every backgrounded job gets its OWN
# process group (pgid == its own pid). This is load-bearing twice:
#   1. the child's group is killable as `-$child_pgid` without also
#      signalling this wrapper, and
#   2. the watchdog lands in a DIFFERENT group than the child, so
#      `kill -- -$child_pgid` never takes the watchdog down with it.
set -m

child_pgid=

# cleanup() is the single source of truth for the kill sequence. Both the
# in-process trap AND the watchdog call it, so the two paths can never
# drift apart. SIGTERM first (graceful), 500ms grace, then SIGKILL the
# stragglers -- identical shape to the Linux fallback's cleanup() so a
# reviewer reading both sees the same contract.
cleanup() {
    if [ -n "${child_pgid:-}" ]; then
        kill -TERM "-$child_pgid" 2>/dev/null || true
        sleep 0.5
        kill -KILL "-$child_pgid" 2>/dev/null || true
    fi
}

# parent_identity: macOS has no /proc, so identity = PID + process start
# time via BSD `ps -o lstart=` (the `=` suppresses the header). A recycled
# PID gets a different start time, so a stale match is impossible except in
# the sub-second window where a new process reuses our exact PID AND starts
# within the same 1-second lstart tick -- the same residual-risk class as
# the Linux /proc-mtime approach (also 1s resolution). Trimmed identically
# on both sides so the comparison can never skew on whitespace padding.
parent_identity() {
    ps -p "$1" -o lstart= 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//' || true
}

trap cleanup EXIT INT TERM HUP

"$claude_path" "$@" &
child_pid=$!
child_pgid=$child_pid   # set -m guarantees pgid == pid for bg jobs

# --- watchdog: external supervisor for the SIGKILL-of-wrapper case -------
#
# Disowned subshell. Ignores the catchable signals (so the parent shell's
# exit doesn't HUP it and a stray TERM can't kill it before its job is
# done), polls the wrapper's identity, and on the wrapper's disappearance
# reaps the child group via the SAME cleanup() defined above (inherited by
# the subshell fork). This is the WEAK -> MEDIUM upgrade.
parent_pid=$$
parent_fp="$(parent_identity "$parent_pid")"

(
    trap '' INT TERM HUP
    while :; do
        now_fp="$(parent_identity "$parent_pid")"
        if [ -z "$now_fp" ] || [ "$now_fp" != "$parent_fp" ]; then
            # Wrapper is gone (or its PID was recycled). Reap and exit.
            cleanup
            exit 0
        fi
        sleep 0.2
    done
) &
watchdog_pid=$!
disown "$watchdog_pid" 2>/dev/null || true

# `wait` returns the child's exit code, OR 128+signal if interrupted.
# Disable -e around it so a non-zero claude exit doesn't trip our own
# EXIT trap before we capture the code.
set +e
wait "$child_pid"
exit_code=$?
set -e

# Graceful path: the wrapper is still alive here, so the watchdog is still
# in its poll loop and has NOT reaped anything. Take it down before it can
# fire a redundant pass. It deliberately ignores catchable signals, so
# only SIGKILL reliably stops it from here -- safe precisely because at
# this point it has done nothing that needs unwinding.
trap - EXIT
kill -KILL "$watchdog_pid" 2>/dev/null || true
cleanup   # one explicit idempotent pass (reaps any lingering grandchild)
exit "$exit_code"
