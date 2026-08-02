[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [ValidateSet('check', 'run', 'build', 'test')][string]$Command = 'run',
    [switch]$Release,
    [switch]$Locked
)

$ErrorActionPreference = 'Stop'
$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot = (Resolve-Path (Join-Path $packageRoot '..\..')).Path
$sdlRoot = Join-Path $workspaceRoot 'vendor\sdl3\native\windows-x86_64'
$wgpuRoot = Join-Path $workspaceRoot 'vendor\wgpu\native\windows-x86_64'

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'The bundled SDL3 runtime currently supports Windows x64.'
}
. (Join-Path $workspaceRoot 'scripts\assert-vendored-checksums.ps1')
Assert-VendoredChecksums -PackageRoot (Join-Path $workspaceRoot 'vendor\sdl3') -RelativePath @(
    'native/windows-x86_64/SDL3.dll',
    'native/windows-x86_64/SDL3.lib'
)
Assert-VendoredChecksums -PackageRoot (Join-Path $workspaceRoot 'vendor\wgpu') -RelativePath @(
    'native/windows-x86_64/wgpu_native.dll',
    'native/windows-x86_64/wgpu_native.lib',
    'native/windows-x86_64/wgpu_bridge.dll',
    'native/windows-x86_64/wgpu_bridge.lib'
)

$debugCompiler = Join-Path $workspaceRoot 'target\debug\reimer.exe'
$releaseCompiler = Join-Path $workspaceRoot 'target\release\reimer.exe'
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
try {
    $env:PATH = "$wgpuRoot;$sdlRoot;$previousPath"
    $env:LIB = if ([string]::IsNullOrEmpty($previousLib)) {
        "$wgpuRoot;$sdlRoot"
    } else {
        "$wgpuRoot;$sdlRoot;$previousLib"
    }

    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "The compiler command failed with exit code $LASTEXITCODE."
    }

    if ($Command -eq 'build') {
        $profile = if ($Release) { 'release' } else { 'debug' }
        $outputDirectory = Join-Path $projectRoot "target\reimer\$profile"
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        foreach ($runtime in @('SDL3.dll', 'wgpu_native.dll', 'wgpu_bridge.dll')) {
            $sourceRoot = if ($runtime -eq 'SDL3.dll') { $sdlRoot } else { $wgpuRoot }
            Copy-Item -LiteralPath (Join-Path $sourceRoot $runtime) `
                -Destination (Join-Path $outputDirectory $runtime) -Force
        }
    }
}
finally {
    $env:PATH = $previousPath
    $env:LIB = $previousLib
}
