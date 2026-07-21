#!/usr/bin/env bash
#
# Install OpenCL headers, the Khronos ICD loader, and the PoCL CPU runtime on
# macOS, then print the resulting paths as key=value lines.
#
# Apple's OpenCL.framework is not a Khronos ICD loader -- it exports no
# clIcdGetPlatformIDsKHR -- so it cannot load PoCL. The two are mutually
# exclusive; this script selects one or the other, never both.
#
# Homebrew's opencl-icd-loader and opencl-headers are keg_only
# :shadowed_by_macos, meaning they are deliberately NOT symlinked into the
# Homebrew prefix. Anything compiled with -framework OpenCL or a bare
# -lOpenCL silently keeps using Apple's framework and never sees PoCL. Every
# path emitted below is therefore fully qualified.

set -euo pipefail

runtime="${SE_RUNTIME:-pocl}"

emit() { printf '%s=%s\n' "$1" "$2"; }

sdk_path="$(xcrun --show-sdk-path)"

if [ "${runtime}" = "apple" ]; then
    framework="${sdk_path}/System/Library/Frameworks/OpenCL.framework"
    emit opencl-root        "${framework}"
    emit opencl-include-dir "${framework}/Headers"
    # Emit the framework directory, not the binary inside it. On modern macOS,
    # the binary lives only in the dyld shared cache; the framework directory is
    # what CMake's find_library(OpenCL_LIBRARY) returns on macOS.
    emit opencl-library     "/System/Library/Frameworks/OpenCL.framework"
    emit opencl-cppflags    "-DCL_SILENCE_DEPRECATION"
    emit opencl-libs        "-framework OpenCL"
    emit icd-vendors-path   ""
    emit runtime-name       "apple"
    emit sdkroot            "${sdk_path}"
    exit 0
fi

formulae="opencl-headers opencl-icd-loader"
if [ "${runtime}" != "none" ]; then
    formulae="${formulae} pocl"
fi

# HOMEBREW_NO_AUTO_UPDATE keeps a formula refresh out of every job.
# shellcheck disable=SC2086
HOMEBREW_NO_AUTO_UPDATE=1 brew install --quiet ${formulae}

headers_prefix="$(brew --prefix opencl-headers)"
loader_prefix="$(brew --prefix opencl-icd-loader)"

emit opencl-root        "${loader_prefix}"
emit opencl-include-dir "${headers_prefix}/include"
emit opencl-library     "${loader_prefix}/lib/libOpenCL.dylib"
emit opencl-cppflags    "-I${headers_prefix}/include"
emit opencl-libs        "-L${loader_prefix}/lib -lOpenCL"
emit sdkroot            "${sdk_path}"

if [ "${runtime}" = "none" ]; then
    emit icd-vendors-path ""
    emit runtime-name     "none"
else
    # PoCL installs its .icd under its own prefix, not /etc/OpenCL/vendors,
    # so exporting OCL_ICD_VENDORS is mandatory rather than optional.
    emit icd-vendors-path "$(brew --prefix pocl)/etc/OpenCL/vendors"
    emit runtime-name     "pocl"
fi
