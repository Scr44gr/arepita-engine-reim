$ErrorActionPreference = 'Stop'

function Get-WgpuPlatform {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $architecture = switch ($architecture) {
        'x64' { 'x86_64' }
        'arm64' { 'aarch64' }
        default { throw "wgpu-native is not packaged for architecture '$architecture'." }
    }

    if ($env:OS -eq 'Windows_NT') {
        return "windows-$architecture"
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Linux
    )) {
        return "linux-$architecture"
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::OSX
    )) {
        return "macos-$architecture"
    }
    throw 'wgpu-native is currently packaged for Windows, Linux, and macOS.'
}

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

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedHash) {
        throw "Checksum mismatch for '$Path': expected $ExpectedHash, got $actualHash"
    }
}

function Initialize-WgpuMsvc {
    param(
        [Parameter(Mandatory = $true)][string]$Platform
    )

    $compiler = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($null -ne $compiler) {
        return $compiler.Source
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw 'MSVC was not found. Install the Visual Studio C++ build tools.'
    }
    $requiredComponent = if ($Platform.EndsWith('-aarch64')) {
        'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
    } else {
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
    }
    $installation = & $vswhere -latest -products * `
        -requires $requiredComponent `
        -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installation)) {
        throw 'Visual Studio C++ build tools were not found.'
    }

    $targetArchitecture = if ($Platform.EndsWith('-aarch64')) { 'arm64' } else { 'amd64' }
    $vcvars = Join-Path $installation.Trim() 'VC\Auxiliary\Build\vcvarsall.bat'
    $environmentLines = & cmd.exe /d /c ('call "' + $vcvars + '" ' + $targetArchitecture + ' >nul && set')
    if ($LASTEXITCODE -ne 0) {
        throw "Initializing the MSVC $targetArchitecture environment failed."
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
    $toolsRoot = [Environment]::GetEnvironmentVariable('VCToolsInstallDir', 'Process')
    $hostArchitecture = switch (
        [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    ) {
        'Arm64' { 'Hostarm64' }
        'X64' { 'HostX64' }
        'X86' { 'HostX86' }
        default { throw 'MSVC is not supported on this host architecture.' }
    }
    $compilerArchitecture = if ($targetArchitecture -eq 'amd64') { 'x64' } else { $targetArchitecture }
    $compiler = Join-Path $toolsRoot "bin\$hostArchitecture\$compilerArchitecture\cl.exe"
    if (-not (Test-Path -LiteralPath $compiler)) {
        throw "MSVC initialized, but its compiler was not found at '$compiler'."
    }
    return $compiler
}

function Build-WgpuBridge {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$Platform
    )

    $workspaceRoot = (Resolve-Path (Join-Path $PackageRoot '..\..')).Path
    $buildRoot = Join-Path $workspaceRoot "target\wgpu-api-gen\bridge\$Platform"
    $nativeRoot = Join-Path $PackageRoot "native\$Platform"
    $source = Join-Path $PackageRoot 'bridge\wgpu_bridge.c'
    $includeRoot = Join-Path $PackageRoot 'upstream\include'
    New-Item -ItemType Directory -Force $buildRoot, $nativeRoot | Out-Null

    if ($Platform.StartsWith('windows-')) {
        $compiler = Initialize-WgpuMsvc -Platform $Platform
        $outputDll = Join-Path $buildRoot 'wgpu_bridge.dll'
        $outputLibrary = Join-Path $buildRoot 'wgpu_bridge.lib'
        $nativeLibrary = Join-Path $nativeRoot 'wgpu_native.lib'
        Push-Location -LiteralPath $buildRoot
        try {
            & $compiler /nologo /LD /std:c17 /O2 /Brepro /MD /utf-8 /W4 /WX `
                "/I$includeRoot" $source $nativeLibrary `
                "/Fe:$outputDll" /link "/IMPLIB:$outputLibrary" /OPT:REF /OPT:ICF
            if ($LASTEXITCODE -ne 0) {
                throw "Compiling the wgpu callback bridge failed with exit code $LASTEXITCODE."
            }
        }
        finally {
            Pop-Location
        }
        Copy-Item -LiteralPath $outputDll -Destination (Join-Path $nativeRoot 'wgpu_bridge.dll') -Force
        Copy-Item -LiteralPath $outputLibrary -Destination (Join-Path $nativeRoot 'wgpu_bridge.lib') -Force
        return
    }

    $compiler = (Get-Command cc -ErrorAction Stop).Source
    $nativeLibraryRoot = Join-Path $PackageRoot "native\$Platform"
    if ($Platform.StartsWith('linux-')) {
        $output = Join-Path $nativeRoot 'libwgpu_bridge.so'
        & $compiler -std=c11 -O2 -fPIC -fvisibility=hidden -Wall -Wextra -Werror -shared `
            "-I$includeRoot" $source "-L$nativeLibraryRoot" -lwgpu_native `
            -pthread '-Wl,-rpath,$ORIGIN' -o $output
    }
    else {
        $output = Join-Path $nativeRoot 'libwgpu_bridge.dylib'
        & $compiler -std=c11 -O2 -fPIC -fvisibility=hidden -Wall -Wextra -Werror -dynamiclib `
            "-I$includeRoot" $source "-L$nativeLibraryRoot" -lwgpu_native `
            -pthread '-Wl,-rpath,@loader_path' -o $output
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Compiling the wgpu callback bridge failed with exit code $LASTEXITCODE."
    }
}
