#!/usr/bin/env bats
# Integration test: SIGKILL of the wrapper still reaps the child tree
# via the systemd transient scope (cgroup.kill) strong path.
#
# This is the critical behavioral test: bash traps don't fire on SIGKILL,
# so only kernel-enforced cleanup can satisfy this case. If this test
# passes, we have parity with the Win32 KILL_ON_JOB_CLOSE guarantee.
#
# Skips cleanly when systemd-run / systemctl --user are unavailable
# (containers without systemd, WSL1, minimal images). The fallback
# behavior on those systems is exercised by test-pgid-cleanup.bats.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WRAPPER="$REPO_ROOT/tools/linux/claude-jobbed.sh"
    [ -x "$WRAPPER" ] || chmod +x "$WRAPPER"
    [ -x "$REPO_ROOT/tools/linux/find-claude.sh" ] || chmod +x "$REPO_ROOT/tools/linux/find-claude.sh"

    # Skip if systemd-run isn't installed.
    if ! command -v systemd-run >/dev/null 2>&1; then
        skip "systemd-run not available -- fallback path covered by test-pgid-cleanup.bats"
    fi
    # Skip if --user systemd isn't running (e.g., GitHub Actions default
    # ubuntu-latest sometimes lacks an active --user instance for the
    # runner user; the strong-path check requires it).
    if ! systemctl --user is-active default.target >/dev/null 2>&1; then
        skip "systemctl --user not active in this environment -- run linger setup first"
    fi
    # Skip on kernel < 5.14 (cgroup.kill not available).
    local k; k="$(uname -r | cut -d. -f1-2)"
    if ! printf '%s\n5.14\n' "$k" | sort -V -C 2>/dev/null; then
        skip "kernel $k below 5.14 -- cgroup.kill unavailable"
    fi

    SANDBOX="$(mktemp -d)"
    ORIG_PATH="$PATH"

    cat > "$SANDBOX/claude" <<FAKE
#!/usr/bin/env bash
sleep 60 &
echo \$! > "$SANDBOX/grandchild.pid"
wait
FAKE
    chmod +x "$SANDBOX/claude"
    export PATH="$SANDBOX:$PATH"
    # Make sure we DO NOT force fallback -- we want the strong path here.
    unset CLAUDE_JOBBED_FORCE_FALLBACK
}

teardown() {
    if [ -f "$SANDBOX/grandchild.pid" ]; then
        local gc; gc="$(cat "$SANDBOX/grandchild.pid" 2>/dev/null || echo)"
        [ -n "$gc" ] && kill -KILL "$gc" 2>/dev/null || true
    fi
    export PATH="$ORIG_PATH"
    rm -rf "$SANDBOX"
}

@test "claude-jobbed (strong): SIGKILL of wrapper still reaps via cgroup.kill" {
    "$WRAPPER" &
    local wrapper_pid=$!

    local i=0
    while [ ! -s "$SANDBOX/grandchild.pid" ] && [ $i -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -s "$SANDBOX/grandchild.pid" ]
    local gc_pid; gc_pid="$(cat "$SANDBOX/grandchild.pid")"

    kill -0 "$gc_pid"

    # SIGKILL the wrapper -- bypasses any bash trap. Only systemd's
    # scope cleanup (cgroup.kill) can save us here.
    kill -KILL "$wrapper_pid"

    # systemd cleanup is fast but not instant; allow up to 5s.
    i=0
    while kill -0 "$gc_pid" 2>/dev/null && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    if kill -0 "$gc_pid" 2>/dev/null; then
        kill -KILL "$gc_pid" 2>/dev/null || true
        printf 'FAIL: grandchild PID %s survived wrapper SIGKILL (cgroup.kill did not reap)\n' "$gc_pid" >&2
        return 1
    fi
}
