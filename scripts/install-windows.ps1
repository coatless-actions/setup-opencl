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

    The pinned default's asset file name is known ahead of time (it is
    recorded alongside the tag below), so the default path makes no network
    call. An overriding 'version' does not carry a known build number, so
    that case resolves the actual asset name from the GitHub Releases API
    for the given tag before building the download URL.
#>

[CmdletBinding()]
param(
    [string] $Runtime    = $env:SE_RUNTIME,
    [string] $Version    = $env:SE_VERSION,
    [string] $InstallDir = "$env:RUNNER_TEMP\opencl"
)

$ErrorActionPreference = 'Stop'

# Pinned defaults. update-runtime.yml opens a PR when a newer tag appears.
$SdkVersion  = 'v2026.05.29'
$SdkUrl      = "https://github.com/KhronosGroup/OpenCL-SDK/releases/download/$SdkVersion/OpenCL-SDK-$SdkVersion-Win-x64.zip"
$RuntimeTag  = '2026-WW28'
$RuntimeFile = 'win-oclcpuexp-2026.22.6.1.17_160000_rel.zip'

if (-not $Runtime) { $Runtime = 'intel' }

function Emit([string] $Key, [string] $Value) {
    Write-Output "$Key=$Value"
}

# Resolves the win-oclcpuexp asset name for an overriding release tag. The
# pinned default's build number can't be assumed for an arbitrary tag --
# that was the bug: reordering alone still hardcoded $RuntimeFile, so any
# tag other than the pinned one would 404. Query the release's own asset
# list instead of guessing.
function Resolve-RuntimeAssetName([string] $Tag) {
    $headers = @{ 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) {
        # Avoids anonymous rate limiting on busy runners; works without it too.
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }

    $apiUrl = "https://api.github.com/repos/intel/llvm/releases/tags/$Tag"
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    } catch {
        Write-Output "::error::intel/llvm has no release tagged '$Tag' (or the GitHub API request failed: $($_.Exception.Message))"
        Write-Output "Check https://github.com/intel/llvm/releases for a valid tag, e.g. '2026-WW28'."
        exit 1
    }

    $asset = $release.assets |
             Where-Object { $_.name -like 'win-oclcpuexp*' -and $_.name -like '*.zip' } |
             Select-Object -First 1
    if (-not $asset) {
        Write-Output "::error::intel/llvm release '$Tag' has no asset matching 'win-oclcpuexp*.zip'"
        Write-Output "Check the assets listed at https://github.com/intel/llvm/releases/tag/$Tag."
        exit 1
    }

    return $asset.name
}

if ($Version) {
    # Only reassign after a successful resolution -- never fall back to the
    # pinned default silently on a bad tag.
    $RuntimeTag  = $Version
    $RuntimeFile = Resolve-RuntimeAssetName -Tag $RuntimeTag
}
$RuntimeUrl = "https://github.com/intel/llvm/releases/download/$RuntimeTag/$RuntimeFile"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# ---------- headers and ICD loader ----------

$sdkDir = Join-Path $InstallDir 'sdk'

# Check every file this action depends on downstream (headers for
# consumers, OpenCL.lib for the link line this action exports, clinfo.exe
# for the Windows probe step) -- a tree missing any one of them is not a
# complete cache hit and must be re-extracted, not silently used as-is.
function Test-SdkComplete([string] $Dir) {
    (Test-Path (Join-Path $Dir 'include\CL\cl.h')) -and
    (Test-Path (Join-Path $Dir 'lib\OpenCL.lib')) -and
    (Test-Path (Join-Path $Dir 'bin\clinfo.exe'))
}

if (-not (Test-SdkComplete $sdkDir)) {
    $sdkZip = Join-Path $InstallDir 'sdk.zip'
    Invoke-WebRequest -Uri $SdkUrl -OutFile $sdkZip
    Expand-Archive -Path $sdkZip -DestinationPath $InstallDir -Force
    $extracted = Get-ChildItem -Path $InstallDir -Directory |
                 Where-Object { $_.Name -like 'OpenCL-SDK-*' } |
                 Select-Object -First 1
    if (-not $extracted) {
        Write-Output "::error::OpenCL SDK archive did not contain the expected directory"
        Write-Output "The archive layout may have changed for SDK release $SdkVersion."
        exit 1
    }
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
