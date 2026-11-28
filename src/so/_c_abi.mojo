# =============================================================================
# FFI-BOUNDARY: the C ABI of libkomira, the one file of so that holds
# pointers.
# =============================================================================
# Twenty-eight `@export abi("C")` functions are the library's whole surface today. Their C
# prototypes are komira.h, which `//src/so:komira_abi` makes from the golden `abi/komira.tsv`
# (one row per export, with its types and the version that added it) and builds only while this
# file's exports are exactly the golden's rows; `src/so/README.md` lists them in prose.
#
# Ownership. `komira_ctx_new` (and `_with_options`) creates a `Session` (the last error and the
# engine, whose workers start here) in an `OwnedPointer`, relinquishes its free (`unsafe_leak`)
# and hands the address out as `void *`; when the engine does not start it returns NULL,
# allocates nothing and drops the message. The caller owns the handle until `komira_ctx_free`,
# which rebuilds the one `OwnedPointer` and destroys the session, stopping its workers. Freeing
# twice, or using a handle after `komira_ctx_free`, is undefined, as for `free(3)`; freeing NULL
# does nothing. A run handle (`komira_run_new`) is a `RunControl` (a cancel token and a progress
# counter) held the same way until `komira_run_free`. Unlike a context it is used from several
# threads at once: `komira_run_cancel` and `komira_run_progress` may run while
# `komira_sql_stream_run` given the same handle runs on another. They touch only atomic cells
# and the token's shared slot (written before the flag), and the run works on a second handle of
# its own (`share`), so the caller's `RunControl` is never written while another thread reads
# it. A run handle is freed only once no call given it is running. Every other pointer is the
# caller's: this library reads or writes it during the call and keeps none.
#
# The Arrow stream. `komira_sql_stream` and `komira_plan_stream` fill the caller's `struct
# ArrowArrayStream` only on `KOMIRA_OK`; otherwise it is left as the caller wrote it. Then the
# caller owns the stream and calls its `release` once; the stream owns the answer's batches
# (`arrow_ipc.build_record_batch_stream`) and no reference to the session, so `komira_ctx_free`
# may come first. Its callbacks are code of this library, which must stay loaded until every
# stream from it is released. `komira_register_arrow_stream` copies a caller's stream into a
# table the session holds and calls its `release` once before it returns, whatever the status
# (unless NULL or released); the caller frees the struct.
#
# Errors and inputs (src/so/README.md states them in full, with the session options, the
# two-call output protocol, the error's code and step and the credential values). A call returns
# `KOMIRA_OK` (0) or a negative `KOMIRA_ERR_*` code (status.mojo); the source and render calls
# clear the last error first and store the engine's message on `KOMIRA_ERR_ENGINE`. A `char *`
# is copied, and refused unless UTF-8, before use; byte inputs (`ptr[0..len]`) are refused above
# `KOMIRA_MAX_INPUT_BYTES` before any byte is read, and copied in full before decoding.
#
# Pointer types. Only the `comptime` aliases below name a wildcard origin: a `void *` that lives
# in the host between calls has no Mojo origin, and the Mojo side takes no pointer from the host
# except through them.
# =============================================================================

from std.memory import OwnedPointer, unsafe_memcpy

from arrow_ipc.c_data_stream import CArrowArrayStream, build_record_batch_stream, consumer_release_c_stream
from arrow_ipc.c_stream_table import drain_record_batch_stream_table

from so.bindings import add_sql_binding
from so.session import Session, session_options, try_new_session
from sdk_exec.run_control import RunControl
from so.sources import (
    check_table_name,
    csv_binding_bytes,
    is_cancelled_error,
    json_binding_bytes,
    parquet_schema_bytes,
    plan_render_text,
    plan_result,
    register_arrow,
    register_csv,
    register_json,
    register_parquet,
    sql_result,
)
from so.status import (
    KOMIRA_ERR_CANCELLED,
    KOMIRA_ERR_ENGINE,
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_ERR_TOO_LARGE,
    KOMIRA_MAX_INPUT_BYTES,
    KOMIRA_OK,
    KOMIRA_STEP_BIND,
    KOMIRA_STEP_NONE,
    abi_version,
    buffer_status,
    input_length_status,
)

# `Handle`, `CStr`, `ConstBytes` and `ArrowStream` are the names the ABI golden (abi/komira.tsv)
# knows: the header spells them `komira_handle`, `const char *`, `const uint8_t *` and `struct
# ArrowArrayStream *`, and the golden check refuses a `CStr` or `ConstBytes` that is not a pointer
# to `UInt8`, and an `ArrowStream` that is not a pointer to `CArrowArrayStream`, the Mojo struct of
# the Arrow C stream's layout. The exported signatures spell every other pointer in full.
# SAFETY: `void *`, the context handle: an address returned by `komira_ctx_new`, valid until
# `komira_ctx_free`; and the run handle, returned by `komira_run_new`, valid until
# `komira_run_free`. The golden knows one opaque handle type, so both are `komira_handle`.
comptime Handle = UnsafePointer[NoneType, MutUntrackedOrigin]
# SAFETY: `uint8_t *`, a caller-owned output buffer with its capacity beside it.
comptime _Bytes = UnsafePointer[UInt8, MutUntrackedOrigin]
# SAFETY: `uint64_t *`, one caller-owned output slot.
comptime _Len = UnsafePointer[UInt64, MutUntrackedOrigin]
# SAFETY: `const char *`, a NUL-terminated string the caller keeps alive for the call; it is
# copied into a `String` before any use.
comptime CStr = UnsafePointer[UInt8, MutUntrackedOrigin]
# SAFETY: `const uint8_t *`, the bytes of `komira_plan_render`, `komira_plan_stream`,
# `komira_add_sql_binding` and `komira_credential_set`: read for their length argument, copied in
# full, never written.
comptime ConstBytes = UnsafePointer[UInt8, MutUntrackedOrigin]
# SAFETY: `struct ArrowArrayStream *`, a stream the caller allocated. As an output
# (`komira_sql_stream`, `komira_plan_stream`) it is never read, and written once, whole, only on
# `KOMIRA_OK`; then the caller owns what it holds. As `komira_register_arrow_stream`'s input it is
# the caller's live stream, drained and released during the call and kept nowhere.
comptime ArrowStream = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]


@always_inline
def _null_handle() -> Handle:
    """The NULL context handle, what `komira_ctx_new` returns on failure."""
    # SAFETY: the stdlib has no null pointer constructor and the tree bans `unsafe_from_address=`.
    # `Optional[UnsafePointer[...]]` is layout-compatible with the bare pointer and `None` is the
    # all-zero bit pattern, so reading the `None` slot as a `Handle` gives NULL. The origin is the
    # handle's own (`MutUntrackedOrigin`, the host's `void *`); the value is only returned to the
    # caller and never dereferenced.
    var none: Optional[Handle] = None
    return UnsafePointer(to=none).bitcast[Handle]()[]


@always_inline
def _session(ctx: Handle) -> UnsafePointer[Session, MutUntrackedOrigin]:
    """The session behind a non-NULL handle."""
    # SAFETY: `ctx` was returned by `komira_ctx_new` and has not been passed to `komira_ctx_free`
    # (the handle's contract); every caller tests for NULL first. The slot holds one live `Session`.
    return ctx.bitcast[Session]()


@export
def komira_abi_version() abi("C") -> Int32:
    """The ABI version as `major * 1000 + minor`. Never fails."""
    return abi_version()


@export
def komira_ctx_new() abi("C") -> Handle:
    """Create a session and return its handle. The caller frees it with
    `komira_ctx_free`. NULL when the session's engine does not start."""
    var session = try_new_session()
    if not session:
        return _null_handle()
    return _leak_session(session.take())


@export
def komira_ctx_new_with_options(
    worker_count: Int64, memory_budget_bytes: Int64
) abi("C") -> Handle:
    """Create a session whose engine runs `worker_count` workers within
    `memory_budget_bytes`, and return its handle; the caller frees it with
    `komira_ctx_free`.

    0 for either is the host's own value (`komira_ctx_new` is both 0). NULL
    when the engine does not start: a negative worker count or budget is
    refused, and so is a host the engine cannot start on. A query whose sinks
    need more than the budget is refused at step `execute`, naming the sink and
    the budget, as `komira_sql_stream`'s `KOMIRA_ERR_ENGINE`.
    """
    var session = try_new_session(
        session_options(worker_count, memory_budget_bytes)
    )
    if not session:
        return _null_handle()
    return _leak_session(session.take())


def _leak_session(var session: Session) -> Handle:
    """Move `session` to the heap and hand its address out as a handle."""
    var owned = OwnedPointer[Session](session^)
    # SAFETY: `unsafe_leak` relinquishes the OwnedPointer's free, so the only owner of the
    # allocation from here on is whoever holds the returned address; `komira_ctx_free` rebuilds
    # the single OwnedPointer over it.
    return owned^.unsafe_take_allocation().unsafe_leak().bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()


@export
def komira_ctx_free(ctx: Handle) abi("C"):
    """Destroy a session created by `komira_ctx_new`. NULL does nothing."""
    if Int(ctx) == 0:
        return
    # SAFETY: `ctx` is the allocation `komira_ctx_new` leaked from its OwnedPointer and nothing
    # else owns it, so this OwnedPointer is the single owner: it moves the session out and frees
    # the slot once.
    var owned = OwnedPointer[Session](unsafe_from_raw_pointer=_session(ctx))
    var session = owned^.into_inner()
    _ = session^


def _copy_error_field(
    session: UnsafePointer[Session, MutUntrackedOrigin],
    call: String,
    text: String,
    out_buf: _Bytes,
    out_cap: UInt64,
    out_len: _Len,
) -> Int32:
    """Writes `text` (the error's text or code) by the two-call protocol; a
    NULL argument is refused in the name of the export `call`."""
    if Int(out_len) == 0:
        session[].set_error(call + String(": out_len is NULL"))
        return KOMIRA_ERR_NULL_ARG
    return _emit(session, text.as_bytes(), out_buf, out_cap, out_len, call)


@export
def komira_last_error(
    ctx: Handle, out_buf: UnsafePointer[UInt8, MutUntrackedOrigin], out_cap: UInt64,
    out_len: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Copy the session's last error text into `out_buf` (two-call protocol).

    Returns `KOMIRA_ERR_NULL_CTX` for a NULL `ctx`, `KOMIRA_ERR_NULL_ARG` for a
    NULL `out_len` (or a NULL `out_buf` when text is to be written),
    `KOMIRA_ERR_BUFFER_TOO_SMALL` with `*out_len` set when `out_cap` is below
    the text length, and `KOMIRA_OK` otherwise. A fresh session's text is
    empty.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    var text = session[].last_error()
    return _copy_error_field(session, "komira_last_error", text, out_buf, out_cap, out_len)


@export
def komira_last_error_code(
    ctx: Handle, out_buf: UnsafePointer[UInt8, MutUntrackedOrigin], out_cap: UInt64,
    out_len: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Copy the last error's code (`SQL_SYNTAX_ERROR`; empty when it has
    none) into `out_buf`, as `komira_last_error` copies the text."""
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    var code = session[].last_error_code()
    return _copy_error_field(session, "komira_last_error_code", code, out_buf, out_cap, out_len)


@export
def komira_last_error_step(ctx: Handle) abi("C") -> Int32:
    """The `KOMIRA_STEP_*` of the last error; `KOMIRA_STEP_NONE` for a NULL
    `ctx`, no error, or an error with no step. Never fails or clears."""
    if Int(ctx) == 0:
        return KOMIRA_STEP_NONE
    return _session(ctx)[].last_error_step()


def _c_string(text: CStr) raises -> String:
    """A copy of the NUL-terminated string at `text`; raises if the bytes are
    not valid UTF-8."""
    var bytes = List[UInt8]()
    var i = 0
    while True:
        # SAFETY: `text` is non-NULL (every caller tests first) and points at a
        # NUL-terminated string the caller keeps alive for the call; this reads
        # up to and including the terminator and keeps no reference.
        var b = text[i]
        if b == 0:
            break
        bytes.append(b)
        i += 1
    try:
        return String(from_utf8=Span(bytes))
    except:
        raise Error("a string argument is not valid UTF-8")


def _c_text_length(text: CStr) -> Optional[Int]:
    """The byte count of the NUL-terminated string at `text`, or None when
    none of its first `KOMIRA_MAX_INPUT_BYTES + 1` bytes is the NUL (a text
    longer than the bound). No byte past the NUL or past that bound is read."""
    var limit = Int(KOMIRA_MAX_INPUT_BYTES)
    var i = 0
    while i <= limit:
        # SAFETY: `text` is non-NULL (every caller tests first) and points at
        # a NUL-terminated string the caller keeps alive for the call; every
        # byte before its NUL is readable, and this stops at the NUL, so it
        # never reads past the string.
        if text[i] == 0:
            return i
        i += 1
    return None


def _copy_in(plan: _Bytes, plan_len: UInt64) -> List[UInt8]:
    """A copy of `plan[0..plan_len]` (plan or source bytes, a credential value or the
    SQL text before its NUL); `plan_len` is at most `KOMIRA_MAX_INPUT_BYTES` (the
    caller tests with `input_length_status` or `_c_text_length`)."""
    var n = Int(plan_len)
    var bytes = List[UInt8](length=n, fill=0)
    if n > 0:
        # SAFETY: `plan` is non-NULL (every caller tests first) and holds at
        # least `plan_len` readable bytes by the caller's contract; the copy
        # owns its bytes, so nothing downstream borrows caller memory.
        unsafe_memcpy(dest=bytes.unsafe_ptr(), src=plan, count=n)
    return bytes^


def _emit(
    session: UnsafePointer[Session, MutUntrackedOrigin],
    data: Span[UInt8, _],
    out_buf: _Bytes,
    out_cap: UInt64,
    out_len: _Len,
    call: String = "",
) -> Int32:
    """The write half of the two-call protocol for the source and render calls
    (and, through `_copy_error_field`, the last-error calls): stores the byte
    count in `*out_len`, then returns `KOMIRA_ERR_BUFFER_TOO_SMALL` (writing
    nothing) when `out_cap` is below it. A NULL `out_buf` is refused only when
    there are bytes to write, in the name of the export `call` when one is
    given."""
    var n = len(data)
    # SAFETY: `out_len` is non-NULL (every caller tests first), a caller-owned slot.
    out_len[0] = UInt64(n)
    var status = buffer_status(n, out_cap)
    if status != KOMIRA_OK:
        return status
    if n == 0:
        return KOMIRA_OK
    if Int(out_buf) == 0:
        var prefix = (call + ": ") if call.byte_length() > 0 else String("")
        session[].set_error(prefix + "out_buf is NULL")
        return KOMIRA_ERR_NULL_ARG
    # SAFETY: `out_buf` holds at least `out_cap >= len(data)` bytes by the
    # caller's contract, just tested by `buffer_status`; `data` is alive for
    # the copy and does not overlap the caller's buffer.
    unsafe_memcpy(dest=out_buf, src=data.unsafe_ptr(), count=n)
    return KOMIRA_OK


@export
def komira_register_parquet(ctx: Handle, name: CStr, path: CStr) abi("C") -> Int32:
    """Register the Parquet file at `path` in the session under `name`.

    The footer is read at registration, so a missing or unreadable file is
    `KOMIRA_ERR_ENGINE` here, with the reader's message as the last error.
    Returns `KOMIRA_ERR_NULL_CTX` for a NULL `ctx` and `KOMIRA_ERR_NULL_ARG`
    for a NULL `name` or `path`.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(name) == 0 or Int(path) == 0:
        session[].set_error(String("komira_register_parquet: name or path is NULL"))
        return KOMIRA_ERR_NULL_ARG
    try:
        register_parquet(session[], _c_string(name), _c_string(path))
        return KOMIRA_OK
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


@export
def komira_parquet_schema(
    ctx: Handle, path: CStr, out_buf: UnsafePointer[UInt8, MutUntrackedOrigin], out_cap: UInt64,
    out_len: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Write the Arrow schema of the Parquet file at `path` as `WireSchema`
    bytes (two-call protocol).

    The bytes are what a plan author splices into a Parquet scan. Returns
    `KOMIRA_ERR_NULL_CTX` for a NULL `ctx`, `KOMIRA_ERR_NULL_ARG` for a NULL
    `path` or `out_len`, `KOMIRA_ERR_ENGINE` for a file that cannot be read,
    and `KOMIRA_ERR_BUFFER_TOO_SMALL` with `*out_len` set when `out_cap` is
    below the length.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(path) == 0 or Int(out_len) == 0:
        session[].set_error(String("komira_parquet_schema: path or out_len is NULL"))
        return KOMIRA_ERR_NULL_ARG
    try:
        var bytes = parquet_schema_bytes(_c_string(path))
        return _emit(session, Span(bytes), out_buf, out_cap, out_len)
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


def _csv_binding_call(
    ctx: Handle, op: String, path: CStr, delimiter: UInt8, has_header: Int32,
    all_varchar: Int32, skip: Int64, out_buf: _Bytes, out_cap: UInt64, out_len: _Len,
) -> Int32:
    """The body of `komira_csv_binding` and `komira_csv_binding_with_skip`;
    `op` names the export in the NULL-argument refusal."""
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(path) == 0 or Int(out_len) == 0:
        session[].set_error(op + ": path or out_len is NULL")
        return KOMIRA_ERR_NULL_ARG
    try:
        var bytes = csv_binding_bytes(
            _c_string(path), delimiter, Int(has_header) != 0, Int(all_varchar) != 0, Int(skip)
        )
        return _emit(session, Span(bytes), out_buf, out_cap, out_len)
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


@export
def komira_csv_binding(
    ctx: Handle, path: CStr, delimiter: UInt8, has_header: Int32, all_varchar: Int32,
    out_buf: UnsafePointer[UInt8, MutUntrackedOrigin], out_cap: UInt64,
    out_len: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Write the `WireScanBinding` of the CSV file at `path` (two-call
    protocol).

    The schema is inferred from a bounded prefix of an uncompressed file; a
    compressed file is read whole. `has_header` and `all_varchar` are
    `int32_t` and any non-zero value is true. Errors are those of
    `komira_parquet_schema`.
    """
    return _csv_binding_call(
        ctx, "komira_csv_binding", path, delimiter, has_header, all_varchar, 0,
        out_buf, out_cap, out_len,
    )


@export
def komira_csv_binding_with_skip(
    ctx: Handle, path: CStr, delimiter: UInt8, has_header: Int32, all_varchar: Int32,
    skip: Int64, out_buf: UnsafePointer[UInt8, MutUntrackedOrigin], out_cap: UInt64,
    out_len: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """`komira_csv_binding` with the first `skip` lines skipped (ABI 1.11; 0 is
    `komira_csv_binding`). A negative `skip` (`CSV_SKIP_NEGATIVE`) or one that
    leaves no line (`CSV_SKIP_PAST_END`) is `KOMIRA_ERR_ENGINE` at step bind."""
    return _csv_binding_call(
        ctx, "komira_csv_binding_with_skip", path, delimiter, has_header, all_varchar,
        skip, out_buf, out_cap, out_len,
    )


@export
def komira_json_binding(
    ctx: Handle, path: CStr, out_buf: UnsafePointer[UInt8, MutUntrackedOrigin], out_cap: UInt64,
    out_len: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Write the `WireScanBinding` of the newline-delimited JSON file at
    `path` (two-call protocol). Errors are those of `komira_parquet_schema`.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(path) == 0 or Int(out_len) == 0:
        session[].set_error(String("komira_json_binding: path or out_len is NULL"))
        return KOMIRA_ERR_NULL_ARG
    try:
        var bytes = json_binding_bytes(_c_string(path))
        return _emit(session, Span(bytes), out_buf, out_cap, out_len)
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


@export
def komira_plan_render(
    ctx: Handle,
    plan: ConstBytes,
    plan_len: UInt64,
    out_buf: UnsafePointer[UInt8, MutUntrackedOrigin],
    out_cap: UInt64,
    out_len: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Decode the serialized plan `plan[0..plan_len]` and write its text
    (two-call protocol). The plan is not run.

    The text is UTF-8, not NUL-terminated, and is the plan as authored, before
    any optimizer rule. A malformed or hostile plan is refused by the decoder
    as `KOMIRA_ERR_ENGINE`. Returns `KOMIRA_ERR_NULL_CTX` for a NULL `ctx` and
    `KOMIRA_ERR_NULL_ARG` for a NULL `plan` or `out_len`, and
    `KOMIRA_ERR_TOO_LARGE` for a `plan_len` above `KOMIRA_MAX_INPUT_BYTES`
    (64 MiB), checked before the plan is read.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(plan) == 0 or Int(out_len) == 0:
        session[].set_error(String("komira_plan_render: plan or out_len is NULL"))
        return KOMIRA_ERR_NULL_ARG
    if input_length_status(plan_len) != KOMIRA_OK:
        session[].set_error(
            String("komira_plan_render: plan_len is above ")
            + String(KOMIRA_MAX_INPUT_BYTES)
            + String(" bytes")
        )
        return KOMIRA_ERR_TOO_LARGE
    try:
        var text = plan_render_text(_copy_in(plan, plan_len))
        return _emit(session, text.as_bytes(), out_buf, out_cap, out_len)
    except e:
        session[].set_error(String(e))
        return KOMIRA_ERR_ENGINE


@export
def komira_credential_add(
    ctx: Handle,
    kind: Int32,
    name: CStr,
    # SAFETY: `int32_t *`, one caller-owned slot, written only on KOMIRA_OK.
    out_id: UnsafePointer[Int32, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Open a definition of the credential `name` of kind `kind` (a
    `KOMIRA_CRED_*` constant) and store its id in `*out_id`.

    Returns `KOMIRA_ERR_NULL_CTX` for a NULL `ctx`, `KOMIRA_ERR_NULL_ARG` for a
    NULL `name` or `out_id`, and `KOMIRA_ERR_ENGINE` with a
    `CREDENTIALS_INVALID` last error for an unknown kind, a name outside the
    grammar, or `ambient` or `anonymous`. `*out_id` is written only on
    `KOMIRA_OK`.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(name) == 0 or Int(out_id) == 0:
        session[].set_error(String("komira_credential_add: name or out_id is NULL"))
        return KOMIRA_ERR_NULL_ARG
    var text: String
    try:
        text = _c_string(name)
    except:
        session[].set_error(
            String("CREDENTIALS_INVALID: add credential: the name is not UTF-8"),
            KOMIRA_STEP_BIND,
        )
        return KOMIRA_ERR_ENGINE
    try:
        var id = session[].credentials.add(kind, text)
        # SAFETY: `out_id` is non-NULL (tested above) and is one caller-owned
        # `int32_t` slot.
        out_id[0] = id
        return KOMIRA_OK
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


@export
def komira_credential_set(
    ctx: Handle,
    id: Int32,
    field: Int32,
    value: ConstBytes,
    value_len: UInt64,
) abi("C") -> Int32:
    """Set the field `field` (a `KOMIRA_FIELD_*` constant) of the open
    definition `id` to `value[0..value_len]`.

    The value is read in place and copied only once it is admitted, before
    the call returns; it is never echoed. Returns
    `KOMIRA_ERR_NULL_CTX` for a NULL `ctx`, `KOMIRA_ERR_NULL_ARG` for a NULL
    `value` with a non-zero `value_len`, `KOMIRA_ERR_TOO_LARGE` for a
    `value_len` above `KOMIRA_MAX_INPUT_BYTES` (nothing is read), and
    `KOMIRA_ERR_ENGINE` with a `CREDENTIALS_INVALID` last error when `id` is not
    open or the field or value does not fit the kind; that refusal discards
    the definition.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(value) == 0 and value_len != 0:
        session[].set_error(String("komira_credential_set: value is NULL and value_len is not 0"))
        return KOMIRA_ERR_NULL_ARG
    if input_length_status(value_len) != KOMIRA_OK:
        session[].set_error(
            String("komira_credential_set: value_len is above ")
            + String(KOMIRA_MAX_INPUT_BYTES)
            + String(" bytes")
        )
        return KOMIRA_ERR_TOO_LARGE
    var n = Int(value_len)
    var empty = List[UInt8]()
    try:
        if n == 0:
            session[].credentials.set(id, field, Span(empty))
        else:
            # SAFETY: `value` is non-NULL (a NULL with a non-zero length is
            # refused above) and holds `value_len` readable bytes by the
            # caller's contract; `value_len` is at most KOMIRA_MAX_INPUT_BYTES.
            # The span is read during this call only: `set` copies what it
            # keeps, and nothing holds the span after it returns.
            session[].credentials.set(
                id, field, Span[UInt8, MutUntrackedOrigin](unsafe_ptr=value, length=n)
            )
        return KOMIRA_OK
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


@export
def komira_credential_seal(ctx: Handle, id: Int32, scope: Int32) abi("C") -> Int32:
    """Seal the open definition `id` in `scope` (`KOMIRA_BIND_SESSION`): it
    becomes the session's value of its name, and `id` is closed.

    Returns `KOMIRA_ERR_NULL_CTX` for a NULL `ctx` and `KOMIRA_ERR_ENGINE` with
    a `CREDENTIALS_INVALID` last error when `id` is not open, `scope` is not
    `KOMIRA_BIND_SESSION`, or a field the kind needs is not set (the error
    names the field); that refusal discards the definition.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    try:
        session[].credentials.seal(id, scope)
        return KOMIRA_OK
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


def _sql_stream(
    session: UnsafePointer[Session, MutUntrackedOrigin],
    call: String,
    sql: CStr,
    control: RunControl,
    out_stream: ArrowStream,
) -> Int32:
    """What `komira_sql_stream` and `komira_sql_stream_run` do once the
    context, and the run handle of the second, are known to be non-NULL:
    bound and copy the SQL text, run it under `control` and write the stream.
    `call` names the export in its own refusals. A run that `control`'s cancel
    stopped is `KOMIRA_ERR_CANCELLED`, every other refusal of the engine
    `KOMIRA_ERR_ENGINE`."""
    var n = _c_text_length(sql)
    if not n:
        session[].set_error(
            call
            + String(": sql is above ")
            + String(KOMIRA_MAX_INPUT_BYTES)
            + String(" bytes")
        )
        return KOMIRA_ERR_TOO_LARGE
    var bytes = _copy_in(sql, UInt64(n.value()))
    var text: String
    try:
        text = String(from_utf8=Span(bytes))
    except:
        session[].set_error(call + String(": the SQL text is not valid UTF-8"))
        return KOMIRA_ERR_ENGINE
    try:
        var result = sql_result(session[], text, control)
        # Nothing is written to `*out_stream` before this call, and it writes the
        # stream whole once its own checks have passed.
        build_record_batch_stream(result.take_batches(), result.take_schema(), out_stream)
        return KOMIRA_OK
    except e:
        var message = String(e)
        var status = KOMIRA_ERR_CANCELLED if is_cancelled_error(message) else KOMIRA_ERR_ENGINE
        # `sql_result` records an engine refusal with its step and code; one
        # with nothing held is the export check's, with neither.
        if not session[].has_error():
            session[].set_error(message^)
        return status


@export
def komira_sql_stream(ctx: Handle, sql: CStr, out_stream: ArrowStream) abi("C") -> Int32:
    """Run the SQL statement `sql` on the session and fill the caller's
    `struct ArrowArrayStream` at `out_stream` with its answer.

    The statement reads the tables registered on the session; a `COPY ... TO`
    a local file answers one row, the BIGINT `Count`. The answer is computed
    before the call returns. `*out_stream` is written only on `KOMIRA_OK`, and the
    caller then owns the stream and releases it once; it needs neither the
    session nor the handle, so `komira_ctx_free` may come first. Returns
    `KOMIRA_ERR_NULL_CTX` for a NULL `ctx`, `KOMIRA_ERR_NULL_ARG` for a NULL
    `sql` or `out_stream`, `KOMIRA_ERR_TOO_LARGE` for a text whose NUL is not among
    its first `KOMIRA_MAX_INPUT_BYTES + 1` bytes (nothing past that is read),
    and `KOMIRA_ERR_ENGINE` for a text that is not UTF-8 and for every engine
    refusal, with the last error `<step>: <reason>` (`parse`, `bind`,
    `optimize`, `lower` or `execute`; for `parse`, `<reason> at line <L>,
    column <C>`, both from 1, where the text stopped parsing) or the export's error naming a column
    the stream cannot carry. The session stays usable after any refusal.
    Nothing can cancel the run: `komira_sql_stream_run` is the call that takes
    a run handle.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(sql) == 0 or Int(out_stream) == 0:
        session[].set_error(String("komira_sql_stream: sql or out is NULL"))
        return KOMIRA_ERR_NULL_ARG
    return _sql_stream(
        session, String("komira_sql_stream"), sql, RunControl(), out_stream
    )


@always_inline
def _run(run: Handle) -> UnsafePointer[RunControl, MutUntrackedOrigin]:
    """The run control behind a non-NULL run handle."""
    # SAFETY: `run` was returned by `komira_run_new` and has not been passed to `komira_run_free`
    # (the handle's contract); every caller tests for NULL first. The slot holds one live
    # `RunControl`.
    return run.bitcast[RunControl]()


@export
def komira_run_new() abi("C") -> Handle:
    """Create a run handle: an uncancelled cancel token and a progress counter at
    0 of 0 segments. The caller frees it with `komira_run_free`. Never NULL."""
    var owned = OwnedPointer[RunControl](RunControl())
    # SAFETY: `unsafe_leak` relinquishes the OwnedPointer's free, so the only owner of the
    # allocation from here on is whoever holds the returned address; `komira_run_free` rebuilds
    # the single OwnedPointer over it.
    return owned^.unsafe_take_allocation().unsafe_leak().bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()


@export
def komira_run_free(run: Handle) abi("C"):
    """Destroy a run handle from `komira_run_new`. NULL does nothing. No call
    given the handle may still be running."""
    if Int(run) == 0:
        return
    # SAFETY: `run` is the allocation `komira_run_new` leaked from its OwnedPointer and nothing
    # else owns it (a run given the handle holds its own clone of the token and counts, and has
    # returned), so this OwnedPointer is the single owner: it moves the control out and frees the
    # slot once.
    var owned = OwnedPointer[RunControl](unsafe_from_raw_pointer=_run(run))
    var control = owned^.into_inner()
    _ = control^


@export
def komira_run_cancel(run: Handle) abi("C") -> Int32:
    """Cancel every run given `run`, the one in flight and every later one.
    Callable from any thread, while a call given `run` is running on
    another; a second cancel does nothing. Returns `KOMIRA_ERR_NULL_ARG` for a
    NULL `run` and `KOMIRA_OK` otherwise; it touches no context."""
    if Int(run) == 0:
        return KOMIRA_ERR_NULL_ARG
    # SAFETY: `run` is a live run handle (tested non-NULL; the caller frees it only after every
    # call given it returned). `cancel` writes only through the token's shared slot, claimed by an
    # atomic cell so that one caller writes, and reads no field another thread writes.
    _run(run)[].cancel()
    return KOMIRA_OK


@export
def komira_run_progress(
    run: Handle,
    # SAFETY: `uint64_t *`, one caller-owned slot each, written only on
    # KOMIRA_OK.
    out_done: UnsafePointer[UInt64, MutUntrackedOrigin],
    out_total: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Store in `*out_done` the segments finished, and in `*out_total` the
    segments counted, by the runs given `run`. Callable from any thread,
    while a call given `run` is running on another. Both only grow, and
    `*out_done` is at most `*out_total`. Returns `KOMIRA_ERR_NULL_ARG` for a
    NULL `run`, `out_done` or `out_total` (nothing written) and `KOMIRA_OK`
    otherwise; it touches no context."""
    if Int(run) == 0 or Int(out_done) == 0 or Int(out_total) == 0:
        return KOMIRA_ERR_NULL_ARG
    # SAFETY: `run` is a live run handle (tested non-NULL); `snapshot` only
    # loads two atomic cells.
    var reading = _run(run)[].snapshot()
    # SAFETY: `out_done` and `out_total` are non-NULL (tested above) and are
    # caller-owned slots.
    out_done[0] = UInt64(reading.done)
    out_total[0] = UInt64(reading.total)
    return KOMIRA_OK


@export
def komira_sql_stream_run(
    ctx: Handle, sql: CStr, run: Handle, out_stream: ArrowStream
) abi("C") -> Int32:
    """`komira_sql_stream` under the run handle `run`: a `komira_run_cancel`
    of it, from another thread, stops the run at its next check (before each
    segment of the plan, and at each morsel boundary inside one), and the run
    counts its segments into the handle's progress.

    Returns what `komira_sql_stream` returns, and `KOMIRA_ERR_NULL_ARG` for a
    NULL `run` too, and `KOMIRA_ERR_CANCELLED` when the run is refused at step
    `execute` with `run` cancelled, `*out_stream` untouched and the last error
    `QUERY_CANCELLED: execute: <reason>`. A cancel that comes after the run's
    last check leaves the answer standing (`KOMIRA_OK`); a statement refused
    before its plan runs keeps its own refusal. The session stays usable after
    a cancel. `run` stays the caller's: it is not freed, and it may be given
    to later calls, which a cancelled handle refuses too.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(sql) == 0 or Int(run) == 0 or Int(out_stream) == 0:
        session[].set_error(String("komira_sql_stream_run: sql, run or out is NULL"))
        return KOMIRA_ERR_NULL_ARG
    # SAFETY: `run` is a live run handle (tested non-NULL). The run works on a
    # second handle of its own (`share`), so nothing here reads the caller's
    # `RunControl` while another thread cancels through it.
    var control = _run(run)[].share()
    return _sql_stream(
        session, String("komira_sql_stream_run"), sql, control, out_stream
    )


def _register_csv_call(
    ctx: Handle, op: String, name: CStr, path: CStr, delimiter: UInt8,
    has_header: Int32, all_varchar: Int32, skip: Int64,
) -> Int32:
    """The body of `komira_register_csv` and `komira_register_csv_with_skip`;
    `op` names the export in the NULL-argument refusal."""
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(name) == 0 or Int(path) == 0:
        session[].set_error(op + ": name or path is NULL")
        return KOMIRA_ERR_NULL_ARG
    try:
        register_csv(
            session[], _c_string(name), _c_string(path), delimiter,
            Int(has_header) != 0, Int(all_varchar) != 0, Int(skip),
        )
        return KOMIRA_OK
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


@export
def komira_register_csv(
    ctx: Handle, name: CStr, path: CStr, delimiter: UInt8, has_header: Int32, all_varchar: Int32
) abi("C") -> Int32:
    """Register the CSV file at `path` in the session as the table `name`.

    The table is what `read_csv` reads for the same file and dialect: its
    schema is inferred here from a bounded prefix of an uncompressed file (a
    compressed file is read whole), and every later query reads the file at
    that schema. `has_header` and `all_varchar` are `int32_t`; any non-zero
    value is true. Returns `KOMIRA_ERR_NULL_CTX` for a NULL `ctx`,
    `KOMIRA_ERR_NULL_ARG` for a NULL `name` or `path`, and `KOMIRA_ERR_ENGINE`
    with a last error for a file that cannot be read or inferred, an empty
    name (`TABLE_NAME_EMPTY`) and a name the session already holds
    (`TABLE_ALREADY_REGISTERED`); nothing is registered then.
    """
    return _register_csv_call(
        ctx, "komira_register_csv", name, path, delimiter, has_header, all_varchar, 0
    )


@export
def komira_register_csv_with_skip(
    ctx: Handle, name: CStr, path: CStr, delimiter: UInt8, has_header: Int32,
    all_varchar: Int32, skip: Int64,
) abi("C") -> Int32:
    """`komira_register_csv` with the first `skip` lines skipped, as `read_csv(...,
    skip = n)` does (ABI 1.11). A negative `skip` (`CSV_SKIP_NEGATIVE`) or one that
    leaves no line (`CSV_SKIP_PAST_END`) is `KOMIRA_ERR_ENGINE`; nothing is registered."""
    return _register_csv_call(
        ctx, "komira_register_csv_with_skip", name, path, delimiter, has_header, all_varchar, skip
    )


@export
def komira_register_json(ctx: Handle, name: CStr, path: CStr) abi("C") -> Int32:
    """Register the newline-delimited JSON file at `path` in the session as
    the table `name`.

    The table is what `read_json` reads for the same file: its schema is
    inferred here from the leading records. Errors are those of
    `komira_register_csv`.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(name) == 0 or Int(path) == 0:
        session[].set_error(String("komira_register_json: name or path is NULL"))
        return KOMIRA_ERR_NULL_ARG
    try:
        register_json(session[], _c_string(name), _c_string(path))
        return KOMIRA_OK
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


@export
def komira_plan_stream(
    ctx: Handle, plan: ConstBytes, plan_len: UInt64, out_stream: ArrowStream
) abi("C") -> Int32:
    """Decode the `WirePlanEnvelope` `plan[0..plan_len]`, run it with no SQL
    front end and fill `*out_stream` as `komira_sql_stream` does: -1 NULL
    `ctx`, -2 NULL `plan` or `out_stream`, -5 `plan_len` above the bound (not
    read), -3 a refusal `<step>: <reason>` (`decode`, `bind`, `optimize`,
    `lower`, `execute`)."""
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(plan) == 0 or Int(out_stream) == 0:
        session[].set_error(String("komira_plan_stream: plan or out is NULL"))
        return KOMIRA_ERR_NULL_ARG
    if input_length_status(plan_len) != KOMIRA_OK:
        session[].set_error(
            String("komira_plan_stream: plan_len is above ")
            + String(KOMIRA_MAX_INPUT_BYTES)
            + String(" bytes")
        )
        return KOMIRA_ERR_TOO_LARGE
    try:
        var result = plan_result(session[], _copy_in(plan, plan_len))
        # Nothing is written to `*out_stream` before this call, and it writes the
        # stream whole once its own checks have passed.
        build_record_batch_stream(result.take_batches(), result.take_schema(), out_stream)
        return KOMIRA_OK
    except e:
        # `plan_result` records a refusal with its step and code; one with
        # nothing held is the export check's, with neither.
        if not session[].has_error():
            session[].set_error(String(e))
        return KOMIRA_ERR_ENGINE


@export
def komira_register_arrow_stream(
    ctx: Handle, name: CStr, stream: ArrowStream
) abi("C") -> Int32:
    """Drain `stream` into a table held in memory and register it as `name`,
    replacing the session's table of that name (`so.register_arrow`). -1 NULL
    `ctx`, -2 NULL `name` or `stream`, else -3 with a last error; nothing is
    registered or replaced on a refusal (src/so/README.md lists each)."""
    if Int(ctx) == 0 or Int(name) == 0 or Int(stream) == 0:
        consumer_release_c_stream(stream)
        if Int(ctx) == 0:
            return KOMIRA_ERR_NULL_CTX
        _session(ctx)[].set_error(String("komira_register_arrow_stream: name or stream is NULL"))
        return KOMIRA_ERR_NULL_ARG
    var session = _session(ctx)
    session[].clear_error()
    try:
        var table_name = _c_string(name)
        check_table_name(table_name)
        # SAFETY: `stream` is non-NULL (tested above) and the caller's live
        # stream for the call; the drain reads it by reference and keeps none.
        register_arrow(session[], table_name, drain_record_batch_stream_table(stream[]))
        return KOMIRA_OK
    except e:
        # Live only if refused before the drain, which releases it on every path.
        consumer_release_c_stream(stream)
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE


@export
def komira_add_sql_binding(
    ctx: Handle, name: CStr, source: ConstBytes, source_len: UInt64, scope: Int32
) abi("C") -> Int32:
    """Bind the table `name` to the `WireBoundSource` bytes `source[0..source_len]`,
    replacing the session's table of that name (`so.add_sql_binding`). -1 NULL
    `ctx`, -2 NULL `name` or `source`, -5 `source_len` above the bound (not
    read), else -3 with a last error (step `bind`): `scope` other than
    `KOMIRA_BIND_SESSION`, an empty or non-UTF-8 name, a source that is not a
    `WireBoundSource` or names no kind, or a source the reader refuses; nothing
    is bound or replaced then (src/so/README.md lists each)."""
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(name) == 0 or Int(source) == 0:
        session[].set_error(String("komira_add_sql_binding: name or source is NULL"))
        return KOMIRA_ERR_NULL_ARG
    if input_length_status(source_len) != KOMIRA_OK:
        session[].set_error(
            String("komira_add_sql_binding: source_len is above ")
            + String(KOMIRA_MAX_INPUT_BYTES)
            + String(" bytes")
        )
        return KOMIRA_ERR_TOO_LARGE
    try:
        add_sql_binding(session[], _c_string(name), _copy_in(source, source_len), scope)
        return KOMIRA_OK
    except e:
        session[].set_error(String(e), KOMIRA_STEP_BIND)
        return KOMIRA_ERR_ENGINE
