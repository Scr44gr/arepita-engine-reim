[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')
$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot = (Resolve-Path (Join-Path $packageRoot '..\..')).Path

& (Join-Path $PSScriptRoot 'fetch.ps1') -UpdateHeaders

Push-Location -LiteralPath $workspaceRoot
try {
    cargo run -q -p wgpu-api-gen -- `
        (Join-Path $packageRoot 'upstream\include\webgpu.h') `
        (Join-Path $packageRoot 'upstream\include\wgpu.h') `
        (Join-Path $packageRoot 'src\raw\types.reim') `
        (Join-Path $packageRoot 'src\raw\constants.reim') `
        (Join-Path $packageRoot 'src\raw\functions.reim') `
        (Join-Path $packageRoot 'coverage.toml')
    if ($LASTEXITCODE -ne 0) {
        throw "Generating Reimer declarations failed with exit code $LASTEXITCODE."
    }
    cargo run -q -p reimer-cli -- fmt $packageRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Formatting generated declarations failed with exit code $LASTEXITCODE."
    }
    cargo run -q -p reimer-cli -- check $packageRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Checking generated declarations failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$checksumFiles = @(
    'LICENSE-APACHE',
    'LICENSE-MIT',
    'LICENSE-WEBGPU',
    'upstream/include/webgpu.h',
    'upstream/include/wgpu.h',
    'bridge/wgpu_bridge.c',
    'src/raw/types.reim',
    'src/raw/constants.reim',
    'src/raw/functions.reim'
)
$platform = Get-WgpuPlatform
if ($platform.StartsWith('windows-')) {
    $checksumFiles += `
        "native/$platform/wgpu_native.dll", `
        "native/$platform/wgpu_native.lib", `
        "native/$platform/wgpu_bridge.dll", `
        "native/$platform/wgpu_bridge.lib"
}
elseif ($platform.StartsWith('linux-')) {
    $checksumFiles += `
        "native/$platform/libwgpu_native.so", `
        "native/$platform/libwgpu_bridge.so"
}
else {
    $checksumFiles += `
        "native/$platform/libwgpu_native.dylib", `
        "native/$platform/libwgpu_bridge.dylib"
}
$checksumLines = foreach ($relativePath in $checksumFiles) {
    $path = Join-Path $packageRoot $relativePath
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relativePath"
}
[System.IO.File]::WriteAllText(
    (Join-Path $packageRoot 'checksums.sha256'),
    ($checksumLines -join "`n") + "`n",
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host 'Generated and verified the documented wgpu-native bindings.'
