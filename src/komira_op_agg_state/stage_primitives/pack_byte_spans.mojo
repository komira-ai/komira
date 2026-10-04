# =============================================================================
# pack_byte_spans.mojo — Q1-OPT-2 small-width STRING composite key packing
#
# Encapsulated helpers that pack 2 or 3 small-width byte spans (each ≤3 bytes)
# into a single Int64. Used by the runtime-breaker composite-STRING feed to
# route through the i64-keyed dense `HashAggTableF64` substrate (which has
# Knuth-multiplicative hash + SIMD `update_chunk[W]`), bypassing the byte-
# keyed substrate's per-byte FNV-1a + scalar memcmp on sub-16-byte keys.
#
# # Packing scheme (collision-safe across heterogeneous lengths)
#
# For arity-2 composite (`pack_2_byte_spans_u64`):
#
#   bit:    63              56 55              32 31              24 23                0
#           +----------------+--------------------+------------------+------------------+
# val:      |   len0 (byte)  |   c0 bytes (3 B)   |   len1 (byte)    |   c1 bytes (3 B) |
#           +----------------+--------------------+------------------+------------------+
#           ^                ^                    ^                  ^
#           MSB (bits 63-56) (bits 55-32)         (bits 31-24)       LSB (bits 23-0)
#
#   - `len0` in `[0, 3]`. `len0 > 3` → MUST fall back to byte-keyed substrate.
#   - `c0` bytes are packed as big-endian, zero-padded to 3 bytes.
#   - Same shape for `len1` + `c1`.
#
# For arity-3 composite (`pack_3_byte_spans_u64`):
#
#   Reserved 4 bits per length tag (max 2 bytes per component); 2-byte payload
#   per component:
#
#   bit:    63    60    56  47..32 31    28    24  23..0
#           +-----+-----+----+------+-----+-----+----+------+
# val:      |len0 |len1 |len2| c0 (2B) | c1 (2B) | c2 (2B) |
#           +-----+-----+----+------+-----+-----+----+------+
#
#   Wait: 4+4+4=12 bits for lengths + 16+16+16=48 bits for payload = 60 bits.
#   Remaining 4 bits zero-reserved (kept for future-proofing).
#
#   - Lengths in `[0, 2]`. `len > 2` → fall back.
#   - Designed primarily for Q1 / TPC-H Q1-shape queries where char codes are 1B.
#
# # Collision-safety proof sketch
#
# The packed value is a bijection from (len-tuple, byte-tuple) to u64 for all
# tuples where every length ≤ MAX_LEN_PER_COMPONENT. Two distinct input tuples
# differ in at least one position; that position maps to distinct bits in the
# u64; therefore distinct u64 outputs. (`('A', 'B') vs ('AB', '')` example:
# len0=1 ≠ len0=2 → byte 7 differs → distinct packed u64.)
#
# # Encapsulation invariants (the internal development notes §1, §3)
#
# - Public API: `pack_2_byte_spans_u64[ImmO, ImmO']` + `pack_3_byte_spans_u64`
#   accept `Span[UInt8, ImmO]` (no UnsafePointer crossing) and return
#   `Optional[Int64]` (None on width-overflow → caller falls back).
# - Reverse: `unpack_2_byte_spans_u64(packed) -> (List[UInt8], List[UInt8])`
#   returns owned byte sequences for the finalize/decode path.
# - All math is on POD `UInt64` / `UInt8`; no wildcard origins.
# =============================================================================


comptime PACK_MAX_LEN_PER_COMPONENT_2: Int = 3
"""Maximum bytes per component for arity-2 packing. Components exceeding
this width MUST take the byte-keyed fallback."""

comptime PACK_MAX_LEN_PER_COMPONENT_3: Int = 2
"""Maximum bytes per component for arity-3 packing. Components exceeding
this width MUST take the byte-keyed fallback."""


@always_inline
def pack_2_byte_spans_u64[
    ImmO0: Origin[mut=False], ImmO1: Origin[mut=False],
](
    imm c0: Span[UInt8, ImmO0],
    imm c1: Span[UInt8, ImmO1],
) -> Optional[Int64]:
    """Pack two small byte spans into a single Int64 key.

    Returns `None` if EITHER component exceeds `PACK_MAX_LEN_PER_COMPONENT_2`
    (3 bytes). Caller falls back to byte-keyed substrate on `None`.

    Layout (collision-safe via length-prefix-per-component):
        bits[63:56]: len0
        bits[55:32]: c0 (3 bytes, big-endian, zero-padded right)
        bits[31:24]: len1
        bits[23:0]:  c1 (3 bytes, big-endian, zero-padded right)
    """
    var l0 = len(c0)
    var l1 = len(c1)
    if l0 > PACK_MAX_LEN_PER_COMPONENT_2 or l1 > PACK_MAX_LEN_PER_COMPONENT_2:
        return None

    # Pack c0 bytes left-aligned into bits 55..32 (3 bytes, zero-pad right).
    var c0_packed = UInt64(0)
    if l0 > 0:
        c0_packed = c0_packed | (UInt64(c0[0]) << 16)
    if l0 > 1:
        c0_packed = c0_packed | (UInt64(c0[1]) << 8)
    if l0 > 2:
        c0_packed = c0_packed | UInt64(c0[2])

    # Pack c1 bytes left-aligned into bits 23..0 (3 bytes, zero-pad right).
    var c1_packed = UInt64(0)
    if l1 > 0:
        c1_packed = c1_packed | (UInt64(c1[0]) << 16)
    if l1 > 1:
        c1_packed = c1_packed | (UInt64(c1[1]) << 8)
    if l1 > 2:
        c1_packed = c1_packed | UInt64(c1[2])

    var packed = (
        (UInt64(l0) << 56)
        | (c0_packed << 32)
        | (UInt64(l1) << 24)
        | c1_packed
    )
    return Optional[Int64](Int64(packed))


@always_inline
def unpack_2_byte_spans_u64(packed: Int64) -> Tuple[List[UInt8], List[UInt8]]:
    """Reverse-pack: extract the two byte sequences from a packed Int64.

    Returns `(c0_bytes, c1_bytes)` as owned `List[UInt8]` (length-correct,
    NOT padded). Used at finalize time to reconstruct the STRING output cells.
    """
    var p = UInt64(packed)
    var l0 = Int((p >> 56) & 0xFF)
    var c0_packed = (p >> 32) & 0xFFFFFF
    var l1 = Int((p >> 24) & 0xFF)
    var c1_packed = p & 0xFFFFFF

    var c0 = List[UInt8](capacity=l0)
    if l0 > 0:
        c0.append(UInt8((c0_packed >> 16) & 0xFF))
    if l0 > 1:
        c0.append(UInt8((c0_packed >> 8) & 0xFF))
    if l0 > 2:
        c0.append(UInt8(c0_packed & 0xFF))

    var c1 = List[UInt8](capacity=l1)
    if l1 > 0:
        c1.append(UInt8((c1_packed >> 16) & 0xFF))
    if l1 > 1:
        c1.append(UInt8((c1_packed >> 8) & 0xFF))
    if l1 > 2:
        c1.append(UInt8(c1_packed & 0xFF))

    return (c0^, c1^)


@always_inline
def pack_3_byte_spans_u64[
    ImmO0: Origin[mut=False],
    ImmO1: Origin[mut=False],
    ImmO2: Origin[mut=False],
](
    imm c0: Span[UInt8, ImmO0],
    imm c1: Span[UInt8, ImmO1],
    imm c2: Span[UInt8, ImmO2],
) -> Optional[Int64]:
    """Pack three small byte spans into a single Int64 key.

    Returns `None` if ANY component exceeds `PACK_MAX_LEN_PER_COMPONENT_3`
    (2 bytes).

    Layout:
        bits[63:60]: len0 (0..2)
        bits[59:56]: len1
        bits[55:52]: len2
        bits[51:48]: reserved (0)
        bits[47:32]: c0 (2 bytes)
        bits[31:16]: c1 (2 bytes)
        bits[15:0]:  c2 (2 bytes)
    """
    var l0 = len(c0)
    var l1 = len(c1)
    var l2 = len(c2)
    if l0 > PACK_MAX_LEN_PER_COMPONENT_3 \
            or l1 > PACK_MAX_LEN_PER_COMPONENT_3 \
            or l2 > PACK_MAX_LEN_PER_COMPONENT_3:
        return None

    var c0_packed = UInt64(0)
    if l0 > 0:
        c0_packed = c0_packed | (UInt64(c0[0]) << 8)
    if l0 > 1:
        c0_packed = c0_packed | UInt64(c0[1])

    var c1_packed = UInt64(0)
    if l1 > 0:
        c1_packed = c1_packed | (UInt64(c1[0]) << 8)
    if l1 > 1:
        c1_packed = c1_packed | UInt64(c1[1])

    var c2_packed = UInt64(0)
    if l2 > 0:
        c2_packed = c2_packed | (UInt64(c2[0]) << 8)
    if l2 > 1:
        c2_packed = c2_packed | UInt64(c2[1])

    var packed = (
        (UInt64(l0) << 60)
        | (UInt64(l1) << 56)
        | (UInt64(l2) << 52)
        | (c0_packed << 32)
        | (c1_packed << 16)
        | c2_packed
    )
    return Optional[Int64](Int64(packed))


@always_inline
def unpack_3_byte_spans_u64(
    packed: Int64,
) -> Tuple[List[UInt8], List[UInt8], List[UInt8]]:
    """Reverse-pack: extract three byte sequences from a packed Int64."""
    var p = UInt64(packed)
    var l0 = Int((p >> 60) & 0xF)
    var l1 = Int((p >> 56) & 0xF)
    var l2 = Int((p >> 52) & 0xF)
    var c0_packed = (p >> 32) & 0xFFFF
    var c1_packed = (p >> 16) & 0xFFFF
    var c2_packed = p & 0xFFFF

    var c0 = List[UInt8](capacity=l0)
    if l0 > 0:
        c0.append(UInt8((c0_packed >> 8) & 0xFF))
    if l0 > 1:
        c0.append(UInt8(c0_packed & 0xFF))

    var c1 = List[UInt8](capacity=l1)
    if l1 > 0:
        c1.append(UInt8((c1_packed >> 8) & 0xFF))
    if l1 > 1:
        c1.append(UInt8(c1_packed & 0xFF))

    var c2 = List[UInt8](capacity=l2)
    if l2 > 0:
        c2.append(UInt8((c2_packed >> 8) & 0xFF))
    if l2 > 1:
        c2.append(UInt8(c2_packed & 0xFF))

    return (c0^, c1^, c2^)
