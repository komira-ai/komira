# =============================================================================
# wire_types.mojo — Protocol Buffers wire-type constants + zigzag transforms.
# =============================================================================
#
# The 3-bit wire-type field that prefixes every protobuf record. These four
# values are the ENTIRE protobuf wire-type space — wire types 3 and 4 (start /
# end group) are deprecated and never emitted by a proto3 encoder.
#
# Protocol Buffers wire encoding primer (proto3):
#   - A field is `tag = (field_number << 3) | wire_type`, the tag itself a
#     varint. The low 3 bits select the wire type.
#   - VARINT  (0): base-128 LEB128. int32/64, uint32/64, sint, bool, enum.
#   - FIXED64 (1): 8 little-endian bytes. fixed64, sfixed64, double.
#   - LEN     (2): varint length prefix + payload. string, bytes, embedded
#                  messages, packed-repeated scalars.
#   - FIXED32 (5): 4 little-endian bytes. fixed32, sfixed32, float.
#
# Encapsulation: this module is pure constants + pure scalar arithmetic — no
# pointers, no allocations. It is the leaf of the komira_protobuf DAG.
# =============================================================================


# =============================================================================
# Protobuf wire types (the low 3 bits of every field tag).
# =============================================================================

comptime PB_WIRE_VARINT: Int = 0  # int32/64, uint32/64, sint, bool, enum
comptime PB_WIRE_FIXED64: Int = 1  # fixed64, sfixed64, double
comptime PB_WIRE_LEN: Int = 2  # string, bytes, embedded messages, packed repeated
comptime PB_WIRE_FIXED32: Int = 5  # fixed32, sfixed32, float


@always_inline
def _write_pb_wire_type_name[W: Writer](mut writer: W, wire_type: Int):
    """WRITE what `pb_wire_type_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, so a shipped shared
    library can bind such a pair CROSSED and take the host process
    with it."""
    if wire_type == PB_WIRE_VARINT:
        writer.write(String("VARINT"))
        return
    elif wire_type == PB_WIRE_FIXED64:
        writer.write(String("FIXED64"))
        return
    elif wire_type == PB_WIRE_LEN:
        writer.write(String("LEN"))
        return
    elif wire_type == PB_WIRE_FIXED32:
        writer.write(String("FIXED32"))
        return
    writer.write(String("UNKNOWN"))
    return


@always_inline
def pb_wire_type_name(wire_type: Int) -> String:
    """Human-readable protobuf wire-type name (for diagnostics / tests)."""
    var out = String()
    _write_pb_wire_type_name(out, wire_type)
    return out^


# =============================================================================
# Zigzag transforms — the sint32 / sint64 signed-varint encoding.
#
# Protobuf's plain int32/int64 encode negative numbers as a full 10-byte
# varint (sign-extended). The `sint*` types instead zigzag-map signed integers
# to unsigned so small-magnitude negatives stay small on the wire:
#   ...,  -2 -> 3,  -1 -> 1,  0 -> 0,  1 -> 2,  2 -> 4, ...
# encode: (n << 1) ^ (n >> 63)        decode: (u >>> 1) ^ -(u & 1)
# =============================================================================


@always_inline
def zigzag_encode(v: Int64) -> UInt64:
    """Protobuf sint64 zigzag encode: `(n << 1) ^ (n >> 63)`."""
    return UInt64((v << 1) ^ (v >> 63))


@always_inline
def zigzag_decode(u: UInt64) -> Int64:
    """Protobuf sint64 zigzag decode: `(n >>> 1) ^ -(n & 1)`."""
    return Int64(u >> 1) ^ -Int64(u & 1)


@always_inline
def zigzag_encode32(v: Int32) -> UInt32:
    """Protobuf sint32 zigzag encode: `(n << 1) ^ (n >> 31)`."""
    return UInt32((v << 1) ^ (v >> 31))


@always_inline
def zigzag_decode32(u: UInt32) -> Int32:
    """Protobuf sint32 zigzag decode: `(n >>> 1) ^ -(n & 1)`."""
    return Int32(u >> 1) ^ -Int32(u & 1)
