# komira_so

The C ABI of komira's one shared library, `libkomira` (`libkomira.so` on Linux,
`libkomira.dylib` on macOS arm64). Every language binding links against that
one library and its flat C surface: no Mojo type crosses it. This package holds
the surface's skeleton (the status codes, the version, the context handle and
the last-error call) and the source and render calls: registering a Parquet
file, the schema and scan bindings of Parquet, CSV and JSON files, and a plan
rendered as text. No call runs a query yet.

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
from komira_so import (
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
from komira_so import ABI_MAJOR, ABI_MINOR, abi_version
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
from komira_so import Session
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
from komira_so import KOMIRA_ERR_BUFFER_TOO_SMALL, KOMIRA_OK, buffer_status
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
./buck2 build komira//src/komira_so:komira_so       # the package and its tests
./buck2 build komira//src/komira_so:libkomira       # the shared library, behind its gate
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
The seven C owners in the library's closure (async, async_api, compression, fs,
libc, metrics, scan_source) are linked as their own shared libraries
(`native_owners`), not embedded. The thirteenth driver, `gate_native_owners`,
reads the `DT_NEEDED` entries of the library's ELF dynamic section and requires
the SONAME of each of the seven (`libkomira_<owner>_native.so.1`); an owner
dropped from `native_owners` leaves its C embedded, and that driver fails.
The plan driver also refuses a `plan_len` of 64 MiB plus one and of
`UINT64_MAX` (-5, nothing written), and accepts exactly 64 MiB as a length;
`gate_parquet_schema` passes a path that is not valid UTF-8 and requires -3.

Like every Mojo library, `libkomira` has `DT_NEEDED libKGENCompilerRTShared.so`
and finds the Mojo runtime in `lib/` beside it
(see "C-ABI shared libraries" in `tools/build/mojo/README.md`).

## Not done

No golden file, generated header or version check yet; no plan execution, query
or UDF call; no engine in the session; no language binding.
