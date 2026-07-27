#!/usr/bin/env bash
#
# Runs the macOS install script and the probe on this machine, so the macOS
# paths can be exercised without pushing to CI. The counterpart to
# tests/linux-container.sh, which does the same for Linux inside a container.
# Run from the repository root.
#
# Usage: tests/macos-install.sh [runtime] [pocl-source] [expectation]
#   runtime     defaults to pocl; the other documented values are apple, none
#   pocl-source defaults to empty, which is what a bare local run of the
#               install script sees and takes the Homebrew path. Note this is
#               NOT what the action's 'pocl-source: auto' resolves to any more
#               -- that is conda-forge -- so pass 'conda-forge' to exercise
#               what an unconfigured caller now gets
#   expectation passed to tests/probe-contract.sh; defaults to >=1 for a
#               runtime that installs a device and =0 for 'none'
#
# For runtime 'pocl' this also runs tests/macos-emission-contract.sh against
# the values this run emitted, so the header-spelling and C++ linkage
# contracts are checked here too. That file is where they live because they
# have to hold for BOTH pocl sources, which is one run of this script each;
# run it with no arguments to cover both in one command.
#
# Note: there is no container to isolate this. The Homebrew path installs
# formulae onto the machine it runs on, exactly as it would on a runner. The
# conda-forge path does not -- it builds a self-contained environment under
# ${RUNNER_TEMP:-${TMPDIR:-/tmp}}/setup-opencl-conda and touches nothing else,
# so set RUNNER_TEMP to a scratch directory to keep it out of the way.

set -euo pipefail

runtime="${1:-pocl}"
pocl_source="${2:-}"

# Validated rather than passed through. A value the install script does not
# recognize does not fail there -- it falls through to Homebrew on purpose,
# so a standalone run never stops on a typo -- which means a mistyped
# 'conda-forge' would install Homebrew's PoCL and this script would then
# report PASS under the label the caller typed. That is the same silent
# substitution the emission contract exists to catch, one level up.
case "${pocl_source}" in
    ''|homebrew|conda-forge) ;;
    *)
        echo "Unknown pocl-source '${pocl_source}': use 'homebrew', 'conda-forge', or leave it empty for the Homebrew path a bare local run takes." >&2
        exit 1
        ;;
esac

expectation="${3:-}"
if [ -z "${expectation}" ]; then
    expectation=">=1"
    [ "${runtime}" = "none" ] && expectation="=0"
    # Apple's framework enumerates a platform and no device on a hosted
    # runner, but does report one on bare-metal Apple silicon, so there is no
    # single right answer here. >=0 would assert nothing on an unsigned count;
    # make the caller say what they expect instead.
    if [ "${runtime}" = "apple" ]; then
        echo "Pass an explicit expectation for 'apple': hosted runners report 0 devices, bare metal reports 1." >&2
        exit 1
    fi
fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

out="$(SE_RUNTIME="${runtime}" SE_POCL_SOURCE="${pocl_source}" bash scripts/install-macos.sh)"
printf '%s\n' "${out}"

value() { printf '%s\n' "${out}" | sed -n "s/^$1=//p"; }

# pocl-source and pocl-llvm-major are in this list for every runtime, not just
# 'pocl': the install script emits them empty when it installs no PoCL, so a
# consumer can tell "nothing to report" from "never wired through". A missing
# key here would be the latter.
for key in opencl-root opencl-include-dir opencl-library opencl-cppflags \
           opencl-libs icd-vendors-path runtime-name sdkroot \
           pocl-source pocl-llvm-major; do
    printf '%s\n' "${out}" | grep -q "^${key}=" \
        || fail "missing key '${key}' in the install script's output"
done

include_dir="$(value opencl-include-dir)"
[ -e "${include_dir}/CL/cl.h" ] \
    || fail "opencl-include-dir '${include_dir}' does not contain CL/cl.h"

library="$(value opencl-library)"
[ -e "${library}" ] || fail "opencl-library '${library}' does not exist"

if [ "${runtime}" = "pocl" ]; then
    # The loader must be a Khronos ICD loader, never Apple's framework: the
    # framework exports no clIcdGetPlatformIDsKHR and cannot load PoCL at all,
    # and a build that silently fell back to it would still link and still
    # report a platform.
    case "${library}" in
        *OpenCL.framework*) fail "runtime 'pocl' emitted Apple's framework as opencl-library: ${library}" ;;
    esac

    # An absolute install name is what lets a consumer link '-L<dir> -lOpenCL'
    # -- or, like the sibling setup-clblast action, link the absolute
    # opencl-library path -- and get something that loads without carrying an
    # rpath of its own. conda-forge ships @rpath install names and
    # install-macos-conda.sh rewrites them for exactly this reason; Homebrew's
    # keg is absolute already. Either way the guarantee is the same, so assert
    # it for both sources rather than only the one that has to work for it.
    install_name="$(otool -D "${library}" | tail -1)"
    case "${install_name}" in
        /*) ;;
        *) fail "opencl-library's install name is '${install_name}', not an absolute path; anything linked against it will die at launch with 'no LC_RPATH's found'" ;;
    esac

    vendors="$(value icd-vendors-path)"
    [ -d "${vendors}" ] || fail "icd-vendors-path '${vendors}' is not a directory"
    ls "${vendors}"/*.icd >/dev/null 2>&1 \
        || fail "icd-vendors-path '${vendors}' contains no .icd file"

    # Fed the emission this run already captured rather than letting the
    # contract script install a second time. An empty pocl-source took the
    # Homebrew path above, so that is what it is labelled.
    tests/macos-emission-contract.sh --emitted \
        <(printf '%s\n' "${out}") "${pocl_source:-homebrew}"
fi

OPENCL_CPPFLAGS="$(value opencl-cppflags)"
OPENCL_LIBS="$(value opencl-libs)"
SDKROOT="$(value sdkroot)"

# Empty for 'apple' and 'none', where there is no vendor ICD to point at.
# Exported anyway so the probe below never inherits a stale value from the
# surrounding shell, which is precisely how a 'none' run would otherwise
# appear to find a device.
OCL_ICD_VENDORS="$(value icd-vendors-path)"

export OPENCL_CPPFLAGS OPENCL_LIBS SDKROOT OCL_ICD_VENDORS

tests/probe-contract.sh "${expectation}"
