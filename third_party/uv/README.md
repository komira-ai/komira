# uv: the pin

The `uv publish` that kci_pkg_upload's fidelity fixtures are measured
against ([src/kci_pkg_upload/tests/fidelity](../../src/kci_pkg_upload/tests/fidelity/README.md)).
Test tooling only: nothing ships it, and only `komira//src/kci_pkg_upload`
may name the binary (the visibility of `:uv_dist`).

| target | what |
|---|---|
| `:uv-x86_64-unknown-linux-musl.tar.gz` | the release archive, pinned by sha256 and size (`pinned_file`): on a remote-cache hit nothing is fetched |
| `:uv_dist` | the archive's `uv` (mode 0755), unpacked by `archive_files`; `:uv_dist[uv]` is the executable |
| `:LICENSE-MIT`, `:LICENSE-APACHE` | uv's two licenses (it is dual licensed), the files of the repository at the release tag's commit, pinned by commit (the archive holds no license text) |

## The pin

| | |
|---|---|
| version | 0.12.21 |
| source | `https://github.com/astral-sh/uv/releases/download/0.12.21/uv-x86_64-unknown-linux-musl.tar.gz` |
| sha256 | the one the release's `uv-x86_64-unknown-linux-musl.tar.gz.sha256` states, which the downloaded archive matched |
| license | MIT or Apache-2.0, from `https://raw.githubusercontent.com/astral-sh/uv/<commit>/LICENSE-MIT` and `LICENSE-APACHE`, the commit the `0.12.21` tag names |

The binary is the musl build, linked static-pie: it needs no loader and no
shared library, so it runs on every Linux x86_64 worker. Linux x86_64 only:
the capture runs on that execution platform alone.

## Bumping it

1. In [`BUCK`](BUCK): `_VERSION`; `_COMMIT`, the commit the new tag names
   (`gh api repos/astral-sh/uv/git/ref/tags/<version>`); `_SHA256` (from the
   release's `.sha256` file, checked against the download) and `_SIZE` of
   the archive; the sha256 and size of both LICENSE files at that commit.
2. Build `komira//src/kci_pkg_upload:uv_fidelity_check` with
   `-c komira.uv_fidelity=true`. A new uv may send different bytes: the
   check names each file that differs and the first differing byte. Read
   what changed before refreshing the fixtures (the fidelity README), since
   the Mojo client must then change to match.
