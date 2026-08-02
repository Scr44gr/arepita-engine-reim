param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest,
    [Parameter(Mandatory = $true)]
    [string]$Output,
    [ValidateSet("debug", "release")]
    [string]$Profile = "release"
)

$ErrorActionPreference = "Stop"
$engineRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cookerRoot = Join-Path $engineRoot "tools\cooker"
$codecVendor = Join-Path $engineRoot "vendor\media-codecs"
$manifestPath = (Resolve-Path $Manifest).Path
$outputPath = [System.IO.Path]::GetFullPath($Output)

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$architecture = switch ($architecture) {
    "x64" { "x86_64" }
    "arm64" { "aarch64" }
    default { throw "Unsupported architecture '$architecture'." }
}
$platform = if ($IsWindows -or $env:OS -eq "Windows_NT") {
    "windows-$architecture"
} elseif ($IsLinux) {
    "linux-$architecture"
} elseif ($IsMacOS) {
    "macos-$architecture"
} else {
    throw "Unsupported operating system."
}
$nativeRoot = Join-Path $codecVendor "native\$platform"
$runtimeName = if ($platform.StartsWith("windows-")) {
    "media_codecs.dll"
} elseif ($platform.StartsWith("linux-")) {
    "libmedia_codecs.so"
} else {
    "libmedia_codecs.dylib"
}
if (-not (Test-Path -LiteralPath (Join-Path $nativeRoot $runtimeName) -PathType Leaf)) {
    throw "The media codec runtime for '$platform' is not bundled."
}

. (Join-Path $engineRoot "scripts\assert-vendored-checksums.ps1")
$checksumTargets = @("native/$platform/$runtimeName")
if ($platform.StartsWith("windows-")) {
    $checksumTargets += "native/$platform/media_codecs.lib"
}
Assert-VendoredChecksums -PackageRoot $codecVendor -RelativePath $checksumTargets

$arguments = @("run", $cookerRoot)
if ($Profile -eq "release") {
    $arguments += "--release"
}
$arguments += @("--refresh", "--", "--manifest", $manifestPath, "--output", $outputPath)

$compiler = Get-Command reimer -ErrorAction Stop
$previousPath = $env:PATH
$previousLibraryPath = $env:LD_LIBRARY_PATH
$previousMacLibraryPath = $env:DYLD_LIBRARY_PATH
$previousLib = $env:LIB
try {
    if ($platform.StartsWith("windows-")) {
        $env:PATH = "$nativeRoot;$previousPath"
        $env:LIB = if ([string]::IsNullOrEmpty($previousLib)) {
            $nativeRoot
        } else {
            "$nativeRoot;$previousLib"
        }
    } elseif ($platform.StartsWith("linux-")) {
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

    & $compiler.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Asset cooking failed with exit code $LASTEXITCODE."
    }
}
finally {
    $env:PATH = $previousPath
    $env:LD_LIBRARY_PATH = $previousLibraryPath
    $env:DYLD_LIBRARY_PATH = $previousMacLibraryPath
    $env:LIB = $previousLib
}
