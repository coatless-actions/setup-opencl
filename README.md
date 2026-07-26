# Setup OpenCL

[![Test](https://github.com/coatless-actions/setup-opencl/actions/workflows/test.yml/badge.svg)](https://github.com/coatless-actions/setup-opencl/actions/workflows/test.yml)

Install OpenCL headers, an ICD loader, and a working CPU device on GitHub-hosted runners.

Installing headers and a loader is one package-manager line per platform. Producing a runner where an OpenCL kernel actually executes is harder, and getting it wrong is quiet: a job that compiles and links against OpenCL but enumerates zero devices passes its test suite without running a single kernel. This action installs a real CPU device, registers it with the loader, and fails the job when no device is found, unless you explicitly ask for headers only.

Enumerating a device is not the same as being able to use one, so the action also runs a real kernel — build, launch, read back, compare the numbers — and reports the result as the `kernel` output. A device that reports itself as present and healthy while its runtime cannot compile a single kernel is a real state, and one this action used to pass over in silence; now it always warns, and fails the job if you ask it to.

## Quickstart

    name: test
    on: [push, pull_request]

    jobs:
      test:
        runs-on: ${{ matrix.os }}
        strategy:
          matrix:
            os: [ubuntu-24.04, macos-latest, windows-2025]
        steps:
          - uses: actions/checkout@v6
          - uses: coatless-actions/setup-opencl@v1
          - run: cc -o demo demo.c $OPENCL_CPPFLAGS $OPENCL_LIBS
            shell: bash

## Inputs

| Input | Description | Default |
|---|---|---|
| `runtime` | OpenCL runtime to install: `pocl`, `intel`, `apple`, `none`, or `auto`. `auto` resolves to `pocl` on Linux and macOS and `intel` on Windows. | `auto` |
| `pocl-source` | Where PoCL comes from on macOS: `homebrew`, `conda-forge`, or `auto`. Only honored for `runtime: pocl` on macOS; ignored, with a warning, for every other platform and runtime. `auto` resolves to `conda-forge`, which costs about 90 MB of downloads on a cold cache; `homebrew` is faster but its PoCL miscompiles OpenCL kernels — see [PoCL on macOS](#pocl-on-macos). | `auto` |
| `version` | Pin the runtime version. Only honored for `runtime: intel` on Windows, where it takes an `intel/llvm` release tag (e.g. `2026-WW22`). Ignored, with a warning, for every other runtime. Verified against the digest the GitHub API reports for that release at resolution time, not a pinned one, and the job fails if the API reports none and `version-sha256` supplies none either. | `''` |
| `version-sha256` | Expected SHA-256 (64 hex characters, no `sha256:` prefix) of the asset `version` selects. Needed only for a release whose asset predates the digest GitHub now reports. Must agree with the API's digest when both exist. Ignored, with a warning, when `version` is unset. | `''` |
| `verify` | Fail the job when no OpenCL device is found (`'true'` or `'false'`). Never fatal when `runtime` is `none`. | `true` |
| `require-fp64` | Also fail when the device does not support double precision (`'true'` or `'false'`). | `false` |
| `require-kernel` | Also fail when the device cannot actually run a kernel (`'true'` or `'false'`). The state is **always** reported as a warning; this makes it fatal. | `false` |
| `cache` | Cache downloads and package archives (`'true'` or `'false'`). A no-op on runners with nothing worth caching. | `true` |

`runtime`, `pocl-source`, `verify`, `require-fp64`, `require-kernel`, and `cache` are validated by hand, since the runner enforces neither input types nor allowed values. An **empty string** (for example `verify: ''`, which is what an absent key in a build matrix expands to) is rejected rather than falling back to the default above — the action cannot distinguish "omitted" from "explicitly empty." Leave the input out of `with:` entirely to get the default, or interpolate a matrix value that is guaranteed to be `'true'`/`'false'` on every leg. `version` and `version-sha256` are strings rather than flags, so an empty value is the documented way to say "unset".

## Outputs

| Output | Description |
|---|---|
| `opencl-root` | Root directory of the installed OpenCL SDK. |
| `opencl-include-dir` | Directory containing `CL/cl.h`. |
| `opencl-library` | Full path to the ICD loader library. |
| `icd-vendors-path` | Diagnostic; not a portable value. See the note below the table. |
| `runtime-name` | Runtime actually installed: `pocl`, `intel-cpu`, `apple`, or `none`. |
| `platform-version` | `CL_PLATFORM_VERSION` of the platform providing the first device. |
| `device-name` | `CL_DEVICE_NAME` of the first device found. |
| `device-count` | Number of OpenCL devices found. Zero is a valid value, not an error signal. |
| `fp64` | Whether the first device reports double-precision support. |
| `kernel` | Whether the first device actually ran a kernel and returned the right numbers. `false` whenever `device-count` is `0`, and `false` when the check could not be run at all. |

`kernel` is the only output measured by running something rather than by asking the device what it supports. Every other value above comes from `clGetDeviceInfo` or `clinfo`, both of which describe a device that has not been asked to do anything yet; `kernel` is the result of `clCreateProgramWithSource` → `clBuildProgram` → `clEnqueueNDRangeKernel` → `clEnqueueReadBuffer` on the first device, with the bytes that come back compared against the arithmetic the kernel was supposed to perform. That distinction is not academic: an Intel CPU runtime on Windows can report a healthy fp64 device and then crash (`0xC0000005`, inside `common_clang64.dll`) on every kernel build it is given. `device-count`, `device-name`, `platform-version`, and `fp64` are all accurate in that state, and all four are useless.

When `device-count` is greater than zero and `kernel` is `false`, the action always emits a warning, whatever the other inputs say. Set `require-kernel: 'true'` to make it fail the job instead.

The action also exports `OPENCL_CPPFLAGS`, `OPENCL_LIBS`, `OpenCL_ROOT`, `OpenCL_LIBRARY`, and `OpenCL_INCLUDE_DIR` to the job environment, plus `OCL_ICD_VENDORS` on Linux and macOS (when a vendor ICD was installed), `OCL_ICD_FILENAMES` on Windows, and `SDKROOT` on macOS. On Windows, the loader's `bin` directory (containing `clinfo.exe` and the loader DLL) is also prepended to `PATH`. A caller's own explicit setting of any of these always wins over the action's.

`icd-vendors-path` means three different things depending on the platform: a **file** on Linux (the single `.icd` under `/etc/OpenCL/vendors`), a **directory** on macOS (PoCL's vendors directory inside whichever prefix `pocl-source` selected), and a **vendor DLL path** on Windows (the value passed to `OCL_ICD_FILENAMES` and written to the registry). Each is correct for its own loader, but none of them is a portable value: a workflow that does, say, `export OCL_ICD_VENDORS=${{ steps.opencl.outputs.icd-vendors-path }}` to work identically across platforms will get three different semantics, and on Windows that variable is the wrong one entirely. Do not wire this output up yourself — the action already exports the loader-correct environment variable for the current platform (`OCL_ICD_VENDORS` on Linux and macOS, `OCL_ICD_FILENAMES` on Windows), and that is what a cross-platform consumer should rely on. `icd-vendors-path` exists for diagnostics (what did the action actually point the loader at?) and for cache keys, not for consumers to depend on directly.

## Examples

### Require double precision

    - uses: coatless-actions/setup-opencl@v1
      with:
        require-fp64: 'true'

### Headers and loader only, no device

    - uses: coatless-actions/setup-opencl@v1
      with:
        runtime: none

### Require a device that can actually run a kernel

    - uses: coatless-actions/setup-opencl@v1
      with:
        require-kernel: 'true'

### Trade a working kernel compiler for a faster macOS install

On macOS the action installs conda-forge's PoCL by default, because Homebrew's is built against `llvm@21` and miscompiles OpenCL kernels. That costs about 90 MB of downloads and an environment build the first time, cached afterwards. If your job never compiles a kernel — it only needs headers, a loader and a device that enumerates — Homebrew's is faster on a cold cache and still available. The action warns on every run that you have chosen it. See [PoCL on macOS](#pocl-on-macos).

    - uses: coatless-actions/setup-opencl@v1
      with:
        pocl-source: homebrew

### Branch on the device that was found

    - uses: coatless-actions/setup-opencl@v1
      id: opencl
    - if: steps.opencl.outputs.fp64 == 'true'
      run: ./run-double-precision-tests
    - if: steps.opencl.outputs.kernel == 'true'
      run: ./run-gpu-tests

### Compile against Apple's framework (compile-only on hosted runners)

Apple's `OpenCL.framework` enumerates a platform on hosted `macos-latest` runners but `clGetDeviceIDs` returns `-30` there, so `device-count` is `0`. This is a property of the virtualized runner, not of the framework: the same framework reports one device on bare-metal Apple Silicon. `verify: 'false'` is required to use `runtime: apple` in hosted CI; without it, the action fails the job on the expected zero-device count.

    - uses: coatless-actions/setup-opencl@v1
      with:
        runtime: apple
        verify: 'false'

### Pin the Intel CPU runtime on Windows

    - uses: coatless-actions/setup-opencl@v1
      with:
        runtime: intel
        version: '2026-WW22'

### Pin a release whose asset has no published digest

Nothing is ever installed unverified. The pinned default carries a digest fixed in this action's source; a `version:` override is normally verified against the digest the GitHub Releases API reports for that asset. Older assets — uploaded before GitHub began computing that field — report no digest at all, and the action refuses them rather than downloading 110 MB of unverified binary it is about to register machine-wide. `version-sha256` is how you pin one anyway: you state the digest you expect, and it is verified against that.

    - uses: coatless-actions/setup-opencl@v1
      with:
        runtime: intel
        version: '2025-WW13'
        version-sha256: '<64 hex characters>'

Obtain the value by fetching the asset once from its release page, satisfying yourself out of band that the copy is genuine, and hashing it:

    Get-FileHash -Algorithm SHA256 win-oclcpuexp-<version>_rel.zip   # Windows
    sha256sum win-oclcpuexp-<version>_rel.zip                        # Linux/macOS

If the API does report a digest and it disagrees with yours, the job fails and installs nothing — the disagreement means one of the two describes a different file, and the action will not choose for you. Supplying a digest turns a moving target into a pin fixed in your workflow; on its own it does not authenticate the origin, which is why the out-of-band step above matters.

## Requirements

Requirements differ by platform:

- **Linux** needs a C compiler (`cc`) and a Debian-family package manager (`apt-get`). The compiler builds a small probe program to check for a device — even when `runtime` is `none` and `verify` is `'false'` — and `apt-get` installs the headers, loader, and (unless `runtime` is `none`) PoCL.
- **macOS** needs a C compiler (`cc`) for the same probe program, but no package manager: this action shells out to `brew` itself rather than assuming one is already configured. `apt-get` is a Linux-only package manager and plays no role here. `pocl-source: conda-forge`, which is what `auto` resolves to, needs no `brew` at all — it downloads micromamba and builds its own environment — but it does use `otool`, `install_name_tool`, and `codesign`, which arrive with the same Xcode Command Line Tools that provide `cc`. A missing one fails with an `::error::` naming it.
- **Windows** needs neither in order to install or to report a device: it enumerates with `clinfo.exe` from the installed SDK, and `install-windows.ps1` never invokes a C compiler or a package manager. The `kernel` output alone needs a compiler, because no `clinfo` can run a kernel for you. GitHub's `windows-*` images ship mingw `gcc` on `PATH`, so this is satisfied out of the box; on a runner without `gcc`, `clang`, or `cc`, the action warns and reports `kernel=false` rather than failing — the other four probe outputs are unaffected.

A C compiler and `apt-get` are preinstalled on every GitHub-hosted `ubuntu-*` runner image; a C compiler (the Xcode Command Line Tools) is preinstalled on every `macos-*` image. Neither is guaranteed inside a `container:` job, which is common for C++ and R projects and still runs on a GitHub-hosted runner — but Actions' `container:` jobs run on Linux hosts only, so this caveat applies to Linux images, never macOS (`xcode-select --install` has no `container:`-job scenario to remediate). Use a Debian-family container image (e.g. `ubuntu:24.04`) with a C compiler installed — `build-essential` — or install one yourself before this step. Missing either fails the job with an `::error::` and remediation, not a bare `command not found`.

## Supported runners

| Runner | Runtime | Support |
|---|---|---|
| `ubuntu-24.04`, `ubuntu-24.04-arm` | PoCL | Tested on every push and pull request |
| `macos-latest` | PoCL (conda-forge) | Tested on every push and pull request. `pocl-source: homebrew` is tested nightly |
| `windows-2025`, `windows-2022` | Intel CPU runtime | Tested on every push and pull request |
| `ubuntu-26.04`, `ubuntu-26.04-arm` | PoCL | Tested nightly, best effort |
| `ubuntu-22.04` | PoCL | Tested nightly, best effort. Reports OpenCL 1.2 (jammy ships PoCL 1.8 built against LLVM 11) |
| `macos-15-intel` | PoCL (conda-forge) | Tested nightly, best effort, both `pocl-source` values |
| `ubuntu-latest`, `macos-latest`, `windows-latest` (floating labels) | whichever runtime `auto` resolves to on that image | Tested nightly, best effort. These labels move to a new underlying image without notice |
| `windows-11-arm` | none available | Not supported. The action fails fast: no OpenCL CPU runtime exists for Windows on ARM64 |

`runtime: pocl` and `runtime: apple` are rejected on Windows; `runtime: intel` is rejected on Linux and macOS.

On Windows, `windows-2025` and `windows-2022` report `platform-version=OpenCL 3.0 WINDOWS` and `fp64=true`. `kernel` is a separate question there: Intel's `oclcpuexp` has shipped generations whose kernel compiler crashes on every build it is given while still enumerating that same healthy-looking device, so this action's own CI measures `kernel` on Windows nightly rather than asserting it on every pull request — a defect in a third-party runtime is not a defect in this action. If you hit it, `version` (with `version-sha256` where the older asset reports no digest) is how you pin a generation that works.

## PoCL on macOS

This action installs PoCL and the Khronos ICD loader on macOS rather than using Apple's `OpenCL.framework`. Homebrew's `opencl-icd-loader` and `opencl-headers` formulae are keg-only and shadowed by macOS, so code that hardcodes `-framework OpenCL` or a bare `-lOpenCL` silently keeps using Apple's framework and never sees PoCL. Use the exported `OPENCL_CPPFLAGS` and `OPENCL_LIBS` instead of hardcoding link flags.

There are two PoCLs to choose between, and the difference is which LLVM each is built against:

| `pocl-source` | PoCL | LLVM | Notes |
|---|---|---|---|
| `conda-forge` | conda-forge `pocl=7.1`, installed with micromamba into `$RUNNER_TEMP` | LLVM 19.1.7 | What `auto` resolves to. About 90 MB of downloads on a cold cache. |
| `homebrew` | Homebrew's `pocl` formula | `llvm@21` (21.1.8) | Faster on a cold cache. Warned about on every run. |

LLVM 21's Clang miscompiles the kernel stubs it generates for OpenCL — [llvm#161077](https://github.com/llvm/llvm-project/issues/161077), fixed in LLVM 22 and never backported to the 21.1.x line. The result is a runtime that enumerates a healthy, double-precision-capable CPU device and then dies inside real kernels. Measured on Apple silicon against a GPU linear-algebra package's suite: three separate operations exited 139 on Homebrew's PoCL and passed on conda-forge's, with nothing changed between the two runs but `OCL_ICD_VENDORS`. This is not a novel diagnosis — PoCL's own README marks its CUDA backend broken on LLVM 21, and Arch pins `pocl` to `clang20`.

So the action emits a `::warning::` naming the defect whenever it installs Homebrew's PoCL, and both install paths log the LLVM version the installed PoCL actually links so the claim can be checked against the run rather than taken on faith.

**`auto` resolving to `conda-forge` is a behaviour change for existing `@v1` consumers.** `homebrew` was the default only so that this input's arrival changed nothing for anybody, and it is the option known to be broken. What changed is the evidence, not the diagnosis: the conda-forge path had until now only ever run on developer hardware with a full Xcode and twelve cores. It has since gone green on hosted `macos-latest` (arm64) and `macos-15-intel` with `require-kernel: 'true'` — which asserts a kernel builds, launches and returns the right numbers, not merely that a device enumerates — and on a real R package's test suite, where it took macOS from six of ten test scripts segfaulting to none.

It is not free. The conda-forge environment is about 90 MB of downloads plus a solve, where `brew install pocl` is neither, so the **first** run of a job with no cache entry is slower than it used to be. Later runs restore it under `cache: 'true'`, like the Windows runtime — but note what that stores: the restored environment is roughly **413 MB** in your repository's Actions cache, against a 10 GB quota with least-recently-used eviction, so on a cache-heavy repository it can push other entries out. A further ~500 MB of micromamba package cache lands in `RUNNER_TEMP`, outside the cached path, and is discarded with the runner. A job that never compiles an OpenCL kernel — one that needs headers, a loader and a device that enumerates — can set `pocl-source: homebrew` and get exactly the old behaviour back, warning included.

The conda-forge environment is self-contained: headers, the Khronos ICD loader, PoCL, and its `.icd` all live under one prefix in `$RUNNER_TEMP`, nothing is installed system-wide, and `pocl=7.1` is pinned rather than floated, because the LLVM generation is a transitive dependency that a floating version would eventually move.

`opencl-library` points at the environment's own `libOpenCL.dylib` in either case, and its install name is absolute in either case — Homebrew's keg already is, and the conda-forge one is rewritten to be, because conda ships `@rpath` install names and nothing downstream of this action carries an rpath. That matters for anything that links the loader by absolute path, such as the companion `setup-clblast` action building CLBlast from source.

## Versioning

Pin the action by major version (`@v1`) for painless upgrades, by full tag (`@v1.0.0`) for strict reproducibility, or by SHA for the strictest pin.

## License

AGPL-3.0. See `LICENSE`.
