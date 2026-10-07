# =============================================================================
# csv_chunk_split.mojo — QUOTE-SAFE partition of a CSV body into row ranges.
# =============================================================================
#
# THE ONE PLACE a CSV body is split for parallel decode. A newline-snapped
# splitter that assumes a raw `\n` is always a row terminator is wrong in
# two ways:
#
#   * it cuts inside a quoted field that contains a newline, so a worker
#     raises unterminated-quote (or returns shredded rows);
#   * a reader that knows that cannot use it once a projected column is
#     var-width, so it must clamp to one worker -- and `all_varchar` makes
#     every column var-width, so a large CSV decodes on one core.
#
# The unlock is that for an RFC-4180-family dialect a byte's quoting state is
# a PARITY, so a split point can be classified in one linear pass instead of
# by tokenizing everything before it:
#
#     byte k is inside a quoted field  <=>  the number of `"` before it is odd
#
# and a doubled-quote escape (`""`, the RFC-4180 escape) contributes TWO
# quotes, so it PRESERVES that parity. `quote_region_mask_u64` computes the
# per-64-byte-chunk form of exactly this with one carry-less multiply
# (PCLMULQDQ / PMULL64) — the same primitive `scan_csv_phase3_pclmulqdq`
# already uses to filter its candidate bytes.
#
# ⚠ POSIX IS EXCLUDED, EXPLICITLY AND AT COMPTIME. The Posix dialect escapes
# an embedded quote as `\"` — ONE quote byte — so a Posix escape FLIPS the
# parity and the model above is simply false. `Q.DOUBLE_QUOTE_ESCAPES` is the
# exact predicate, and the Posix arm emits ONE range (i.e. serial) rather than
# splitting a file it cannot classify. Silently mis-splitting it would corrupt
# rows with no error, which is the worst available outcome.
#
# =============================================================================
# WHY PARITY ALONE IS NOT ENOUGH — the check that makes this safe
# =============================================================================
#
# The scanners this splitter feeds are FSA-exact, and the FSA opens a quoted
# region ONLY when the quote is the FIRST byte of a cell
# (`csv_scanner_phase1.mojo`: `if b == quote and pos == cell_start`). A quote
# in the MIDDLE of an unquoted field — `12" pipe,3` — is ordinary content to
# the FSA and does NOT open a region. Parity disagrees: it flips, and from
# there every subsequent classification is INVERTED, so this splitter would
# happily choose a boundary that sits INSIDE a genuinely quoted field and
# hand a worker a stream that starts mid-row.
#
# That divergence is cheap to DETECT, so it is detected rather than assumed
# away. In the same pass, every quote that parity calls an OPENER is checked
# against the FSA's own rule: its predecessor must be a delimiter, CR, LF, or
# the start of the body. One shift and one AND per 64-byte chunk. On the first
# violation the split STOPS — the ranges already emitted are still exact
# (parity was still FSA-exact over the bytes that produced them) and the
# remainder becomes one trailing range, so a file with a stray quote degrades
# to LESS parallelism and never to wrong rows.
#
# ⚠ Do NOT "simplify" this by dropping the opener check. The parity-only model
# is the one `scan_csv_phase3_pclmulqdq` uses, and it is why THAT scanner
# mis-tokenizes the same files; copying it here would have converted a
# tokenizer bug into a row-shredding one, on the path that reads every CSV.
#
# CLOSERS are deliberately NOT checked. The FSA accepts a closing quote
# followed by content (`"abc"def,` — QUOTE_IN_QUOTED then STANDARD), and
# parity agrees with it there (two quotes, net even), so a closer check would
# reject files that are already handled correctly.
#
# =============================================================================
# COST
# =============================================================================
#
# One linear pass over the body, ending at the last boundary rather than at
# EOF. The dominant case — a chunk with NO quote byte while outside a region —
# short-circuits to the same work `find_first_newline_simd` does (load, one
# byte-compare, one movemask), so a quote-free 850 MB CSV pays roughly a
# `memchr` over the file. Chunks that DO carry quotes pay the cancellation +
# clmul + opener check. Against the ~27 s that same file spends being parsed,
# either is noise; against a one-worker clamp, it is not close.
#
# Encapsulation: the public entry takes a `Span` + `List[Int]` out-params and
# returns nothing. No `UnsafePointer` in any signature here; the only raw
# pointer is inside `_load_u8x64`, which is package-internal to
# `csv_scanner_phase1` and never crosses out of it.
# =============================================================================

from std.bit import count_trailing_zeros

from komira_simd.byte_class.movemask import (
    movemask_to_uint_u8x64,
    byte_eq_to_bytemask_u8x64,
)
from komira_simd.byte_class.byte_find_any_of import byte_find_eq_4_u8x64
from komira_simd.byte_class.quote_region_mask import quote_region_mask_u64

from .quote_styles import QuoteStyle
from .csv_scanner_phase1 import _load_u8x64, _cancel_doubled_quotes_u64


# =============================================================================
# csv_split_is_quote_parity_safe — the dialect predicate, exposed.
# =============================================================================


@always_inline
def csv_split_is_quote_parity_safe[Q: QuoteStyle]() -> Bool:
    """True iff dialect `Q` escapes an embedded quote by DOUBLING it.

    The whole quote-parity split rests on this: `""` contributes two quote
    bytes and therefore preserves parity, whereas Posix's `\\"` contributes
    one and inverts it. Callers that want to report WHY a file went serial
    can read this instead of re-deriving the rule.
    """
    return Q.DOUBLE_QUOTE_ESCAPES


# =============================================================================
# compute_csv_quote_safe_row_ranges — the public entry.
# =============================================================================


def compute_csv_quote_safe_row_ranges[
    Q: QuoteStyle
](
    bytes: Span[UInt8, _],
    data_start_byte: Int,
    k_desired: Int,
    delimiter: UInt8,
    quote: UInt8,
    mut los: List[Int],
    mut his: List[Int],
):
    """Split `bytes[data_start_byte:]` into at most `k_desired` half-open
    ranges, each of which starts at a REAL row boundary.

    "Real" means: outside any quoted field, per the same rule the FSA
    scanners apply. A range therefore decodes standalone, and concatenating
    the per-range results in ascending order reproduces the serial row
    sequence exactly.

    On return `len(los) == len(his)`, both `<= k_desired`, and the ranges
    tile `[data_start_byte, len(bytes))` with no gap and no overlap. The
    result may be SHORTER than `k_desired` — boundaries that resolve to the
    same position merge, a dialect that cannot be classified yields one
    range, and a file that violates the parity precondition keeps the
    boundaries proven so far and folds the rest into a trailing range.

    Fewer ranges is always safe (it is less parallelism, not wrong rows);
    the caller decides what to do with `k == 1`.

    Args:
        bytes: The whole file buffer (the header is skipped via
            `data_start_byte`, never removed — cell offsets stay absolute).
        data_start_byte: Offset of the first DATA byte (post-header).
        k_desired: How many ranges the caller would like.
        delimiter: The column separator byte, needed by the opener check.
        quote: The quote byte (typically `"`).
        los: Out-param, cleared then filled with range starts.
        his: Out-param, cleared then filled with range ends (exclusive).
    """
    los.clear()
    his.clear()
    var n = len(bytes)
    if n <= 0 or data_start_byte >= n:
        return
    if k_desired <= 1:
        los.append(data_start_byte)
        his.append(n)
        return

    comptime if not Q.DOUBLE_QUOTE_ESCAPES:
        # POSIX. `\"` is a one-byte escape, so quote parity is not a valid
        # model of quoting state. Emit ONE range: this dialect decodes
        # serially until someone builds it an escape-aware splitter. Stated
        # here rather than silently mis-split — see the header.
        los.append(data_start_byte)
        his.append(n)
        return

    var data_len = n - data_start_byte
    var bounds = List[Int]()
    bounds.append(data_start_byte)

    # ---- walk state -----------------------------------------------------
    # `carry`      : in-quoted-region parity at `pos` (False == outside).
    # `dq_tail`    : a `""` pair straddles into `pos` (see
    #                `_cancel_doubled_quotes_u64`).
    # `prev_spec`  : byte `pos-1` is delim/CR/LF, or `pos` is the body start.
    #                This is exactly the FSA's `pos == cell_start` in STANDARD
    #                state, which is what makes a quote an opener.
    # `cand_i`/`cand`: the next boundary we are looking for.
    var pos = data_start_byte
    var carry = False
    var dq_tail = False
    var prev_spec = True
    var cand_i = 1
    var cand = data_start_byte + (data_len * cand_i) // k_desired
    var safe = True

    # ---- 64-byte SIMD loop ---------------------------------------------
    while pos + 64 <= n and cand_i < k_desired and safe:
        var chunk = _load_u8x64(bytes, pos)
        var qbits = movemask_to_uint_u8x64(
            byte_eq_to_bytemask_u8x64(chunk, quote)
        )

        if qbits == UInt64(0):
            # FAST PATH — no quote byte in these 64 bytes. Nothing can open
            # or close a region, so parity is unchanged and `dq_tail` cannot
            # survive (a straddling pair needs a quote at byte 0).
            dq_tail = False
            if not carry and cand < pos + 64:
                var lf_fast = movemask_to_uint_u8x64(
                    byte_eq_to_bytemask_u8x64(chunk, UInt8(0x0A))
                )
                _take_boundaries_in_chunk(
                    lf_fast, pos, n, data_start_byte, data_len, k_desired,
                    bounds, cand_i, cand,
                )
            prev_spec = _is_row_structural(bytes[pos + 63], delimiter)
            pos = pos + 64
            continue

        # ---- full path: this chunk carries quotes -----------------------
        # Cancel `""` pairs FIRST. Without it every RFC-4180 escape reads as
        # a close-then-open and the opener check below would reject every
        # correctly-escaped file.
        var next_is_quote = (pos + 64 < n) and (bytes[pos + 64] == quote)
        var qcanon = _cancel_doubled_quotes_u64(qbits, dq_tail, next_is_quote)

        var in_str = quote_region_mask_u64(qcanon, carry)

        # A quote byte that is itself "inside" toggled outside->inside, i.e.
        # it OPENED the region. (A closer's own bit reads "outside".)
        var openers = qcanon & in_str
        if openers != UInt64(0):
            var sp_bits = movemask_to_uint_u8x64(
                byte_find_eq_4_u8x64(
                    chunk, delimiter, UInt8(0x0A), UInt8(0x0D), delimiter
                )
            )
            # bit k set iff byte k-1 is delim/CR/LF (bit 0 from the carry).
            var pred_spec = sp_bits << UInt64(1)
            if prev_spec:
                pred_spec = pred_spec | UInt64(1)
            if (openers & ~pred_spec) != UInt64(0):
                # A quote opened a region from a non-cell-start position.
                # Parity has diverged from the FSA here and stays diverged.
                # Keep every boundary proven BEFORE this chunk; stop.
                safe = False
                break
            prev_spec = (sp_bits & UInt64(0x8000000000000000)) != UInt64(0)
        else:
            prev_spec = _is_row_structural(bytes[pos + 63], delimiter)

        if cand < pos + 64:
            var lf_bits = movemask_to_uint_u8x64(
                byte_eq_to_bytemask_u8x64(chunk, UInt8(0x0A))
            )
            _take_boundaries_in_chunk(
                lf_bits & ~in_str, pos, n, data_start_byte, data_len,
                k_desired, bounds, cand_i, cand,
            )

        carry = (in_str & UInt64(0x8000000000000000)) != UInt64(0)
        pos = pos + 64

    # ---- scalar tail ----------------------------------------------------
    # Reached for the last <64 bytes, and for whole small fixtures (the
    # forced-workers tests run entirely here, which is why this path is the
    # readable reference semantics rather than a special case).
    if safe and cand_i < k_desired:
        # A straddling `""` whose high half is byte `pos`: the SIMD loop
        # cancelled the low half, so step over the high half here.
        if dq_tail and pos < n and bytes[pos] == quote:
            pos = pos + 1
        var in_q = carry
        var at_cell_start = prev_spec
        while pos < n and cand_i < k_desired:
            var b = bytes[pos]
            if in_q:
                if b == quote:
                    if pos + 1 < n and bytes[pos + 1] == quote:
                        pos = pos + 2  # `""` escape: content, not a close.
                        continue
                    in_q = False
                    at_cell_start = False
                pos = pos + 1
                continue
            if b == quote:
                if not at_cell_start:
                    # Same divergence the SIMD opener check catches.
                    break
                in_q = True
                at_cell_start = False
                pos = pos + 1
                continue
            if b == UInt8(0x0A):
                if pos >= cand:
                    var bnd = pos + 1
                    if bnd > bounds[len(bounds) - 1] and bnd < n:
                        bounds.append(bnd)
                        cand_i = _advance_candidate(
                            bnd, data_start_byte, data_len, k_desired,
                            cand_i, cand,
                        )
                at_cell_start = True
                pos = pos + 1
                continue
            at_cell_start = (b == delimiter) or (b == UInt8(0x0D))
            pos = pos + 1

    # ---- materialize ranges ---------------------------------------------
    bounds.append(n)
    var b_i = 0
    while b_i + 1 < len(bounds):
        var lo = bounds[b_i]
        var hi = bounds[b_i + 1]
        if hi > lo:
            los.append(lo)
            his.append(hi)
        b_i = b_i + 1


# =============================================================================
# Internal helpers.
# =============================================================================


@always_inline
def _is_row_structural(b: UInt8, delimiter: UInt8) -> Bool:
    """True iff `b` ends a cell or a row — the FSA's cell-start predecessors.
    """
    return (
        b == delimiter or b == UInt8(0x0A) or b == UInt8(0x0D)
    )


@always_inline
def _advance_candidate(
    past: Int,
    data_start_byte: Int,
    data_len: Int,
    k_desired: Int,
    cand_i: Int,
    mut cand: Int,
) -> Int:
    """Move the candidate cursor to the first index whose position is beyond
    `past`, so one long row cannot make two ranges start at the same place.

    Returns the new candidate index; writes the new position through `cand`.
    """
    var i = cand_i + 1
    while i < k_desired:
        cand = data_start_byte + (data_len * i) // k_desired
        if cand > past:
            return i
        i = i + 1
    return k_desired


@always_inline
def _take_boundaries_in_chunk(
    outside_lf_bits: UInt64,
    pos: Int,
    n: Int,
    data_start_byte: Int,
    data_len: Int,
    k_desired: Int,
    mut bounds: List[Int],
    mut cand_i: Int,
    mut cand: Int,
):
    """Consume every boundary this 64-byte chunk can settle.

    `outside_lf_bits` has bit k set iff byte `pos+k` is an LF that is NOT
    inside a quoted field. A candidate is settled by the first such LF at or
    after it; the boundary is the byte AFTER that LF (so a CRLF terminator is
    kept whole and the range starts on the next row's first byte).

    Loops because a small fixture with a large `k_desired` can settle several
    candidates inside one chunk. Stops when the chunk holds no further LF for
    the current candidate — the candidate then carries to a later chunk,
    where `cand < pos` makes the low-bit mask a no-op.
    """
    while cand_i < k_desired and cand < pos + 64:
        var lo_off = cand - pos
        if lo_off < 0:
            lo_off = 0
        var usable = outside_lf_bits
        if lo_off > 0:
            usable = usable & ~((UInt64(1) << UInt64(lo_off)) - UInt64(1))
        if usable == UInt64(0):
            return
        var bit = Int(count_trailing_zeros(usable))
        var bnd = pos + bit + 1
        if bnd >= n:
            # The last row ends at EOF; a range starting there would be empty.
            cand_i = k_desired
            return
        if bnd > bounds[len(bounds) - 1]:
            bounds.append(bnd)
        cand_i = _advance_candidate(
            bnd, data_start_byte, data_len, k_desired, cand_i, cand
        )
