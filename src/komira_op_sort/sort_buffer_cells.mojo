# =============================================================================
# The cell codec of `SortBuffer_Untyped`: one cell in, two cells compared
# =============================================================================
#
# `_encode_cell` copies one (column, row) cell of a `BatchView` into a slot
# of the buffer's `ColumnFormatStorage`; `_compare_cells` orders two slots of
# one column. Both dispatch at run time on the column's `ColDescriptor`
# (storage kind and DType tag).
#
# Narrow signed DTypes (I16, I8) are stored in unsigned cells of their width
# and sign-extended on the way back by integer arithmetic (`_sext_cell_*`).
# Do not "simplify" those to `Int(Int16(Int(u)))`: the compiler has folded
# that sign-extend-of-truncate-of-zero-extend to a zero-extend, which sorts
# every negative key after every non-negative one.
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_arrow.string_column_view import (
    BinaryColumnView,
    StringColumnView,
)
from komira_column_format.column_format_storage import (
    ColumnFormatStorage,
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    COL_VAR_BINARY,
    COL_DECIMAL128,
    DT_I64,
    DT_F64,
    DT_I32,
    DT_F32,
    DT_I16,
    DT_I8,
    DT_U8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_DATE32,
    DT_DATE64,
    DT_BOOL,
    DT_TIMESTAMP_NS,
    DT_TIMESTAMP_US,
    DT_TIMESTAMP_MS,
    DT_TIMESTAMP_S,
    DT_DECIMAL128,
    DT_STRING,
    DT_BINARY,
    DT_NONE,
)

from .sort import sort_key_lt


@always_inline
def _sext_cell_u16(u: UInt16) -> Int:
    """Reinterpret a u16 cell as a signed Int16 value, widened to Int."""
    var v = Int(u)
    if v >= 0x8000:
        return v - 0x10000
    return v


@always_inline
def _sext_cell_u8(u: UInt8) -> Int:
    """Reinterpret a u8 cell as a signed Int8 value, widened to Int."""
    var v = Int(u)
    if v >= 0x80:
        return v - 0x100
    return v


def _encode_cell[
    bo: Origin[mut=False]
](
    mut storage: ColumnFormatStorage,
    batch: BatchView[bo],
    desc: ColDescriptor,
    row: Int,
    slot: Int,
) raises:
    """Copy cell (`desc.col_idx_in_batch`, `row`) of `batch` into
    `storage` at (`desc.col_idx_in_storage`, `slot`), by `desc`'s kind and
    DType tag. I16 / I8 go into unsigned cells of the same width; DATE64 and
    the TIMESTAMP units into u64 cells; BOOL into a u8 cell (0 / 1)."""
    var col_in_storage = desc.col_idx_in_storage
    var col_in_batch = desc.col_idx_in_batch

    # ─── Fixed DTypes ────────────────────────────────────────────────
    if desc.kind == COL_FIXED:
        if desc.dtype_tag == DT_I64:
            var v = batch.col_i64(col_in_batch).load[1](row)[0]
            storage.write_slot_i64(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_F64:
            var v = batch.col_f64(col_in_batch).load[1](row)[0]
            storage.write_slot_f64(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_I32:
            var v = batch.col_i32(col_in_batch).load[1](row)[0]
            storage.write_slot_i32(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_F32:
            var v = batch.col_f32(col_in_batch).load[1](row)[0]
            storage.write_slot_f32(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_DATE32:
            var v = batch.col_date32(col_in_batch).load[1](row)[0]
            storage.write_slot_i32(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_I16:
            var v = batch.col_i16(col_in_batch).load[1](row)[0]
            storage.write_slot_u16(col_in_storage, slot, UInt16(Int(v)))
            return
        if desc.dtype_tag == DT_U16:
            var v = batch.col_u16(col_in_batch).load[1](row)[0]
            storage.write_slot_u16(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_I8:
            var v = batch.col_i8(col_in_batch).load[1](row)[0]
            storage.write_slot_u8(col_in_storage, slot, UInt8(Int(v)))
            return
        if desc.dtype_tag == DT_U8:
            var v = batch.col_u8(col_in_batch).load[1](row)[0]
            storage.write_slot_u8(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_U32:
            var v = batch.col_u32(col_in_batch).load[1](row)[0]
            storage.write_slot_u32(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_U64:
            var v = batch.col_u64(col_in_batch).load[1](row)[0]
            storage.write_slot_u64(col_in_storage, slot, v)
            return
        if desc.dtype_tag == DT_DATE64:
            var v = batch.col_date64(col_in_batch).load[1](row)[0]
            storage.write_slot_u64(col_in_storage, slot, UInt64(Int(v)))
            return
        if desc.dtype_tag == DT_TIMESTAMP_NS:
            var v = batch.col_timestamp_ns(col_in_batch).load[1](row)[0]
            storage.write_slot_u64(col_in_storage, slot, UInt64(Int(v)))
            return
        if desc.dtype_tag == DT_TIMESTAMP_US:
            var v = batch.col_timestamp_us(col_in_batch).load[1](row)[0]
            storage.write_slot_u64(col_in_storage, slot, UInt64(Int(v)))
            return
        if desc.dtype_tag == DT_TIMESTAMP_MS:
            var v = batch.col_timestamp_ms(col_in_batch).load[1](row)[0]
            storage.write_slot_u64(col_in_storage, slot, UInt64(Int(v)))
            return
        if desc.dtype_tag == DT_TIMESTAMP_S:
            var v = batch.col_timestamp_s(col_in_batch).load[1](row)[0]
            storage.write_slot_u64(col_in_storage, slot, UInt64(Int(v)))
            return
        if desc.dtype_tag == DT_BOOL:
            # `.load` (the VALUE bit), NOT `.validity_load`.
            var v = batch.col_bool(col_in_batch).load[1](row)[0]
            storage.write_slot_u8(
                col_in_storage,
                slot,
                UInt8(1) if v else UInt8(0),
            )
            return
        raise Error(
            "SortBuffer_Untyped encode: unsupported fixed"
            " dtype_tag=" + String(Int(desc.dtype_tag))
        )

    # ─── Decimal128 ──────────────────────────────────────────────────
    if desc.kind == COL_DECIMAL128:
        # Full 128-bit key: store BOTH words (LO at slot*16, HI at
        # slot*16+8). LO-only stored the low 64 bits and mis-ordered
        # decimals whose ordering lives in the high 64 bits (and treated
        # the value as unsigned).
        var lo = batch.col_decimal128_lo(col_in_batch).load[1](row)[0]
        var hi = batch.col_decimal128_hi(col_in_batch).load[1](row)[0]
        storage.write_slot_decimal128(col_in_storage, slot, lo, hi)
        return

    # ─── Varlen STRING / BINARY ──────────────────────────────────────
    if desc.kind == COL_VAR_STRING:
        var sv = batch.col_str(col_in_batch).get(row)
        var payload = List[UInt8]()
        var slen = sv.length()
        for i in range(slen):
            payload.append(sv.byte_at(i))
        storage.write_slot_str(col_in_storage, slot, payload^)
        return
    if desc.kind == COL_VAR_BINARY:
        var bv = batch.col_binary(col_in_batch).get(row)
        var payload = List[UInt8]()
        var blen = bv.length()
        for i in range(blen):
            payload.append(bv.byte_at(i))
        storage.write_slot_str(col_in_storage, slot, payload^)
        return

    raise Error(
        "SortBuffer_Untyped encode: unknown kind="
        + String(Int(desc.kind))
        + " dtype_tag=" + String(Int(desc.dtype_tag))
    )


def _compare_cells(
    storage: ColumnFormatStorage, desc: ColDescriptor, slot_a: Int, slot_b: Int
) raises -> Int:
    """-1 / 0 / +1: cell `slot_a` against cell `slot_b` of column
    `desc.col_idx_in_storage`, ascending. Floats order by `sort_key_lt`
    (NaN above +inf); the caller applies the direction."""
    var col_in_storage = desc.col_idx_in_storage

    if desc.kind == COL_FIXED:
        if desc.dtype_tag == DT_I64:
            var a = storage.read_slot_i64(col_in_storage, slot_a)
            var b = storage.read_slot_i64(col_in_storage, slot_b)
            if Int(a) < Int(b):
                return -1
            if Int(a) > Int(b):
                return 1
            return 0
        if desc.dtype_tag == DT_F64:
            var a = storage.read_slot_f64(col_in_storage, slot_a)
            var b = storage.read_slot_f64(col_in_storage, slot_b)
            if sort_key_lt(a, b):
                return -1
            if sort_key_lt(b, a):
                return 1
            return 0
        if desc.dtype_tag == DT_I32 or desc.dtype_tag == DT_DATE32:
            var a = storage.read_slot_i32(col_in_storage, slot_a)
            var b = storage.read_slot_i32(col_in_storage, slot_b)
            if Int(a) < Int(b):
                return -1
            if Int(a) > Int(b):
                return 1
            return 0
        if desc.dtype_tag == DT_F32:
            var a = storage.read_slot_f32(col_in_storage, slot_a)
            var b = storage.read_slot_f32(col_in_storage, slot_b)
            if sort_key_lt(a, b):
                return -1
            if sort_key_lt(b, a):
                return 1
            return 0
        if desc.dtype_tag == DT_I16:
            var a = storage.read_slot_u16(col_in_storage, slot_a)
            var b = storage.read_slot_u16(col_in_storage, slot_b)
            # Reinterpret the unsigned cell as signed Int16.
            # Not `Int(Int16(Int(a)))`: see `_sext_cell_u16`.
            var sa = _sext_cell_u16(a)
            var sb = _sext_cell_u16(b)
            if sa < sb:
                return -1
            if sa > sb:
                return 1
            return 0
        if desc.dtype_tag == DT_U16:
            var a = storage.read_slot_u16(col_in_storage, slot_a)
            var b = storage.read_slot_u16(col_in_storage, slot_b)
            if Int(a) < Int(b):
                return -1
            if Int(a) > Int(b):
                return 1
            return 0
        if desc.dtype_tag == DT_I8:
            var a = storage.read_slot_u8(col_in_storage, slot_a)
            var b = storage.read_slot_u8(col_in_storage, slot_b)
            # Not `Int(Int8(Int(a)))`: see `_sext_cell_u8`.
            var sa = _sext_cell_u8(a)
            var sb = _sext_cell_u8(b)
            if sa < sb:
                return -1
            if sa > sb:
                return 1
            return 0
        if desc.dtype_tag == DT_U8 or desc.dtype_tag == DT_BOOL:
            var a = storage.read_slot_u8(col_in_storage, slot_a)
            var b = storage.read_slot_u8(col_in_storage, slot_b)
            if Int(a) < Int(b):
                return -1
            if Int(a) > Int(b):
                return 1
            return 0
        if desc.dtype_tag == DT_U32:
            var a = storage.read_slot_u32(col_in_storage, slot_a)
            var b = storage.read_slot_u32(col_in_storage, slot_b)
            if Int(a) < Int(b):
                return -1
            if Int(a) > Int(b):
                return 1
            return 0
        if desc.dtype_tag == DT_U64:
            var a = storage.read_slot_u64(col_in_storage, slot_a)
            var b = storage.read_slot_u64(col_in_storage, slot_b)
            if a < b:
                return -1
            if a > b:
                return 1
            return 0
        if desc.dtype_tag == DT_DATE64:
            var a = storage.read_slot_u64(col_in_storage, slot_a)
            var b = storage.read_slot_u64(col_in_storage, slot_b)
            # Date64 stored as u64 cell; reinterpret as signed Int64.
            var sa = Int(Int64(Int(a)))
            var sb = Int(Int64(Int(b)))
            if sa < sb:
                return -1
            if sa > sb:
                return 1
            return 0
        if (desc.dtype_tag == DT_TIMESTAMP_NS
                or desc.dtype_tag == DT_TIMESTAMP_US
                or desc.dtype_tag == DT_TIMESTAMP_MS
                or desc.dtype_tag == DT_TIMESTAMP_S):
            var a = storage.read_slot_u64(col_in_storage, slot_a)
            var b = storage.read_slot_u64(col_in_storage, slot_b)
            # Timestamp_* stored as u64 cell; reinterpret as signed Int64.
            var sa = Int(Int64(Int(a)))
            var sb = Int(Int64(Int(b)))
            if sa < sb:
                return -1
            if sa > sb:
                return 1
            return 0
        raise Error(
            "SortBuffer_Untyped compare:"
            " unsupported fixed dtype_tag="
            + String(Int(desc.dtype_tag))
        )
    if desc.kind == COL_DECIMAL128:
        # Full 128-bit SIGNED compare: reassemble each slot's two LE u64
        # words into an int128 (two's complement) and order signed. Same-
        # scale within one column, so unscaled-int128 order == decimal
        # order. LO-only + unsigned mis-ordered negatives and any values
        # whose ordering lives in the high 64 bits.
        var a_lo = storage.read_slot_u64(col_in_storage, slot_a)
        var a_hi = storage.read_slot_decimal128_hi(
            col_in_storage, slot_a
        )
        var b_lo = storage.read_slot_u64(col_in_storage, slot_b)
        var b_hi = storage.read_slot_decimal128_hi(
            col_in_storage, slot_b
        )
        var a = (
            (a_hi.cast[DType.uint128]() << UInt128(64))
            | a_lo.cast[DType.uint128]()
        ).cast[DType.int128]()
        var b = (
            (b_hi.cast[DType.uint128]() << UInt128(64))
            | b_lo.cast[DType.uint128]()
        ).cast[DType.int128]()
        if a < b:
            return -1
        if a > b:
            return 1
        return 0
    if desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
        # Byte-wise unsigned, the shorter first on a shared prefix.
        var bytes_a = storage.read_slot_str_bytes(
            col_in_storage, slot_a
        )
        var bytes_b = storage.read_slot_str_bytes(
            col_in_storage, slot_b
        )
        var an = bytes_a.__len__()
        var bn = bytes_b.__len__()
        var minlen = an if an < bn else bn
        for i in range(minlen):
            var ai = Int(bytes_a[i])
            var bi = Int(bytes_b[i])
            if ai < bi:
                return -1
            if ai > bi:
                return 1
        # Prefix-equal: shorter sorts first.
        if an < bn:
            return -1
        if an > bn:
            return 1
        return 0
    raise Error(
        "SortBuffer_Untyped compare: unknown"
        " kind=" + String(Int(desc.kind))
    )
