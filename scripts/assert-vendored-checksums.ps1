Set-StrictMode -Version Latest

function Assert-VendoredChecksums {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string[]]$RelativePath
    )

    $ErrorActionPreference = 'Stop'
    $resolvedRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
    $manifestPath = Join-Path $resolvedRoot 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Vendored checksum manifest is missing at '$manifestPath'."
    }

    $expectedHashes = @{}
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $entry = [regex]::Match($line, '^([0-9a-fA-F]{64})  (.+)$')
        if (-not $entry.Success) {
            throw "Malformed vendored checksum entry in '$manifestPath': $line"
        }
        $name = $entry.Groups[2].Value.Replace('\', '/')
        $expectedHashes[$name] = $entry.Groups[1].Value.ToLowerInvariant()
    }

    foreach ($relative in $RelativePath) {
        $normalized = $relative.Replace('\', '/')
        if (-not $expectedHashes.ContainsKey($normalized)) {
            throw "Vendored artifact '$normalized' has no checksum in '$manifestPath'."
        }
        $path = Join-Path $resolvedRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Vendored artifact is missing at '$path'."
        }
        $resolvedPath = (Resolve-Path -LiteralPath $path).Path
        $separator = [IO.Path]::DirectorySeparatorChar
        $rootPrefix = $resolvedRoot.TrimEnd(
            $separator,
            [IO.Path]::AltDirectorySeparatorChar
        ) + $separator
        $comparison = if ($env:OS -eq 'Windows_NT') {
            [StringComparison]::OrdinalIgnoreCase
        } else {
            [StringComparison]::Ordinal
        }
        if (-not $resolvedPath.StartsWith($rootPrefix, $comparison)) {
            throw "Vendored artifact '$path' resolves outside '$resolvedRoot'."
        }
        $actual = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expectedHashes[$normalized]) {
            throw "Checksum mismatch for '$path': expected $($expectedHashes[$normalized]), got $actual."
        }
    }
}
