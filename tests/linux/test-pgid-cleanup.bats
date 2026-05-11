#!/usr/bin/env bats
# Integration test: graceful SIGTERM to the wrapper reaps the child tree
# via the setpgid+trap fallback path.
#
# Forces fallback path via CLAUDE_JOBBED_FORCE_FALLBACK=1 so we exercise
# this code even on a CI runner that has systemd-run available.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WRAPPER="$REPO_ROOT/tools/linux/claude-jobbed.sh"
    [ -x "$WRAPPER" ] || chmod +x "$WRAPPER"
    [ -x "$REPO_ROOT/tools/linux/find-claude.sh" ] || chmod +x "$REPO_ROOT/tools/linux/find-claude.sh"

    SANDBOX="$(mktemp -d)"
    ORIG_PATH="$PATH"

    # Fake claude: spawn a long-lived sleep child whose PID we can probe.
    # Writes its grandchild PID to a known file so the test can poll it.
    cat > "$SANDBOX/claude" <<FAKE
#!/usr/bin/env bash
sleep 60 &
echo \$! > "$SANDBOX/grandchild.pid"
wait
FAKE
    chmod +x "$SANDBOX/claude"
    export PATH="$SANDBOX:$PATH"
    export CLAUDE_JOBBED_FORCE_FALLBACK=1
}

teardown() {
    # Kill anything we spawned that might have leaked. Best-effort.
    if [ -f "$SANDBOX/grandchild.pid" ]; then
        local gc; gc="$(cat "$SANDBOX/grandchild.pid" 2>/dev/null || echo)"
        [ -n "$gc" ] && kill -KILL "$gc" 2>/dev/null || true
    fi
    export PATH="$ORIG_PATH"
    unset CLAUDE_JOBBED_FORCE_FALLBACK
    rm -rf "$SANDBOX"
}

@test "claude-jobbed (fallback): SIGTERM to wrapper reaps child tree" {
    # Launch wrapper in background, capture its PID.
    "$WRAPPER" &
    local wrapper_pid=$!

    # Wait up to 3s for the fake claude to write the grandchild PID.
    local i=0
    while [ ! -s "$SANDBOX/grandchild.pid" ] && [ $i -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -s "$SANDBOX/grandchild.pid" ]
    local gc_pid; gc_pid="$(cat "$SANDBOX/grandchild.pid")"

    # Sanity: grandchild is alive before we kill the wrapper.
    kill -0 "$gc_pid"

    # Send SIGTERM to wrapper -- trap should fire and reap the pgid.
    kill -TERM "$wrapper_pid"

    # Wait up to 3s for grandchild to die. fallback grace = 500ms + slack.
    i=0
    while kill -0 "$gc_pid" 2>/dev/null && [ $i -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    # Assert grandchild is gone.
    if kill -0 "$gc_pid" 2>/dev/null; then
        # Cleanup before failing so we don't leak across tests.
        kill -KILL "$gc_pid" 2>/dev/null || true
        printf 'FAIL: grandchild PID %s survived wrapper SIGTERM\n' "$gc_pid" >&2
        return 1
    fi
}

@test "claude-jobbed (fallback): graceful child exit propagates exit code" {
    # Replace fake claude with one that exits 42 immediately.
    cat > "$SANDBOX/claude" <<'FAKE'
#!/usr/bin/env bash
exit 42
FAKE
    chmod +x "$SANDBOX/claude"

    run "$WRAPPER"
    [ "$status" -eq 42 ]
}

@test "claude-jobbed (fallback): forwards args verbatim" {
    cat > "$SANDBOX/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@"
FAKE
    chmod +x "$SANDBOX/claude"

    run "$WRAPPER" --version --foo "bar baz"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--version" ]
    [ "${lines[1]}" = "--foo" ]
    [ "${lines[2]}" = "bar baz" ]
}
