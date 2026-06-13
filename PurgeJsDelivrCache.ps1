<#
.SYNOPSIS
Purges jsDelivr cache for version manifest JSON files.

.EXAMPLES
.\PurgeJsDelivrCache.ps1 LogisticsPlanner.json

.EXAMPLES
.\PurgeJsDelivrCache.ps1

.EXAMPLES
.\PurgeJsDelivrCache.ps1 -All
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]] $Files,

    [string] $Owner = "ibox233",

    [string] $Repo = "MyMod_Version",

    [string] $Ref = "main",

    [switch] $All,

    [switch] $DryRun
)

$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    $root = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($root)) {
        return $root.Trim()
    }

    return (Get-Location).Path
}

function Get-ChangedJsonFiles {
    $upstream = & git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)) {
        $changed = & git diff --name-only '@{u}..HEAD' -- '*.json' 2>$null
        if ($LASTEXITCODE -eq 0 -and $changed) {
            return $changed
        }
    }

    $latest = & git diff-tree --no-commit-id --name-only -r HEAD -- '*.json' 2>$null
    if ($LASTEXITCODE -eq 0 -and $latest) {
        return $latest
    }

    $working = @()
    $working += & git diff --name-only -- '*.json' 2>$null
    $working += & git diff --cached --name-only -- '*.json' 2>$null
    $working += & git ls-files --others --exclude-standard -- '*.json' 2>$null
    return $working
}

function Convert-ToRelativePath {
    param(
        [string] $RepoRoot,
        [string] $Path
    )

    $normalized = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($normalized)) {
        $rootFull = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')
        $fileFull = (Resolve-Path -LiteralPath $normalized).Path
        if (!$fileFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "File is outside the repository: $normalized"
        }

        $normalized = $fileFull.Substring($rootFull.Length).TrimStart('\', '/')
    }

    $normalized = $normalized.Replace('\', '/').TrimStart('.', '/')
    if (!$normalized.EndsWith(".json", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Only JSON files can be purged: $normalized"
    }

    $fullPath = Join-Path $RepoRoot $normalized
    if (!(Test-Path -LiteralPath $fullPath)) {
        throw "File does not exist: $normalized"
    }

    return $normalized
}

function Convert-ToUrlPath {
    param([string] $Path)

    return (($Path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

$repoRoot = Get-RepoRoot

if ($All) {
    $Files = Get-ChildItem -LiteralPath $repoRoot -Filter "*.json" -File | Select-Object -ExpandProperty Name
} elseif (!$Files -or $Files.Count -eq 0) {
    $Files = Get-ChangedJsonFiles
}

$targets = @($Files | ForEach-Object { Convert-ToRelativePath $repoRoot $_ } | Where-Object { $_ } | Sort-Object -Unique)
if ($targets.Count -eq 0) {
    Write-Host "No JSON manifests found to purge."
    exit 0
}

$failed = 0
foreach ($target in $targets) {
    $urlPath = Convert-ToUrlPath $target
    $url = "https://purge.jsdelivr.net/gh/$Owner/$Repo@$Ref/$urlPath"

    if ($DryRun) {
        Write-Host "Would purge $url"
        continue
    }

    try {
        $response = Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 20
        $status = if ($response.status) { $response.status } else { "unknown" }
        Write-Host "Purged $target ($status)"
    } catch {
        $failed++
        Write-Warning "Failed to purge $target`: $($_.Exception.Message)"
    }
}

if ($failed -gt 0) {
    exit 1
}
