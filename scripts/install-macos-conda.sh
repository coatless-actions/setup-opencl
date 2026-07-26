#!/usr/bin/env bash
#
# Install PoCL, the Khronos ICD loader, and OpenCL headers on macOS from
# conda-forge, into one self-contained prefix, then print the resulting paths
# as key=value lines. install-macos.sh hands off to this script when
# 'pocl-source' resolves to conda-forge; it is also runnable on its own, which
# is what tests/macos-install.sh does.
#
# WHY A SECOND MACOS SOURCE EXISTS
#
# Homebrew's pocl 7.1 links llvm@21 (21.1.8). LLVM 21's Clang miscompiles the
# kernel stubs it generates for OpenCL -- llvm#161077, fixed in LLVM 22 and
# never backported to the 21.1.x line -- so the runtime enumerates a healthy
# fp64 CPU device and then dies inside real kernels. Measured on Apple silicon
# against RcppBandicoot's suite: three separate operations exited 139 on
# Homebrew's PoCL and passed on conda-forge's, with nothing changed between
# the two runs but OCL_ICD_VENDORS. Two other downstreams already route around
# the same generation -- PoCL's own README marks its CUDA backend broken on
# LLVM 21, and Arch pins pocl to clang20.
#
# conda-forge's pocl-core 7.1 build 2 carries a 'libllvm19 >=19.1.7,<19.2' run
# dependency, so picking that channel is what picks the LLVM generation.
# Nothing below asks for LLVM 19 by name, which is why the version pin matters
# and why the linkage actually installed is reported into the log every run.
#
# WHY MICROMAMBA
#
# A single static binary, no base environment, no shell integration, and
# nothing left on the runner outside ${RUNNER_TEMP}. The macOS runner images
# do ship a Miniconda, but its channel configuration and .condarc belong to
# the image rather than to this action, and using it would make the solve
# depend on state this script cannot see. micromamba with --no-rc --no-env
# takes every input from its own command line.
#
# WHY THE LOADER'S INSTALL NAME IS REWRITTEN
#
# See the block above install_name_tool below. Short version: conda ships
# @rpath install names, this action's consumers carry no rpath, and Homebrew's
# loader -- which every existing macOS consumer of this action is built
# against -- has an absolute one. Rewriting makes the two sources
# interchangeable instead of subtly different.

set -euo pipefail

# Everything this script shells out to -- curl, micromamba, install_name_tool
# -- prints to stdout, and action.yml captures this script's stdout as a
# key=value contract. micromamba's transaction table alone is dozens of lines,
# and a single line of it that happened to look like 'key=value' would land in
# GITHUB_OUTPUT. Move the contract onto fd 3 and give stdout to the chatter.
# Diagnostics then also reach the job log immediately rather than only being
# replayed after the capture succeeds, which is what install-linux.sh's
# stderr-only error messages exist to guarantee on the failure paths.
exec 3>&1
exec 1>&2

emit() { printf '%s=%s\n' "$1" "$2" >&3; }

# The relocation below is not optional and neither is reading back what it
# did, so a missing tool is a hard failure with a real diagnostic rather than
# a bare "command not found" from the middle of the install. All three ship
# with the Xcode Command Line Tools, which this action already requires on
# macOS for 'cc'.
for tool in curl shasum otool install_name_tool codesign; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "::error::'${tool}' not found on PATH"
        echo "The conda-forge PoCL source needs the Xcode Command Line Tools ('xcode-select --install'). Use 'pocl-source: homebrew' if that is not possible on this runner."
        exit 1
    fi
done

# Pinned defaults. The '=' alignment matches install-windows.ps1's pinned
# block; keep it if these are edited by hand.
#
# PoCL is pinned to an exact minor version rather than floated because the
# LLVM generation is a *transitive* choice: conda-forge's pocl-core carries a
# libllvm19 run dependency today and a future pocl release will carry a
# different one. Floating would silently move this path onto whatever LLVM
# conda-forge builds against next -- possibly 21 -- and hand back exactly the
# runtime this source exists to avoid. The build number is deliberately not
# pinned: conda-forge rebuilds a given version against newer dependencies
# under a higher build number, so within 7.1 it is the LLVM check further down
# that catches drift, not this pin. That check refuses the install outright
# rather than warning, so a rebuild onto a bad generation stops the job
# instead of handing back a device that segfaults once it compiles a kernel.
#
# The micromamba digests are pins fixed here, checked against the downloaded
# file before it is ever executed -- the same rule install-windows.ps1 applies
# to the Windows SDK and runtime archives.
pocl_version='7.1'
micromamba_version='2.8.1-0'
micromamba_arm64_sha256='de71a646b73af92dd663e6ddc78993a6a4d47ea28b5d8908c3cc2b9c3077e528'
micromamba_x64_sha256='b2bd613791c0a524883d7cb66505d630bf15badd1f492bc93ba78550a3a1a94b'

case "$(uname -m)" in
    arm64)
        mm_platform='osx-arm64'
        mm_sha256="${micromamba_arm64_sha256}"
        ;;
    x86_64)
        mm_platform='osx-64'
        mm_sha256="${micromamba_x64_sha256}"
        ;;
    *)
        echo "::error::Unsupported macOS architecture '$(uname -m)' for the conda-forge PoCL source"
        echo "micromamba is published for osx-arm64 and osx-64 only. Use 'pocl-source: homebrew' on this runner."
        exit 1
        ;;
esac

# RUNNER_TEMP exists only on a GitHub Actions runner; fall back to system temp
# directories so this script can run locally, the same fallback the Homebrew
# path uses for its shim directories.
#
# ${env_dir} is also the literal path action.yml's cache step restores, so the
# two must agree -- change one and change the other.
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
env_dir="${temp_root}/setup-opencl-conda"
marker="${env_dir}/.setup-opencl-stamp"

# micromamba's own root -- its package cache and index -- deliberately lives
# OUTSIDE ${env_dir}. It is another ~400 MB of extracted packages and tarballs
# that the environment does not need at runtime, and keeping it out halves
# what the cache entry has to carry.
mamba_root="${temp_root}/setup-opencl-micromamba"

# What a reusable tree must have been built from. Both pins are in it, so an
# environment restored from a cache entry whose key no longer reflects this
# script's pins is rebuilt instead of trusted. So is the prefix: the loader's
# install name is rewritten below to an absolute path inside ${env_dir}, which
# makes this environment non-relocatable by construction, and a tree restored
# under a different prefix than it was built at would hand back a loader
# pointing somewhere that no longer exists. Hosted runners have a fixed
# RUNNER_TEMP so this cannot happen there; a self-hosted one has no such
# guarantee, and the cost of noticing is one string comparison.
stamp="pocl=${pocl_version} micromamba=${micromamba_version} platform=${mm_platform} prefix=${env_dir}"

sdk_path="$(xcrun --show-sdk-path)"

# The stamp is written last, after the tree has been checked and relocated, so
# a half-restored or half-built environment never looks complete.
if [ -f "${marker}" ] && [ "$(cat "${marker}")" = "${stamp}" ]; then
    echo "Reusing the cached conda-forge environment at ${env_dir} (${stamp})."
else
    rm -rf "${env_dir}"

    mm_dir="$(mktemp -d)"
    trap 'rm -rf "${mm_dir}"' EXIT
    mm="${mm_dir}/micromamba"
    mm_url="https://github.com/mamba-org/micromamba-releases/releases/download/${micromamba_version}/micromamba-${mm_platform}"

    echo "Downloading micromamba ${micromamba_version} for ${mm_platform}..."
    curl -fsSL --retry 3 --retry-delay 2 -o "${mm}" "${mm_url}"

    actual_sha256="$(shasum -a 256 "${mm}" | cut -d' ' -f1)"
    if [ "${actual_sha256}" != "${mm_sha256}" ]; then
        echo "::error::SHA-256 mismatch for micromamba ${micromamba_version} (${mm_platform})"
        echo "Expected ${mm_sha256}, got ${actual_sha256}. Nothing was executed. Either the release asset was replaced upstream or the download was tampered with in transit; verify the asset out of band before updating the pin in this script."
        exit 1
    fi
    chmod +x "${mm}"

    # --no-rc and --no-env make this hermetic: no .condarc, no .mambarc, and
    # no CONDA_*/MAMBA_* variable the runner image or a caller happens to have
    # set can add a channel, redirect the package cache, or otherwise change
    # the solve. Every input comes from this command line. Naming only
    # conda-forge also keeps the 'defaults' channel -- whose terms of service
    # now require explicit acceptance -- out of the solve entirely.
    #
    # The 'pocl' metapackage is what pulls pocl-core (libpocl and the .icd),
    # pocl-cpu (the pthread device) and pocl-cpu-minimal together, and it is
    # the exact package whose osx-arm64 build was measured running
    # RcppBandicoot's kernels correctly. opencl-headers and
    # khronos-opencl-icd-loader arrive as dependencies of pocl-core anyway,
    # but are requested by name because this script emits paths into both: a
    # transitive dependency is free to disappear, a requested one is not.
    echo "Creating the conda-forge environment at ${env_dir} (pocl=${pocl_version})..."
    "${mm}" create --yes --no-rc --no-env \
        --root-prefix "${mamba_root}" \
        --prefix "${env_dir}" \
        --channel conda-forge \
        "pocl=${pocl_version}" opencl-headers khronos-opencl-icd-loader

    # Unlike Apple's framework, whose headers sit directly under Headers/ with
    # no CL subdirectory, conda-forge's opencl-headers already installs
    # include/CL/cl.h (plus an include/OpenCL -> CL symlink). No shim
    # directory is built here, and none is needed. The prefix also holds both
    # halves -- headers and loader -- so it can be handed out as opencl-root
    # directly, where the Homebrew path has to merge two keg-only prefixes
    # into a symlinked root first.
    for required in \
        "${env_dir}/include/CL/cl.h" \
        "${env_dir}/lib/libOpenCL.dylib" \
        "${env_dir}/lib/libOpenCL.1.dylib" \
        "${env_dir}/lib/libpocl.dylib" \
        "${env_dir}/etc/OpenCL/vendors/pocl.icd"; do
        if [ ! -e "${required}" ]; then
            echo "::error::The conda-forge environment is missing ${required}"
            echo "The layout of conda-forge's pocl / khronos-opencl-icd-loader / opencl-headers packages has changed, so the paths this script emits would be wrong. Use 'pocl-source: homebrew' until this script is updated."
            exit 1
        fi
    done

    # conda rewrites its build prefix inside pocl.icd when the package is
    # linked into an environment, so the path it holds must land inside this
    # environment. If it does not, the loader would be pointed at some other
    # PoCL -- or at nothing -- while every path emitted below still looked
    # right.
    icd_target="$(cat "${env_dir}/etc/OpenCL/vendors/pocl.icd")"
    # Compare resolved paths. conda writes the prefix as the kernel reports it,
    # so on macOS a prefix under /tmp comes back as /private/tmp and a literal
    # comparison fails on a path that is in fact correct. Hosted runners put
    # RUNNER_TEMP under /Users/runner and never hit it; a local run does.
    icd_target_real="$(cd "$(dirname "${icd_target}")" 2>/dev/null && pwd -P)/$(basename "${icd_target}")"
    env_dir_real="$(cd "${env_dir}" && pwd -P)"
    case "${icd_target_real}" in
        "${env_dir_real}"/*) ;;
        *)
            echo "::error::pocl.icd points at '${icd_target}', which is outside ${env_dir}"
            echo "conda's prefix rewriting did not run, or the environment was relocated after installation. The ICD loader would not load this environment's PoCL."
            exit 1
            ;;
    esac

    # conda builds its dylibs with an @rpath install name
    # (@rpath/libOpenCL.1.dylib), which is how conda environments stay
    # relocatable: every consumer is expected to carry its own -rpath. This
    # action's consumers do not. Measured, both on Apple silicon:
    #
    #   * probe.c linked '-L<env>/lib -lOpenCL' compiles cleanly and then dies
    #     at launch -- "Library not loaded: @rpath/libOpenCL.1.dylib ... no
    #     LC_RPATH's found".
    #   * a shared library built the way the sibling setup-clblast action
    #     builds CLBlast, against the absolute ${OpenCL_LIBRARY} path, records
    #     that same unresolvable @rpath reference in its own load commands.
    #
    # Homebrew's opencl-icd-loader keg -- which every existing macOS consumer
    # of this action is already built against -- has an absolute install name
    # (/opt/homebrew/opt/opencl-icd-loader/lib/libOpenCL.1.dylib). Rewriting
    # conda's to match makes the two sources interchangeable: identical
    # opencl-libs shape, and nothing downstream needs an rpath it does not
    # already have. Relocating install names is what Homebrew itself does when
    # it pours a bottle, not a workaround invented here.
    #
    # install_name_tool invalidates the code signature and prints a warning
    # saying so. On Apple silicon an invalid signature is fatal -- dyld kills
    # the process outright (SIGKILL, exit 137) rather than refusing to load
    # the library -- so re-sign ad hoc immediately afterwards.
    #
    # These are the system tools, not the environment's: the solve pulls in
    # conda-forge's own ld64 and sigtool-codesign, but nothing here ever puts
    # ${env_dir}/bin on PATH, so /usr/bin/codesign is what signs this.
    loader_real="${env_dir}/lib/libOpenCL.dylib"
    hops=0
    while [ -L "${loader_real}" ]; do
        hops=$((hops + 1))
        if [ "${hops}" -gt 8 ]; then
            echo "::error::${env_dir}/lib/libOpenCL.dylib does not resolve to a real file within 8 symlink hops"
            exit 1
        fi
        target="$(readlink "${loader_real}")"
        case "${target}" in
            /*) loader_real="${target}" ;;
            *)  loader_real="$(dirname "${loader_real}")/${target}" ;;
        esac
    done

    loader_id="${env_dir}/lib/libOpenCL.1.dylib"
    echo "Rewriting ${loader_real}'s install name to ${loader_id} and re-signing it ad hoc; install_name_tool's code-signature warning below is expected."
    install_name_tool -id "${loader_id}" "${loader_real}"
    codesign --force --sign - "${loader_real}"

    # otool -D prints the file name on its own line first, then the id.
    actual_id="$(otool -D "${loader_real}" | tail -1)"
    if [ "${actual_id}" != "${loader_id}" ]; then
        echo "::error::The ICD loader's install name is '${actual_id}', expected '${loader_id}'"
        echo "install_name_tool did not take effect, so anything linked against this loader would die at launch with 'no LC_RPATH's found' instead of loading it."
        exit 1
    fi

    printf '%s' "${stamp}" > "${marker}"
fi

# Reported on every run, cache hit included. The pin above chooses a pocl
# version, not an LLVM generation, and which LLVM ends up underneath is the
# entire reason this source exists. Read with otool rather than from the
# environment's package list because the list cannot answer the question: a
# solve for pocl 7.1 installs libllvm19 *and* libllvm22 (the latter pulled in
# by ld64), and only libpocl's own load commands say which one PoCL uses.
llvm_line="$(otool -L "${env_dir}/lib/libpocl.dylib" | grep -i 'libLLVM' | head -1 | sed 's/^[[:space:]]*//' || true)"
echo "conda-forge PoCL ${pocl_version} links: ${llvm_line:-(otool reported no libLLVM dependency)}"

# conda-forge carries the generation in the SONAME (libLLVM.19.1.dylib), so
# the file name is enough here. install-macos.sh parses the Homebrew keg name
# instead, because Homebrew's is an unversioned libLLVM.dylib.
llvm_major="$(printf '%s' "${llvm_line}" | sed -n 's/.*libLLVM\.\([0-9][0-9]*\).*/\1/p')"
# Refused rather than warned. The whole purpose of this source is "a PoCL that
# is not built against LLVM 21"; installing one anyway and carrying on would
# hand back a device that enumerates as perfectly healthy and then segfaults
# mid-kernel, with the only warning buried in an annotation nobody reads. An
# empty llvm_major is treated the same way: if a future build links an
# unversioned libLLVM.dylib the parse yields nothing, and silently passing an
# unknown generation is exactly the failure this check exists to prevent.
if [ "${llvm_major}" = "21" ] || [ -z "${llvm_major}" ]; then
    echo "::error::conda-forge's pocl ${pocl_version} links ${llvm_line:-an LLVM whose generation could not be determined}"
    echo "This source exists precisely to avoid LLVM 21 (llvm#161077 -- fixed in LLVM 22, never backported to 21.1.8), so an unusable or unknown generation is refused rather than installed. Revisit the pinned pocl version in scripts/install-macos-conda.sh."
    exit 1
fi

# The loader and the headers are re-exported through shim directories that
# contain nothing else.
#
# The environment's own lib/ is not a keg holding one library: pocl-core pulls
# in libcxx, libzlib and libjpeg-turbo, and libllvm19 adds libxml2 and zstd. R
# links packages with clang++, which appends -lc++, and -L directories are
# searched ahead of the SDK's, so handing a consumer -L${env_dir}/lib makes its
# .so resolve -lc++ to conda's libc++ and record @rpath/libc++.1.dylib -- with
# no rpath anywhere downstream to satisfy it. library.dynam() then fails with
# "no LC_RPATH's found" and the package never loads. That is invisible to
# probe.c, which is C and links no C++ runtime, so nothing in this action's own
# tests would have caught it. include/ has the same problem in the milder
# direction: it carries zlib.h, jpeglib.h, hwloc.h and zstd.h, which would sit
# ahead of the SDK's.
#
# The Homebrew branch needs none of this because its keg genuinely does contain
# only libOpenCL.
lib_shim="${env_dir}/.setup-opencl-lib-shim"
inc_shim="${env_dir}/.setup-opencl-include-shim"
rm -rf "${lib_shim}" "${inc_shim}"
mkdir -p "${lib_shim}" "${inc_shim}"
for lib in "${env_dir}"/lib/libOpenCL*.dylib; do
    [ -e "${lib}" ] || continue
    ln -sfn "${lib}" "${lib_shim}/$(basename "${lib}")"
done
ln -sfn "${env_dir}/include/CL" "${inc_shim}/CL"

emit opencl-root        "${env_dir}"
emit opencl-include-dir "${inc_shim}"
emit opencl-library     "${env_dir}/lib/libOpenCL.dylib"
emit opencl-cppflags    "-I${inc_shim}"
emit opencl-libs        "-L${lib_shim} -lOpenCL"
# PoCL's .icd lives under the environment's own prefix, never
# /etc/OpenCL/vendors, so exporting OCL_ICD_VENDORS is mandatory rather than
# optional -- same as the Homebrew path. The loader in this environment does
# default to this exact directory (conda rewrites the compiled-in vendor path
# too), but saying so explicitly is what keeps any other PoCL installed on the
# runner from also being enumerated.
emit icd-vendors-path   "${env_dir}/etc/OpenCL/vendors"
emit runtime-name       "pocl"
# PoCL's LLVM cannot find system headers without SDKROOT.
emit sdkroot            "${sdk_path}"
