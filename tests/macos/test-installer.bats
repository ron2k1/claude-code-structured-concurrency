#!/usr/bin/env bats
# Unit tests for install.sh on the macOS (Darwin) path.
#
# Faithful sibling of tests/linux/test-installer.bats: the idempotent
# inject / --force / --uninstall / unknown-flag contracts are identical
# across platforms, so those assertions keep the same shape. This file
# additionally pins the TWO things the Linux suite has no reason to carry:
#
#   1. ~/.bash_profile is targeted. macOS Terminal.app runs bash as a
#      LOGIN shell, which sources ~/.bash_profile and NOT ~/.bashrc. The
#      Linux installer deliberately never writes ~/.bash_profile; the
#      Darwin branch must. A regression dropping this would leave every
#      Terminal.app bash user with an installer that "succeeded" yet never
#      actually wrapped `claude` -- the worst kind of silent failure.
#
#   2. The MEDIUM banner states the honest ceiling in words ("NOT
#      survivable if the wrapper AND its watchdog are kill -9'd
#      simultaneously ... This is the honest ceiling, not a TODO").
#      test-honesty.bats proves the BEHAVIOR; this proves we still tell
#      the user the truth about it at install time.
#
# install.sh only takes its Darwin arm when `uname -s` is Darwin, so the
# whole suite skips with an honest reason on a non-macOS runner rather
# than a green that proves nothing.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    INSTALL="$REPO_ROOT/install.sh"
    [ -x "$INSTALL" ] || chmod +x "$INSTALL"

    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/csc-installer.XXXXXX")"
    ORIG_HOME="$HOME"
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME"
    touch "$HOME/.bashrc"
    touch "$HOME/.zshrc"
    # macOS LOGIN-shell bash reads THIS, not .bashrc -- inject_into skips
    # files that don't exist, so it must pre-exist for the divergence to
    # be observable.
    touch "$HOME/.bash_profile"
    # leave fish unset to verify "skip when absent" behavior

    # install.sh refuses to take the Darwin path off macOS (it would exit
    # 1 as "unsupported OS" on anything that is neither Linux nor Darwin,
    # and take the Linux arm on Linux). The macOS contract is only
    # observable on macOS; anywhere else this suite skips honestly.
    if [ "$(uname -s)" != "Darwin" ]; then
        skip "install.sh's Darwin branch is unexercisable on $(uname -s); Linux path is covered by tests/linux/test-installer.bats"
    fi
}

teardown() {
    export HOME="$ORIG_HOME"
    rm -rf "$SANDBOX"
}

@test "install.sh(macos): --yes injects into zsh + bashrc + bash_profile" {
    run "$INSTALL" --yes
    [ "$status" -eq 0 ]

    grep -qF "claude-code-structured-concurrency" "$HOME/.zshrc"
    grep -qF "claude-code-structured-concurrency" "$HOME/.bashrc"
    # THE macOS divergence: LOGIN-shell bash reads .bash_profile. The Linux
    # installer never writes here; the Darwin branch must.
    grep -qF "claude-code-structured-concurrency" "$HOME/.bash_profile"
    # fish config wasn't created -- installer should NOT have made one.
    [ ! -e "$HOME/.config/fish/config.fish" ]
}

@test "install.sh(macos): banner states the honest MEDIUM ceiling" {
    run "$INSTALL" --yes
    [ "$status" -eq 0 ]
    # We took the Darwin arm, not the "unsupported OS" exit.
    [[ "$output" == *"Detected: Darwin"* ]]
    # The tier, and -- critically -- the words that keep it honest. If a
    # refactor ever softens this to "MEDIUM (TODO: harden)" or drops the
    # ceiling sentence, this fails and forces the diff to explain itself.
    [[ "$output" == *"MEDIUM"* ]]
    [[ "$output" == *"honest ceiling"* ]]
}

@test "install.sh(macos): re-running without --force is idempotent" {
    "$INSTALL" --yes
    local before
    before="$(grep -cF "claude-code-structured-concurrency" "$HOME/.bash_profile")"

    run "$INSTALL" --yes
    [ "$status" -eq 0 ]

    local after
    after="$(grep -cF "claude-code-structured-concurrency" "$HOME/.bash_profile")"
    [ "$before" -eq "$after" ]
}

@test "install.sh(macos): --force overwrites the bash_profile block (no dup)" {
    "$INSTALL" --yes
    run "$INSTALL" --yes --force
    [ "$status" -eq 0 ]

    # open + close marker == exactly twice per file, not 4x.
    local marker_count
    marker_count="$(grep -cE "(>>>|<<<) claude-code-structured-concurrency" "$HOME/.bash_profile")"
    [ "$marker_count" -eq 2 ]
}

@test "install.sh(macos): --uninstall removes the block from ALL mac rc files" {
    "$INSTALL" --yes
    grep -qF "claude-code-structured-concurrency" "$HOME/.bash_profile"

    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]

    local rc
    for rc in .zshrc .bashrc .bash_profile; do
        if grep -qF "claude-code-structured-concurrency" "$HOME/$rc" 2>/dev/null; then
            printf 'FAIL: marker still present in %s after --uninstall\n' "$rc" >&2
            return 1
        fi
    done
}

@test "install.sh(macos): --uninstall is a no-op when never installed" {
    local before; before="$(cat "$HOME/.bash_profile")"
    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]
    local after; after="$(cat "$HOME/.bash_profile")"
    [ "$before" = "$after" ]
}

@test "install.sh(macos): refuses unknown flags with exit 2" {
    run "$INSTALL" --not-a-real-flag
    [ "$status" -eq 2 ]
}
