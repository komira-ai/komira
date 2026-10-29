# =============================================================================
# FFI-BOUNDARY: the C ABI of libkomira, the one file of komira_so that holds
# pointers.
# =============================================================================
# Nine `@export abi("C")` functions are the library's whole surface today:
#
#   int32_t  komira_abi_version(void);
#   void    *komira_ctx_new(void);
#   void     komira_ctx_free(void *ctx);
#   int32_t  komira_last_error(void *ctx, uint8_t *out_buf, uint64_t out_cap,
#                              uint64_t *out_len);
#   int32_t  komira_register_parquet(void *ctx, const char *name,
#                                    const char *path);
#   int32_t  komira_parquet_schema(void *ctx, const char *path,
#                                  uint8_t *out_buf, uint64_t out_cap,
#                                  uint64_t *out_len);
#   int32_t  komira_csv_binding(void *ctx, const char *path, uint8_t delimiter,
#                               int32_t has_header, int32_t all_varchar,
#                               uint8_t *out_buf, uint64_t out_cap,
#                               uint64_t *out_len);
#   int32_t  komira_json_binding(void *ctx, const char *path,
#                                uint8_t *out_buf, uint64_t out_cap,
#                                uint64_t *out_len);
#   int32_t  komira_plan_render(void *ctx, const uint8_t *plan,
#                               uint64_t plan_len, uint8_t *out_buf,
#                               uint64_t out_cap, uint64_t *out_len);
#
# Ownership. `komira_ctx_new` creates a `Session` in an `OwnedPointer`,
# relinquishes the pointer's own free (`unsafe_leak`) and hands the address to
# the caller as `void *`. The caller owns that handle until it passes it to
# `komira_ctx_free`, which rebuilds the one `OwnedPointer` over the same
# allocation and destroys the session. Freeing a handle twice, or using one
# after `komira_ctx_free`, is undefined, as for `free(3)`; `komira_ctx_free`
# of NULL does nothing. Every other pointer is the caller's: this library
# reads or writes it during the call and keeps none.
#
# Errors. A call returns `KOMIRA_OK` (0) or a negative `KOMIRA_ERR_*` code
# (status.mojo). A call refused with `KOMIRA_ERR_NULL_ARG` on a live context
# stores its refusal as the context's last error; `KOMIRA_ERR_BUFFER_TOO_SMALL`
# stores nothing. Every source and render call first clears the context's last
# error, and stores the engine's message when it returns `KOMIRA_ERR_ENGINE`.
# `komira_last_error` does not clear what it reads.
#
# Strings and byte inputs. A `const char *` is NUL-terminated UTF-8 that the
# caller keeps alive for the call; the library copies it before using it, and a
# string that is not valid UTF-8 is refused as `KOMIRA_ERR_ENGINE` with a last
# error, never used. The plan bytes of `komira_plan_render` are
# `plan[0..plan_len]`, with the length an argument because a serialized plan
# holds NUL bytes; they are copied in full before anything is decoded. The
# length is bounded: above `KOMIRA_MAX_INPUT_BYTES` (64 MiB) the call returns
# `KOMIRA_ERR_TOO_LARGE` with a last error, before any byte of `plan` is read
# or any memory is allocated for it. Exactly 64 MiB is accepted.
#
# The two-call output protocol (`komira_last_error`). The text is not
# NUL-terminated; `*out_len` is its byte count. `*out_len` is stored before the
# capacity is tested. The first call passes `out_cap` 0 (and may pass a NULL
# `out_buf`) to learn the length; the second passes a buffer of at least that
# many bytes. A buffer that is too small is never written, so a caller never
# parses a truncated text. An empty text needs no buffer: `out_buf` may be NULL.
#
# Pointer types. Only the `comptime` aliases below name a wildcard origin: a
# `void *` that lives in the host between calls has no Mojo origin, and the
# Mojo side takes no pointer from the host except through them.
# =============================================================================

from std.memory import OwnedPointer, unsafe_memcpy

from komira_so.session import Session
from komira_so.sources import (
    csv_binding_bytes,
    json_binding_bytes,
    parquet_schema_bytes,
    plan_render_text,
    register_parquet,
)
from komira_so.status import (
    KOMIRA_ERR_ENGINE,
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_ERR_TOO_LARGE,
    KOMIRA_MAX_INPUT_BYTES,
    KOMIRA_OK,
    abi_version,
    buffer_status,
    input_length_status,
)

# `Handle`, `CStr` and `ConstBytes` are the names the ABI golden
# (abi/komira.tsv) knows: the header spells them `komira_handle`,
# `const char *` and `const uint8_t *`, and the golden check refuses a
# declaration of `CStr` or `ConstBytes` that is not a pointer to `UInt8`. The
# exported signatures spell every other pointer in full, for the same reason.
# SAFETY: `void *`, the context handle: an address returned by
# `komira_ctx_new`, valid until `komira_ctx_free`.
comptime Handle = UnsafePointer[NoneType, MutUntrackedOrigin]
# SAFETY: `uint8_t *`, a caller-owned output buffer with its capacity beside it.
comptime _Bytes = UnsafePointer[UInt8, MutUntrackedOrigin]
# SAFETY: `uint64_t *`, one caller-owned output slot.
comptime _Len = UnsafePointer[UInt64, MutUntrackedOrigin]
# SAFETY: `const char *`, a NUL-terminated string the caller keeps alive for
# the call; it is copied into a `String` before any use.
comptime CStr = UnsafePointer[UInt8, MutUntrackedOrigin]
# SAFETY: `const uint8_t *`, the plan bytes of `komira_plan_render`: read for
# `plan_len` bytes, copied in full, never written.
comptime ConstBytes = UnsafePointer[UInt8, MutUntrackedOrigin]


@always_inline
def _session(ctx: Handle) -> UnsafePointer[Session, MutUntrackedOrigin]:
    """The session behind a non-NULL handle."""
    # SAFETY: `ctx` was returned by `komira_ctx_new` and has not been passed
    # to `komira_ctx_free` (the documented contract of the handle); every
    # caller tests for NULL first. The slot holds one live `Session`.
    return ctx.bitcast[Session]()


@export
def komira_abi_version() abi("C") -> Int32:
    """The ABI version as `major * 1000 + minor`. Never fails."""
    return abi_version()


@export
def komira_ctx_new() abi("C") -> Handle:
    """Create a session and return its handle. The caller frees it with
    `komira_ctx_free`."""
    var owned = OwnedPointer[Session](Session())
    # SAFETY: `unsafe_leak` relinquishes the OwnedPointer's free, so the only
    # owner of the allocation from here on is whoever holds the returned
    # address; `komira_ctx_free` rebuilds the single OwnedPointer over it.
    return owned^.unsafe_take_allocation().unsafe_leak().bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()


@export
def komira_ctx_free(ctx: Handle) abi("C"):
    """Destroy a session created by `komira_ctx_new`. NULL does nothing."""
    if Int(ctx) == 0:
        return
    # SAFETY: `ctx` is the allocation `komira_ctx_new` leaked from its
    # OwnedPointer and nothing else owns it, so this OwnedPointer is the
    # single owner: it moves the session out and frees the slot once.
    var owned = OwnedPointer[Session](unsafe_from_raw_pointer=_session(ctx))
    var session = owned^.into_inner()
    _ = session^


@export
def komira_last_error(
    ctx: Handle,
    out_buf: UnsafePointer[UInt8, MutUntrackedOrigin],
    out_cap: UInt64,
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
    if Int(out_len) == 0:
        session[].set_error(String("komira_last_error: out_len is NULL"))
        return KOMIRA_ERR_NULL_ARG
    var text = session[].last_error()
    var n = text.byte_length()
    # SAFETY: `out_len` is non-NULL (tested above) and is a caller-owned slot.
    out_len[0] = UInt64(n)
    var status = buffer_status(n, out_cap)
    if status != KOMIRA_OK:
        return status
    if n == 0:
        return KOMIRA_OK
    if Int(out_buf) == 0:
        session[].set_error(String("komira_last_error: out_buf is NULL"))
        return KOMIRA_ERR_NULL_ARG
    # SAFETY: `out_buf` holds at least `out_cap >= n` bytes by the caller's
    # contract and `buffer_status` just confirmed it; `text` is alive for the
    # copy and does not overlap the caller's buffer.
    unsafe_memcpy(dest=out_buf, src=text.unsafe_ptr(), count=n)
    return KOMIRA_OK


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


def _copy_in(plan: _Bytes, plan_len: UInt64) -> List[UInt8]:
    """A copy of `plan[0..plan_len]`; `plan_len` is at most
    `KOMIRA_MAX_INPUT_BYTES` (the caller tests with `input_length_status`)."""
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
) -> Int32:
    """The write half of the two-call protocol for the source and render calls.

    Stores the byte count in `*out_len` first, then returns
    `KOMIRA_ERR_BUFFER_TOO_SMALL` (writing nothing) when `out_cap` is below it.
    A NULL `out_buf` is refused only when there are bytes to write.
    """
    var n = len(data)
    # SAFETY: `out_len` is non-NULL (every caller tests first) and a
    # caller-owned slot.
    out_len[0] = UInt64(n)
    var status = buffer_status(n, out_cap)
    if status != KOMIRA_OK:
        return status
    if n == 0:
        return KOMIRA_OK
    if Int(out_buf) == 0:
        session[].set_error(String("out_buf is NULL"))
        return KOMIRA_ERR_NULL_ARG
    # SAFETY: `out_buf` holds at least `out_cap >= len(data)` bytes by the
    # caller's contract, just tested by `buffer_status`; `data` is alive for
    # the copy and does not overlap the caller's buffer.
    unsafe_memcpy(dest=out_buf, src=data.unsafe_ptr(), count=n)
    return KOMIRA_OK


@export
def komira_register_parquet(
    ctx: Handle, name: CStr, path: CStr
) abi("C") -> Int32:
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
        session[].set_error(
            String("komira_register_parquet: name or path is NULL")
        )
        return KOMIRA_ERR_NULL_ARG
    try:
        register_parquet(session[], _c_string(name), _c_string(path))
        return KOMIRA_OK
    except e:
        session[].set_error(String(e))
        return KOMIRA_ERR_ENGINE


@export
def komira_parquet_schema(
    ctx: Handle,
    path: CStr,
    out_buf: UnsafePointer[UInt8, MutUntrackedOrigin],
    out_cap: UInt64,
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
        session[].set_error(
            String("komira_parquet_schema: path or out_len is NULL")
        )
        return KOMIRA_ERR_NULL_ARG
    try:
        var bytes = parquet_schema_bytes(_c_string(path))
        return _emit(session, Span(bytes), out_buf, out_cap, out_len)
    except e:
        session[].set_error(String(e))
        return KOMIRA_ERR_ENGINE


@export
def komira_csv_binding(
    ctx: Handle,
    path: CStr,
    delimiter: UInt8,
    has_header: Int32,
    all_varchar: Int32,
    out_buf: UnsafePointer[UInt8, MutUntrackedOrigin],
    out_cap: UInt64,
    out_len: UnsafePointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    """Write the `WireScanBinding` of the CSV file at `path` (two-call
    protocol).

    The schema is inferred from a bounded prefix of an uncompressed file; a
    compressed file is read whole. `has_header` and `all_varchar` are
    `int32_t` and any non-zero value is true. Errors are those of
    `komira_parquet_schema`.
    """
    if Int(ctx) == 0:
        return KOMIRA_ERR_NULL_CTX
    var session = _session(ctx)
    session[].clear_error()
    if Int(path) == 0 or Int(out_len) == 0:
        session[].set_error(
            String("komira_csv_binding: path or out_len is NULL")
        )
        return KOMIRA_ERR_NULL_ARG
    try:
        var bytes = csv_binding_bytes(
            _c_string(path), delimiter, Int(has_header) != 0, Int(all_varchar) != 0
        )
        return _emit(session, Span(bytes), out_buf, out_cap, out_len)
    except e:
        session[].set_error(String(e))
        return KOMIRA_ERR_ENGINE


@export
def komira_json_binding(
    ctx: Handle,
    path: CStr,
    out_buf: UnsafePointer[UInt8, MutUntrackedOrigin],
    out_cap: UInt64,
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
        session[].set_error(
            String("komira_json_binding: path or out_len is NULL")
        )
        return KOMIRA_ERR_NULL_ARG
    try:
        var bytes = json_binding_bytes(_c_string(path))
        return _emit(session, Span(bytes), out_buf, out_cap, out_len)
    except e:
        session[].set_error(String(e))
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
        session[].set_error(
            String("komira_plan_render: plan or out_len is NULL")
        )
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
