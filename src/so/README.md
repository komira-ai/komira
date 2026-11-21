# so

The C ABI of komira's one shared library, `libkomira` (`libkomira.so` on Linux,
`libkomira.dylib` on macOS arm64). Every language binding links against that
one library and its flat C surface: no Mojo type crosses it. This package holds
the surface's skeleton (the status codes, the version, the context handle and
the last-error call) and the source and render calls: registering a Parquet
file, the schema and scan bindings of Parquet, CSV and JSON files, and a plan
rendered as text. No call runs a query yet.

- `abi/komira.tsv`: the golden of the C ABI; `komira.h` is made from it.
- `status.mojo`: the six status codes, `KOMIRA_MAX_INPUT_BYTES`, `abi_version`, `buffer_status`, `input_length_status`.
- `session.mojo`: `Session`, the state a context handle stands for: the last
  error and the catalog of registered tables.
- `sources.mojo`: what the source and render calls do on values (a path or the
  bytes of a plan in; bytes or text out, or a raise with the engine's message).
- `_c_abi.mojo`: the exports. It is the only file here that holds pointers, it
  is not part of the Mojo package (it is the source of the `libkomira`
  target), and its header says who owns and frees each pointer.

## The C surface

```text
int32_t  komira_abi_version(void);
void    *komira_ctx_new(void);
void     komira_ctx_free(void *ctx);
int32_t  komira_last_error(void *ctx, uint8_t *out_buf, uint64_t out_cap,
                           uint64_t *out_len);
int32_t  komira_register_parquet(void *ctx, const char *name,
                                 const char *path);
int32_t  komira_parquet_schema(void *ctx, const char *path, uint8_t *out_buf,
                               uint64_t out_cap, uint64_t *out_len);
int32_t  komira_csv_binding(void *ctx, const char *path, uint8_t delimiter,
                            int32_t has_header, int32_t all_varchar,
                            uint8_t *out_buf, uint64_t out_cap,
                            uint64_t *out_len);
int32_t  komira_json_binding(void *ctx, const char *path, uint8_t *out_buf,
                             uint64_t out_cap, uint64_t *out_len);
int32_t  komira_plan_render(void *ctx, const uint8_t *plan, uint64_t plan_len,
                            uint8_t *out_buf, uint64_t out_cap,
                            uint64_t *out_len);
```

**Status codes.** Every fallible call returns one: `KOMIRA_OK` (0),
`KOMIRA_ERR_NULL_CTX` (-1, the context is NULL), `KOMIRA_ERR_NULL_ARG` (-2, a
required pointer other than the context is NULL), `KOMIRA_ERR_ENGINE` (-3, the
engine refused; the context's last error says why),
`KOMIRA_ERR_BUFFER_TOO_SMALL` (-4, below) and `KOMIRA_ERR_TOO_LARGE` (-5, a byte
input is longer than `KOMIRA_MAX_INPUT_BYTES`, 64 MiB; see `komira_plan_render`).

A caller tells the codes apart by value alone: success is zero, every failure
is negative.

```mojo
from so import (
    KOMIRA_ERR_BUFFER_TOO_SMALL,
    KOMIRA_ERR_ENGINE,
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_ERR_TOO_LARGE,
    KOMIRA_MAX_INPUT_BYTES,
    KOMIRA_OK,
    input_length_status,
)
from std.testing import assert_equal, assert_true

assert_equal(KOMIRA_OK, Int32(0))
assert_equal(KOMIRA_ERR_NULL_CTX, Int32(-1))
assert_equal(KOMIRA_ERR_NULL_ARG, Int32(-2))
assert_equal(KOMIRA_ERR_ENGINE, Int32(-3))
assert_equal(KOMIRA_ERR_BUFFER_TOO_SMALL, Int32(-4))
assert_equal(KOMIRA_ERR_TOO_LARGE, Int32(-5))
assert_equal(KOMIRA_MAX_INPUT_BYTES, UInt64(64 * 1024 * 1024))
assert_equal(input_length_status(KOMIRA_MAX_INPUT_BYTES), KOMIRA_OK)
assert_equal(
    input_length_status(KOMIRA_MAX_INPUT_BYTES + UInt64(1)),
    KOMIRA_ERR_TOO_LARGE,
)
assert_true(KOMIRA_ERR_ENGINE < KOMIRA_OK)
```

**Version.** `komira_abi_version()` is `major * 1000 + minor`: 1000 is 1.0.
Adding a symbol raises the minor version; changing or removing one raises the
major version and resets the minor to 0. The minor version stays below 1000.

```mojo
from so import ABI_MAJOR, ABI_MINOR, abi_version
from std.testing import assert_equal

assert_equal(abi_version(), ABI_MAJOR * 1000 + ABI_MINOR)
assert_equal(abi_version(), Int32(1001))
```

**The handle.** `komira_ctx_new` returns a context the caller owns until it
passes it to `komira_ctx_free`. A handle is not safe to use from two threads at
once, freeing one twice or using it after the free is undefined (as for
`free(3)`), and `komira_ctx_free(NULL)` does nothing. A context holds a
`Session`: the text of the last error, empty on a fresh one, and the tables
registered by name.

```mojo
from so import Session
from std.testing import assert_equal, assert_false, assert_true

var session = Session()
assert_false(session.has_error())
session.set_error(String("the file does not exist"))
assert_true(session.has_error())
assert_equal(session.last_error(), String("the file does not exist"))
session.clear_error()
assert_equal(session.last_error(), String(""))
```

**The two-call output protocol.** A call that returns bytes takes
`out_buf`, `out_cap` and `out_len`. It stores the byte count in `*out_len`
first. If `out_cap` is below the count it returns `KOMIRA_ERR_BUFFER_TOO_SMALL`
and writes nothing, so a caller never parses a truncated answer. So a caller
calls once with `out_cap` 0 (and `out_buf` NULL) to learn the length, allocates
that many bytes, and calls again.

```mojo
from so import KOMIRA_ERR_BUFFER_TOO_SMALL, KOMIRA_OK, buffer_status
from std.testing import assert_equal

assert_equal(buffer_status(12, UInt64(0)), KOMIRA_ERR_BUFFER_TOO_SMALL)
assert_equal(buffer_status(12, UInt64(11)), KOMIRA_ERR_BUFFER_TOO_SMALL)
assert_equal(buffer_status(12, UInt64(12)), KOMIRA_OK)
assert_equal(buffer_status(0, UInt64(0)), KOMIRA_OK)
```

**`komira_last_error`.** It copies the session's last error text, which is
UTF-8 and not NUL-terminated, into `out_buf` by that protocol. A fresh session's
text is empty: the call returns `KOMIRA_OK` with `*out_len` 0 and needs no
buffer. A NULL `ctx` is checked first (-1); then a NULL `out_len` (-2); a NULL
`out_buf` is refused (-2) only when there is text to write. A call refused for
a NULL argument on a live context stores its refusal as that context's last
error; a too-small buffer stores nothing, so the text a probe measured is the
text the next call returns.

**Sources and render.** Each call below takes the context first and returns a
status code; on `KOMIRA_ERR_ENGINE` the context's last error holds the engine's
message. Every one of them clears the previous last error when it starts, so
after a success the error is empty. A `const char *` is a NUL-terminated UTF-8
string the caller keeps alive for the call; one that is not valid UTF-8 is
refused (-3, with a last error) before it is used.

| call | what it does | refusals |
|---|---|---|
| `komira_register_parquet(ctx, name, path)` | reads the footer of the Parquet file at `path` and binds it into the session under `name` (found without regard to case) | NULL `name` or `path`: -2. A missing, unreadable or nested file: -3 |
| `komira_parquet_schema(ctx, path, out_buf, out_cap, out_len)` | the file's Arrow schema as `komira.plan.v1` `WireSchema` bytes, for a plan author to splice into a Parquet scan | NULL `path` or `out_len`: -2. A file that cannot be read: -3 |
| `komira_csv_binding(ctx, path, delimiter, has_header, all_varchar, out_buf, out_cap, out_len)` | the whole `WireScanBinding` of a CSV file, schema inferred from a bounded prefix of an uncompressed file (a compressed file is read whole). `has_header` and `all_varchar` are `int32_t`; any non-zero value is true | as `komira_parquet_schema` |
| `komira_json_binding(ctx, path, out_buf, out_cap, out_len)` | the same for a newline-delimited JSON file; the schema comes from the leading records | as `komira_parquet_schema` |
| `komira_plan_render(ctx, plan, plan_len, out_buf, out_cap, out_len)` | decodes the serialized plan `plan[0..plan_len]` (a `WirePlanEnvelope`) and writes its text as authored, before any optimizer rule; the plan is not run | NULL `plan` or `out_len`: -2. `plan_len` above 64 MiB (`KOMIRA_MAX_INPUT_BYTES`): -5, checked before the plan is read or anything is allocated; exactly 64 MiB is accepted. Bytes that are not an admissible plan: -3 |

The four calls with an `out_buf` follow the two-call protocol above. The
binding and schema bytes are what a plan author splices into a scan leaf: the
fingerprint, kind id and snapshot fields come from the engine and are not
computed by the caller. A NULL `ctx` is -1 for all five.

## Building and testing

```sh
./buck2 build komira//src/so:so       # the package and its tests
./buck2 build komira//src/so:libkomira       # the shared library, behind its gate
```

The library is published only if the gate passes: the exports check, then
thirteen drivers (`tests/gate/`) that open it with `RTLD_NOW` and call it as a
foreign host would. Seven cover the skeleton: the version (1001, which is 1.1),
create and free (distinct handles, separate sessions), no symbol beyond the
nine, a fresh session's empty error, the two-call protocol (zero capacity, one
byte short, exact, larger), a NULL context, and a NULL `out_len`. One driver per
new call writes its input file under `$TEST_TMPDIR` and checks a good input,
NULL context (-1), a NULL input (-2 with a last error), a bad file or plan (-3
with the message as the last error) and, for the four calls with an output, the
two-call protocol; a good call after a refusal leaves no error.
`exports_exact` makes the nine names above the whole dynamic symbol table.
On Linux the eight C owners in the library's closure (async, async_api, compression, fs,
libc, metrics, parquet_codec, scan_source) are linked as their own shared libraries
(`native_owners`), not embedded; on macOS arm64 there are none, and the C archives are linked
statically into `libkomira.dylib`. On Linux the thirteenth driver, `gate_native_owners`,
reads the `DT_NEEDED` entries of the library's ELF dynamic section and requires
the SONAME of each of the eight (`libkomira_<owner>_native.so.1`); an owner
dropped from `native_owners` leaves its C embedded, and that driver fails.
The plan driver also refuses a `plan_len` of 64 MiB plus one and of
`UINT64_MAX` (-5, nothing written), and accepts exactly 64 MiB as a length;
`gate_parquet_schema` passes a path that is not valid UTF-8 and requires -3.

Like every Mojo library, `libkomira` has `DT_NEEDED libKGENCompilerRTShared.so`
and finds the Mojo runtime in `lib/` beside it
(see "C-ABI shared libraries" in `tools/build/mojo/README.md`).

## What the library links and weighs

The table is the output of `komira//tools/build/package/libkomira:libkomira_elf_report`
(linux-x86_64). One build action runs `so_report`
(`tools/build/native/so_report.zig`, tested in `so_report_test.zig`) on the built
`libkomira.so`, on each native owner's `.so.1`, and on the Mojo runtime libraries of
the platform row's `runtime_libs`, and writes the table below; nothing is
read by hand. It is a record of the library as it is while `so` depends on `sdk` and
not on `sdk_exec`, not a gate: the gates above and `libkomira_install` hold the
exports, the owner SONAMEs, a version of at least 1000 and that every library is
mapped from the prefix. Each `RUNPATH` or `RPATH` entry is one backticked
item; an entry holding colons is one string the loader splits itself. The `RPATH` values of
the Mojo runtime libraries are the vendor's own.

| file | role | size (bytes) | SONAME | RUNPATH | RPATH | highest GLIBC | highest GLIBCXX | highest CXXABI |
|---|---|---|---|---|---|---|---|---|
| `libkomira.so` | target | 3524608 | `libkomira.so` | `$ORIGIN/lib:$ORIGIN` | none | `GLIBC_2.34` | none | none |
| `libkomira_async_api_native.so.1` | owner | 2760 | `libkomira_async_api_native.so.1` | none | none | none | none | none |
| `libkomira_async_rt_native.so.1` | owner | 43992 | `libkomira_async_rt_native.so.1` | none | none | `GLIBC_2.17` | none | none |
| `libkomira_compression_native.so.1` | owner | 244856 | `libkomira_compression_native.so.1` | none | none | `GLIBC_2.34` | none | none |
| `libkomira_fs_native.so.1` | owner | 9344 | `libkomira_fs_native.so.1` | none | none | `GLIBC_2.33` | none | none |
| `libkomira_libc_native.so.1` | owner | 11080 | `libkomira_libc_native.so.1` | none | none | `GLIBC_2.33` | none | none |
| `libkomira_metrics_native.so.1` | owner | 2600 | `libkomira_metrics_native.so.1` | none | none | none | none | none |
| `libkomira_parquet_codec_native.so.1` | owner | 173736 | `libkomira_parquet_codec_native.so.1` | none | none | `GLIBC_2.14` | none | none |
| `libkomira_scan_source_native.so.1` | owner | 2488 | `libkomira_scan_source_native.so.1` | none | none | none | none | none |
| `libAsyncRTRuntimeGlobals.so` | runtime | 685176 | `libAsyncRTRuntimeGlobals.so` | none | `$ORIGIN:$ORIGIN/../lib:$ORIGIN/../_solib_k8/_USupport:$ORIGIN/libAsyncRTRuntimeGlobals.so.runfiles/_main/_solib_k8/_USupport` | `GLIBC_2.35` | `GLIBCXX_3.4.29` | `CXXABI_1.3.9` |
| `libKGENCompilerRTShared.so` | runtime | 1222584 | `libKGENCompilerRTShared.so` | none | `$ORIGIN:$ORIGIN/../lib:$ORIGIN/../_solib_k8/_USupport:$ORIGIN/libKGENCompilerRTShared.so.runfiles/_main/_solib_k8/_USupport:$ORIGIN/../_solib_k8/_UAsyncRT:$ORIGIN/libKGENCompilerRTShared.so.runfiles/_main/_solib_k8/_UAsyncRT` | `GLIBC_2.34` | `GLIBCXX_3.4.30` | `CXXABI_1.3.11` |
| `libMSupportGlobals.so` | runtime | 49200 | `libMSupportGlobals.so` | none | `$ORIGIN:$ORIGIN/../lib` | `GLIBC_2.34` | `GLIBCXX_3.4.14` | `CXXABI_1.3.11` |
| `libgcc_s.so.1` | runtime | 902392 | `libgcc_s.so.1` | none | `$ORIGIN/.` | `GLIBC_2.14` | none | none |
| `libstdc++.so.6` | runtime | 21186008 | `libstdc++.so.6` | none | `$ORIGIN/.` | `GLIBC_2.17` | none | none |

| file | DT_NEEDED, in order |
|---|---|
| `libkomira.so` | `libKGENCompilerRTShared.so`, `libkomira_async_rt_native.so.1`, `libkomira_async_api_native.so.1`, `libkomira_compression_native.so.1`, `libkomira_fs_native.so.1`, `libkomira_libc_native.so.1`, `libkomira_metrics_native.so.1`, `libkomira_parquet_codec_native.so.1`, `libkomira_scan_source_native.so.1`, `libpthread.so.0`, `libc.so.6` |
| `libkomira_async_api_native.so.1` | none |
| `libkomira_async_rt_native.so.1` | `libpthread.so.0`, `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libkomira_compression_native.so.1` | `libpthread.so.0`, `libc.so.6` |
| `libkomira_fs_native.so.1` | `libpthread.so.0`, `libc.so.6` |
| `libkomira_libc_native.so.1` | `libpthread.so.0`, `libc.so.6` |
| `libkomira_metrics_native.so.1` | none |
| `libkomira_parquet_codec_native.so.1` | `libc.so.6` |
| `libkomira_scan_source_native.so.1` | none |
| `libAsyncRTRuntimeGlobals.so` | `libm.so.6`, `libstdc++.so.6`, `libMSupportGlobals.so`, `libgcc_s.so.1`, `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libKGENCompilerRTShared.so` | `libm.so.6`, `libstdc++.so.6`, `libMSupportGlobals.so`, `libAsyncRTRuntimeGlobals.so`, `libgcc_s.so.1`, `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libMSupportGlobals.so` | `libm.so.6`, `libstdc++.so.6`, `libgcc_s.so.1`, `libc.so.6` |
| `libgcc_s.so.1` | `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libstdc++.so.6` | `libm.so.6`, `libdl.so.2`, `libc.so.6`, `ld-linux-x86-64.so.2`, `libgcc_s.so.1` |

| library | role | reached from the target | target's undefined symbols it defines |
|---|---|---|---|
| `libkomira_async_api_native.so.1` | owner | needed (direct) | 0 |
| `libkomira_async_rt_native.so.1` | owner | needed (direct) | 0 |
| `libkomira_compression_native.so.1` | owner | needed (direct) | 1 |
| `libkomira_fs_native.so.1` | owner | needed (direct) | 0 |
| `libkomira_libc_native.so.1` | owner | needed (direct) | 6 |
| `libkomira_metrics_native.so.1` | owner | needed (direct) | 0 |
| `libkomira_parquet_codec_native.so.1` | owner | needed (direct) | 1 |
| `libkomira_scan_source_native.so.1` | owner | needed (direct) | 0 |
| `libAsyncRTRuntimeGlobals.so` | runtime | needed (through another library) | 0 |
| `libKGENCompilerRTShared.so` | runtime | needed (direct) | 5 |
| `libMSupportGlobals.so` | runtime | needed (through another library) | 0 |
| `libgcc_s.so.1` | runtime | needed (through another library) | 0 |
| `libstdc++.so.6` | runtime | needed (through another library) | 0 |

Owners needed: 8 of 8 (490856 bytes); declared only: 0.

Wheel tag: `manylinux_2_34` (highest GLIBC of the target and the owners: `GLIBC_2.34`).

Reading it:

- **Owners.** All eight are `DT_NEEDED` of libkomira (direct), none is embedded, and
  together they weigh 490,856 bytes. They are needed at load time: the loader refuses
  a library with a missing `DT_NEEDED`. Only three of the eight (libc, compression,
  parquet_codec) define a symbol that libkomira's own undefined symbols name; the other five
  (async_rt, async_api, fs, metrics, scan_source) are `DT_NEEDED` with no symbol bound to
  them from libkomira itself, so today they are declared and loaded but not called through
  libkomira's own symbol table. They stay in the package because each is a
  `native_owners` entry the library's gate requires.
- **glibc floor.** The highest `GLIBC_` version of libkomira and the eight owners is
  2.34 (libkomira and compression), so `manylinux_2_34` is honest for the files the package
  carries. No `GLIBCXX_` or `CXXABI_` version is needed by them. The Python wheel's bundled
  flavour also carries the three Mojo runtime libraries (through `[dist]`), and its external
  flavour loads them, so both are tagged alike; `libAsyncRTRuntimeGlobals.so`
  needs `GLIBC_2.35`, one above that floor, and `libKGENCompilerRTShared.so` needs
  `GLIBCXX_3.4.30` and `CXXABI_1.3.11`, so the wheel is tagged `manylinux_2_35` and a host
  needs at least glibc 2.35 (see `docs/design/mojo_runtime_pypi_vs_conda.md`).
- **Mojo runtime.** libkomira is `DT_NEEDED` on `libKGENCompilerRTShared.so` only; that
  library in turn needs `libMSupportGlobals.so` and `libAsyncRTRuntimeGlobals.so`, the
  other two of the three, and those need `libstdc++.so.6` and `libgcc_s.so.1`. Each
  carries its own `RPATH` that includes `$ORIGIN`, so the three are found beside one
  another; libkomira finds them through its `RUNPATH` entry `$ORIGIN/lib`. The `[dist]`
  directory of this target holds them in `lib/` beside the eight owners, and the Python
  wheel copies it whole; the C++ libraries are not in it, the host provides them.

The `libkomira_install` check loads libkomira from an empty prefix with `RTLD_NOW`
and the probe measured `komira_abi_version` 1001; every library the loader mapped came from the
prefix's `lib/`: the eight owners, `libKGENCompilerRTShared.so`, and the runtime's
own dependencies of it (`libAsyncRTRuntimeGlobals.so`, `libMSupportGlobals.so`,
`libgcc_s.so.1`, `libstdc++.so.6`).

### The CPU-level variants

`:libkomira_x86_64_v2` and `:libkomira_x86_64_v3` are the same library linked once per
level of the linux-x86_64 row's `isa_variants` (`tools/build/platforms/table.bzl`;
`docs/design/isa_variants.md`), and
`komira//tools/build/package/libkomira:libkomira_elf_report_x86_64_v2` and
`:libkomira_elf_report_x86_64_v3` write the table above for each. They differ from it
only in the `libkomira.so` row; the owners and runtime rows are the same files:

| variant | size of `libkomira.so` (bytes) | RUNPATH | highest GLIBC |
|---|---|---|---|
| `x86-64-v2` (the floor) | 3543840 | `$ORIGIN/lib:$ORIGIN` | `GLIBC_2.34` |
| `x86-64-v3` | 3524608 | `$ORIGIN/lib:$ORIGIN:$ORIGIN/../../lib` | `GLIBC_2.34` |

x86-64-v3 is built with the toolchain and CPU of `:libkomira` (the row's `target_cpu`);
the extra `$ORIGIN/../../lib` finds the one `lib/` of the variants directory from
`variants/x86-64-v3/`. A second level adds one more `libkomira.so`, about 3.4 MiB, to a
native directory; the owners and the runtime are shared.

## The header and the golden

`abi/komira.tsv` is the golden of the ABI: the version (1.1), one row per export
with its return type, argument types and the version that added it, and one row
per status code and per limit (`constant`). `komira_abi_golden` checks it on every
build against the `@export abi("C")` functions of `_c_abi.mojo` (names, return and
argument types) and against `status.mojo` (the constants and their values), and
writes `komira.h` from it:

```sh
./buck2 build komira//src/so:komira_abi      # komira.h, only if the golden is exact
```

An export added to `_c_abi.mojo` without a row, a row without an export, a changed
type and a changed or added constant all fail that target, naming the finding. The
header spells the opaque context `komira_handle`, strings `const char *` and the
plan bytes `const uint8_t *`; `_c_abi.mojo` declares `Handle`, `CStr` and
`ConstBytes` for them. The golden does not check that its version was raised when
a row changed: that compares with the previous release.

`tests/c/abi_driver.c` is a C program that includes `komira.h` and nothing of
ours. It opens `./libkomira.so`, binds each of the nine functions to a pointer
declared with the header's own prototype, and checks the version in the header
against `komira_abi_version()`, the status codes, the input bound
(`KOMIRA_MAX_INPUT_BYTES` plus one is -5), and the last-error round trip (NULL
context, NULL `out_len`, an engine refusal, a buffer one byte short, an exact
buffer). It is built by zig cc and run against the published library:

```sh
./buck2 build komira//src/so:c_abi_check     # exit 0 of the driver, or red
```

The header is not part of the library's conda package yet; that waits on the
packaging change that lists it.

## Not done

No release-over-release version check and no packaged header yet; no plan execution, query
or UDF call; no engine in the session; the one language binding is the Node addon ([`node/`](https://github.com/komira-ai/komira/blob/main/node/README.md)).
The calls that run a query, ported from the earlier SDK, their result as an Arrow
C stream, and what an abort does at the boundary are described in
[docs/design/libkomira_run_abi.md](https://github.com/komira-ai/komira/blob/main/docs/design/libkomira_run_abi.md).
