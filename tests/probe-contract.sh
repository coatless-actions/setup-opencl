#!/usr/bin/env bash
#
# Asserts the probe's output contract: four keys, always exit 0, and a device
# count that is a non-negative integer. Run from the repository root.
#
# Usage: tests/probe-contract.sh [expected-min-devices]
#   expected-min-devices defaults to 1. Pass 0 to assert only the contract.

set -uo pipefail

expected_min="${1:-1}"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cc -o "${workdir}/probe" scripts/probe.c ${OPENCL_CPPFLAGS:-} ${OPENCL_LIBS:-} \
    || fail "probe.c did not compile"

output="$("${workdir}/probe")"
status=$?

[ "${status}" -eq 0 ] || fail "probe exited ${status}, expected 0"

for key in device-count device-name platform-version fp64; do
    printf '%s\n' "${output}" | grep -q "^${key}=" \
        || fail "missing key '${key}' in output:
${output}"
done

count="$(printf '%s\n' "${output}" | sed -n 's/^device-count=//p')"
case "${count}" in
    ''|*[!0-9]*) fail "device-count '${count}' is not a non-negative integer" ;;
esac

fp64="$(printf '%s\n' "${output}" | sed -n 's/^fp64=//p')"
case "${fp64}" in
    true|false) ;;
    *) fail "fp64 '${fp64}' is not 'true' or 'false'" ;;
esac

[ "${count}" -ge "${expected_min}" ] \
    || fail "device-count ${count} is below expected minimum ${expected_min}
${output}"

printf 'PASS: %s\n' "$(printf '%s\n' "${output}" | tr '\n' ' ')"
