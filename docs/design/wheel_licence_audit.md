# Licence audit of the files the Python wheel carries

The wheel carries `libkomira`, the native owner libraries `libkomira`
links as `DT_NEEDED`, the three Mojo runtime libraries it needs, the Python
package, `py.typed` and six licence files (`LICENSE`, `NOTICE`,
`AWS_LC_LICENSE`, `S2N_TLS_LICENSE`, `MODULAR_LICENSE`,
`MODULAR_THIRD_PARTY_NOTICES`). This page lists every native file, the third-party code
inside each, its licence, and where `NOTICE` reproduces the notice that
licence requires. The file list is the measured table in
[src/so/README.md](../../src/so/README.md) ("What the library links and
weighs"), made by `//tools/build/package/libkomira:libkomira_elf_report` from
the built files; this page adds what each file contains.

## The native files

| file | third-party code inside | licence | required notice | `NOTICE` section |
|---|---|---|---|---|
| `libkomira.so` | none: komira's own Mojo, compiled by Modular's compiler | Apache-2.0 | none beyond `LICENSE` | (LICENSE) |
| `libkomira_async_rt_native.so.1` | none: komira's C | Apache-2.0 | none | (LICENSE) |
| `libkomira_async_api_native.so.1` | none: komira's C | Apache-2.0 | none | (LICENSE) |
| `libkomira_fs_native.so.1` | none: komira's C | Apache-2.0 | none | (LICENSE) |
| `libkomira_libc_native.so.1` | none: komira's C | Apache-2.0 | none | (LICENSE) |
| `libkomira_metrics_native.so.1` | none: komira's C | Apache-2.0 | none | (LICENSE) |
| `libkomira_objectstore_native.so.1` | none: komira's C | Apache-2.0 | none | (LICENSE) |
| `libkomira_scan_source_native.so.1` | none: komira's C | Apache-2.0 | none | (LICENSE) |
| `libkomira_compression_native.so.1` | snappy 1.3.1 (static); LLVM libc++ and libc++abi from the Zig toolchain (static, symbols local) | BSD-3-Clause; Apache-2.0 with LLVM exceptions | snappy: copyright notice, conditions and disclaimer reproduced for binary redistribution; libc++: none for object code (LLVM exception), recorded anyway | "Third-party code inside the native files" 1 and 3 |
| `libkomira_parquet_codec_native.so.1` | Brotli decoder 1.1.0 (static, names prefixed `komira_brotli_`) | MIT | copyright notice and permission notice reproduced | same section, 2 |
| `libkomira_crypto_native.so.1` | aws-lc 1.39.0 libcrypto (static, names prefixed `komira_awslc_`), with komira's SHA-256 C | Apache-2.0 OR ISC (AWS-LC's files); OpenSSL License and original SSLeay License, ISC, MIT, BSD-3-Clause (inherited parts, as its LICENSE states) | its NOTICE reproduced in `NOTICE`; its LICENSE (every notice, condition and disclaimer of those licences) carried unmodified as `.dist-info/licenses/AWS_LC_LICENSE` | same section, 4 |
| `libkomira_http_core_native.so.1` | s2n-tls 1.5.6 (static, names prefixed `komira_s2n_`); `DT_NEEDED` on the crypto owner above | Apache-2.0 | its NOTICE reproduced in `NOTICE`; its LICENSE carried unmodified as `.dist-info/licenses/S2N_TLS_LICENSE` | same section, 5 |
| `libKGENCompilerRTShared.so` | Modular's Mojo runtime: binary, unmodified from the pinned `mojo-compiler` conda package | Modular Community License Terms (`LicenseRef-Modular-Proprietary`) | the licence text displayed with the copies, which the wheel carries as `.dist-info/licenses/MODULAR_LICENSE`, and the package's `Third-Party-Notices` (`.dist-info/licenses/MODULAR_THIRD_PARTY_NOTICES`) | "The Mojo runtime: Modular's libraries, carried in the wheel" |
| `libAsyncRTRuntimeGlobals.so` | same | same | same | same |
| `libMSupportGlobals.so` | same | same | same | same |

Sources and pins: snappy `//third_party/snappy` (version and archive sha256
there), Brotli `//third_party/brotli`, aws-lc `//third_party/aws-lc`, s2n-tls
`//third_party/s2n-tls` (same). The archive's `COPYING` and
`LICENSE` are extracted unmodified as that target's files.

## What the wheel does not carry

- **The C++ runtime** the Mojo runtime libraries need (`libstdc++.so.6`,
  `libgcc_s.so.1`): not in the wheel, taken from the host. `NOTICE` says so.
  The wheel is tagged `manylinux_2_35` and the library checks bound the
  `GLIBCXX_` and `CXXABI_` versions the carried files need (3.4.30 and
  1.3.11).
- **System libraries** the loader takes from the host: `libc.so.6`,
  `libpthread.so.0`, `ld-linux-x86-64.so.2` (glibc; the wheel tag
  `manylinux_2_35` is its floor: `libAsyncRTRuntimeGlobals.so` needs
  `GLIBC_2.35`, one above the floor of komira's own files).
- **Codec libraries opened at run time**: `libz`, `liblz4`, `libzstd`,
  `libbz2`, `liblzma` are opened with `dlopen` by soname on first use of
  their codec (`src/compression/src/compression/codec_libraries.mojo` and the
  zlib and lz4 packages). They are not `DT_NEEDED`, not carried, and are
  the host's own files under their own licences; komira neither copies nor
  links them, so no notice of theirs is owed by the wheel.
  If one is absent, the first call of that codec aborts with
  `compression: cannot load <soname>`; other codecs and Parquet files that do
  not use it are unaffected.
- **The AWS, Google and Azure clients**: not in the wheel. The Mojo closure of
  the `so` package is `sdk_exec`'s (read from the `deps` of each `BUCK` file
  from `so` down): it holds `http_client`, `http_core`, `net`, `objectstore`,
  `iceberg_catalog` and `crypto`, and no `aws_*`, `gcp_*` or `azure_*`
  package. aws-lc and s2n-tls are carried, in the crypto and http_core owner
  libraries above (Linux; on macOS arm64 there are no owner libraries, and
  libkomira.dylib links the same archives statically, under the same
  notices). A
  change that adds a third-party library to the closure changes the table of
  `libkomira_elf_report` and must update this page and `NOTICE` in the same
  pull request.
- **Generated clients** (`NOTICE`, "Generated clients"): not in libkomira's
  closure, so no text derived from botocore or googleapis is in the wheel.

## Telemetry and network

Verified by reading, not by running anything on a developer machine:

- `libkomira`'s dynamic symbol table is exactly the twenty-seven `komira_*` exports
  (`exports_exact` gate in `src/so/tests/gate/`). None takes a URL, host or
  socket: they take a local file path, a worker count and memory budget, the bytes of a plan, SQL text, or a
  credential's kind, name and field values, a run handle, the bytes of a bound source, or an Arrow C stream the caller
  produced, and return bytes,
  text, an id, a run handle, two counts, an Arrow C stream or a status.
- The closure holds network code: `async_rt`'s reactor and socket primitives,
  `net`, `http_core` (HTTP and TLS) and `http_client`, which the engine uses
  to read object stores and to call an Iceberg REST catalog. Two exports of the
  twenty-seven reach it, and only for a table the caller bound to an object store:
  `komira_add_sql_binding`, given an `s3://` or `az://` location, reads the
  objects' footers from that store (and lists it for a glob), with the endpoint
  the caller passed and a credential the caller sealed; and `komira_sql_stream`
  and `komira_sql_stream_run` read such a table's objects through the same
  store (`so.store_fs`). A table bound to a local path, and every other export,
  opens no connection: `komira_ctx_new` and `komira_ctx_new_with_options`
  start the engine's worker threads and open nothing, and `komira_register_parquet` lists and reads local files
  only (`parquet_footers` reads through `LocalFs`), as do `komira_register_csv` and
  `komira_register_json`, which infer a local file's schema; the `COPY ... TO` of
  `komira_sql_stream` refuses a URL
  (`check_copy_target`); the run-handle calls (`komira_run_new`, `_free`, `_cancel`,
  `_progress`) touch only a cancel flag and two counters in memory; `komira_udf_runtime_set`
  opens the local library path it is given (`dlopen`) and the runtime starts its worker processes on
  the machine (the user's own code runs in them; the export itself opens no connection); `komira_plan_stream` runs
  `sdk_exec.run_plan`, with the same local-only scans, and the plan decoder
  refuses a scan of a remote file system (`PLAN_WIRE_UNSUPPORTED_REMOTE_FS`);
  an envelope with a write target is written to a local file
  (`sdk_exec.run_plan_write`, which refuses a URL with `check_copy_target`); `komira_register_arrow_stream` reads only the memory of the stream it is given,
  through that stream's own callbacks; the other exports read a local file or
  the bytes given.
- Nothing is sent anywhere. `docs/design/logging_and_telemetry.md` records
  that spans and metrics go to in-process rings and that "nothing exports".
  The closure reads the environment through one primitive
  (`src/libc/src/libc/posix.mojo`), whose header limits it to platform
  handshake and test-runner values and states that configuration is never read
  from the environment.
- The only file the library opens that the caller did not name are the shared
  libraries above, by soname, through the system loader.

Offline behaviour follows: installing needs the network once, for `pip` to fetch
the komira wheel (it depends on no other distribution); running needs none.

## Keeping this page true

The table follows the file list of `libkomira_elf_report`. Any change to
`NATIVE_OWNERS` in `src/so/BUCK`, to the `archives` of a `native_shared_library`
of an owner, or to `cxx_runtime`, changes a row here and a section of `NOTICE`
in the same pull request.
