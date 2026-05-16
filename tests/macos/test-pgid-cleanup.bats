#!/usr/bin/env bats
# Integration test: graceful SIGTERM to the macOS wrapper reaps the child
# tree via the setpgid + bash-trap path, plus exit-code and arg-forwarding
# contracts.
#
# Unlike Linux, the macOS wrapper has NO CLAUDE_JOBBED_FORCE_FALLBACK
# toggle: there is a single path (setpgid + trap + out-of-process
# watchdog), always armed. So this file just drives that one path. The
# SIGKILL-of-wrapper case (where the trap canNOT fire and only the
# watchdog saves the tree) is the MEDIUM proof and lives in
# test-honesty.bats, alongside the negative test that pins the ceiling.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WRAPPER="$REPO_ROOT/tools/macos/claude-jobbed.sh"
    [ -x "$WRAPPER" ] || chmod +x "$WRAPPER"
    [ -x "$REPO_ROOT/tools/macos/find-claude.sh" ] || chmod +x "$REPO_ROOT/tools/macos/find-claude.sh"

    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/csc-pgid.XXXXXX")"
    ORIG_PATH="$PATH"

    # Fake claude: spawn a long-lived sleep child whose PID we can probe.
    # `set -m` in the wrapper gives this fake its own process group, and
    # the sleep stays in that group, so a group-directed kill reaps both.
    cat > "$SANDBOX/claude" <<FAKE
#!/usr/bin/env bash
sleep 60 &
echo \$! > "$SANDBOX/grandchild.pid"
wait
FAKE
    chmod +x "$SANDBOX/claude"
    export PATH="$SANDBOX:$PATH"
}

teardown() {
    if [ -f "$SANDBOX/grandchild.pid" ]; then
        local gc; gc="$(cat "$SANDBOX/grandchild.pid" 2>/dev/null || echo)"
        [ -n "$gc" ] && kill -KILL "$gc" 2>/dev/null || true
    fi
    export PATH="$ORIG_PATH"
    rm -rf "$SANDBOX"
}

@test "claude-jobbed(macos): SIGTERM to wrapper reaps child tree (trap path)" {
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

    # SIGTERM the wrapper -- the EXIT/TERM trap fires cleanup() which
    # SIGTERMs the child group, waits 500ms, then SIGKILLs stragglers.
    kill -TERM "$wrapper_pid"

    # Grace is 500ms + scheduling slack; poll up to 3s.
    i=0
    while kill -0 "$gc_pid" 2>/dev/null && [ $i -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    if kill -0 "$gc_pid" 2>/dev/null; then
        kill -KILL "$gc_pid" 2>/dev/null || true
        printf 'FAIL: grandchild PID %s survived wrapper SIGTERM\n' "$gc_pid" >&2
        return 1
    fi
}

@test "claude-jobbed(macos): graceful child exit propagates exit code" {
    cat > "$SANDBOX/claude" <<'FAKE'
#!/usr/bin/env bash
exit 42
FAKE
    chmod +x "$SANDBOX/claude"

    run "$WRAPPER"
    [ "$status" -eq 42 ]
}

@test "claude-jobbed(macos): forwards args verbatim" {
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
