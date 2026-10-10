# =============================================================================
# arrow_row.mojo — byte-lex Arrow Row sort encoding
# =============================================================================
#
# Ports DataFusion's `arrow-row` byte-lex sort encoding from
# `arrow-rs/arrow-row/src/{lib,fixed}.rs`. Apache-2.0 licensed (see
# attribution block below).
#
# Produces a memcmp-comparable byte string from a row's keys so that
# multi-column sort comparison reduces to a single `memcmp` call instead of
# per-cell branching (~50-80 ms/query on Row-routed sort). A nested Arrow Row
# encoding would reuse the per-DType leaf encoders here.
#
# Scope:
#   * Fixed-width DTypes: I64 / F64 / I32 / F32 / I16 / I8 / U8 / U16 /
#     U32 / U64 / BOOL / DATE32 / DATE64 / TIMESTAMP_NS / TIMESTAMP_US /
#     TIMESTAMP_MS / TIMESTAMP_S / DECIMAL128.
#   * Variable-width (STRING, BINARY): OUT OF SCOPE. The composite encoder
#     raises on these dtype tags; the public API signature already accepts
#     them.
#
# Encoding rules (per DataFusion `arrow-row/src/lib.rs` rendered doc):
#   * Null sentinel byte per column slot:
#       0x00 = null (NULLS_FIRST mode)
#       0x01 = non-null
#       0xFF = null (NULLS_LAST mode)
#   * Signed integers (I8/I16/I32/I64): flip sign bit (XOR 1<<(W-1)) +
#     big-endian write.
#   * Unsigned integers (U8/U16/U32/U64): big-endian, no sign flip.
#   * F32/F64: the engine's float order (the DuckDB QUOTIENT order) —
#     CANONICALISE (every NaN -> one +NaN, -0.0 -> +0.0), then
#     reinterpret bits; if sign set, flip all bits; if clear, flip only the
#     sign bit. Then big-endian.
#   * Bool: 0x00 / 0x01 raw.
#   * Decimal128 (the 16-byte cell's high and low u64 words):
#     flip sign bit of high u64; write [high_BE, low_BE] (16 bytes).
#   * Date/Timestamp: inherits underlying I32/I64 encoding.
#   * ASC: encoded bytes stand. DESC: bit-invert the value bytes (^0xFF)
#     and the non-null sentinel (0x01 -> 0xFE). A NULL slot's sentinel is
#     never inverted (as in arrow-rs): NULLS_FIRST is 0x00 and NULLS_LAST
#     0xFF under either direction, so the NULL sorts before (0x00 < 0x01,
#     0xFE) or after (0xFF > 0x01, 0xFE) every value of that key.
#   * Composite (multi-column): concatenate per-column encoded bytes in
#     column order. memcmp on the concatenation = lex order over columns.
#
# Encapsulation invariants:
#   * Zero `UnsafePointer` in any PUBLIC function signature. Public
#     entries return `List[UInt8]` (composite) or `InlineArray[UInt8, W]`
#     (per-DType leaf); pointer arithmetic is confined to private
#     (`_`-prefixed) byte-write helpers with concrete-origin pointers.
#   * Zero wildcard origin.
#   * Zero `unsafe_from_address=Int(...)`.
#   * Zero ArcPointer.
#   * Zero `take_pointee`.
#
# -----------------------------------------------------------------------------
# Upstream attribution (Apache-2.0):
#
#   Apache Arrow — Rust implementation
#   Copyright 2017-2024 The Apache Software Foundation
#
#   Licensed under the Apache License, Version 2.0 (the "License"); you
#   may not use this file except in compliance with the License. You may
#   obtain a copy of the License at:
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
#   implied. See the License for the specific language governing
#   permissions and limitations under the License.
# -----------------------------------------------------------------------------

from std.bit import byte_swap
from std.memory import bitcast

from komira_udf.float_quotient_order import (
    float_quotient_order_bits_f32,
    float_quotient_order_bits_f64,
)

from komira_arrow.batch_view import BatchView


# =============================================================================
# Sentinel byte aliases
# =============================================================================

# Per arrow-row spec (rendered doc, "Nulls"):
comptime ARROW_ROW_NULL_FIRST: UInt8 = 0x00  # null under NULLS_FIRST default
comptime ARROW_ROW_NON_NULL: UInt8 = 0x01    # non-null value follows
comptime ARROW_ROW_NULL_LAST: UInt8 = 0xFF   # null under NULLS_LAST inversion


# =============================================================================
# DType tags — mirror of `row_block.mojo`
# =============================================================================
#
# We re-declare the aliases here (instead of importing from row_block.mojo)
# to keep this module a pure-byte primitive — same layering invariant as
# `xxh3.mojo`. Any drift in these values vs row_block.mojo is caught by
# the `eval_test_arrow_row` cross-check test.

comptime DT_I64: UInt8 = 1
comptime DT_F64: UInt8 = 2
comptime DT_I32: UInt8 = 3
comptime DT_F32: UInt8 = 4
comptime DT_I16: UInt8 = 5
comptime DT_I8: UInt8 = 6
comptime DT_U8: UInt8 = 7
comptime DT_STRING: UInt8 = 8
comptime DT_U16: UInt8 = 9
comptime DT_U32: UInt8 = 10
comptime DT_U64: UInt8 = 11
comptime DT_DATE32: UInt8 = 12
comptime DT_DECIMAL128: UInt8 = 13
comptime DT_BOOL: UInt8 = 14
comptime DT_DATE64: UInt8 = 15
comptime DT_TIMESTAMP_NS: UInt8 = 16
comptime DT_TIMESTAMP_US: UInt8 = 17
comptime DT_TIMESTAMP_MS: UInt8 = 18
comptime DT_TIMESTAMP_S: UInt8 = 19
comptime DT_BINARY: UInt8 = 20


# =============================================================================
# Sort direction tags (mirror of `row_sort.mojo`)
# =============================================================================

comptime SORT_ASC: UInt8 = 0
comptime SORT_DESC: UInt8 = 1


# Null position tags
comptime NULLS_FIRST: UInt8 = 1
comptime NULLS_LAST: UInt8 = 0


# =============================================================================
# Per-DType encoded widths (excluding the leading null sentinel byte)
# =============================================================================

comptime ENC_W_I8: Int = 1
comptime ENC_W_U8: Int = 1
comptime ENC_W_BOOL: Int = 1
comptime ENC_W_I16: Int = 2
comptime ENC_W_U16: Int = 2
comptime ENC_W_I32: Int = 4
comptime ENC_W_U32: Int = 4
comptime ENC_W_F32: Int = 4
comptime ENC_W_DATE32: Int = 4
comptime ENC_W_I64: Int = 8
comptime ENC_W_U64: Int = 8
comptime ENC_W_F64: Int = 8
comptime ENC_W_DATE64: Int = 8
comptime ENC_W_TIMESTAMP_NS: Int = 8
comptime ENC_W_TIMESTAMP_US: Int = 8
comptime ENC_W_TIMESTAMP_MS: Int = 8
comptime ENC_W_TIMESTAMP_S: Int = 8
comptime ENC_W_DECIMAL128: Int = 16


# =============================================================================
# Per-DType scalar encoders — public surface for nested encoding
# =============================================================================
#
# Each takes a typed scalar value + an `asc: Bool` flag. If asc=False, the
# returned bytes are bit-inverted (^0xFF) so that memcmp natural ascending
# order matches numeric DESCENDING order. This is the leaf primitive for
# nested encoding.
#
# Null sentinel is NOT emitted by these helpers — the composite encoder
# (`encode_row_keys_for_sort`) is responsible for the per-column sentinel.

@always_inline
def _bswap_u16(v: UInt16) -> UInt16:
    """Byte-swap a u16 (BE write on little-endian)."""
    return byte_swap(v)


@always_inline
def _bswap_u32(v: UInt32) -> UInt32:
    """Byte-swap a u32."""
    return byte_swap(v)


@always_inline
def _bswap_u64(v: UInt64) -> UInt64:
    """Byte-swap a u64."""
    return byte_swap(v)


@always_inline
def _maybe_invert_for_desc(b: UInt8, asc: Bool) -> UInt8:
    """Invert byte if asc=False (DESC mode). Single XOR; LLVM lowers to a
    conditional-move on modern x86_64."""
    if asc:
        return b
    return b ^ UInt8(0xFF)


@always_inline
def encode_i64_to_bytes(v: Int64, asc: Bool) -> Array[UInt8, 8]:
    """Encode a signed 64-bit integer.

    Spec: flip sign bit (XOR with 1<<63), then big-endian.
    """
    # Sign-bit flip transforms two's-complement signed to unsigned-magnitude
    # form whose byte-lex order matches numeric signed order.
    var u = bitcast[DType.uint64, 1](v) ^ UInt64(0x8000000000000000)
    var be = _bswap_u64(u)
    var out = Array[UInt8, 8](fill=UInt8(0))
    out[0] = _maybe_invert_for_desc(UInt8((Int(be) >> 0) & 0xFF), asc)
    out[1] = _maybe_invert_for_desc(UInt8((Int(be) >> 8) & 0xFF), asc)
    out[2] = _maybe_invert_for_desc(UInt8((Int(be) >> 16) & 0xFF), asc)
    out[3] = _maybe_invert_for_desc(UInt8((Int(be) >> 24) & 0xFF), asc)
    out[4] = _maybe_invert_for_desc(UInt8((Int(be) >> 32) & 0xFF), asc)
    out[5] = _maybe_invert_for_desc(UInt8((Int(be) >> 40) & 0xFF), asc)
    out[6] = _maybe_invert_for_desc(UInt8((Int(be) >> 48) & 0xFF), asc)
    out[7] = _maybe_invert_for_desc(UInt8((Int(be) >> 56) & 0xFF), asc)
    return out^


@always_inline
def encode_u64_to_bytes(v: UInt64, asc: Bool) -> Array[UInt8, 8]:
    """Encode an unsigned 64-bit integer. No sign-bit flip; big-endian."""
    var be = _bswap_u64(v)
    var out = Array[UInt8, 8](fill=UInt8(0))
    out[0] = _maybe_invert_for_desc(UInt8((Int(be) >> 0) & 0xFF), asc)
    out[1] = _maybe_invert_for_desc(UInt8((Int(be) >> 8) & 0xFF), asc)
    out[2] = _maybe_invert_for_desc(UInt8((Int(be) >> 16) & 0xFF), asc)
    out[3] = _maybe_invert_for_desc(UInt8((Int(be) >> 24) & 0xFF), asc)
    out[4] = _maybe_invert_for_desc(UInt8((Int(be) >> 32) & 0xFF), asc)
    out[5] = _maybe_invert_for_desc(UInt8((Int(be) >> 40) & 0xFF), asc)
    out[6] = _maybe_invert_for_desc(UInt8((Int(be) >> 48) & 0xFF), asc)
    out[7] = _maybe_invert_for_desc(UInt8((Int(be) >> 56) & 0xFF), asc)
    return out^


@always_inline
def encode_f64_to_bytes(v: Float64, asc: Bool) -> Array[UInt8, 8]:
    """Encode a 64-bit float so byte-lex order is the engine's FLOAT ORDER.

    That order is the DuckDB quotient order (`komira_udf.float_quotient_order`):
    every NaN is ONE value above `+inf`, and `-0.0`
    ties `+0.0`. The image is `float_quotient_order_bits_f64` -- the sign-flip
    of the CANONICAL value -- so `-0.0` encodes to `+0.0`'s bytes and every NaN
    to the one canonical NaN's.

    ⛔ NOT IEEE-754 `totalOrder` of the RAW bits (a `-NaN` below `-inf`,
    `-0.0` strictly before `+0.0`): every ORDER BY route must use the same
    order, or one query gets two different answers.
    """
    return encode_u64_to_bytes(float_quotient_order_bits_f64(v), asc)


@always_inline
def encode_i32_to_bytes(v: Int32, asc: Bool) -> Array[UInt8, 4]:
    """Encode a signed 32-bit integer."""
    var u = bitcast[DType.uint32, 1](v) ^ UInt32(0x80000000)
    var be = _bswap_u32(u)
    var out = Array[UInt8, 4](fill=UInt8(0))
    out[0] = _maybe_invert_for_desc(UInt8((Int(be) >> 0) & 0xFF), asc)
    out[1] = _maybe_invert_for_desc(UInt8((Int(be) >> 8) & 0xFF), asc)
    out[2] = _maybe_invert_for_desc(UInt8((Int(be) >> 16) & 0xFF), asc)
    out[3] = _maybe_invert_for_desc(UInt8((Int(be) >> 24) & 0xFF), asc)
    return out^


@always_inline
def encode_u32_to_bytes(v: UInt32, asc: Bool) -> Array[UInt8, 4]:
    """Encode an unsigned 32-bit integer."""
    var be = _bswap_u32(v)
    var out = Array[UInt8, 4](fill=UInt8(0))
    out[0] = _maybe_invert_for_desc(UInt8((Int(be) >> 0) & 0xFF), asc)
    out[1] = _maybe_invert_for_desc(UInt8((Int(be) >> 8) & 0xFF), asc)
    out[2] = _maybe_invert_for_desc(UInt8((Int(be) >> 16) & 0xFF), asc)
    out[3] = _maybe_invert_for_desc(UInt8((Int(be) >> 24) & 0xFF), asc)
    return out^


@always_inline
def encode_f32_to_bytes(v: Float32, asc: Bool) -> Array[UInt8, 4]:
    """Encode a 32-bit float so byte-lex order is the engine's float order
    (the quotient order -- see `encode_f64_to_bytes`)."""
    return encode_u32_to_bytes(float_quotient_order_bits_f32(v), asc)


@always_inline
def encode_i16_to_bytes(v: Int16, asc: Bool) -> Array[UInt8, 2]:
    """Encode a signed 16-bit integer."""
    var u = bitcast[DType.uint16, 1](v) ^ UInt16(0x8000)
    var be = _bswap_u16(u)
    var out = Array[UInt8, 2](fill=UInt8(0))
    out[0] = _maybe_invert_for_desc(UInt8(Int(be) & 0xFF), asc)
    out[1] = _maybe_invert_for_desc(UInt8((Int(be) >> 8) & 0xFF), asc)
    return out^


@always_inline
def encode_u16_to_bytes(v: UInt16, asc: Bool) -> Array[UInt8, 2]:
    """Encode an unsigned 16-bit integer."""
    var be = _bswap_u16(v)
    var out = Array[UInt8, 2](fill=UInt8(0))
    out[0] = _maybe_invert_for_desc(UInt8(Int(be) & 0xFF), asc)
    out[1] = _maybe_invert_for_desc(UInt8((Int(be) >> 8) & 0xFF), asc)
    return out^


@always_inline
def encode_i8_to_bytes(v: Int8, asc: Bool) -> UInt8:
    """Encode a signed 8-bit integer. Single byte; sign-flip only."""
    var u = bitcast[DType.uint8, 1](v) ^ UInt8(0x80)
    return _maybe_invert_for_desc(u, asc)


@always_inline
def encode_u8_to_bytes(v: UInt8, asc: Bool) -> UInt8:
    """Encode an unsigned 8-bit integer. Single raw byte."""
    return _maybe_invert_for_desc(v, asc)


@always_inline
def encode_bool_to_bytes(v: Bool, asc: Bool) -> UInt8:
    """Encode a bool. 0x00 false; 0x01 true. Bit-invert if DESC."""
    var b: UInt8 = UInt8(1) if v else UInt8(0)
    return _maybe_invert_for_desc(b, asc)


@always_inline
def encode_decimal128_to_bytes(
    hi: UInt64, lo: UInt64, asc: Bool
) -> Array[UInt8, 16]:
    """Encode a signed 128-bit decimal (high 64 + low 64).

    Spec: flip sign bit of high u64, then write [high_BE, low_BE].
    """
    var hi_flipped = hi ^ UInt64(0x8000000000000000)
    var hi_be = _bswap_u64(hi_flipped)
    var lo_be = _bswap_u64(lo)
    var out = Array[UInt8, 16](fill=UInt8(0))
    # high 8 bytes (most significant first under BE)
    out[0] = _maybe_invert_for_desc(UInt8((Int(hi_be) >> 0) & 0xFF), asc)
    out[1] = _maybe_invert_for_desc(UInt8((Int(hi_be) >> 8) & 0xFF), asc)
    out[2] = _maybe_invert_for_desc(UInt8((Int(hi_be) >> 16) & 0xFF), asc)
    out[3] = _maybe_invert_for_desc(UInt8((Int(hi_be) >> 24) & 0xFF), asc)
    out[4] = _maybe_invert_for_desc(UInt8((Int(hi_be) >> 32) & 0xFF), asc)
    out[5] = _maybe_invert_for_desc(UInt8((Int(hi_be) >> 40) & 0xFF), asc)
    out[6] = _maybe_invert_for_desc(UInt8((Int(hi_be) >> 48) & 0xFF), asc)
    out[7] = _maybe_invert_for_desc(UInt8((Int(hi_be) >> 56) & 0xFF), asc)
    out[8] = _maybe_invert_for_desc(UInt8((Int(lo_be) >> 0) & 0xFF), asc)
    out[9] = _maybe_invert_for_desc(UInt8((Int(lo_be) >> 8) & 0xFF), asc)
    out[10] = _maybe_invert_for_desc(UInt8((Int(lo_be) >> 16) & 0xFF), asc)
    out[11] = _maybe_invert_for_desc(UInt8((Int(lo_be) >> 24) & 0xFF), asc)
    out[12] = _maybe_invert_for_desc(UInt8((Int(lo_be) >> 32) & 0xFF), asc)
    out[13] = _maybe_invert_for_desc(UInt8((Int(lo_be) >> 40) & 0xFF), asc)
    out[14] = _maybe_invert_for_desc(UInt8((Int(lo_be) >> 48) & 0xFF), asc)
    out[15] = _maybe_invert_for_desc(UInt8((Int(lo_be) >> 56) & 0xFF), asc)
    return out^


# =============================================================================
# Composite encoder — public entry point for sort consumers
# =============================================================================

def encoded_width_for_dtype(dtype_tag: UInt8) raises -> Int:
    """Return the per-column byte width of an encoded slot (including the
    leading null sentinel byte) for a fixed-width DType.

    Raises on STRING / BINARY (varlen).
    """
    if dtype_tag == DT_I8:
        return 1 + ENC_W_I8
    elif dtype_tag == DT_U8:
        return 1 + ENC_W_U8
    elif dtype_tag == DT_BOOL:
        return 1 + ENC_W_BOOL
    elif dtype_tag == DT_I16:
        return 1 + ENC_W_I16
    elif dtype_tag == DT_U16:
        return 1 + ENC_W_U16
    elif dtype_tag == DT_I32:
        return 1 + ENC_W_I32
    elif dtype_tag == DT_U32:
        return 1 + ENC_W_U32
    elif dtype_tag == DT_F32:
        return 1 + ENC_W_F32
    elif dtype_tag == DT_DATE32:
        return 1 + ENC_W_DATE32
    elif dtype_tag == DT_I64:
        return 1 + ENC_W_I64
    elif dtype_tag == DT_U64:
        return 1 + ENC_W_U64
    elif dtype_tag == DT_F64:
        return 1 + ENC_W_F64
    elif dtype_tag == DT_DATE64:
        return 1 + ENC_W_DATE64
    elif dtype_tag == DT_TIMESTAMP_NS:
        return 1 + ENC_W_TIMESTAMP_NS
    elif dtype_tag == DT_TIMESTAMP_US:
        return 1 + ENC_W_TIMESTAMP_US
    elif dtype_tag == DT_TIMESTAMP_MS:
        return 1 + ENC_W_TIMESTAMP_MS
    elif dtype_tag == DT_TIMESTAMP_S:
        return 1 + ENC_W_TIMESTAMP_S
    elif dtype_tag == DT_DECIMAL128:
        return 1 + ENC_W_DECIMAL128
    elif dtype_tag == DT_STRING or dtype_tag == DT_BINARY:
        raise Error(
            "arrow_row.encoded_width_for_dtype: varlen STRING/BINARY"
            " encoding is not implemented"
            " (dtype_tag=" + String(Int(dtype_tag)) + ")"
        )
    else:
        raise Error(
            "arrow_row.encoded_width_for_dtype: unsupported dtype_tag="
            + String(Int(dtype_tag))
        )


def _append_sentinel(
    mut out: List[UInt8], is_null: Bool, nulls_first: Bool, asc: Bool
):
    """Emit the per-slot null sentinel byte. NULLS_FIRST: null=0x00,
    NULLS_LAST: null=0xFF; non-null=0x01, bit-inverted to 0xFE under DESC.

    A NULL's sentinel is not inverted under DESC (arrow-rs does the same):
    `nulls_first` names the NULL's place in the output order, which the
    sort direction does not change. 0x00 sorts before both non-null
    sentinels and 0xFF after both.
    """
    if is_null:
        out.append(
            ARROW_ROW_NULL_FIRST if nulls_first else ARROW_ROW_NULL_LAST
        )
    else:
        out.append(_maybe_invert_for_desc(ARROW_ROW_NON_NULL, asc))


@always_inline
def _append_zeros(mut out: List[UInt8], n: Int):
    """Append `n` zero bytes (used to pad a null slot's value section so
    the encoded slot has constant width per dtype). Under DESC the zeros
    are NOT inverted because they are placeholders for an absent value;
    arrow-row's spec is silent here, but the order-preserving property
    holds as long as the value placeholder is constant across ALL null
    encodings for the same column slot."""
    for _ in range(n):
        out.append(UInt8(0))


def _append_inline_array_8(
    mut out: List[UInt8], v: Array[UInt8, 8]
):
    """Append all 8 bytes of an InlineArray[UInt8, 8] to out."""
    out.append(v[0]); out.append(v[1]); out.append(v[2]); out.append(v[3])
    out.append(v[4]); out.append(v[5]); out.append(v[6]); out.append(v[7])


def _append_inline_array_4(
    mut out: List[UInt8], v: Array[UInt8, 4]
):
    """Append all 4 bytes of an InlineArray[UInt8, 4] to out."""
    out.append(v[0]); out.append(v[1]); out.append(v[2]); out.append(v[3])


def _append_inline_array_2(
    mut out: List[UInt8], v: Array[UInt8, 2]
):
    """Append all 2 bytes of an InlineArray[UInt8, 2] to out."""
    out.append(v[0]); out.append(v[1])


def _append_inline_array_16(
    mut out: List[UInt8], v: Array[UInt8, 16]
):
    """Append all 16 bytes of an InlineArray[UInt8, 16] to out."""
    out.append(v[0]); out.append(v[1]); out.append(v[2]); out.append(v[3])
    out.append(v[4]); out.append(v[5]); out.append(v[6]); out.append(v[7])
    out.append(v[8]); out.append(v[9]); out.append(v[10]); out.append(v[11])
    out.append(v[12]); out.append(v[13]); out.append(v[14]); out.append(v[15])


# =============================================================================
# Composite row-key encoder (BatchView-based)
# =============================================================================

def encode_row_keys_for_sort[bo: Origin[mut=False]](
    batch: BatchView[bo],
    row_idx: Int,
    key_col_idxs: List[Int],
    key_dtype_tags: List[UInt8],
    asc_flags: List[UInt8],
    nulls_first_flags: List[UInt8],
    is_null_per_key: List[Bool],
) raises -> List[UInt8]:
    """Encode one row's composite key as a memcmp-comparable byte string.

    Per-column slot layout: 1 byte null sentinel + W bytes value-encoded
    (where W depends on the dtype). For null slots, the value section is
    zero-padded to W bytes so the encoded slot has constant width per
    column — this preserves order-preserving + memcmp-compatible semantics
    across rows.

    Args:
        batch: Read-only batch view over the input batch.
        row_idx: Row index within the batch.
        key_col_idxs: Column indices in the batch (one per key column).
        key_dtype_tags: Per-column DT_* tag.
        asc_flags: Per-column SORT_ASC (0) or SORT_DESC (1).
        nulls_first_flags: Per-column NULLS_FIRST (1) or NULLS_LAST (0).
        is_null_per_key: Per-column null bit at `row_idx` — caller derives
            from the BatchView's column-level validity bitmap (no
            BatchView `col_is_null(col, row)` accessor; the
            caller is the natural place to fold per-batch null mask
            walking into the encode loop). Length must == n_keys.

    Returns:
        Byte string; memcmp-comparable against other rows' encodings.

    Raises:
        STRING / BINARY dtype tags raise.
        Length-mismatched argument lists raise.
        Unsupported dtype tags raise.

    Parameters:
        bo: Origin of the input BatchView.
    """
    var n_keys = len(key_col_idxs)
    if len(key_dtype_tags) != n_keys:
        raise Error(
            "arrow_row.encode_row_keys_for_sort: key_dtype_tags length "
            + String(len(key_dtype_tags)) + " != n_keys " + String(n_keys)
        )
    if len(asc_flags) != n_keys:
        raise Error(
            "arrow_row.encode_row_keys_for_sort: asc_flags length "
            + String(len(asc_flags)) + " != n_keys " + String(n_keys)
        )
    if len(nulls_first_flags) != n_keys:
        raise Error(
            "arrow_row.encode_row_keys_for_sort: nulls_first_flags length "
            + String(len(nulls_first_flags)) + " != n_keys "
            + String(n_keys)
        )
    if len(is_null_per_key) != n_keys:
        raise Error(
            "arrow_row.encode_row_keys_for_sort: is_null_per_key length "
            + String(len(is_null_per_key)) + " != n_keys " + String(n_keys)
        )

    # Reserve a List with capacity sum-of-widths for amortized append.
    var total: Int = 0
    for k in range(n_keys):
        total = total + encoded_width_for_dtype(key_dtype_tags[k])
    var out = List[UInt8](capacity=total)

    for k in range(n_keys):
        var col_idx = key_col_idxs[k]
        var dt = key_dtype_tags[k]
        var asc = asc_flags[k] == SORT_ASC
        var nf = nulls_first_flags[k] != UInt8(0)
        var col_is_null: Bool = is_null_per_key[k]

        if dt == DT_I64:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_I64)
            else:
                var v = batch.col_i64(col_idx).load[1](row_idx)[0]
                _append_inline_array_8(out, encode_i64_to_bytes(v, asc))
        elif dt == DT_F64:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_F64)
            else:
                var v = batch.col_f64(col_idx).load[1](row_idx)[0]
                _append_inline_array_8(out, encode_f64_to_bytes(v, asc))
        elif dt == DT_U64:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_U64)
            else:
                var v = batch.col_u64(col_idx).load[1](row_idx)[0]
                _append_inline_array_8(out, encode_u64_to_bytes(v, asc))
        elif dt == DT_I32:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_I32)
            else:
                var v = batch.col_i32(col_idx).load[1](row_idx)[0]
                _append_inline_array_4(out, encode_i32_to_bytes(v, asc))
        elif dt == DT_F32:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_F32)
            else:
                var v = batch.col_f32(col_idx).load[1](row_idx)[0]
                _append_inline_array_4(out, encode_f32_to_bytes(v, asc))
        elif dt == DT_U32:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_U32)
            else:
                var v = batch.col_u32(col_idx).load[1](row_idx)[0]
                _append_inline_array_4(out, encode_u32_to_bytes(v, asc))
        elif dt == DT_DATE32:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_DATE32)
            else:
                # DATE32 stored as I32 under the hood (row_block.mojo).
                var v = batch.col_i32(col_idx).load[1](row_idx)[0]
                _append_inline_array_4(out, encode_i32_to_bytes(v, asc))
        elif dt == DT_DATE64:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_DATE64)
            else:
                # DATE64 stored as I64 (row_block.mojo).
                var v = batch.col_i64(col_idx).load[1](row_idx)[0]
                _append_inline_array_8(out, encode_i64_to_bytes(v, asc))
        elif (
            dt == DT_TIMESTAMP_NS or dt == DT_TIMESTAMP_US
            or dt == DT_TIMESTAMP_MS or dt == DT_TIMESTAMP_S
        ):
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, 8)
            else:
                # Timestamps stored as I64 (row_block.mojo).
                var v = batch.col_i64(col_idx).load[1](row_idx)[0]
                _append_inline_array_8(out, encode_i64_to_bytes(v, asc))
        elif dt == DT_I16:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_I16)
            else:
                var v = batch.col_i16(col_idx).load[1](row_idx)[0]
                _append_inline_array_2(out, encode_i16_to_bytes(v, asc))
        elif dt == DT_U16:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_U16)
            else:
                var v = batch.col_u16(col_idx).load[1](row_idx)[0]
                _append_inline_array_2(out, encode_u16_to_bytes(v, asc))
        elif dt == DT_I8:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_I8)
            else:
                var v = batch.col_i8(col_idx).load[1](row_idx)[0]
                out.append(encode_i8_to_bytes(v, asc))
        elif dt == DT_U8:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_U8)
            else:
                var v = batch.col_u8(col_idx).load[1](row_idx)[0]
                out.append(encode_u8_to_bytes(v, asc))
        elif dt == DT_BOOL:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_BOOL)
            else:
                var v = batch.col_bool(col_idx).load_bit(row_idx)
                out.append(encode_bool_to_bytes(v, asc))
        elif dt == DT_DECIMAL128:
            _append_sentinel(out, col_is_null, nf, asc)
            if col_is_null:
                _append_zeros(out, ENC_W_DECIMAL128)
            else:
                # The 16-byte cell's high and low words, read at the
                # 16-byte cell stride.
                var hi = batch.col_decimal128_hi(col_idx).load[1](row_idx)[0]
                var lo = batch.col_decimal128_lo(col_idx).load[1](row_idx)[0]
                _append_inline_array_16(
                    out, encode_decimal128_to_bytes(hi, lo, asc)
                )
        elif dt == DT_STRING or dt == DT_BINARY:
            raise Error(
                "arrow_row.encode_row_keys_for_sort: varlen STRING/BINARY"
                " encoding is not implemented"
                " (key col " + String(k) + " dtype_tag="
                + String(Int(dt)) + ")"
            )
        else:
            raise Error(
                "arrow_row.encode_row_keys_for_sort: unsupported dtype_tag="
                + String(Int(dt)) + " on key col " + String(k)
            )

    return out^


# =============================================================================
# Comparison helper (thin wrapper over libc memcmp)
# =============================================================================

def arrow_row_compare(imm a: List[UInt8], imm b: List[UInt8]) -> Int:
    """Return -1 if a < b, +1 if a > b, 0 if equal, by byte-lex order.

    For length-mismatched inputs: ties on the common prefix are broken
    by length (shorter < longer). This matches Python's bytes comparison
    semantics. For arrow-row encoded keys with equal column-arity + same
    dtypes, lengths are identical so the length-tiebreak is unreached.

    There is no varlen STRING/BINARY encoding (the encoder refuses those
    tags), so every key this compares has a fixed width per dtype.
    """
    var na = len(a)
    var nb = len(b)
    var nmin = na if na < nb else nb
    for i in range(nmin):
        var av = Int(a[i])
        var bv = Int(b[i])
        if av < bv:
            return -1
        if av > bv:
            return 1
    if na < nb:
        return -1
    if na > nb:
        return 1
    return 0
