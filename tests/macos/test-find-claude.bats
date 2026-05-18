#!/usr/bin/env bats
# Unit tests for tools/macos/find-claude.sh probe ordering.
#
# Faithful mirror of tests/linux/test-find-claude.bats: the two platforms
# share a discovery contract, so the probe-priority assertions are the same
# shape. The ONE intentional divergence is probe 6 (fnm): macOS defaults
# FNM_DIR to ~/Library/Application Support/fnm rather than the XDG
# ~/.local/share/fnm, and find-claude.sh probes BOTH. We add a dedicated
# test for the Library layout that the Linux suite has no reason to carry.
#
# Pure-bats. Sandboxes PATH and HOME so probes hit only paths we control.
# Probes 3-4 (Homebrew /opt/homebrew, /usr/local) are absolute paths that
# cannot be redirected via HOME/PATH; they are exercised only when the
# Homebrew bin dir is actually writable (rare without sudo on a CI runner),
# otherwise skipped with an honest reason rather than a silent pass.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    FIND="$REPO_ROOT/tools/macos/find-claude.sh"
    [ -x "$FIND" ] || chmod +x "$FIND"

    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/csc-find.XXXXXX")"
    ORIG_PATH="$PATH"
    ORIG_HOME="$HOME"
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME"
    # Strip system claude (if any) -- only what we add inside SANDBOX shows up.
    # /usr/bin and /bin needed for sort, ls, grep used inside the script.
    export PATH="/usr/bin:/bin"
}

teardown() {
    export PATH="$ORIG_PATH"
    export HOME="$ORIG_HOME"
    rm -rf "$SANDBOX"
}

make_fake_claude() {
    local target="$1"
    mkdir -p "$(dirname "$target")"
    printf '#!/bin/sh\necho "fake claude at $0"\n' > "$target"
    chmod +x "$target"
}

# --- Probe 1: PATH --------------------------------------------------------

@test "find-claude(macos): returns 127 when no claude exists anywhere" {
    # `cmd || status=$?` -- the `||` makes failure expected to bats so the
    # test doesn't abort on bash's non-zero exit, AND we capture the actual
    # exit code. Avoids `run` (BW01 on 127-exit) and `run -127` (BW02 on
    # the older bats some runners ship, which lacks -N support).
    local status=0
    bash "$FIND" >/dev/null 2>&1 || status=$?
    [ "$status" -eq 127 ]
}

@test "find-claude(macos): locates claude via PATH (probe 1)" {
    local d="$SANDBOX/onpath"
    make_fake_claude "$d/claude"
    PATH="$d:$PATH" run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$d/claude" ]
}

# --- Probe 2: npm prefix --------------------------------------------------

@test "find-claude(macos): locates claude via npm prefix (probe 2)" {
    local npm_dir="$SANDBOX/npm-prefix"
    make_fake_claude "$npm_dir/bin/claude"

    local mock_dir="$SANDBOX/mock-bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/npm" <<MOCK
#!/bin/sh
if [ "\$1" = "config" ] && [ "\$2" = "get" ] && [ "\$3" = "prefix" ]; then
    echo "$npm_dir"
fi
MOCK
    chmod +x "$mock_dir/npm"

    PATH="$mock_dir:/usr/bin:/bin" run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$npm_dir/bin/claude" ]
}

@test "find-claude(macos): PATH wins over npm prefix (priority order)" {
    local d="$SANDBOX/onpath"
    make_fake_claude "$d/claude"

    local npm_dir="$SANDBOX/npm-prefix"
    make_fake_claude "$npm_dir/bin/claude"

    local mock_dir="$SANDBOX/mock-bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/npm" <<MOCK
#!/bin/sh
if [ "\$1" = "config" ]; then echo "$npm_dir"; fi
MOCK
    chmod +x "$mock_dir/npm"

    # Order matters: $d before mock_dir means PATH-resolved claude wins.
    PATH="$d:$mock_dir:/usr/bin:/bin" run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$d/claude" ]
}

# --- Probes 3-4: Homebrew (real only when the prefix is writable) ---------

@test "find-claude(macos): /opt/homebrew/bin/claude resolves (probe 3)" {
    if [ ! -d /opt/homebrew/bin ] || [ ! -w /opt/homebrew/bin ]; then
        skip "needs a writable /opt/homebrew/bin (Apple Silicon Homebrew, sudo-less runner cannot)"
    fi
    # Real probe: only safe to run when we can write+remove our own marker.
    local hb="/opt/homebrew/bin/claude.csc-test"
    printf '#!/bin/sh\necho hb\n' > "$hb"
    chmod +x "$hb"
    # The script hardcodes /opt/homebrew/bin/claude; rename our marker in.
    if [ -e /opt/homebrew/bin/claude ]; then
        skip "real claude already present in /opt/homebrew/bin -- not clobbering it"
    fi
    mv "$hb" /opt/homebrew/bin/claude
    run bash "$FIND"
    rm -f /opt/homebrew/bin/claude
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/homebrew/bin/claude" ]
}

# --- Probe 5: nvm ---------------------------------------------------------

@test "find-claude(macos): locates claude via nvm, highest version wins (probe 5)" {
    make_fake_claude "$HOME/.nvm/versions/node/v18.20.0/bin/claude"
    make_fake_claude "$HOME/.nvm/versions/node/v22.5.0/bin/claude"

    run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.nvm/versions/node/v22.5.0/bin/claude" ]
}

# --- Probe 6: fnm -- BOTH layouts (the one real macOS divergence) ---------

@test "find-claude(macos): locates claude via fnm XDG layout (probe 6a)" {
    make_fake_claude "$HOME/.local/share/fnm/aliases/default/bin/claude"
    run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.local/share/fnm/aliases/default/bin/claude" ]
}

@test "find-claude(macos): locates claude via fnm macOS Library layout (probe 6b)" {
    # This is the macOS-specific path the Linux suite never exercises.
    make_fake_claude "$HOME/Library/Application Support/fnm/aliases/default/bin/claude"
    run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/Library/Application Support/fnm/aliases/default/bin/claude" ]
}

# --- Probe 9: yarn global -------------------------------------------------

@test "find-claude(macos): locates claude via yarn global (probe 9)" {
    make_fake_claude "$HOME/.config/yarn/global/node_modules/.bin/claude"
    run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.config/yarn/global/node_modules/.bin/claude" ]
}

# --- Source-mode contract -------------------------------------------------

@test "find-claude(macos): sourceable -- find_claude defined, no script side effect" {
    local d="$SANDBOX/onpath"
    make_fake_claude "$d/claude"

    PATH="$d:/usr/bin:/bin" run bash -c ". '$FIND' && declare -F find_claude && find_claude"
    [ "$status" -eq 0 ]
    [[ "$output" == *"find_claude"* ]]
    [[ "$output" == *"$d/claude"* ]]
}
