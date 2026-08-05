[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [ValidateSet('check', 'run', 'build', 'test')]
    [string]$Command = 'run',

    [switch]$Release,

    [switch]$Locked
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'The bundled Dear ImGui bridge currently targets Windows x64.'
}

$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot = (Resolve-Path (Join-Path $packageRoot '..\..')).Path
$imguiNativeRoot = Join-Path $packageRoot 'native\windows-x86_64'
$sdlNativeRoot = Join-Path $workspaceRoot 'vendor\sdl3\native\windows-x86_64'
$wgpuNativeRoot = Join-Path $workspaceRoot 'vendor\wgpu\native\windows-x86_64'
$imguiLibrary = Join-Path $imguiNativeRoot 'imgui.lib'
$imguiRuntime = Join-Path $imguiNativeRoot 'imgui.dll'
$sdlLibrary = Join-Path $sdlNativeRoot 'SDL3.lib'
$sdlRuntime = Join-Path $sdlNativeRoot 'SDL3.dll'
$wgpuRuntime = Join-Path $wgpuNativeRoot 'wgpu_native.dll'
$projectRoot = (Resolve-Path -LiteralPath $Project).Path

. (Join-Path $workspaceRoot 'scripts\assert-vendored-checksums.ps1')
Assert-VendoredChecksums -PackageRoot $packageRoot -RelativePath @(
    'native/windows-x86_64/imgui.dll',
    'native/windows-x86_64/imgui.lib'
)
Assert-VendoredChecksums -PackageRoot (Join-Path $workspaceRoot 'vendor\sdl3') -RelativePath @(
    'native/windows-x86_64/SDL3.dll',
    'native/windows-x86_64/SDL3.lib'
)
Assert-VendoredChecksums -PackageRoot (Join-Path $workspaceRoot 'vendor\wgpu') -RelativePath @(
    'native/windows-x86_64/wgpu_native.dll',
    'native/windows-x86_64/wgpu_native.lib'
)

$compiler = Get-Command reimer -ErrorAction Stop
$arguments = @($Command, $projectRoot)
if ($Release) {
    $arguments += '--release'
}
if ($Locked) {
    $arguments += '--locked'
}

$previousPath = $env:PATH
$previousLib = $env:LIB
try {
    $env:PATH = "$imguiNativeRoot;$sdlNativeRoot;$wgpuNativeRoot;$previousPath"
    $nativeLibraries = "$imguiNativeRoot;$sdlNativeRoot;$wgpuNativeRoot"
    $env:LIB = if ([string]::IsNullOrEmpty($previousLib)) {
        $nativeLibraries
    } else {
        "$nativeLibraries;$previousLib"
    }

    $executionDirectory = if ($Command -eq 'run') {
        $directory = Join-Path $projectRoot 'target'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $directory
    } else {
        $projectRoot
    }
    Push-Location -LiteralPath $executionDirectory
    try {
        & $compiler.Source @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "The compiler command failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    if ($Command -eq 'build') {
        $profile = if ($Release) { 'release' } else { 'debug' }
        $outputDirectory = Join-Path $projectRoot "target\reimer\$profile"
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        Copy-Item -LiteralPath $imguiRuntime -Destination (Join-Path $outputDirectory 'imgui.dll') -Force
        Copy-Item -LiteralPath $sdlRuntime -Destination (Join-Path $outputDirectory 'SDL3.dll') -Force
        Copy-Item -LiteralPath $wgpuRuntime -Destination (Join-Path $outputDirectory 'wgpu_native.dll') -Force
    }
}
finally {
    $env:PATH = $previousPath
    $env:LIB = $previousLib
}
