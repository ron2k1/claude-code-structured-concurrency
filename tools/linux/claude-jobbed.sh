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

# --- strong path: systemd transient scope ---------------------------------
#
# --user           : runs in the per-user systemd instance (no root needed)
# --scope          : transient unit type that runs in OUR shell, not a
#                    detached service -- so stdin/stdout/stderr stay wired
#                    and exit code propagates cleanly.
# --slice=         : groups all claude-code processes under one slice for
#                    `systemctl --user status claude-code.slice` visibility.
# --quiet          : suppresses the systemd "Running scope as unit" notice.
# --unit=          : per-PID name keeps concurrent wrappers from colliding.

if use_strong_path; then
    exec systemd-run \
        --user \
        --scope \
        --quiet \
        --slice=claude-code.slice \
        --unit="claude-jobbed-$$.scope" \
        -- "$claude_path" "$@"
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
