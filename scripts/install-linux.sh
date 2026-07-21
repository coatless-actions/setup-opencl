#!/usr/bin/env bash
#
# Install OpenCL headers, the ocl-icd loader, and the PoCL CPU runtime on
# Debian-family Linux, then print the resulting paths as key=value lines.
#
# Packages are installed by name and never version-pinned. This keeps the
# action roll-forward safe: when ubuntu-latest moves from 24.04 to 26.04,
# PoCL goes 5.0 -> 6.0 and its LLVM dependency 16 -> 18, and apt resolves
# that without any change here. Only the install duration changes.
#
# ICD selection uses OCL_ICD_VENDORS, never OCL_ICD_FILENAMES. The latter is
# a Khronos-loader variable that ocl-icd added only in 2.3.5; every Ubuntu
# release through 26.04 ships an older ocl-icd (jammy 2.2.14, noble 2.3.2,
# questing 2.3.3, resolute 2.3.4).

set -euo pipefail

# This script assumes a Debian-family image (apt-get, dpkg-architecture). A
# `container:` job -- common for C++ and R projects, and still a
# GitHub-hosted runner -- may use a non-Debian base, where this would
# otherwise fail with a bare "apt-get: command not found" from the first
# apt-get invocation below.
#
# Written to stderr, not stdout: action.yml's "Install OpenCL" step captures
# this script's whole stdout via `output="$(bash ... "${script}")"` and only
# prints it back out (and thus into the job log) after that command
# substitution succeeds. Under `set -e`, a non-zero exit here aborts that
# step immediately, before the capture is ever replayed -- so a stdout-only
# message would reach neither the log nor an annotation, silently, on
# exactly the failure path it exists to report loudly.
if ! command -v apt-get >/dev/null 2>&1; then
    echo "::error::apt-get not found" >&2
    echo "This install script supports Debian-family Linux images only. Use a Debian-family base image (e.g. 'ubuntu:24.04') for 'container:' jobs, or install OpenCL headers, an ICD loader, and a CPU runtime yourself before this step." >&2
    exit 1
fi

runtime="${SE_RUNTIME:-pocl}"

emit() { printf '%s=%s\n' "$1" "$2"; }

packages="opencl-headers ocl-icd-opencl-dev"
if [ "${runtime}" != "none" ]; then
    packages="${packages} pocl-opencl-icd"
fi

sudo_cmd=""
[ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"

# DEBIAN_FRONTEND keeps tzdata and friends from blocking on a prompt. It is
# passed through `env` after sudo_cmd, not set on this process, because
# Ubuntu's default sudoers uses env_reset and does not env_keep it: setting
# it here would only affect the caller's environment and never reach
# apt-get, silently defeating the suppression.
# shellcheck disable=SC2086
${sudo_cmd} env DEBIAN_FRONTEND=noninteractive apt-get update -qq
# shellcheck disable=SC2086
${sudo_cmd} env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    --no-install-recommends ${packages}

# ocl-icd ships the loader under the multiarch triplet directory. Resolve it
# rather than hardcoding, so this works on amd64 and arm64 alike.
multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo '')"
loader="/usr/lib/${multiarch}/libOpenCL.so"
[ -e "${loader}" ] || loader="$(find /usr/lib -name 'libOpenCL.so' -print -quit)"

emit opencl-root        "/usr"
emit opencl-include-dir "/usr/include"
emit opencl-library     "${loader}"
emit opencl-cppflags    "-I/usr/include"
emit opencl-libs        "-lOpenCL"

if [ "${runtime}" = "none" ]; then
    emit icd-vendors-path ""
    emit runtime-name     "none"
else
    # Point at the single .icd rather than the directory, so a stray vendor
    # ICD installed by something else cannot double-enumerate.
    emit icd-vendors-path "/etc/OpenCL/vendors/pocl.icd"
    emit runtime-name     "pocl"
fi
