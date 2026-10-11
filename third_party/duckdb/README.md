# DuckDB CLI: the pin

The SQL engine of `sql_oracle` ([tools/build/sql](../../tools/build/sql/README.md)),
which runs this binary as a build action. Test data only: nothing ships it,
and only the test-only packages (`komira//src/tests/...`) and the rule's own
tests may declare a `sql_oracle` (the visibility of `:duckdb`).

| target | what |
|---|---|
| `:duckdb_cli-linux-amd64.zip` | the release archive, pinned by sha256 and size (`pinned_file`): on a remote-cache hit nothing is fetched |
| `:duckdb_cli` | the archive's one file, `duckdb` (mode 0755), unpacked by `archive_files`; `:duckdb_cli[duckdb]` is the binary |
| `:native_libs` | `libgcc_s.so.1` and `libstdc++.so.6` (GCC 15.3), unpacked from the conda-forge packages the [platform table](../../tools/build/platforms/table.bzl) pins for the toolchains; every `sql_oracle` action names their directory in `LD_LIBRARY_PATH` |
| `:duckdb` | `duckdb_dist`: the binary, `:native_libs` and the version, `sql_oracle`'s default |
| `:LICENSE` | DuckDB's MIT license, the `LICENSE` of the repository at the release tag's commit, pinned by commit (the archive holds no license text) |

## The pin

| | |
|---|---|
| version | 1.5.6, the version the oracle datasets were generated with |
| source | `https://github.com/duckdb/duckdb/releases/download/v1.5.6/duckdb_cli-linux-amd64.zip` |
| sha256 | the archive's, as downloaded twice from that URL (the release publishes no checksum file) |
| license | MIT, from `https://raw.githubusercontent.com/duckdb/duckdb/<commit>/LICENSE`, the commit the `v1.5.6` tag names |

The binary is the glibc build: it links `libstdc++.so.6` and `libgcc_s.so.1`
(from `:native_libs`) and glibc (2.25 symbol versions or older, under the
host floor, [toolchains](../../tools/build/toolchains/README.md#host-floor)).
The release's `-musl` build needs the musl loader, which no worker has. The
CLI has Parquet, CSV and ICU (the time zones) built in: the fixtures read
and write them with no extension loading; `sql_oracle`
loads and installs no other extension.

Linux x86_64 only. The release also publishes `duckdb_cli-osx-arm64.zip`;
it is not pinned: no macOS worker runs a `sql_oracle` action (the macro
places every one on the linux x86_64 execution platform).

## Bumping it

1. In [`BUCK`](BUCK): `_VERSION`; `_COMMIT`, the commit the new tag names
   (`gh api repos/duckdb/duckdb/git/ref/tags/v<version>`); `_SHA256` and
   `_SIZE` of `duckdb_cli-linux-amd64.zip`, downloaded twice from the new
   release URL; `_LICENSE_SHA256` and `_LICENSE_SIZE` of the `LICENSE` at
   that commit.
2. `sql_oracle` refuses a binary that reports another version than
   `_VERSION`, so a stale `_VERSION` fails every oracle.
3. Build `tests//functional/sql_oracle:check`: its CSV and TSV goldens show
   a change in how the new release writes them (a Parquet file also names
   the writer's version, so its bytes change on every bump). Then rebuild
   every `sql_oracle` and review what changed in the data built from it.
