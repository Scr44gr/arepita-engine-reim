param(
    [ValidateSet("check", "test", "fmt", "sprites", "audio", "bench", "bunnymark", "collision-bench", "navigation-bench")]
    [string]$Action = "check",
    [string]$CompilerRoot = ""
)

$ErrorActionPreference = "Stop"
$engineRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($CompilerRoot)) {
    $CompilerRoot = Join-Path (Split-Path $engineRoot -Parent) "reimer"
}
$CompilerRoot = (Resolve-Path $CompilerRoot).Path

$sdlPath = (Resolve-Path (Join-Path $engineRoot "vendor\sdl3\native\windows-x86_64")).Path
$wgpuPath = (Resolve-Path (Join-Path $engineRoot "vendor\wgpu\native\windows-x86_64")).Path
$codecPath = (Resolve-Path (Join-Path $engineRoot "vendor\media-codecs\native\windows-x86_64")).Path
$env:PATH = "$sdlPath;$wgpuPath;$codecPath;$env:PATH"
$env:LIB = "$sdlPath;$wgpuPath;$codecPath;$env:LIB"

function Invoke-Reimer {
    param([string[]]$Arguments)

    & cargo run -q -p reimer-cli -- @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Reimer command failed with exit code $LASTEXITCODE."
    }
}

Push-Location $CompilerRoot
try {
    switch ($Action) {
        "check" {
            Invoke-Reimer @("check", $engineRoot, "--refresh")
        }
        "test" {
            Invoke-Reimer @("test", $engineRoot, "--release", "--refresh")
        }
        "fmt" {
            Invoke-Reimer @("fmt", $engineRoot, "--check")
        }
        "sprites" {
            $example = Join-Path $engineRoot "examples\sprites"
            Invoke-Reimer @("run", $example, "--release", "--refresh")
        }
        "audio" {
            $example = Join-Path $engineRoot "examples\audio-tone"
            Invoke-Reimer @("run", $example, "--release", "--refresh")
        }
        "bench" {
            $benchmark = Join-Path $engineRoot "benches\ecs"
            Invoke-Reimer @("run", $benchmark, "--release", "--refresh")
        }
        "bunnymark" {
            $benchmark = Join-Path $engineRoot "benches\bunnymark"
            Invoke-Reimer @("run", $benchmark, "--release", "--refresh")
        }
        "collision-bench" {
            $benchmark = Join-Path $engineRoot "benches\collision"
            Invoke-Reimer @("run", $benchmark, "--release", "--refresh")
        }
        "navigation-bench" {
            $benchmark = Join-Path $engineRoot "benches\navigation"
            Invoke-Reimer @("run", $benchmark, "--release", "--refresh")
        }
    }
}
finally {
    Pop-Location
}
