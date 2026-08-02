[CmdletBinding()]
param(
    [switch]$UpdateHeaders
)

. (Join-Path $PSScriptRoot 'common.ps1')

$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot = (Resolve-Path (Join-Path $packageRoot '..\..')).Path
$cacheRoot = Join-Path $workspaceRoot 'target\wgpu-api-gen'
$downloadRoot = Join-Path $cacheRoot 'downloads'
$sourceRoot = Join-Path $cacheRoot 'sources'
$platform = Get-WgpuPlatform
$artifacts = Get-Content (Join-Path $packageRoot 'artifacts.lock.json') -Raw | ConvertFrom-Json
$sourceLock = Get-Content (Join-Path $packageRoot 'source.lock.json') -Raw | ConvertFrom-Json
$artifact = $artifacts.platforms.$platform
if ($null -eq $artifact) {
    throw "No pinned wgpu-native artifact exists for '$platform'."
}

New-Item -ItemType Directory -Force $downloadRoot, $sourceRoot | Out-Null
$archive = Join-Path $downloadRoot $artifact.archive
Get-PinnedFile `
    -Url "$($artifacts.base_url)/$($artifact.archive)" `
    -Destination $archive `
    -ExpectedHash $artifact.sha256

$extracted = Join-Path $sourceRoot $platform
$releaseMarker = Join-Path $extracted 'wgpu-native-meta\wgpu-native-git-tag'
if (-not (Test-Path -LiteralPath $releaseMarker) -or
    (Get-Content -LiteralPath $releaseMarker -Raw).Trim() -ne $artifacts.release) {
    if (Test-Path -LiteralPath $extracted) {
        $resolvedCache = (Resolve-Path -LiteralPath $cacheRoot).Path
        $resolvedExtracted = (Resolve-Path -LiteralPath $extracted).Path
        if (-not $resolvedExtracted.StartsWith($resolvedCache, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to replace extraction directory outside '$resolvedCache'."
        }
        Remove-Item -LiteralPath $resolvedExtracted -Recurse -Force
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $extracted -Force
}

$webgpuHeader = Join-Path $extracted 'include\webgpu\webgpu.h'
$nativeHeader = Join-Path $extracted 'include\webgpu\wgpu.h'
Assert-FileHash -Path $webgpuHeader -ExpectedHash $sourceLock.headers.'webgpu.h'
Assert-FileHash -Path $nativeHeader -ExpectedHash $sourceLock.headers.'wgpu.h'

if ($UpdateHeaders) {
    $includeRoot = Join-Path $packageRoot 'upstream\include'
    New-Item -ItemType Directory -Force $includeRoot | Out-Null
    Copy-Item -LiteralPath $webgpuHeader -Destination (Join-Path $includeRoot 'webgpu.h') -Force
    Copy-Item -LiteralPath $nativeHeader -Destination (Join-Path $includeRoot 'wgpu.h') -Force
}

$nativeRoot = Join-Path $packageRoot "native\$platform"
New-Item -ItemType Directory -Force $nativeRoot | Out-Null
$libraryRoot = Join-Path $extracted 'lib'
if ($platform.StartsWith('windows-')) {
    Copy-Item -LiteralPath (Join-Path $libraryRoot 'wgpu_native.dll') `
        -Destination (Join-Path $nativeRoot 'wgpu_native.dll') -Force
    Copy-Item -LiteralPath (Join-Path $libraryRoot 'wgpu_native.dll.lib') `
        -Destination (Join-Path $nativeRoot 'wgpu_native.lib') -Force
}
elseif ($platform.StartsWith('linux-')) {
    Copy-Item -LiteralPath (Join-Path $libraryRoot 'libwgpu_native.so') `
        -Destination (Join-Path $nativeRoot 'libwgpu_native.so') -Force
}
else {
    Copy-Item -LiteralPath (Join-Path $libraryRoot 'libwgpu_native.dylib') `
        -Destination (Join-Path $nativeRoot 'libwgpu_native.dylib') -Force
}

Build-WgpuBridge -PackageRoot $packageRoot -Platform $platform

Write-Host "Prepared pinned wgpu-native runtime for $platform."
