# Licence audit of the files the Python wheel carries

The wheel carries `libkomira`, the native owner libraries `libkomira` links
as `DT_NEEDED`, the three Mojo runtime libraries it needs, the Python package,
`py.typed` and four licence files (`LICENSE`, `NOTICE`, `MODULAR_LICENSE`,
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
| `libkomira_scan_source_native.so.1` | none: komira's C | Apache-2.0 | none | (LICENSE) |
| `libkomira_compression_native.so.1` | snappy 1.3.1 (static); LLVM libc++ and libc++abi from the Zig toolchain (static, symbols local) | BSD-3-Clause; Apache-2.0 with LLVM exceptions | snappy: copyright notice, conditions and disclaimer reproduced for binary redistribution; libc++: none for object code (LLVM exception), recorded anyway | "Third-party code inside the native files" 1 and 3 |
| `libkomira_parquet_codec_native.so.1` | Brotli decoder 1.1.0 (static, names prefixed `komira_brotli_`) | MIT | copyright notice and permission notice reproduced | same section, 2 |
| `libKGENCompilerRTShared.so` | Modular's Mojo runtime: binary, unmodified from the pinned `mojo-compiler` conda package | Modular Community License Terms (`LicenseRef-Modular-Proprietary`) | the licence text displayed with the copies, which the wheel carries as `.dist-info/licenses/MODULAR_LICENSE`, and the package's `Third-Party-Notices` (`.dist-info/licenses/MODULAR_THIRD_PARTY_NOTICES`) | "The Mojo runtime: Modular's libraries, carried in the wheel" |
| `libAsyncRTRuntimeGlobals.so` | same | same | same | same |
| `libMSupportGlobals.so` | same | same | same | same |

Sources and pins: snappy `//third_party/snappy` (version and archive sha256
there), Brotli `//third_party/brotli` (same). The archive's `COPYING` and
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
- **aws-lc, s2n-tls and the AWS, Google and Azure clients**: not in the
  wheel. The Mojo closure of the `so` package (53 packages, read from the
  `deps` of each `BUCK` file from `so` down) holds no `awslc`, `crypto`,
  `http`, `connect`, `aws_*`, `gcp_*` or `azure_*` package, and the `DT_NEEDED`
  list above holds no TLS library. `awslc` and `s2n-tls` stay build and
  test inputs of other packages (see `NOTICE`, opening paragraph). A change
  that adds one to the closure changes the table of `libkomira_elf_report` and
  must update this page and `NOTICE` in the same pull request.
- **Generated clients** (`NOTICE`, "Generated clients"): not in libkomira's
  closure, so no text derived from botocore or googleapis is in the wheel.

## Telemetry and network

Verified by reading, not by running anything on a developer machine:

- `libkomira`'s dynamic symbol table is exactly the nine `komira_*` exports
  (`exports_exact` gate in `src/so/tests/gate/`). None takes a URL, host or
  socket: they take a local file path or the bytes of a plan, and return
  bytes, text or a status.
- Outside `async_rt`, no package of the closure has code that names a socket,
  a host-name lookup, a reactor or an `http(s)://` literal (searched with
  `grep` over each package's `.mojo` and `.c` files, tests excluded; the hits
  are comments). `async_rt` holds the reactor and socket primitives and is
  compiled into the library, as other packages import its file and morsel
  parts; no export of the nine starts a reactor or opens a socket.
- Nothing is sent anywhere. `docs/design/logging_and_telemetry.md` records
  that spans and metrics go to in-process rings and that "nothing exports".
  The closure reads the environment through one primitive
  (`src/libc/src/libc/posix.mojo`), whose header limits it to platform
  handshake and test-runner values and states that configuration is never read
  from the environment.
- The only file the library opens that the caller did not name are the shared
  libraries above, by soname, through the system loader.

Offline behaviour follows: installing needs the network once, for `pip` to fetch
the komira wheel, which depends on no other distribution; running needs none.

## Keeping this page true

The table follows the file list of `libkomira_elf_report`. Any change to
`NATIVE_OWNERS` in `src/so/BUCK`, to the `archives` of a `native_shared_library`
of an owner, or to `cxx_runtime`, changes a row here and a section of `NOTICE`
in the same pull request.
