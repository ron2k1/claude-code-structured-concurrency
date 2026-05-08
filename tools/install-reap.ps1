# install-reap.ps1 -- one-time setup for the reap skill.
#
# Idempotent. Safe to run multiple times. Adds:
#   1. PowerShell profile function `claude-jobbed` so it's on the PATH
#      of every PS session
#   2. Bash function `claude-jobbed` in ~/.bashrc for Git Bash users
#   3. ~/.reap/config.json -- starter config (does NOT overwrite an
#      existing one; rename or delete to re-seed)
#
# Does NOT touch ~/.claude/settings.json -- that edit is the user's
# call. See docs/CONFIGURATION.md for the SessionStart hook entry.
#
# Usage:
#   .\install-reap.ps1                            # install with moderate profile
#   .\install-reap.ps1 -ConfigProfile aggressive  # pick a starter profile
#   .\install-reap.ps1 -SkipUserConfig            # don't create ~/.reap/
#   .\install-reap.ps1 -Uninstall                 # remove aliases (leaves ~/.reap intact)

[CmdletBinding()]
param(
    [switch] $Uninstall,
    [switch] $WhatIf,
    [switch] $SkipUserConfig,
    [ValidateSet('conservative', 'moderate', 'aggressive', 'paranoid')]
    [string] $ConfigProfile = 'moderate'
)

$ErrorActionPreference = 'Stop'

$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir  = Split-Path -Parent $here
$wrapperPs = Join-Path $here 'claude-jobbed.ps1'

if (-not (Test-Path $wrapperPs)) {
    Write-Error "expected wrapper not found at $wrapperPs"
    exit 1
}

$markerStart = '# === reap skill alias (managed by install-reap.ps1) ==='
$markerEnd   = '# === end reap skill alias ==='

# --- helper: idempotent block insert/remove -----------------------------

function Edit-Block {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Block,
        [Parameter(Mandatory)] [string] $Label,
        [switch] $Remove
    )

    if (-not (Test-Path $Path)) {
        if ($Remove) {
            Write-Host "[$Label] $Path does not exist -- nothing to remove"
            return
        }
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) {
            if (-not $WhatIf) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }
        if (-not $WhatIf) { New-Item -ItemType File -Path $Path -Force | Out-Null }
    }

    $content = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = '' }

    $startEsc   = [regex]::Escape($markerStart)
    $endEsc     = [regex]::Escape($markerEnd)
    $blockRegex = "(?ms)\r?\n?$startEsc.*?$endEsc\r?\n?"

    if ($Remove) {
        if ($content -match $startEsc) {
            $new = [regex]::Replace($content, $blockRegex, '')
            if (-not $WhatIf) { Set-Content -Path $Path -Value $new -Encoding utf8 -NoNewline }
            Write-Host "[$Label] removed reap block from $Path"
        } else {
            Write-Host "[$Label] no reap block present in $Path"
        }
        return
    }

    if ($content -match $startEsc) {
        # Replace existing block (covers wrapper-path moves between installs)
        $new = [regex]::Replace($content, $blockRegex, ([Environment]::NewLine + $Block + [Environment]::NewLine))
        if ($new -ne $content) {
            if (-not $WhatIf) { Set-Content -Path $Path -Value $new -Encoding utf8 -NoNewline }
            Write-Host "[$Label] updated existing reap block in $Path"
        } else {
            Write-Host "[$Label] reap block already current in $Path"
        }
    } else {
        $sep = if ($content -and -not $content.EndsWith("`n")) { [Environment]::NewLine + [Environment]::NewLine } else { [Environment]::NewLine }
        $new = $content + $sep + $Block + [Environment]::NewLine
        if (-not $WhatIf) { Set-Content -Path $Path -Value $new -Encoding utf8 -NoNewline }
        Write-Host "[$Label] added reap block to $Path"
    }
}

# --- 1. PowerShell profile (CurrentUserAllHosts works for PS 5.1 + PS 7) -

$psProfile = $PROFILE.CurrentUserAllHosts
$psBlock = @"
$markerStart
function claude-jobbed { & '$wrapperPs' @args }
$markerEnd
"@

Edit-Block -Path $psProfile -Block $psBlock -Label 'PS-profile' -Remove:$Uninstall

# --- 2. ~/.bashrc for Git Bash users ------------------------------------

$bashrc  = Join-Path $env:USERPROFILE '.bashrc'
$bashWrapperEsc = $wrapperPs -replace '\\', '\\'
$bashBlock = @"
$markerStart
claude-jobbed() {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$bashWrapperEsc" "`$@"
}
$markerEnd
"@

Edit-Block -Path $bashrc -Block $bashBlock -Label 'bashrc' -Remove:$Uninstall

# --- 3. user config at ~/.reap/config.json ------------------------------

$userConfigDir  = Join-Path $env:USERPROFILE '.reap'
$userConfigPath = Join-Path $userConfigDir 'config.json'
$exampleSource  = Join-Path $skillDir "config-examples\$ConfigProfile.json"

if (-not $Uninstall -and -not $SkipUserConfig) {
    if (-not (Test-Path $exampleSource)) {
        Write-Warning "[user-config] starter profile not found at $exampleSource (skill install incomplete?)"
    } elseif (Test-Path $userConfigPath) {
        Write-Host "[user-config] $userConfigPath already exists -- preserving (rename or delete to re-seed)"
    } else {
        if (-not (Test-Path $userConfigDir)) {
            if (-not $WhatIf) { New-Item -ItemType Directory -Path $userConfigDir -Force | Out-Null }
        }
        if (-not $WhatIf) { Copy-Item -Path $exampleSource -Destination $userConfigPath -Force }
        Write-Host "[user-config] seeded $userConfigPath from $ConfigProfile profile"
    }
} elseif ($SkipUserConfig) {
    Write-Host "[user-config] skipped (-SkipUserConfig); engine will use built-in safe-no-op default"
}

# --- final guidance -----------------------------------------------------

Write-Host ""
if ($Uninstall) {
    Write-Host "Uninstall complete. Open a new shell to drop the alias from your environment."
    Write-Host "Note: ~/.reap/config.json was NOT removed (your config is your data)."
} else {
    Write-Host "Install complete. Open a new shell, then verify:"
    Write-Host "  PowerShell: claude-jobbed --version"
    Write-Host "  Git Bash:   claude-jobbed --version"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Edit $userConfigPath to add your in-house tools to spare_cmdline_patterns"
    Write-Host "  2. Run a dry-run reap:  .\tools\cleanup-orphans.ps1"
    Write-Host "  3. (Optional) Wire SessionStart hook -- see docs\CONFIGURATION.md"
}
