# =============================================================================
# komira_libc.fd_write_all — a write(2) loop that CLAMPS its per-call length.
# =============================================================================
#
# # The defect this exists to make impossible
#
# A `while off < total:` loop around `write(2)` handles SHORT writes. It does
# NOT handle a kernel that refuses the length outright, and the two failures
# look identical in source:
#
#     while off < total:
#         n = write(fd, base + off, total - off)   # ⛔ asks for the WHOLE rest
#
# `total - off` on the FIRST iteration is the whole payload. Above 2 GiB the
# two platforms Komira ships on diverge:
#
#   * **Linux** caps a single `write(2)` at `0x7ffff000` (2,147,479,552) and
#     returns that as a PARTIAL write with `errno` untouched. The loop above
#     then completes normally — so the defect is INVISIBLE on Linux.
#   * **macOS** refuses `nbyte > INT_MAX` outright: `-1` / `EINVAL`, with
#     **zero bytes written**. The loop above raises on its first iteration.
#
# On macOS a result stream larger than INT_MAX written this way fails with:
#
#     write(2) to stdout returned -1 with 3200288832 of 3200288832
#     bytes unwritten.
#
# ⚠ THAT IS NOT A PLATFORM LIMIT ON THE ANSWER SIZE. It is a limit on ONE
# `write(2)` CALL, and a call is ours to choose. The fix is to never ask for
# more than `max_call_bytes` at a time; the loop does the rest.
#
# # Why a function and not a copy of the loop per caller
#
# Every hand-written `write(2)` loop repeats the same `total - off` first
# call (`RawWriteFd.write_bytes` in this directory's `posix_io.mojo` is one).
# For a logger whose payload is one line the clamp is unreachable; a sink
# that carries whatever a caller hands it is not. The point of this function
# is that a call site gets the clamp by CALLING, not by remembering.
#
# # Why a function and not four copies of the loop
#
# The tree has FOUR hand-written `write(2)` loops (`komira_log/stderr_sink.mojo`,
# `komira_log/engine/output_sink.mojo`,
# `komira_http/middleware/fault_report.mojo` and `RawWriteFd.write_bytes` in
# this directory's `posix_io.mojo`), all with the same `total - off` first call. Three are LOGGERS whose payload is one line, so
# the clamp is unreachable for them; the fourth carries whatever a caller hands
# it. A fifth copy in `plan_exec` is what this file replaces — the point is that
# a call site now gets the clamp by CALLING, not by remembering.
#
# # The clamp value
#
# `FD_WRITE_MAX_CALL_BYTES` is 64 MiB, DELIBERATELY the same number as
# `komira_libc.chunked_write.CHUNK_BYTES`, the WRITE-side sibling, and for
# the same four reasons written down there: a 32x margin under the 2 GiB
# threshold, large enough to amortize the syscall, small enough that a
# failure localizes, and the batch size production C++ writers (DuckDB's
# Parquet sink, Arrow IPC) already use.
#
# ⚠ They are two constants, not one, ON PURPOSE. `CHUNK_BYTES` governs a
# `std.io.FileHandle.write(String)` workaround for a *stdlib* bug; this governs
# the *syscall* argument. Coupling them would mean a future edit to one silently
# rewrites the other's contract. The shared value is stated here so the
# relationship is visible rather than accidental.
#
# # Why `komira_write_bytes` and not `external_call["write", ...]`
#
# A bare `external_call["write", Int]` collides with the stdlib's own
# reserved `write` FFI declaration ("existing function with conflicting
# signature") once a link unit's closure also pulls std.os's declaration in.
# It legalizes fine in a SMALL closure, which is why it is not safe in
# `komira_core`, upstream of nearly every binary. `komira_write_bytes` is a
# C shim symbol linked into every binary and test.
#
# # Encapsulation
#
# Public surface is `Int32` / `Span[UInt8, _]` / `String` / `Int`. The
# `payload.unsafe_ptr()` arithmetic is confined to this function body; the
# pointer is read-only, never escapes, and `payload`'s origin keeps the backing
# storage alive across the whole loop. `write(2)` copies into the kernel.
#
# Test coverage:
# `komira_libc/tests/test_fd_write_all_clamps_per_call_length.mojo`.
# =============================================================================

from std.ffi import external_call


# 64 MiB. See the file header for the value's rationale and for why it is a
# separate constant from `chunked_write.CHUNK_BYTES` despite being equal to it.
comptime FD_WRITE_MAX_CALL_BYTES: Int = 64 * 1024 * 1024


def write_all_fd(
    fd: Int32,
    payload: Span[UInt8, _],
    context: String,
    max_call_bytes: Int = FD_WRITE_MAX_CALL_BYTES,
) raises -> Int:
    """Write every byte of `payload` to `fd`, never asking `write(2)` for more
    than `max_call_bytes` in one call. Returns the number of bytes written
    (always `len(payload)` — the only other outcome is a raise).

    Args:
        fd: An open, writable file descriptor.
        payload: The bytes. A zero-length payload issues NO syscall and
            returns 0 — an IPC sink calls this once per frame and a result
            with no dictionary column legitimately has no `DictionaryBatch`
            frames.
        context: Prefixed to any error, so the raise names the CALLER's stream
            rather than this helper.
        max_call_bytes: The per-call clamp. Injectable so a test can drive the
            multi-call path over a small buffer; production callers take the
            default.

    Raises:
        * If `max_call_bytes` is not positive — a zero clamp is an infinite
          loop, which is worse than a refusal.
        * If `write(2)` returns <= 0. **It does not `break`.** A logger loop
          may break, and for a logger that is right:
          losing a diagnostic beats wedging the process. A caller of THIS
          function is writing an ANSWER, and giving up on one hands its reader a
          truncated stream under a success status.
    """
    var total = len(payload)
    if total == 0:
        return 0
    if max_call_bytes <= 0:
        raise Error(
            context
            + ": write_all_fd was given max_call_bytes="
            + String(max_call_bytes)
            + ", which cannot make progress. It must be > 0."
        )
    var off = 0
    # The Span's origin pins the backing storage alive across every iteration;
    # `write(2)` copies into the kernel and retains nothing.
    # SAFETY: `payload.unsafe_ptr()` is the caller's own buffer, read-only, and
    # never escapes this function. No pointer crosses a module boundary.
    var base = payload.unsafe_ptr()
    while off < total:
        var remaining = total - off
        # ★ THE WHOLE FIX IS THIS CLAMP. `remaining` is what an unclamped
        # loop passes, and above INT_MAX macOS refuses it with -1 having
        # written nothing.
        var request = remaining
        if request > max_call_bytes:
            request = max_call_bytes
        var n = external_call["komira_write_bytes", Int](
            fd, base + off, UInt64(request)
        )
        if n <= 0:
            raise Error(
                context
                + ": write(2) returned "
                + String(n)
                + " for a "
                + String(request)
                + "-byte call with "
                + String(remaining)
                + " of "
                + String(total)
                + " bytes unwritten. The byte stream is TRUNCATED; refusing to"
                " report success over a partial write."
            )
        off += Int(n)
    _ = base
    return off
