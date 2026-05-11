#!/usr/bin/env bash
# install.sh -- claude-code-structured-concurrency installer (POSIX side).
#
# Detects OS, prints the kernel-guarantee tier honestly, then injects an
# idempotent shell function into the user's rc files so plain `claude`
# routes through the wrapper.
#
# Windows users: run install-reap.ps1 from PowerShell instead.
# macOS users: not yet supported (v1.2.0 milestone).
#
# Flags:
#   --yes / -y   non-interactive (skip the prompt; required for CI)
#   --force      overwrite an existing injected block
#   --uninstall  remove the injected block from all rc files

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- arg parsing ----------------------------------------------------------

assume_yes=0
force=0
uninstall=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)    assume_yes=1 ;;
        --force)     force=1 ;;
        --uninstall) uninstall=1 ;;
        *) printf 'install.sh: unknown flag %s\n' "$arg" >&2; exit 2 ;;
    esac
done

# --- OS detection + guarantee statement ----------------------------------

uname_s="$(uname -s)"
case "$uname_s" in
    Linux)
        platform=linux
        kernel="$(uname -r | cut -d. -f1-2)"
        # major.minor compare against 5.14. sort -V -C succeeds when input is
        # already in ascending order, so put the floor (5.14) FIRST and the
        # detected kernel SECOND -- that succeeds iff kernel >= 5.14.
        if printf '5.14\n%s\n' "$kernel" | sort -V -C 2>/dev/null; then
            guarantee="STRONG (cgroup.kill via systemd transient scope; kernel $kernel >= 5.14)"
        else
            guarantee="MEDIUM (setpgid + trap fallback; kernel $kernel below 5.14 floor)"
        fi
        ;;
    Darwin)
        printf 'install.sh: macOS support is on the v1.2.0 roadmap, not v1.1.0.\n' >&2
        printf '  Track: https://github.com/ron2k1/claude-code-structured-concurrency/milestones\n' >&2
        exit 1
        ;;
    *)
        printf 'install.sh: unsupported OS %s\n' "$uname_s" >&2
        printf '  Windows users: run install-reap.ps1 from PowerShell\n' >&2
        exit 1
        ;;
esac

wrapper="$repo_root/tools/$platform/claude-jobbed.sh"
if [ ! -f "$wrapper" ]; then
    printf 'install.sh: wrapper not found at %s\n' "$wrapper" >&2
    printf '  did you clone the repo? (git clone https://github.com/ron2k1/claude-code-structured-concurrency)\n' >&2
    exit 1
fi
chmod +x "$wrapper" "$repo_root/tools/$platform/find-claude.sh"

# --- shell function block (the thing we inject) --------------------------

block_marker_open='# >>> claude-code-structured-concurrency >>>'
block_marker_close='# <<< claude-code-structured-concurrency <<<'
read -r -d '' block <<BLOCK || true
$block_marker_open
# Routes \`claude\` through the structured-concurrency wrapper.
# Remove this block (or run install.sh --uninstall) to disable.
claude() { command "$wrapper" "\$@"; }
$block_marker_close
BLOCK

inject_into() {
    local rc="$1"
    [ -e "$rc" ] || return 0
    if grep -qF "$block_marker_open" "$rc" 2>/dev/null; then
        if [ "$force" -eq 1 ]; then
            # remove old block first (sed in-place; portable form needs tmp)
            local tmp; tmp="$(mktemp)"
            awk -v marker_open="$block_marker_open" -v marker_close="$block_marker_close" '
                $0 == marker_open { skip = 1; next }
                $0 == marker_close { skip = 0; next }
                !skip { print }
            ' "$rc" > "$tmp"
            mv "$tmp" "$rc"
        else
            printf '  skipping %s (block already present; use --force to overwrite)\n' "$rc"
            return 0
        fi
    fi
    printf '\n%s\n' "$block" >> "$rc"
    printf '  injected into %s\n' "$rc"
}

uninstall_from() {
    local rc="$1"
    [ -e "$rc" ] || return 0
    if ! grep -qF "$block_marker_open" "$rc" 2>/dev/null; then
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    awk -v marker_open="$block_marker_open" -v marker_close="$block_marker_close" '
        $0 == marker_open { skip = 1; next }
        $0 == marker_close { skip = 0; next }
        !skip { print }
    ' "$rc" > "$tmp"
    mv "$tmp" "$rc"
    printf '  removed from %s\n' "$rc"
}

# --- uninstall path ------------------------------------------------------

if [ "$uninstall" -eq 1 ]; then
    printf 'Uninstalling claude-code-structured-concurrency shell-function block:\n'
    uninstall_from "$HOME/.bashrc"
    uninstall_from "$HOME/.zshrc"
    uninstall_from "$HOME/.config/fish/config.fish"
    printf 'Done. Restart your shell to take effect.\n'
    exit 0
fi

# --- install path: pre-flight ack ----------------------------------------

cat <<INFO
This wraps \`claude\` in a process supervisor so child processes are
reaped on exit instead of leaking.

  Detected: $uname_s ($platform)
  Guarantee: $guarantee

Will append a shell function to:
  ~/.bashrc, ~/.zshrc, ~/.config/fish/config.fish (each, if present)

Wrapper path: $wrapper

INFO

if [ "$assume_yes" -eq 0 ]; then
    printf 'Continue? [y/N] '
    read -r reply </dev/tty || reply=""
    case "$reply" in
        y|Y|yes|Yes) ;;
        *) printf 'Aborted.\n'; exit 0 ;;
    esac
fi

inject_into "$HOME/.bashrc"
inject_into "$HOME/.zshrc"
inject_into "$HOME/.config/fish/config.fish"

cat <<DONE

Installed.
Restart your shell or run \`source ~/.bashrc\` (or your shell's equivalent).
Verify with: type claude     # should print "claude is a function"
Diagnose: $repo_root/tools/$platform/claude-jobbed.sh --version
Uninstall: $repo_root/install.sh --uninstall
DONE
