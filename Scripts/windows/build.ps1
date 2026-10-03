# Builds nib for Windows from a clean checkout, and runs the core's tests.
#
#   powershell -File Scripts\windows\build.ps1               # x64, Release
#   powershell -File Scripts\windows\build.ps1 -Arch arm64   # cross-compiled from x64
#   powershell -File Scripts\windows\build.ps1 -SkipTests
#
# Needs Visual Studio 2022 (or the Build Tools) with the C++ workload, CMake
# and Ninja. Everything else -- ICU, the engines -- is fetched.
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [ValidateSet('Release', 'Debug')][string]$Config = 'Release',
    [switch]$SkipTests,
    [string]$Version = '1.1.0'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $root

& (Join-Path $PSScriptRoot 'fetch-engines.ps1') -Arch $Arch
. (Join-Path $PSScriptRoot 'vsenv.ps1') -Arch $Arch

$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$cross = $Arch -ne $hostArch
$extra = @()
if ($cross) {
    # Tests run where they are built; a cross build only produces nib.exe.
    $extra += '-DCMAKE_SYSTEM_NAME=Windows', "-DCMAKE_SYSTEM_PROCESSOR=$($Arch.ToUpper())"
}

$appBuild = "windows/build-$Arch"
cmake -S windows -B $appBuild -G Ninja "-DCMAKE_BUILD_TYPE=$Config" "-DNIB_RELEASE_VERSION=$Version" @extra
if ($LASTEXITCODE) { throw 'configure failed' }
cmake --build $appBuild
if ($LASTEXITCODE) { throw 'build failed' }

if (-not $SkipTests -and -not $cross) {
    $coreBuild = "core/build-win-$Arch"
    cmake -S core -B $coreBuild -G Ninja "-DCMAKE_BUILD_TYPE=$Config"
    if ($LASTEXITCODE) { throw 'core configure failed' }
    cmake --build $coreBuild
    if ($LASTEXITCODE) { throw 'core build failed' }
    & "$coreBuild/nibcore_tests.exe"
    if ($LASTEXITCODE) { throw 'core tests failed' }
}

Write-Host "built $appBuild\nib.exe"
