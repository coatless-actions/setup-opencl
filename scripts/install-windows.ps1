<#
.SYNOPSIS
    Install OpenCL headers, the Khronos ICD loader, and Intel's CPU runtime on
    Windows, then print the resulting paths as key=value lines.

.DESCRIPTION
    Headers and loader come from the Khronos OpenCL-SDK release zip: roughly
    1 MB, unzips in seconds, and considerably newer than vcpkg's port, which
    would otherwise cost about four minutes of source build per job.

    The CPU runtime comes from intel/llvm's oclcpuexp zip rather than Intel's
    MSI. It is a pure file drop -- no elevation, no installer state -- so it
    caches perfectly and the extracted layout is known rather than probed.
    Intel's registrationcenter URLs embed opaque GUIDs with no derivable
    pattern, making "latest" impossible; intel/llvm release tags are
    enumerable, which is what makes the version bump automatable.
#>

[CmdletBinding()]
param(
    [string] $Runtime    = $env:SE_RUNTIME,
    [string] $Version    = $env:SE_VERSION,
    [string] $InstallDir = "$env:RUNNER_TEMP\opencl"
)

$ErrorActionPreference = 'Stop'

# Pinned defaults. update-runtime.yml opens a PR when a newer tag appears.
$SdkVersion     = 'v2026.05.29'
$SdkUrl         = "https://github.com/KhronosGroup/OpenCL-SDK/releases/download/$SdkVersion/OpenCL-SDK-$SdkVersion-Win-x64.zip"
$RuntimeTag     = '2026-WW28'
$RuntimeFile    = 'win-oclcpuexp-2026.22.6.1.17_160000_rel.zip'
$RuntimeUrl     = "https://github.com/intel/llvm/releases/download/$RuntimeTag/$RuntimeFile"

if (-not $Runtime) { $Runtime = 'intel' }
if ($Version)      { $RuntimeTag = $Version }

function Emit([string] $Key, [string] $Value) {
    Write-Output "$Key=$Value"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# ---------- headers and ICD loader ----------

$sdkDir = Join-Path $InstallDir 'sdk'
if (-not (Test-Path (Join-Path $sdkDir 'include\CL\cl.h'))) {
    $sdkZip = Join-Path $InstallDir 'sdk.zip'
    Invoke-WebRequest -Uri $SdkUrl -OutFile $sdkZip
    Expand-Archive -Path $sdkZip -DestinationPath $InstallDir -Force
    $extracted = Get-ChildItem -Path $InstallDir -Directory |
                 Where-Object { $_.Name -like 'OpenCL-SDK-*' } |
                 Select-Object -First 1
    if (-not $extracted) { throw "OpenCL SDK archive did not contain the expected directory" }
    if (Test-Path $sdkDir) { Remove-Item -Recurse -Force $sdkDir }
    Move-Item -Path $extracted.FullName -Destination $sdkDir
    Remove-Item -Force $sdkZip
}

$includeDir = Join-Path $sdkDir 'include'
$libPath    = Join-Path $sdkDir 'lib\OpenCL.lib'
$binDir     = Join-Path $sdkDir 'bin'

# Forward slashes avoid escaping trouble in shell consumers such as
# configure.win, which reads OPENCL_CPPFLAGS and OPENCL_LIBS directly.
$includeFwd = $includeDir -replace '\\', '/'
$sdkLibFwd  = (Join-Path $sdkDir 'lib') -replace '\\', '/'

Emit 'opencl-root'         ($sdkDir -replace '\\', '/')
Emit 'opencl-include-dir'  $includeFwd
Emit 'opencl-library'      ($libPath -replace '\\', '/')
Emit 'opencl-cppflags'     "-I$includeFwd"
Emit 'opencl-libs'         "-L$sdkLibFwd -lOpenCL"
Emit 'loader-bin-dir'      $binDir

if ($Runtime -eq 'none') {
    Emit 'icd-vendors-path' ''
    Emit 'icd-filenames'    ''
    Emit 'runtime-name'     'none'
    exit 0
}

# ---------- Intel CPU runtime ----------

$rtDir = Join-Path $InstallDir 'oclcpuexp'
$icd   = Join-Path $rtDir 'intelocl64.dll'

if (-not (Test-Path $icd)) {
    $rtZip = Join-Path $InstallDir 'oclcpuexp.zip'
    Invoke-WebRequest -Uri $RuntimeUrl -OutFile $rtZip
    New-Item -ItemType Directory -Force -Path $rtDir | Out-Null
    Expand-Archive -Path $rtZip -DestinationPath $rtDir -Force
    Remove-Item -Force $rtZip
}

if (-not (Test-Path $icd)) {
    # The archive layout has moved between releases; locate the vendor ICD
    # rather than assuming. This is the exact mistake that left
    # RcppBandicoot registering the loader instead of the vendor.
    $found = Get-ChildItem -Path $rtDir -Recurse -Filter 'intelocl64.dll' |
             Select-Object -First 1
    if (-not $found) {
        Write-Output "::error::intelocl64.dll not found in the oclcpuexp archive"
        Write-Output "The archive layout may have changed in release $RuntimeTag."
        exit 1
    }
    $icd = $found.FullName
}

Emit 'icd-vendors-path' ($icd -replace '\\', '/')
Emit 'icd-filenames'    $icd
Emit 'runtime-name'     'intel-cpu'
