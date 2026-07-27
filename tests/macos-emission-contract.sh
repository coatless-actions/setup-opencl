#!/usr/bin/env bash
#
# Asserts the contract of the values scripts/install-macos.sh actually emits on
# macOS, for both PoCL sources. Run from the repository root.
#
# WHY THIS IS A SEPARATE FILE FROM tests/macos-install.sh
#
# That script takes a runtime and a pocl-source and exercises exactly one
# configuration end to end, install through probe. The properties below are
# not properties of one configuration -- they belong to the action, so they
# have to hold for homebrew and conda-forge alike, and a script whose first
# two arguments select a single pair cannot say "both" without changing an
# argument contract every existing caller and the README already use. So the
# assertions live here, where "both" is the default, and tests/macos-install.sh
# calls this file with the emission it already captured (--emitted) so its own
# single-configuration runs get them too, without paying for a second install.
#
# WHAT IS ASSERTED, AND WHY EACH ONE EXISTS
#
# The first two are here because the failure they describe was found by a
# downstream package breaking, not by anything in this repository -- and in
# both cases neither this action nor the one composed with it was wrong on its
# own. They are checks on the seam. The third is a check on identity: which
# PoCL this is, and therefore whether kernels run.
#
#  1. The emitted include directory answers BOTH header spellings, and answers
#     them itself. macOS consumers write <OpenCL/...> and everyone else writes
#     <CL/...>; CLBlast is one of the former. An include directory
#     offering only CL/ does not fail to find a header -- the compiler falls
#     through to Apple's OpenCL.framework inside the SDK, so the build mixes
#     Khronos' cl.h with Apple's cl_gl.h and dies later on an undefined
#     CL_EXT_SUFFIX__VERSION_1_0. Compiling is therefore not the assertion:
#     the fallthrough compiles. Where the header came from is the assertion,
#     read out of the preprocessor's own dependency output.
#
#  2. A C++ program built with the emitted flags acquires no dylib beyond the
#     system ones and the OpenCL loader itself. The conda-forge prefix's lib/
#     holds libc++ as well as the loader; R links packages with clang++, which
#     appends -lc++, and -L directories are searched ahead of the SDK's, so
#     emitting -L<that prefix>/lib made a consumer's shared object resolve
#     libc++ to conda's copy and record an @rpath entry no consumer carries.
#     library.dynam() then fails with "no LC_RPATH's found". This must be C++:
#     scripts/probe.c is C, links no C++ runtime, and could never have seen
#     it. A negative control below proves the check would actually fire.
#
#  3. The PoCL that installed is the one the requested source names, and where
#     that source is the one whose whole purpose is avoiding LLVM 21, it is
#     not on LLVM 21. 'auto' resolving to conda-forge is the entire content of
#     the v1.3.0 release and nothing asserted it: the existing device and
#     kernel gates cannot, because Homebrew's llvm@21 PoCL passes them --
#     it compiles this action's trivial probe kernel fine and segfaults on
#     real work (measured: 4 of 4 runs on a 50x50 elementwise add). So the
#     assertion is on the property that actually differs, the linked LLVM
#     major, rather than on a path proving which branch ran: a major version
#     also catches Homebrew moving onto a good generation, or conda-forge
#     drifting onto a bad one under a rebuild the pinned version allows.
#     Scoped by source, because llvm@21 is not a defect on the Homebrew path
#     -- it is what that path IS, warned about on every run. There the source
#     name is asserted and the generation only reported.
#
# Usage: tests/macos-emission-contract.sh [pocl-source ...]
#          defaults to running both: homebrew conda-forge
#        tests/macos-emission-contract.sh --emitted <file> <label>
#          asserts against an already-captured key=value block instead of
#          installing anything. <label> is the source that was REQUESTED, and
#          it is load-bearing for assertion 3 rather than decoration: 'auto'
#          is a valid label there and is the case that must come back
#          conda-forge
#
# Note: with no --emitted, this runs the real install script once per source,
# exactly as tests/macos-install.sh does. The Homebrew path installs formulae
# onto the machine it runs on; the conda-forge path builds a self-contained
# environment under ${RUNNER_TEMP:-${TMPDIR:-/tmp}}/setup-opencl-conda, so set
# RUNNER_TEMP to a scratch directory to keep it out of the way.

set -euo pipefail

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Checked up front so a missing tool reads as a missing tool. Without this,
# an absent realpath(1) would silently resolve nothing, every load command
# would fail the comparison below, and the report would be a contract
# violation that is not one. All four ship with macOS or the Xcode Command
# Line Tools, which this action already requires for 'cc'.
for tool in cc c++ otool realpath; do
    command -v "${tool}" >/dev/null 2>&1 \
        || fail "'${tool}' is not on PATH. This test needs a C and a C++ compiler, otool to read load commands, and realpath to compare symlinked paths; all arrive with the Xcode Command Line Tools ('xcode-select --install')."
done

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# One C++ translation unit, reused by the assertion and by its negative
# control. <cstdio> alone is enough to make clang++ record a libc++ load
# command -- the driver appends -lc++ whether or not a single libc++ symbol is
# referenced, which is exactly how a consumer that never writes C++ of its own
# still ends up pointed at the wrong one. clGetPlatformIDs keeps a real
# undefined reference to the loader in the object, so the link records it too.
cat > "${workdir}/consumer.cpp" <<'PROGRAM'
#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <cstdio>
int main(void) {
    cl_uint n = 0;
    cl_int status = clGetPlatformIDs(0, 0, &n);
    std::printf("status=%d platforms=%u\n", (int)status, (unsigned)n);
    return 0;
}
PROGRAM

# Every header spelling a consumer might write must resolve inside the
# directory the action emitted, never into an SDK framework.
#
# Four combinations, not two. The spellings are the point -- <CL/...> for
# everyone and <OpenCL/...> for macOS consumers -- but 'opencl.h' is tested
# next to 'cl.h' because it is the one CLBlast's public headers actually
# include (`#if defined(__APPLE__) ... #include <OpenCL/opencl.h>`), and an
# include directory built out of per-file symlinks rather than a directory
# symlink could answer cl.h and not opencl.h. Testing only what the design
# happens to make equivalent today is how the original gap survived review.
assert_both_header_spellings() {
    local label="$1" include_dir="$2" cppflags="$3"
    local pair spelling header resolved

    for pair in CL:cl.h CL:opencl.h OpenCL:cl.h OpenCL:opencl.h; do
        spelling="${pair%%:*}"
        header="${pair#*:}"

        cat > "${workdir}/spelling.c" <<EOF
#define CL_TARGET_OPENCL_VERSION 300
#include <${spelling}/${header}>
int main(void) { return 0; }
EOF

        # -MD records the paths the preprocessor actually opened, so one
        # invocation answers both questions: it compiles, and this is where
        # the header came from.
        # shellcheck disable=SC2086
        cc -c -MD -MF "${workdir}/spelling.d" -o "${workdir}/spelling.o" \
           "${workdir}/spelling.c" ${cppflags} \
            || fail "[${label}] a translation unit including <${spelling}/${header}> does not compile against the emitted opencl-cppflags '${cppflags}'. Both spellings have to work: macOS consumers (CLBlast among them) write <OpenCL/...>, everyone else writes <CL/...>, and the action emits one include directory for both."

        # Dependency output is one target followed by a whitespace-separated,
        # backslash-continued list of paths, so awk's default field splitting
        # is exactly the right parse -- a lone continuation backslash is just
        # a field that matches nothing. Suffix-matched on the header's own
        # name, and the first match wins: the requested header is opened
        # before anything it includes, so this is the file the '#include'
        # above resolved to and not one of its children ('opencl.h' pulls in
        # 'cl.h', which is why matching on 'cl.h' alone would not do).
        resolved="$(awk -v suffix="/${header}" '
            {
                for (i = 1; i <= NF; i++) {
                    if (length($i) > length(suffix) &&
                        substr($i, length($i) - length(suffix) + 1) == suffix) {
                        print $i
                        exit
                    }
                }
            }' "${workdir}/spelling.d")"
        if [ -z "${resolved}" ]; then
            fail "[${label}] could not tell where <${spelling}/${header}> was resolved from: the compiler's dependency output named no ${header} at all. Without that path this assertion cannot distinguish the emitted include directory from Apple's framework, which is the entire question."
        fi

        case "${resolved}" in
            "${include_dir}"/*) ;;
            *.framework/*)
                fail "[${label}] <${spelling}/${header}> resolved to '${resolved}' -- inside an SDK framework, not inside the emitted opencl-include-dir '${include_dir}'. The emitted directory does not offer that spelling, so the compiler fell through to Apple's headers. It compiled anyway: that IS the failure mode. A build that gets Khronos' cl.h from one place and Apple's cl_gl.h from another dies later on an undefined CL_EXT_SUFFIX__VERSION_1_0, a long way from here. Add the missing spelling to the include shim the install script builds."
                ;;
            *)
                fail "[${label}] <${spelling}/${header}> resolved to '${resolved}', which is outside the emitted opencl-include-dir '${include_dir}'. Whatever the action handed the consumer, the consumer is not using it, and the headers it did find are not the ones the emitted loader matches."
                ;;
        esac

        printf '  <%s/%s> resolved to %s\n' "${spelling}" "${header}" "${resolved}"
    done
}

# Prints one line per load command that violates the contract, and nothing at
# all when the binary is clean. Separate from the assertion so the negative
# control below can call it and require a non-empty answer.
foreign_dylibs() {
    local binary="$1" loader_real="$2"
    local deps dep dep_real

    # otool -L's first line is the binary's own name, not a dependency.
    deps="$(otool -L "${binary}" | tail -n +2 \
            | sed -e 's/^[[:space:]]*//' -e 's/ (compatibility version.*$//')"

    while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        case "${dep}" in
            /usr/lib/*|/System/Library/*) continue ;;
            # @rpath, @loader_path and @executable_path all name a search path
            # the consumer has to supply. Nothing downstream of this action
            # carries one, so any of them is a load-time failure waiting to
            # happen and cannot be resolved for comparison either.
            @*) printf '%s\n' "${dep}"; continue ;;
        esac
        dep_real="$(realpath "${dep}" 2>/dev/null || true)"
        if [ -n "${dep_real}" ] && [ "${dep_real}" = "${loader_real}" ]; then
            continue
        fi
        printf '%s\n' "${dep}"
    done <<EOF
${deps}
EOF
}

assert_no_foreign_dylibs() {
    local label="$1" cppflags="$2" libs="$3" library="$4"
    local binary loader_real offenders

    binary="${workdir}/cxx-consumer"
    # shellcheck disable=SC2086
    c++ -o "${binary}" "${workdir}/consumer.cpp" ${cppflags} ${libs} \
        || fail "[${label}] a C++ program does not build against the emitted opencl-cppflags '${cppflags}' and opencl-libs '${libs}'. The action's own probe is C, so C++ is the case nothing else here covers -- and it is the one R packages, CLBlast and every CMake consumer actually compile."

    # Compared by resolved path, not by string: the emitted library is
    # libOpenCL.dylib while what a link records is the install name, usually
    # libOpenCL.1.dylib, and on Homebrew both are symlinks into a Cellar path.
    loader_real="$(realpath "${library}" 2>/dev/null || true)"
    [ -n "${loader_real}" ] \
        || fail "[${label}] the emitted opencl-library '${library}' does not resolve to a real file, so there is nothing to compare the binary's load commands against"

    offenders="$(foreign_dylibs "${binary}" "${loader_real}")"
    if [ -n "${offenders}" ]; then
        printf '%s\n' "--- otool -L ${binary} ---" >&2
        otool -L "${binary}" >&2
        fail "[${label}] a C++ program linked with the emitted flags acquired dylibs that are neither a system library nor the OpenCL loader (${loader_real}):
$(printf '%s\n' "${offenders}" | sed 's/^/    /')
An '@rpath/...' entry names a search path no consumer of this action carries, so the binary or shared object dies at load time with \"no LC_RPATH's found\" -- for an R package, inside library.dynam(), with nothing pointing back here. That happens when an emitted -L points into a prefix holding more than the loader: R links packages with clang++, which appends -lc++, and -L directories are searched ahead of the SDK's, so the prefix's own libc++ wins. Emit a shim directory containing only the loader, not the runtime's whole lib/."
    fi

    printf '  C++ consumer links only system libraries and %s\n' "${loader_real}"
}

# An assertion that cannot fail is not an assertion. This links the same C++
# program the way the broken emission used to -- straight at the runtime
# prefix's own lib/ -- and requires the check above to catch it. Only possible
# where that directory really does ship a libc++ of its own, which is the
# conda-forge prefix and not the Homebrew keg; where it does not, the defect
# is unreachable and the control says so rather than pretending to run.
assert_the_check_can_fail() {
    local label="$1" cppflags="$2" root="$3" loader_real="$4"
    local raw_lib_dir binary offenders

    raw_lib_dir="${root}/lib"
    if ! ls "${raw_lib_dir}"/libc++*.dylib >/dev/null 2>&1; then
        printf '  negative control skipped: %s ships no libc++ of its own, so the flags cannot break this way here\n' "${raw_lib_dir}"
        return 0
    fi

    binary="${workdir}/cxx-control"
    # shellcheck disable=SC2086
    c++ -o "${binary}" "${workdir}/consumer.cpp" ${cppflags} -L"${raw_lib_dir}" -lOpenCL \
        || fail "[${label}] the negative control did not build, so the check above is left unproven"

    offenders="$(foreign_dylibs "${binary}" "${loader_real}")"
    [ -n "${offenders}" ] \
        || fail "[${label}] negative control: a C++ program linked against '${raw_lib_dir}' -- which ships its own libc++ next to the loader, exactly the mistake this file exists to catch -- came back clean. The check above cannot detect the defect it was written for, so its passing means nothing."

    printf '  negative control: -L%s produced %s, correctly rejected\n' \
        "${raw_lib_dir}" "$(printf '%s' "${offenders}" | tr '\n' ' ')"
}

# What a requested source must actually install. Only 'auto' maps to something
# with a different name, and that mapping is the point: it is action.yml's
# resolution, restated here so a run that quietly stopped honoring it fails.
expected_pocl_source() {
    case "$1" in
        auto|conda-forge) printf 'conda-forge\n' ;;
        homebrew)         printf 'homebrew\n' ;;
        *) return 1 ;;
    esac
}

# Identity, not paths: which PoCL is installed and which LLVM it links.
#
# Neither can be inferred from anything else asserted in this file. Both
# sources emit the same shape of include directory and link flags, both
# produce a loader with an absolute install name, and both enumerate a
# healthy fp64 device -- the difference between them only shows up inside a
# real kernel, long after this action has finished and reported success.
assert_pocl_identity() {
    local label="$1" emitted="$2"
    local key expected actual major

    if ! expected="$(expected_pocl_source "${label}")"; then
        fail "unknown pocl-source label '${label}': there is no defined answer for what that should install, so asserting against it would assert nothing. Use 'auto', 'homebrew' or 'conda-forge'."
    fi

    for key in pocl-source pocl-llvm-major; do
        printf '%s\n' "${emitted}" | grep -q "^${key}=" \
            || fail "[${label}] the emission carries no '${key}' key at all. Either the install script did not emit it or it was not wired through action.yml's outputs -- and an assertion against a key that is absent rather than empty is one that can never fail."
    done

    actual="$(printf '%s\n' "${emitted}" | sed -n 's/^pocl-source=//p')"
    if [ "${actual}" != "${expected}" ]; then
        fail "[${label}] requesting pocl-source '${label}' installed PoCL from '${actual:-(nothing reported)}', expected '${expected}'. Every emitted path still looks correct and a device still enumerates, so nothing else here would have noticed; what changes is whether a kernel runs."
    fi

    major="$(printf '%s\n' "${emitted}" | sed -n 's/^pocl-llvm-major=//p')"
    case "${major}" in
        '') ;;
        *[!0-9]*)
            fail "[${label}] pocl-llvm-major is '${major}', which is not a major version number. The install script parses this out of otool's output; a value that is not a bare integer means the parse picked up the wrong thing, and every comparison against it -- including the '!= 21' one below -- would then be meaningless."
            ;;
    esac

    if [ "${expected}" = "conda-forge" ]; then
        # The reason this source exists, restated as a check. Empty is
        # rejected as hard as 21: install-macos-conda.sh refuses both, so an
        # empty value here means the refusal did not run or its result never
        # reached the emission, and "not measured" would otherwise pass a
        # test written to prove "not 21".
        [ -n "${major}" ] \
            || fail "[${label}] pocl-llvm-major is empty, so which LLVM the conda-forge PoCL links was never established. install-macos-conda.sh refuses an unreadable generation outright, so this means the check did not run or its value was lost on the way out -- and an empty string satisfies every '!= 21' comparison there is."
        [ "${major}" != "21" ] \
            || fail "[${label}] the conda-forge PoCL links LLVM 21, the one generation this source exists to avoid: LLVM 21's Clang miscompiles the kernel stubs it generates for OpenCL (llvm#161077, fixed in 22 and never backported to 21.1.x). The device will enumerate, this action's own probe kernel will run, and real work will segfault. Revisit the pinned pocl version in scripts/install-macos-conda.sh."
        printf '  installed conda-forge PoCL, linking LLVM %s (not 21)\n' "${major}"
    else
        # Deliberately not asserted. Homebrew's PoCL is built against llvm@21;
        # that is what this source is, action.yml warns about it on every run,
        # and failing here would be this repository's own test suite objecting
        # to a documented, supported choice. The source name above is the
        # assertion on this path -- it is what proves the branch ran and the
        # value reached the emission -- and the generation is reported so a
        # move off llvm@21 is visible in the log the day it happens.
        printf '  installed Homebrew PoCL, linking LLVM %s (not asserted: llvm@21 is what this source is)\n' \
            "${major:-(not measured)}"
    fi
}

assert_emission() {
    local label="$1" emitted="$2"
    local key root include_dir library cppflags libs loader_real

    assert_pocl_identity "${label}" "${emitted}"

    for key in opencl-root opencl-include-dir opencl-library opencl-cppflags opencl-libs; do
        printf '%s\n' "${emitted}" | grep -q "^${key}=" \
            || fail "[${label}] the install script emitted no '${key}', so there is nothing to assert a contract about"
    done

    root="$(printf '%s\n' "${emitted}" | sed -n 's/^opencl-root=//p')"
    include_dir="$(printf '%s\n' "${emitted}" | sed -n 's/^opencl-include-dir=//p')"
    library="$(printf '%s\n' "${emitted}" | sed -n 's/^opencl-library=//p')"
    cppflags="$(printf '%s\n' "${emitted}" | sed -n 's/^opencl-cppflags=//p')"
    libs="$(printf '%s\n' "${emitted}" | sed -n 's/^opencl-libs=//p')"

    assert_both_header_spellings "${label}" "${include_dir}" "${cppflags}"
    assert_no_foreign_dylibs "${label}" "${cppflags}" "${libs}" "${library}"

    loader_real="$(realpath "${library}")"
    assert_the_check_can_fail "${label}" "${cppflags}" "${root}" "${loader_real}"

    printf 'PASS: %s installed the PoCL it names, on an LLVM generation that is allowed for it, and emits an include directory answering both spellings and link flags that pull in nothing but the loader\n' \
        "${label}"
}

if [ "${1:-}" = "--emitted" ]; then
    [ "$#" -eq 3 ] \
        || fail "usage: tests/macos-emission-contract.sh --emitted <file> <label>"
    [ -r "$2" ] || fail "cannot read the emitted key=value block at '$2'"
    assert_emission "$3" "$(cat "$2")"
    exit 0
fi

sources="$*"
[ -n "${sources}" ] || sources="homebrew conda-forge"

for source in ${sources}; do
    case "${source}" in
        homebrew|conda-forge) ;;
        *)
            fail "unknown pocl-source '${source}': this asserts the contract of a Khronos layout, and only 'homebrew' and 'conda-forge' produce one. Anything else would be labelled as a source it is not."
            ;;
    esac

    printf '== pocl-source: %s ==\n' "${source}"
    assert_emission "${source}" \
        "$(SE_RUNTIME=pocl SE_POCL_SOURCE="${source}" bash scripts/install-macos.sh)"
done
