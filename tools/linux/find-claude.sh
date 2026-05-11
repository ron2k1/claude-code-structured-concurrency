#!/usr/bin/env bash
# find-claude.sh -- locate the claude binary across common install layouts.
#
# Prints the resolved path on stdout. Exits 0 on success, 127 if not found.
# Pure POSIX-shell-friendly bash; no external dependencies beyond coreutils.
#
# Probe order (first hit wins):
#   1. command -v claude          # PATH
#   2. $(npm config get prefix)/bin/claude
#   3. /opt/homebrew/bin/claude   # Apple Silicon brew
#   4. /usr/local/bin/claude      # Intel brew + classic /usr/local
#   5. ~/.nvm/versions/node/*/bin/claude   (latest version)
#   6. ~/.local/share/fnm/aliases/default/bin/claude
#   7. asdf which claude
#   8. volta which claude
#   9. ~/.config/yarn/global/node_modules/.bin/claude
#
# Sourceable: defines find_claude(); callers can source and reuse.
# Executable: runs find_claude and prints the result.

set -euo pipefail

find_claude() {
    # 1. PATH
    if command -v claude >/dev/null 2>&1; then
        command -v claude
        return 0
    fi

    # 2. npm global prefix
    if command -v npm >/dev/null 2>&1; then
        local npm_prefix
        npm_prefix="$(npm config get prefix 2>/dev/null || true)"
        if [ -n "${npm_prefix:-}" ] && [ -x "$npm_prefix/bin/claude" ]; then
            printf '%s\n' "$npm_prefix/bin/claude"
            return 0
        fi
    fi

    # 3-4. Homebrew (Apple Silicon first, then Intel/Linux classic)
    local p
    for p in /opt/homebrew/bin/claude /usr/local/bin/claude; do
        if [ -x "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    # 5. nvm -- pick the highest-version dir's claude
    if [ -d "${HOME:-/dev/null}/.nvm/versions/node" ]; then
        local nvm_pick
        nvm_pick="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1 || true)"
        if [ -n "${nvm_pick:-}" ] && [ -x "$HOME/.nvm/versions/node/$nvm_pick/bin/claude" ]; then
            printf '%s\n' "$HOME/.nvm/versions/node/$nvm_pick/bin/claude"
            return 0
        fi
    fi

    # 6. fnm
    if [ -x "${HOME:-}/.local/share/fnm/aliases/default/bin/claude" ]; then
        printf '%s\n' "$HOME/.local/share/fnm/aliases/default/bin/claude"
        return 0
    fi

    # 7. asdf
    if command -v asdf >/dev/null 2>&1; then
        local asdf_hit
        asdf_hit="$(asdf which claude 2>/dev/null || true)"
        if [ -n "${asdf_hit:-}" ] && [ -x "$asdf_hit" ]; then
            printf '%s\n' "$asdf_hit"
            return 0
        fi
    fi

    # 8. volta
    if command -v volta >/dev/null 2>&1; then
        local volta_hit
        volta_hit="$(volta which claude 2>/dev/null || true)"
        if [ -n "${volta_hit:-}" ] && [ -x "$volta_hit" ]; then
            printf '%s\n' "$volta_hit"
            return 0
        fi
    fi

    # 9. yarn global
    if [ -x "${HOME:-}/.config/yarn/global/node_modules/.bin/claude" ]; then
        printf '%s\n' "$HOME/.config/yarn/global/node_modules/.bin/claude"
        return 0
    fi

    return 127
}

# Run as script -- print the result. Source-safe: skip when sourced.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
    if path="$(find_claude)"; then
        printf '%s\n' "$path"
    else
        printf 'find-claude: claude not found in PATH or any known install location\n' >&2
        exit 127
    fi
fi
