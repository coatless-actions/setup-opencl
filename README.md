# Setup OpenCL

[![Test](https://github.com/coatless-actions/setup-opencl/actions/workflows/test.yml/badge.svg)](https://github.com/coatless-actions/setup-opencl/actions/workflows/test.yml)

Install OpenCL headers, an ICD loader, and a working CPU device on GitHub-hosted runners.

Installing headers and a loader is one package-manager line per platform. Producing a runner where an OpenCL kernel actually executes is harder, and getting it wrong is quiet: a job that compiles and links against OpenCL but enumerates zero devices passes its test suite without running a single kernel. This action installs a real CPU device, registers it with the loader, and fails the job when no device is found, unless you explicitly ask for headers only.

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
| `version` | Pin the runtime version. Only honored for `runtime: intel` on Windows, where it takes an `intel/llvm` release tag (e.g. `2026-WW22`). Ignored, with a warning, for every other runtime. Verified against the digest the GitHub API reports for that release at resolution time, not a pinned one, and the job fails if the API reports none. | `''` |
| `verify` | Fail the job when no OpenCL device is found (`'true'` or `'false'`). Never fatal when `runtime` is `none`. | `true` |
| `require-fp64` | Also fail when the device does not support double precision (`'true'` or `'false'`). | `false` |
| `cache` | Cache downloads and package archives (`'true'` or `'false'`). A no-op on runners with nothing worth caching. | `true` |

`runtime`, `verify`, `require-fp64`, and `cache` are validated by hand, since the runner enforces neither input types nor allowed values. An **empty string** (for example `verify: ''`, which is what an absent key in a build matrix expands to) is rejected rather than falling back to the default above — the action cannot distinguish "omitted" from "explicitly empty." Leave the input out of `with:` entirely to get the default, or interpolate a matrix value that is guaranteed to be `'true'`/`'false'` on every leg.

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

The action also exports `OPENCL_CPPFLAGS`, `OPENCL_LIBS`, `OpenCL_ROOT`, `OpenCL_LIBRARY`, and `OpenCL_INCLUDE_DIR` to the job environment, plus `OCL_ICD_VENDORS` on Linux and macOS (when a vendor ICD was installed), `OCL_ICD_FILENAMES` on Windows, and `SDKROOT` on macOS. On Windows, the loader's `bin` directory (containing `clinfo.exe` and the loader DLL) is also prepended to `PATH`. A caller's own explicit setting of any of these always wins over the action's.

`icd-vendors-path` means three different things depending on the platform: a **file** on Linux (the single `.icd` under `/etc/OpenCL/vendors`), a **directory** on macOS (PoCL's keg-relative vendors directory), and a **vendor DLL path** on Windows (the value passed to `OCL_ICD_FILENAMES` and written to the registry). Each is correct for its own loader, but none of them is a portable value: a workflow that does, say, `export OCL_ICD_VENDORS=${{ steps.opencl.outputs.icd-vendors-path }}` to work identically across platforms will get three different semantics, and on Windows that variable is the wrong one entirely. Do not wire this output up yourself — the action already exports the loader-correct environment variable for the current platform (`OCL_ICD_VENDORS` on Linux and macOS, `OCL_ICD_FILENAMES` on Windows), and that is what a cross-platform consumer should rely on. `icd-vendors-path` exists for diagnostics (what did the action actually point the loader at?) and for cache keys, not for consumers to depend on directly.

## Examples

### Require double precision

    - uses: coatless-actions/setup-opencl@v1
      with:
        require-fp64: 'true'

### Headers and loader only, no device

    - uses: coatless-actions/setup-opencl@v1
      with:
        runtime: none

### Branch on the device that was found

    - uses: coatless-actions/setup-opencl@v1
      id: opencl
    - if: steps.opencl.outputs.fp64 == 'true'
      run: ./run-double-precision-tests

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

## Requirements

This action assumes a C compiler is on `PATH`: it compiles a small probe program to check for a device, even when `runtime` is `none` and `verify` is `'false'`. On Linux, it also assumes a Debian-family package manager (`apt-get`). Both are preinstalled on every GitHub-hosted `ubuntu-*`, `macos-*`, and `windows-*` runner image, but neither is guaranteed inside a `container:` job, which is common for C++ and R projects and still runs on a GitHub-hosted runner. Use a Debian-family container image (e.g. `ubuntu:24.04`) with a C compiler installed — `build-essential` on Debian-family Linux, the Xcode Command Line Tools (`xcode-select --install`) on macOS — or install one yourself before this step. Missing either fails the job with an `::error::` and remediation, not a bare `command not found`.

## Supported runners

| Runner | Runtime | Support |
|---|---|---|
| `ubuntu-24.04`, `ubuntu-24.04-arm` | PoCL | Tested on every push and pull request |
| `macos-latest` | PoCL | Tested on every push and pull request |
| `windows-2025`, `windows-2022` | Intel CPU runtime | Tested on every push and pull request |
| `ubuntu-26.04`, `ubuntu-26.04-arm` | PoCL | Tested nightly, best effort |
| `ubuntu-22.04` | PoCL | Tested nightly, best effort. Reports OpenCL 1.2 (jammy ships PoCL 1.8 built against LLVM 11) |
| `macos-15-intel` | PoCL | Tested nightly, best effort |
| `ubuntu-latest`, `macos-latest`, `windows-latest` (floating labels) | whichever runtime `auto` resolves to on that image | Tested nightly, best effort. These labels move to a new underlying image without notice |
| `windows-11-arm` | none available | Not supported. The action fails fast: no OpenCL CPU runtime exists for Windows on ARM64 |

`runtime: pocl` and `runtime: apple` are rejected on Windows; `runtime: intel` is rejected on Linux and macOS.

On Windows, `windows-2025` and `windows-2022` report `platform-version=OpenCL 3.0 WINDOWS` and `fp64=true`.

On macOS, this action installs PoCL and the Khronos ICD loader by default rather than using Apple's `OpenCL.framework`. Homebrew's `opencl-icd-loader` and `opencl-headers` formulae are keg-only and shadowed by macOS, so code that hardcodes `-framework OpenCL` or a bare `-lOpenCL` silently keeps using Apple's framework and never sees PoCL. Use the exported `OPENCL_CPPFLAGS` and `OPENCL_LIBS` instead of hardcoding link flags.

## Versioning

Pin the action by major version (`@v1`) for painless upgrades, by full tag (`@v1.0.0`) for strict reproducibility, or by SHA for the strictest pin.

## License

AGPL-3.0. See `LICENSE`.
