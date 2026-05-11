#!/usr/bin/env bash
# claude-jobbed.sh -- Linux subprocess hygiene wrapper for claude.
#
# Two reaper paths, picked at runtime:
#
#   1. STRONG path: systemd-run --user --scope (kernel-enforced via
#      cgroup.kill, requires kernel >= 5.14, default on every modern
#      distro since Ubuntu 22.04 / Fedora 36 / Debian 12).
#      When the wrapper exits OR is SIGKILL'd OR the box panics, systemd
#      reaps the entire scope. Closest POSIX equivalent of the Win32
#      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE primitive.
#
#   2. FALLBACK path: setpgid + trap on EXIT/INT/TERM/HUP. Works on
#      no-systemd containers, older kernels, WSL1, minimal Alpine.
#      CAVEAT: does NOT survive SIGKILL of the wrapper itself --
#      bash traps don't fire on -9. README documents this honestly.
#
# Path selection:
#   - If systemd-run is available AND systemctl --user is healthy
#     AND CLAUDE_JOBBED_FORCE_FALLBACK is unset, take strong path.
#   - Otherwise take fallback path.
#
# CLAUDE_JOBBED_FORCE_FALLBACK=1 is the test escape hatch -- lets us
# exercise the fallback code on a systemd-equipped CI runner.
#
# Usage (matches Windows wrapper):
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

# --- decide which path to take --------------------------------------------

use_strong_path() {
    [ -z "${CLAUDE_JOBBED_FORCE_FALLBACK:-}" ] || return 1
    command -v systemd-run >/dev/null 2>&1 || return 1
    systemctl --user is-active default.target >/dev/null 2>&1 || return 1
    return 0
}

# --- strong path: systemd transient scope + watchdog ----------------------
#
# Why a watchdog: `systemd-run --scope` does NOT auto-stop the scope when
# its controller (us) dies. Quoting systemd.scope(5): "When the last
# process leaves the scope, systemd cleans the scope up." -- meaning scope
# lifetime tracks descendant lifetime, not controller lifetime. So a
# SIGKILL of this wrapper would leave the scope (with claude + descendants)
# orphaned. Bash traps don't fire on SIGKILL either, so we can't tear it
# down from in-process. We need an external supervisor.
#
# The watchdog is a backgrounded subshell that polls our PID via stat -c %Y
# on /proc/$$ (mtime of the procfs entry == process start time, robust to
# PID reuse). When it sees we're gone OR a different process now owns our
# PID, it calls `systemctl --user stop` on the scope, which triggers
# cgroup.kill of every descendant. This is what delivers the SIGKILL-
# survival guarantee documented in the README.

if use_strong_path; then
    unit="claude-jobbed-$$.scope"
    parent_pid=$$
    parent_birth="$(stat -c %Y "/proc/$parent_pid" 2>/dev/null || echo 0)"

    # Watchdog: ignore inherited signals, poll parent identity, stop scope
    # the moment the parent vanishes or the PID is recycled. Disowned so
    # the parent shell's exit doesn't HUP it.
    (
        trap '' INT TERM HUP
        while [ "$(stat -c %Y "/proc/$parent_pid" 2>/dev/null || echo 0)" = "$parent_birth" ] && [ "$parent_birth" != "0" ]; do
            sleep 0.2
        done
        systemctl --user stop "$unit" >/dev/null 2>&1 || true
    ) &
    watchdog_pid=$!
    disown "$watchdog_pid" 2>/dev/null || true

    # Graceful-exit cleanup: stop the scope ourselves so cgroup.kill fires
    # without waiting on the watchdog's poll interval, then take the
    # watchdog out so it doesn't fire a second (no-op) stop after we exit.
    cleanup_strong() {
        kill "$watchdog_pid" 2>/dev/null || true
        systemctl --user stop "$unit" >/dev/null 2>&1 || true
    }
    trap cleanup_strong EXIT INT TERM HUP

    # Run systemd-run in foreground; --scope mode keeps stdin/stdout/stderr
    # wired through and propagates exit code. set -e is off around it so
    # a non-zero claude exit doesn't trigger our trap before we capture.
    set +e
    systemd-run \
        --user \
        --scope \
        --quiet \
        --slice=claude-code.slice \
        --unit="$unit" \
        -- "$claude_path" "$@"
    exit_code=$?
    set -e

    trap - EXIT
    kill "$watchdog_pid" 2>/dev/null || true
    exit "$exit_code"
fi

# --- fallback path: setpgid + trap ---------------------------------------
#
# `set -m` enables job control so a backgrounded child gets its OWN
# process group (pgid == its own pid). Without -m, the child stays in the
# wrapper's pgid and `kill -- -$pgid` would also signal the wrapper itself.

set -m

child_pgid=

cleanup() {
    if [ -n "${child_pgid:-}" ]; then
        # Negative PID = entire process group. SIGTERM first (graceful),
        # 500ms grace, then SIGKILL anything that didn't honor TERM.
        kill -TERM "-$child_pgid" 2>/dev/null || true
        sleep 0.5
        kill -KILL "-$child_pgid" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM HUP

"$claude_path" "$@" &
child_pid=$!
child_pgid=$child_pid   # set -m guarantees pgid == pid for bg jobs

# `wait` returns the child's exit code, OR 128+signal if interrupted.
# Disable -e around wait so a non-zero claude exit doesn't trigger
# our own EXIT before we capture the code.
set +e
wait "$child_pid"
exit_code=$?
set -e

# Skip the EXIT trap re-running cleanup (we already waited cleanly).
trap - EXIT
cleanup   # one explicit pass for safety -- idempotent
exit "$exit_code"
