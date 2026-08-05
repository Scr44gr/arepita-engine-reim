param(
    [string]$ImGuiSource = "",
    [string]$SdlSource = "",
    [string]$CompilerRoot = ""
)

$ErrorActionPreference = "Stop"
$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workspaceRoot = (Resolve-Path (Join-Path $packageRoot "..\..")).Path
if ([string]::IsNullOrWhiteSpace($CompilerRoot)) {
    $localCompiler = Join-Path $workspaceRoot "Cargo.toml"
    $CompilerRoot = if (Test-Path -LiteralPath $localCompiler) {
        $workspaceRoot
    }
    else {
        Join-Path (Split-Path $workspaceRoot -Parent) "reimer"
    }
}
$compilerRoot = (Resolve-Path -LiteralPath $CompilerRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $compilerRoot "Cargo.toml"))) {
    throw "The Reimer compiler workspace was not found at '$compilerRoot'."
}
$cacheRoot = Join-Path $workspaceRoot "target\imgui-api-gen"
$downloadRoot = Join-Path $cacheRoot "downloads"
$sourceRoot = Join-Path $cacheRoot "sources"
$bindingRoot = Join-Path $cacheRoot "dear-bindings"
$buildRoot = Join-Path $cacheRoot "native\windows-x86_64"
$nativeRoot = Join-Path $packageRoot "native\windows-x86_64"
$wgpuVendorRoot = Join-Path $workspaceRoot "vendor\wgpu"
$webgpuIncludeRoot = Join-Path $cacheRoot "native\webgpu-include"
$webgpuHeaderRoot = Join-Path $webgpuIncludeRoot "webgpu"

$imguiVersion = "1.92.8"
$imguiArchiveHash = "27765c56ab27ce47472d0bea43cf1e3301c726362ce585e99a059e3b37616870"
$imguiArchiveUrl = "https://github.com/ocornut/imgui/archive/refs/tags/v$imguiVersion.zip"
$dearBindingsRelease = "DearBindings_v0.21_ImGui_v1.92.8"
$dearBindingsRoot = "https://github.com/dearimgui/dear_bindings/releases/download/$dearBindingsRelease"
$sdlVersion = "3.4.12"
$sdlArchiveHash = "3d4de8967a49c0451e775a0c1e9022092c19fdef41ba38a83fcf031c5a6496e2"
$sdlArchiveUrl = "https://github.com/libsdl-org/SDL/releases/download/release-$sdlVersion/SDL3-$sdlVersion.zip"

$assets = @(
    @{ Name = "dcimgui.cpp"; Hash = "931c8e603d672f723bc12efc2ae53cd3ed5112debe4e2041180dd3a112160853" },
    @{ Name = "dcimgui.h"; Hash = "6382c75220d87db3f5d2e0c3a80f63fd5fd462d5929017e597e7f9ac69d47e95" },
    @{ Name = "dcimgui.json"; Hash = "bdad2fb0c70ba0374fcd2fc6b47030be6d13005a6b23c82677233fdc2aec3725" },
    @{ Name = "dcimgui_impl_opengl3.cpp"; Hash = "472dbf084607fd69d0db3a0833e5cde3600468f03ef65bf9535904d2ce351122" },
    @{ Name = "dcimgui_impl_opengl3.h"; Hash = "032d7611ec0dcbaecbb160fcfdcfc9012d5077170b2507e6e9e82c35a0f953f4" },
    @{ Name = "dcimgui_impl_opengl3.json"; Hash = "9b45b520f7268f6c8c0cb8e2d24b4ea0a07a35cd666747a5da58d7959984dfa8" },
    @{ Name = "dcimgui_impl_sdl3.cpp"; Hash = "20cae3eaf5602b4c1631cf528d99eba52958ce0d609afbd480f9543db29ae1b9" },
    @{ Name = "dcimgui_impl_sdl3.h"; Hash = "6726bac88dd582121ba6568413b4d12affe67b7de8a7270e182b4ab8a5d4ec56" },
    @{ Name = "dcimgui_impl_sdl3.json"; Hash = "212593abbd52616cf1c36b349bd286675674cf4809c008f5eaadbf8e2cdf6bc5" },
    @{ Name = "LICENSE.txt"; Hash = "173506a2d6f7fb67990d257fb2507f188690eca39060c39469ae7bef43aae2a3" }
)

function Get-PinnedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        Write-Host "Downloading $(Split-Path $Destination -Leaf)..."
        Invoke-WebRequest -Uri $Url -OutFile $Destination
    }
    $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedHash) {
        throw "Checksum mismatch for '$Destination': expected $ExpectedHash, got $actualHash"
    }
}

function Initialize-Msvc {
    $compiler = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($null -ne $compiler) {
        return $compiler.Source
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "MSVC was not found. Install the Visual Studio C++ build tools."
    }
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installation)) {
        throw "Visual Studio C++ build tools were not found."
    }
    $vcvars = Join-Path $installation.Trim() "VC\Auxiliary\Build\vcvars64.bat"
    $environmentLines = & cmd.exe /d /c ('call "' + $vcvars + '" >nul && set')
    if ($LASTEXITCODE -ne 0) {
        throw "Initializing the MSVC x64 environment failed."
    }
    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            [Environment]::SetEnvironmentVariable(
                $line.Substring(0, $separator),
                $line.Substring($separator + 1),
                'Process'
            )
        }
    }
    $compiler = Get-Command cl.exe -ErrorAction Stop
    return $compiler.Source
}

function New-Wgpu29CompatibleBackend {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    # wgpu-native 29 adopted the same standard C structure layouts and names
    # already used by Dear ImGui's Dawn/WGVK branches. Dear ImGui 1.92.8 still
    # classifies its WGPU branch as the older layout, so make that classification
    # explicit in a generated copy while leaving the pinned upstream source intact.
    $text = [System.IO.File]::ReadAllText($Source)
    $legacyCondition = '#if defined IMGUI_IMPL_WEBGPU_BACKEND_DAWN || defined IMGUI_IMPL_WEBGPU_BACKEND_WGVK'
    $standardCondition = '#if defined IMGUI_IMPL_WEBGPU_BACKEND_DAWN || defined IMGUI_IMPL_WEBGPU_BACKEND_WGVK || defined IMGUI_IMPL_WEBGPU_BACKEND_WGPU'
    $parenthesizedLegacy = '#if defined(IMGUI_IMPL_WEBGPU_BACKEND_DAWN) || defined(IMGUI_IMPL_WEBGPU_BACKEND_WGVK)'
    $parenthesizedStandard = '#if defined(IMGUI_IMPL_WEBGPU_BACKEND_DAWN) || defined(IMGUI_IMPL_WEBGPU_BACKEND_WGVK) || defined(IMGUI_IMPL_WEBGPU_BACKEND_WGPU)'
    if ([regex]::Matches($text, [regex]::Escape($legacyCondition)).Count -ne 2) {
        throw 'Dear ImGui WGPU compatibility sites changed; review the pinned backend before updating.'
    }
    if ([regex]::Matches($text, [regex]::Escape($parenthesizedLegacy)).Count -ne 2) {
        throw 'Dear ImGui WGPU status compatibility sites changed; review the pinned backend before updating.'
    }
    $text = $text.Replace($legacyCondition, $standardCondition)
    $text = $text.Replace($parenthesizedLegacy, $parenthesizedStandard)
    [System.IO.File]::WriteAllText(
        $Destination,
        $text,
        [System.Text.UTF8Encoding]::new($false)
    )
}

if ($env:OS -ne "Windows_NT" -or -not [Environment]::Is64BitProcess) {
    throw "The bundled Dear ImGui bridge currently targets Windows x64."
}

New-Item -ItemType Directory -Force $downloadRoot, $sourceRoot, $bindingRoot, $buildRoot, $nativeRoot, $webgpuHeaderRoot | Out-Null

foreach ($header in @("webgpu.h", "wgpu.h")) {
    $source = Join-Path $wgpuVendorRoot "upstream\include\$header"
    if (-not (Test-Path -LiteralPath $source)) {
        throw "The pinned wgpu header is missing at '$source'."
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $webgpuHeaderRoot $header) -Force
}

if ([string]::IsNullOrWhiteSpace($ImGuiSource)) {
    $imguiArchive = Join-Path $downloadRoot "imgui-$imguiVersion.zip"
    Get-PinnedFile -Url $imguiArchiveUrl -Destination $imguiArchive -ExpectedHash $imguiArchiveHash
    $resolvedImGuiSource = Join-Path $sourceRoot "imgui-$imguiVersion"
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedImGuiSource "imgui.h"))) {
        Expand-Archive -LiteralPath $imguiArchive -DestinationPath $sourceRoot -Force
    }
}
else {
    $resolvedImGuiSource = (Resolve-Path -LiteralPath $ImGuiSource).Path
}

if ([string]::IsNullOrWhiteSpace($SdlSource)) {
    $sdlArchive = Join-Path $downloadRoot "SDL3-$sdlVersion.zip"
    Get-PinnedFile -Url $sdlArchiveUrl -Destination $sdlArchive -ExpectedHash $sdlArchiveHash
    $resolvedSdlSource = Join-Path $sourceRoot "SDL3-$sdlVersion"
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedSdlSource "include\SDL3\SDL.h"))) {
        Expand-Archive -LiteralPath $sdlArchive -DestinationPath $sourceRoot -Force
    }
}
else {
    $resolvedSdlSource = (Resolve-Path -LiteralPath $SdlSource).Path
}

foreach ($asset in $assets) {
    $destination = Join-Path $bindingRoot $asset.Name
    Get-PinnedFile -Url "$dearBindingsRoot/$($asset.Name)" -Destination $destination -ExpectedHash $asset.Hash
}

Push-Location -LiteralPath $compilerRoot
try {
    cargo run -q -p imgui-api-gen -- `
        (Join-Path $bindingRoot "dcimgui.json") `
        (Join-Path $bindingRoot "dcimgui_impl_sdl3.json") `
        (Join-Path $bindingRoot "dcimgui_impl_opengl3.json") `
        (Join-Path $packageRoot "src\raw\types.reim") `
        (Join-Path $packageRoot "src\raw\constants.reim") `
        (Join-Path $packageRoot "src\raw\functions.reim") `
        (Join-Path $packageRoot "src\raw\backends.reim") `
        (Join-Path $packageRoot "coverage.toml")
    if ($LASTEXITCODE -ne 0) {
        throw "Generating Reimer declarations failed with exit code $LASTEXITCODE."
    }
    cargo run -q -p reimer-cli -- fmt $packageRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Formatting generated declarations failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$compiler = Initialize-Msvc
$wgpuBackendSource = Join-Path $resolvedImGuiSource "backends\imgui_impl_wgpu.cpp"
$compatibleWgpuBackend = Join-Path $buildRoot "imgui_impl_wgpu_wgpu29.cpp"
New-Wgpu29CompatibleBackend -Source $wgpuBackendSource -Destination $compatibleWgpuBackend
$includeArguments = @(
    "/I$resolvedImGuiSource",
    "/I$(Join-Path $resolvedImGuiSource 'backends')",
    "/I$bindingRoot",
    "/I$(Join-Path $resolvedSdlSource 'include')",
    "/I$webgpuIncludeRoot"
)
$compileArguments = @(
    "/nologo",
    "/c",
    "/std:c++17",
    "/EHsc",
    "/MD",
    "/O2",
    "/Brepro",
    "/utf-8",
    "/permissive-",
    "/D_CRT_SECURE_NO_WARNINGS",
    "/DIMGUI_IMPL_WEBGPU_BACKEND_WGPU",
    "/DCIMGUI_API=__declspec(dllexport)",
    "/DCIMGUI_IMPL_API=__declspec(dllexport)"
) + $includeArguments
$sources = @(
    (Join-Path $resolvedImGuiSource "imgui.cpp"),
    (Join-Path $resolvedImGuiSource "imgui_draw.cpp"),
    (Join-Path $resolvedImGuiSource "imgui_tables.cpp"),
    (Join-Path $resolvedImGuiSource "imgui_widgets.cpp"),
    (Join-Path $resolvedImGuiSource "imgui_demo.cpp"),
    (Join-Path $resolvedImGuiSource "backends\imgui_impl_sdl3.cpp"),
    (Join-Path $resolvedImGuiSource "backends\imgui_impl_opengl3.cpp"),
    $compatibleWgpuBackend,
    (Join-Path $bindingRoot "dcimgui.cpp"),
    (Join-Path $bindingRoot "dcimgui_impl_sdl3.cpp"),
    (Join-Path $bindingRoot "dcimgui_impl_opengl3.cpp"),
    (Join-Path $packageRoot "bridge\wgpu_bridge.cpp")
)
$objects = @()
foreach ($source in $sources) {
    $objectName = [System.IO.Path]::GetFileNameWithoutExtension($source) + ".obj"
    $object = Join-Path $buildRoot $objectName
    & $compiler @compileArguments "/Fo$object" $source
    if ($LASTEXITCODE -ne 0) {
        throw "Compiling '$source' failed with exit code $LASTEXITCODE."
    }
    $objects += $object
}

$linker = (Get-Command link.exe -ErrorAction Stop).Source
$outputDll = Join-Path $buildRoot "imgui.dll"
$outputLibrary = Join-Path $buildRoot "imgui.lib"
$sdlLibrary = Join-Path $workspaceRoot "vendor\sdl3\native\windows-x86_64\SDL3.lib"
$wgpuLibrary = Join-Path $wgpuVendorRoot "native\windows-x86_64\wgpu_native.lib"
if (-not (Test-Path -LiteralPath $sdlLibrary)) {
    throw "The SDL3 import library is missing at '$sdlLibrary'."
}
if (-not (Test-Path -LiteralPath $wgpuLibrary)) {
    throw "The wgpu-native import library is missing at '$wgpuLibrary'."
}
& $linker /nologo /DLL /Brepro "/OUT:$outputDll" "/IMPLIB:$outputLibrary" /OPT:REF /OPT:ICF @objects $sdlLibrary $wgpuLibrary opengl32.lib
if ($LASTEXITCODE -ne 0) {
    throw "Linking the Dear ImGui bridge failed with exit code $LASTEXITCODE."
}

Copy-Item -LiteralPath $outputDll -Destination (Join-Path $nativeRoot "imgui.dll") -Force
Copy-Item -LiteralPath $outputLibrary -Destination (Join-Path $nativeRoot "imgui.lib") -Force
Copy-Item -LiteralPath (Join-Path $resolvedImGuiSource "LICENSE.txt") -Destination (Join-Path $packageRoot "LICENSE-DEAR-IMGUI.txt") -Force
Copy-Item -LiteralPath (Join-Path $bindingRoot "LICENSE.txt") -Destination (Join-Path $packageRoot "LICENSE-DEAR-BINDINGS.txt") -Force

$checksumFiles = @(
    "native/windows-x86_64/imgui.dll",
    "native/windows-x86_64/imgui.lib",
    "LICENSE-DEAR-IMGUI.txt",
    "LICENSE-DEAR-BINDINGS.txt"
)
$checksumLines = foreach ($relativePath in $checksumFiles) {
    $path = Join-Path $packageRoot $relativePath
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relativePath"
}
[System.IO.File]::WriteAllText(
    (Join-Path $packageRoot "checksums.sha256"),
    ($checksumLines -join "`n") + "`n",
    [System.Text.UTF8Encoding]::new($false)
)

Push-Location -LiteralPath $compilerRoot
try {
    cargo run -q -p reimer-cli -- check $packageRoot --refresh
    if ($LASTEXITCODE -ne 0) {
        throw "Refreshing the generated package lockfile failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

Write-Host "Generated documented bindings and built the Dear ImGui SDL3/OpenGL3/wgpu bridge."
