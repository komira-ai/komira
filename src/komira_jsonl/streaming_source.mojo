# =============================================================================
# JSONL streaming source — chunked-read + per-chunk materializer.
# =============================================================================
#
# Scope:
#
#   Producer-consumer wrapper around `materialize_jsonl_to_batch` so
#   files >100 MB don't have to live in memory in full. Pattern:
#
#     1. Open the file with FileHandle.
#     2. Read a chunk (default `DEFAULT_CHUNK_BYTES` = 4 MB).
#     3. Use `line_splitter.split_lines_in_buffer_with_state` to find
#        complete-line offsets. Any trailing partial line gets carried
#        forward into the next chunk.
#     4. Pass the complete-line subset of the chunk into
#        `materialize_jsonl_to_batch` -> one `RecordBatch`.
#     5. Append the per-chunk batch to a result `Slab[RecordBatch]`
#        (RecordBatch is non-Copyable so `List[RecordBatch]` is
#        rejected by the stdlib List bound — we use
#        `Slab[T]` which accepts Movable T).
#     6. Drop the chunk bytes BEFORE reading the next chunk so the
#        peak resident bytes stays at ~1 chunk + 1 in-progress batch.
#
# Memory contract:
#   At any moment during steady state, the resident bytes are
#   approximately:
#     * 1 chunk buffer (~DEFAULT_CHUNK_BYTES + max-line-tail)
#     * 1 carry-forward partial-line buffer (≤ max line length)
#     * 1 in-progress per-chunk RecordBatch (~chunk_bytes / 22 rows
#       for the int-pair synthetic shape)
#     * the accumulating output Slab[RecordBatch] (the SDK consumer
#       drains this morsel-at-a-time — at consumer time, the ceiling
#       collapses to one chunk's worth).
#
# Pointer discipline:
#   - All chunk buffers are `List[UInt8]` (heap-owned, ASAP-destroyed).
#   - `materialize_jsonl_to_batch` accepts `Span[UInt8, _]` — no
#     unsafe pointer crosses a module boundary. Auto-coerces from
#     `List[UInt8]` at the call site.
#   - No wildcard origin fields on any struct in this module.
#   - No `unsafe_from_address=Int(...)` laundering.
# =============================================================================

from std.io import FileHandle
from std.memory import unsafe_memcpy

from komira_core.collections.slab import Slab
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.arrow_helpers.streaming_concat import _concat_two_batches

from komira_jsonl.columnar_materializer import _materialize_checked
from komira_jsonl.part_concat import _concat_jsonl_parts
from komira_jsonl.line_check import build_jsonl_index
from komira_json_index.input_limits import (
    MAX_JSONL_LINE_BYTES,
    check_jsonl_carry_size,
)
from komira_jsonl.line_splitter import (
    LineSplitResult,
    split_lines_in_buffer_with_state,
)


# Default chunk size: 4 MiB. Empirically matches L2 cache on Skylake-X
# + Apple silicon; minimizes resident bytes; line splitter scans 4 MiB
# in low-millisecond range. Callers may override per-call for testing
# chunk-boundary behavior with small chunks.
comptime DEFAULT_CHUNK_BYTES: Int = 4 * 1024 * 1024


# 100 MB threshold. Files smaller than this can use
# the bulk slurper without memory concerns; files larger benefit from
# the chunked reader.
comptime STREAMING_FILE_SIZE_THRESHOLD_BYTES: Int = 100 * 1024 * 1024


def _file_size_bytes(path: String) raises -> Int:
    """Return the byte length of the file at `path` by SEEK_END.

    Local helper so this module does not depend on `komira_parquet`'s
    writer helpers; the dep direction stays `komira_jsonl -> komira_core`.
    """
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)  # SEEK_END
    var size = Int(f.seek(0, 1))  # tell
    f.close()
    return size


def _read_next_chunk(
    mut f: FileHandle,
    chunk_bytes: Int,
    var carry: List[UInt8],
    mut hit_eof: Bool,
) raises -> List[UInt8]:
    """Read up to `chunk_bytes` from `f`, prefixed with any carry-forward
    partial-line bytes from the previous chunk.

    Returns a `List[UInt8]` whose contents are `carry + bytes_read`.
    The carry input is consumed; the returned buffer is the chunk to
    feed into `split_lines_in_buffer_with_state`.

    Returns an empty List if EOF is hit with no carry.

    ⚠ `hit_eof` is set True when the read returned ZERO bytes, and the caller
    MUST stop looping on it. Without that signal the driver loop below spins
    forever on any file whose last line lacks a trailing newline: the read
    returns nothing, this function hands the SAME carry back as the chunk, the
    splitter finds no complete line, the carry is re-derived as the whole
    chunk, and the next iteration repeats it identically. See the loop for the
    full note — that hang is reachable from any untrusted JSONL file that does
    not end in `\n`.
    """
    var raw = f.read_bytes(chunk_bytes)
    if len(raw) == 0:
        hit_eof = True
    var carry_len = len(carry)
    var raw_len = len(raw)
    if raw_len == 0 and carry_len == 0:
        return List[UInt8]()
    var total = carry_len + raw_len
    var result = List[UInt8](capacity=total)
    result.resize(total, UInt8(0))
    if carry_len > 0:
        # SAFETY: memcpy from a heap-owned `carry` (alive through the
        # call) into a heap-owned `result` (just allocated). No
        # wildcard origin; both pointers come from same-thread
        # ASAP-tracked Lists.
        unsafe_memcpy(
            dest=result.unsafe_ptr(),
            src=carry.unsafe_ptr(),
            count=carry_len,
        )
    if raw_len > 0:
        unsafe_memcpy(
            dest=result.unsafe_ptr() + carry_len,
            src=raw.unsafe_ptr(),
            count=raw_len,
        )
    return result^


def _slice_carry(
    src: List[UInt8], start: Int,
) -> List[UInt8]:
    """Return a copy of `src[start:]` as a fresh `List[UInt8]`.

    Used to extract the trailing partial-line bytes from the current
    chunk so they can be prefixed onto the next read.

    The slice is a true copy (not a view) — the next-chunk buffer
    consumes the carry and frees its allocation, so we want the carry
    to be owned and small.
    """
    var n = len(src)
    if start >= n:
        return List[UInt8]()
    var tail_len = n - start
    var out = List[UInt8](capacity=tail_len)
    out.resize(tail_len, UInt8(0))
    unsafe_memcpy(
        dest=out.unsafe_ptr(),
        src=src.unsafe_ptr() + start,
        count=tail_len,
    )
    return out^


def _trim_chunk_to_complete_lines(
    var chunk: List[UInt8],
    trailing_partial_start: Int,
) -> List[UInt8]:
    """Truncate `chunk` to the prefix containing only complete lines.

    The complete-line prefix is `chunk[0:trailing_partial_start]`.
    The trailing partial (if any) is sliced off separately via
    `_slice_carry`. We re-use the same allocation for the prefix by
    calling `.resize(trailing_partial_start)` which is O(1) shrink.
    """
    if trailing_partial_start <= 0:
        var empty = List[UInt8]()
        return empty^
    if trailing_partial_start >= len(chunk):
        return chunk^
    chunk.resize(trailing_partial_start, UInt8(0))
    return chunk^


def read_jsonl_streamed_to_batches(
    path: String,
    var schema: Schema,
    chunk_bytes: Int = DEFAULT_CHUNK_BYTES,
    max_line_bytes: Int = MAX_JSONL_LINE_BYTES,
) raises -> Slab[RecordBatch]:
    """Stream-read a JSONL file in chunks; emit one `RecordBatch` per chunk.

    Caller is expected to drain the result slab. Each batch covers the
    complete lines that fit inside one chunk; trailing partial lines
    are carried forward to the next chunk so no line is split across
    batches.

    `Slab[T]` (not `List[T]`) used because `RecordBatch` is `Movable`
    but not `Copyable` — the stdlib `List[T]` requires
    `Copyable`.

    `max_line_bytes` bounds the carry-forward partial-line buffer. It is a
    HARD safety ceiling, not a tuning knob: without it a file with no
    unescaped newline makes the carry grow by one chunk per read (O(file^2)
    copies, ~2x file resident) and then materializes the whole file as one
    line — which defeats the entire purpose of the chunked path. Exposed as
    a parameter so callers with tighter memory budgets (and the regression
    test) can lower it.

    Returns:
        `Slab[RecordBatch]` — empty slab if the file has zero complete
        lines.

    Raises:
        Error naming the line length and the limit when a single line
        exceeds `max_line_bytes`.
    """
    var f = FileHandle(path, "r")
    var batches = Slab[RecordBatch]()
    var carry = List[UInt8]()
    var in_string: Bool = False
    var prev_was_backslash: Bool = False
    # ⚠ EOF TERMINATION. See `_read_next_chunk`: the loop must distinguish
    # "read returned nothing" from "read returned nothing but there is
    # still a carry". Without `hit_eof`, a file whose last line lacks a
    # trailing newline spins here forever — `_read_next_chunk` hands the
    # same carry back as the chunk on every iteration, the splitter finds no
    # complete line in it, and the carry is re-derived unchanged, so the
    # post-loop "treat the carry as one final complete line" branch is never
    # reached. Any untrusted JSONL file that does not end in `\n` reaches
    # this; it shows up as a hang, not a crash.
    var hit_eof: Bool = False
    # Lines in the chunks already read: an error in a later chunk names its
    # line in the file. Each chunk read ends at the LF of its last complete
    # line, so its line count is its number of complete lines.
    var lines_done: Int = 0
    var no_prefix = List[UInt8]()
    while True:
        var chunk = _read_next_chunk(f, chunk_bytes, carry^, hit_eof)
        if len(chunk) == 0:
            # EOF: re-init carry to empty so the post-loop check below
            # sees a valid (empty) state. The previous iteration's
            # carry has already been merged into `chunk` by
            # `_read_next_chunk`; chunk is empty so there is no carry
            # to recover.
            carry = List[UInt8]()
            break
        var r = split_lines_in_buffer_with_state(
            chunk,
            in_string,
            prev_was_backslash,
        )
        # Set up carry for next iteration BEFORE consuming the chunk.
        carry = _slice_carry(chunk, r.trailing_partial_start)
        # MAX-LINE CEILING (ASSERT=none hardening). The whole
        # point of this chunked path is to BOUND resident bytes for >100 MB
        # files, and the carry is the one buffer that can grow without limit:
        # a file with no unescaped newline (or one unterminated `"` that makes
        # every newline string-interior) grows the carry by a full chunk per
        # read, so `_read_next_chunk` memcpys O(file^2) bytes, holds ~2x the
        # file resident, and finally materializes the entire file as ONE line.
        # ONE compare per chunk read (once per 4 MiB by default).
        check_jsonl_carry_size(len(carry), chunk_bytes, max_line_bytes)
        # State threading invariant: the carry contains the bytes of
        # the trailing PARTIAL line (offsets `trailing_partial_start..N`).
        # The line splitter outputs `in_string_at_end` reflecting the
        # state AFTER walking those bytes. But since carry is re-walked
        # at the head of the next chunk, the splitter re-seeds the
        # in_string state by walking the same bytes again — so the seed
        # passed in must be False/False (the state BEFORE the carry
        # bytes), NOT the state AFTER. A `\n` is only emitted OUTSIDE a
        # string, so the byte at `trailing_partial_start` is by
        # construction outside-of-string.
        in_string = False
        prev_was_backslash = False

        if len(r.starts) > 0:
            # Trim chunk down to the complete-line prefix and pass it
            # whole to materialize_jsonl_to_batch. The materializer's
            # internal structural index will walk the same byte range
            # and emit one RecordBatch.
            var trimmed = _trim_chunk_to_complete_lines(
                chunk^, r.trailing_partial_start,
            )
            var idx = build_jsonl_index(trimmed, no_prefix, lines_done)
            var batch = _materialize_checked(
                trimmed, schema.copy(), idx, no_prefix, lines_done
            )
            batches.append(batch^)
            lines_done += len(r.starts)
        else:
            # No complete line in this chunk -> drop chunk; bytes
            # already copied into `carry` for next iteration.
            _ = chunk^

        if hit_eof:
            # The read that produced this chunk returned zero bytes, so the
            # chunk WAS the carry and there is nothing left to append to it.
            # Looping again would re-derive the identical carry forever.
            # Whatever remains in `carry` is the final unterminated line and
            # is handled by the tail block below.
            break
    f.close()
    # If there is a carry left over at EOF (file ends without a trailing
    # `\n`), treat the carry as one final complete line.
    if len(carry) > 0:
        # Append a synthetic `\n` so the materializer's structural index
        # closes the line cleanly.
        carry.append(UInt8(0x0A))
        var tail_idx = build_jsonl_index(carry, no_prefix, lines_done)
        var tail = _materialize_checked(
            carry, schema^, tail_idx, no_prefix, lines_done
        )
        batches.append(tail^)
    else:
        # Drop schema (was held across loop).
        _ = schema^
    return batches^


def read_jsonl_streamed_to_one_batch(
    path: String,
    var schema: Schema,
    chunk_bytes: Int = DEFAULT_CHUNK_BYTES,
    max_line_bytes: Int = MAX_JSONL_LINE_BYTES,
) raises -> RecordBatch:
    """Stream-read a JSONL file in chunks and fold to ONE `RecordBatch`.

    The plan compiler's JSON scan routes files >
    `STREAMING_FILE_SIZE_THRESHOLD_BYTES` here in place of the bulk
    read + `materialize_jsonl_to_batch` path.

    Memory profile:
        Steady state: ~chunk_bytes + ~per-chunk-batch + accumulating
        result. The pair-wise concat keeps two batches alive at any
        moment (left + right) plus the next-chunk buffer; the
        streaming peak is bounded by `chunk_bytes` (input buffer)
        + `result_so_far` (output) + `current_chunk_batch` (in-flight).
        The dominant cost at large file sizes is the cumulative output
        — for files much larger than max-morsel, the caller should
        consume the per-chunk batches via the
        `read_jsonl_streamed_to_batches` entry instead of the
        fold-to-one form.
    """
    var batches = read_jsonl_streamed_to_batches(
        path, schema^, chunk_bytes, max_line_bytes,
    )
    var n = len(batches)
    if n == 0:
        # Empty file -> empty default batch. Defensive — production
        # callers should not invoke on an empty file.
        return RecordBatch()
    if n == 1:
        var only = batches.take_slot_unchecked(0)
        # Per Slab.take_slot_unchecked contract: caller MUST update
        # length to reflect initialized slots remaining.
        batches.set_len_unchecked(0)
        _ = batches^
        return only^
    # Multi-way concat via the canonical single-pass helper. Each input
    # batch's bytes are copied EXACTLY ONCE into the output, vs. the
    # pair-wise fold's O(N²) re-copy (the same single-pass concat the
    # hash aggregate's output path uses).
    #
    # Move each `RecordBatch` from `batches: Slab[RecordBatch]` into a
    # `Slab[Optional[RecordBatch]]` (the multi-way concat's expected
    # input shape — Optional makes the per-slot "consumed" state
    # explicit so the concat can `.take()` each slot as it processes).
    var staged = Slab[Optional[RecordBatch]]()
    for i in range(n):
        var b = batches.take_slot_unchecked(i)
        staged.append(Optional[RecordBatch](b^))
    batches.set_len_unchecked(0)
    _ = batches^
    # Zero-column chunks (a schema with no fields) are joined by row count.
    var combined = _concat_jsonl_parts(staged, n)
    # `_concat_jsonl_parts` `.take()`s each slot, so
    # the slab's destructor sees all-empty slots and is a no-op.
    _ = staged^
    return combined^
