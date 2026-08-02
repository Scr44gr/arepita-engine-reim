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
$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot = (Resolve-Path (Join-Path $packageRoot '..\..')).Path
$projectRoot = (Resolve-Path -LiteralPath $Project).Path

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$architecture = switch ($architecture) {
    'x64' { 'x86_64' }
    'arm64' { 'aarch64' }
    default { throw "Unsupported architecture '$architecture'." }
}
$platform = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    "windows-$architecture"
} elseif ($IsLinux) {
    "linux-$architecture"
} elseif ($IsMacOS) {
    "macos-$architecture"
} else {
    throw 'Unsupported operating system.'
}

$nativeRoot = Join-Path $packageRoot "native\$platform"
$runtimeName = if ($platform.StartsWith('windows-')) {
    'media_codecs.dll'
} elseif ($platform.StartsWith('linux-')) {
    'libmedia_codecs.so'
} else {
    'libmedia_codecs.dylib'
}
$runtime = Join-Path $nativeRoot $runtimeName
if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    throw "The media codec runtime for '$platform' is not bundled. Run tools/build.ps1 on that target first."
}

. (Join-Path $workspaceRoot 'scripts\assert-vendored-checksums.ps1')
$relativeRuntime = "native/$platform/$runtimeName"
$checksumTargets = @($relativeRuntime)
if ($platform.StartsWith('windows-')) {
    $checksumTargets += "native/$platform/media_codecs.lib"
}
Assert-VendoredChecksums -PackageRoot $packageRoot -RelativePath $checksumTargets

$compiler = Get-Command reimer -ErrorAction Stop
$arguments = @($Command, $projectRoot)
if ($Release) {
    $arguments += '--release'
}
if ($Locked) {
    $arguments += '--locked'
}

$previousPath = $env:PATH
$previousLibraryPath = $env:LD_LIBRARY_PATH
$previousMacLibraryPath = $env:DYLD_LIBRARY_PATH
$previousLib = $env:LIB
try {
    if ($platform.StartsWith('windows-')) {
        $env:PATH = "$nativeRoot;$previousPath"
        $env:LIB = if ([string]::IsNullOrEmpty($previousLib)) {
            $nativeRoot
        } else {
            "$nativeRoot;$previousLib"
        }
    } elseif ($platform.StartsWith('linux-')) {
        $env:LD_LIBRARY_PATH = if ([string]::IsNullOrEmpty($previousLibraryPath)) {
            $nativeRoot
        } else {
            "$nativeRoot`:$previousLibraryPath"
        }
    } else {
        $env:DYLD_LIBRARY_PATH = if ([string]::IsNullOrEmpty($previousMacLibraryPath)) {
            $nativeRoot
        } else {
            "$nativeRoot`:$previousMacLibraryPath"
        }
    }

    Push-Location -LiteralPath $projectRoot
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
        Copy-Item -LiteralPath $runtime -Destination (Join-Path $outputDirectory $runtimeName) -Force
    }
}
finally {
    $env:PATH = $previousPath
    $env:LD_LIBRARY_PATH = $previousLibraryPath
    $env:DYLD_LIBRARY_PATH = $previousMacLibraryPath
    $env:LIB = $previousLib
}
