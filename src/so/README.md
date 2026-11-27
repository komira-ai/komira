# so

The C ABI of komira's one shared library, `libkomira` (`libkomira.so` on Linux,
`libkomira.dylib` on macOS arm64). Every language binding links against that
one library and its flat C surface: no Mojo type crosses it. This package holds
the surface's skeleton (the status codes, the version, the context handle and
the last-error call), the session options (the engine's worker count and
memory budget, as arguments of `komira_ctx_new_with_options`) and the source and render calls: registering a Parquet,
CSV or newline-delimited JSON file as a table, the schema and scan bindings of Parquet, CSV and JSON files, and a plan
rendered as text; the credential calls, which define a credential on the
session by name and hold its values in the session's secret store; and
`komira_sql_stream`, which runs one SQL statement on the session and hands its
answer over as an Arrow C stream; and the run handle, a cancel token and a
progress counter that `komira_sql_stream_run` runs a statement under and that
another thread cancels and reads while it runs; `komira_plan_stream`,
which runs a serialized logical plan the same way, with no SQL text on the
way; and
`komira_register_arrow_stream`, which drains a host's Arrow C stream into a
table the session holds in memory, which SQL on the session reads by name; and
`komira_add_sql_binding`, which binds a table name to the protobuf bytes of a
`WireBoundSource` (a local Parquet path, or Parquet objects of an `s3://` or
`az://` location read with a credential sealed on the session), replacing a
table of that name; `komira_sql_stream` reads such a table through the object
store.

- `abi/komira.tsv`: the golden of the C ABI; `komira.h` is made from it.
- `status.mojo`: the seven status codes, `KOMIRA_MAX_INPUT_BYTES`, the credential
  kinds, fields and scope, `abi_version`, `buffer_status`, `input_length_status`.
- `session.mojo`: `Session`, the state a context handle stands for: the last
  error, the engine (`sdk_exec`'s `EngineContext`), whose catalog holds the
  registered tables, and the credentials. `try_new_session` is the session
  `komira_ctx_new` hands out, or None when the engine does not start (the
  export returns that as NULL). `session_options` turns the two `int64_t`
  arguments of `komira_ctx_new_with_options` into the engine's options.
- `credentials.mojo`: `SessionCredentials`, the credential calls on values (a
  kind, a name, a field's bytes in; an id out, or a raise with a named error).
- `credential_store.mojo`: `SessionSecretStore`, the `SecretStore` the values
  live in, wiped when replaced or dropped.
- `sources.mojo`: what the source, render, SQL and plan calls do on values (a
  path, the bytes of a plan or SQL text in; bytes, text or the answer batches
  of `sql_result` and `plan_result` out, or a raise with the engine's message);
  `sql_result` also runs under a `RunControl` (`sdk_exec.run_control`), whose
  cancel raises the named error `QUERY_CANCELLED`.
- `bindings.mojo`: what `komira_add_sql_binding` does on values (a name, the
  bytes of a `WireBoundSource` and a scope in; a table bound on the session, or
  a raise with the named refusal).
- `_c_abi.mojo`: the exports. It is the only file here that holds pointers, it
  is not part of the Mojo package (it is the source of the `libkomira`
  target), and its header says who owns and frees each pointer.

## The C surface

```text
int32_t  komira_abi_version(void);
void    *komira_ctx_new(void);
void    *komira_ctx_new_with_options(int64_t worker_count,
                                     int64_t memory_budget_bytes);
void     komira_ctx_free(void *ctx);
int32_t  komira_last_error(void *ctx, uint8_t *out_buf, uint64_t out_cap,
                           uint64_t *out_len);
int32_t  komira_last_error_code(void *ctx, uint8_t *out_buf,
                                uint64_t out_cap, uint64_t *out_len);
int32_t  komira_last_error_step(void *ctx);
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
int32_t  komira_credential_add(void *ctx, int32_t kind, const char *name,
                               int32_t *out_id);
int32_t  komira_credential_set(void *ctx, int32_t id, int32_t field,
                               const uint8_t *value, uint64_t value_len);
int32_t  komira_credential_seal(void *ctx, int32_t id, int32_t scope);
int32_t  komira_sql_stream(void *ctx, const char *sql,
                           struct ArrowArrayStream *out);
int32_t  komira_register_csv(void *ctx, const char *name, const char *path,
                             uint8_t delimiter, int32_t has_header,
                             int32_t all_varchar);
int32_t  komira_register_json(void *ctx, const char *name,
                              const char *path);
void    *komira_run_new(void);
void     komira_run_free(void *run);
int32_t  komira_run_cancel(void *run);
int32_t  komira_run_progress(void *run, uint64_t *out_done,
                             uint64_t *out_total);
int32_t  komira_sql_stream_run(void *ctx, const char *sql, void *run,
                               struct ArrowArrayStream *out);
int32_t  komira_plan_stream(void *ctx, const uint8_t *plan, uint64_t plan_len,
                            struct ArrowArrayStream *out);
int32_t  komira_register_arrow_stream(void *ctx, const char *name,
                                      struct ArrowArrayStream *stream);
int32_t  komira_add_sql_binding(void *ctx, const char *name,
                                const uint8_t *source, uint64_t source_len,
                                int32_t scope);
int32_t  komira_csv_binding_with_skip(void *ctx, const char *path,
                                      uint8_t delimiter, int32_t has_header,
                                      int32_t all_varchar, int64_t skip,
                                      uint8_t *out_buf, uint64_t out_cap,
                                      uint64_t *out_len);
int32_t  komira_register_csv_with_skip(void *ctx, const char *name,
                                       const char *path, uint8_t delimiter,
                                       int32_t has_header, int32_t all_varchar,
                                       int64_t skip);
```

**Status codes.** Every fallible call returns one: `KOMIRA_OK` (0),
`KOMIRA_ERR_NULL_CTX` (-1, the context is NULL), `KOMIRA_ERR_NULL_ARG` (-2, a
required pointer other than the context is NULL), `KOMIRA_ERR_ENGINE` (-3, the
engine refused; the context's last error says why),
`KOMIRA_ERR_BUFFER_TOO_SMALL` (-4, below), `KOMIRA_ERR_TOO_LARGE` (-5, a byte
input is longer than `KOMIRA_MAX_INPUT_BYTES`, 64 MiB; see `komira_plan_render`)
and `KOMIRA_ERR_CANCELLED` (-6, the run was cancelled through its run handle;
see "Cancel and progress" below).

A caller tells the codes apart by value alone: success is zero, every failure
is negative. A binding treats a negative code it does not know as a failure, so
a code a later minor version adds is not mistaken for success.

```mojo
from so import (
    KOMIRA_ERR_BUFFER_TOO_SMALL,
    KOMIRA_ERR_CANCELLED,
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
assert_equal(KOMIRA_ERR_CANCELLED, Int32(-6))
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
assert_equal(abi_version(), Int32(1011))
```

**The handle.** `komira_ctx_new` returns a context the caller owns until it
passes it to `komira_ctx_free`, or NULL when the context's engine does not
start (the host probe or the start of its workers fails); with no context
there is no last error, so the engine's message is not available. A handle is not safe to use from two threads at
once, freeing one twice or using it after the free is undefined (as for
`free(3)`), and `komira_ctx_free(NULL)` does nothing. A context holds a
`Session`: the last error (its text, its step and its code, all empty or `KOMIRA_STEP_NONE` on a fresh one), and an engine
(`sdk_exec`'s `EngineContext`) whose catalog holds the tables registered by
name. The engine's workers (the host's compute thread count) start in
`komira_ctx_new` and stop in `komira_ctx_free`.

**Session options.** `komira_ctx_new_with_options(worker_count,
memory_budget_bytes)` is `komira_ctx_new` with the engine's options as
arguments; nothing is read from the environment. `worker_count` is the number
of compute workers; `memory_budget_bytes` is the bytes the sinks of one query
may reserve in total (the segment pool). 0 for either is the host's own value
(the hardware probe's compute thread count, and 70% of the available memory),
which is what `komira_ctx_new` uses for both. A negative value is refused:
the call returns NULL, as it does when the engine cannot start. A positive
value has no upper bound. The options are fixed for the life of the context.
A query whose aggregation, sort or window state needs more than the budget is
refused at step `execute`: `komira_sql_stream` returns `KOMIRA_ERR_ENGINE`
with a last error of the form `execute: [Processor] MEMORY_BUDGET_EXCEEDED: pipeline_exec: the
aggregation sink of segment <n> was denied <bytes> bytes of the segment's memory pool (budget
<budget>, granted <bytes>)`, and the context answers the next query.

```mojo
from sdk_exec.engine_options import EngineOptions
from so import (
    KOMIRA_STEP_BIND,
    KOMIRA_STEP_NONE,
    Session,
    error_code,
    session_options,
    step_number,
    try_new_session,
)
from std.testing import assert_equal, assert_false, assert_true

var session = Session()
assert_false(session.has_error())
session.set_error(String("the file does not exist"))
assert_true(session.has_error())
assert_equal(session.last_error(), String("the file does not exist"))
assert_equal(session.last_error_step(), KOMIRA_STEP_NONE)
session.clear_error()
assert_equal(session.last_error(), String(""))
# An engine refusal keeps its step and code beside its text.
session.set_refusal(String("bind"), String("SQL bind error: unknown table 't'"))
assert_equal(session.last_error(), String("bind: SQL bind error: unknown table 't'"))
assert_equal(session.last_error_step(), KOMIRA_STEP_BIND)
assert_equal(session.last_error_code(), String("SQL_BIND_ERROR"))
assert_equal(step_number(String("bind")), KOMIRA_STEP_BIND)
assert_equal(error_code(String("ERR: x")), String(""))
session.clear_error()
# The engine started with the host's own worker count and holds no table yet.
assert_true(session.engine.host_profile.thread_count >= 1)
assert_false(session.engine.catalog.has("t"))
# komira_ctx_new's session: None (the NULL handle) when the engine does not
# start, here because it refuses a worker count of 0; nothing raises.
assert_false(Bool(try_new_session(EngineOptions(worker_count=0))))
# komira_ctx_new_with_options(2, 1 << 20): two workers within 1 MiB. A 0 is
# the host's own value; a negative value is the NULL handle.
var made = try_new_session(session_options(2, 1 << 20))
assert_true(Bool(made))
var small = made.take()
assert_equal(small.engine.host_profile.thread_count, 2)
assert_equal(small.engine.host_profile.memory_budget_bytes, 1 << 20)
assert_false(Bool(session_options(0, 0).worker_count))
assert_false(Bool(try_new_session(session_options(-1, 0))))
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

**`komira_last_error_code` and `komira_last_error_step`.** The text of an
error is also read as a code and a step, so a caller need not parse it.
`komira_last_error_code` copies the code, UTF-8 and not NUL-terminated, by the
same two-call protocol and with the same NULL rules as `komira_last_error` (a
NULL `ctx` is -1, a NULL `out_len` is -2, a NULL `out_buf` is -2 only when there
are bytes to write, a short buffer is -4 with the length stored). The code is
the empty text when the error has none or there is no error; it does not clear
the error. `komira_last_error_step` returns one of `KOMIRA_STEP_NONE` (0),
`KOMIRA_STEP_PARSE` (1), `KOMIRA_STEP_BIND` (2), `KOMIRA_STEP_OPTIMIZE` (3),
`KOMIRA_STEP_LOWER` (4) and `KOMIRA_STEP_EXECUTE` (5); it is `KOMIRA_STEP_NONE`
for a NULL `ctx`, when no error is held and for an error with no step, and it
never fails or clears.

The step of an error: an engine refusal of `komira_sql_stream` has the step
that refused, and so does one of `komira_plan_stream` at `bind` (a write's
destination), `optimize`, `lower` or `execute` (one at `decode` has `KOMIRA_STEP_NONE`, as `decode` is no step
of the SQL pipeline); a `KOMIRA_ERR_ENGINE` of `komira_register_parquet`,
`komira_parquet_schema`, `komira_csv_binding`, `komira_json_binding` or a
credential call has `KOMIRA_STEP_BIND`; every other error (a NULL argument, a
too-long input, a text that is not UTF-8 for `komira_sql_stream`, a column the
stream cannot carry, `komira_plan_render`) has `KOMIRA_STEP_NONE`. The code is
computed from the reason by `error_code` (`session.mojo`): `SQL syntax error: `
is `SQL_SYNTAX_ERROR`, `SQL bind error: ` is `SQL_BIND_ERROR`, `SQL not
supported: ` is `SQL_NOT_SUPPORTED`; any other reason that starts with an
upper-case word of two or more underscore-joined parts and `: `
(`LOWERING_WINDOW_UNSERVED: ...`) has that word; every other reason has no code.
For a `komira_sql_stream` or `komira_plan_stream` refusal the reason is the
text after `<step>: `, so an envelope with UDFs has the code
`PLAN_WIRE_UDFS_DROPPED` and a write to an `s3://` destination has
`STORAGE_URL_REFUSED` (step `bind`).

**Sources and render.** Each call below takes the context first and returns a
status code; on `KOMIRA_ERR_ENGINE` the context's last error holds the engine's
message. Every one of them clears the previous last error when it starts, so
after a success the error is empty. A `const char *` is a NUL-terminated UTF-8
string the caller keeps alive for the call; one that is not valid UTF-8 is
refused (-3, with a last error) before it is used.

| call | what it does | refusals |
|---|---|---|
| `komira_register_parquet(ctx, name, path)` | reads the footers of the Parquet files at `path` (one file, a glob or a directory) through the engine's footer reader and binds them into the engine's catalog as the table `name` (found without regard to case) | NULL `name` or `path`: -2. A missing, unreadable or nested file, a glob that matches nothing, or files whose schemas differ: -3 |
| `komira_parquet_schema(ctx, path, out_buf, out_cap, out_len)` | the file's Arrow schema as `komira.plan.v1` `WireSchema` bytes, for a plan author to splice into a Parquet scan | NULL `path` or `out_len`: -2. A file that cannot be read: -3 |
| `komira_csv_binding(ctx, path, delimiter, has_header, all_varchar, out_buf, out_cap, out_len)` | the whole `WireScanBinding` of a CSV file, schema inferred from a bounded prefix of an uncompressed file (a compressed file is read whole). `has_header` and `all_varchar` are `int32_t`; any non-zero value is true | as `komira_parquet_schema` |
| `komira_json_binding(ctx, path, out_buf, out_cap, out_len)` | the same for a newline-delimited JSON file; the schema comes from the leading records | as `komira_parquet_schema` |
| `komira_register_csv(ctx, name, path, delimiter, has_header, all_varchar)` | infers the schema of the CSV file at `path` now (a bounded prefix of an uncompressed file; a compressed file is read whole) and binds the file into the engine's catalog as the table `name` (found without regard to case). The table is the scan `read_csv` builds for the same file and dialect: `delimiter` and `has_header` are what the file is read with, `all_varchar` makes every column a string; `has_header` and `all_varchar` are `int32_t`, any non-zero value is true. Every later query reads the file at the schema inferred here. A table registered with `has_header` 0 is refused when a query reads it, at `lower`, naming `header=false`, as `read_csv(..., header=false)` is, until the reader names the columns as DuckDB does | NULL `name` or `path`: -2. A file that cannot be read or has no column: -3. An empty name: -3, `TABLE_NAME_EMPTY: a table name must not be empty`. A name the session already holds, of any kind and in any case: -3, `TABLE_ALREADY_REGISTERED: the session already has a table named '<name>'`. Nothing is registered on a refusal |
| `komira_register_json(ctx, name, path)` | the same for a newline-delimited JSON file, the scan `read_json` builds; the schema comes from the leading records | as `komira_register_csv` |
| `komira_csv_binding_with_skip(ctx, path, delimiter, has_header, all_varchar, skip, out_buf, out_cap, out_len)` (1.11) | `komira_csv_binding` for a file whose first `skip` lines are not data: they are skipped before the header (or before the first record with `has_header` 0), as SQL's `read_csv(..., skip = n)` does, and a non-zero `skip` is a param of the binding and part of its identity. `skip` is an `int64_t`; 0 answers the bytes of `komira_csv_binding` | as `komira_csv_binding`. A negative `skip`: -3, `CSV_SKIP_NEGATIVE: skip=<n> is negative; skip is the number of lines to skip at the start of the file and must be 0 or more`, step `bind`. A `skip` that leaves no line of the file: -3, `CSV_SKIP_PAST_END: skip=<n> skips every line of the file, which has <m> lines; no header or record is left to read` |
| `komira_register_csv_with_skip(ctx, name, path, delimiter, has_header, all_varchar, skip)` (1.11) | `komira_register_csv` for a file whose first `skip` lines are not data: the schema is inferred after them and every later query reads the file after them. 0 is `komira_register_csv` | as `komira_register_csv`, and the two refusals of `komira_csv_binding_with_skip`; nothing is registered on one |
| `komira_plan_render(ctx, plan, plan_len, out_buf, out_cap, out_len)` | decodes the serialized plan `plan[0..plan_len]` (a `WirePlanEnvelope`) and writes its text as authored, before any optimizer rule; the plan is not run | NULL `plan` or `out_len`: -2. `plan_len` above 64 MiB (`KOMIRA_MAX_INPUT_BYTES`): -5, checked before the plan is read or anything is allocated; exactly 64 MiB is accepted. Bytes that are not an admissible plan: -3 |

The four calls with an `out_buf` follow the two-call protocol above. The
binding and schema bytes are what a plan author splices into a scan leaf: the
fingerprint, kind id and snapshot fields come from the engine and are not
computed by the caller. A NULL `ctx` is -1 for all seven.

`komira_register_csv` and `komira_register_json` refuse a taken name.
`komira_register_parquet` replaces the table of a taken name (any kind, any
case), as `komira_add_sql_binding` and `komira_register_arrow_stream` do; a
registration it refuses leaves that table as it was. `register_csv` and
`register_json` are the calls on values:

```mojo
from runtime_paths import test_tmpdir
from so import Session, register_csv, register_json, sql_result
from std.testing import assert_equal, assert_true

var csv = test_tmpdir() + "/readme_people.csv"
with open(csv, "w") as f:
    f.write("id|name\n1|ann\n2|bob\n")
var jsonl = test_tmpdir() + "/readme_events.jsonl"
with open(jsonl, "w") as f:
    f.write('{"id":1,"v":"x"}\n{"id":2,"v":"y"}\n')

var session = Session()
register_csv(session, "people", csv, UInt8(ord("|")), True, False)
register_json(session, "events", jsonl)
var answer = sql_result(session, "select id from people where name = 'bob'")
assert_equal(answer.batches[0].column_at(0).as_primitive[DType.int64]().get(0), Int64(2))
var counted = sql_result(session, "select count(*) from events where v = 'y'")
assert_equal(counted.batches[0].column_at(0).as_primitive[DType.int64]().get(0), Int64(1))
var refused = String()
try:
    register_json(session, "People", jsonl)
except e:
    refused = String(e)
assert_true(refused.startswith("TABLE_ALREADY_REGISTERED: "))
```

**Running SQL.** `komira_sql_stream(ctx, sql, out)` runs the one SQL statement
`sql` on the session's engine, over the tables registered on it, and fills the
caller's `struct ArrowArrayStream` (the Arrow C Stream Interface; `komira.h`
defines the struct as the specification does) with the answer. A query answers
its rows; `COPY (<query>) TO '<file>'` writes a local Parquet, CSV or JSON file
and answers one row, the BIGINT `Count` of rows written; an answer of no rows is
its schema and one chunk of no rows. The answer is computed before the call
returns.

- `*out` is written only on `KOMIRA_OK`; on every other status it is left as
  the caller wrote it, so a caller can zero it and has nothing to release.
- After `KOMIRA_OK` the caller owns the stream and calls its `release` once.
  The stream needs neither the session nor the handle: `komira_ctx_free` may
  come first. Chunks taken from it stay readable after the stream's `release`,
  each with its own `release`. The callbacks are code of `libkomira`, which
  stays loaded while any stream from it is live.
- Refusals: NULL `ctx` is -1; a NULL `sql` or `out` is -2; a text whose NUL is
  not among its first `KOMIRA_MAX_INPUT_BYTES + 1` bytes is -5 before anything
  past them is read (a text of exactly 64 MiB is run); a text that is not UTF-8,
  and every engine refusal, is -3. The last error of an engine refusal is
  `<step>: <reason>`, the step that refused (`parse`, `bind`, `optimize`,
  `lower` or `execute`) and its own message; for `parse` the message is
  followed by ` at line <L>, column <C>` (both from 1; the column counts
  characters), where the text stopped parsing, as in
  `parse: SQL syntax error: expected keyword 'by' at line 1, column 42`; a result column the stream cannot
  carry is refused by name before `*out` is written. The context answers the
  next call after any refusal. The refusal's step and code are read with
`komira_last_error_step` and `komira_last_error_code`.

`sql_result` is the call on values: SQL text in, the answer's batches and
schema out (an `sdk_exec` `ArrowResult`, every batch checked to cross the
stream), or a raise with the `<step>: <reason>` text (with its position for `parse`).

```mojo
from so import Session, sql_result
from std.testing import assert_equal, assert_true

var session = Session()
var answer = sql_result(session, "select 1 as n")
assert_equal(answer.schema.field_name(0), String("n"))
assert_equal(answer.batches[0].num_rows(), 1)
var refused = String()
try:
    _ = sql_result(session, "select * from nosuch")
except e:
    refused = String(e)
assert_true(refused.startswith("bind: "))
```

**Running a plan.** `komira_plan_stream(ctx, plan, plan_len, out)` decodes
`plan[0..plan_len]`, an authored `komira.plan.v1.WirePlanEnvelope` (the bytes
`komira_plan_render` renders and the SDKs' plan builders write), optimizes it,
lowers it and runs it on the session's engine, and fills `*out` as
`komira_sql_stream` does. No SQL text is made and the SQL front end does not
run: a frame built by an SDK reaches the engine as a plan. A scan leaf carries
its own source (its paths and the schema `komira_parquet_schema` answers), so
the plan needs no table registered on the session.

- `*out`, its ownership and its lifetime are as for `komira_sql_stream`.
- An envelope that carries a write target (`WirePlanEnvelope.write_target`,
  format version 5) is written, not answered: the plan's rows go to the local
  Parquet, CSV or newline-delimited JSON file the target names, as `COPY ... TO`
  writes them (the same bytes, replacing an existing file), and `*out` is the
  one-row stream `COPY` answers, one `NOT NULL` int64 column `Count` holding
  the rows written. The destination is checked at `bind`, before the plan runs
  or any file is touched, so a refused write leaves the destination as it was.
- Refusals: NULL `ctx` is -1; a NULL `plan` or `out` is -2; a `plan_len` above
  `KOMIRA_MAX_INPUT_BYTES` is -5 before any byte of `plan` is read (exactly
  64 MiB is read, and the decoder then refuses what is above its own 16 MiB
  bound); every other refusal is -3, with the last error `<step>: <reason>`:
  `decode` for bytes that are not a plan this build runs (SQL text among them,
  a version it does not speak, and an envelope that carries UDFs,
  `PLAN_WIRE_UDFS_DROPPED`), then `bind` (a write's destination refused before
  the plan runs: a path with `://`, `STORAGE_URL_REFUSED`; CSV or JSON with
  `lz4`, `COPY_COMPRESSION_UNSUPPORTED`), then `optimize`, `lower` or
  `execute` (a destination directory that does not exist,
  `STORAGE_NOT_FOUND`; a column type the writer does not write,
  `COPY_TYPE_UNSUPPORTED`). The context answers the next call after any
  refusal. The refusal's step and code are read with `komira_last_error_step`
  and `komira_last_error_code`.

`plan_result` is the call on values: the plan's bytes in, an `ArrowResult` out,
or a raise with the `<step>: <reason>` text, which it records on the session
as the last error with its step and code. The route from the optimizer down
is `sdk_exec.engine_plan.run_plan`, the one `run_sql` takes after it binds; an
envelope with a write target takes `sdk_exec.engine_plan.run_plan_write`, the
route `run_sql` takes for `COPY ... TO`.

```mojo
from so import KOMIRA_STEP_NONE, STEP_DECODE, Session, plan_result
from std.testing import assert_equal, assert_true

var session = Session()
var not_a_plan = List[UInt8]()
not_a_plan.append(UInt8(0xFF))
not_a_plan.append(UInt8(0x00))
var refused = String()
try:
    _ = plan_result(session, not_a_plan^)
except e:
    refused = String(e)
assert_true(refused.startswith(String(STEP_DECODE) + ": "))
assert_equal(session.last_error(), refused)
assert_equal(session.last_error_step(), KOMIRA_STEP_NONE)
```

**Cancel and progress.** A run handle is a cancel token and a progress
counter. `komira_run_new()` returns one (never NULL), not cancelled and at 0 of
0 segments; the caller owns it until `komira_run_free(run)` (NULL does
nothing), which comes only once no call given it is running.
`komira_sql_stream_run(ctx, sql, run, out)` is `komira_sql_stream` under it:
the run polls the handle's token before each segment of its plan and at each
morsel boundary inside one, and counts its segments into the handle's
progress. Unlike a context, a run handle is used from two threads at once:
while `komira_sql_stream_run` runs on one thread, any other thread may call

- `komira_run_cancel(run)`: cancels the run in flight and every later run given
  the handle (a cancel is one-way); a second cancel does nothing. `KOMIRA_OK`,
  or -2 for a NULL `run`.
- `komira_run_progress(run, &done, &total)`: the segments finished and the
  segments counted by the runs given the handle. Both only grow, `done` is at
  most `total`, and a run that finishes leaves them equal. A run counts its
  plan's segments once the plan is checked, so a statement still being parsed,
  bound, optimized or lowered reads as before it started. -2 for a NULL `run`,
  `done` or `total`, with nothing written.

Neither touches a context or a last error. A run handle given to several calls
one after another sums their counts. Progress is read by the caller, never
called back.

A run the cancel stopped returns `KOMIRA_ERR_CANCELLED` (-6) with `*out` as the
caller wrote it and the last error `QUERY_CANCELLED: execute: <reason>` (today
`QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the caller
cancelled the run`). A cancel is observed only while the plan runs: a statement
refused before that keeps its own refusal (a bind error is -3 `bind: ...`
under a cancelled handle too), and a cancel that comes after the run's last
check leaves the answer standing (`KOMIRA_OK`). The context answers the next
call after a cancel. `komira_sql_stream_run` refuses a NULL `run` with -2 (the
last error `komira_sql_stream_run: sql, run or out is NULL`); its other
refusals are those of `komira_sql_stream`. A `COPY` whose run was cancelled
writes no file; its write, after the run, is not polled.

```mojo
from sdk_exec.run_control import RunControl
from so import Session, is_cancelled_error, sql_result
from std.testing import assert_equal, assert_true

var session = Session()
var control = RunControl()
var answer = sql_result(session, "select 1 as n", control)
assert_equal(answer.batches[0].num_rows(), 1)
assert_true(control.snapshot().total > 0)
assert_equal(control.snapshot().done, control.snapshot().total)

control.cancel()
var refused = String()
try:
    _ = sql_result(session, "select 1 as n", control)
except e:
    refused = String(e)
assert_true(is_cancelled_error(refused))
assert_true(refused.startswith("QUERY_CANCELLED: execute: "))
```

**Credentials.** A credential is defined in three calls and then belongs to
the session under its name. `komira_credential_add(ctx, kind, name, &id)` opens
a definition; `komira_credential_set(ctx, id, field, value, value_len)` sets one
field of it; `komira_credential_seal(ctx, id, KOMIRA_BIND_SESSION)` checks it
has every field its kind needs and makes it the session's value of `name`,
replacing any earlier one. A secret never travels in a `const char *` or in an
argument list a process shows: a value is bytes with a length, copied into the
session's `SecretStore` before `komira_credential_set` returns (the caller may
wipe its buffer at once), never written back and never put in an error. Values
are wiped when they are replaced and when the context is freed.

| kind (`KOMIRA_CRED_*`) | fields it needs (`KOMIRA_FIELD_*`) | fields it may set |
|---|---|---|
| `AWS_KEYS` 1 | `KEY_ID` 1, `SECRET` 2 | `SESSION_TOKEN` 3 |
| `AWS_PROFILE` 2 | `PROFILE` 4 | |
| `GCP_SERVICE_ACCOUNT` 3 | `FILE` 5 | |
| `GCP_TOKEN` 4 | `TOKEN` 6 | |
| `AZURE_KEY` 5 | `ACCOUNT` 7, `KEY` 8 | |
| `AZURE_SAS` 6 | `ACCOUNT` 7, `SAS` 9 | |
| `BEARER` 7 | `TOKEN` 6 | |
| `OAUTH2_CLIENT` 8 | `CLIENT_ID` 10, `CLIENT_SECRET` 11 | `SCOPE` 12, `TOKEN_URL` 13 |

A name is 1 to 128 bytes of letters, digits, `_`, `.` and `-`; `ambient` and
`anonymous` (in any case) are built in and are not defined. A wrong definition
is -3 with a named last error, `CREDENTIALS_INVALID: <operation>: <reason>`,
which names the credential and the setting and never a value; a name that is
refused is not quoted. A refused `set` or `seal` discards the definition. NULL
`ctx` is -1; a NULL `name` or `out_id`, or a NULL `value` with a non-zero
length, is -2; a `value_len` above `KOMIRA_MAX_INPUT_BYTES` is -5 before the
value is read. `*out_id` is written only on `KOMIRA_OK`. Sealing a byte-equal
value again keeps the name's generation; any other value takes the next one.
The only scope today is the session; a per-call scope comes with the call that
runs a query.

```mojo
from so import (
    KOMIRA_BIND_SESSION,
    KOMIRA_CRED_AWS_KEYS,
    KOMIRA_FIELD_KEY_ID,
    KOMIRA_FIELD_SECRET,
    SessionCredentials,
)
from std.testing import assert_equal, assert_true

var creds = SessionCredentials()
var id = creds.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
creds.set(id, KOMIRA_FIELD_KEY_ID, "AKIDEXAMPLE".as_bytes())
try:
    creds.seal(id, KOMIRA_BIND_SESSION)
except e:
    assert_equal(
        String(e),
        "CREDENTIALS_INVALID: seal credential=raw-etl: AwsKeys needs secret=",
    )
assert_true(not creds.is_sealed("raw-etl"))

id = creds.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
creds.set(id, KOMIRA_FIELD_KEY_ID, "AKIDEXAMPLE".as_bytes())
creds.set(id, KOMIRA_FIELD_SECRET, "example-secret".as_bytes())
creds.seal(id, KOMIRA_BIND_SESSION)
assert_true(creds.is_sealed("raw-etl"))
assert_equal(creds.kind_of("raw-etl"), KOMIRA_CRED_AWS_KEYS)
```

A consumer reads a sealed value only through a reveal: the session's
`secret_bindings()` and `secret_store()` are what
`SecretCapability(node_id_of(name, field)).open_connection_for` (in `sdk_exec`)
takes, and the value reaches the consumer as a zeroizing `SecretValue` for the
length of that one call.

**An Arrow stream as a table.** `komira_register_arrow_stream(ctx, name,
stream)` takes a stream the host produced (a pyarrow table or reader, a pandas
frame through pyarrow, any producer of the Arrow C Stream Interface), reads
its schema and every chunk, copies each buffer into a table the session holds,
and registers that table as `name`, found without regard to case. Every query
on the session then reads the copy: the host may free or change what it
exported as soon as the call returns. A stream of no chunk is a table of no
row with the stream's schema.

The library takes the stream. It calls the stream's own `release` exactly
once before it returns, whatever the status, unless `stream` is NULL or
already released (its `release` NULL); the host frees only the struct it
allocated. A name or context refused before the stream is read releases it
without calling `get_schema`.

A second registration of a name replaces the table of that name, of any kind,
as DuckDB's `register` replaces a view of that name; the file registrations
(`komira_register_csv`, `komira_register_json`) still refuse a name the
session holds, this table's too. Refusals are -1 for a NULL `ctx`, -2 for a
NULL `name` or `stream` (the last error `komira_register_arrow_stream: name or
stream is NULL`), and -3 with a last error for an empty name
(`TABLE_NAME_EMPTY: a table name must not be empty`), a released stream
(`from_arrow_c_stream: stream is already released`), a callback of the stream
that fails (`from_arrow_c_stream: get_schema failed (rc=<n>): <the stream's
last error>`, and the same for `get_next`), a column type the import does not
read (`UnsupportedArrowCABIType: ...`, the Null type among them), and a column
of a nested type (list, struct, map) or a union
(`TABLE_TYPE_UNSUPPORTED: column '<c>' has type <t>; only flat columns are
registered`). Nothing is registered or replaced on a refusal.

On values, the call is `register_arrow` over the table the drain built:

```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.table import Table
from so import Session, register_arrow, sql_result
from std.testing import assert_equal

var sb = SchemaBuilder()
sb.add_field(Field(String("k"), ArrowType.INT64, False))
var rows = RecordBatchBuilder.with_capacity(1)
rows.add_column(
    Column.from_primitive(
        PrimitiveArray[DType.int64].from_list([Int64(1), Int64(2), Int64(3)])
    )
)
var session = Session()
register_arrow(session, String("t"), Table.from_batch(rows.build(sb.build())))
var answer = sql_result(session, String("select count(*) as n from T where k > 1"))
assert_equal(answer.batches[0].column_at(0).as_primitive[DType.int64]().get(0), Int64(2))
```

**A source as a table.** `komira_add_sql_binding(ctx, name, source,
source_len, scope)` binds `name` (found without regard to case) to the
protobuf bytes `source[0..source_len]` of a `komira.plan.v1.WireBoundSource`
(`src/plan_proto/bound_source.proto`); `scope` is
`KOMIRA_BIND_SESSION` (1), the only scope there is. The source names its kind
as the `files` case, a Parquet location: a path with no scheme, which binds as
`komira_register_parquet` does (the footer is read at the call, so a missing
or unreadable file is -3 with the reader's message), or an object-store
location: `s3://bucket/key` (`s3a://` too) read with an `AwsKeys` credential
and the source's `region` (and `endpoint`, `addressing`), or
`az://container/blob` (`abfs://`, `abfss://`, and the forms `azure_blob`'s
`parse_azure_url` reads) read with an `AzureKey` or `AzureSas` credential,
whose `ACCOUNT` names the account, or `anonymous` when the location names the
account. The key may be a glob (`*`, `?`, `[...]`, `{a,b}`, one `**`), listed
now. The footers are read now, through the store, so a refused key or a
missing object is -3 with the store's message. Path-style addressing is the
default on an endpoint of the source's own, virtual-hosted on the
provider's; plaintext only for an `http://` endpoint. `komira_sql_stream`
reads the table through the same store, with the value sealed under the
credential's name when the statement starts (`so.store_fs`: one file system per
bound bucket); a credential that no longer fits refuses the statement at step
`bind`. The bytes
carry no secret: the source's access names a credential sealed on the
session beforehand (`komira_credential_add`, `_set`, `_seal`), and the library
reveals its value inside itself when it reads. The bytes are copied before
they are decoded, so `source` and `name` are the caller's again when the call
returns; a `source_len` of 0 with a non-NULL `source` is a source that names
no kind. A second binding of a name replaces the table of that name, of any
kind, as `komira_register_arrow_stream` and `komira_register_parquet` do;
`komira_register_csv` and `komira_register_json` still refuse a taken name.

Refusals are -1 for a NULL `ctx`, -2 for a NULL `name` or `source` (the last
error `komira_add_sql_binding: name or source is NULL`), -5 for a
`source_len` above `KOMIRA_MAX_INPUT_BYTES` (the last error
`komira_add_sql_binding: source_len is above 67108864 bytes`; no byte of
`source` is read), and -3 with a last error at step `bind`, checked in this
order, for a name that is not UTF-8 (`a string argument is not valid UTF-8`),
a `scope` other than 1
(`BIND_SCOPE_UNSUPPORTED: add_sql_binding scope=<scope>: only KOMIRA_BIND_SESSION (1) binds a source`), an empty
name (`TABLE_NAME_EMPTY: a table name must not be empty`), bytes that are not a
`WireBoundSource`
(`BIND_SOURCE_MALFORMED: add_sql_binding name=<name>: the source is not a komira.plan.v1.WireBoundSource`),
bytes that decode but name no kind, an empty buffer among them
(`BIND_SOURCE_MALFORMED: add_sql_binding name=<name>: the source names no kind`),
and a local file the reader refuses. Then the source's own refusals, each
`<CODE>: add_sql_binding name=<name>: <reason>`: `STORAGE_URL_REFUSED` (user
information in a location or endpoint, a query or fragment, an endpoint that is
not `http://` or `https://`, and every scheme but those above: `gs://` is not
read yet), `BIND_SOURCE_UNSUPPORTED` (a signing service, Hive partitioning on
an object store, an endpoint, region or addressing on a local path, a region on
Azure, `anonymous` or an `AwsProfile` on S3), `CREDENTIALS_NOT_FOUND` (an
object-store source naming no credential, or `ambient`, which the library does
not resolve), `CREDENTIAL_KIND_MISMATCH` (a credential of another store, or
one on a local path), `STORAGE_REGION_UNKNOWN` (an S3 source with no region),
`BIND_SCOPE_NOT_A_TABLE` (a location ending in `/`), and
`BIND_STORE_CONFLICT` (a bucket another table of the session reads with
another credential name or other settings: a statement reads each bucket one
way); `CREDENTIAL_UNBOUND` is `SessionCredentials`'s, for a name with no
sealed value. No message holds a credential's value. Nothing is bound or
replaced on a refusal.

On values, the call is `add_sql_binding` over the source's bytes (`so.bindings`).

## Building and testing

```sh
./buck2 build komira//src/so:so       # the package and its tests
./buck2 build komira//src/so:libkomira       # the shared library, behind its gate
```

The library is published only if the gate passes: the exports check, then
twenty drivers (`tests/gate/`) that open it with `RTLD_NOW` and call it as a
foreign host would. Seven cover the skeleton: the version (1011, which is 1.11),
create and free (distinct handles, separate sessions), no symbol beyond the
twenty-eight, a fresh session's empty error, the two-call protocol (zero capacity, one
byte short, exact, larger), a NULL context, and a NULL `out_len`. `gate_error_code_step`
checks that `komira_last_error_code` and `komira_last_error_step` exist and, on a
fresh session, give an empty code and step 0, and that a NULL context is -1 and
step 0. One driver per
new call writes its input file under `$TEST_TMPDIR` and checks a good input,
NULL context (-1), a NULL input (-2 with a last error), a bad file or plan (-3
with the message as the last error) and, for the four calls with an output, the
two-call protocol; a good call after a refusal leaves no error.
`gate_credentials` defines a credential through the three calls and checks each
named refusal word for word, the NULL and length cases, and that `*out_id` is
untouched on a refusal.
`gate_register_csv` and `gate_register_json` register a file they write (the
CSV driver once for each dialect argument), and check a taken name (in any
case, and taken by the other call) and an empty one word for word, the NULL
cases, a missing and an empty file and a path that is not UTF-8, and that a
refused name stays free.
`gate_register_csv_with_skip` registers a file with a note line above its
header at skip 1, and checks the NULL cases, a negative skip (-3 with
`CSV_SKIP_NEGATIVE` word for word, step `bind`, the name left free), a skip
past the last line (-3 with `CSV_SKIP_PAST_END`), and that
`komira_csv_binding_with_skip` at skip 0 answers the bytes of
`komira_csv_binding` and at skip 1 other bytes that name the `skip` param.
`gate_register_arrow_stream` checks the refusals met before any chunk is
read: a released stream (five NULL words) and an empty name or one that is
not UTF-8 are -3 word for word, the NULL cases -1 and -2, and each leaves the
name free; the streams the library drains are the C driver's.
`gate_add_sql_binding` binds a local Parquet file it writes through a
`WireBoundSource` it encodes by hand (0, and again under the same name), and
checks the NULL cases (-1, -2 with the named last error), a `source_len` of 64 MiB
plus one (-5 with its last error), and each -3 word for word with step `bind`
and its code: a scope other than 1, an empty name, a name that is not UTF-8, a
one-byte source, a zero-length source and a missing file; a good call after a
refusal leaves no error.
`exports_exact` makes the twenty-eight names above the whole dynamic symbol table.
On Linux the eleven C owners in the library's closure (async, async_api,
compression, crypto, fs, http_core, libc, metrics, objectstore, parquet_codec,
scan_source) are linked as their own shared libraries (`native_owners`), not
embedded; on macOS arm64 there are none, and the C archives are linked
statically into `libkomira.dylib`. On Linux the nineteenth driver, `gate_native_owners`,
reads the `DT_NEEDED` entries of the library's ELF dynamic section and requires
the SONAME of each of the eleven (`libkomira_<owner>_native.so.1`); an owner
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
read by hand. It is a record of the library as it is now that `so` depends on
`sdk_exec` (a session holds an engine), not a gate: the gates above and `libkomira_install` hold the
exports, the owner SONAMEs, a version of at least 1000 and that every library is
mapped from the prefix. Each `RUNPATH` or `RPATH` entry is one backticked
item; an entry holding colons is one string the loader splits itself. The `RPATH` values of
the Mojo runtime libraries are the vendor's own.

| file | role | size (bytes) | SONAME | RUNPATH | RPATH | highest GLIBC | highest GLIBCXX | highest CXXABI |
|---|---|---|---|---|---|---|---|---|
| `libkomira.so` | target | 3752832 | `libkomira.so` | `$ORIGIN/lib:$ORIGIN` | none | `GLIBC_2.34` | none | none |
| `libkomira_async_api_native.so.1` | owner | 2760 | `libkomira_async_api_native.so.1` | none | none | none | none | none |
| `libkomira_async_rt_native.so.1` | owner | 43992 | `libkomira_async_rt_native.so.1` | none | none | `GLIBC_2.17` | none | none |
| `libkomira_compression_native.so.1` | owner | 244856 | `libkomira_compression_native.so.1` | none | none | `GLIBC_2.34` | none | none |
| `libkomira_crypto_native.so.1` | owner | 3240416 | `libkomira_crypto_native.so.1` | none | none | `GLIBC_2.33` | none | none |
| `libkomira_fs_native.so.1` | owner | 11192 | `libkomira_fs_native.so.1` | none | none | `GLIBC_2.33` | none | none |
| `libkomira_http_core_native.so.1` | owner | 1180024 | `libkomira_http_core_native.so.1` | `$ORIGIN` | none | `GLIBC_2.33` | none | none |
| `libkomira_libc_native.so.1` | owner | 11080 | `libkomira_libc_native.so.1` | none | none | `GLIBC_2.33` | none | none |
| `libkomira_metrics_native.so.1` | owner | 2600 | `libkomira_metrics_native.so.1` | none | none | none | none | none |
| `libkomira_objectstore_native.so.1` | owner | 8472 | `libkomira_objectstore_native.so.1` | none | none | `GLIBC_2.33` | none | none |
| `libkomira_parquet_codec_native.so.1` | owner | 173736 | `libkomira_parquet_codec_native.so.1` | none | none | `GLIBC_2.14` | none | none |
| `libkomira_scan_source_native.so.1` | owner | 2488 | `libkomira_scan_source_native.so.1` | none | none | none | none | none |
| `libAsyncRTRuntimeGlobals.so` | runtime | 685176 | `libAsyncRTRuntimeGlobals.so` | none | `$ORIGIN:$ORIGIN/../lib:$ORIGIN/../_solib_k8/_USupport:$ORIGIN/libAsyncRTRuntimeGlobals.so.runfiles/_main/_solib_k8/_USupport` | `GLIBC_2.35` | `GLIBCXX_3.4.29` | `CXXABI_1.3.9` |
| `libKGENCompilerRTShared.so` | runtime | 1267976 | `libKGENCompilerRTShared.so` | none | `$ORIGIN:$ORIGIN/../lib:$ORIGIN/../_solib_k8/_USupport:$ORIGIN/libKGENCompilerRTShared.so.runfiles/_main/_solib_k8/_USupport:$ORIGIN/../_solib_k8/_UAsyncRT:$ORIGIN/libKGENCompilerRTShared.so.runfiles/_main/_solib_k8/_UAsyncRT` | `GLIBC_2.34` | `GLIBCXX_3.4.30` | `CXXABI_1.3.11` |
| `libMSupportGlobals.so` | runtime | 49296 | `libMSupportGlobals.so` | none | `$ORIGIN:$ORIGIN/../lib` | `GLIBC_2.34` | `GLIBCXX_3.4.14` | `CXXABI_1.3.11` |
| `libgcc_s.so.1` | runtime | 902392 | `libgcc_s.so.1` | none | `$ORIGIN/.` | `GLIBC_2.14` | none | none |
| `libstdc++.so.6` | runtime | 21186008 | `libstdc++.so.6` | none | `$ORIGIN/.` | `GLIBC_2.17` | none | none |

| file | DT_NEEDED, in order |
|---|---|
| `libkomira.so` | `libKGENCompilerRTShared.so`, `libkomira_async_rt_native.so.1`, `libkomira_async_api_native.so.1`, `libkomira_compression_native.so.1`, `libkomira_crypto_native.so.1`, `libkomira_fs_native.so.1`, `libkomira_http_core_native.so.1`, `libkomira_libc_native.so.1`, `libkomira_metrics_native.so.1`, `libkomira_objectstore_native.so.1`, `libkomira_parquet_codec_native.so.1`, `libkomira_scan_source_native.so.1`, `libpthread.so.0`, `libc.so.6` |
| `libkomira_async_api_native.so.1` | none |
| `libkomira_async_rt_native.so.1` | `libpthread.so.0`, `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libkomira_compression_native.so.1` | `libpthread.so.0`, `libc.so.6` |
| `libkomira_crypto_native.so.1` | `libpthread.so.0`, `libc.so.6` |
| `libkomira_fs_native.so.1` | `libpthread.so.0`, `libc.so.6` |
| `libkomira_http_core_native.so.1` | `libkomira_crypto_native.so.1`, `libpthread.so.0`, `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libkomira_libc_native.so.1` | `libpthread.so.0`, `libc.so.6` |
| `libkomira_metrics_native.so.1` | none |
| `libkomira_objectstore_native.so.1` | `libpthread.so.0`, `libc.so.6` |
| `libkomira_parquet_codec_native.so.1` | `libc.so.6` |
| `libkomira_scan_source_native.so.1` | none |
| `libAsyncRTRuntimeGlobals.so` | `libm.so.6`, `libstdc++.so.6`, `libMSupportGlobals.so`, `libgcc_s.so.1`, `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libKGENCompilerRTShared.so` | `libm.so.6`, `libstdc++.so.6`, `libMSupportGlobals.so`, `libAsyncRTRuntimeGlobals.so`, `libgcc_s.so.1`, `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libMSupportGlobals.so` | `libm.so.6`, `libstdc++.so.6`, `libgcc_s.so.1`, `libc.so.6` |
| `libgcc_s.so.1` | `libc.so.6`, `ld-linux-x86-64.so.2` |
| `libstdc++.so.6` | `libm.so.6`, `libdl.so.2`, `libc.so.6`, `ld-linux-x86-64.so.2`, `libgcc_s.so.1` |

| library | role | reached from the target | target's undefined symbols it defines |
|---|---|---|---|
| `libkomira_async_api_native.so.1` | owner | needed (direct) | 1 |
| `libkomira_async_rt_native.so.1` | owner | needed (direct) | 2 |
| `libkomira_compression_native.so.1` | owner | needed (direct) | 1 |
| `libkomira_crypto_native.so.1` | owner | needed (direct) | 0 |
| `libkomira_fs_native.so.1` | owner | needed (direct) | 5 |
| `libkomira_http_core_native.so.1` | owner | needed (direct) | 0 |
| `libkomira_libc_native.so.1` | owner | needed (direct) | 6 |
| `libkomira_metrics_native.so.1` | owner | needed (direct) | 0 |
| `libkomira_objectstore_native.so.1` | owner | needed (direct) | 0 |
| `libkomira_parquet_codec_native.so.1` | owner | needed (direct) | 1 |
| `libkomira_scan_source_native.so.1` | owner | needed (direct) | 0 |
| `libAsyncRTRuntimeGlobals.so` | runtime | needed (through another library) | 0 |
| `libKGENCompilerRTShared.so` | runtime | needed (direct) | 6 |
| `libMSupportGlobals.so` | runtime | needed (through another library) | 0 |
| `libgcc_s.so.1` | runtime | needed (through another library) | 0 |
| `libstdc++.so.6` | runtime | needed (through another library) | 0 |

Owners needed: 11 of 11 (4921616 bytes); declared only: 0.

Wheel tag: `manylinux_2_34` (highest GLIBC of the target and the owners: `GLIBC_2.34`).

Reading it:

- **Owners.** All eleven are `DT_NEEDED` of libkomira (direct), none is embedded, and
  together they weigh 4,921,616 bytes, of which crypto (aws-lc's libcrypto, 3,240,416)
  and http_core (s2n-tls, 1,180,024; itself `DT_NEEDED` on crypto) are most. They are
  needed at load time: the loader refuses a library with a missing `DT_NEEDED`. Six of
  the eleven (async_api, async_rt, compression, fs, libc, parquet_codec) define a symbol
  that libkomira's own undefined symbols name; the other five (crypto, http_core,
  metrics, objectstore, scan_source) are `DT_NEEDED` with no symbol bound to them from
  libkomira itself, so today they are declared and loaded but not called through
  libkomira's own symbol table. They stay in the package because each is a
  `native_owners` entry of the library's closure that the gate requires; a call that
  runs a query reaches them, and then their C is never embedded in libkomira.
- **glibc floor.** The highest `GLIBC_` version of libkomira and the eleven owners is
  2.34 (libkomira and compression), so `manylinux_2_34` is honest for the files the package
  carries. No `GLIBCXX_` or `CXXABI_` version is needed by them. The Python wheel also
  carries the three Mojo runtime libraries (through `[dist]`); `libAsyncRTRuntimeGlobals.so`
  needs `GLIBC_2.35`, one above that floor, and `libKGENCompilerRTShared.so` needs
  `GLIBCXX_3.4.30` and `CXXABI_1.3.11`, so the wheel is tagged `manylinux_2_35` and a host
  needs at least glibc 2.35 (see `docs/design/mojo_runtime_pypi_vs_conda.md`).
- **Mojo runtime.** libkomira is `DT_NEEDED` on `libKGENCompilerRTShared.so` only; that
  library in turn needs `libMSupportGlobals.so` and `libAsyncRTRuntimeGlobals.so`, the
  other two of the three, and those need `libstdc++.so.6` and `libgcc_s.so.1`. Each
  carries its own `RPATH` that includes `$ORIGIN`, so the three are found beside one
  another; libkomira finds them through its `RUNPATH` entry `$ORIGIN/lib`. The `[dist]`
  directory of this target holds them in `lib/` beside the eleven owners, and the Python
  wheel copies it whole; the C++ libraries are not in it, the host provides them.

The `libkomira_install` check loads libkomira from an empty prefix with `RTLD_NOW`
and the probe calls `komira_abi_version`; every library the loader mapped came from the
prefix's `lib/`: the eleven owners, `libKGENCompilerRTShared.so`, and the runtime's
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
`variants/x86-64-v3/`. A second level adds one more `libkomira.so` to a native directory, about
3.4 MiB (derived from the table: 3524608 bytes is 3.36 MiB); the owners and the runtime are shared.

## The header and the golden

`abi/komira.tsv` is the golden of the ABI: the version (1.11), one row per export
with its return type, argument types and the version that added it, and one row
per status code, limit and credential kind, field and scope (`constant`). `komira_abi_golden` checks it on every
build against the `@export abi("C")` functions of `_c_abi.mojo` (names, return and
argument types) and against `status.mojo` (the constants and their values), and
writes `komira.h` from it:

```sh
./buck2 build komira//src/so:komira_abi      # komira.h, only if the golden is exact
```

An export added to `_c_abi.mojo` without a row, a row without an export, a changed
type and a changed or added constant all fail that target, naming the finding. The
header spells the opaque context `komira_handle`, strings `const char *`, the
plan bytes `const uint8_t *` and the stream `struct ArrowArrayStream *`;
`_c_abi.mojo` declares `Handle`, `CStr`, `ConstBytes` and `ArrowStream` for them.
Because a row takes `ArrowStream`, the header also defines `ArrowSchema`,
`ArrowArray` and `ArrowArrayStream` as the Arrow C Data and C Stream interfaces
do, inside the specification's own `ARROW_C_DATA_INTERFACE` and
`ARROW_C_STREAM_INTERFACE` guards, so it can be included beside Arrow's own
headers. The golden does not check that its version was raised when
a row changed: that compares with the previous release.

`tests/c/abi_driver.c` is a C program that includes `komira.h` and nothing of
ours. It opens `./libkomira.so`, binds each of the twenty-eight functions to a pointer
declared with the header's own prototype, and checks the version in the header
against `komira_abi_version()`, the status codes, the input bound
(`KOMIRA_MAX_INPUT_BYTES` plus one is -5), and the last-error round trip (NULL
context, NULL `out_len`, an engine refusal, a buffer one byte short, an exact
buffer), the last error's step and code (`komira_last_error_step`,
`komira_last_error_code`) after a parse error, a bind refusal, an execute
refusal, a refusal with no code, a missing Parquet file (step bind, no code), a
text that is not UTF-8 (step none) and a success, with the two-call protocol and
the NULL rules of the code call, and defines a credential with the header's constants, where one sealed
without its secret is -3 with the named error. It runs SQL through
`komira_sql_stream` and reads each answer through the header's structs as an
Arrow consumer does (the schema, every chunk, the stream released before its
chunks are read): `count(*)` over `tests/fixtures/two_columns.parquet`, staged
beside it (0, a BIGINT never NULL); that file's two columns with no row; a
three-row Parquet file it writes with `COPY` from a CSV file under
`$TEST_TMPDIR` (`Count` 3), registers and filters; a NULL `ctx`, `sql` or
`out`, a parse error, an unknown table and a text that is not UTF-8, each
leaving `*out` byte for byte as written and followed by a good query on the
same context; a text of exactly `KOMIRA_MAX_INPUT_BYTES` bytes that runs and
one of a byte more that is -5; and a stream read whole after its context was
freed. Then it creates contexts with `komira_ctx_new_with_options`: under a
budget of one byte (with one worker, and with the host's count) a `sum` over
the three-row file is -3 with the sink's denial naming `budget 1` at step
`execute`, `*out` untouched and the context still answering; the same `sum`
answers with 0 and 0 and with one worker; and a negative worker count or
budget (-1, `INT64_MIN`) is NULL. It also registers files it writes under `$TEST_TMPDIR` with
`komira_register_csv` (a file with a header, a `|` file and one with
`all_varchar`), `komira_register_csv_with_skip` (a file with a note line above
its header, skipped) and `komira_register_json`, and holds each query by name to the
rows it wrote; a file registered with no header is refused at `lower` when
queried, naming `header=false`; a taken name, an empty one, a missing file and the
NULL cases are refused with their named last error, and the tables first
registered keep answering. Under a run handle: NULL `run`, `done` and `total` are -2 with nothing
written; a fresh handle reads 0 of 0; a run nobody cancels answers and reads
done equal to total, and a second run given the handle doubles both; a handle
cancelled before the call (twice) refuses the run with -6, `*out` untouched
and the `QUERY_CANCELLED` last error word for word, counting its segments and
finishing none; a bind error under it stays -3; the context answers after. A
second thread then runs a query while this one reads its progress until the
run returns: every reading has done at most total and none is below the one
before, and the reading after the run is done equal to total. Last, this
thread cancels a run in flight on a second thread: the answer (the cancel came
after the run's last check) or -6 with `*out` untouched and a
`QUERY_CANCELLED` last error, and the context answers after either; no check
depends on how long the run takes.
It binds tables with `komira_add_sql_binding` (the cases are in
`tests/c/binding_cases.h`, which it includes), each source a `WireBoundSource`
it encodes by hand: the no-row fixture's `count(*)` is 0, binding the same name
to the three-row file replaces it (3, and its rows by name), and binding the
fixture again answers 0; a NULL `ctx` is -1, a NULL `name` or `source` -2, a
length of 64 MiB plus one or `UINT64_MAX` -5, and each -3 (scope 2, an empty
name, a one-byte source, a zero-length source, a missing file, a name that is
not UTF-8) has its named last error, step and code and leaves the earlier table
answering; a good call after them leaves no error.
It runs plans through `komira_plan_stream` (the cases are in `tests/c/plan_cases.h`,
which it includes), each a `WirePlanEnvelope` it encodes by hand (a scan of a Parquet file, the schema bytes
`komira_parquet_schema` answers spliced in), on a second context with no table
registered: the three-row file's scan answers what `SELECT k FROM three`
answers on the first (names, formats, flags, rows and values), and so does the
no-row fixture's against `SELECT i64, s FROM two`; SQL text as plan bytes,
garbage, an envelope of version 3 and exactly 64 MiB of garbage are -3 at
`decode`, a scan of a missing file is -3 at `lower` naming the file, a NULL
`plan` or `out` is -2, and a `plan_len` of 64 MiB plus one and `UINT64_MAX` are
-5 with a 3-byte buffer unread, each leaving `*out` as written and followed by
a good plan on the same context; a NULL `ctx` is -1; and a plan's stream is read
whole after its context was freed. And it is a producer of Arrow C streams, in
C, whose callbacks count the library's releases: a stream of two chunks
registered with `komira_register_arrow_stream` answers a sort, filters, an
aggregate and a join with a registered CSV file after the producer overwrote
and freed its buffers, with the stream, its schema and each chunk released
once; a stream of no chunk keeps its schema; a second registration replaces
a table (a CSV one too) and `komira_register_csv` refuses a name it holds; a
failing `get_schema`, a failing `get_next` after one chunk and a Null-type
column are refused word for word with the stream released once and the table
under the name kept; an empty or NULL name and a NULL context release the
stream without reading it. It is built by zig cc and run against the
published library:

```sh
./buck2 build komira//src/so:c_abi_check     # exit 0 of the driver, or red
```

The header is not part of the library's conda package yet; that waits on the
packaging change that lists it.

## What an abort does to the host

A raise inside the library is a value: every export catches it and returns a
status (`KOMIRA_ERR_ENGINE` with the message as the last error), and no raise
crosses the boundary. An `abort()`, a failed `debug_assert`, a fault, stack
exhaustion or an out-of-memory kill is not a value. Mojo has no unwinding, so
nothing in the library can turn one into a status: it ends the host process
(the Python interpreter, the Node process) at once. The library installs no
signal handler and never `longjmp`s: a handler that jumped back into the export
would leave other engine threads holding locks over half-written state, skip
Mojo destructors, and replace the host's own handler (Python's `faulthandler`,
Node's).

What the library does instead is refuse, before running, every input known to
reach one, so that it comes back as a status:

- A statement nested more than 100 levels deep (parentheses, prefix operators,
  function calls, `CASE`, subqueries, derived tables; `src/sql/README.md` lists
  what counts as a level) is `parse: SQL syntax error: the statement nests
  deeper than 100 levels at line <L>, column <C>`, where the text stopped
  parsing. The parser recursed once per level on the
  caller's stack, so a deep enough text exhausted it.
- `lpad`, `rpad` and `repeat` whose value for one row would be over 64 MiB
  (`STRING_FN_N_REPEAT_MAX_BYTES`) are refused by name before anything is
  allocated.
- libzstd, libz and liblz4, which the codec packages open by soname at first
  use in an initializer that cannot raise, are opened first by a probe that
  can, at the start of every call that can reach a codec (the Parquet, CSV
  and JSON register and describe calls, `komira_sql_stream`,
  `komira_sql_stream_run` and `komira_plan_stream`;
  `komira_register_arrow_stream` reads no file and is not probed). A missing library is `compression: cannot load
  <soname>: <the loader's error>`, not an abort in the middle of a query.

`tests/c/abort_driver.c` sends each of these inputs from a C host, on its main
thread, and requires the status and the reason as the last error, `*out`
untouched, and a good query on the same context afterwards. Each form nested to
exactly the limit still runs, except nested scalar subqueries, which the
optimizer refuses by name:

```sh
./buck2 build komira//src/so:abort_check     # exit 0 of the driver, or red
```

What is left ends the host process, and the bindings say so. The library is
built at the compiler's default assert level (`safe`): the `debug_assert`s
declared `assert_mode="safe"` are kept and abort when they fail. The rest of the
abort sites in the library's closure and the inputs still known to end the
process are listed, each with why, in §8 of
[docs/design/libkomira_run_abi.md](https://github.com/komira-ai/komira/blob/main/docs/design/libkomira_run_abi.md).

## Not done

No release-over-release version check and no packaged header yet; the session
holds an engine, and `komira_sql_stream` runs SQL on it (cancelled and
watched through a run handle with `komira_sql_stream_run`) and
`komira_plan_stream` a plan, and writes it to a file when its envelope carries a
write target, but no call runs a UDF yet (the plan door refuses an envelope
with UDFs); no session
options beyond the worker count and the memory budget (no spill directory); the one language binding is the Node addon ([`node/`](https://github.com/komira-ai/komira/blob/main/node/README.md)).
The calls that run a query, ported from the earlier SDK, their result as an Arrow
C stream, and the abort-prone paths the library does not refuse yet are described in
[docs/design/libkomira_run_abi.md](https://github.com/komira-ai/komira/blob/main/docs/design/libkomira_run_abi.md).
