#!/usr/bin/env bats
# THE honesty test for the macOS port. It exists to make the wrapper's
# guarantee claim falsifiable and to stop it from ever silently drifting
# into a lie.
#
# tools/macos/claude-jobbed.sh claims MEDIUM:
#
#   CASE 1 (we beat WEAK): a SIGKILL of the wrapper ALONE is survived --
#   the disowned, separate-process watchdog notices the wrapper vanish
#   and reaps the child group. A plain setpgid+trap wrapper (no watchdog)
#   would leak here because bash traps never fire on SIGKILL. This test
#   asserts the grandchild DIES.
#
#   CASE 2 (we do NOT claim STRONG): a SIMULTANEOUS SIGKILL of BOTH the
#   wrapper AND the watchdog leaks the tree. macOS has no kernel primitive
#   (cgroup.kill / Job Object) to cover this the way Linux 5.14+ and
#   Windows do. This test asserts the grandchild SURVIVES -- i.e. it pins
#   the honest ceiling. If someone "fixes" this into a pass, they have
#   either added a real kernel primitive (great -- update the guarantee)
#   or, far more likely, written something that does not actually hold.
#   Either way the diff must explain itself.
#
# A negative assertion ("the leak still happens") is unusual on purpose:
# the install banner and DESIGN.md both state this ceiling in words; this
# test is what keeps those words true.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WRAPPER="$REPO_ROOT/tools/macos/claude-jobbed.sh"
    [ -x "$WRAPPER" ] || chmod +x "$WRAPPER"
    [ -x "$REPO_ROOT/tools/macos/find-claude.sh" ] || chmod +x "$REPO_ROOT/tools/macos/find-claude.sh"

    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/csc-honesty.XXXXXX")"
    ORIG_PATH="$PATH"

    cat > "$SANDBOX/claude" <<FAKE
#!/usr/bin/env bash
sleep 60 &
echo \$! > "$SANDBOX/grandchild.pid"
wait
FAKE
    chmod +x "$SANDBOX/claude"
    export PATH="$SANDBOX:$PATH"
    : > "$SANDBOX/cleanup.pids"
}

teardown() {
    # Best-effort net. Case 2 deliberately leaves a live tree; kill
    # everything we ever recorded plus the grandchild file.
    if [ -f "$SANDBOX/cleanup.pids" ]; then
        local p
        while read -r p; do
            [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
        done < "$SANDBOX/cleanup.pids"
    fi
    if [ -f "$SANDBOX/grandchild.pid" ]; then
        local gc; gc="$(cat "$SANDBOX/grandchild.pid" 2>/dev/null || echo)"
        [ -n "$gc" ] && kill -KILL "$gc" 2>/dev/null || true
    fi
    export PATH="$ORIG_PATH"
    rm -rf "$SANDBOX"
}

# Wait for the fake claude to publish its grandchild PID; echo it.
_await_grandchild() {
    local i=0
    while [ ! -s "$SANDBOX/grandchild.pid" ] && [ $i -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -s "$SANDBOX/grandchild.pid" ] || return 1
    cat "$SANDBOX/grandchild.pid"
}

# Discover the watchdog PID from outside. Process tree:
#   wrapper(W) -> { fake-claude(C), watchdog-subshell(Wd) }
#   fake-claude(C) -> sleep(G)   [G = grandchild.pid]
# So C = parent of G, and Wd = the child of W that is not C. We poll until
# W has exactly its two children so the identification is unambiguous.
_discover_pids() {
    local wpid="$1" gpid="$2"
    local cpid kids i=0
    cpid="$(ps -o ppid= -p "$gpid" 2>/dev/null | tr -d ' ')"
    [ -n "$cpid" ] || return 1
    while [ $i -lt 30 ]; do
        kids="$(pgrep -P "$wpid" 2>/dev/null | tr '\n' ' ')"
        # Expect two children (fake-claude + watchdog).
        set -- $kids
        if [ "$#" -ge 2 ]; then
            break
        fi
        sleep 0.1
        i=$((i + 1))
    done
    local wd="" k
    for k in $kids; do
        if [ "$k" != "$cpid" ]; then
            wd="$k"
        fi
    done
    [ -n "$wd" ] || return 1
    printf '%s %s\n' "$cpid" "$wd"
}

@test "honesty CASE 1: SIGKILL of wrapper ALONE is survived (proves MEDIUM)" {
    "$WRAPPER" &
    local wrapper_pid=$!
    echo "$wrapper_pid" >> "$SANDBOX/cleanup.pids"

    local gc_pid; gc_pid="$(_await_grandchild)"
    [ -n "$gc_pid" ]
    echo "$gc_pid" >> "$SANDBOX/cleanup.pids"
    kill -0 "$gc_pid"          # alive before we strike

    # SIGKILL the wrapper ONLY. Its bash trap cannot fire (SIGKILL is
    # uncatchable). The watchdog is a separate process and survives; it
    # must notice and reap within its 0.2s poll + cleanup grace.
    kill -KILL "$wrapper_pid"

    # Watchdog poll (<=0.2s) + cleanup (TERM, 0.5s, KILL) + slack. 5s cap.
    local i=0
    while kill -0 "$gc_pid" 2>/dev/null && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    if kill -0 "$gc_pid" 2>/dev/null; then
        kill -KILL "$gc_pid" 2>/dev/null || true
        printf 'FAIL: grandchild %s survived a lone wrapper SIGKILL -- the watchdog did NOT reap. This is WEAK, not MEDIUM.\n' "$gc_pid" >&2
        return 1
    fi
}

@test "honesty CASE 2: simultaneous SIGKILL of wrapper+watchdog leaks (pins the ceiling)" {
    "$WRAPPER" &
    local wrapper_pid=$!
    echo "$wrapper_pid" >> "$SANDBOX/cleanup.pids"

    local gc_pid; gc_pid="$(_await_grandchild)"
    [ -n "$gc_pid" ]
    echo "$gc_pid" >> "$SANDBOX/cleanup.pids"
    kill -0 "$gc_pid"

    local pids cpid watchdog_pid
    pids="$(_discover_pids "$wrapper_pid" "$gc_pid")"
    [ -n "$pids" ]
    cpid="${pids%% *}"
    watchdog_pid="${pids##* }"
    echo "$cpid" >> "$SANDBOX/cleanup.pids"
    echo "$watchdog_pid" >> "$SANDBOX/cleanup.pids"

    # Prove we actually found a real, distinct, live watchdog -- otherwise
    # this test could "pass" trivially by having killed nothing.
    [ -n "$watchdog_pid" ]
    [ "$watchdog_pid" != "$wrapper_pid" ]
    [ "$watchdog_pid" != "$cpid" ]
    [ "$watchdog_pid" != "$gc_pid" ]
    kill -0 "$watchdog_pid"

    # One syscall batch -> both get an uncatchable SIGKILL before either
    # can run another instruction. The watchdog cannot reap because it is
    # dead before its next poll iteration. This is the documented hole.
    kill -KILL "$wrapper_pid" "$watchdog_pid"

    # Give any (nonexistent) cleanup the same generous window CASE 1 got.
    # If the grandchild is going to be reaped it would happen well within
    # this; we assert it is STILL ALIVE at the end.
    local i=0
    while [ $i -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    if ! kill -0 "$gc_pid" 2>/dev/null; then
        printf 'UNEXPECTED: grandchild %s was reaped after a simultaneous wrapper+watchdog SIGKILL.\n' "$gc_pid" >&2
        printf '  macOS has no kernel primitive that should make this possible. Either a real\n' >&2
        printf '  primitive was added (update the guarantee to STRONG and this test), or the\n' >&2
        printf '  reap came from somewhere unaudited. Do not just flip the assertion.\n' >&2
        return 1
    fi
    # Grandchild survived exactly as the MEDIUM ceiling says it must.
    # teardown() will clean up the deliberately-leaked tree.
}
