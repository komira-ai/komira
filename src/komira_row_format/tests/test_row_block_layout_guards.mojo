# =============================================================================
# `komira_row_format.row_block`: layout flags, capacity, the bool and decimal
# batch encoders' cell bytes, the nested-cell refusals, the STRUCT record
# layout, and the var-width key hash.
# =============================================================================
#
# WHAT THIS PROVES
# ----------------
# * `RowLayout` marks a layout var-width for a VAR_STRING or VAR_BINARY
#   descriptor, key or payload, and reserves ceil(n/8) validity bytes once.
# * `write_bool_batch` stores one byte per cell, 0x01 or 0x00, at the cell's
#   offset, touching no other byte; its 64-lane chunk is driven with every
#   lane holding both values across chunks, plus a tail.
# * `write_decimal128_batch` stores the low word then the high word,
#   little-endian (checked byte by byte), and refuses halves of different
#   lengths.
# * The nested cells refuse a values / validity length mismatch and a row out
#   of range, and a NULL LIST<string> reads back empty.
# * A STRUCT record is `[0x00][field bitmap ceil(k/8)][slots...]`: a fixed slot
#   is `fixed_width` little-endian bytes, a var slot a u32 little-endian
#   length then the bytes. The record below is written byte by byte; both the
#   free readers and the RowBlock readers must walk past every field kind to
#   reach the last field. `serialize_struct_record` must write the same bytes.
# * `_hash_row_bytes` over a var-width key hashes the payload, not its
#   descriptor: the same key at two heap offsets hashes alike, while a change
#   in the fixed bytes before or after the descriptor, or anywhere in a
#   payload longer than the 240-byte xxh3 chunk, changes the hash.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_row_format.row_block import (
    COL_DECIMAL128,
    COL_FIXED,
    COL_LIST,
    COL_VAR_BINARY,
    COL_VAR_STRING,
    DT_BINARY,
    DT_DECIMAL128,
    DT_I32,
    DT_I64,
    DT_STRING,
    DT_U16,
    DT_U8,
    ColDescriptor,
    RowBlock,
    RowLayout,
    _hash_row_bytes,
    serialize_struct_record,
    struct_record_field_null,
    struct_record_fixed_field,
    struct_record_is_null,
    struct_record_string_field,
)


def _desc(kind: UInt8, dt: UInt8, w: Int, off: Int) -> ColDescriptor:
    return ColDescriptor(
        kind=kind, dtype_tag=dt, fixed_width=UInt16(w), offset_in_row=UInt16(off)
    )


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _raises_with(msg: String, want: String) raises:
    assert_true(want in msg, "want '" + want + "' in: " + msg)


# -----------------------------------------------------------------------------
# RowLayout
# -----------------------------------------------------------------------------


def test_layout_var_width_flag_per_kind() raises:
    """VAR_STRING and VAR_BINARY set has_var_width as a key or a payload;
    fixed and decimal cells do not."""
    var kinds: List[UInt8] = [COL_VAR_STRING, COL_VAR_BINARY]
    for k in kinds:
        var a = RowLayout()
        a.add_key_col(_desc(k, DT_STRING, 8, 0))
        assert_true(a.has_var_width)
        assert_equal(a.n_key_cols(), 1)
        var b = RowLayout()
        b.add_payload_col(_desc(k, DT_BINARY, 8, 0))
        assert_true(b.has_var_width)
        assert_equal(b.n_payload_cols(), 1)
    var f = RowLayout()
    f.add_key_col(_desc(COL_FIXED, DT_I64, 8, 0))
    f.add_payload_col(_desc(COL_DECIMAL128, DT_DECIMAL128, 16, 8))
    assert_false(f.has_var_width)


def test_layout_validity_bytes_around_eight() raises:
    """ceil(n/8) validity bytes: 0, 1, 1, 2, 2, 3 for 0, 1, 8, 9, 16, 17
    columns; enable_validity reserves them once, at the old stride."""
    var ns: List[Int] = [0, 1, 8, 9, 16, 17]
    var want: List[Int] = [0, 1, 1, 2, 2, 3]
    for i in range(len(ns)):
        assert_equal(RowLayout.validity_bytes_for(ns[i]), want[i])
    var lay = RowLayout()
    for c in range(9):
        lay.add_key_col(_desc(COL_FIXED, DT_I32, 4, 4 * c))
    lay.set_fixed_row_stride(36)
    lay.enable_validity()
    assert_true(lay.has_validity)
    assert_equal(lay.validity_offset, 36)
    assert_equal(lay.fixed_row_stride, 38)
    lay.enable_validity()
    assert_equal(lay.validity_offset, 36)
    assert_equal(lay.fixed_row_stride, 38)


def test_with_capacity_var_budget() raises:
    """with_capacity's var budget is used before any regrow; a zero stride
    reserves no rows."""
    var rb = RowBlock.with_capacity(4, 100, 8)
    assert_equal(rb.capacity, 4)
    assert_equal(rb.var_storage_capacity, 100)
    rb.set_n_rows(1)
    var payload = List[UInt8](length=100, fill=0x5A)
    rb.write_var_string_cell(0, 0, payload)
    assert_equal(rb.var_storage_capacity, 100)
    assert_equal(rb.var_storage_used, 100)
    assert_equal(rb.read_var_string_at(0, 0), payload)
    var zero_stride = RowBlock.with_capacity(4, 0, 0)
    assert_equal(zero_stride.capacity, 0)
    assert_equal(zero_stride.var_storage_capacity, 0)


# -----------------------------------------------------------------------------
# Bool and decimal batch encoders
# -----------------------------------------------------------------------------


def _bool_batch(bits: List[Bool]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.BOOL, False))
    var ba = BooleanArray.allocate(len(bits))
    for i in range(len(bits)):
        ba.set(i, bits[i])
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_boolean(ba))
    return rbb.build(sb.build())


def test_bool_batch_every_lane_both_values() raises:
    """130 rows: chunk 0 holds lane % 3 == 0, chunk 1 its complement, so every
    lane of the 64-wide chunk stores both 0x01 and 0x00; rows 128 and 129 are
    the tail. The cell is byte 1 of a 3-byte row; bytes 0 and 2 keep 0xA5. A
    shorter column written later leaves n_rows at 130."""
    var bits = List[Bool]()
    for r in range(130):
        if r < 64:
            bits.append(r % 3 == 0)
        elif r < 128:
            bits.append((r - 64) % 3 != 0)
        else:
            bits.append(r == 128)
    var batch = _bool_batch(bits)
    var rb = RowBlock.with_capacity(130, 0, 3)
    for r in range(130):
        rb.write_fixed[DType.uint8](r, 0, 0xA5)
        rb.write_fixed[DType.uint8](r, 1, 0x77)
        rb.write_fixed[DType.uint8](r, 2, 0xA5)
    rb.write_bool_batch(BatchView(batch).col_bool(0), 1)
    assert_equal(rb.n_rows, 130)
    for r in range(130):
        var want = UInt8(1) if bits[r] else UInt8(0)
        assert_equal(rb.read_fixed[DType.uint8](r, 1), want, "row " + String(r))
        assert_equal(rb.read_fixed[DType.uint8](r, 0), 0xA5)
        assert_equal(rb.read_fixed[DType.uint8](r, 2), 0xA5)
    var short_bits: List[Bool] = [False, True]
    var short = _bool_batch(short_bits)
    rb.write_bool_batch(BatchView(short).col_bool(0), 1)
    assert_equal(rb.n_rows, 130)
    assert_equal(rb.read_fixed[DType.uint8](0, 1), 0)
    assert_equal(rb.read_fixed[DType.uint8](1, 1), 1)
    assert_equal(rb.read_fixed[DType.uint8](2, 1), 0)


def _dec_batch(lo: List[Int64], hi: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DECIMAL128, False))
    var arr = Decimal128Array.allocate(len(lo), precision=38, scale=0)
    for i in range(len(lo)):
        arr.set_raw(i, lo[i], hi[i])
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_decimal128(arr^))
    return rbb.build(sb.build())


def test_decimal_batch_bytes_and_refusal() raises:
    """Low word at +0, high word at +8, each little-endian; a block already
    holding more rows keeps its n_rows; lo and hi views of different lengths
    are refused."""
    var lo: List[Int64] = [0x0102030405060708, -1]
    var hi: List[Int64] = [0x1112131415161718, 0]
    var batch = _dec_batch(lo, hi)
    var rb = RowBlock.with_capacity(5, 0, 20)
    rb.set_n_rows(5)
    var bv = BatchView(batch)
    rb.write_decimal128_batch(bv.col_decimal128_lo(0), bv.col_decimal128_hi(0), 2)
    assert_equal(rb.n_rows, 5)
    for b in range(8):
        assert_equal(rb.read_fixed[DType.uint8](0, 2 + b), UInt8(8 - b))
        assert_equal(rb.read_fixed[DType.uint8](0, 10 + b), UInt8(0x18 - b))
        assert_equal(rb.read_fixed[DType.uint8](1, 2 + b), 0xFF)
        assert_equal(rb.read_fixed[DType.uint8](1, 10 + b), 0)
    # Two batches held in one list, so their views share one origin.
    var three: List[Int64] = [1, 2, 3]
    var pair = List[RecordBatch]()
    pair.append(_dec_batch(three, three))
    pair.append(_dec_batch(lo, hi))
    var lo_view = BatchView(pair[0]).col_decimal128_lo(0)
    var hi_view = BatchView(pair[1]).col_decimal128_hi(0)
    var msg = String("")
    try:
        rb.write_decimal128_batch(lo_view, hi_view, 2)
    except e:
        msg = String(e)
    _raises_with(msg, "lo.length()=3 != hi.length()=2")


# -----------------------------------------------------------------------------
# Var-string and nested-cell refusals
# -----------------------------------------------------------------------------


def test_key_cell_refusals_and_ranges() raises:
    """A zero-length cell has no NULL tag byte and is refused as a key; a
    negative row is out of range for the var-string reader."""
    var rb = RowBlock.with_capacity(2, 0, 8)
    rb.set_n_rows(2)
    rb.write_var_string_cell(0, 0, List[UInt8]())
    var msg = String("")
    try:
        _ = rb.var_string_key_is_null_at(0, 0)
    except e:
        msg = String(e)
    _raises_with(msg, "row 0, offset 0 carries a zero-length payload")
    rb.write_var_string_key_null_cell(1, 0)
    assert_true(rb.var_string_key_is_null_at(1, 0))
    rb.write_var_string_key_cell(1, 0, String("").as_bytes())
    assert_false(rb.var_string_key_is_null_at(1, 0))
    var raised = False
    try:
        _ = rb.read_var_string_at(-1, 0)
    except:
        raised = True
    assert_true(raised)


def test_nested_cells_refuse_mismatch_and_range() raises:
    """Each nested writer refuses a validity span of another length; each
    reader refuses a row below 0 or at n_rows; a NULL LIST<string> reads
    back as two empty lists."""
    var rb = RowBlock.with_capacity(2, 0, 8)
    rb.set_n_rows(2)
    var two_vals: List[Int32] = [1, 2]
    var three_nulls: List[Bool] = [False, False, False]
    var one_null: List[Bool] = [False]
    var msg = String("")
    try:
        rb.write_list_primitive_cell[DType.int32](0, 0, two_vals, three_nulls)
    except e:
        msg = String(e)
    _raises_with(msg, "values len 2 != elem_nulls len 3")
    var elems = List[List[UInt8]]()
    elems.append([0x61])
    elems.append([0x62])
    msg = String("")
    try:
        rb.write_list_string_cell(0, 0, elems, one_null)
    except e:
        msg = String(e)
    _raises_with(msg, "elems len 2 != elem_nulls len 1")
    var fields = List[ColDescriptor]()
    fields.append(_desc(COL_FIXED, DT_I32, 4, 0))
    msg = String("")
    try:
        rb.write_list_struct_cell(0, 0, fields, elems, three_nulls)
    except e:
        msg = String(e)
    _raises_with(msg, "records len 2 != elem_nulls len 3")
    for row in [-1, 2]:
        var r1 = False
        try:
            _ = rb.read_list_primitive_at[DType.int32](row, 0)
        except:
            r1 = True
        assert_true(r1, "list<prim> row " + String(row))
        var r2 = False
        try:
            _ = rb.read_list_string_at(row, 0)
        except:
            r2 = True
        assert_true(r2, "list<string> row " + String(row))
    rb.write_list_null_cell(1, 0)
    assert_true(rb.is_list_null(1, 0))
    assert_equal(rb.list_len(1, 0), 0)
    var got = rb.read_list_string_at(1, 0)
    assert_equal(len(got[0]), 0)
    assert_equal(len(got[1]), 0)


# -----------------------------------------------------------------------------
# STRUCT record layout
# -----------------------------------------------------------------------------


def _struct_fields() -> List[ColDescriptor]:
    """i32, string, decimal128, binary, u16."""
    var f = List[ColDescriptor]()
    f.append(_desc(COL_FIXED, DT_I32, 4, 0))
    f.append(_desc(COL_VAR_STRING, DT_STRING, 8, 0))
    f.append(_desc(COL_DECIMAL128, DT_DECIMAL128, 16, 0))
    f.append(_desc(COL_VAR_BINARY, DT_BINARY, 8, 0))
    f.append(_desc(COL_FIXED, DT_U16, 2, 0))
    return f^


def _struct_record() -> List[UInt8]:
    """The record of `_struct_fields()` for (-2, "héllo", 16 bytes 0x11..0x20,
    NULL, 0xBEEF), byte by byte."""
    var r: List[UInt8] = [0x00, 0x08]  # present; field 3 NULL
    r.extend([UInt8(0xFE), 0xFF, 0xFF, 0xFF])  # i32 -2
    r.extend([UInt8(6), 0, 0, 0])  # "héllo" is 6 bytes
    r.extend(String("héllo").as_bytes())
    for b in range(16):
        r.append(UInt8(0x11 + b))  # decimal128 slot
    r.extend([UInt8(0), 0, 0, 0])  # NULL binary: length 0
    r.extend([UInt8(0xEF), 0xBE])  # u16 0xBEEF
    return r^


def test_struct_record_free_readers_walk_every_kind() raises:
    """The free readers find each field of the hand-built record, the last
    one past a fixed, a var-string, a decimal and a var-binary slot."""
    var rec = _struct_record()
    var fields = _struct_fields()
    assert_false(struct_record_is_null(rec))
    assert_equal(struct_record_fixed_field[DType.int32](rec, fields, 0), -2)
    assert_equal(
        struct_record_string_field(rec, fields, 1),
        _bytes("héllo"),
    )
    assert_equal(struct_record_fixed_field[DType.uint16](rec, fields, 4), 0xBEEF)
    assert_equal(len(struct_record_string_field(rec, fields, 3)), 0)
    for f in range(5):
        assert_equal(struct_record_field_null(rec, f), f == 3)
    var bad = _struct_fields()
    bad[1] = _desc(COL_LIST, DT_STRING, 8, 0)
    var msg = String("")
    try:
        _ = struct_record_fixed_field[DType.uint16](rec, bad, 4)
    except e:
        msg = String(e)
    _raises_with(msg, "_struct_record_slot_offset: unsupported nested field kind 5")


def test_struct_record_block_readers_walk_every_kind() raises:
    """The same record stored as a STRUCT cell (an 8-byte (offset, length)
    descriptor, written here through the var-string cell writer, which uses
    the same packing): the RowBlock readers agree with the free readers."""
    var rb = RowBlock.with_capacity(1, 0, 8)
    rb.set_n_rows(1)
    rb.write_var_string_cell(0, 0, String("pad").as_bytes())  # record not at 0
    rb.write_var_string_cell(0, 0, _struct_record())
    var fields = _struct_fields()
    assert_equal(rb.read_struct_record_bytes(0, 0), _struct_record())
    assert_false(rb.is_struct_null(0, 0))
    assert_equal(rb.read_struct_fixed_field[DType.int32](0, 0, fields, 0), -2)
    assert_equal(
        rb.read_struct_string_field(0, 0, fields, 1),
        _bytes("héllo"),
    )
    assert_equal(rb.read_struct_fixed_field[DType.uint16](0, 0, fields, 4), 0xBEEF)
    assert_true(rb.is_struct_field_null(0, 0, 3))
    assert_false(rb.is_struct_field_null(0, 0, 4))
    var bad = _struct_fields()
    bad[2] = _desc(COL_LIST, DT_STRING, 8, 0)
    var msg = String("")
    try:
        _ = rb.read_struct_fixed_field[DType.uint16](0, 0, bad, 4)
    except e:
        msg = String(e)
    _raises_with(msg, "_struct_field_slot_offset: unsupported nested field kind 5")
    for row in [-1, 1]:
        var raised = False
        try:
            _ = rb.read_struct_record_bytes(row, 0)
        except:
            raised = True
        assert_true(raised, "row " + String(row))


def test_pack_fixed_field_zero_extends() raises:
    """pack_fixed_field puts the value's own bytes in the low end of the u64
    and zeros above them: a negative i32 or i16 is not sign-extended, and a
    float keeps its bit pattern."""
    var i32s: List[Int32] = [-2, 7]
    var f32s: List[Float32] = [-1.5, 0.5]
    var i16s: List[Int16] = [-2]
    var i64s: List[Int64] = [-2]
    assert_equal(RowBlock.pack_fixed_field[DType.int32](i32s[0]), 0xFFFFFFFE)
    assert_equal(RowBlock.pack_fixed_field[DType.int32](i32s[1]), 7)
    assert_equal(RowBlock.pack_fixed_field[DType.float32](f32s[0]), 0xBFC00000)
    assert_equal(RowBlock.pack_fixed_field[DType.float32](f32s[1]), 0x3F000000)
    assert_equal(RowBlock.pack_fixed_field[DType.int16](i16s[0]), 0xFFFE)
    assert_equal(
        RowBlock.pack_fixed_field[DType.int64](i64s[0]), 0xFFFFFFFFFFFFFFFE
    )


def test_serialize_struct_record_bytes() raises:
    """serialize_struct_record writes the documented bytes: for (i32 -2,
    string "héllo", NULL binary, u16 0xBEEF) the hand-built record minus the
    decimal slot, with the NULL bit on field 2."""
    var fields = List[ColDescriptor]()
    fields.append(_desc(COL_FIXED, DT_I32, 4, 0))
    fields.append(_desc(COL_VAR_STRING, DT_STRING, 8, 0))
    fields.append(_desc(COL_VAR_BINARY, DT_BINARY, 8, 0))
    fields.append(_desc(COL_FIXED, DT_U16, 2, 0))
    var fixed: List[UInt64] = [0xFFFFFFFE, 0xBEEF]
    var vars = List[List[UInt8]]()
    vars.append(_bytes("héllo"))
    vars.append([0x99, 0x98])  # NULL: not written
    var nulls: List[Bool] = [False, False, True, False]
    var got = serialize_struct_record(fields, fixed, vars, nulls)
    var want: List[UInt8] = [0x00, 0x04, 0xFE, 0xFF, 0xFF, 0xFF, 6, 0, 0, 0]
    want.extend(String("héllo").as_bytes())
    want.extend([UInt8(0), 0, 0, 0, 0xEF, 0xBE])
    assert_equal(got, want)
    # A DECIMAL128 field takes a 16-byte slot. Its `fixed_vals` entry is a
    # u64, which holds only the low 8 bytes of a 128-bit value, so only those
    # are asserted; what the writer puts in the upper 8 is not specified.
    var dfields = List[ColDescriptor]()
    dfields.append(_desc(COL_DECIMAL128, DT_DECIMAL128, 16, 0))
    dfields.append(_desc(COL_FIXED, DT_U16, 2, 0))
    var dfixed: List[UInt64] = [0x0102030405060708, 0xBEEF]
    var dnulls: List[Bool] = [False, False]
    var drec = serialize_struct_record(dfields, dfixed, List[List[UInt8]](), dnulls)
    assert_equal(len(drec), 1 + 1 + 16 + 2)
    for b in range(8):
        assert_equal(drec[2 + b], UInt8(8 - b))
    assert_equal(struct_record_fixed_field[DType.uint16](drec, dfields, 1), 0xBEEF)
    var null_rec = serialize_struct_record(fields, fixed, vars, nulls, True)
    assert_equal(null_rec, [UInt8(1)])
    assert_true(struct_record_is_null(null_rec))


def test_serialize_struct_record_nine_fields_and_refusals() raises:
    """Nine u8 fields need two bitmap bytes: a NULL on field 8 is bit 0 of
    the second byte. A field_nulls of another length and a nested field kind
    are refused."""
    var fields = List[ColDescriptor]()
    var fixed = List[UInt64]()
    for i in range(9):
        fields.append(_desc(COL_FIXED, DT_U8, 1, 0))
        fixed.append(UInt64(0x30 + i))
    var nulls = List[Bool](length=9, fill=False)
    nulls[8] = True
    nulls[7] = True
    var got = serialize_struct_record(fields, fixed, List[List[UInt8]](), nulls)
    var want: List[UInt8] = [0x00, 0x80, 0x01]
    for i in range(9):
        want.append(UInt8(0x30 + i))
    assert_equal(got, want)
    assert_true(struct_record_field_null(got, 8))
    assert_true(struct_record_field_null(got, 7))
    assert_false(struct_record_field_null(got, 6))
    var msg = String("")
    var short_nulls: List[Bool] = [False]
    try:
        _ = serialize_struct_record(fields, fixed, List[List[UInt8]](), short_nulls)
    except e:
        msg = String(e)
    _raises_with(msg, "fields len 9 != field_nulls len 1")
    var nested = List[ColDescriptor]()
    nested.append(_desc(COL_LIST, DT_STRING, 8, 0))
    var one: List[Bool] = [False]
    msg = String("")
    try:
        _ = serialize_struct_record(nested, fixed, List[List[UInt8]](), one)
    except e:
        msg = String(e)
    _raises_with(msg, "unsupported nested field kind 5 (depth-1 flat only")


# -----------------------------------------------------------------------------
# Var-width key hash
# -----------------------------------------------------------------------------


def _key_block(
    pad: Int, a: Int64, s: List[UInt8], b: Int64
) raises -> RowBlock:
    """One row of a 24-byte key: i64 `a` @0, var key cell @8, i64 `b` @16.
    `pad` junk payload bytes go into the heap first, so the cell's
    descriptor offset differs with `pad`."""
    var rb = RowBlock.with_capacity(1, 0, 24)
    rb.set_n_rows(1)
    if pad > 0:
        rb.write_var_string_cell(0, 8, List[UInt8](length=pad, fill=0xEE))
    rb.write_fixed[DType.int64](0, 0, a)
    rb.write_var_string_key_cell(0, 8, s)
    rb.write_fixed[DType.int64](0, 16, b)
    rb.var_key_offsets = [8]
    return rb^


def test_var_key_hash_follows_payload_not_descriptor() raises:
    """Same key at heap offsets 0 and 37: equal hash, different descriptor.
    A change in the i64 before the cell, the i64 after it, or the payload
    changes the hash."""
    var abc: List[UInt8] = [0x61, 0x62, 0x63]
    var x = _key_block(0, 1, abc, 2)
    var y = _key_block(37, 1, abc, 2)
    assert_true(x.read_fixed[DType.uint64](0, 8) != y.read_fixed[DType.uint64](0, 8))
    var hx = _hash_row_bytes(x, 0, 24)
    assert_equal(hx, _hash_row_bytes(y, 0, 24))
    assert_true(hx != _hash_row_bytes(_key_block(0, 9, abc, 2), 0, 24))
    assert_true(hx != _hash_row_bytes(_key_block(0, 1, abc, 9), 0, 24))
    var abd: List[UInt8] = [0x61, 0x62, 0x64]
    assert_true(hx != _hash_row_bytes(_key_block(0, 1, abd, 2), 0, 24))


def test_var_key_hash_cell_alone_and_two_cells() raises:
    """A key that is only a var cell (offset 0, stride 8), and a key of two
    var cells (offsets 0 and 8): offset-independent, and the two payloads
    are not interchangeable."""
    var ab: List[UInt8] = [0x61, 0x62]
    var c: List[UInt8] = [0x63]
    var hs = List[UInt64]()
    for pad in [0, 11]:
        var rb = RowBlock.with_capacity(1, 0, 16)
        rb.set_n_rows(1)
        if pad > 0:
            rb.write_var_string_cell(0, 0, List[UInt8](length=pad, fill=0xEE))
        rb.write_var_string_key_cell(0, 0, ab)
        rb.write_var_string_key_cell(0, 8, c)
        rb.var_key_offsets = [0]
        hs.append(_hash_row_bytes(rb, 0, 8))
        rb.var_key_offsets = [0, 8]
        hs.append(_hash_row_bytes(rb, 0, 16))
    assert_equal(hs[0], hs[2])
    assert_equal(hs[1], hs[3])
    var sw = RowBlock.with_capacity(1, 0, 16)
    sw.set_n_rows(1)
    sw.write_var_string_key_cell(0, 0, c)
    sw.write_var_string_key_cell(0, 8, ab)
    sw.var_key_offsets = [0, 8]
    assert_true(hs[1] != _hash_row_bytes(sw, 0, 16))


def test_var_key_hash_long_payload_chunks() raises:
    """A 300-byte key payload (the cell's payload is 301 bytes with its tag)
    spans two 240-byte chunks: equal payloads at two offsets hash alike; a
    change in either fixed i64, at byte 3 (first chunk) or at byte 299
    (second chunk) changes the hash; 239 and 240 key bytes (240 and 241 payload bytes) differ too."""
    var base = List[UInt8]()
    for i in range(300):
        base.append(UInt8(i & 0xFF))
    var h0 = _hash_row_bytes(_key_block(0, 1, base, 2), 0, 24)
    assert_equal(h0, _hash_row_bytes(_key_block(5, 1, base, 2), 0, 24))
    # The fixed bytes still count when the payload is chunked: every chunk
    # is chained from the seed the fixed bytes produced.
    assert_true(h0 != _hash_row_bytes(_key_block(0, 9, base, 2), 0, 24))
    assert_true(h0 != _hash_row_bytes(_key_block(0, 1, base, 9), 0, 24))
    var early = base.copy()
    early[3] = 0xFF
    assert_true(h0 != _hash_row_bytes(_key_block(0, 1, early, 2), 0, 24))
    var late = base.copy()
    late[299] = 0x00
    assert_true(h0 != _hash_row_bytes(_key_block(0, 1, late, 2), 0, 24))
    var k239 = List[UInt8](length=239, fill=0x41)
    var k240 = List[UInt8](length=240, fill=0x41)
    var h239 = _hash_row_bytes(_key_block(0, 1, k239, 2), 0, 24)
    var h240 = _hash_row_bytes(_key_block(0, 1, k240, 2), 0, 24)
    assert_true(h239 != h240)
    assert_equal(h240, _hash_row_bytes(_key_block(3, 1, k240, 2), 0, 24))


def main() raises:
    var s = TestSuite()
    s.test[test_layout_var_width_flag_per_kind]()
    s.test[test_layout_validity_bytes_around_eight]()
    s.test[test_with_capacity_var_budget]()
    s.test[test_bool_batch_every_lane_both_values]()
    s.test[test_decimal_batch_bytes_and_refusal]()
    s.test[test_key_cell_refusals_and_ranges]()
    s.test[test_nested_cells_refuse_mismatch_and_range]()
    s.test[test_struct_record_free_readers_walk_every_kind]()
    s.test[test_struct_record_block_readers_walk_every_kind]()
    s.test[test_pack_fixed_field_zero_extends]()
    s.test[test_serialize_struct_record_bytes]()
    s.test[test_serialize_struct_record_nine_fields_and_refusals]()
    s.test[test_var_key_hash_follows_payload_not_descriptor]()
    s.test[test_var_key_hash_cell_alone_and_two_cells]()
    s.test[test_var_key_hash_long_payload_chunks]()
    s^.run()
