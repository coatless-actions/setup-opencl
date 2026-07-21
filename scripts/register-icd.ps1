<#
.SYNOPSIS
    Register a vendor ICD with the Khronos loader on Windows.

.DESCRIPTION
    Runs on every job, cache hit or miss. actions/cache restores files only --
    not HKLM values, not machine PATH, not installer state -- so registration
    can never be conditional on a cache miss.

    OCL_ICD_FILENAMES is the primary mechanism: khrIcdOsVendorsEnumerate calls
    khrIcdVendorsEnumerateEnv before it reads SOFTWARE\Khronos\OpenCL\Vendors,
    it needs no elevation, and it cannot drift. The registry key is written as
    well, idempotently, for consumers that spawn processes with a scrubbed
    environment.

    Wow6432Node is deliberately skipped: Intel dropped 32-bit CPU runtime
    libraries as of 2025.0, and R on Windows has been 64-bit-only since 4.2.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IcdPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $IcdPath)) {
    Write-Output "::error::Vendor ICD not found at $IcdPath"
    exit 1
}

$key = 'HKLM:\SOFTWARE\Khronos\OpenCL\Vendors'
if (-not (Test-Path $key)) {
    New-Item -Path $key -Force | Out-Null
}
New-ItemProperty -Path $key -Name $IcdPath -Value 0 -PropertyType DWord -Force | Out-Null

Write-Output "Registered vendor ICD: $IcdPath"
