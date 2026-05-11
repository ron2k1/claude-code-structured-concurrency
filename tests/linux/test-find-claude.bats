#!/usr/bin/env bats
# Unit tests for find-claude.sh probe ordering.
#
# Pure-bats. Sandboxes PATH and HOME so probes hit only paths we control.
# Probes 3-4 (Homebrew /opt/homebrew, /usr/local) require absolute writable
# paths and are not safely testable from userspace -- those land in CI via
# a runner that has Homebrew installed (macos-* job) or are skipped here.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    FIND="$REPO_ROOT/tools/linux/find-claude.sh"
    [ -x "$FIND" ] || chmod +x "$FIND"

    SANDBOX="$(mktemp -d)"
    ORIG_PATH="$PATH"
    ORIG_HOME="$HOME"
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME"
    # Strip system claude (if any) -- only what we add inside SANDBOX shows up.
    # /usr/bin and /bin needed for sort, ls, grep, awk used inside the script.
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

@test "find-claude: returns 127 when no claude exists anywhere" {
    # Direct invocation -- bypass `run` entirely. bats-core 1.5+ has `run -127`
    # to declare the expected exit, but Ubuntu ships bats 1.2 (no -N support),
    # which emits BW01 on `run` returning 127 and BW02 on `-N` syntax. The
    # direct call avoids both.
    bash "$FIND" >/dev/null 2>&1
    status=$?
    [ "$status" -eq 127 ]
}

@test "find-claude: locates claude via PATH (probe 1)" {
    local d="$SANDBOX/onpath"
    make_fake_claude "$d/claude"
    PATH="$d:$PATH" run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$d/claude" ]
}

# --- Probe 2: npm prefix --------------------------------------------------

@test "find-claude: locates claude via npm prefix (probe 2)" {
    local npm_dir="$SANDBOX/npm-prefix"
    make_fake_claude "$npm_dir/bin/claude"

    # Mock `npm config get prefix` -- a tiny shell script returning npm_dir.
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

@test "find-claude: PATH wins over npm prefix (priority order)" {
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

# --- Probes 3-4: Homebrew (CI-only) --------------------------------------

@test "find-claude: locates claude in /opt/homebrew/bin (probe 3, CI-only)" {
    if [ ! -d /opt/homebrew/bin ] || [ ! -w /opt/homebrew/bin ]; then
        skip "requires writable /opt/homebrew/bin -- macOS arm64 CI runner only"
    fi
    skip "deferred: real /opt/homebrew/bin probe coverage lands with v1.2.0 macOS support"
}

# --- Probe 5: nvm ---------------------------------------------------------

@test "find-claude: locates claude via nvm (probe 5)" {
    # Two nvm-managed node versions; expect highest (v22.5.0) to win.
    make_fake_claude "$HOME/.nvm/versions/node/v18.20.0/bin/claude"
    make_fake_claude "$HOME/.nvm/versions/node/v22.5.0/bin/claude"

    run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.nvm/versions/node/v22.5.0/bin/claude" ]
}

# --- Probe 6: fnm ---------------------------------------------------------

@test "find-claude: locates claude via fnm (probe 6)" {
    make_fake_claude "$HOME/.local/share/fnm/aliases/default/bin/claude"
    run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.local/share/fnm/aliases/default/bin/claude" ]
}

# --- Probe 9: yarn global -------------------------------------------------

@test "find-claude: locates claude via yarn global (probe 9)" {
    make_fake_claude "$HOME/.config/yarn/global/node_modules/.bin/claude"
    run bash "$FIND"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.config/yarn/global/node_modules/.bin/claude" ]
}

# --- Source-mode contract -------------------------------------------------

@test "find-claude: sourceable -- find_claude function defined, no script side effect" {
    local d="$SANDBOX/onpath"
    make_fake_claude "$d/claude"

    PATH="$d:/usr/bin:/bin" run bash -c ". '$FIND' && declare -F find_claude && find_claude"
    [ "$status" -eq 0 ]
    [[ "$output" == *"find_claude"* ]]
    [[ "$output" == *"$d/claude"* ]]
}
