# =============================================================================
# FFI-BOUNDARY: the C ABI of libkomira, the one file of komira_so that holds
# pointers.
# =============================================================================
# Four `@export abi("C")` functions are the library's whole surface today:
#
#   int32_t  komira_abi_version(void);
#   void    *komira_ctx_new(void);
#   void     komira_ctx_free(void *ctx);
#   int32_t  komira_last_error(void *ctx, uint8_t *out_buf, uint64_t out_cap,
#                              uint64_t *out_len);
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
# stores nothing.
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
from komira_so.status import (
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_OK,
    abi_version,
    buffer_status,
)

# SAFETY: `void *`, the context handle: an address returned by
# `komira_ctx_new`, valid until `komira_ctx_free`.
comptime _Handle = UnsafePointer[NoneType, MutUntrackedOrigin]
# SAFETY: `uint8_t *`, a caller-owned output buffer with its capacity beside it.
comptime _Bytes = UnsafePointer[UInt8, MutUntrackedOrigin]
# SAFETY: `uint64_t *`, one caller-owned output slot.
comptime _Len = UnsafePointer[UInt64, MutUntrackedOrigin]


@always_inline
def _session(ctx: _Handle) -> UnsafePointer[Session, MutUntrackedOrigin]:
    """The session behind a non-NULL handle.

    # SAFETY: `ctx` was returned by `komira_ctx_new` and has not been passed
    # to `komira_ctx_free` (the documented contract of the handle); every
    # caller tests for NULL first. The slot holds one live `Session`.
    """
    return ctx.bitcast[Session]()


@export
def komira_abi_version() abi("C") -> Int32:
    """The ABI version as `major * 1000 + minor`. Never fails."""
    return abi_version()


@export
def komira_ctx_new() abi("C") -> _Handle:
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
def komira_ctx_free(ctx: _Handle) abi("C"):
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
    ctx: _Handle, out_buf: _Bytes, out_cap: UInt64, out_len: _Len
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
