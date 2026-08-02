param(
    [ValidateSet("debug", "release")]
    [string]$Profile = "release"
)

$ErrorActionPreference = "Stop"
$vendorRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$bridgeManifest = Join-Path $vendorRoot "bridge\Cargo.toml"
$buildArguments = @("build", "--locked", "--manifest-path", $bridgeManifest)
if ($Profile -eq "release") {
    $buildArguments += "--release"
}

& cargo @buildArguments
if ($LASTEXITCODE -ne 0) {
    throw "Media codec build failed with exit code $LASTEXITCODE."
}

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

$profileDirectory = Join-Path $vendorRoot "bridge\target\$Profile"
$destination = Join-Path $vendorRoot "native\$platform"
New-Item -ItemType Directory -Path $destination -Force | Out-Null

if ($platform.StartsWith("windows-")) {
    Copy-Item -LiteralPath (Join-Path $profileDirectory "media_codecs.dll") -Destination (Join-Path $destination "media_codecs.dll") -Force
    Copy-Item -LiteralPath (Join-Path $profileDirectory "media_codecs.dll.lib") -Destination (Join-Path $destination "media_codecs.lib") -Force
} elseif ($platform.StartsWith("linux-")) {
    Copy-Item -LiteralPath (Join-Path $profileDirectory "libmedia_codecs.so") -Destination (Join-Path $destination "libmedia_codecs.so") -Force
} else {
    Copy-Item -LiteralPath (Join-Path $profileDirectory "libmedia_codecs.dylib") -Destination (Join-Path $destination "libmedia_codecs.dylib") -Force
}

$checksumPath = Join-Path $vendorRoot "checksums.sha256"
$vendorPrefix = $vendorRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$lines = Get-ChildItem -Path (Join-Path $vendorRoot "native") -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
        if (-not $_.FullName.StartsWith($vendorPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Artifact escaped the media codec vendor root: $($_.FullName)"
        }
        $relative = $_.FullName.Substring($vendorPrefix.Length).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relative"
    }
[System.IO.File]::WriteAllLines($checksumPath, $lines, [System.Text.UTF8Encoding]::new($false))

Write-Host "Built media codecs for $platform ($Profile)."
