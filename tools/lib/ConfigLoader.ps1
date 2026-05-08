# ConfigLoader.ps1 -- declarative config layer for cleanup-orphans.ps1.
#
# Loads ~/.reap/config.json (or a path passed in) and produces a config
# object the predicate consumes. Ships with safe defaults so the engine
# is always a no-op when no config exists -- aggression is opt-in.
#
# Loading precedence (highest wins):
#   1. $env:REAP_CONFIG_PATH (CI / scripts override)
#   2. ~/.reap/config.json   (normal user config)
#   3. Built-in default      (safe no-op: kills nothing)
#
# Schema (config.json):
#
#   {
#     "schema_version":          1,
#     "min_age_seconds":         30,
#     "spare_classifications":   ["claude", "lsp", "plugin-runtime", "unknown"],
#     "spare_cmdline_patterns":  ["my-stateful-tool", "in-house-runtime"],
#     "kill_classifications":    ["mcp-stdio", "cmd-shim", "npx-wrapper"],
#     "kill_names":              [],
#     "custom_classifiers": [
#       {"pattern": "my-tool",      "classification": "plugin-runtime"},
#       {"pattern": "internal-mcp", "classification": "mcp-stdio"}
#     ]
#   }
#
# Decision order in Test-ReapPredicate (first match wins):
#   1. Not orphan      -> skip (defensive; caller already filtered)
#   2. Too young       -> skip
#   3. Spare classification match -> skip
#   4. Spare cmdline-pattern match -> skip
#   5. Kill name match  -> kill
#   6. Kill classification match -> kill
#   7. Default          -> skip (fail-safe)
#
# This file is dot-sourced by cleanup-orphans.ps1.

function Get-ReapConfig {
    <#
    .SYNOPSIS
    Load reap config from disk, applying defaults for any missing fields.

    .PARAMETER Path
    Override path. If not set, uses $env:REAP_CONFIG_PATH or
    ~/.reap/config.json in that order.

    .OUTPUTS
    Hashtable with fields: schema_version, min_age_seconds,
    spare_classifications, spare_cmdline_patterns, kill_classifications,
    kill_names, custom_classifiers, source.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $Path)

    # Built-in safe default -- kills nothing. This is what runs out of the
    # box if the user has no ~/.reap/config.json. It must be a no-op so
    # `cleanup-orphans.ps1 -Force` can never wreck a fresh install.
    $defaults = @{
        schema_version         = 1
        min_age_seconds        = 30
        spare_classifications  = @('claude', 'lsp', 'plugin-runtime', 'unknown')
        spare_cmdline_patterns = @()
        kill_classifications   = @()
        kill_names             = @()
        custom_classifiers     = @()
        source                 = 'built-in-default'
    }

    if (-not $Path) {
        if ($env:REAP_CONFIG_PATH) {
            $Path = $env:REAP_CONFIG_PATH
        } else {
            $Path = Join-Path $env:USERPROFILE '.reap\config.json'
        }
    }

    if (-not (Test-Path $Path)) {
        return $defaults
    }

    try {
        $raw = [IO.File]::ReadAllText($Path)
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "reap: failed to parse $Path -- using safe defaults. error=$_"
        return $defaults
    }

    # Merge: user fields override defaults. Each field validated to a
    # safe type so a malformed config can't crash the engine.
    $result = @{ source = $Path }
    foreach ($key in $defaults.Keys) {
        if ($key -eq 'source') { continue }
        $userVal = $cfg.PSObject.Properties[$key]
        if ($userVal -and $null -ne $userVal.Value) {
            $result[$key] = $userVal.Value
        } else {
            $result[$key] = $defaults[$key]
        }
    }

    # Coerce array fields to actual arrays (single-value JSON yields scalar)
    foreach ($arrKey in 'spare_classifications', 'spare_cmdline_patterns',
                        'kill_classifications', 'kill_names',
                        'custom_classifiers') {
        if ($null -eq $result[$arrKey]) {
            $result[$arrKey] = @()
        } else {
            $result[$arrKey] = @($result[$arrKey])
        }
    }

    # Coerce numerics
    $result.min_age_seconds = [int]$result.min_age_seconds
    $result.schema_version  = [int]$result.schema_version

    return $result
}

function Test-ReapPredicate {
    <#
    .SYNOPSIS
    Apply the loaded config to a single process and decide kill/skip.

    .PARAMETER Process
    PSCustomObject from Get-CCProcessSnapshot.

    .PARAMETER Classification
    String from Get-ProcessClassification.

    .PARAMETER Age
    [TimeSpan] from Get-ProcessAge.

    .PARAMETER IsOrphan
    [bool], expected $true -- caller filters to orphans before invoking.

    .PARAMETER Config
    Hashtable from Get-ReapConfig.

    .OUTPUTS
    [bool] -- $true if the process is killable per config, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]            $Process,
        [Parameter(Mandatory)] [string]   $Classification,
        [Parameter(Mandatory)] [TimeSpan] $Age,
        [Parameter(Mandatory)] [bool]     $IsOrphan,
        [Parameter(Mandatory)] [hashtable] $Config
    )

    if (-not $IsOrphan) { return $false }
    if ($Age.TotalSeconds -lt $Config.min_age_seconds) { return $false }

    if ($Classification -in $Config.spare_classifications) { return $false }

    if ($Process.CmdLine) {
        foreach ($pattern in $Config.spare_cmdline_patterns) {
            if (-not $pattern) { continue }
            if ($Process.CmdLine -match $pattern) { return $false }
        }
    }

    if ($Process.Name -and $Process.Name -in $Config.kill_names) {
        return $true
    }

    if ($Classification -in $Config.kill_classifications) {
        return $true
    }

    return $false
}
