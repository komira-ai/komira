# =============================================================================
# csv_scanner_phase1 — Phase 1 DuckDB-pattern chassis.
# =============================================================================
#
#
# Walks a byte buffer with the Phase 1 chassis:
#   - 8-byte ContainsZeroByte fast skip in STANDARD state (no specials in
#     the next 8 bytes -> advance 8).
#   - Per-byte FSA tail loop when specials are present.
#
# Emits per-row record-boundaries via the `Row` struct (list of cell ranges).
# The cell-range carries the (start, end) byte offsets into the buffer + an
# `needs_unescape: Bool` flag (True iff the cell was quoted AND contained
# a doubled-quote escape or a Posix backslash escape that needs an in-place
# rewrite before consumption).
#
# Encapsulation: the public surface is `scan_csv_phase1[Q: QuoteStyle](...)`
# which takes a `Span[UInt8, _]` (origin-poly view) and returns
# `List[Row]` (Movable struct list). NO UnsafePointer in any public
# signature. The 8-byte fast skip walks via Mojo's `bitcast` on a Span
# byte-window inside a private helper that carries the SAFETY: comment.
# =============================================================================

from std.bit import count_trailing_zeros

from komira_simd.byte_class.byte_find_any_of import (
    byte_find_eq_4_u8x32,
    byte_find_eq_4_u8x64,
)
from komira_simd.byte_class.movemask import (
    movemask_to_uint_u8x32,
    movemask_to_uint_u8x64,
    byte_eq_to_bytemask_u8x64,
)
from komira_simd.byte_class.quote_region_mask import (
    quote_region_mask_u64,
)

from .quote_styles import QuoteStyle
from .csv_state_machine import (
    CSV_STATE_STANDARD,
    CSV_STATE_QUOTED,
    CSV_STATE_QUOTE_IN_QUOTED,
    CSV_STATE_POSIX_ESCAPE,
    CSV_STATE_CR_LF_LOOKAHEAD,
    contains_any_of_4,
    broadcast_byte,
)
from .scanned_cells import (
    ScannedCells,
    CELL_FLAG_WAS_QUOTED,
    CELL_FLAG_NEEDS_UNESCAPE,
    pack_cell_flags,
)


# =============================================================================
# CellRange — byte-offset window into the source buffer for one cell.
# =============================================================================


@fieldwise_init
struct CellRange(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """One CSV cell as (start_offset, end_offset) within the source buffer.

    The buffer is borrowed from the caller; `start_offset` is inclusive,
    `end_offset` is exclusive (Pythonic slice convention).

    `was_quoted` is True iff the cell was delimited by quote bytes (the
    quote bytes themselves are EXCLUDED from start_offset..end_offset).

    `needs_unescape` is True iff `was_quoted` AND the cell body contained
    at least one doubled-quote `""` (RFC-4180/Excel) or single-byte escape
    `\\"` (Posix). The cell parser inspects this flag and runs the
    in-place unescape routine on its working copy of the slice.
    """

    var start: Int
    var end: Int
    var was_quoted: Bool
    var needs_unescape: Bool


# =============================================================================
# Row — sequence of CellRanges making up one CSV row.
# =============================================================================


struct Row(Copyable, Movable, Deinitable):
    """One CSV record: an ordered list of CellRange entries.

    Wraps `List[CellRange]` rather than a fixed InlineArray because the
    column count is data-driven. The scanners emit each record's cells as
    they find them and do not compare field counts: a `Row` may hold fewer or
    more cells than the header. The readers (`read_csv_bytes_to_batch`,
    `read_csv_bytes_to_schema`, the parallel reader) refuse such a record via
    `record_shape.check_csv_record_shape`, which raises naming the record,
    line and field, before any column is built.
    """

    var cells: List[CellRange]

    def __init__(out self):
        self.cells = List[CellRange]()

    def copy(self) -> Self:
        var out = Self()
        var i = 0
        while i < len(self.cells):
            out.cells.append(self.cells[i])
            i = i + 1
        return out^


# =============================================================================
# find_first_newline_simd — SIMD newline scanner for row-streaming partition
# =============================================================================
#
# The row-streaming CSV/JSONL readers only
# need to locate ROW boundaries (newlines) — they do NOT need cell
# tokenization or quote-region tracking (those are handled per-line by
# the row decoder).
#
# `scan_csv_phase3_pclmulqdq` (the column-intermediate path's SIMD
# scanner) is overkill for this use case: it tracks quote-region state,
# does cell tokenization (delimiter detection), and emits
# `(start, end, was_quoted, needs_unescape)` per-cell metadata. Row-
# streaming throws all of that away — it only consumes byte offsets of
# newlines.
#
# This sibling primitive `find_first_newline_simd` runs a much simpler
# 64-byte-chunked SIMD scan: at each chunk, compare every byte against
# 0x0A, movemask to a UInt64, count_trailing_zeros to find the first
# set bit. Scalar tail loop handles the last <64 bytes. NO quote
# tracking, NO cell tokenization, NO state machine.
#
# Performance: each 64-byte chunk costs:
#   * 1 SIMD load (`_load_u8x64`)
#   * 1 byte-eq -> bytemask (`byte_eq_to_bytemask_u8x64`)
#   * 1 movemask -> bitmask (`movemask_to_uint_u8x64`)
#   * 1 `count_trailing_zeros` (only on the chunk that has a hit)
# vs the scalar memchr which costs ~64 byte-compares + branches per
# 64-byte window. The row-streaming partition walks O(file_size /
# n_workers) bytes per worker boundary, so the savings compound.
#
# Encapsulation: public surface is `find_first_newline_simd(bytes, start)
# -> Int`. NO UnsafePointer in the signature. The internal
# `_load_u8x64` helper is module-internal (same as `scan_csv_phase{1,2,3}`).
# =============================================================================


def find_first_newline_simd(bytes: Span[UInt8, _], start: Int) -> Int:
    """Find the byte offset of the first 0x0A (LF) at or after `start`.

    Returns `len(bytes)` if no LF is found in `bytes[start:]`.

    SIMD-vectorized 64-byte-chunked scan. Used by the row-streaming
    CSV/JSONL readers for parallel partition-boundary computation.

    Walks the buffer in 64-byte SIMD chunks:
      1. Load 64 bytes via `_load_u8x64`.
      2. Compute byte-mask via `byte_eq_to_bytemask_u8x64(chunk, 0x0A)`.
      3. Compute bitmask via `movemask_to_uint_u8x64`.
      4. If bitmask != 0: `count_trailing_zeros` gives the offset of
         the FIRST 0x0A in the chunk; return `chunk_base + tzcnt`.
      5. Else advance by 64 bytes and reload.
      6. Tail (<64 bytes): fall through to per-byte scalar scan.

    The result is BYTE-IDENTICAL to the scalar `while p < n: if bytes[p]
    == 0x0A: break; p = p + 1` loop. Verified by the byte-identity
    test in `tests/test_simd_row_boundary_scan.mojo`.

    Args:
        bytes: Origin-poly Span over the file contents.
        start: Byte offset to start scanning from (inclusive).

    Returns:
        Byte offset of first 0x0A at or after `start`, or `len(bytes)`
        if no LF is present. NEVER returns a value less than `start`.
    """
    var n = len(bytes)
    if start >= n:
        return n
    var pos = start

    # 64-byte SIMD fast loop.
    while pos + 64 <= n:
        var chunk = _load_u8x64(bytes, pos)
        var bm = byte_eq_to_bytemask_u8x64(chunk, UInt8(0x0A))
        var bits = movemask_to_uint_u8x64(bm)
        if bits != UInt64(0):
            var k = Int(count_trailing_zeros(bits))
            return pos + k
        pos = pos + 64

    # Scalar tail (last <64 bytes).
    while pos < n:
        if bytes[pos] == UInt8(0x0A):
            return pos
        pos = pos + 1
    return n


# =============================================================================
# scan_csv_phase1 — Phase 1 chassis entry point.
# =============================================================================


def scan_csv_phase1[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    delimiter: UInt8,
    quote: UInt8,
) raises -> List[Row]:
    """Scan a CSV byte buffer into a list of Row records (Phase 1 chassis).

    8-byte `ContainsZeroByte` STANDARD-state fast skip
    + per-byte FSA tail loop.

    The `Q: QuoteStyle` comptime parameter selects the dialect:
      - Rfc4180 / Excel: DOUBLE_QUOTE_ESCAPES=True path (RFC `""` escape).
      - Posix:           DOUBLE_QUOTE_ESCAPES=False path (`\\"` escape).
    The state machine compiles two distinct shapes per Q via the
    comptime cascade inside `_step` (no runtime branch).

    Args:
        bytes:      origin-poly Span over the full file contents.
        delimiter:  column separator byte (typically b',').
        quote:      quote byte (typically b'"').

    Returns:
        List[Row] — one per record. Each Row owns its List[CellRange];
        cell ranges are byte-offsets into the caller's `bytes` buffer.

    Raises:
        Error on unterminated quoted region (EOF inside QUOTED state).
    """
    var rows = List[Row]()
    var n = len(bytes)
    if n == 0:
        return rows^

    # Determine the Posix escape byte (0 for Rfc4180/Excel).
    var posix_escape_byte: UInt8 = Q.ESCAPE_BYTE

    var state: UInt8 = CSV_STATE_STANDARD
    var pos: Int = 0
    var cell_start: Int = 0
    var cell_was_quoted: Bool = False
    var cell_needs_unescape: Bool = False
    var cur_row = Row()

    # Phase 1 broadcast words for the ContainsZeroByte fast skip.
    var delim_word = broadcast_byte(delimiter)
    var quote_word = broadcast_byte(quote)
    var cr_word = broadcast_byte(UInt8(0x0D))
    var lf_word = broadcast_byte(UInt8(0x0A))

    # BOM swallow (Excel ACCEPTS_BOM=True). UTF-8 BOM = EF BB BF.
    comptime if Q.ACCEPTS_BOM:
        if (
            n >= 3
            and bytes[0] == UInt8(0xEF)
            and bytes[1] == UInt8(0xBB)
            and bytes[2] == UInt8(0xBF)
        ):
            pos = 3
            cell_start = 3

    while pos < n:
        # Fast skip: when in STANDARD state and we have >=8 bytes remaining,
        # peek 8 bytes for any structural byte. If none, advance 8.
        if state == CSV_STATE_STANDARD and pos + 8 <= n:
            var w = _load_u64_le(bytes, pos)
            if not contains_any_of_4(w, delim_word, quote_word, cr_word, lf_word):
                pos = pos + 8
                continue

        # Per-byte FSA step.
        var b = bytes[pos]
        if state == CSV_STATE_STANDARD:
            if b == delimiter:
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == quote and pos == cell_start:
                state = CSV_STATE_QUOTED
                cell_was_quoted = True
                cell_start = pos + 1  # skip opening quote
                pos = pos + 1
                continue
            if b == UInt8(0x0A):  # LF — row terminator
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                rows.append(cur_row^)
                cur_row = Row()
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == UInt8(0x0D):  # CR — might be CRLF or bare CR
                # Close cell first; finalize row in CR_LF_LOOKAHEAD step.
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                rows.append(cur_row^)
                cur_row = Row()
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            # Otherwise: normal field byte. Advance.
            pos = pos + 1
            continue

        if state == CSV_STATE_QUOTED:
            comptime if Q.DOUBLE_QUOTE_ESCAPES:
                if b == quote:
                    state = CSV_STATE_QUOTE_IN_QUOTED
                    pos = pos + 1
                    continue
                pos = pos + 1
                continue
            else:
                # Posix-style: backslash escape.
                if posix_escape_byte != UInt8(0) and b == posix_escape_byte:
                    state = CSV_STATE_POSIX_ESCAPE
                    cell_needs_unescape = True
                    pos = pos + 1
                    continue
                if b == quote:
                    # Posix close-quote: no doubled-quote interpretation;
                    # next non-quote byte must be delim or newline.
                    var end_excl = pos
                    cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
                    state = CSV_STATE_STANDARD
                    cell_was_quoted = False
                    cell_needs_unescape = False
                    pos = pos + 1
                    # After Posix close-quote: expect delimiter or row end.
                    if pos < n:
                        var nb = bytes[pos]
                        if nb == delimiter:
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0A):
                            rows.append(cur_row^)
                            cur_row = Row()
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0D):
                            rows.append(cur_row^)
                            cur_row = Row()
                            state = CSV_STATE_CR_LF_LOOKAHEAD
                            pos = pos + 1
                            cell_start = pos
                            continue
                    else:
                        # The closing quote was the last byte: the record
                        # ends here. Close the row so the end-of-input
                        # flush does not append a phantom empty field.
                        rows.append(cur_row^)
                        cur_row = Row()
                        cell_start = pos
                        continue
                pos = pos + 1
                continue

        if state == CSV_STATE_QUOTE_IN_QUOTED:
            if b == quote:
                # Doubled-quote escape — stay QUOTED.
                state = CSV_STATE_QUOTED
                cell_needs_unescape = True
                pos = pos + 1
                continue
            # Close-quote, then re-process this byte in STANDARD.
            # Cell range is (cell_start, pos-1) because the previous byte
            # was the closing quote.
            var end_excl = pos - 1
            cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
            cell_was_quoted = False
            cell_needs_unescape = False
            state = CSV_STATE_STANDARD
            # Re-process current byte in STANDARD (don't advance pos).
            if b == delimiter:
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0A):
                rows.append(cur_row^)
                cur_row = Row()
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0D):
                rows.append(cur_row^)
                cur_row = Row()
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                continue
            # Otherwise it's a stray byte after a closed quote --
            # tolerant behavior: treat as field-body bytes of a new
            # un-quoted region. cell_start stays at the now-stale value
            # so the field will start with whatever bytes came after the
            # close-quote -- mirrors DuckDB's strict_mode=false MAYBE_QUOTED.
            cell_start = pos
            pos = pos + 1
            continue

        if state == CSV_STATE_POSIX_ESCAPE:
            # Consume one literal byte and return to QUOTED.
            state = CSV_STATE_QUOTED
            pos = pos + 1
            continue

        if state == CSV_STATE_CR_LF_LOOKAHEAD:
            if b == UInt8(0x0A):
                # CRLF -> already emitted the row in CR; just consume LF.
                pos = pos + 1
                cell_start = pos
                state = CSV_STATE_STANDARD
                continue
            # Bare CR: only valid for Q.ACCEPT_CR_NEWLINES (Excel). For
            # Rfc4180/Posix the row was already emitted (tolerant); we
            # return to STANDARD without consuming the byte.
            state = CSV_STATE_STANDARD
            continue

        # Unreachable
        pos = pos + 1  # cov: unreachable every FSA state arm above ends in continue

    # Flush the last in-progress cell + row (if the file doesn't end with
    # a trailing newline).
    if state == CSV_STATE_QUOTED or state == CSV_STATE_POSIX_ESCAPE:
        raise Error(
            "csv_scanner_phase1: unterminated quoted region (EOF inside"
            " QUOTED state); file may be truncated or have mismatched"
            " quotes."
        )

    if state == CSV_STATE_QUOTE_IN_QUOTED:
        # Last cell closed by EOF after a quote.
        var end_excl = n - 1
        cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
        rows.append(cur_row^)
    else:
        # STANDARD-state at EOF.
        if pos > cell_start or len(cur_row.cells) > 0:
            cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
            rows.append(cur_row^)

    return rows^


# =============================================================================
# Private helpers.
# =============================================================================


@always_inline
def _load_u64_le(bytes: Span[UInt8, _], pos: Int) -> UInt64:
    """Load 8 bytes at `pos` as a little-endian UInt64.

    SAFETY: caller has verified `pos + 8 <= len(bytes)`. The 8-byte
    window stays within the Span's origin so this is encapsulation-safe
    (read-only span access). NO UnsafePointer crosses a module boundary —
    the bytes are read via the Span subscript inside this helper.
    """
    # Endian-independent load: pull 8 bytes via subscript and assemble.
    # Modern compilers fold this into a single MOV; the LE/BE detection
    # is comptime so M3/M4 + x86 produce identical machine code.
    var b0 = UInt64(bytes[pos])
    var b1 = UInt64(bytes[pos + 1]) << 8
    var b2 = UInt64(bytes[pos + 2]) << 16
    var b3 = UInt64(bytes[pos + 3]) << 24
    var b4 = UInt64(bytes[pos + 4]) << 32
    var b5 = UInt64(bytes[pos + 5]) << 40
    var b6 = UInt64(bytes[pos + 6]) << 48
    var b7 = UInt64(bytes[pos + 7]) << 56
    return b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7


# =============================================================================
# Phase 2 — movemask_u8x32 32-byte SIMD batch scan.
# =============================================================================
#
# Swaps the Phase 1 8-byte ContainsZeroByte STANDARD-state fast skip
# for a 32-byte SIMD batch via the byte_class.byte_find_eq_4_u8x32
# primitive (AVX2 `vpcmpeqb` x4 + OR-fold on x86; NEON 4× `cmeq.16b`
# split across two halves on ARM).
#
# The structure is IDENTICAL to scan_csv_phase1; only the STANDARD-state
# fast-skip block changes. FSA transitions + per-Q quote-state machine
# + cell emission + BOM handling + EOF cleanup are byte-for-byte the
# same. The acceptance gate is "variant 1 and variant 2 produce
# identical Row lists on every input" (asserted by 10 parity tests in
# tests/test_csv_scanner_phase2_movemask.mojo).
#
# Algorithmic detail: when a 32-byte chunk has zero specials (`bits ==
# 0`), advance 32 in a single step. When at least one special is
# present, advance `pos` to the FIRST set-bit position (via
# `count_trailing_zeros`), then fall through to the per-byte FSA step.
# The next iteration re-enters the fast-skip; for cells that span many
# chunks, this gives O(chunks) STANDARD-state cost — the lighter weight
# vs Phase 1's O(chunks × 4) byte-equality cost in the same window.
# =============================================================================


@always_inline
def _load_u8x32(bytes: Span[UInt8, _], pos: Int) -> SIMD[DType.uint8, 32]:
    """Load 32 bytes at `pos` as a SIMD[uint8, 32] chunk.

    SAFETY: caller has verified `pos + 32 <= len(bytes)`. The 32-byte
    window stays within the Span's origin so this is encapsulation-safe
    (read-only span access). The UnsafePointer materialized here is
    INTERNAL to this module — never crosses a public function boundary.
    Mirrors the JSON reader's structural-index 16-byte load idiom scaled
    to AVX2 width.
    """
    var base_ptr = bytes.unsafe_ptr()
    return (base_ptr + pos).load[width=32](0)


def scan_csv_phase2_movemask[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    delimiter: UInt8,
    quote: UInt8,
) raises -> List[Row]:
    """Scan a CSV byte buffer with the Phase 2 SIMD movemask chassis.

    Replaces Phase 1's 8-byte UInt64-arithmetic
    STANDARD-state fast skip with a 32-byte SIMD batch via the
    `byte_find_eq_4_u8x32` + `movemask_to_uint_u8x32` primitives.

    The `Q: QuoteStyle` comptime parameter selects the dialect
    (identical to Phase 1; no change in the FSA cascade). Per-byte
    FSA tail step + quote-state machine + cell range emission are
    BYTE-FOR-BYTE the same as `scan_csv_phase1[Q]`.

    Args:
        bytes:      Origin-poly Span over the full file contents.
        delimiter:  Column separator byte (typically b',').
        quote:      Quote byte (typically b'"').

    Returns:
        List[Row] — one per record. Byte-identical to the output of
        `scan_csv_phase1[Q]` on the same input (asserted by
        test_csv_scanner_phase2_movemask).

    Raises:
        Error on unterminated quoted region (EOF inside QUOTED state).
    """
    var rows = List[Row]()
    var n = len(bytes)
    if n == 0:
        return rows^

    var posix_escape_byte: UInt8 = Q.ESCAPE_BYTE

    var state: UInt8 = CSV_STATE_STANDARD
    var pos: Int = 0
    var cell_start: Int = 0
    var cell_was_quoted: Bool = False
    var cell_needs_unescape: Bool = False
    var cur_row = Row()

    # BOM swallow (Excel ACCEPTS_BOM=True). UTF-8 BOM = EF BB BF.
    comptime if Q.ACCEPTS_BOM:
        if (
            n >= 3
            and bytes[0] == UInt8(0xEF)
            and bytes[1] == UInt8(0xBB)
            and bytes[2] == UInt8(0xBF)
        ):
            pos = 3
            cell_start = 3

    while pos < n:
        # Phase 2 SIMD fast skip: STANDARD-state-only. The chunk is 32
        # bytes; the bytemask flags any byte equal to delim / quote /
        # CR / LF. If the bitmask is zero, the entire chunk is body
        # bytes -- skip 32. Else: advance to the first set-bit position
        # and let the per-byte FSA step process that byte (the next
        # iteration re-enters the SIMD fast-skip if we're back in
        # STANDARD state, otherwise the per-byte tail loop handles the
        # quoted region until close-quote).
        if state == CSV_STATE_STANDARD and pos + 32 <= n:
            var chunk = _load_u8x32(bytes, pos)
            var bm = byte_find_eq_4_u8x32(
                chunk,
                delimiter,
                quote,
                UInt8(0x0D),  # CR
                UInt8(0x0A),  # LF
            )
            var bits = movemask_to_uint_u8x32(bm)
            if bits == UInt32(0):
                pos = pos + 32
                continue
            # Has at least one special; advance to the first set bit
            # within this chunk, then fall through to the per-byte FSA
            # step for that byte. The next iteration of the outer loop
            # re-enters the fast skip if we're still in STANDARD state.
            var k = Int(count_trailing_zeros(bits))
            pos = pos + k

        # Per-byte FSA step (UNCHANGED from Phase 1 -- byte-identical
        # behavior across the variant boundary).
        var b = bytes[pos]
        if state == CSV_STATE_STANDARD:
            if b == delimiter:
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == quote and pos == cell_start:
                state = CSV_STATE_QUOTED
                cell_was_quoted = True
                cell_start = pos + 1
                pos = pos + 1
                continue
            if b == UInt8(0x0A):  # LF
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                rows.append(cur_row^)
                cur_row = Row()
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == UInt8(0x0D):  # CR
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                rows.append(cur_row^)
                cur_row = Row()
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            # Otherwise: normal field byte. (Reachable in the sub-32-byte
            # tail when SIMD fast skip is not taken.)
            pos = pos + 1
            continue

        if state == CSV_STATE_QUOTED:
            comptime if Q.DOUBLE_QUOTE_ESCAPES:
                if b == quote:
                    state = CSV_STATE_QUOTE_IN_QUOTED
                    pos = pos + 1
                    continue
                pos = pos + 1
                continue
            else:
                if posix_escape_byte != UInt8(0) and b == posix_escape_byte:
                    state = CSV_STATE_POSIX_ESCAPE
                    cell_needs_unescape = True
                    pos = pos + 1
                    continue
                if b == quote:
                    var end_excl = pos
                    cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
                    state = CSV_STATE_STANDARD
                    cell_was_quoted = False
                    cell_needs_unescape = False
                    pos = pos + 1
                    if pos < n:
                        var nb = bytes[pos]
                        if nb == delimiter:
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0A):
                            rows.append(cur_row^)
                            cur_row = Row()
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0D):
                            rows.append(cur_row^)
                            cur_row = Row()
                            state = CSV_STATE_CR_LF_LOOKAHEAD
                            pos = pos + 1
                            cell_start = pos
                            continue
                    else:
                        # The closing quote was the last byte: the record
                        # ends here. Close the row so the end-of-input
                        # flush does not append a phantom empty field.
                        rows.append(cur_row^)
                        cur_row = Row()
                        cell_start = pos
                        continue
                pos = pos + 1
                continue

        if state == CSV_STATE_QUOTE_IN_QUOTED:
            if b == quote:
                state = CSV_STATE_QUOTED
                cell_needs_unescape = True
                pos = pos + 1
                continue
            var end_excl = pos - 1
            cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
            cell_was_quoted = False
            cell_needs_unescape = False
            state = CSV_STATE_STANDARD
            if b == delimiter:
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0A):
                rows.append(cur_row^)
                cur_row = Row()
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0D):
                rows.append(cur_row^)
                cur_row = Row()
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                continue
            cell_start = pos
            pos = pos + 1
            continue

        if state == CSV_STATE_POSIX_ESCAPE:
            state = CSV_STATE_QUOTED
            pos = pos + 1
            continue

        if state == CSV_STATE_CR_LF_LOOKAHEAD:
            if b == UInt8(0x0A):
                pos = pos + 1
                cell_start = pos
                state = CSV_STATE_STANDARD
                continue
            state = CSV_STATE_STANDARD
            continue

        # Unreachable
        pos = pos + 1  # cov: unreachable every FSA state arm above ends in continue

    if state == CSV_STATE_QUOTED or state == CSV_STATE_POSIX_ESCAPE:
        raise Error(
            "csv_scanner_phase2_movemask: unterminated quoted region"
            " (EOF inside QUOTED state); file may be truncated or have"
            " mismatched quotes."
        )

    if state == CSV_STATE_QUOTE_IN_QUOTED:
        var end_excl = n - 1
        cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
        rows.append(cur_row^)
    else:
        if pos > cell_start or len(cur_row.cells) > 0:
            cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
            rows.append(cur_row^)

    return rows^


# =============================================================================
# Phase 3 — PCLMULQDQ / PMULL64 simdcsv-tier 64-byte SIMD scan
# =============================================================================
#
# After the simdcsv design (Langdale and Lemire): instead of running
# the per-byte FSA over every byte in QUOTED state (the dominant cost in
# Phase 2 on quote-heavy data), use a 64-byte SIMD batch + PCLMULQDQ /
# PMULL64 to compute the in-string mask (bit k = 1 iff byte k is INSIDE
# a quoted region) in ONE carry-less-multiply instruction.  Then for
# each set bit in the candidate-special bitmask
# `(quote | escape) | (delim | nl | cr) & ~quote_region`, advance to the
# bit position via `count_trailing_zeros` and run a per-byte FSA step.
#
# The optimization vs Phase 2:
#   - Phase 2 fast-skip is STANDARD-state-only (32-byte chunks).
#   - Phase 3 batches ALL state across 64-byte chunks; the quote-region
#     mask filters out delim/nl/cr positions INSIDE quoted regions
#     (where they would be no-op FSA steps in Phase 1/2), so the ctz
#     iteration count drops dramatically on quote-heavy data.
#
# Byte-identity with Phase 1/2 is preserved: every position visited by
# the per-byte FSA step is one that Phase 2 would also have visited
# (delim/nl/cr OUTSIDE quotes + quote/escape ANY position).  Positions
# masked out by the quote_region filter are STANDARD-state delim/nl/cr
# bytes that lie WITHIN a quoted region — those bytes would only have
# advanced `pos` by 1 in Phase 1/2 (no cell-boundary or row-boundary
# effect inside QUOTED state) — so skipping them is observably
# equivalent on the Row output.
#
# Cross-chunk carry: PCLMULQDQ's input is a 64-bit bitmask, so cross-
# chunk quote-region state is threaded via `quote_carry: Bool` (True
# iff the previous chunk ended INSIDE a quoted region).  The
# `quote_region_mask_u64_with_carry_out` primitive handles both the
# carry-in XOR and the carry-out extraction.
#
# RFC-4180 doubled-quote pre-cancellation: a `""` pair represents an
# escaped single quote (NOT a region open + close).  We detect adjacent
# bit pairs in `quote_bits` and clear both — this is the
# `_cancel_doubled_quotes_u64` helper.  After cancellation, the
# remaining `1` bits are unambiguous open / close quotes that toggle
# the quote-region state correctly via PCLMULQDQ.
#
# Per-arch dispatch is fully encapsulated in `quote_region_mask_u64`:
#   - x86 with PCLMULQDQ: `vpcmpeqb` + `vpmovmskb` + `pclmulqdq`
#   - ARM with PMULL64: `cmeq.16b` + `pmull` (in-tree precedent: crc32)
#   - Other targets: `prefix_xor_u64` shift-XOR ladder fallback
# =============================================================================


@always_inline
def _load_u8x64(bytes: Span[UInt8, _], pos: Int) -> SIMD[DType.uint8, 64]:
    """Load 64 bytes at `pos` as a SIMD[uint8, 64] chunk.

    SAFETY: caller has verified `pos + 64 <= len(bytes)`. The 64-byte
    window stays within the Span's origin so this is encapsulation-safe
    (read-only span access). The UnsafePointer materialized here is
    INTERNAL to this module — never crosses a public function boundary.
    Mirror of `_load_u8x32`, scaled to AVX-512 BW width.
    """
    var base_ptr = bytes.unsafe_ptr()
    return (base_ptr + pos).load[width=64](0)


@always_inline
def _cancel_doubled_quotes_u64(
    quote_bits: UInt64, mut tail_carry: Bool, next_byte_is_quote: Bool
) -> UInt64:
    """For RFC-4180-style dialects: pre-cancel `""` doubled-quote pairs.

    A `""` pair represents an escaped single quote (the FSA handles
    this via QUOTE_IN_QUOTED → QUOTED transition).  For the purpose of
    quote-region computation via PCLMULQDQ, we must clear both bits of
    each adjacent pair — otherwise the carry-less multiply would flip
    the in-string state twice for what's logically a single literal
    quote byte, leaving the region state correct ONLY by accident.

    Algorithm: iterate paired bits via `quote_bits & (quote_bits >> 1)`.
    The result has bit k set iff bytes k AND k+1 are both quotes — i.e.
    the LOW bit of each adjacent pair.  Shift left by 1 to get the
    high bit positions.  XOR both into the original to clear the pair.

    Cross-chunk: `tail_carry` means "the previous chunk's byte 63 was the LOW
    half of a `""` pair straddling the boundary, and its bit was cleared
    there" — so this chunk must clear its bit 0 to cancel the high half.
    `next_byte_is_quote` is a ONE-BYTE lookahead at `chunk_base + 64` (False
    at end-of-input) and is what makes the straddling case decidable at the
    point where bit 63 is classified; see the block at the end of the body.
    """
    var bits = quote_bits

    # Cross-chunk carry: if the prior chunk's last byte was a quote AND
    # this chunk's first byte is a quote, that's a boundary-straddling
    # pair — clear bit 0 here (the prior chunk already cleared its bit
    # 63 via the same tail_carry path).
    if tail_carry and (bits & UInt64(1)) != 0:
        bits = bits & ~UInt64(1)

    # Find adjacent pairs: bit k of `pairs_lo` = 1 iff bytes k AND k+1
    # are both quotes (i.e. k is the LOW bit of the pair).
    var pairs_lo = bits & (bits >> UInt64(1))

    # Iterate non-overlapping pairs: we need to clear only the FIRST
    # pair starting at each run of N consecutive quote bits, not every
    # overlapping pair.  Use a greedy left-to-right scan via while
    # loop on the bitmask.  Each iteration: tzcnt to find the lowest
    # pair, clear both bits, also clear the pair bit one position to
    # the right (so we don't double-count `"""` as two pairs starting
    # one byte apart — RFC-4180 interpretation: `"""` is a quoted-empty
    # cell `""` then continues, so the FIRST pair is bytes 0,1 cancelled,
    # byte 2 is a real quote).
    while pairs_lo != UInt64(0):
        var k = Int(count_trailing_zeros(pairs_lo))
        var low_mask = UInt64(1) << UInt64(k)
        var high_mask = UInt64(1) << UInt64(k + 1)
        bits = bits & ~(low_mask | high_mask)
        # Clear the pair flag at k (already consumed) and at k+1 (so
        # that an `"""` triplet doesn't fire pair at k+1 too).
        pairs_lo = pairs_lo & ~(low_mask | (low_mask << UInt64(1)))

    # ⚠ BOUNDARY-STRADDLING PAIR (see the falsifier
    # `test_phase3_matches_phase1_on_doubled_quotes`).
    #
    # If bit 63 is a quote that SURVIVED in-chunk pairing, it is either
    #   (a) the LOW half of a `""` pair whose high half is byte 0 of the NEXT
    #       chunk — both bits are literal content and NEITHER may toggle the
    #       quote region; or
    #   (b) a genuine region-toggling quote.
    # Always taking (b) is wrong: it leaves bit 63 SET (toggling the region
    # CLOSED at that byte) and clears the next chunk's bit 0 (so nothing
    # re-opens it). From there the region mask is INVERTED for the rest of the
    # row: the cell's real closing quote re-opens it, and the following
    # delimiter and newline are filtered out of `candidates` as "string
    # interior", so the scanner runs the cell to the next surviving candidate
    # (e.g. `"he said ""hi""",6\n` with the `""` straddling a 64-byte
    # boundary yields one oversized cell where variants 1/2 emit two).
    #
    # A ONE-BYTE lookahead decides it exactly, so the ambiguity is removed
    # rather than guessed: `next_byte_is_quote` is byte `chunk_base + 64`
    # (False at end-of-input, which is correct — an unterminated tail quote is
    # a real quote, and the FSA raises on it separately).
    var hi_bit_survived = (bits & UInt64(0x8000000000000000)) != 0
    if hi_bit_survived and next_byte_is_quote:
        # Case (a): straddling pair. Cancel BOTH halves — clear bit 63 here,
        # and signal the next chunk to clear its bit 0 via `tail_carry`.
        bits = bits & ~UInt64(0x8000000000000000)
        tail_carry = True
    else:
        # Case (b) (or no high quote at all): bit 63 stays as-is and there is
        # no pair to cancel across the boundary.
        tail_carry = False

    return bits


def scan_csv_phase3_pclmulqdq[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    delimiter: UInt8,
    quote: UInt8,
) raises -> List[Row]:
    """Scan a CSV byte buffer with the Phase 3 simdcsv-tier chassis.

    64-byte SIMD batch + PCLMULQDQ (x86) / PMULL64
    (ARM) quote-region mask + iterative bitmask fallback for
    non-clmul platforms.  Filters delim/nl/cr positions INSIDE quoted
    regions out of the candidate-special bitmask, dramatically reducing
    the per-byte FSA step count on quote-heavy data vs Phase 2.

    The `Q: QuoteStyle` comptime parameter selects the dialect
    (identical to Phase 1/2; no change in the FSA cascade).  Per-byte
    FSA step + quote-state machine + cell-range emission are
    BYTE-FOR-BYTE the same as `scan_csv_phase{1,2}[Q]`.

    Args:
        bytes:      Origin-poly Span over the full file contents.
        delimiter:  Column separator byte (typically b',').
        quote:      Quote byte (typically b'"').

    Returns:
        List[Row] — one per record.  Byte-identical to the output of
        `scan_csv_phase1[Q]` and `scan_csv_phase2_movemask[Q]` on the
        same input (asserted by `tests/test_csv_scanner_phase3_pclmulqdq.mojo`).

    Raises:
        Error on unterminated quoted region (EOF inside QUOTED state).
    """
    var rows = List[Row]()
    var n = len(bytes)
    if n == 0:
        return rows^

    var posix_escape_byte: UInt8 = Q.ESCAPE_BYTE

    var state: UInt8 = CSV_STATE_STANDARD
    var pos: Int = 0
    var cell_start: Int = 0
    var cell_was_quoted: Bool = False
    var cell_needs_unescape: Bool = False
    var cur_row = Row()

    # BOM swallow (Excel ACCEPTS_BOM=True). UTF-8 BOM = EF BB BF.
    comptime if Q.ACCEPTS_BOM:
        if (
            n >= 3
            and bytes[0] == UInt8(0xEF)
            and bytes[1] == UInt8(0xBB)
            and bytes[2] == UInt8(0xBF)
        ):
            pos = 3
            cell_start = 3

    # PCLMULQDQ batch-level state for the quote-region mask.
    # `quote_region_carry`: True iff the prior chunk ended INSIDE a
    # quoted region (carry-in to next chunk's clmul).
    # `doubled_quote_tail_carry`: True iff the prior chunk's last byte
    # was a quote AND was NOT consumed as the HIGH bit of a doubled-
    # quote pair (only meaningful when Q.DOUBLE_QUOTE_ESCAPES is True).
    var quote_region_carry: Bool = False
    var doubled_quote_tail_carry: Bool = False

    # Pending candidate-special bitmask from the current 64-byte chunk.
    # When non-zero, we consume set bits from low to high via tzcnt +
    # blsr (bit-clear-lowest-set).  When zero, we advance `pos` to the
    # next 64-byte boundary and reload.
    var chunk_base: Int = -1  # byte offset of the first byte in `pending_bits`
    var chunk_valid: Bool = False  # True iff a 64-byte chunk is loaded
    var pending_bits: UInt64 = UInt64(0)

    while pos < n:
        # Re-batch if we've outrun the current chunk's mask OR we haven't
        # loaded one yet.
        if not chunk_valid or pos >= chunk_base + 64:
            if pos + 64 <= n:
                # 64-byte SIMD chunk load.
                var chunk = _load_u8x64(bytes, pos)
                # Quote bitmask: bit k = 1 iff byte k is the quote byte.
                var quote_bm = byte_eq_to_bytemask_u8x64(chunk, quote)
                var quote_bits = movemask_to_uint_u8x64(quote_bm)

                # RFC-4180 doubled-quote pre-cancellation: clear adjacent
                # `""` pair bits so they don't fire two region-toggle
                # transitions via clmul.  Posix dialects skip this step
                # (escape is `\\"`, a different byte; pairs of `""`
                # in Posix are TWO consecutive open/close events that
                # PCLMULQDQ handles correctly without preprocessing).
                var quote_bits_canon: UInt64
                comptime if Q.DOUBLE_QUOTE_ESCAPES:
                    # One-byte lookahead so a `""` pair straddling this
                    # chunk's tail is classified exactly rather than guessed.
                    var next_is_quote = (
                        pos + 64 < n and bytes[pos + 64] == quote
                    )
                    quote_bits_canon = _cancel_doubled_quotes_u64(
                        quote_bits, doubled_quote_tail_carry, next_is_quote
                    )
                else:
                    quote_bits_canon = quote_bits

                # Quote-region mask: bit k = 1 iff byte k is INSIDE a
                # quoted region.  PCLMULQDQ on x86, PMULL64 on ARM,
                # prefix_xor_u64 shift-ladder fallback elsewhere.
                # Threads `quote_region_carry` across chunks.
                var quote_region = quote_region_mask_u64(
                    quote_bits_canon, quote_region_carry
                )
                # Update carry-out for next chunk: high bit of result.
                quote_region_carry = (
                    quote_region & UInt64(0x8000000000000000)
                ) != 0

                # Specials bitmask: delim | nl | cr (using 4-needle scan
                # with one duplicate slot; quote handled separately).
                var specials_bm = byte_find_eq_4_u8x64(
                    chunk,
                    delimiter,
                    UInt8(0x0A),  # LF
                    UInt8(0x0D),  # CR
                    delimiter,    # duplicate (no 3-needle u8x64 helper)
                )
                var specials_bits = movemask_to_uint_u8x64(specials_bm)

                # Escape bitmask (Posix only): bit k = 1 iff byte k is
                # the Posix escape byte (typically `\\`).
                var escape_bits: UInt64
                comptime if Q.DOUBLE_QUOTE_ESCAPES:
                    escape_bits = UInt64(0)
                else:
                    if posix_escape_byte != UInt8(0):
                        var esc_bm = byte_eq_to_bytemask_u8x64(
                            chunk, posix_escape_byte
                        )
                        escape_bits = movemask_to_uint_u8x64(esc_bm)
                    else:
                        escape_bits = UInt64(0)

                # Candidate-special bitmask:
                #   - delim / nl / cr OUTSIDE quoted regions
                #   - quote ANY position (FSA must react to enter/exit)
                #   - escape INSIDE quoted regions (Posix only)
                # The "& ~quote_region" filter on specials_bits is the
                # PCLMULQDQ win: drops delim/nl/cr inside quoted body.
                var candidates = (specials_bits & ~quote_region) | quote_bits
                comptime if not Q.DOUBLE_QUOTE_ESCAPES:
                    # Posix escape bytes inside quoted regions matter
                    # (they flip state to POSIX_ESCAPE).  Outside, an
                    # escape byte is a normal field byte — exclude it.
                    candidates = candidates | (escape_bits & quote_region)

                chunk_base = pos
                chunk_valid = True
                pending_bits = candidates
            else:
                # Tail < 64 bytes: fall through to per-byte FSA via the
                # legacy Phase 1 path (no SIMD fast-skip available for
                # sub-chunk tail; correctness > marginal perf).
                chunk_valid = False
                pending_bits = UInt64(0)

        # Walk to the next candidate position in the current chunk.
        #
        # ⚠ STATE GUARD. The jump is legal ONLY in the two
        # STABLE states, exactly like the chunk-end fast-forward below --
        # without this condition variant 3 is NOT byte-identical to
        # variants 1/2.
        #
        # In the three TRANSIENT states the byte AT `pos` is load-bearing and
        # must be stepped, not skipped:
        #   * QUOTE_IN_QUOTED computes `end_excl = pos - 1` on the assumption
        #     that `pos` is exactly one past the closing quote. After a jump
        #     it is not, so `a,"xy"zzzz,` emitted ONE cell ending at
        #     (comma - 1) where variants 1/2 emit TWO, the first ending at
        #     the closing quote -- corrupt cell CONTENT (the range stays
        #     in-bounds, so no bounds check was ever going to catch it).
        #   * POSIX_ESCAPE consumes exactly one byte unconditionally; after a
        #     jump it consumes the CANDIDATE byte (e.g. the closing quote),
        #     so the quoted region never terminates.
        #   * CR_LF_LOOKAHEAD must inspect the very next byte for the `\n`.
        if (
            chunk_valid
            and pending_bits != UInt64(0)
            and (state == CSV_STATE_STANDARD or state == CSV_STATE_QUOTED)
        ):
            # The lowest set bit in `pending_bits` corresponds to byte
            # `chunk_base + tzcnt(pending_bits)`.  Skip ahead to that
            # position if it's still ahead of `pos`.
            var k = Int(count_trailing_zeros(pending_bits))
            var target = chunk_base + k
            if target > pos:
                pos = target
            # Clear the lowest set bit so the NEXT iteration sees the
            # next candidate.
            pending_bits = pending_bits & (pending_bits - UInt64(1))
            # Re-check loop invariant before stepping FSA.
            if pos >= n:
                break  # cov: unreachable a candidate bit names a byte of a full 64-byte chunk, so pos < n
        elif chunk_valid and pending_bits == UInt64(0) and pos < chunk_base + 64:
            # Fast-forward: no more candidates in this chunk.  Safe to
            # jump to chunk-end ONLY if the FSA state is "stable" (i.e.
            # not in a transient single-byte transition state like
            # QUOTE_IN_QUOTED, POSIX_ESCAPE, or CR_LF_LOOKAHEAD — those
            # consume exactly 1 byte and MUST be processed).  In
            # STANDARD or QUOTED, all state-changing bytes were
            # candidates (delim/nl/cr if outside quotes; quote anywhere;
            # escape inside quotes) — by construction, the remaining
            # chunk bytes are non-special body bytes.
            if (
                state == CSV_STATE_STANDARD
                or state == CSV_STATE_QUOTED
            ):
                pos = chunk_base + 64
                continue

        # Per-byte FSA step (UNCHANGED from Phase 1/2 — byte-identical
        # behavior across all three variants).
        var b = bytes[pos]
        if state == CSV_STATE_STANDARD:
            if b == delimiter:
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == quote and pos == cell_start:
                state = CSV_STATE_QUOTED
                cell_was_quoted = True
                cell_start = pos + 1
                pos = pos + 1
                continue
            if b == UInt8(0x0A):  # LF
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                rows.append(cur_row^)
                cur_row = Row()
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == UInt8(0x0D):  # CR
                cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
                rows.append(cur_row^)
                cur_row = Row()
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            # Otherwise: normal field byte.
            pos = pos + 1
            continue

        if state == CSV_STATE_QUOTED:
            comptime if Q.DOUBLE_QUOTE_ESCAPES:
                if b == quote:
                    state = CSV_STATE_QUOTE_IN_QUOTED
                    pos = pos + 1
                    continue
                pos = pos + 1
                continue
            else:
                if posix_escape_byte != UInt8(0) and b == posix_escape_byte:
                    state = CSV_STATE_POSIX_ESCAPE
                    cell_needs_unescape = True
                    pos = pos + 1
                    continue
                if b == quote:
                    var end_excl = pos
                    cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
                    state = CSV_STATE_STANDARD
                    cell_was_quoted = False
                    cell_needs_unescape = False
                    pos = pos + 1
                    if pos < n:
                        var nb = bytes[pos]
                        if nb == delimiter:
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0A):
                            rows.append(cur_row^)
                            cur_row = Row()
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0D):
                            rows.append(cur_row^)
                            cur_row = Row()
                            state = CSV_STATE_CR_LF_LOOKAHEAD
                            pos = pos + 1
                            cell_start = pos
                            continue
                    else:
                        # The closing quote was the last byte: the record
                        # ends here. Close the row so the end-of-input
                        # flush does not append a phantom empty field.
                        rows.append(cur_row^)
                        cur_row = Row()
                        cell_start = pos
                        continue
                pos = pos + 1
                continue

        if state == CSV_STATE_QUOTE_IN_QUOTED:
            if b == quote:
                state = CSV_STATE_QUOTED
                cell_needs_unescape = True
                pos = pos + 1
                continue
            var end_excl = pos - 1
            cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
            cell_was_quoted = False
            cell_needs_unescape = False
            state = CSV_STATE_STANDARD
            if b == delimiter:
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0A):
                rows.append(cur_row^)
                cur_row = Row()
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0D):
                rows.append(cur_row^)
                cur_row = Row()
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                continue
            cell_start = pos
            pos = pos + 1
            continue

        if state == CSV_STATE_POSIX_ESCAPE:
            state = CSV_STATE_QUOTED
            pos = pos + 1
            continue

        if state == CSV_STATE_CR_LF_LOOKAHEAD:
            if b == UInt8(0x0A):
                pos = pos + 1
                cell_start = pos
                state = CSV_STATE_STANDARD
                continue
            state = CSV_STATE_STANDARD
            continue

        # Unreachable
        pos = pos + 1  # cov: unreachable every FSA state arm above ends in continue

    if state == CSV_STATE_QUOTED or state == CSV_STATE_POSIX_ESCAPE:
        raise Error(
            "csv_scanner_phase3_pclmulqdq: unterminated quoted region"
            " (EOF inside QUOTED state); file may be truncated or have"
            " mismatched quotes."
        )

    if state == CSV_STATE_QUOTE_IN_QUOTED:
        var end_excl = n - 1
        cur_row.cells.append(CellRange(cell_start, end_excl, cell_was_quoted, cell_needs_unescape))
        rows.append(cur_row^)
    else:
        if pos > cell_start or len(cur_row.cells) > 0:
            cur_row.cells.append(CellRange(cell_start, pos, cell_was_quoted, cell_needs_unescape))
            rows.append(cur_row^)

    return rows^


# =============================================================================
# Flat-buffer scanner variants.
# =============================================================================
#
# Because a `List[Row]` + per-row `List[CellRange]` allocation cascade is a
# large share of the single-thread wall, the
# variants below emit cells into a 4-buffer `ScannedCells` struct that
# mirrors pyarrow's `RawBlockBuffer` / DuckDB's `DataChunk` / polars'
# per-worker partition buffers.
#
# The scanner FSA + per-byte step logic is BYTE-IDENTICAL to the legacy
# Phase 1 / Phase 2 / Phase 3 scanners above; the ONLY change is the
# cell-emit shape:
#   legacy:  cur_row.cells.append(CellRange(start, end, q, ue))
#            rows.append(cur_row^); cur_row = Row()
#   flat:    cells.cell_starts.append(start)
#            cells.cell_ends.append(end)
#            cells.cell_flags.append(pack_cell_flags(q, ue))
#            cells.row_starts.append(len(cells.cell_starts))  (at row end)
#
# Pre-sizing hint: estimate `est_cells = n_bytes / 12` (avg cell ~12 bytes
# for TPC-H lineitem) and `est_rows = n_bytes / 120`. List doubles
# capacity on overrun -- 2x over-estimation is benign and a 2x under-
# estimation incurs ~log2 reallocs (versus ~96 M reallocs in the legacy
# per-cell shape).
# =============================================================================


@always_inline
def _estimate_capacities(n_bytes: Int) -> Tuple[Int, Int]:
    """Heuristic pre-size: avg ~12 bytes/cell, ~120 bytes/row (TPC-H
    lineitem shape).

    Returns (est_cells, est_rows). Floor of 64 to avoid tiny-file churn.
    """
    var est_cells = n_bytes // 12
    if est_cells < 64:
        est_cells = 64
    var est_rows = n_bytes // 120
    if est_rows < 16:
        est_rows = 16
    return (est_cells, est_rows)


def scan_csv_phase1_into_cells[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    delimiter: UInt8,
    quote: UInt8,
) raises -> ScannedCells:
    """Phase 1 chassis -- flat-buffer emit variant.

    Identical FSA + 8-byte ContainsZeroByte fast-skip to
    `scan_csv_phase1`, but emits cells into a pre-sized `ScannedCells`
    struct (4 contiguous Lists) rather than `List[Row]` of
    `List[CellRange]`. Eliminates ~96 M per-cell List.append events on
    TPC-H SF1 lineitem.
    """
    var est = _estimate_capacities(len(bytes))
    var cells = ScannedCells(est[0], est[1])
    var n = len(bytes)
    if n == 0:
        return cells^

    var posix_escape_byte: UInt8 = Q.ESCAPE_BYTE

    var state: UInt8 = CSV_STATE_STANDARD
    var pos: Int = 0
    var cell_start: Int = 0
    var cell_was_quoted: Bool = False
    var cell_needs_unescape: Bool = False

    var delim_word = broadcast_byte(delimiter)
    var quote_word = broadcast_byte(quote)
    var cr_word = broadcast_byte(UInt8(0x0D))
    var lf_word = broadcast_byte(UInt8(0x0A))

    comptime if Q.ACCEPTS_BOM:
        if (
            n >= 3
            and bytes[0] == UInt8(0xEF)
            and bytes[1] == UInt8(0xBB)
            and bytes[2] == UInt8(0xBF)
        ):
            pos = 3
            cell_start = 3

    while pos < n:
        if state == CSV_STATE_STANDARD and pos + 8 <= n:
            var w = _load_u64_le(bytes, pos)
            if not contains_any_of_4(w, delim_word, quote_word, cr_word, lf_word):
                pos = pos + 8
                continue

        var b = bytes[pos]
        if state == CSV_STATE_STANDARD:
            if b == delimiter:
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == quote and pos == cell_start:
                state = CSV_STATE_QUOTED
                cell_was_quoted = True
                cell_start = pos + 1
                pos = pos + 1
                continue
            if b == UInt8(0x0A):
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                cells.row_starts.append(len(cells.cell_starts))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == UInt8(0x0D):
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                cells.row_starts.append(len(cells.cell_starts))
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            pos = pos + 1
            continue

        if state == CSV_STATE_QUOTED:
            comptime if Q.DOUBLE_QUOTE_ESCAPES:
                if b == quote:
                    state = CSV_STATE_QUOTE_IN_QUOTED
                    pos = pos + 1
                    continue
                pos = pos + 1
                continue
            else:
                if posix_escape_byte != UInt8(0) and b == posix_escape_byte:
                    state = CSV_STATE_POSIX_ESCAPE
                    cell_needs_unescape = True
                    pos = pos + 1
                    continue
                if b == quote:
                    var end_excl = pos
                    cells.cell_starts.append(cell_start)
                    cells.cell_ends.append(end_excl)
                    cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                    state = CSV_STATE_STANDARD
                    cell_was_quoted = False
                    cell_needs_unescape = False
                    pos = pos + 1
                    if pos < n:
                        var nb = bytes[pos]
                        if nb == delimiter:
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0A):
                            cells.row_starts.append(len(cells.cell_starts))
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0D):
                            cells.row_starts.append(len(cells.cell_starts))
                            state = CSV_STATE_CR_LF_LOOKAHEAD
                            pos = pos + 1
                            cell_start = pos
                            continue
                        # A byte after the closing quote that is not the
                        # delimiter or a line end: record it (the reader
                        # refuses the record) and start the next field
                        # there, as the doubled-quote dialects do.
                        cells.note_quote_violation(pos, cells.cells_in_open_row() - 1)
                        cell_start = pos
                        pos = pos + 1
                        continue
                    else:
                        # The closing quote was the last byte: the record
                        # ends here. Close the row so the end-of-input
                        # flush does not append a phantom empty field.
                        cells.row_starts.append(len(cells.cell_starts))
                        cell_start = pos
                        continue
                pos = pos + 1
                continue

        if state == CSV_STATE_QUOTE_IN_QUOTED:
            if b == quote:
                state = CSV_STATE_QUOTED
                cell_needs_unescape = True
                pos = pos + 1
                continue
            var end_excl = pos - 1
            cells.cell_starts.append(cell_start)
            cells.cell_ends.append(end_excl)
            cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
            cell_was_quoted = False
            cell_needs_unescape = False
            state = CSV_STATE_STANDARD
            if b == delimiter:
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0A):
                cells.row_starts.append(len(cells.cell_starts))
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0D):
                cells.row_starts.append(len(cells.cell_starts))
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                continue
            # A byte after the closing quote that is not the delimiter or a
            # line end: malformed under every dialect. Record it (the reader
            # refuses the record) and keep the scan going.
            cells.note_quote_violation(pos, cells.cells_in_open_row() - 1)
            cell_start = pos
            pos = pos + 1
            continue

        if state == CSV_STATE_POSIX_ESCAPE:
            state = CSV_STATE_QUOTED
            pos = pos + 1
            continue

        if state == CSV_STATE_CR_LF_LOOKAHEAD:
            if b == UInt8(0x0A):
                pos = pos + 1
                cell_start = pos
                state = CSV_STATE_STANDARD
                continue
            state = CSV_STATE_STANDARD
            continue

        pos = pos + 1  # cov: unreachable every FSA state arm above ends in continue

    if state == CSV_STATE_QUOTED or state == CSV_STATE_POSIX_ESCAPE:
        raise Error(
            "csv_scanner_phase1_into_cells: unterminated quoted region"
            " (EOF inside QUOTED state); file may be truncated or have"
            " mismatched quotes."
        )

    var pending_cells_at_row = len(cells.cell_starts) - cells.row_starts[len(cells.row_starts) - 1]
    if state == CSV_STATE_QUOTE_IN_QUOTED:
        var end_excl = n - 1
        cells.cell_starts.append(cell_start)
        cells.cell_ends.append(end_excl)
        cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
        cells.row_starts.append(len(cells.cell_starts))
    else:
        if pos > cell_start or pending_cells_at_row > 0:
            cells.cell_starts.append(cell_start)
            cells.cell_ends.append(pos)
            cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
            cells.row_starts.append(len(cells.cell_starts))

    return cells^


def scan_csv_phase2_movemask_into_cells[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    delimiter: UInt8,
    quote: UInt8,
) raises -> ScannedCells:
    """Phase 2 movemask chassis -- flat-buffer emit variant.

    Identical FSA + 32-byte movemask fast-skip to
    `scan_csv_phase2_movemask`, but emits cells into a `ScannedCells`
    struct. See `scan_csv_phase1_into_cells` for the emit shape.
    """
    var est = _estimate_capacities(len(bytes))
    var cells = ScannedCells(est[0], est[1])
    var n = len(bytes)
    if n == 0:
        return cells^

    var posix_escape_byte: UInt8 = Q.ESCAPE_BYTE

    var state: UInt8 = CSV_STATE_STANDARD
    var pos: Int = 0
    var cell_start: Int = 0
    var cell_was_quoted: Bool = False
    var cell_needs_unescape: Bool = False

    comptime if Q.ACCEPTS_BOM:
        if (
            n >= 3
            and bytes[0] == UInt8(0xEF)
            and bytes[1] == UInt8(0xBB)
            and bytes[2] == UInt8(0xBF)
        ):
            pos = 3
            cell_start = 3

    while pos < n:
        if state == CSV_STATE_STANDARD and pos + 32 <= n:
            var chunk = _load_u8x32(bytes, pos)
            var bm = byte_find_eq_4_u8x32(
                chunk,
                delimiter,
                quote,
                UInt8(0x0D),
                UInt8(0x0A),
            )
            var bits = movemask_to_uint_u8x32(bm)
            if bits == UInt32(0):
                pos = pos + 32
                continue
            var k = Int(count_trailing_zeros(bits))
            pos = pos + k

        var b = bytes[pos]
        if state == CSV_STATE_STANDARD:
            if b == delimiter:
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == quote and pos == cell_start:
                state = CSV_STATE_QUOTED
                cell_was_quoted = True
                cell_start = pos + 1
                pos = pos + 1
                continue
            if b == UInt8(0x0A):
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                cells.row_starts.append(len(cells.cell_starts))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == UInt8(0x0D):
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                cells.row_starts.append(len(cells.cell_starts))
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            pos = pos + 1
            continue

        if state == CSV_STATE_QUOTED:
            comptime if Q.DOUBLE_QUOTE_ESCAPES:
                if b == quote:
                    state = CSV_STATE_QUOTE_IN_QUOTED
                    pos = pos + 1
                    continue
                pos = pos + 1
                continue
            else:
                if posix_escape_byte != UInt8(0) and b == posix_escape_byte:
                    state = CSV_STATE_POSIX_ESCAPE
                    cell_needs_unescape = True
                    pos = pos + 1
                    continue
                if b == quote:
                    var end_excl = pos
                    cells.cell_starts.append(cell_start)
                    cells.cell_ends.append(end_excl)
                    cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                    state = CSV_STATE_STANDARD
                    cell_was_quoted = False
                    cell_needs_unescape = False
                    pos = pos + 1
                    if pos < n:
                        var nb = bytes[pos]
                        if nb == delimiter:
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0A):
                            cells.row_starts.append(len(cells.cell_starts))
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0D):
                            cells.row_starts.append(len(cells.cell_starts))
                            state = CSV_STATE_CR_LF_LOOKAHEAD
                            pos = pos + 1
                            cell_start = pos
                            continue
                        # A byte after the closing quote that is not the
                        # delimiter or a line end: record it (the reader
                        # refuses the record) and start the next field
                        # there, as the doubled-quote dialects do.
                        cells.note_quote_violation(pos, cells.cells_in_open_row() - 1)
                        cell_start = pos
                        pos = pos + 1
                        continue
                    else:
                        # The closing quote was the last byte: the record
                        # ends here. Close the row so the end-of-input
                        # flush does not append a phantom empty field.
                        cells.row_starts.append(len(cells.cell_starts))
                        cell_start = pos
                        continue
                pos = pos + 1
                continue

        if state == CSV_STATE_QUOTE_IN_QUOTED:
            if b == quote:
                state = CSV_STATE_QUOTED
                cell_needs_unescape = True
                pos = pos + 1
                continue
            var end_excl = pos - 1
            cells.cell_starts.append(cell_start)
            cells.cell_ends.append(end_excl)
            cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
            cell_was_quoted = False
            cell_needs_unescape = False
            state = CSV_STATE_STANDARD
            if b == delimiter:
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0A):
                cells.row_starts.append(len(cells.cell_starts))
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0D):
                cells.row_starts.append(len(cells.cell_starts))
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                continue
            # A byte after the closing quote that is not the delimiter or a
            # line end: malformed under every dialect. Record it (the reader
            # refuses the record) and keep the scan going.
            cells.note_quote_violation(pos, cells.cells_in_open_row() - 1)
            cell_start = pos
            pos = pos + 1
            continue

        if state == CSV_STATE_POSIX_ESCAPE:
            state = CSV_STATE_QUOTED
            pos = pos + 1
            continue

        if state == CSV_STATE_CR_LF_LOOKAHEAD:
            if b == UInt8(0x0A):
                pos = pos + 1
                cell_start = pos
                state = CSV_STATE_STANDARD
                continue
            state = CSV_STATE_STANDARD
            continue

        pos = pos + 1  # cov: unreachable every FSA state arm above ends in continue

    if state == CSV_STATE_QUOTED or state == CSV_STATE_POSIX_ESCAPE:
        raise Error(
            "scan_csv_phase2_movemask_into_cells: unterminated quoted region"
            " (EOF inside QUOTED state); file may be truncated or have"
            " mismatched quotes."
        )

    var pending_cells_at_row = len(cells.cell_starts) - cells.row_starts[len(cells.row_starts) - 1]
    if state == CSV_STATE_QUOTE_IN_QUOTED:
        var end_excl = n - 1
        cells.cell_starts.append(cell_start)
        cells.cell_ends.append(end_excl)
        cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
        cells.row_starts.append(len(cells.cell_starts))
    else:
        if pos > cell_start or pending_cells_at_row > 0:
            cells.cell_starts.append(cell_start)
            cells.cell_ends.append(pos)
            cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
            cells.row_starts.append(len(cells.cell_starts))

    return cells^


# =============================================================================
# Projection-aware Phase 2 movemask scanner.
# =============================================================================
#
# Problem: `scan_csv_phase2_movemask_into_cells` emits boundary metadata
# (cell_starts / cell_ends / cell_flags) for EVERY column of EVERY row. On
# TPC-H SF1 lineitem (6 M rows x 21 cols) that's ~126 M cells x 3 List.append
# each (~2 GB of metadata + ~378 M append events), even when the query
# `.select()`s only 2-3 columns. A row-native CSV reader can narrow the typed
# PARSE to the projected columns, but the tokenizer would still materialize
# the whole 21-column cell index — ~8x the work the query needs.
#
# The delimiter scan itself (SIMD movemask) is unavoidable: to know WHERE the
# projected columns sit in each row you must still walk every delimiter. But
# the per-cell metadata store + the downstream per-cell handling scale with
# the UNPROJECTED column count, and that is the part this scanner cuts. It
# tracks `col_idx` across delimiters (exactly as the full scanner does) and
# appends a (start, end, flags) triple ONLY when the current column is in the
# projected set. Output rows carry exactly `n_proj` cells, in FILE-COLUMN
# order (ascending file-col index of the wanted columns).
#
# Byte-identity contract: for every projected column the emitted
# (start, end, was_quoted, needs_unescape) is BIT-IDENTICAL to what the full
# scanner emits for the same column — the FSA is the same; only the emit is
# gated. The caller (the row reader) maps each segment-input column to its
# RANK among the wanted columns (the projected emit order), not the full-header
# index.
#
# `wanted` is a `List[Bool]` mask indexed by file-column index, sized to at
# least `max_wanted_file_col + 1`. A row that runs past the mask length (a
# column index >= len(wanted)) is treated as not-wanted (the FSA still tracks
# the boundary so row/column counting stays exact). `n_proj` is the count of
# True entries; it equals the number of cells emitted per complete row.
# =============================================================================


def scan_csv_phase2_movemask_projected[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    delimiter: UInt8,
    quote: UInt8,
    imm wanted: List[Bool],
    n_proj: Int,
) raises -> ScannedCells:
    """Projection-aware Phase 2 movemask scanner.

    Identical FSA + 32-byte movemask fast-skip to
    `scan_csv_phase2_movemask_into_cells`, but EMITS cell boundary metadata
    ONLY for columns whose file-column index `c` has `wanted[c] == True`. The
    delimiter scan still visits every column boundary (required to locate the
    projected columns within each row); the gate is purely on the
    `cells.cell_*.append` calls.

    Output: a `ScannedCells` where each complete row holds exactly `n_proj`
    cells, in ascending file-column order of the wanted set. For each emitted
    cell the (start, end, was_quoted, needs_unescape) is byte-identical to the
    full scanner's output for that same column.

    Args:
        bytes:      Origin-poly Span over the full file contents.
        delimiter:  Column separator byte (typically b',').
        quote:      Quote byte (typically b'"').
        wanted:     Mask indexed by file-column index; `wanted[c]` is True iff
                    column `c`'s boundary metadata should be emitted. Columns
                    with index >= len(wanted) are treated as not-wanted.
        n_proj:     Number of True entries in `wanted` (the per-row emit count).

    Returns:
        `ScannedCells` with `n_proj` cells per complete row.

    Raises:
        Error on unterminated quoted region (EOF inside QUOTED state).
    """
    # Pre-size to the PROJECTED footprint, not the full-column footprint: the
    # whole point is to avoid materializing ~21-col metadata. `est_rows` from
    # the avg-row heuristic, cells = est_rows * n_proj.
    var est = _estimate_capacities(len(bytes))
    var est_rows = est[1]
    var est_cells = est_rows * n_proj
    if est_cells < 64:
        est_cells = 64
    var cells = ScannedCells(est_cells, est_rows)
    var n = len(bytes)
    if n == 0:
        return cells^

    var n_wanted_mask = len(wanted)

    var posix_escape_byte: UInt8 = Q.ESCAPE_BYTE

    var state: UInt8 = CSV_STATE_STANDARD
    var pos: Int = 0
    var cell_start: Int = 0
    var cell_was_quoted: Bool = False
    var cell_needs_unescape: Bool = False
    # Current column index within the in-progress row.
    var col_idx: Int = 0

    comptime if Q.ACCEPTS_BOM:
        if (
            n >= 3
            and bytes[0] == UInt8(0xEF)
            and bytes[1] == UInt8(0xBB)
            and bytes[2] == UInt8(0xBF)
        ):
            pos = 3
            cell_start = 3

    while pos < n:
        if state == CSV_STATE_STANDARD and pos + 32 <= n:
            var chunk = _load_u8x32(bytes, pos)
            var bm = byte_find_eq_4_u8x32(
                chunk,
                delimiter,
                quote,
                UInt8(0x0D),
                UInt8(0x0A),
            )
            var bits = movemask_to_uint_u8x32(bm)
            if bits == UInt32(0):
                pos = pos + 32
                continue
            var k = Int(count_trailing_zeros(bits))
            pos = pos + k

        var b = bytes[pos]
        if state == CSV_STATE_STANDARD:
            if b == delimiter:
                if col_idx < n_wanted_mask and wanted[col_idx]:
                    cells.cell_starts.append(cell_start)
                    cells.cell_ends.append(pos)
                    cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                col_idx = col_idx + 1
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == quote and pos == cell_start:
                state = CSV_STATE_QUOTED
                cell_was_quoted = True
                cell_start = pos + 1
                pos = pos + 1
                continue
            if b == UInt8(0x0A):
                if col_idx < n_wanted_mask and wanted[col_idx]:
                    cells.cell_starts.append(cell_start)
                    cells.cell_ends.append(pos)
                    cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                cells.row_starts.append(len(cells.cell_starts))
                col_idx = 0
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == UInt8(0x0D):
                if col_idx < n_wanted_mask and wanted[col_idx]:
                    cells.cell_starts.append(cell_start)
                    cells.cell_ends.append(pos)
                    cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                cells.row_starts.append(len(cells.cell_starts))
                col_idx = 0
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            pos = pos + 1
            continue

        if state == CSV_STATE_QUOTED:
            comptime if Q.DOUBLE_QUOTE_ESCAPES:
                if b == quote:
                    state = CSV_STATE_QUOTE_IN_QUOTED
                    pos = pos + 1
                    continue
                pos = pos + 1
                continue
            else:
                if posix_escape_byte != UInt8(0) and b == posix_escape_byte:
                    state = CSV_STATE_POSIX_ESCAPE
                    cell_needs_unescape = True
                    pos = pos + 1
                    continue
                if b == quote:
                    var end_excl = pos
                    if col_idx < n_wanted_mask and wanted[col_idx]:
                        cells.cell_starts.append(cell_start)
                        cells.cell_ends.append(end_excl)
                        cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                    state = CSV_STATE_STANDARD
                    cell_was_quoted = False
                    cell_needs_unescape = False
                    pos = pos + 1
                    if pos < n:
                        var nb = bytes[pos]
                        if nb == delimiter:
                            col_idx = col_idx + 1
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0A):
                            cells.row_starts.append(len(cells.cell_starts))
                            col_idx = 0
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0D):
                            cells.row_starts.append(len(cells.cell_starts))
                            col_idx = 0
                            state = CSV_STATE_CR_LF_LOOKAHEAD
                            pos = pos + 1
                            cell_start = pos
                            continue
                        # A byte after the closing quote that is not the
                        # delimiter or a line end: record it (the reader
                        # refuses the record) and start the next field
                        # there, as the doubled-quote dialects do.
                        cells.note_quote_violation(pos, col_idx)
                        cell_start = pos
                        pos = pos + 1
                        continue
                    else:
                        # The closing quote was the last byte: the record
                        # ends here. Close the row so the end-of-input
                        # flush does not append a phantom empty field.
                        cells.row_starts.append(len(cells.cell_starts))
                        col_idx = 0
                        cell_start = pos
                        continue
                pos = pos + 1
                continue

        if state == CSV_STATE_QUOTE_IN_QUOTED:
            if b == quote:
                state = CSV_STATE_QUOTED
                cell_needs_unescape = True
                pos = pos + 1
                continue
            var end_excl = pos - 1
            if col_idx < n_wanted_mask and wanted[col_idx]:
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(end_excl)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
            cell_was_quoted = False
            cell_needs_unescape = False
            state = CSV_STATE_STANDARD
            if b == delimiter:
                col_idx = col_idx + 1
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0A):
                cells.row_starts.append(len(cells.cell_starts))
                col_idx = 0
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0D):
                cells.row_starts.append(len(cells.cell_starts))
                col_idx = 0
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                continue
            # A byte after the closing quote that is not the delimiter or a
            # line end: malformed under every dialect. Record it (the reader
            # refuses the record) and keep the scan going.
            cells.note_quote_violation(pos, col_idx)
            cell_start = pos
            pos = pos + 1
            continue

        if state == CSV_STATE_POSIX_ESCAPE:
            state = CSV_STATE_QUOTED
            pos = pos + 1
            continue

        if state == CSV_STATE_CR_LF_LOOKAHEAD:
            if b == UInt8(0x0A):
                pos = pos + 1
                cell_start = pos
                state = CSV_STATE_STANDARD
                continue
            state = CSV_STATE_STANDARD
            continue

        pos = pos + 1  # cov: unreachable every FSA state arm above ends in continue

    if state == CSV_STATE_QUOTED or state == CSV_STATE_POSIX_ESCAPE:
        raise Error(
            "scan_csv_phase2_movemask_projected: unterminated quoted region"
            " (EOF inside QUOTED state); file may be truncated or have"
            " mismatched quotes."
        )

    var pending_cells_at_row = len(cells.cell_starts) - cells.row_starts[len(cells.row_starts) - 1]
    if state == CSV_STATE_QUOTE_IN_QUOTED:
        var end_excl = n - 1
        if col_idx < n_wanted_mask and wanted[col_idx]:
            cells.cell_starts.append(cell_start)
            cells.cell_ends.append(end_excl)
            cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
        cells.row_starts.append(len(cells.cell_starts))
    else:
        # A final row is in-progress iff we've consumed body bytes past
        # cell_start OR already emitted/advanced columns on this row. The
        # full scanner's `pending_cells_at_row > 0` check used emitted cell
        # count; under projection a row whose only columns are unprojected
        # would have zero emitted cells but is still a real row. Use
        # `col_idx > 0` (we've passed at least one delimiter) OR consumed
        # body bytes as the real-row signal, matching the full scanner's
        # row-count semantics.
        if pos > cell_start or col_idx > 0 or pending_cells_at_row > 0:
            if col_idx < n_wanted_mask and wanted[col_idx]:
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
            cells.row_starts.append(len(cells.cell_starts))

    return cells^


def scan_csv_phase3_pclmulqdq_into_cells[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    delimiter: UInt8,
    quote: UInt8,
) raises -> ScannedCells:
    """Phase 3 PCLMULQDQ chassis -- flat-buffer emit variant.

    Identical FSA + 64-byte PCLMULQDQ quote-region mask to
    `scan_csv_phase3_pclmulqdq`, but emits cells into a `ScannedCells`
    struct.
    """
    var est = _estimate_capacities(len(bytes))
    var cells = ScannedCells(est[0], est[1])
    var n = len(bytes)
    if n == 0:
        return cells^

    var posix_escape_byte: UInt8 = Q.ESCAPE_BYTE

    var state: UInt8 = CSV_STATE_STANDARD
    var pos: Int = 0
    var cell_start: Int = 0
    var cell_was_quoted: Bool = False
    var cell_needs_unescape: Bool = False

    comptime if Q.ACCEPTS_BOM:
        if (
            n >= 3
            and bytes[0] == UInt8(0xEF)
            and bytes[1] == UInt8(0xBB)
            and bytes[2] == UInt8(0xBF)
        ):
            pos = 3
            cell_start = 3

    var quote_region_carry: Bool = False
    var doubled_quote_tail_carry: Bool = False

    var chunk_base: Int = -1
    var chunk_valid: Bool = False
    var pending_bits: UInt64 = UInt64(0)

    while pos < n:
        if not chunk_valid or pos >= chunk_base + 64:
            if pos + 64 <= n:
                var chunk = _load_u8x64(bytes, pos)
                var quote_bm = byte_eq_to_bytemask_u8x64(chunk, quote)
                var quote_bits = movemask_to_uint_u8x64(quote_bm)

                var quote_bits_canon: UInt64
                comptime if Q.DOUBLE_QUOTE_ESCAPES:
                    # One-byte lookahead so a `""` pair straddling this
                    # chunk's tail is classified exactly rather than guessed.
                    var next_is_quote = (
                        pos + 64 < n and bytes[pos + 64] == quote
                    )
                    quote_bits_canon = _cancel_doubled_quotes_u64(
                        quote_bits, doubled_quote_tail_carry, next_is_quote
                    )
                else:
                    quote_bits_canon = quote_bits

                var quote_region = quote_region_mask_u64(
                    quote_bits_canon, quote_region_carry
                )
                quote_region_carry = (
                    quote_region & UInt64(0x8000000000000000)
                ) != 0

                var specials_bm = byte_find_eq_4_u8x64(
                    chunk,
                    delimiter,
                    UInt8(0x0A),
                    UInt8(0x0D),
                    delimiter,
                )
                var specials_bits = movemask_to_uint_u8x64(specials_bm)

                var escape_bits: UInt64
                comptime if Q.DOUBLE_QUOTE_ESCAPES:
                    escape_bits = UInt64(0)
                else:
                    if posix_escape_byte != UInt8(0):
                        var esc_bm = byte_eq_to_bytemask_u8x64(
                            chunk, posix_escape_byte
                        )
                        escape_bits = movemask_to_uint_u8x64(esc_bm)
                    else:
                        escape_bits = UInt64(0)

                var candidates = (specials_bits & ~quote_region) | quote_bits
                comptime if not Q.DOUBLE_QUOTE_ESCAPES:
                    candidates = candidates | (escape_bits & quote_region)

                chunk_base = pos
                chunk_valid = True
                pending_bits = candidates
            else:
                chunk_valid = False
                pending_bits = UInt64(0)

        # ⚠ STATE GUARD -- see the identical guard in
        # `scan_csv_phase3_pclmulqdq` for the full rationale. The ctz jump is
        # legal ONLY in the STABLE states; in QUOTE_IN_QUOTED / POSIX_ESCAPE /
        # CR_LF_LOOKAHEAD the byte at `pos` is load-bearing and skipping it
        # silently corrupts cell CONTENT (in-bounds, so no bounds check
        # applies -- ASSERT level is irrelevant to this defect).
        if (
            chunk_valid
            and pending_bits != UInt64(0)
            and (state == CSV_STATE_STANDARD or state == CSV_STATE_QUOTED)
        ):
            var k = Int(count_trailing_zeros(pending_bits))
            var target = chunk_base + k
            if target > pos:
                pos = target
            pending_bits = pending_bits & (pending_bits - UInt64(1))
            if pos >= n:
                break  # cov: unreachable a candidate bit names a byte of a full 64-byte chunk, so pos < n
        elif chunk_valid and pending_bits == UInt64(0) and pos < chunk_base + 64:
            if (
                state == CSV_STATE_STANDARD
                or state == CSV_STATE_QUOTED
            ):
                pos = chunk_base + 64
                continue

        var b = bytes[pos]
        if state == CSV_STATE_STANDARD:
            if b == delimiter:
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == quote and pos == cell_start:
                state = CSV_STATE_QUOTED
                cell_was_quoted = True
                cell_start = pos + 1
                pos = pos + 1
                continue
            if b == UInt8(0x0A):
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                cells.row_starts.append(len(cells.cell_starts))
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            if b == UInt8(0x0D):
                cells.cell_starts.append(cell_start)
                cells.cell_ends.append(pos)
                cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                cells.row_starts.append(len(cells.cell_starts))
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                cell_was_quoted = False
                cell_needs_unescape = False
                continue
            pos = pos + 1
            continue

        if state == CSV_STATE_QUOTED:
            comptime if Q.DOUBLE_QUOTE_ESCAPES:
                if b == quote:
                    state = CSV_STATE_QUOTE_IN_QUOTED
                    pos = pos + 1
                    continue
                pos = pos + 1
                continue
            else:
                if posix_escape_byte != UInt8(0) and b == posix_escape_byte:
                    state = CSV_STATE_POSIX_ESCAPE
                    cell_needs_unescape = True
                    pos = pos + 1
                    continue
                if b == quote:
                    var end_excl = pos
                    cells.cell_starts.append(cell_start)
                    cells.cell_ends.append(end_excl)
                    cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
                    state = CSV_STATE_STANDARD
                    cell_was_quoted = False
                    cell_needs_unescape = False
                    pos = pos + 1
                    if pos < n:
                        var nb = bytes[pos]
                        if nb == delimiter:
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0A):
                            cells.row_starts.append(len(cells.cell_starts))
                            pos = pos + 1
                            cell_start = pos
                            continue
                        if nb == UInt8(0x0D):
                            cells.row_starts.append(len(cells.cell_starts))
                            state = CSV_STATE_CR_LF_LOOKAHEAD
                            pos = pos + 1
                            cell_start = pos
                            continue
                        # A byte after the closing quote that is not the
                        # delimiter or a line end: record it (the reader
                        # refuses the record) and start the next field
                        # there, as the doubled-quote dialects do.
                        cells.note_quote_violation(pos, cells.cells_in_open_row() - 1)
                        cell_start = pos
                        pos = pos + 1
                        continue
                    else:
                        # The closing quote was the last byte: the record
                        # ends here. Close the row so the end-of-input
                        # flush does not append a phantom empty field.
                        cells.row_starts.append(len(cells.cell_starts))
                        cell_start = pos
                        continue
                pos = pos + 1
                continue

        if state == CSV_STATE_QUOTE_IN_QUOTED:
            if b == quote:
                state = CSV_STATE_QUOTED
                cell_needs_unescape = True
                pos = pos + 1
                continue
            var end_excl = pos - 1
            cells.cell_starts.append(cell_start)
            cells.cell_ends.append(end_excl)
            cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
            cell_was_quoted = False
            cell_needs_unescape = False
            state = CSV_STATE_STANDARD
            if b == delimiter:
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0A):
                cells.row_starts.append(len(cells.cell_starts))
                pos = pos + 1
                cell_start = pos
                continue
            if b == UInt8(0x0D):
                cells.row_starts.append(len(cells.cell_starts))
                state = CSV_STATE_CR_LF_LOOKAHEAD
                pos = pos + 1
                cell_start = pos
                continue
            # A byte after the closing quote that is not the delimiter or a
            # line end: malformed under every dialect. Record it (the reader
            # refuses the record) and keep the scan going.
            cells.note_quote_violation(pos, cells.cells_in_open_row() - 1)
            cell_start = pos
            pos = pos + 1
            continue

        if state == CSV_STATE_POSIX_ESCAPE:
            state = CSV_STATE_QUOTED
            pos = pos + 1
            continue

        if state == CSV_STATE_CR_LF_LOOKAHEAD:
            if b == UInt8(0x0A):
                pos = pos + 1
                cell_start = pos
                state = CSV_STATE_STANDARD
                continue
            state = CSV_STATE_STANDARD
            continue

        pos = pos + 1  # cov: unreachable every FSA state arm above ends in continue

    if state == CSV_STATE_QUOTED or state == CSV_STATE_POSIX_ESCAPE:
        raise Error(
            "scan_csv_phase3_pclmulqdq_into_cells: unterminated quoted region"
            " (EOF inside QUOTED state); file may be truncated or have"
            " mismatched quotes."
        )

    var pending_cells_at_row = len(cells.cell_starts) - cells.row_starts[len(cells.row_starts) - 1]
    if state == CSV_STATE_QUOTE_IN_QUOTED:
        var end_excl = n - 1
        cells.cell_starts.append(cell_start)
        cells.cell_ends.append(end_excl)
        cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
        cells.row_starts.append(len(cells.cell_starts))
    else:
        if pos > cell_start or pending_cells_at_row > 0:
            cells.cell_starts.append(cell_start)
            cells.cell_ends.append(pos)
            cells.cell_flags.append(pack_cell_flags(cell_was_quoted, cell_needs_unescape))
            cells.row_starts.append(len(cells.cell_starts))

    return cells^
