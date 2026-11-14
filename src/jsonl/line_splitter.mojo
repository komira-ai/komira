# =============================================================================
# JSON line splitter — string-state-aware `\n` finder for JSONL streaming.
# =============================================================================
#
# Scope:
#
#   - Walk a byte buffer and emit (line_start, line_end) pairs without
#     copying. `line_end` is the position of the line-terminating `\n`
#     (exclusive of the byte itself), so `bytes[line_start:line_end]`
#     is the line payload.
#   - `\n` (0x0A) inside a `"..."` JSON string MUST NOT terminate a
#     line. The string boundary is tracked by an `in_string` flag that
#     toggles on unescaped `"` (0x22).
#   - `\` (0x5C) escapes the next byte inside a string. Two cases this
#     handles correctly:
#       (1) `\"` — escaped quote does NOT close the string.
#       (2) `\\` — escaped backslash does NOT escape the byte after.
#       (3) Raw `0x0A` inside a `"..."` region is consumed as a string
#           byte, NOT a line terminator (per JSON-spec it's invalid,
#           but the splitter is deliberately permissive — the
#           downstream parser raises on malformed JSON).
#
# Pointer discipline:
#   - Public API takes `Span[UInt8, _]` (origin-poly). No
#     `UnsafePointer` in any public signature.
#   - All scanning is byte-indexed; no pointer arithmetic crosses a
#     module boundary.
# =============================================================================


struct LineSplitResult(Movable):
    """Result of `split_lines_in_buffer` over a JSONL byte chunk.

    Fields:
        starts: per-line start offsets (inclusive) into the buffer.
        ends:   per-line end offsets (exclusive of the terminating
                `\\n`). `bytes[starts[i]:ends[i]]` is the line payload.
        trailing_partial_start: offset where the trailing PARTIAL
                line begins (the bytes from this offset to end-of-
                buffer have NOT been terminated by `\\n`). If the
                buffer ends exactly on a `\\n`, this equals
                `len(bytes)` (no trailing partial). The streaming
                source uses this to carry-forward into the next chunk.
        in_string_at_end: True if the splitter is still inside a JSON
                string at end-of-buffer (a quoted region spans the
                buffer boundary). The streaming source threads this
                back into the next call so a string spanning chunks
                is handled correctly.
        prev_was_backslash_at_end: True if the last byte consumed was
                an in-string backslash (i.e. the FIRST byte of the
                next chunk is escaped). Threaded through chunk
                boundaries.
    """

    var starts: List[Int]
    var ends: List[Int]
    var trailing_partial_start: Int
    var in_string_at_end: Bool
    var prev_was_backslash_at_end: Bool

    def __init__(out self):
        self.starts = List[Int]()
        self.ends = List[Int]()
        self.trailing_partial_start = 0
        self.in_string_at_end = False
        self.prev_was_backslash_at_end = False


def split_lines_in_buffer(
    bytes: Span[UInt8, _],
) -> LineSplitResult:
    """Walk `bytes` and emit (start, end) pairs for each complete line.

    A "line" is the byte range between two `\\n` terminators (or between
    `bytes[0]` and the first `\\n`). The terminating `\\n` byte itself
    is EXCLUDED — `bytes[start:end]` is the line payload.

    String-state-aware: `\\n` (raw 0x0A) inside `"..."` is treated as
    part of the string and NOT as a line terminator. Escape handling
    inside strings: `\\` escapes the next byte (so `\\"` does not close
    the string, and `\\\\` does not escape the byte after).

    Use the `_with_state` variant for chunk-boundary string-state
    threading. This entry assumes a fresh JSON document — `in_string`
    starts False.

    Complexity: O(n) — single scalar walk. A SIMD memchr-style fast
    path for the steady-state "no-quote bytes" path is feasible; this is
    the scalar reference impl.
    """
    return split_lines_in_buffer_with_state(bytes, False, False)


def split_lines_in_buffer_with_state(
    bytes: Span[UInt8, _],
    initial_in_string: Bool,
    initial_prev_was_backslash: Bool,
) -> LineSplitResult:
    """Chunk-boundary-aware line splitter.

    Threads the caller-supplied `initial_in_string` and
    `initial_prev_was_backslash` so a string spanning two adjacent
    chunks is handled correctly:

        chunk_N      : `{"k":"hello\n` -> ends in_string=True
        chunk_{N+1}  : `world\n"}\n`   -> starts in_string=True; the
                                          0x0A inside the string is NOT
                                          a line terminator; the 0x0A
                                          after `"}` is.

    The streaming source passes the previous chunk's
    `result.in_string_at_end` and `result.prev_was_backslash_at_end`
    as the next chunk's seeds.
    """
    var result = LineSplitResult()
    var n = len(bytes)
    if n == 0:
        result.trailing_partial_start = 0
        result.in_string_at_end = initial_in_string
        result.prev_was_backslash_at_end = initial_prev_was_backslash
        return result^

    var i: Int = 0
    var line_start: Int = 0
    var in_string: Bool = initial_in_string
    var prev_was_backslash: Bool = initial_prev_was_backslash

    while i < n:
        var c = bytes[i]
        if in_string:
            if prev_was_backslash:
                # This byte is escaped — consume without state change.
                prev_was_backslash = False
            elif c == UInt8(0x5C):  # backslash
                prev_was_backslash = True
            elif c == UInt8(0x22):  # unescaped quote — close string
                in_string = False
            # `\n` (0x0A) inside a string is consumed as a string byte
            # by falling through — NOT a line terminator.
        else:
            if c == UInt8(0x22):  # opening quote
                in_string = True
                prev_was_backslash = False
            elif c == UInt8(0x0A):  # newline outside string
                result.starts.append(line_start)
                result.ends.append(i)
                line_start = i + 1
        i += 1

    result.trailing_partial_start = line_start
    result.in_string_at_end = in_string
    result.prev_was_backslash_at_end = prev_was_backslash
    return result^


@always_inline
def next_newline_outside_string(
    bytes: Span[UInt8, _],
    start: Int,
    mut in_string: Bool,
    mut prev_was_backslash: Bool,
) -> Int:
    """Find the next `\\n` at or after `start` that is NOT inside a JSON
    string. Returns the offset of the `\\n`, or `len(bytes)` if no such
    newline is found in this buffer.

    The caller threads `in_string` + `prev_was_backslash` across calls
    so a string spanning multiple buffers is handled correctly.

    This is the single-newline-at-a-time variant of
    `split_lines_in_buffer`. Streaming consumers that materialize one
    line at a time (rare path) can use this; the bulk batch shape
    above is the production driver.
    """
    var n = len(bytes)
    var i: Int = start
    while i < n:
        var c = bytes[i]
        if in_string:
            if prev_was_backslash:
                prev_was_backslash = False
            elif c == UInt8(0x5C):
                prev_was_backslash = True
            elif c == UInt8(0x22):
                in_string = False
        else:
            if c == UInt8(0x22):
                in_string = True
                prev_was_backslash = False
            elif c == UInt8(0x0A):
                return i
        i += 1
    return n
