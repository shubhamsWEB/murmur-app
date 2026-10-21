<#
Builds Murmur's Windows installer on this PC, as the Windows workflow (.github/workflows/windows.yml) builds it on
GitHub: the tools it needs are installed with winget the first time (Visual Studio's C++ build tools, Swift, Rust,
Node, Python, CMake and Ninja, MSYS2 for the small ffmpeg, the Vulkan SDK), then the same scripts run.

    powershell -ExecutionPolicy Bypass -File scripts\windows-build.ps1            # build
    powershell -ExecutionPolicy Bypass -File scripts\windows-build.ps1 -Install   # build, then install it

Run it from the repository (the windows branch), in a normal PowerShell window; Windows asks for permission once while
Visual Studio's build tools install. The first build takes about an hour (installing the tools, then ffmpeg, llama.cpp
and the engine); later ones reuse what's built and take a few minutes. The installer lands in dist\.
#>
param([switch]$Install, [switch]$SkipTools)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
    foreach ($name in "VULKAN_SDK", "SDKROOT") {
        $value = [Environment]::GetEnvironmentVariable($name, "Machine")
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, "User") }
        if ($value) { Set-Item "env:$name" $value }
    }
}

function Have($command) { [bool](Get-Command $command -ErrorAction SilentlyContinue) }

function Winget($id, [string[]]$extra = @()) {
    $listed = winget list --id $id -e --accept-source-agreements 2>$null | Out-String
    if ($listed -match [regex]::Escape($id)) { Write-Host "$id is installed"; return }
    Write-Host "installing $id"
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements @extra
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {   # -1978335189: already installed
        throw "winget couldn't install $id (exit $LASTEXITCODE)"
    }
}

if (-not (Have "winget")) { throw "winget isn't here: install 'App Installer' from the Microsoft Store, then run this again" }
if (-not (Test-Path "$repo\shell\src-tauri\tauri.conf.json")) { throw "run this from Murmur's repository, on the windows branch" }

# MARK: Tools

if (-not $SkipTools) {
    Step "Tools (installed once)"
    Winget "Git.Git"
    # The C++ compiler, linker and Windows SDK that Swift, Rust, llama.cpp and the engine build with.
    Winget "Microsoft.VisualStudio.2022.BuildTools" @("--override",
        "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended")
    Winget "Swift.Toolchain"
    Winget "Rustlang.Rustup"
    Winget "OpenJS.NodeJS.LTS"
    Winget "Python.Python.3.12"
    Winget "Kitware.CMake"
    Winget "Ninja-build.Ninja"
    Winget "MSYS2.MSYS2"
    Winget "KhronosGroup.VulkanSDK"
    Refresh-Path
    if (Have "rustup") { rustup default stable | Out-Null }
}
Refresh-Path

if (-not $env:VULKAN_SDK) {
    $sdk = Get-ChildItem "C:\VulkanSDK" -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($sdk) { $env:VULKAN_SDK = $sdk.FullName; $env:Path = "$($sdk.FullName)\Bin;$env:Path" }
}
foreach ($need in "git", "swift", "cargo", "node", "npx", "cmake", "ninja") {
    if (-not (Have $need)) { throw "$need isn't on PATH yet: open a new PowerShell window and run this again" }
}
$bash = "$env:ProgramFiles\Git\bin\bash.exe"
$msys = "C:\msys64\usr\bin\bash.exe"
if (-not (Test-Path $bash)) { throw "no Git Bash at $bash" }
if (-not (Test-Path $msys)) { throw "no MSYS2 at C:\msys64" }

# MARK: ffmpeg (MSYS2's MinGW compilers, before Visual Studio's environment)

Step "ffmpeg (built once, about 15 minutes)"
$env:MSYSTEM = "MINGW64"
$env:CHERE_INVOKING = "1"   # MSYS2's login shell stays in this folder
& $msys -lc "pacman -S --needed --noconfirm --quiet curl make mingw-w64-x86_64-gcc mingw-w64-x86_64-meson mingw-w64-x86_64-ninja mingw-w64-x86_64-nasm mingw-w64-x86_64-pkgconf mingw-w64-x86_64-zlib > /dev/null && scripts/build-ffmpeg.sh"
if ($LASTEXITCODE -ne 0) { throw "ffmpeg didn't build" }
Remove-Item env:MSYSTEM, env:CHERE_INVOKING

# MARK: Visual Studio's environment, then the build

Step "Visual Studio's build environment"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "Visual Studio's C++ build tools aren't installed" }
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64" | Out-Null
Set-Location $repo

Step "Murmur (the engine, llama.cpp, the speech runtime, the app, the installer)"
# MSVC's tools before Git's: Git's /usr/bin/link (coreutils) would stand in for link.exe.
& $bash -c 'export PATH="$(dirname "$(command -v cl)"):$PATH"; set -e; scripts/fetch-vendor.sh; scripts/build-llama.sh; scripts/package-windows.sh'
if ($LASTEXITCODE -ne 0) { throw "the build failed: the lines above say where" }

$setup = Get-ChildItem "$repo\shell\src-tauri\target\release\bundle\nsis\*-setup.exe" | Select-Object -First 1
New-Item -ItemType Directory -Force "$repo\dist" | Out-Null
Copy-Item $setup.FullName "$repo\dist\" -Force
$built = "$repo\dist\$($setup.Name)"
Step "Built $built"

if ($Install) {
    Step "Installing (for this account; Murmur starts when it's done)"
    Get-Process Murmur -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Process $built -ArgumentList "/S" -Wait
    Start-Process "$env:LOCALAPPDATA\Murmur\Murmur.exe"
    Write-Host "Murmur is running. Its logs: $env:LOCALAPPDATA\com.copico.Murmur\logs"
}
