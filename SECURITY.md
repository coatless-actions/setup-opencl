# Security Policy

## Why this matters here

This action downloads third-party archives (an OpenCL SDK and, on Windows, a
CPU runtime), registers a vendor ICD loader entry under `HKLM` on Windows,
and modifies `PATH` and other job-environment variables. A flaw in the
digest pins, the download URLs, the registry write, or the
environment-export logic could let a workflow run untrusted code or link
against a tampered binary.

Verification is not uniform across every path, and it is worth being
precise about that:

- **Pinned default** (no `version:` input): each archive is verified
  against a SHA-256 digest fixed in this action's source and refreshed by
  its own update automation. This is the strongest guarantee -- a true pin,
  independent of the download itself.
- **Cache hit**: nothing is downloaded and nothing is re-hashed. Integrity
  instead comes from the cache key's binding to the installer script's
  hash and the resolved version, not from a digest check.
- **`version:` override**: the digest is resolved from the same GitHub
  Releases API response used to resolve the download itself, moments
  before the bytes are fetched from that same origin -- a transport check,
  not a pin against a value fixed in advance. If the API reports no digest
  for the resolved asset, the download is refused outright rather than
  proceeding unverified.

## Supported versions

Security fixes are made to the latest tagged major version (`v1`) only. A
workflow pinned to `@v1` picks up a fix on its next run; a workflow pinned to
a specific `@v1.x.y` tag or commit SHA needs to be re-pinned manually.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Report it privately by emailing james.balamuta@gmail.com with a description
of the issue and, if possible, steps to reproduce it. Expect an
acknowledgment within a few days.
