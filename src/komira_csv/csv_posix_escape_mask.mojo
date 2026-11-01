# =============================================================================
# Posix escaped-quote cancellation for the phase-3 quote-region mask.
# =============================================================================
#
# The phase-3 scanners compute "is byte k inside a quoted field" as a prefix
# XOR of the chunk's quote bits. For the Posix dialect a quote preceded by the
# escape byte inside a quoted field is literal content, so its bit must be
# cleared before the prefix XOR or it flips the parity and every later byte of
# the chunk is classified on the wrong side (komira-ai/komira#1129).
#
# Which escape bytes are active depends on the quote region, and the quote
# region depends on which quotes survive, so this walk is sequential: it
# visits only the set bits of `quote_bits | escape_bits` in byte order and
# mirrors the per-byte FSA (an escape byte inside a quoted field consumes the
# next byte, whatever it is; outside a quoted field it is a field byte).
# Chunks with no escape byte and no carried escape return `quote_bits`
# unchanged without walking.
# =============================================================================

from std.bit import count_trailing_zeros


@always_inline
def cancel_posix_escaped_quotes_u64(
    quote_bits: UInt64,
    escape_bits: UInt64,
    in_quote_at_start: Bool,
    mut escape_carry: Bool,
) -> UInt64:
    """Clear the bits of quotes escaped by the Posix escape byte.

    Args:
        quote_bits:        Bit k set iff byte k of the chunk is the quote.
        escape_bits:       Bit k set iff byte k of the chunk is the escape.
        in_quote_at_start: True iff byte 0 of the chunk lies inside a quoted
                           field (the previous chunk's quote-region carry).
        escape_carry:      In: byte 63 of the previous chunk was an active
                           escape, so byte 0 of this chunk is escaped. Out:
                           byte 63 of this chunk is an active escape.

    Returns:
        `quote_bits` without the escaped quotes: every remaining bit opens or
        closes a quoted field.
    """
    if escape_bits == UInt64(0) and not escape_carry:
        return quote_bits
    var bits = quote_bits
    var in_quote = in_quote_at_start
    # The byte index the last active escape consumes; -1 when none.
    var escaped_pos: Int = 0 if escape_carry else -1
    var walk = quote_bits | escape_bits
    while walk != UInt64(0):
        var k = Int(count_trailing_zeros(walk))
        walk = walk & (walk - UInt64(1))
        var mask = UInt64(1) << UInt64(k)
        if k == escaped_pos:
            # Consumed by the preceding escape: literal content.
            bits = bits & ~mask
            continue
        # Same precedence as the FSA's QUOTED state: escape before quote.
        if in_quote and (escape_bits & mask) != UInt64(0):
            escaped_pos = k + 1
        elif (quote_bits & mask) != UInt64(0):
            in_quote = not in_quote
    escape_carry = escaped_pos == 64
    return bits
