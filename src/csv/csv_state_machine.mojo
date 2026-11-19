# =============================================================================
# csv_state_machine — FSA states + transitions for the chassis (Phase 1).
# =============================================================================
#
#
# Hand-written FSA (NOT the 256xN transition-table approach — the table
# is a Phase 2/3 perf optimization on top of this chassis). The state set
# below is the minimum needed for RFC-4180 + Excel + Posix correctness:
#
#   STANDARD              — normal field byte; transitions on delim/quote/CR/LF.
#   QUOTED                — inside a quoted region; transitions on quote-close
#                           + (Posix-only) escape.
#   QUOTE_IN_QUOTED       — just saw a `"` while QUOTED. If the next byte is
#                           also `"`, the pair is a doubled-quote escape and
#                           we stay QUOTED; otherwise the field has closed
#                           (transition on the just-seen byte).
#   POSIX_ESCAPE          — saw `\` inside QUOTED (Posix only); next byte is
#                           a literal field byte.
#   CR_LF_LOOKAHEAD       — saw `\r` in STANDARD; if next is `\n` we treat
#                           CRLF as one row terminator; if not, CR was the
#                           terminator (Excel-only) or a parse error (strict).
#
# The state byte is exposed as a comptime alias-constant set; the scanner
# walks bytes one-at-a-time within this module (Phase 1 chassis).
# =============================================================================

# State byte values. Kept as plain `comptime` Int constants (not enum-wrapped)
# so the scanner can index InlineArray transition tables directly in Phase 2.
comptime CSV_STATE_STANDARD: UInt8 = 0
comptime CSV_STATE_QUOTED: UInt8 = 1
comptime CSV_STATE_QUOTE_IN_QUOTED: UInt8 = 2
comptime CSV_STATE_POSIX_ESCAPE: UInt8 = 3
comptime CSV_STATE_CR_LF_LOOKAHEAD: UInt8 = 4

comptime CSV_N_STATES: Int = 5


# =============================================================================
# Byte classes (used by the per-byte FSA + by the Phase 2/3 SIMD scanners
# that swap the inner loop). Each class is a UInt8 token.
# =============================================================================

# `CSV_CLASS_OTHER` is the default — covers every byte that is NOT one of
# the structural bytes below. The scanner treats it as a field body byte.
comptime CSV_CLASS_OTHER: UInt8 = 0
comptime CSV_CLASS_DELIM: UInt8 = 1
comptime CSV_CLASS_QUOTE: UInt8 = 2
comptime CSV_CLASS_CR: UInt8 = 3
comptime CSV_CLASS_LF: UInt8 = 4
comptime CSV_CLASS_POSIX_ESCAPE: UInt8 = 5


@always_inline
def classify_byte(
    b: UInt8, delimiter: UInt8, quote: UInt8, posix_escape: UInt8
) -> UInt8:
    """Map a byte to one of the 5 CSV classes.

    Args:
        b: The input byte.
        delimiter: Column-delimiter byte (typically b',').
        quote: Quote byte (typically b'"').
        posix_escape: Backslash byte if Q is Posix; 0 if no escape.

    Returns:
        One of CSV_CLASS_* tokens.

    Notes:
        Branchy by design (5-way cascade). Phase 2 swaps this with a SIMD
        movemask + bit-position extraction for ~5-10x throughput.
    """
    if b == delimiter:
        return CSV_CLASS_DELIM
    if b == quote:
        return CSV_CLASS_QUOTE
    if b == UInt8(0x0D):  # '\r'
        return CSV_CLASS_CR
    if b == UInt8(0x0A):  # '\n'
        return CSV_CLASS_LF
    if posix_escape != UInt8(0) and b == posix_escape:
        return CSV_CLASS_POSIX_ESCAPE
    return CSV_CLASS_OTHER


# =============================================================================
# ContainsZeroByte trick (Hacker's Delight) — the Phase 1 chassis fast skip.
# =============================================================================
#
# `(v - 0x0101010101010101) & ~v & 0x8080808080808080` is non-zero iff any
# byte of `v` is zero. Combined with XOR-broadcast of a target byte, we can
# detect "any of `target` present in 8 bytes" in 3-5 cycles (1 multiply for
# broadcast + 1 XOR + 1 sub + 1 AND + 1 AND + 1 compare).
# =============================================================================


@always_inline
def broadcast_byte(b: UInt8) -> UInt64:
    """Replicate `b` across all 8 bytes of a UInt64.

    Single 64-bit multiply -- 3-4 cycles on M3/M4/x86.
    """
    return UInt64(b) * UInt64(0x0101010101010101)


@always_inline
def contains_zero_byte(v: UInt64) -> Bool:
    """True iff any byte of `v` is zero.

    Per Hacker's Delight section 6-1. Branch-free 4-op cookbook.
    """
    var s = v - UInt64(0x0101010101010101)
    var n = ~v
    var mask = s & n & UInt64(0x8080808080808080)
    return mask != UInt64(0)


@always_inline
def contains_any_of_4(
    word: UInt64, a: UInt64, b: UInt64, c: UInt64, d: UInt64
) -> Bool:
    """True iff `word` contains any of the 4 broadcast bytes a/b/c/d
    in at least one lane.

    Computes XOR with each broadcast (zero-byte iff the lane matches that
    byte) and ANDs the inverses together — final zero-byte means at least
    one of the 4 XORs produced a zero-byte at that lane position.
    """
    # If lane == a: (word ^ a) has a zero byte at that lane. We want
    # "ANY zero byte across the 4 XORs" = ContainsZeroByte over the
    # AND of all 4 (lane is zero in result iff zero in all 4 XORs is
    # WRONG — we want at least 1). The Hacker's-Delight formulation
    # for `any-of-N` is:
    #
    #   x1 = word ^ a; x2 = word ^ b; x3 = word ^ c; x4 = word ^ d
    #   result_word = x1 & x2 & x3 & x4 has a zero byte at lane k
    #                 iff lane k of word equals AT LEAST ONE of {a,b,c,d}
    #
    # because each xi has a zero byte at lane k iff word[k] == i. AND-ing
    # them means lane k is zero iff ALL match — which is impossible across
    # distinct bytes. So we want OR / different formulation.
    #
    # Correct N-way contains: OR of per-byte zero detections. Each XOR
    # tells us "lane k matches THIS byte"; we want union (OR) across
    # all 4.
    var x1 = word ^ a
    var x2 = word ^ b
    var x3 = word ^ c
    var x4 = word ^ d
    var has1 = (x1 - UInt64(0x0101010101010101)) & ~x1 & UInt64(0x8080808080808080)
    var has2 = (x2 - UInt64(0x0101010101010101)) & ~x2 & UInt64(0x8080808080808080)
    var has3 = (x3 - UInt64(0x0101010101010101)) & ~x3 & UInt64(0x8080808080808080)
    var has4 = (x4 - UInt64(0x0101010101010101)) & ~x4 & UInt64(0x8080808080808080)
    var any_match = has1 | has2 | has3 | has4
    return any_match != UInt64(0)
