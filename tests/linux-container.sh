#!/usr/bin/env bash
#
# Runs the Linux install script and the probe inside a container, so the
# Linux path can be exercised without pushing to CI.
#
# Usage: tests/linux-container.sh [image] [platform] [runtime]
#   image    defaults to ubuntu:24.04
#   platform passed to --platform when non-empty, e.g. linux/amd64
#   runtime  defaults to pocl; the other documented value is none
#
# Note: containers lack the runner image's preinstalled clang, so PoCL pulls
# LLVM here. That makes this a conservative test -- slower than CI, never
# faster.

set -euo pipefail

image="${1:-ubuntu:24.04}"
platform="${2:-}"
runtime="${3:-pocl}"

expectation=">=1"
[ "${runtime}" = "none" ] && expectation="=0"

engine="docker"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || engine="podman"

platform_args=()
[ -n "${platform}" ] && platform_args=(--platform "${platform}")

"${engine}" run --rm ${platform_args[@]+"${platform_args[@]}"} \
    -v "$(pwd):/work:ro" -w /work \
    -e SE_RUNTIME="${runtime}" \
    "${image}" bash -c '
        set -euo pipefail
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends build-essential >/dev/null
        out="$(bash scripts/install-linux.sh)"
        printf "%s\n" "${out}"
        export OPENCL_CPPFLAGS="$(printf "%s\n" "${out}" | sed -n "s/^opencl-cppflags=//p")"
        export OPENCL_LIBS="$(printf "%s\n" "${out}" | sed -n "s/^opencl-libs=//p")"
        export OCL_ICD_VENDORS="$(printf "%s\n" "${out}" | sed -n "s/^icd-vendors-path=//p")"
        cd /tmp && cp -r /work/tests .
        mkdir -p scripts && cp /work/scripts/probe.c scripts/
        tests/probe-contract.sh '"${expectation}"'
    '
