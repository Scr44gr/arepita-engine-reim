$ErrorActionPreference = "Stop"

$benchmarkRoot = $PSScriptRoot
$engineRoot = (Resolve-Path -LiteralPath (Join-Path $benchmarkRoot "..\..")).Path
$nativeDirectories = @(
    (Join-Path $engineRoot "vendor\sdl3\native\windows-x86_64"),
    (Join-Path $engineRoot "vendor\wgpu\native\windows-x86_64"),
    (Join-Path $engineRoot "vendor\media-codecs\native\windows-x86_64")
)

foreach ($directory in $nativeDirectories) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Missing vendored native directory: $directory"
    }
}

$documentsRoot = (Resolve-Path -LiteralPath (Join-Path $engineRoot "..")).Path
$debugCompiler = Join-Path $documentsRoot "reimer\target\debug\reimer.exe"
$releaseCompiler = Join-Path $documentsRoot "reimer\target\release\reimer.exe"
$compilerCommand = Get-Command reimer -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $debugCompiler -PathType Leaf) {
    $compiler = $debugCompiler
} elseif (Test-Path -LiteralPath $releaseCompiler -PathType Leaf) {
    $compiler = $releaseCompiler
} elseif ($null -ne $compilerCommand) {
    $compiler = $compilerCommand.Source
} else {
    throw "Could not find reimer. Install it or add reimer.exe to PATH."
}

$previousPath = $env:PATH
$previousLib = $env:LIB
$nativePath = $nativeDirectories -join ";"

try {
    $env:PATH = "$nativePath;$previousPath"
    $env:LIB = "$nativePath;$previousLib"
    Push-Location -LiteralPath $benchmarkRoot
    try {
        & $compiler run . --release
        if ($LASTEXITCODE -ne 0) {
            throw "BunnyMark exited with code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
} finally {
    $env:PATH = $previousPath
    $env:LIB = $previousLib
}
