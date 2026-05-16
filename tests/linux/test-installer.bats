#!/usr/bin/env bats
# Unit tests for install.sh: idempotent inject, --force overwrite, --uninstall.
#
# Sandboxes HOME so we never touch the runner's real rc files.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    INSTALL="$REPO_ROOT/install.sh"
    [ -x "$INSTALL" ] || chmod +x "$INSTALL"

    SANDBOX="$(mktemp -d)"
    ORIG_HOME="$HOME"
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME"
    touch "$HOME/.bashrc"
    touch "$HOME/.zshrc"
    # leave fish unset to verify "skip when absent" behavior

    # These assertions encode the LINUX rc-file contract specifically:
    # the Linux installer targets ~/.bashrc + ~/.zshrc and deliberately
    # never writes ~/.bash_profile. macOS is now supported too, but its
    # path targets ~/.bash_profile as well and is covered by its own
    # suite, so off-Linux this file skips rather than mis-asserting.
    if [ "$(uname -s)" != "Linux" ]; then
        skip "Linux rc-file contract; macOS path covered by tests/macos/test-installer.bats"
    fi
}

teardown() {
    export HOME="$ORIG_HOME"
    rm -rf "$SANDBOX"
}

@test "install.sh: --yes injects block into existing rc files" {
    run "$INSTALL" --yes
    [ "$status" -eq 0 ]

    grep -qF "claude-code-structured-concurrency" "$HOME/.bashrc"
    grep -qF "claude-code-structured-concurrency" "$HOME/.zshrc"
    # fish config wasn't created -- installer should NOT have made one.
    [ ! -e "$HOME/.config/fish/config.fish" ]
}

@test "install.sh: re-running without --force is idempotent (refuses to duplicate)" {
    "$INSTALL" --yes
    local count_before
    count_before="$(grep -cF "claude-code-structured-concurrency" "$HOME/.bashrc")"

    run "$INSTALL" --yes
    [ "$status" -eq 0 ]

    local count_after
    count_after="$(grep -cF "claude-code-structured-concurrency" "$HOME/.bashrc")"
    [ "$count_before" -eq "$count_after" ]
}

@test "install.sh: --force overwrites existing block (no duplication)" {
    "$INSTALL" --yes
    run "$INSTALL" --yes --force
    [ "$status" -eq 0 ]

    # Marker should appear exactly twice per file (open + close), not 4x.
    local marker_count
    marker_count="$(grep -cE "(>>>|<<<) claude-code-structured-concurrency" "$HOME/.bashrc")"
    [ "$marker_count" -eq 2 ]
}

@test "install.sh: --uninstall removes the block cleanly" {
    "$INSTALL" --yes
    grep -qF "claude-code-structured-concurrency" "$HOME/.bashrc"

    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]

    if grep -qF "claude-code-structured-concurrency" "$HOME/.bashrc" 2>/dev/null; then
        printf 'FAIL: marker still present in .bashrc after --uninstall\n' >&2
        return 1
    fi
    if grep -qF "claude-code-structured-concurrency" "$HOME/.zshrc" 2>/dev/null; then
        printf 'FAIL: marker still present in .zshrc after --uninstall\n' >&2
        return 1
    fi
}

@test "install.sh: --uninstall is no-op when block was never installed" {
    # rc files exist but no install was ever done.
    local before; before="$(cat "$HOME/.bashrc")"
    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]
    local after; after="$(cat "$HOME/.bashrc")"
    [ "$before" = "$after" ]
}

@test "install.sh: refuses unknown flags with exit 2" {
    run "$INSTALL" --not-a-real-flag
    [ "$status" -eq 2 ]
}
