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

    Both archives are verified with Get-FileHash before extraction -- the
    SDK zip ends up on the link line and PATH, and the runtime zip's DLL is
    registered machine-wide in HKLM, so neither is trusted unverified. What
    the digest is checked against differs by path, though. The pinned
    default's digest travels with its version/tag pin below and is
    refreshed by update-runtime.yml -- a true pin, fixed ahead of time and
    independent of the download itself. An overriding 'version' has no such
    pin; its digest instead comes from the same GitHub Releases API
    response used to resolve the asset name, moments before the archive is
    fetched from that same origin. That is a transport check -- it catches
    corruption or interception between API call and download -- not a pin
    against a value fixed in advance.

    Some releases have no API-reported digest at all: GitHub only began
    computing the field at a certain point, and assets uploaded before then
    report nothing. Refusing to install those is correct -- an unverified
    110 MB binary is about to be registered machine-wide -- but it left a
    legitimate pin with no way through, which is how intel/llvm's 2025-WW13
    (the last oclcpuexp built on LLVM 20, and therefore the one worth
    testing against a kernel compiler that crashes on LLVM 22) became
    uninstallable. VersionSha256 is the way through: the caller states the
    digest they expect, and the download is verified against that instead.
    It never weakens anything. When the API reports a digest too, the two
    must agree or the run fails; when the caller supplies nothing and the
    API reports nothing, the refusal stands. Every DOWNLOAD passes through
    Assert-FileHash. A cache hit is the one path that does not, because it
    downloads nothing; the expected digest is part of the cache key instead,
    so a changed expectation can never be satisfied by an archive cached
    under a different one.
#>

[CmdletBinding()]
param(
    [string] $Runtime       = $env:SE_RUNTIME,
    [string] $Version       = $env:SE_VERSION,
    [string] $VersionSha256 = $env:SE_VERSION_SHA256,
    [string] $InstallDir    = "$env:RUNNER_TEMP\opencl"
)

$ErrorActionPreference = 'Stop'

# Validated here as well as in action.yml's resolve step, because this script
# is runnable on its own. Rejecting a malformed value up front also keeps it
# out of the comparison below: anything that is not a digest can only ever
# mismatch, and "SHA-256 mismatch" reads as "this download was tampered
# with", which is a far more alarming diagnosis than "you mistyped it".
if ($VersionSha256) {
    $VersionSha256 = $VersionSha256.Trim()
    if ($VersionSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        Write-Output "::error::Input version-sha256 must be a 64-character hex SHA-256 digest"
        Write-Output "Got '$VersionSha256'. Obtain the value with 'Get-FileHash -Algorithm SHA256 <file>' (or 'sha256sum <file>') and pass the bare hex digest, with no 'sha256:' prefix."
        exit 1
    }
    $VersionSha256 = $VersionSha256.ToLowerInvariant()
}

# Pinned defaults. update-runtime.yml opens a PR when a newer tag appears,
# and refreshes the paired SHA-256 alongside it. The '=' sits in the same
# column across all six assignments -- update-runtime.yml's sed rewrites
# match on that alignment, so keep it if this block is touched by hand.
$SdkVersion    = 'v2026.05.29'
$SdkUrl        = "https://github.com/KhronosGroup/OpenCL-SDK/releases/download/$SdkVersion/OpenCL-SDK-$SdkVersion-Win-x64.zip"
$SdkSha256     = '9a85ecef3e9276121ee257122be348bedf29299127b49c0d8286c2d7cf56768d'
$RuntimeTag    = '2026-WW28'
$RuntimeFile   = 'win-oclcpuexp-2026.22.6.1.17_160000_rel.zip'
$RuntimeSha256 = '0f7d88ec112c5526d61486ac9f45f111f2cabfd89907f7db7db6edaa9f101dda'

if (-not $Runtime) { $Runtime = 'intel' }

function Emit([string] $Key, [string] $Value) {
    Write-Output "$Key=$Value"
}

# Fails the run with this action's ::error:: + remediation contract when a
# downloaded archive does not match its expected digest. This is the last
# line of defense before either archive is trusted: the SDK zip ends up on
# the link line and PATH, and the runtime zip's DLL is registered
# machine-wide in HKLM\SOFTWARE\Khronos\OpenCL\Vendors. A silent mismatch
# would defeat the point of pinning a digest at all, so this fails closed,
# never just warns.
function Assert-FileHash([string] $Path, [string] $Expected, [string] $Label) {
    $actual   = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $Expected.ToLowerInvariant()
    if ($actual -ne $expected) {
        Write-Output "::error::SHA-256 mismatch for ${Label}: expected $expected, got $actual"
        Write-Output "The downloaded file does not match its pinned digest. This can mean the download was corrupted or intercepted in transit, or that upstream replaced the asset in place without changing its version/tag. Do not trust this file. If upstream genuinely republished the asset, verify the new digest out of band before updating the pin in install-windows.ps1."
        Remove-Item -Force $Path -ErrorAction SilentlyContinue
        exit 1
    }
}

# Resolves the win-oclcpuexp asset name -- and its SHA-256 digest -- for an
# overriding release tag. The pinned default's build number and digest
# can't be assumed for an arbitrary tag -- that was the original bug:
# reordering alone still hardcoded $RuntimeFile, so any tag other than the
# pinned one would 404. Query the release's own asset list instead of
# guessing.
#
# GitHub computes and reports a SHA-256 'digest' field on every uploaded
# release asset, so the same API call that resolves the asset name also
# resolves the digest to verify it against -- no separate checksums file to
# locate or trust. This is not a pin in the sense the pinned-defaults block
# above is: the digest and the archive both come from the same GitHub-hosted
# origin, resolved minutes apart, so it verifies transport integrity (the
# download matches what the API just described) rather than authenticity
# against a value fixed ahead of time.
#
# $CallerSha256 is the escape hatch for assets that report no digest at all
# (uploaded before GitHub began computing the field, or still processing).
# It is only ever an additional or a substitute *check*, never a way past
# one, so exactly three things can happen:
#
#   both present   -- they must agree; a disagreement fails the run, because
#                     one of the two is describing a different file and
#                     guessing which is not this script's call to make
#   caller only    -- verify against the caller's value, which is a stronger
#                     pin than the API digest ever was: it is fixed in the
#                     workflow ahead of time rather than fetched alongside
#                     the download
#   API only       -- verify against the API's, exactly as before
#
# and when there is neither, resolution still fails closed with this
# project's ::error:: contract rather than proceeding unverified.
function Resolve-RuntimeAsset([string] $Tag, [string] $CallerSha256) {
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

    $apiSha256 = $null
    if ($asset.digest -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $apiSha256 = $Matches[1].ToLowerInvariant()
    }

    if ($apiSha256 -and $CallerSha256) {
        if ($apiSha256 -ne $CallerSha256) {
            Write-Output "::error::The 'version-sha256' input disagrees with the digest the GitHub API reports for intel/llvm release '$Tag' asset '$($asset.name)'"
            Write-Output "Supplied $CallerSha256, API reports $apiSha256. The two are describing different files, and this script will not pick a winner. Re-derive the digest from the asset at https://github.com/intel/llvm/releases/tag/$Tag; if it keeps disagreeing, treat that as a sign the asset was replaced in place and verify out of band before trusting either value. Dropping the input to make this go away would install the file the API describes without ever having checked it against what you expected."
            exit 1
        }
        return [PSCustomObject]@{ Name = $asset.name; Sha256 = $apiSha256; Source = 'the GitHub API, matching the version-sha256 input' }
    }

    if ($CallerSha256) {
        Write-Host "GitHub reports no digest for '$($asset.name)'; verifying the download against the caller-supplied version-sha256 instead."
        return [PSCustomObject]@{ Name = $asset.name; Sha256 = $CallerSha256; Source = 'the version-sha256 input' }
    }

    if ($apiSha256) {
        return [PSCustomObject]@{ Name = $asset.name; Sha256 = $apiSha256; Source = 'the GitHub API' }
    }

    Write-Output "::error::intel/llvm release '$Tag' asset '$($asset.name)' has no SHA-256 digest reported by the GitHub API"
    Write-Output "There is nothing to verify this download against, so it is refused rather than installed unverified. Either use the pinned default (omit 'version'), pick a tag whose asset has a published digest, or state the digest you expect with the 'version-sha256' input. To obtain it: fetch https://github.com/intel/llvm/releases/download/$Tag/$($asset.name) once, satisfy yourself out of band that the copy is genuine, and hash it with 'Get-FileHash -Algorithm SHA256 <file>' (or 'sha256sum <file>'). That turns a moving target into a pin fixed in your workflow; it does not by itself authenticate the origin, which is why the out-of-band step matters."
    exit 1
}

if ($Version) {
    # Only reassign after a successful resolution -- never fall back to the
    # pinned default silently on a bad tag.
    $RuntimeTag = $Version
    $resolved   = Resolve-RuntimeAsset -Tag $RuntimeTag -CallerSha256 $VersionSha256
    $RuntimeFile   = $resolved.Name
    $RuntimeSha256 = $resolved.Sha256
    $RuntimeShaSource = $resolved.Source
} else {
    $RuntimeShaSource = 'this script''s pinned default'
    if ($VersionSha256) {
        # The pinned default carries its own digest above, refreshed by
        # update-runtime.yml alongside the tag it belongs to. A caller-supplied
        # digest cannot replace it: it would describe a different release.
        Write-Output "::warning::The 'version-sha256' input describes the asset that 'version' selects; ignoring it because 'version' is unset. The pinned default runtime is verified against the digest fixed in this script."
    }
}
$RuntimeUrl = "https://github.com/intel/llvm/releases/download/$RuntimeTag/$RuntimeFile"
Write-Host "Resolved Intel CPU runtime release: tag=$RuntimeTag asset=$RuntimeFile"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# ---------- headers and ICD loader ----------

$sdkDir = Join-Path $InstallDir 'sdk'

# Check every file this action depends on downstream (headers for
# consumers, OpenCL.lib for the link line this action exports, clinfo.exe
# for the Windows probe step, and OpenCL.dll -- the loader itself -- which
# the README documents as living alongside clinfo.exe in bin\ and which both
# clinfo.exe and any consumer binary need on PATH at runtime) -- a tree
# missing any one of them is not a complete cache hit and must be
# re-extracted, not silently used as-is.
function Test-SdkComplete([string] $Dir) {
    (Test-Path (Join-Path $Dir 'include\CL\cl.h')) -and
    (Test-Path (Join-Path $Dir 'lib\OpenCL.lib')) -and
    (Test-Path (Join-Path $Dir 'bin\clinfo.exe')) -and
    (Test-Path (Join-Path $Dir 'bin\OpenCL.dll'))
}

if (-not (Test-SdkComplete $sdkDir)) {
    $sdkZip = Join-Path $InstallDir 'sdk.zip'
    Invoke-WebRequest -Uri $SdkUrl -OutFile $sdkZip
    Assert-FileHash -Path $sdkZip -Expected $SdkSha256 -Label "OpenCL SDK archive ($SdkVersion)"
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

    # Re-run the same completeness gate used for the cache-hit decision
    # above. Without this, a layout drift that drops one of the four
    # required files (most notably bin\OpenCL.dll, added to the gate
    # alongside this check) would not fail loudly -- it would make every
    # future run look like a cache miss forever, silently re-downloading
    # and re-extracting the archive on every single run with no error.
    if (-not (Test-SdkComplete $sdkDir)) {
        Write-Output "::error::Extracted OpenCL SDK tree at '$sdkDir' is missing one of: include\CL\cl.h, lib\OpenCL.lib, bin\clinfo.exe, bin\OpenCL.dll"
        Write-Output "The archive layout may have changed for SDK release $SdkVersion. Check https://github.com/KhronosGroup/OpenCL-SDK/releases/tag/$SdkVersion."
        exit 1
    }
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

# The archive layout has moved between releases; locate the vendor ICD
# rather than assuming a fixed path. This is the exact mistake that left
# RcppBandicoot registering the loader instead of the vendor.
#
# This search doubles as the cache gate: it must run *before* deciding
# whether to download, not after. A fixed-path Test-Path here would go
# stale the moment the archive nests the DLL a level deeper (say under
# x64\) -- every cache hit would then look like a miss, re-downloading the
# 110 MB archive on every single run with no error, since the fallback
# search below would still find it and mask the regression. Searching
# first means one code path decides where the ICD is, and the cache gate
# uses that same answer.
$found = if (Test-Path $rtDir) {
    Get-ChildItem -Path $rtDir -Recurse -Filter 'intelocl64.dll' |
        Select-Object -First 1
} else {
    $null
}

if (-not $found) {
    $rtZip = Join-Path $InstallDir 'oclcpuexp.zip'
    Invoke-WebRequest -Uri $RuntimeUrl -OutFile $rtZip
    # $RuntimeSha256 is always non-null here: the pinned default hardcodes
    # it above, and Resolve-RuntimeAsset exits before returning unless it
    # has a digest from the GitHub API, from the caller, or from both in
    # agreement. There is deliberately no fallback path that skips this
    # check. The label names which of the three it was, so a mismatch says
    # what the expected value was being trusted for.
    Assert-FileHash -Path $rtZip -Expected $RuntimeSha256 -Label "Intel CPU runtime archive ($RuntimeTag, digest from $RuntimeShaSource)"
    New-Item -ItemType Directory -Force -Path $rtDir | Out-Null
    Expand-Archive -Path $rtZip -DestinationPath $rtDir -Force
    Remove-Item -Force $rtZip

    $found = Get-ChildItem -Path $rtDir -Recurse -Filter 'intelocl64.dll' |
             Select-Object -First 1
    if (-not $found) {
        Write-Output "::error::intelocl64.dll not found in the oclcpuexp archive"
        Write-Output "The archive layout may have changed in release $RuntimeTag."
        exit 1
    }
}

$icd = $found.FullName

Emit 'icd-vendors-path' ($icd -replace '\\', '/')
Emit 'icd-filenames'    $icd
Emit 'runtime-name'     'intel-cpu'
