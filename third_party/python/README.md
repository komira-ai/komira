# Hermetic Python: the pins

The interpreter and the wheels of the tests' hermetic Python
([tools/build/python](../../tools/build/python/README.md)), each pinned by
sha256 and size in [`pins.bzl`](pins.bzl) and fetched like every other
pinned download (`pinned_file`): on a remote-cache hit, nothing is fetched.
No source distribution is built and pip never runs.

| target | what |
|---|---|
| `:cpython` | CPython 3.13.16, python-build-standalone release 20261003, `x86_64-unknown-linux-gnu-install_only_stripped` |
| `:native_libs` | `libgcc_s.so.1`, `libstdc++.so.6` (GCC 15.3) and `libz.so.1` (zlib 1.3.1), unpacked from the conda-forge packages the [platform table](../../tools/build/platforms/table.bzl) pins for the toolchains; `py_test` loads them before a script runs |
| `:<distribution>` | one wheel installed, e.g. `:pyarrow`; its `deps` are the distributions it requires on linux |

## The closure

| distribution | version | requires | for |
|---|---|---|---|
| pyarrow | 25.0.1 | | live oracle (Arrow IPC, Parquet), Arrow Flight interop |
| duckdb | 1.5.6 | | live oracle (SQL) |
| numpy | 2.5.3 | | pandas, and array oracles |
| pandas | 3.0.6 | numpy, python-dateutil | dataframe oracles |
| python-dateutil | 2.9.0.post0 | six | pandas |
| six | 1.17.0 | | python-dateutil |
| polars | 1.44.2 | polars-runtime-32 | dataframe oracles |
| polars-runtime-32 | 1.44.2 | | polars (its compiled engine) |
| protobuf | 7.36.2 | | protobuf interop |
| grpcio | 1.84.0 | typing-extensions | gRPC interop |
| typing-extensions | 4.16.0 | | grpcio |
| tzdata | 2026.5 | | the time-zone database of every `py_test` and `python_oracle` (IANA 2026e) |

polars is pinned at 1.44.2, the version komira's Python surface implements;
moving to polars 2 is a later change. pandas 3.0.6 is the version the
surface implements.

tzdata is in every `py_test`'s and `python_oracle`'s closure whether or not
its `deps` name it: its `tzdata/zoneinfo` directory is the action's `TZDIR`
and Python's only zone path ([tools/build/python](../../tools/build/python/README.md#time-zones)),
so a zone is never read from the worker.

protobuf 7.36.2 loads the Python gencode of the repository's protoc (29.1,
which writes gencode 5.29.1): its runtime check refuses only gencode newer
than the runtime (or of another domain), not an older major. The test
`protobuf_gencode` (`src/tests/helpers/komira_test_python`) imports a module
protoc 29.1 generated and parses with it; with protobuf 5.28.3 pinned instead
it fails with `VersionError: Detected incompatible Protobuf Gencode/Runtime
versions when loading gencode_probe.proto: gencode 5.29.1 runtime 5.28.3`.
A bump of either pin re-runs it.

Not in the closure yet, each for the change that brings its consumer: the
Google Cloud Storage testbench, kafka-python and opensearch-py (service
drivers), and anything they require.

## Licences

| component | licence (SPDX) | bundled |
|---|---|---|
| CPython (python-build-standalone) | PSF-2.0 | the libraries python-build-standalone links in (OpenSSL, libffi, SQLite and others), under the licences its documentation lists; it builds with libedit instead of GNU readline and without the `_gdbm` module so that no GPL library is linked. The archive carries CPython's `LICENSE.txt` only |
| pyarrow | Apache-2.0 | Arrow C++ and its dependencies, under the licences its `LICENSE.txt` lists (Apache-2.0, MIT, BSD-2-Clause, BSD-3-Clause, BSL-1.0, Zlib, public domain) and a `NOTICE.txt` |
| duckdb | MIT | `duckdb/experimental/spark` carries the Apache-2.0 text; the wheel's licence file lists nothing else |
| numpy | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 | OpenBLAS (BSD-3-Clause), and two GCC runtime libraries: libgfortran (GPL-3.0-or-later WITH GCC-exception-3.1) and libquadmath (LGPL-2.1-or-later) |
| pandas | BSD-3-Clause | its licence file adds those of the code it carries (MIT, BSD, Apache-2.0, and the PSF licence) |
| python-dateutil | Apache-2.0 AND BSD-3-Clause | |
| six | MIT | |
| polars, polars-runtime-32 | MIT | |
| protobuf | BSD-3-Clause | |
| grpcio | Apache-2.0 | its licence file adds BSD-3-Clause (build files) and MPL-2.0 (`etc/roots.pem`, the root certificates) |
| typing-extensions | PSF-2.0 | |
| tzdata | Apache-2.0 | the IANA time-zone database, which is in the public domain |
| libgcc_s, libstdc++ | GPL-3.0-or-later WITH GCC-exception-3.1 | |
| zlib | Zlib | |

None is the AGPL. The GNU-licensed code is GCC's runtime libraries.
libgcc_s, libstdc++ and numpy's libgfortran are GPL-3.0-or-later WITH
GCC-exception-3.1, the GCC Runtime Library Exception, which komira's own
toolchains already use for libgcc_s and libstdc++
([toolchains](../../tools/build/toolchains/README.md)). numpy's libquadmath is
LGPL-2.1-or-later with no exception. libgfortran and libquadmath ship only
inside the numpy wheel, which is test-only: its visibility (`_TEST_ONLY` in
[`BUCK`](BUCK)) keeps it out of every shipped package
([Never shipped](#never-shipped)).

The test [`licenses`](../../src/tests/helpers/komira_test_python/README.md)
holds this table to the files: each installed distribution must be pinned,
a `License-Expression` in its METADATA must equal the pin's `license`, no
licence file may be the AGPL, and every licence file that names a GNU
licence, and every bundled libgfortran, libquadmath, libreadline or libgdbm,
must be one of the reviewed entries in its BUCK file, which say why each is
there. A new wheel, or a new version, that brings another such file fails
the test until it is reviewed.

## Never shipped

The hermetic Python is for tests. What keeps it out of every published
package:

- **Visibility.** `:cpython` and every wheel are visible only to the
  packages `_TEST_ONLY` in [`BUCK`](BUCK) lists, all test-only: packages under
  `src/tests` (`//:src_layout` holds that directory to test-only packages),
  and `release/ci/tests`, which holds only the `py_test` of the CI scripts. A
  `mojo_bundle`, `conda_package` or any other target elsewhere that names one
  fails analysis with a visibility error.
- **What a test hands on.** A `py_test`'s only output is its pass marker:
  it provides no wheel, interpreter or library to a target depending on it.
- **What a package holds.** A `conda_package` holds only a `.mojoc` and a
  README (`komira_pack conda-check`,
  [package/README.md](../../tools/build/package/README.md)), which no Python
  file can become.
