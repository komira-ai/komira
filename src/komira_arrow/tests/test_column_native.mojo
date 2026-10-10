# =============================================================================
# test_column_native.mojo -- ColumnNativeBatch, its builder, descriptors,
# appendix and the typed UnifiedColumnFormat view (column_native.mojo).
# =============================================================================
#
# The contiguous-body fixtures lay out the Arrow Columnar format's own worked
# examples (https://arrow.apache.org/docs/format/Columnar.html) byte for byte:
#
#   Int32 [1, null, 2, 4, 8]            validity 0b00011101, values
#                                       [1, 0, 2, 4, 8] ("Fixed-size Primitive
#                                       Layout", the null slot zeroed)
#   List<Int8> [[12, -7, 25], null,      validity 0b00001101, offsets
#     [0, -127, 127, 50], []]           [0, 3, 3, 7, 7], values
#                                       [12, -7, 25, 0, -127, 127, 50]
#                                       ("Variable-size List Layout")
#   Struct<Int32, Int64>                 validity 0b00001011, the "age"
#     [{1, 10}, {2, 20}, null, {4, 40}]  child [1, 2, 0, 4] ("Struct Layout",
#                                       its Int32 field; the Int64 field is
#                                       ours, to tell fields apart)
#
# Validity is LSB-first, one bit per slot, 1 = valid; offsets are Int32 with
# n + 1 entries; a list cell i is the child slice [offsets[i], offsets[i+1]).
# Each test states the defect it would catch.
# =============================================================================

from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.batch_format import FormatKind
from komira_arrow.column import Column
from komira_arrow.column_native import (
    ColumnAppendix,
    ColumnDescriptor,
    ColumnNativeBatch,
    ColumnNativeBatchBuilder,
    ColumnNativeBatchHeader,
)
from komira_arrow.column_native_nested import (
    ListColumnFormat,
    StructColumnFormat,
)
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab


comptime FINGERPRINT = UInt64(0xDEADBEEF12345678)

# Byte offsets inside the primitive body (0..95 stand for the header region;
# an offset of 0 means "no buffer", so every buffer sits past it).
comptime P_VALIDITY = 96
comptime P_DATA = 104
comptime P_BODY_LEN = 124

# Byte offsets inside the nested body.
comptime N_LIST_VALIDITY = 96
comptime N_LIST_OFFSETS = 100
comptime N_LIST_VALUES = 120
comptime N_STRUCT_VALIDITY = 128
comptime N_STRUCT_F0 = 132
comptime N_STRUCT_F1 = 152
comptime N_BODY_LEN = 184


# =============================================================================
# Fixtures
# =============================================================================


def _addr(v: ByteView[_]) -> Int:
    """The address of a view's first byte, to prove two views share storage."""
    # SAFETY: the pointer is turned into an integer for comparison only and
    # never dereferenced; `v` outlives this call.
    return Int(v._unsafe_ptr())


def _header(n_cols: Int, rows: Int) -> ColumnNativeBatchHeader:
    return ColumnNativeBatchHeader(
        n_cols=UInt32(n_cols),
        row_count=UInt64(rows),
        schema_fingerprint=FINGERPRINT,
        has_selection_vector=0,
        flags=0,
    )


def _desc(
    arrow_type: ArrowType,
    data_off: Int,
    data_len: Int,
    offsets_off: Int,
    validity_off: Int,
    null_count: Int,
) -> ColumnDescriptor:
    return ColumnDescriptor(
        arrow_type=UInt16(Int(arrow_type.type_id)),
        data_off=UInt32(data_off),
        data_len=UInt32(data_len),
        offsets_off=UInt32(offsets_off),
        validity_off=UInt32(validity_off),
        null_count=UInt32(null_count),
    )


def _sab(n: Int) -> SharedAlignedBuffer[HeapRegion]:
    var b = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    b.zero()
    return b^


def _sel(indices: List[Int]) -> SharedAlignedBuffer[HeapRegion]:
    """An Int32-LE selection vector."""
    var b = _sab(len(indices) * 4)
    for i in range(len(indices)):
        b.write_i32_le_at(i * 4, Int32(indices[i]))
    return b^


def _schema1(name: String, t: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, t, True))
    return sb.build()


def _primitive_body() -> SharedAlignedBuffer[HeapRegion]:
    """Int32 [1, null, 2, 4, 8] at P_VALIDITY / P_DATA."""
    var b = _sab(P_BODY_LEN)
    b.write_u8_at(P_VALIDITY, UInt8(0b00011101))
    var vals: List[Int32] = [1, 0, 2, 4, 8]
    for i in range(5):
        b.write_i32_le_at(P_DATA + i * 4, vals[i])
    return b^


def _primitive_batch() -> ColumnNativeBatch:
    """Contiguous-body batch, one Int32 column, 5 rows, built with the
    six-argument constructor (no child descriptors)."""
    var d = Slab[ColumnDescriptor]()
    d.append(_desc(ArrowType.INT32, P_DATA, 20, 0, P_VALIDITY, 1))
    return ColumnNativeBatch(
        _header(1, 5),
        d^,
        _primitive_body(),
        None,
        None,
        _schema1("x", ArrowType.INT32),
    )


def _nested_body() -> SharedAlignedBuffer[HeapRegion]:
    var b = _sab(N_BODY_LEN)
    # List<Int8> [[12, -7, 25], null, [0, -127, 127, 50], []]
    b.write_u8_at(N_LIST_VALIDITY, UInt8(0b00001101))
    var offs: List[Int32] = [0, 3, 3, 7, 7]
    for i in range(5):
        b.write_i32_le_at(N_LIST_OFFSETS + i * 4, offs[i])
    var vals: List[Int] = [12, -7, 25, 0, -127, 127, 50]
    for i in range(7):
        b.write_u8_at(N_LIST_VALUES + i, UInt8(Int8(vals[i])))
    # Struct<Int32, Int64> [{1, 10}, {2, 20}, null, {4, 40}]
    b.write_u8_at(N_STRUCT_VALIDITY, UInt8(0b00001011))
    var f0: List[Int32] = [1, 2, 0, 4]
    var f1: List[Int64] = [10, 20, 0, 40]
    for i in range(4):
        b.write_i32_le_at(N_STRUCT_F0 + i * 4, f0[i])
        b.write_i64_le_at(N_STRUCT_F1 + i * 8, f1[i])
    return b^


def _nested_batch() -> ColumnNativeBatch:
    """Contiguous-body batch: column 0 List<Int8>, column 1 Struct<Int32,
    Int64>, 4 rows, built with the seven-argument constructor. Child
    descriptor 0 is the list's values; 1 and 2 are the struct's fields. The
    struct parent's `data_off` is its child base (1), `data_len` its field
    count (2)."""
    var d = Slab[ColumnDescriptor]()
    d.append(_desc(ArrowType.LIST, 0, 0, N_LIST_OFFSETS, N_LIST_VALIDITY, 1))
    d.append(_desc(ArrowType.STRUCT, 1, 2, 0, N_STRUCT_VALIDITY, 1))
    var c = Slab[ColumnDescriptor]()
    c.append(_desc(ArrowType.INT8, N_LIST_VALUES, 7, 0, 0, 0))
    c.append(_desc(ArrowType.INT32, N_STRUCT_F0, 16, 0, 0, 0))
    c.append(_desc(ArrowType.INT64, N_STRUCT_F1, 32, 0, 0, 0))
    var sb = SchemaBuilder()
    sb.add_field(Field("l", ArrowType.LIST, True))
    sb.add_field(Field("s", ArrowType.STRUCT, True))
    return ColumnNativeBatch(
        _header(2, 4), d^, c^, _nested_body(), None, None, sb.build()
    )


def _wrapped_columns() raises -> Slab[Column[HeapRegion]]:
    """Three columns of 3 rows, each built from its Arrow buffers: Int64 with
    an element offset of 2 into [10, 11, 12, 13, 14, 15] (rows 12, 13, 14);
    Utf8 ["a", "bc", ""] (offsets [0, 1, 3, 3], data "abc"); and Int32
    [7, null, 9] with validity 0b00000101."""
    var cols = Slab[Column[HeapRegion]]()
    var i64 = _sab(48)
    for i in range(6):
        i64.write_i64_le_at(i * 8, Int64(10 + i))
    cols.append(Column[HeapRegion](ArrowType.INT64, i64^, None, None, 3, 0, 2))
    var offs = _sab(16)
    offs.write_i32_le_at(4, 1)
    offs.write_i32_le_at(8, 3)
    offs.write_i32_le_at(12, 3)
    var chars = _sab(3)
    chars.write_u8_at(0, UInt8(ord("a")))
    chars.write_u8_at(1, UInt8(ord("b")))
    chars.write_u8_at(2, UInt8(ord("c")))
    cols.append(
        Column[HeapRegion](
            ArrowType.STRING, chars^, Optional(offs^), None, 3, 0, 0
        )
    )
    var i32 = _sab(12)
    i32.write_i32_le_at(0, 7)
    i32.write_i32_le_at(8, 9)
    var bm = Bitmap.create_all_valid(3)
    bm.clear(1)
    cols.append(
        Column[HeapRegion](ArrowType.INT32, i32^, None, Optional(bm^), 3, 1, 0)
    )
    return cols^


def _wrapped_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.STRING, False))
    sb.add_field(Field("c", ArrowType.INT32, True))
    return sb.build()


def _wrapped_batch() raises -> ColumnNativeBatch:
    return ColumnNativeBatch.wrap_columns(
        _header(3, 3), _wrapped_columns(), _wrapped_schema()
    )


# Generic drivers: the trait surface, reached through the refinement traits
# rather than the concrete type, as a per-format driver would.


def _list_cell_sum[F: ListColumnFormat](b: F, col: Int, row: Int) -> Int:
    var s = 0
    for p in range(b.cell_offset_begin(col, row), b.cell_offset_end(col, row)):
        s += Int(b.child_at[DType.int8](col, p))
    return s


def _struct_row_sum[F: StructColumnFormat](b: F, col: Int, row: Int) -> Int:
    _ = b.struct_field_count(col)
    return Int(b.struct_child_at[DType.int32](col, 0, row)) + Int(
        b.struct_child_at[DType.int64](col, 1, row)
    )


def _is_column_format[F: ListColumnFormat](b: F) -> Bool:
    return (
        F.format_kind() == FormatKind.COLUMN
        and F.supports_zero_copy_export_to_arrow()
        and b.schema_fingerprint() == FINGERPRINT
    )


# =============================================================================
# ColumnDescriptor and ColumnAppendix
# =============================================================================


def test_descriptor_presence_bits_and_type() raises:
    """Offset 0 means absent, any other offset present; the UInt16 tag
    round-trips to its ArrowType. Catches an inverted or `> 1` presence test
    and a tag truncated or read from the wrong field."""
    var none = _desc(ArrowType.INT32, 8, 4, 0, 0, 0)
    assert_false(none.has_offsets())
    assert_false(none.has_validity())
    var both = _desc(ArrowType.STRING, 8, 4, 1, 1, 0)
    assert_true(both.has_offsets())
    assert_true(both.has_validity())
    var only_v = _desc(ArrowType.INT64, 0, 0, 0, 200, 0)
    assert_false(only_v.has_offsets())
    assert_true(only_v.has_validity())
    assert_true(none.arrow_type_enum() == ArrowType.INT32)
    assert_true(both.arrow_type_enum() == ArrowType.STRING)
    assert_true(
        _desc(ArrowType.UTF8_VIEW, 0, 0, 0, 0, 0).arrow_type_enum()
        == ArrowType.UTF8_VIEW
    )


def test_appendix_len_and_view() raises:
    """The appendix exposes exactly its bytes, without a copy. Catches a
    length off by one and a view over other storage."""
    var b = _sab(3)
    b.write_u8_at(0, 1)
    b.write_u8_at(1, 2)
    b.write_u8_at(2, 255)
    var keep = b.share()
    var app = ColumnAppendix(b^)
    assert_equal(app.len(), 3)
    var v = app.view()
    assert_equal(v.len(), 3)
    assert_equal(v.read_u8_at(0), 1)
    assert_equal(v.read_u8_at(1), 2)
    assert_equal(v.read_u8_at(2), 255)
    assert_equal(_addr(v), _addr(keep.as_view()))


# =============================================================================
# Contiguous-body mode: the Arrow primitive layout
# =============================================================================


def test_contiguous_primitive_layout() raises:
    """Spec Int32 example: every value at its slot, the bitmap read LSB-first,
    the batch-level accessors. Catches a wrong element stride, a value region
    taken from the wrong descriptor field, a validity bit read MSB-first or
    with an inverted sense, and a row count taken from n_cols."""
    var b = _primitive_batch()
    assert_false(b.is_wrapped())
    assert_false(b.has_selection())
    assert_equal(b.num_rows(), 5)
    assert_equal(b.physical_row_count(), 5)
    assert_equal(b.num_columns(), 1)
    assert_equal(b.schema_fingerprint(), FINGERPRINT)
    assert_true(ColumnNativeBatch.format_kind() == FormatKind.COLUMN)
    assert_true(ColumnNativeBatch.supports_zero_copy_export_to_arrow())
    var u = b.column_unified[DType.int32](0)
    assert_true(u.is_dense())
    assert_equal(u.len(), 5)
    var want: List[Int32] = [1, 0, 2, 4, 8]
    var valid: List[Bool] = [True, False, True, True, True]
    for i in range(5):
        assert_equal(u.get(i), want[i])
        assert_equal(u.get_dense(i), want[i])
        assert_equal(b.cell_is_valid(0, i), valid[i])
    var d = b.descriptor_at(0)
    assert_equal(Int(d.data_off), P_DATA)
    assert_equal(Int(d.data_len), 20)
    assert_equal(Int(d.validity_off), P_VALIDITY)
    assert_equal(Int(d.null_count), 1)
    assert_true(d.arrow_type_enum() == ArrowType.INT32)


def test_validity_bitmap_crosses_a_byte() raises:
    """Twelve slots, bitmap bytes [0b10100101, 0b00001001]: slot i is bit
    (i % 8) of byte (i / 8). Catches a byte index that ignores `i >> 3` (slots
    8..11 would read byte 0) and a bit index that ignores `& 7`."""
    var body = _sab(112)
    body.write_u8_at(100, UInt8(0b10100101))
    body.write_u8_at(101, UInt8(0b00001001))
    var d = Slab[ColumnDescriptor]()
    d.append(_desc(ArrowType.INT8, 104, 8, 0, 100, 6))
    # Column 1 has no bitmap: every slot is valid, even where column 0's
    # bitmap reads 0 (the bitmap must not be read at offset 0).
    d.append(_desc(ArrowType.INT8, 104, 8, 0, 0, 0))
    var b = ColumnNativeBatch(
        _header(2, 12), d^, body^, None, None, _schema1("v", ArrowType.INT8)
    )
    var want: List[Bool] = [
        True, False, True, False, False, True, False, True,
        True, False, False, True,
    ]
    for i in range(12):
        assert_equal(b.cell_is_valid(0, i), want[i])
        assert_true(b.cell_is_valid(1, i))


def test_body_view_and_take_body_share_storage() raises:
    """body_view and take_body hand out the body itself, not a copy, of its
    full length. Catches a copied or truncated body."""
    var body = _primitive_body()
    var keep = body.share()
    var d = Slab[ColumnDescriptor]()
    d.append(_desc(ArrowType.INT32, P_DATA, 20, 0, P_VALIDITY, 1))
    var b = ColumnNativeBatch(
        _header(1, 5), d^, body^, None, None, _schema1("x", ArrowType.INT32)
    )
    var v = b.body_view()
    assert_equal(v.len(), P_BODY_LEN)
    assert_equal(_addr(v), _addr(keep.as_view()))
    assert_equal(v.read_u8_at(P_VALIDITY), UInt8(0b00011101))
    var out = b^.take_body()
    assert_equal(out.len(), P_BODY_LEN)
    assert_equal(_addr(out.as_view()), _addr(keep.as_view()))
    assert_equal(out.read_i32_le_at(P_DATA + 16), 8)


def test_schema_ref_and_copy() raises:
    """The batch carries the schema it was given. Catches a dropped or
    default schema on either accessor."""
    var b = _nested_batch()
    assert_equal(b.schema_ref().num_columns(), 2)
    assert_equal(b.schema_ref().field_name(1), "s")
    var s = b.schema_copy()
    assert_equal(s.num_columns(), 2)
    assert_equal(s.field_name(0), "l")
    assert_true(s.field_arrow_type(1) == ArrowType.STRUCT)


# =============================================================================
# Selection vectors
# =============================================================================


def test_contiguous_selection_maps_logical_rows() raises:
    """with_selection keeps the body and maps logical row i to selection[i]:
    num_rows is the selection length, physical_row_count the body's, get()
    goes through the selection and get_dense() does not. Catches a selection
    ignored by get(), applied by get_dense(), a length in bytes rather than
    Int32 entries, and the header flag left unset."""
    var b = _primitive_batch().with_selection(_sel([4, 0, 2]))
    assert_true(b.has_selection())
    assert_equal(Int(b._header.has_selection_vector), 1)
    assert_equal(b.num_rows(), 3)
    assert_equal(b.physical_row_count(), 5)
    var u = b.column_unified[DType.int32](0)
    assert_false(u.is_dense())
    assert_equal(u.len(), 3)
    assert_equal(u.get(0), 8)
    assert_equal(u.get(1), 1)
    assert_equal(u.get(2), 2)
    assert_equal(u.get_dense(0), 1)
    assert_equal(u.get_dense(2), 2)
    var idx = b.selection_indices()
    assert_equal(len(idx), 3)
    assert_equal(idx[0], 4)
    assert_equal(idx[1], 0)
    assert_equal(idx[2], 2)


def test_selection_indices_empty_when_dense() raises:
    """A dense batch has no selection indices. Catches a dense batch
    reporting rows as selected."""
    var b = _primitive_batch()
    assert_equal(len(b.selection_indices()), 0)


def test_materialize_dense_identity_and_refusal() raises:
    """A dense batch materializes to itself (same body, same rows); a
    selection-bearing one is refused, since its gather lives in the engine.
    Catches a dense batch refused, and a selection silently dropped."""
    var body = _primitive_body()
    var keep = body.share()
    var d = Slab[ColumnDescriptor]()
    d.append(_desc(ArrowType.INT32, P_DATA, 20, 0, P_VALIDITY, 1))
    var b = ColumnNativeBatch(
        _header(1, 5), d^, body^, None, None, _schema1("x", ArrowType.INT32)
    )
    var m = b^.materialize_dense()
    assert_equal(m.num_rows(), 5)
    assert_equal(_addr(m.body_view()), _addr(keep.as_view()))
    var s = _primitive_batch().with_selection(_sel([1]))
    with assert_raises(contains="selection-bearing batch"):
        _ = s^.materialize_dense()


# =============================================================================
# Nested: the Arrow list and struct layouts
# =============================================================================


def test_list_cells_follow_offsets() raises:
    """Spec List<Int8> example: cell i is the child slice [offsets[i],
    offsets[i+1]); the null cell and the empty cell are both zero-length;
    validity is the parent's. Catches begin and end read from the same
    entry, a 2-byte or 8-byte offset stride, a child located through the
    wrong descriptor, and child values read at the wrong width."""
    var b = _nested_batch()
    var begins: List[Int] = [0, 3, 3, 7]
    var ends: List[Int] = [3, 3, 7, 7]
    var valid: List[Bool] = [True, False, True, True]
    for i in range(4):
        assert_equal(b.cell_offset_begin(0, i), begins[i])
        assert_equal(b.cell_offset_end(0, i), ends[i])
        assert_equal(b.cell_is_valid(0, i), valid[i])
    var vals: List[Int] = [12, -7, 25, 0, -127, 127, 50]
    for p in range(7):
        assert_equal(Int(b.child_at[DType.int8](0, p)), vals[p])
    assert_equal(_list_cell_sum(b, 0, 0), 30)
    assert_equal(_list_cell_sum(b, 0, 1), 0)
    assert_equal(_list_cell_sum(b, 0, 2), 50)
    assert_equal(_list_cell_sum(b, 0, 3), 0)
    assert_true(_is_column_format(b))


def test_struct_fields_by_child_base() raises:
    """Spec Struct example: field f of the struct at column c is child
    descriptor (parent.data_off + f); the field count is parent.data_len;
    validity is the parent's. Catches a field index not added to the child
    base, fields swapped, and the count read from another field."""
    var b = _nested_batch()
    assert_equal(b.struct_field_count(1), 2)
    var f0: List[Int32] = [1, 2, 0, 4]
    var f1: List[Int64] = [10, 20, 0, 40]
    var valid: List[Bool] = [True, True, False, True]
    for i in range(4):
        assert_equal(b.struct_child_at[DType.int32](1, 0, i), f0[i])
        assert_equal(b.struct_child_at[DType.int64](1, 1, i), f1[i])
        assert_equal(b.cell_is_valid(1, i), valid[i])
    assert_equal(_struct_row_sum(b, 1, 3), 44)
    assert_true(b.descriptor_at(1).arrow_type_enum() == ArrowType.STRUCT)


# =============================================================================
# Wrapped (per-column, zero-copy) mode
# =============================================================================


def test_wrapped_descriptors_are_synthesized() raises:
    """A wrapped batch synthesizes each descriptor from its column: the type
    tag, presence sentinels of 1 for an offsets buffer and a bitmap, 0 byte
    offsets, and the column's null count. Catches either presence bit
    inverted or taken from the other buffer, and a null count dropped."""
    var b = _wrapped_batch()
    assert_true(b.is_wrapped())
    assert_equal(b.num_columns(), 3)
    assert_equal(b.num_rows(), 3)
    var d0 = b.descriptor_at(0)
    assert_true(d0.arrow_type_enum() == ArrowType.INT64)
    assert_false(d0.has_offsets())
    assert_false(d0.has_validity())
    assert_equal(Int(d0.data_off), 0)
    assert_equal(Int(d0.data_len), 0)
    assert_equal(Int(d0.null_count), 0)
    var d1 = b.descriptor_at(1)
    assert_true(d1.arrow_type_enum() == ArrowType.STRING)
    assert_equal(Int(d1.offsets_off), 1)
    assert_false(d1.has_validity())
    var d2 = b.descriptor_at(2)
    assert_true(d2.arrow_type_enum() == ArrowType.INT32)
    assert_false(d2.has_offsets())
    assert_equal(Int(d2.validity_off), 1)
    assert_equal(Int(d2.null_count), 1)


def test_wrapped_unified_honours_column_offset() raises:
    """column_unified on a wrapped batch reads the column's own buffer,
    starting at its element offset (a slice of [10..15] at 2 reads 12, 13,
    14), without a copy. Catches the offset ignored, applied in elements
    rather than bytes, and a copied buffer."""
    var b = _wrapped_batch()
    var u = b.column_unified[DType.int64](0)
    assert_true(u.is_dense())
    assert_equal(u.len(), 3)
    assert_equal(u.get(0), 12)
    assert_equal(u.get(1), 13)
    assert_equal(u.get(2), 14)
    assert_equal(u.get_dense(2), 14)
    var u2 = b.column_unified[DType.int32](2)
    assert_equal(u2.get(0), 7)
    assert_equal(u2.get(2), 9)


def test_wrapped_selection() raises:
    """A selection on a wrapped batch maps rows the same way as on a body.
    Catches the wrapped path ignoring the selection or its length."""
    var b = _wrapped_batch().with_selection(_sel([2, 0]))
    assert_true(b.is_wrapped())
    assert_equal(b.num_rows(), 2)
    assert_equal(b.physical_row_count(), 3)
    var u = b.column_unified[DType.int64](0)
    assert_false(u.is_dense())
    assert_equal(u.len(), 2)
    assert_equal(u.get(0), 14)
    assert_equal(u.get(1), 12)


def test_take_columns_wrapped_is_zero_copy() raises:
    """take_columns_wrapped returns the very columns wrapped, buffers
    shared, in order. Catches a copy, a reordering and a dropped column."""
    var cols = _wrapped_columns()
    var a0 = _addr(cols[0].values_view_native())
    var a2 = _addr(cols[2].values_view_native())
    var b = ColumnNativeBatch.wrap_columns(
        _header(3, 3), cols^, _wrapped_schema()
    )
    var u = b.column_unified[DType.int64](0)
    assert_equal(_addr(u._data), a0 + 2 * 8)
    _ = u^
    var out = b^.take_columns_wrapped()
    assert_equal(len(out), 3)
    assert_equal(_addr(out[0].values_view_native()), a0)
    assert_equal(_addr(out[2].values_view_native()), a2)
    assert_equal(out[0].offset(), 2)
    assert_true(out[1].arrow_type == ArrowType.STRING)


# =============================================================================
# ColumnNativeBatchBuilder
# =============================================================================


def test_builder_assembles_batch() raises:
    """The builder's batch holds its descriptors in order, its selection
    (header flag set), its appendix, the body and schema given to build; a
    second build starts from empty descriptors and no selection. Catches a
    descriptor dropped or reordered, the selection or appendix lost, the flag
    unset, and state carried from one build into the next."""
    var bld = ColumnNativeBatchBuilder.create(_header(2, 5))
    bld.add_descriptor(_desc(ArrowType.INT32, P_DATA, 20, 0, P_VALIDITY, 1))
    bld.add_descriptor(_desc(ArrowType.INT8, P_DATA, 5, 0, 0, 0))
    bld.set_selection(_sel([3, 1]))
    var app = _sab(2)
    app.write_u8_at(1, 42)
    bld.set_appendix(ColumnAppendix(app^))
    var b = bld.build(_primitive_body(), _schema1("x", ArrowType.INT32))
    assert_equal(b.num_columns(), 2)
    assert_equal(Int(b.descriptor_at(0).data_len), 20)
    assert_equal(Int(b.descriptor_at(1).data_len), 5)
    assert_true(b.descriptor_at(1).arrow_type_enum() == ArrowType.INT8)
    assert_true(b.has_selection())
    assert_equal(Int(b._header.has_selection_vector), 1)
    assert_equal(b.num_rows(), 2)
    assert_equal(b.column_unified[DType.int32](0).get(0), 4)
    assert_equal(b.column_unified[DType.int32](0).get(1), 0)
    assert_true(Bool(b._appendix))
    assert_equal(b._appendix.value().view().read_u8_at(1), 42)
    assert_equal(b.body_view().len(), P_BODY_LEN)
    assert_equal(b.schema_ref().field_name(0), "x")
    var again = bld.build(_sab(8), _schema1("y", ArrowType.INT8))
    assert_equal(len(again._descriptors), 0)
    assert_false(again.has_selection())
    assert_false(Bool(again._appendix))


def test_builder_without_selection_or_appendix() raises:
    """A builder given neither leaves both absent and the batch dense.
    Catches a default selection or appendix appearing from nowhere."""
    var bld = ColumnNativeBatchBuilder.create(_header(1, 5))
    bld.add_descriptor(_desc(ArrowType.INT32, P_DATA, 20, 0, P_VALIDITY, 1))
    var b = bld.build(_primitive_body(), _schema1("x", ArrowType.INT32))
    assert_false(b.has_selection())
    assert_equal(Int(b._header.has_selection_vector), 0)
    assert_false(Bool(b._appendix))
    assert_equal(b.num_rows(), 5)
    assert_equal(b.column_unified[DType.int32](0).get(4), 8)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
