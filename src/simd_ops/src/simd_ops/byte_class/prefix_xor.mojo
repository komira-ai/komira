# =============================================================================
# prefix_xor.mojo — cumulative XOR with carry threading.
# =============================================================================
#
# CSV / JSON central primitive: given an unescaped-quote bitmask,
# compute the "in_string" state at each bit position via cumulative
# XOR.  Bit k of the result = `carry_in XOR (sum of input bits 0..k mod 2)`.
#
# Three implementations:
#   * `prefix_xor_u16` — 4-step shift-XOR ladder (~5 ops); lowers cleanly
#     on every target.
#   * `prefix_xor_u32` — same pattern at 32-bit width (5 steps).
#   * `prefix_xor_u64` — 64-bit (6 steps).
#
# The PMULL64 path (NEON) is single-instruction:
#
#   pmull.1q result, bits, 0xFFFFFFFFFFFFFFFF
#
# multiplied by all-ones gives the prefix-XOR.  This module keeps the
# shift-ladder form (portable + correct on every target); the carry-less
# multiply form lives in `quote_region_mask.mojo`, where the
# simdcsv-style scan needs it.  Both forms give identical results.
#
# Encapsulation: scalar in, scalar out.  Carry threaded via `mut Bool`
# argument.  No pointers.
# =============================================================================


@always_inline
def prefix_xor_u16(bits: UInt32, mut carry: Bool) -> UInt32:
    """16-bit cumulative-XOR with carry.  Returns 16-bit result in
    lower bits of UInt32.  Mutates `carry` to the carry-out (high bit
    of the cumulative XOR).

    4-step shift-XOR ladder (~5 ops) — lowers cleanly on every target.
    """
    var t: UInt32 = bits & UInt32(0xFFFF)
    t ^= t << UInt32(1)
    t ^= t << UInt32(2)
    t ^= t << UInt32(4)
    t ^= t << UInt32(8)
    t &= UInt32(0xFFFF)
    if carry:
        t ^= UInt32(0xFFFF)
    carry = (t & UInt32(0x8000)) != 0
    return t


@always_inline
def prefix_xor_u32(bits: UInt32, mut carry: Bool) -> UInt32:
    """32-bit cumulative-XOR with carry.

    Same shift-XOR ladder pattern, extended to 32 bits.
    5-step ladder (1 / 2 / 4 / 8 / 16).
    """
    var t: UInt32 = bits
    t ^= t << UInt32(1)
    t ^= t << UInt32(2)
    t ^= t << UInt32(4)
    t ^= t << UInt32(8)
    t ^= t << UInt32(16)
    if carry:
        t ^= UInt32(0xFFFFFFFF)
    carry = (t & UInt32(0x80000000)) != 0
    return t


@always_inline
def prefix_xor_u64(bits: UInt64, mut carry: Bool) -> UInt64:
    """64-bit cumulative-XOR with carry.

    6-step shift-XOR ladder (1 / 2 / 4 / 8 / 16 / 32).
    """
    var t: UInt64 = bits
    t ^= t << UInt64(1)
    t ^= t << UInt64(2)
    t ^= t << UInt64(4)
    t ^= t << UInt64(8)
    t ^= t << UInt64(16)
    t ^= t << UInt64(32)
    if carry:
        t ^= UInt64(0xFFFFFFFFFFFFFFFF)
    carry = (t & UInt64(0x8000000000000000)) != 0
    return t
