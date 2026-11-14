# =============================================================================
# varint_encode.mojo — Avro binary primitive ENCODERS (the inverse of
#                      varint_decode_scalar.mojo).
# =============================================================================
#
# Avro 1.11.1 binary encoding, write direction.
#
# Avro's binary encoding is row-oriented and varint-heavy. This module is the
# write-direction inverse of `varint_decode_scalar.mojo`:
#   - `int` / `long`        : zigzag varint (1-5 / 1-10 bytes).
#   - `float`               : 4 raw little-endian bytes (IEEE-754 binary32).
#   - `double`              : 8 raw little-endian bytes (IEEE-754 binary64).
#   - `boolean`             : 1 byte (0x00 = false, 0x01 = true).
#   - `bytes` / `string`    : a `long` byte-length followed by N raw bytes.
#   - `fixed[N]`            : exactly N raw bytes (no length prefix).
#   - union tag             : a `long` zigzag of the selected branch index.
#
# Encapsulation: every writer appends into a borrowed `mut List[UInt8]` output
# buffer (the canonical owned byte sink). No UnsafePointer crosses any module
# boundary. The encoders are free functions (like the OcfHeader `_read_long`
# named-result discipline) — a
# cursor struct buys nothing on the write side because a `List[UInt8]` already
# carries its own position via `append`.
# =============================================================================

from std.memory import bitcast


# =============================================================================
# Zigzag varint long / int.
# =============================================================================
#
# Avro encodes `int` and `long` identically on the wire (modulo the value
# range). Both use ZigZag then a little-endian base-128 varint:
#   zigzag(n) = (n << 1) ^ (n >> 63)        # arithmetic shift for the sign
# then 7 bits per byte, high bit = continuation.


@always_inline
def encode_long(n: Int64, mut out: List[UInt8]):
    """Encode an Avro `long` (zigzag varint) into `out`. 1-10 bytes."""
    # ZigZag: map signed -> unsigned so small-magnitude values stay short.
    # NOTE: a stack-staged `InlineArray[UInt8, 10]` + `out.extend(Span(le)[:i])`
    # variant (the stage-then-extend pattern of `encode_float`/`encode_double`)
    # was slower: for short varints (1-3 bytes, typical for int64 columns and
    # union tags) the per-byte `append` path avoids Span construction, slicing
    # and the extend bounds check. A faster varint path would have to amortize
    # over many cells of a column, not stage one cell at a time.
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


@always_inline
def encode_int(n: Int32, mut out: List[UInt8]):
    """Encode an Avro `int` (zigzag varint) into `out`. 1-5 bytes.

    The wire encoding is identical to `long` modulo the value width — we widen
    to Int64 and reuse `encode_long` (the reader narrows on read_int)."""
    encode_long(Int64(n), out)


# =============================================================================
# boolean.
# =============================================================================


@always_inline
def encode_boolean(v: Bool, mut out: List[UInt8]):
    """Encode an Avro `boolean`: exactly 1 byte (0x00 / 0x01)."""
    out.append(UInt8(1) if v else UInt8(0))


# =============================================================================
# float / double — raw little-endian IEEE-754.
# =============================================================================


@always_inline
def encode_float(v: Float32, mut out: List[UInt8]):
    """Encode an Avro `float`: 4 raw little-endian bytes (IEEE-754 binary32).

    Stages the 4 LE bytes into a stack `InlineArray` then bulk-extends the
    output in ONE grow+memcpy (vs 4 individual `append` bounds/capacity-check
    stores). The bytes are identical: LE IEEE-754 binary32, same as arrow-avro's
    `value.to_bits().to_le_bytes()` + one `write_all`."""
    var bits = bitcast[DType.uint32, 1](v)
    var le = Array[UInt8, 4](uninitialized=True)
    le[0] = UInt8(bits & UInt32(0xFF))
    le[1] = UInt8((bits >> UInt32(8)) & UInt32(0xFF))
    le[2] = UInt8((bits >> UInt32(16)) & UInt32(0xFF))
    le[3] = UInt8((bits >> UInt32(24)) & UInt32(0xFF))
    out.extend(Span(le))


@always_inline
def encode_double(v: Float64, mut out: List[UInt8]):
    """Encode an Avro `double`: 8 raw little-endian bytes (IEEE-754 binary64).

    Stages the 8 LE bytes into a stack `InlineArray` then bulk-extends the
    output in ONE grow+memcpy (vs 8 individual `append` stores per value — on a
    float64-heavy schema this is the dominant write-append cost). Identical
    bytes to arrow-avro's `to_bits().to_le_bytes()` + one `write_all`."""
    var bits = bitcast[DType.uint64, 1](v)
    var le = Array[UInt8, 8](uninitialized=True)
    comptime for i in range(8):
        le[i] = UInt8((bits >> UInt64(8 * i)) & UInt64(0xFF))
    out.extend(Span(le))


# =============================================================================
# bytes / string — a `long` byte-length followed by N raw bytes.
# =============================================================================


@always_inline
def encode_bytes(b: Span[UInt8, _], mut out: List[UInt8]):
    """Encode an Avro `bytes`: a `long` byte-length followed by the raw bytes.

    Writes the length varint, then bulk-extends the whole payload in ONE
    grow+memcpy (vs N per-byte `append` calls). Mirrors arrow-avro's
    `write_len_prefixed` -> `out.write_all(bytes)`."""
    encode_long(Int64(len(b)), out)
    out.extend(b)


@always_inline
def encode_string(s: String, mut out: List[UInt8]):
    """Encode an Avro `string`: a `long` byte-length followed by UTF-8 bytes.

    Length varint + one bulk `extend` of the whole UTF-8 payload (vs N per-byte
    `append`)."""
    var sb = s.as_bytes()
    encode_long(Int64(len(sb)), out)
    out.extend(sb)


# =============================================================================
# fixed[N] — exactly N raw bytes, no length prefix.
# =============================================================================


@always_inline
def encode_fixed(b: Span[UInt8, _], mut out: List[UInt8]):
    """Encode an Avro `fixed[N]`: exactly the raw bytes, NO length prefix.

    The caller is responsible for ensuring `len(b)` equals the schema's
    declared fixed size (the writer validates this before calling). One bulk
    `extend` (vs N per-byte `append`)."""
    out.extend(b)


# =============================================================================
# union branch tag.
# =============================================================================


@always_inline
def encode_union_tag(branch_index: Int, mut out: List[UInt8]):
    """Encode an Avro union branch selector: a `long` zigzag of the index.

    For a `union[null, T]` (NULL_FIRST), branch 0 == null, branch 1 == T.
    For a `union[T, null]` (NULL_SECOND), branch 0 == T, branch 1 == null.
    This matches the reader's `read_long()` union-tag consume in
    action_table.mojo `_decode_read_field`."""
    encode_long(Int64(branch_index), out)
