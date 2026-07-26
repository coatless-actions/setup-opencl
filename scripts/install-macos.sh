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
#
# Homebrew is not the only PoCL available on macOS: install-macos-conda.sh
# installs one from conda-forge instead, because Homebrew's is built against
# llvm@21 and LLVM 21's Clang miscompiles OpenCL kernel stubs (llvm#161077).
# That script's header explains the whole story; this one keeps the Homebrew
# path and hands off when asked.

set -euo pipefail

runtime="${SE_RUNTIME:-pocl}"

# action.yml resolves 'pocl-source' and only ever passes a non-empty value for
# runtime 'pocl' on macOS; every other combination arrives empty, as does a
# bare local run of this script, and takes the Homebrew path below. Only the
# one value diverts -- anything else, including a typo that got past
# action.yml's validation on a standalone run, falls through to Homebrew,
# which is the safe answer rather than a hard stop.
pocl_source="${SE_POCL_SOURCE:-}"

emit() { printf '%s=%s\n' "$1" "$2"; }

sdk_path="$(xcrun --show-sdk-path)"

if [ "${runtime}" = "apple" ]; then
    framework="${sdk_path}/System/Library/Frameworks/OpenCL.framework"
    headers="${framework}/Headers"

    # Consumers write <CL/cl.h>, the Khronos loader layout that PoCL's
    # headers and the Windows SDK both follow. Apple's framework instead
    # places cl.h directly under Headers/, with no CL subdirectory, so give
    # it one via a symlink rather than asking every consumer (including this
    # action's own probe) to special-case the framework. Every channel that
    # hands a consumer an include path -- opencl-include-dir, opencl-cppflags,
    # and (via the action's export step) OpenCL_INCLUDE_DIR -- must agree, so
    # the shim is built once, here, and all three point at it.
    # RUNNER_TEMP exists only on a GitHub Actions runner; fall back to system
    # temp directories so this script can run locally.
    shim_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/setup-opencl-cl-shim"
    mkdir -p "${shim_dir}"
    ln -sfn "${headers}" "${shim_dir}/CL"

    emit opencl-root        "${framework}"
    emit opencl-include-dir "${shim_dir}"
    # Emit the framework directory, not the binary inside it. On modern macOS,
    # the binary lives only in the dyld shared cache; the framework directory is
    # what CMake's find_library(OpenCL_LIBRARY) returns on macOS.
    emit opencl-library     "/System/Library/Frameworks/OpenCL.framework"
    emit opencl-cppflags    "-I${shim_dir} -DCL_SILENCE_DEPRECATION"
    emit opencl-libs        "-framework OpenCL"
    emit icd-vendors-path   ""
    emit runtime-name       "apple"
    emit sdkroot            "${sdk_path}"
    exit 0
fi

# Handed off rather than branched inline: the conda-forge path carries its own
# pinned versions, digest verification, cache stamp and dylib relocation, and
# it needs its own stdout discipline (micromamba's transaction table must not
# reach the key=value contract). Keeping it in one file also keeps it
# runnable on its own, the way install-windows.ps1 is.
#
# Only runtime 'pocl' reaches here with a source to choose: 'apple' returned
# above, and 'none' installs no runtime at all, so it stays on Homebrew's
# headers and loader whatever this input says.
if [ "${runtime}" = "pocl" ] && [ "${pocl_source}" = "conda-forge" ]; then
    exec bash "$(dirname "${BASH_SOURCE[0]}")/install-macos-conda.sh"
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

# opencl-headers and opencl-icd-loader are two separate kegs, so neither
# keg's own prefix contains both include/CL/cl.h and lib/libOpenCL.dylib. A
# bare OpenCL_ROOT pointed at either one leaves CMake's find_package(OpenCL)
# (via CMP0074) unable to resolve the other half via that root, and it
# silently falls back to Apple's zero-device framework instead of erroring.
# Same shim pattern as the apple branch's CL/ symlink above: build a merged
# root once and hand out that, not either keg's prefix. RUNNER_TEMP exists
# only on a GitHub Actions runner; fall back to system temp directories so
# this script can run locally.
root_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/setup-opencl-root"
mkdir -p "${root_dir}"
ln -sfn "${headers_prefix}/include" "${root_dir}/include"
ln -sfn "${loader_prefix}/lib" "${root_dir}/lib"

emit opencl-root        "${root_dir}"
emit opencl-include-dir "${headers_prefix}/include"
emit opencl-library     "${loader_prefix}/lib/libOpenCL.dylib"
emit opencl-cppflags    "-I${headers_prefix}/include"
emit opencl-libs        "-L${loader_prefix}/lib -lOpenCL"
emit sdkroot            "${sdk_path}"

if [ "${runtime}" = "none" ]; then
    emit icd-vendors-path ""
    emit runtime-name     "none"
else
    pocl_prefix="$(brew --prefix pocl)"

    # Which LLVM PoCL links is the difference between a runtime that runs
    # kernels and one that segfaults inside them (llvm#161077), and it is a
    # transitive choice no pin in this action controls. action.yml warns about
    # llvm@21 unconditionally on this path; this line is the evidence for that
    # warning, and the thing that will show when it has gone stale. Written to
    # stderr so it reaches the job log immediately -- action.yml only replays
    # this script's stdout after the capture succeeds. Same measurement, for
    # the same reason, as install-macos-conda.sh's.
    llvm_line="$(otool -L "${pocl_prefix}/lib/libpocl.dylib" 2>/dev/null | grep -i 'libLLVM' | head -1 | sed 's/^[[:space:]]*//' || true)"
    echo "Homebrew PoCL links: ${llvm_line:-(otool reported no libLLVM dependency)}" >&2

    # Homebrew's libLLVM.dylib is unversioned, so the generation has to come
    # from the keg name in the path. install-macos-conda.sh parses the SONAME
    # instead, because conda-forge's carries the version in the file name.
    llvm_major="$(printf '%s' "${llvm_line}" | sed -n 's/.*llvm@\([0-9][0-9]*\).*/\1/p')"
    if [ -n "${llvm_major}" ] && [ "${llvm_major}" != "21" ]; then
        echo "Note: Homebrew's PoCL is now on llvm@${llvm_major}, not llvm@21. The warning action.yml emits for 'pocl-source: homebrew' names llvm@21 specifically and should be re-checked against llvm#161077 before the next release." >&2
    fi

    # PoCL installs its .icd under its own prefix, not /etc/OpenCL/vendors,
    # so exporting OCL_ICD_VENDORS is mandatory rather than optional.
    emit icd-vendors-path "${pocl_prefix}/etc/OpenCL/vendors"
    emit runtime-name     "pocl"
fi
