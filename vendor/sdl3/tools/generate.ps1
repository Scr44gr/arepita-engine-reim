param(
    [string]$SdlSource = ""
)

$ErrorActionPreference = "Stop"
$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workspaceRoot = (Resolve-Path (Join-Path $packageRoot "..\..")).Path
$sdlVersion = "3.4.12"
$sourceArchiveHash = "3d4de8967a49c0451e775a0c1e9022092c19fdef41ba38a83fcf031c5a6496e2"
$sourceArchiveUrl = "https://github.com/libsdl-org/SDL/releases/download/release-$sdlVersion/SDL3-$sdlVersion.zip"
$cacheRoot = Join-Path $workspaceRoot "target\sdl-api-gen"

if ([string]::IsNullOrWhiteSpace($SdlSource)) {
    $downloadDirectory = Join-Path $cacheRoot "downloads"
    $sourcesDirectory = Join-Path $cacheRoot "sources"
    $sourceArchive = Join-Path $downloadDirectory "SDL3-$sdlVersion.zip"
    $sourceRoot = Join-Path $sourcesDirectory "SDL3-$sdlVersion"
    New-Item -ItemType Directory -Force $downloadDirectory, $sourcesDirectory | Out-Null
    if (-not (Test-Path -LiteralPath $sourceArchive)) {
        Write-Host "Downloading the pinned SDL $sdlVersion source archive..."
        Invoke-WebRequest -Uri $sourceArchiveUrl -OutFile $sourceArchive
    }
    $actualHash = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $sourceArchiveHash) {
        throw "SDL source archive checksum mismatch: expected $sourceArchiveHash, got $actualHash"
    }
    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        Expand-Archive -LiteralPath $sourceArchive -DestinationPath $sourcesDirectory
    }
}
else {
    $sourceRoot = (Resolve-Path $SdlSource).Path
}

$includeRoot = Join-Path $sourceRoot "include\SDL3\SDL.h"
if (-not (Test-Path -LiteralPath $includeRoot)) {
    throw "SDL source tree at $sourceRoot does not contain include\SDL3\SDL.h"
}
$functions = Join-Path $packageRoot "src\raw\functions.reim"
$types = Join-Path $packageRoot "src\raw\types.reim"
$constants = Join-Path $packageRoot "src\raw\constants.reim"
$coverage = Join-Path $packageRoot "coverage.toml"
$workDirectory = $cacheRoot
$translationUnit = Join-Path $workDirectory "sdl_all.c"
$preprocessed = Join-Path $workDirectory "sdl_all.preprocessed.c"
$macroDefinitions = Join-Path $workDirectory "sdl_all.macros.c"
$macroProbe = Join-Path $workDirectory "sdl_macros.c"
$macroExpansions = Join-Path $workDirectory "sdl_macros.expanded.c"
$layoutAssertions = Join-Path $workDirectory "sdl_layout_assertions.c"
$layoutObject = Join-Path $workDirectory "sdl_layout_assertions.obj"
$includeDirectory = Join-Path $sourceRoot "include"

New-Item -ItemType Directory -Force $workDirectory | Out-Null
[System.IO.File]::WriteAllText(
    $translationUnit,
    "#include <SDL3/SDL.h>`r`n",
    [System.Text.UTF8Encoding]::new($false)
)
$layoutSource = @"
#include <SDL3/SDL.h>
_Static_assert(sizeof(SDL_Event) == 128, "SDL_Event size changed");
_Static_assert(_Alignof(SDL_Event) == 8, "SDL_Event alignment changed");
_Static_assert(sizeof(SDL_GamepadBinding) == 32, "SDL_GamepadBinding size changed");
_Static_assert(_Alignof(SDL_GamepadBinding) == 4, "SDL_GamepadBinding alignment changed");
_Static_assert(sizeof(SDL_HapticEffect) == 72, "SDL_HapticEffect size changed");
_Static_assert(_Alignof(SDL_HapticEffect) == 8, "SDL_HapticEffect alignment changed");
"@
[System.IO.File]::WriteAllText(
    $layoutAssertions,
    $layoutSource,
    [System.Text.UTF8Encoding]::new($false)
)

$compiler = Get-Command cl.exe -ErrorAction SilentlyContinue
$vcvars = $null
if ($null -eq $compiler) {
    $installerDirectory = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
    $vswhere = Join-Path $installerDirectory "vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "MSVC was not found. Install the Visual Studio C++ build tools or run from a Developer PowerShell."
    }
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installation)) {
        throw "Visual Studio C++ build tools were not found."
    }
    $vcvars = Join-Path $installation.Trim() "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path -LiteralPath $vcvars)) {
        throw "The MSVC x64 environment script was not found at $vcvars"
    }
    $environmentCommand = 'call "' + $vcvars + '" >nul && set'
    $environmentLines = & cmd.exe /d /c $environmentCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Initializing the MSVC x64 environment failed with exit code $LASTEXITCODE"
    }
    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $name = $line.Substring(0, $separator)
            $value = $line.Substring($separator + 1)
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
    $compiler = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($null -eq $compiler) {
        throw "MSVC was initialized, but cl.exe is still unavailable."
    }
}

function Invoke-SdlPreprocessor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputFile,
        [Parameter(Mandatory = $true)]
        [string]$OutputFile,
        [switch]$PreserveMacros
    )

    $macroOption = if ($PreserveMacros) { " /d1PP" } else { "" }
    $command = '/d /c cl /nologo /E' + $macroOption + ' /I"' + $includeDirectory + '" "' + $InputFile + '" > "' + $OutputFile + '"'
    & cmd.exe $command
    if ($LASTEXITCODE -ne 0) {
        throw "Preprocessing $InputFile failed with exit code $LASTEXITCODE"
    }
}

function Test-SdlStorageLayouts {
    & $compiler.Source /nologo /std:c11 /c "/I$includeDirectory" "/Fo$layoutObject" $layoutAssertions
    if ($LASTEXITCODE -ne 0) {
        throw "Verifying SDL storage layouts failed with exit code $LASTEXITCODE"
    }
}

Invoke-SdlPreprocessor -InputFile $translationUnit -OutputFile $preprocessed
Invoke-SdlPreprocessor -InputFile $translationUnit -OutputFile $macroDefinitions -PreserveMacros
Test-SdlStorageLayouts

Push-Location $workspaceRoot
try {
    cargo run -q -p sdl-api-gen --bin sdl-api-gen -- macro-probe $macroDefinitions $macroProbe
    if ($LASTEXITCODE -ne 0) {
        throw "Generating the SDL macro probe failed with exit code $LASTEXITCODE"
    }
    Invoke-SdlPreprocessor -InputFile $macroProbe -OutputFile $macroExpansions
    cargo run -q -p sdl-api-gen --bin sdl-api-gen -- $sourceRoot $preprocessed $macroExpansions $functions $types $constants $coverage
    if ($LASTEXITCODE -ne 0) {
        throw "SDL binding generation failed with exit code $LASTEXITCODE"
    }
    cargo run -q -p reimer-cli -- fmt $packageRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Formatting generated bindings failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

Write-Host "Generated SDL raw functions, types, enum and macro constants, and coverage metadata."
