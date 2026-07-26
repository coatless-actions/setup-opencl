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
- **conda-forge PoCL on macOS** (the default there since v1.3.0): the
  micromamba binary itself IS pinned -- a SHA-256 fixed in this action's
  source, checked before it is ever executed. The packages it then installs
  are NOT individually pinned here. `pocl` is constrained to an exact minor
  version, but the solve runs live against conda-forge and there is no
  lockfile and no per-package digest in this repository, so integrity for
  those rests on conda-forge's repodata over TLS -- a transport check, the
  same tier as the `version:` case below rather than the pinned-default one
  above. Roughly 90 MB is downloaded and about 413 MB lands in the caller's
  Actions cache. `pocl-source: homebrew` avoids all of it and takes
  Homebrew's trust model instead, at the cost of a PoCL built against an
  LLVM that miscompiles OpenCL kernels.
- **Cache hit**: nothing is downloaded and nothing is re-hashed. Integrity
  instead comes from the cache key's binding to the installer script's
  hash and the resolved version, not from a digest check.
- **`version:` override**: the digest is resolved from the same GitHub
  Releases API response used to resolve the download itself, moments
  before the bytes are fetched from that same origin -- a transport check,
  not a pin against a value fixed in advance. If the API reports no digest
  for the resolved asset, the download is refused outright rather than
  proceeding unverified.
- **`version-sha256:` override**: the caller states the digest they expect
  for the asset `version:` selects, and the download is verified against
  that. This is a stronger guarantee than the API-reported digest above --
  the value is fixed in the workflow ahead of time rather than fetched
  alongside the download -- but only as strong as the caller's own
  out-of-band check that the digest describes the file they intend. When
  the API reports a digest too, the two must agree or the run fails and
  installs nothing; the action never picks a winner. No combination of
  inputs downloads an archive without a digest check. The cache-hit
  exemption noted above still applies -- nothing is downloaded, so nothing
  is re-hashed -- but the expected digest is part of the cache key, so an
  archive cached under one expectation can never satisfy a different one.

## Supported versions

Security fixes are made to the latest tagged major version (`v1`) only. A
workflow pinned to `@v1` picks up a fix on its next run; a workflow pinned to
a specific `@v1.x.y` tag or commit SHA needs to be re-pinned manually.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Report it privately by emailing james.balamuta@gmail.com with a description
of the issue and, if possible, steps to reproduce it. Expect an
acknowledgment within a few days.
