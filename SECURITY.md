# Security Policy

## Why this matters here

This action downloads third-party archives (an OpenCL SDK and, on Windows, a
CPU runtime), verifies each against a pinned SHA-256 digest before use,
registers a vendor ICD loader entry under `HKLM` on Windows, and modifies
`PATH` and other job-environment variables. A flaw in the digest pins, the
download URLs, the registry write, or the environment-export logic could let
a workflow run untrusted code or link against a tampered binary.

## Supported versions

Security fixes are made to the latest tagged major version (`v1`) only. A
workflow pinned to `@v1` picks up a fix on its next run; a workflow pinned to
a specific `@v1.x.y` tag or commit SHA needs to be re-pinned manually.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Report it privately by emailing james.balamuta@gmail.com with a description
of the issue and, if possible, steps to reproduce it. Expect an
acknowledgment within a few days.
