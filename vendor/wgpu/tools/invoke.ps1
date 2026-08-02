[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [ValidateSet('check', 'run', 'build', 'test')][string]$Command = 'run',
    [switch]$Release,
    [switch]$Locked
)

. (Join-Path $PSScriptRoot 'common.ps1')
$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$platform = Get-WgpuPlatform
$nativeRoot = Join-Path $packageRoot "native\$platform"
$runtimeNames = if ($platform.StartsWith('windows-')) {
    @('wgpu_native.dll', 'wgpu_bridge.dll')
}
elseif ($platform.StartsWith('linux-')) {
    @('libwgpu_native.so', 'libwgpu_bridge.so')
}
else {
    @('libwgpu_native.dylib', 'libwgpu_bridge.dylib')
}
$missingRuntime = $runtimeNames | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $nativeRoot $_))
}
if ($missingRuntime.Count -ne 0) {
    & (Join-Path $PSScriptRoot 'fetch.ps1')
}

$workspaceRoot = (Resolve-Path (Join-Path $packageRoot '..\..')).Path
. (Join-Path $workspaceRoot 'scripts\assert-vendored-checksums.ps1')
$checksumPaths = @($runtimeNames | ForEach-Object { "native/$platform/$_" })
if ($platform.StartsWith('windows-')) {
    $checksumPaths += @(
        "native/$platform/wgpu_native.lib",
        "native/$platform/wgpu_bridge.lib"
    )
}
Assert-VendoredChecksums -PackageRoot $packageRoot -RelativePath $checksumPaths
$compilerName = if ($platform.StartsWith('windows-')) { 'reimer.exe' } else { 'reimer' }
$debugCompiler = Join-Path $workspaceRoot "target\debug\$compilerName"
$releaseCompiler = Join-Path $workspaceRoot "target\release\$compilerName"
$compiler = if (Test-Path -LiteralPath $debugCompiler) {
    $debugCompiler
}
elseif (Test-Path -LiteralPath $releaseCompiler) {
    $releaseCompiler
}
else {
    (Get-Command reimer -ErrorAction Stop).Source
}
$projectRoot = (Resolve-Path -LiteralPath $Project).Path
$arguments = @($Command, $projectRoot)
if ($Release) { $arguments += '--release' }
if ($Locked) { $arguments += '--locked' }

$previousPath = $env:PATH
$previousLib = $env:LIB
$previousLdLibraryPath = $env:LD_LIBRARY_PATH
$previousDyldLibraryPath = $env:DYLD_LIBRARY_PATH
try {
    if ($platform.StartsWith('windows-')) {
        $env:PATH = "$nativeRoot;$previousPath"
        $env:LIB = if ([string]::IsNullOrEmpty($previousLib)) {
            $nativeRoot
        } else {
            "$nativeRoot;$previousLib"
        }
    }
    elseif ($platform.StartsWith('linux-')) {
        $env:LD_LIBRARY_PATH = if ([string]::IsNullOrEmpty($previousLdLibraryPath)) {
            $nativeRoot
        } else {
            "$nativeRoot`:$previousLdLibraryPath"
        }
    }
    else {
        $env:DYLD_LIBRARY_PATH = if ([string]::IsNullOrEmpty($previousDyldLibraryPath)) {
            $nativeRoot
        } else {
            "$nativeRoot`:$previousDyldLibraryPath"
        }
    }

    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "The compiler command failed with exit code $LASTEXITCODE."
    }

    if ($Command -eq 'build') {
        $profile = if ($Release) { 'release' } else { 'debug' }
        $outputDirectory = Join-Path $projectRoot "target\reimer\$profile"
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        foreach ($runtimeName in $runtimeNames) {
            Copy-Item -LiteralPath (Join-Path $nativeRoot $runtimeName) `
                -Destination (Join-Path $outputDirectory $runtimeName) -Force
        }
    }
}
finally {
    $env:PATH = $previousPath
    $env:LIB = $previousLib
    $env:LD_LIBRARY_PATH = $previousLdLibraryPath
    $env:DYLD_LIBRARY_PATH = $previousDyldLibraryPath
}
