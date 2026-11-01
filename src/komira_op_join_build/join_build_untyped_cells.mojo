# =============================================================================
# join_build_untyped_cells -- the per-column cell kernels of
# `JoinBuildTable_Untyped`: encode a batch cell into a storage slot, hash a
# key cell (batch side and storage side), and compare a key cell (batch
# against storage, storage against storage)
# =============================================================================
#
# Dispatch is an in-line if/elif over the descriptor's `kind` and `dtype_tag`
# (LLVM lowers the arm set to a switch). Each kernel reads or writes ONE
# column of ONE row; the table loops over its key and payload descriptors.
#
# THE TWO SIDES MUST AGREE. A key hashed from the batch (`_hash_single_col`)
# and the same key hashed back out of storage (`_hash_storage_single_col`) must
# be equal, and the equality the probe uses must hold exactly for keys that
# hash alike under that rule. Float keys follow the query semantics' float
# model: every NaN is one value and `-0.0` equals `+0.0` (both hashes use the
# canonical bits, both equalities `float_quotient_eq_*`).
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_arrow.string_column_view import StringView
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
)
from komira_counters.keyeq_census import keyeq_record, KEYEQ_JOINBUILD_UNTYPED
from komira_udf.float_quotient_order import (
    canonical_bits_f32,
    canonical_bits_f64,
    float_quotient_eq_f32,
    float_quotient_eq_f64,
)

from .join_untyped_key_hash import (
    _hash_decimal128,
    _hash_string_view,
    _hash_u64,
)


def _encode_cell[
    bo: Origin[mut=False]
](
    mut storage: ColumnFormatStorage,
    batch: BatchView[bo],
    desc: ColDescriptor,
    row: Int,
    slot: Int,
) raises:
    """Per-DType encode of a single (col, row) cell from `batch`
    into `storage` at (col_idx_in_storage, slot).

    Phase C-G.3 dispatch is in-line if/elif over the 16 fixed-DType
    tags + varlen STUBs. Phase C-G.5 will hoist this into a
    Variant-typed encoder field on ColDescriptor.
    """
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
            # i16 maps to u16 cell via wire-shape (signed reinterpret).
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
            # `.load`, NOT `.validity_load` — BOOL-KEY-READS-VALIDITY
            #. Account on `_encode_key_cell`'s BOOL arm in
            # `hash_agg_untyped.mojo`.
            var v = batch.col_bool(col_in_batch).load[1](row)[0]
            # Bool stored as 1B per slot in storage (per C-G.1 §3.3).
            storage.write_slot_u8(
                col_in_storage,
                slot,
                UInt8(1) if v else UInt8(0),
            )
            return
        raise Error(
            "JoinBuildTable_Untyped._encode_cell: unsupported fixed"
            " dtype_tag=" + String(Int(desc.dtype_tag))
        )

    # ─── Decimal128 ──────────────────────────────────────────────────
    if desc.kind == COL_DECIMAL128:
        # Full 128-bit key: write BOTH u64 words into the 16B slot (LO at
        # slot*16, HI at slot*16+8) via `write_slot_decimal128`. Carrying
        # only the LO word would false-match two build/probe keys that
        # share their low 64 bits but differ in the high 64 bits — a
        # silent wrong-join hazard.
        var lo = batch.col_decimal128_lo(col_in_batch).load[1](row)[0]
        var hi = batch.col_decimal128_hi(col_in_batch).load[1](row)[0]
        storage.write_slot_decimal128(col_in_storage, slot, lo, hi)
        return

    # ─── Varlen STRING / BINARY via STRINGCOLUMNVIEW-SUBSTRATE-V04 ──
    if desc.kind == COL_VAR_STRING:
        # ⭐ STRKEY-BULK JOIN TWIN: copy the cell bytes STRAIGHT from the
        # borrowed batch window into the slot heap. The prior form
        # allocated a `List[UInt8]` per inserted build row and filled it
        # one `byte_at` call at a time, purely to satisfy
        # `write_slot_str`'s owned-payload signature.
        # `write_slot_str_from_byteview` writes the identical bytes and the
        # identical 8B descriptor cell, as one memcpy.
        var sv = batch.col_str(col_in_batch).get(row)
        storage.write_slot_str_from_byteview(
            col_in_storage, slot, sv.bytes_view(), 0, sv.length()
        )
        return
    if desc.kind == COL_VAR_BINARY:
        var bv = batch.col_binary(col_in_batch).get(row)
        storage.write_slot_str_from_byteview(
            col_in_storage, slot, bv.bytes_view(), 0, bv.length()
        )
        return

    raise Error(
        "JoinBuildTable_Untyped._encode_cell: unknown kind="
        + String(Int(desc.kind))
        + " dtype_tag=" + String(Int(desc.dtype_tag))
    )


def _key_eq_single_col[
    bo: Origin[mut=False]
](
    storage: ColumnFormatStorage,
    batch: BatchView[bo],
    row: Int,
    slot: Int,
    desc: ColDescriptor,
) raises -> Bool:
    """Per-DType single-col key-equality.

    Phase C-G.3 dispatch: in-line if/elif on dtype_tag (sibling of
    `_encode_cell`).
    """
    var col_in_storage = desc.col_idx_in_storage
    var col_in_batch = desc.col_idx_in_batch

    if desc.kind == COL_FIXED:
        if desc.dtype_tag == DT_I64:
            var b = batch.col_i64(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_i64(col_in_storage, slot)
            return Int(b) == Int(s)
        if desc.dtype_tag == DT_F64:
            var b = batch.col_f64(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_f64(col_in_storage, slot)
            # Float keys compare under the float model of the query
            # semantics (docs/design/query_semantics.md, 3.9 and 2.6): every
            # NaN equals every NaN and `-0.0` equals `+0.0`, as in DuckDB.
            # IEEE `==` would drop the NaN pairs; a raw-bit compare would also
            # split the two zeros. `_hash_single_col` hashes the canonical
            # bits, so equal keys always reach this compare.
            return float_quotient_eq_f64(Float64(b), Float64(s))
        if desc.dtype_tag == DT_I32 or desc.dtype_tag == DT_DATE32:
            var b = batch.col_i32(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_i32(col_in_storage, slot)
            return Int(b) == Int(s)
        if desc.dtype_tag == DT_F32:
            var b = batch.col_f32(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_f32(col_in_storage, slot)
            return float_quotient_eq_f32(Float32(b), Float32(s))
        if desc.dtype_tag == DT_I16:
            # SIGNED-NARROW KEY EQUALITY — compare in the UNSIGNED SLOT
            # DOMAIN. The key was stored via
            # `write_slot_u16(UInt16(Int(v)))`, so the slot holds the 16-bit
            # two's-complement pattern. The prior
            # `Int(b) == Int(Int16(Int(s)))` re-derived a signed Int16
            # inline, and `Int(Int16(Int(runtime_u16)))` is MISCOMPILED on
            # the pinned Mojo (the inner truncation is folded away when its
            # result feeds `Int()` directly) — so a NEGATIVE key compared
            # 65535-ish vs -1 and NEVER MATCHED: every build row became its
            # own chain head and every probe row found nothing, i.e. the
            # join silently returned no matches at all. Both sides now
            # materialize at 16 bits, so no conversion semantics are relied
            # on. Guarded by `tests/test_join_hash_store_grow.mojo`.
            var b = batch.col_i16(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u16(col_in_storage, slot)
            return Int(s) == Int(UInt16(Int(b)))
        if desc.dtype_tag == DT_U16:
            var b = batch.col_u16(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u16(col_in_storage, slot)
            return Int(b) == Int(s)
        if desc.dtype_tag == DT_I8:
            # SIGNED-NARROW KEY EQUALITY, one width down — see DT_I16 above.
            var b = batch.col_i8(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u8(col_in_storage, slot)
            return Int(s) == Int(UInt8(Int(b)))
        if desc.dtype_tag == DT_U8 or desc.dtype_tag == DT_BOOL:
            var b: UInt8
            if desc.dtype_tag == DT_BOOL:
                # `.load`, NOT `.validity_load` — BOOL-KEY-READS-VALIDITY
                #. Account on `_encode_key_cell`'s BOOL arm in
                # `hash_agg_untyped.mojo`.
                var v = batch.col_bool(col_in_batch).load[1](row)[0]
                b = UInt8(1) if v else UInt8(0)
            else:
                b = batch.col_u8(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u8(col_in_storage, slot)
            return Int(b) == Int(s)
        if desc.dtype_tag == DT_U32:
            var b = batch.col_u32(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u32(col_in_storage, slot)
            return Int(b) == Int(s)
        if desc.dtype_tag == DT_U64:
            var b = batch.col_u64(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u64(col_in_storage, slot)
            return Int(b) == Int(s)
        if desc.dtype_tag == DT_DATE64:
            var b = batch.col_date64(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u64(col_in_storage, slot)
            return Int(b) == Int(Int64(Int(s)))
        if desc.dtype_tag == DT_TIMESTAMP_NS:
            var b = batch.col_timestamp_ns(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u64(col_in_storage, slot)
            return Int(b) == Int(Int64(Int(s)))
        if desc.dtype_tag == DT_TIMESTAMP_US:
            var b = batch.col_timestamp_us(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u64(col_in_storage, slot)
            return Int(b) == Int(Int64(Int(s)))
        if desc.dtype_tag == DT_TIMESTAMP_MS:
            var b = batch.col_timestamp_ms(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u64(col_in_storage, slot)
            return Int(b) == Int(Int64(Int(s)))
        if desc.dtype_tag == DT_TIMESTAMP_S:
            var b = batch.col_timestamp_s(col_in_batch).load[1](row)[0]
            var s = storage.read_slot_u64(col_in_storage, slot)
            return Int(b) == Int(Int64(Int(s)))
        return False
    if desc.kind == COL_DECIMAL128:
        # Full 128-bit equality: compare BOTH words.
        var b_lo = batch.col_decimal128_lo(col_in_batch).load[1](row)[0]
        var b_hi = batch.col_decimal128_hi(col_in_batch).load[1](row)[0]
        var s_lo = storage.read_slot_u64(col_in_storage, slot)
        var s_hi = storage.read_slot_decimal128_hi(
            col_in_storage, slot
        )
        return Bool(b_lo == s_lo) and Bool(b_hi == s_hi)
    if desc.kind == COL_VAR_STRING:
        # ⭐ STRKEY-BULK JOIN TWIN: in-place byte-compare, no alloc on
        # either side. See `_str_cell_eq_slot` below.
        return _str_cell_eq_slot(storage, 
            batch.col_str(col_in_batch).get(row), col_in_storage, slot
        )
    if desc.kind == COL_VAR_BINARY:
        return _str_cell_eq_slot(storage, 
            batch.col_binary(col_in_batch).get(row), col_in_storage, slot
        )
    return False


@always_inline
def _str_cell_eq_slot[
    so: Origin[mut=False]
](
    storage: ColumnFormatStorage,
    sv: StringView[so],
    col_in_storage: Int,
    slot: Int,
) raises -> Bool:
    """In-place byte-equality of a batch STRING / BINARY cell against the
    stored slot payload. Equivalent to `_bytes_eq(batch_bytes,
    storage_bytes)` — same answer, same census record — without allocating
    either byte list."""
    var sl = sv.length()
    var stored_len = storage.read_slot_str_len(col_in_storage, slot)
    if sl != stored_len:
        # `_bytes_eq`'s own length-mismatch record: width = the FIRST
        # argument's length, which was the batch cell's.
        keyeq_record(KEYEQ_JOINBUILD_UNTYPED, sl, 0, False)
        return False
    var _d = storage.slot_str_first_diff(
        col_in_storage, slot, sv.bytes_view(), 0, sl
    )
    var _eq = _d < 0
    var _i = sl if _eq else _d
    keyeq_record(KEYEQ_JOINBUILD_UNTYPED, sl, _i, _eq)
    return _eq


def _hash_single_col[
    bo: Origin[mut=False]
](
    batch: BatchView[bo],
    desc: ColDescriptor,
    row: Int,
) raises -> UInt64:
    """Per-DType single-col hash.

    Phase C-G.3 dispatch: in-line if/elif on dtype_tag.
    """
    var col_in_batch = desc.col_idx_in_batch

    if desc.kind == COL_FIXED:
        if desc.dtype_tag == DT_I64:
            var v = batch.col_i64(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_F64:
            var v = batch.col_f64(col_in_batch).load[1](row)[0]
            # The CANONICAL bits (-0.0 -> +0.0, every NaN -> one NaN), so
            # keys equal under `float_quotient_eq_f64` hash alike.
            return _hash_u64(canonical_bits_f64(Float64(v)))
        if desc.dtype_tag == DT_I32 or desc.dtype_tag == DT_DATE32:
            var v = batch.col_i32(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_F32:
            var v = batch.col_f32(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(canonical_bits_f32(Float32(v)))))
        if desc.dtype_tag == DT_I16:
            var v = batch.col_i16(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_U16:
            var v = batch.col_u16(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_I8:
            var v = batch.col_i8(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_U8:
            var v = batch.col_u8(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_U32:
            var v = batch.col_u32(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_U64:
            var v = batch.col_u64(col_in_batch).load[1](row)[0]
            return _hash_u64(v)
        if desc.dtype_tag == DT_DATE64:
            var v = batch.col_date64(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_TIMESTAMP_NS:
            var v = batch.col_timestamp_ns(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_TIMESTAMP_US:
            var v = batch.col_timestamp_us(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_TIMESTAMP_MS:
            var v = batch.col_timestamp_ms(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_TIMESTAMP_S:
            var v = batch.col_timestamp_s(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_BOOL:
            # `.load`, NOT `.validity_load` — BOOL-KEY-READS-VALIDITY
            #. Account on `_encode_key_cell`'s BOOL arm in
            # `hash_agg_untyped.mojo`.
            var v = batch.col_bool(col_in_batch).load[1](row)[0]
            return _hash_u64(UInt64(1) if v else UInt64(0))
        raise Error(
            "JoinBuildTable_Untyped._hash_single_col: unsupported"
            " fixed dtype_tag=" + String(Int(desc.dtype_tag))
        )
    if desc.kind == COL_DECIMAL128:
        var v_lo = batch.col_decimal128_lo(col_in_batch).load[1](row)[0]
        var v_hi = batch.col_decimal128_hi(col_in_batch).load[1](row)[0]
        return _hash_decimal128(v_lo, v_hi)
    if desc.kind == COL_VAR_STRING:
        # ⭐ STRKEY-BULK JOIN TWIN: hash the borrowed cell in place.
        # Bit-identical to the per-row `List[UInt8]` + `_hash_bytes` pair
        # it replaces; see `_hash_string_view`.
        return _hash_string_view(batch.col_str(col_in_batch).get(row))
    if desc.kind == COL_VAR_BINARY:
        return _hash_string_view(batch.col_binary(col_in_batch).get(row))
    raise Error(
        "JoinBuildTable_Untyped._hash_single_col: unknown kind="
        + String(Int(desc.kind))
    )


def _storage_key_eq_single_col(
    storage: ColumnFormatStorage, desc: ColDescriptor, slot_a: Int, slot_b: Int
) raises -> Bool:
    """Per-DType single-col storage-vs-storage key equality (sister of
    `_key_eq_single_col`, both sides read from storage)."""
    var ci = desc.col_idx_in_storage
    if desc.kind == COL_FIXED:
        if desc.dtype_tag == DT_F64:
            return float_quotient_eq_f64(
                Float64(storage.read_slot_f64(ci, slot_a)),
                Float64(storage.read_slot_f64(ci, slot_b)),
            )
        if desc.dtype_tag == DT_F32:
            return float_quotient_eq_f32(
                Float32(storage.read_slot_f32(ci, slot_a)),
                Float32(storage.read_slot_f32(ci, slot_b)),
            )
        if desc.dtype_tag == DT_I64:
            return Int(storage.read_slot_i64(ci, slot_a)) == Int(
                storage.read_slot_i64(ci, slot_b)
            )
        if desc.dtype_tag == DT_I32 or desc.dtype_tag == DT_DATE32:
            return Int(storage.read_slot_i32(ci, slot_a)) == Int(
                storage.read_slot_i32(ci, slot_b)
            )
        if (desc.dtype_tag == DT_I16 or desc.dtype_tag == DT_U16):
            return Int(storage.read_slot_u16(ci, slot_a)) == Int(
                storage.read_slot_u16(ci, slot_b)
            )
        if (desc.dtype_tag == DT_I8 or desc.dtype_tag == DT_U8
                or desc.dtype_tag == DT_BOOL):
            return Int(storage.read_slot_u8(ci, slot_a)) == Int(
                storage.read_slot_u8(ci, slot_b)
            )
        if desc.dtype_tag == DT_U32:
            return Int(storage.read_slot_u32(ci, slot_a)) == Int(
                storage.read_slot_u32(ci, slot_b)
            )
        if (desc.dtype_tag == DT_U64 or desc.dtype_tag == DT_DATE64
                or desc.dtype_tag == DT_TIMESTAMP_NS
                or desc.dtype_tag == DT_TIMESTAMP_US
                or desc.dtype_tag == DT_TIMESTAMP_MS
                or desc.dtype_tag == DT_TIMESTAMP_S):
            return Int(storage.read_slot_u64(ci, slot_a)) == Int(
                storage.read_slot_u64(ci, slot_b)
            )
        return False
    if desc.kind == COL_DECIMAL128:
        return Bool(
            storage.read_slot_u64(ci, slot_a)
            == storage.read_slot_u64(ci, slot_b)
        ) and Bool(
            storage.read_slot_decimal128_hi(ci, slot_a)
            == storage.read_slot_decimal128_hi(ci, slot_b)
        )
    if desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
        # ⭐ STRKEY-BULK JOIN TWIN: the storage-vs-storage half. Two
        # `read_slot_str_bytes` allocations (each re-resolving its own
        # descriptor cell, then appending one byte per call) fed a third
        # per-byte loop in `_bytes_eq`. `slot_str_slot_first_diff` resolves
        # BOTH cells once and compares 8 bytes at a time, returning the
        # index the scalar loop broke at. Census triple preserved, and
        # `_bytes_eq` recorded the FIRST argument's length on a mismatch —
        # that was `slot_a`'s.
        var la = storage.read_slot_str_len(ci, slot_a)
        var lb = storage.read_slot_str_len(ci, slot_b)
        if la != lb:
            keyeq_record(KEYEQ_JOINBUILD_UNTYPED, la, 0, False)
            return False
        var _d = storage.slot_str_slot_first_diff(
            ci, slot_a, slot_b, la
        )
        var _eq = _d < 0
        var _i = la if _eq else _d
        keyeq_record(KEYEQ_JOINBUILD_UNTYPED, la, _i, _eq)
        return _eq
    return False


def _hash_storage_single_col(
    storage: ColumnFormatStorage, desc: ColDescriptor, slot: Int
) raises -> UInt64:
    """Per-DType single-col hash, reading from storage at `slot`."""
    var col_in_storage = desc.col_idx_in_storage

    if desc.kind == COL_FIXED:
        if desc.dtype_tag == DT_I64:
            var v = storage.read_slot_i64(col_in_storage, slot)
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_F64:
            var v = storage.read_slot_f64(col_in_storage, slot)
            return _hash_u64(canonical_bits_f64(Float64(v)))
        if desc.dtype_tag == DT_I32 or desc.dtype_tag == DT_DATE32:
            var v = storage.read_slot_i32(col_in_storage, slot)
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_F32:
            var v = storage.read_slot_f32(col_in_storage, slot)
            return _hash_u64(UInt64(Int(canonical_bits_f32(Float32(v)))))
        if desc.dtype_tag == DT_I16 or desc.dtype_tag == DT_U16:
            var v = storage.read_slot_u16(col_in_storage, slot)
            return _hash_u64(UInt64(Int(v)))
        if (desc.dtype_tag == DT_I8 or desc.dtype_tag == DT_U8
                or desc.dtype_tag == DT_BOOL):
            var v = storage.read_slot_u8(col_in_storage, slot)
            return _hash_u64(UInt64(Int(v)))
        if desc.dtype_tag == DT_U32:
            var v = storage.read_slot_u32(col_in_storage, slot)
            return _hash_u64(UInt64(Int(v)))
        if (desc.dtype_tag == DT_U64 or desc.dtype_tag == DT_DATE64
                or desc.dtype_tag == DT_TIMESTAMP_NS
                or desc.dtype_tag == DT_TIMESTAMP_US
                or desc.dtype_tag == DT_TIMESTAMP_MS
                or desc.dtype_tag == DT_TIMESTAMP_S):
            var v = storage.read_slot_u64(col_in_storage, slot)
            return _hash_u64(v)
        raise Error(
            "JoinBuildTable_Untyped._hash_storage_single_col:"
            " unsupported fixed dtype_tag="
            + String(Int(desc.dtype_tag))
        )
    if desc.kind == COL_DECIMAL128:
        var v_lo = storage.read_slot_u64(col_in_storage, slot)
        var v_hi = storage.read_slot_decimal128_hi(
            col_in_storage, slot
        )
        return _hash_decimal128(v_lo, v_hi)
    if desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
        # ⭐ STRKEY-BULK JOIN TWIN: hash the heap bytes IN PLACE. The old
        # path allocated a `List[UInt8]` per occupied slot — and a
        # directory grow rehashes EVERY occupied slot — purely to hand the
        # bytes to `_hash_bytes`. `slot_str_fnv1a` is bit-identical to
        # `_hash_string_view` over the same bytes, which is what makes a
        # rehashed slot land in the bucket the batch-side hash chose: same
        # seed
        # (0xCBF29CE484222325), same prime (0x100000001B3), same byte
        # order, same `h ^= h >> 16` final fold.
        return storage.slot_str_fnv1a(col_in_storage, slot)
    raise Error(
        "JoinBuildTable_Untyped._hash_storage_single_col: unknown"
        " kind=" + String(Int(desc.kind))
    )
