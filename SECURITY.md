# Security policy

## Reporting a vulnerability

Please report a vulnerability privately, through GitHub's private
vulnerability reporting: the **Report a vulnerability** button on this
repository's [Security tab](https://github.com/komira-ai/komira/security).
Do not open a public issue, pull request or discussion about it.

Include what you can of: the affected library or tool, the version or commit,
how to reproduce it, and what an attacker gains. We aim to acknowledge a report
within three working days, and to agree a disclosure date with you once a fix
is understood.

## What is in scope

The libraries under `src/`, the build rules and tools under `tools/`, the
release tooling under `release/`, and the packages published from this
repository. A problem in a dependency that komira vendors or pins (for example
under `third_party/`) is in scope when komira's use of it is affected; please
also report it to that project.

## Supported versions

Fixes go to `main` and to the next published release. komira does not maintain
older release lines yet.
