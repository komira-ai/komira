# =============================================================================
# test_column_native_foundation.mojo: ColumnNativeBatch and its bridges.
# =============================================================================
#
#   (a) round-trip ColumnNativeBatch <-> RecordBatch through the shims is
#       byte-identical (numeric int64 + string columns).
#   (b) UnifiedColumnFormat[T] typed reads are correct (numeric int64 + the
#       string-column descriptor surface).
#   (c) the ListColumnFormat / StructColumnFormat refinement traits compile +
#       a List<Int64> and a Struct{Int64,Float64} cell-access case on a
#       hand-built nested body.
#   (d) ColumnNativeBatch conforms BatchFormat — the comptime-if format_kind
#       gate compiles and selects the COLUMN arm (NO where-clause).
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.batch_format import BatchFormat, FormatKind
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.column_native import (
    ColumnDescriptor,
    ColumnNativeBatch,
    ColumnNativeBatchHeader,
    UnifiedColumnFormat,
)
from komira_arrow.column_native_nested import (
    ListColumnFormat,
    StructColumnFormat,
)
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow_ipc.record_batch_compare import record_batch_byte_equal
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Helpers
# =============================================================================


def _i64_list(*vals: Int) -> List[Scalar[DType.int64]]:
    var out = List[Scalar[DType.int64]]()
    for v in vals:
        out.append(Int64(v))
    return out^


def _int64_schema(name0: String, name1: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.INT64, False))
    sb.add_field(Field(name1, ArrowType.INT64, False))
    return sb.build()


def _string_schema(name0: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.STRING, False))
    return sb.build()


def _build_int64_batch() raises -> RecordBatch:
    var c0 = _i64_list(1, 2, 3, 4, 5, 6, 7, 8)
    var c1 = _i64_list(-100, 0, 100, 200, 300, 400, 500, 600)
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(c0)
        )
    )
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(c1)
        )
    )
    return RecordBatch.from_typed_columns_slab(_int64_schema("a", "b"), cols^)


def _build_string_batch() raises -> RecordBatch:
    var s0 = List[String]()
    s0.append("alpha")
    s0.append("")
    s0.append("gamma")
    s0.append("delta")
    var cols = Slab[Column[HeapRegion]].create(1)
    cols.append(Column.from_string(StringArray.from_strings(s0)))
    return RecordBatch.from_typed_columns_slab(_string_schema("s"), cols^)


# =============================================================================
# (a) round-trip byte-identity: int64
# =============================================================================


def test_roundtrip_int64_byte_identical() raises:
    # Build A; encode to ColumnNativeBatch; decode back to B; compare A2 vs B.
    var a_native = column_native_from_record_batch(_build_int64_batch())
    assert_equal(a_native.num_rows(), 8)
    assert_equal(a_native.num_columns(), 2)
    assert_true(a_native.format_kind() == FormatKind.COLUMN)

    var restored = record_batch_from_column_native(a_native^)
    var golden = _build_int64_batch()
    assert_true(
        record_batch_byte_equal(golden, restored),
        "int64 ColumnNativeBatch round-trip must be byte-identical",
    )


# =============================================================================
# (a') round-trip byte-identity: string (varlen)
# =============================================================================


def test_roundtrip_string_byte_identical() raises:
    var a_native = column_native_from_record_batch(_build_string_batch())
    assert_equal(a_native.num_rows(), 4)
    assert_equal(a_native.num_columns(), 1)

    var restored = record_batch_from_column_native(a_native^)
    var golden = _build_string_batch()
    assert_true(
        record_batch_byte_equal(golden, restored),
        "string ColumnNativeBatch round-trip must be byte-identical",
    )


# =============================================================================
# (b) UnifiedColumnFormat[T] typed reads
# =============================================================================


def test_unified_column_format_numeric() raises:
    var native = column_native_from_record_batch(_build_int64_batch())
    var view0 = native.column_unified[DType.int64](0)
    var view1 = native.column_unified[DType.int64](1)

    assert_equal(view0.len(), 8)
    assert_true(view0.is_dense(), "no selection => dense view")

    var expected0 = _i64_list(1, 2, 3, 4, 5, 6, 7, 8)
    var expected1 = _i64_list(-100, 0, 100, 200, 300, 400, 500, 600)
    for i in range(8):
        assert_equal(view0.get(i), expected0[i])
        assert_equal(view1.get(i), expected1[i])


def test_unified_column_descriptor_string() raises:
    # The string column's descriptor must carry a valid (non-zero) offsets
    # region and a data region — the varlen layout surfaced through the
    # foundation descriptor.
    var native = column_native_from_record_batch(_build_string_batch())
    var d = native.descriptor_at(0)
    assert_equal(Int(d.arrow_type), Int(ArrowType.STRING.type_id))
    assert_true(d.has_offsets(), "STRING column must record an offsets region")


# =============================================================================
# (c) nested refinement traits — List<Int64> + Struct{Int64,Float64}
# =============================================================================


def _append_i64_le(mut buf: List[UInt8], v: Int64):
    var u = UInt64(Int(v))
    for b in range(8):
        buf.append(UInt8(Int((u >> UInt64(b * 8)) & 0xFF)))


def _append_f64_le(mut buf: List[UInt8], v: Float64):
    var u = bitcast[DType.uint64, width=1](SIMD[DType.float64, 1](v))[0]
    for b in range(8):
        buf.append(UInt8(Int((u >> UInt64(b * 8)) & 0xFF)))


def _append_i32_le(mut buf: List[UInt8], v: Int32):
    var u = UInt32(Int(v))
    for b in range(4):
        buf.append(UInt8(Int((u >> UInt32(b * 8)) & 0xFF)))


def _sab_from_bytes(bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    var sab = SharedAlignedBuffer[HeapRegion].heap_owned(max(len(bytes), 1))
    for i in range(len(bytes)):
        sab.write_u8_at(i, bytes[i])
    return sab^


def _empty_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("nested", ArrowType.LIST, True))
    return sb.build()


def test_list_column_refinement_trait() raises:
    # Hand-build a List<Int64> body. 3 list cells:
    #   cell 0 = [10, 20], cell 1 = [], cell 2 = [30, 40, 50]
    # Body layout (one column): [offsets (4 entries x Int32)][child values].
    var body = List[UInt8]()
    # offsets at byte 0: 0, 2, 2, 5
    _append_i32_le(body, 0)
    _append_i32_le(body, 2)
    _append_i32_le(body, 2)
    _append_i32_le(body, 5)
    var data_off = len(body)  # child values begin here
    for v in [Int64(10), Int64(20), Int64(30), Int64(40), Int64(50)]:
        _append_i64_le(body, v)

    var sab = _sab_from_bytes(body)

    # parent List descriptor: offsets at 0; data_off RE-PURPOSED as the child
    # base index into child_descriptors (= 0).
    var parent = ColumnDescriptor(
        arrow_type=UInt16(Int(ArrowType.LIST.type_id)),
        data_off=0,  # child base index
        data_len=1,
        offsets_off=0,  # outer offsets at body byte 0
        validity_off=0,  # all-valid
        null_count=0,
    )
    var descriptors = Slab[ColumnDescriptor].create(1)
    descriptors.append(parent)

    # child-values column descriptor: int64 values at data_off.
    var child = ColumnDescriptor(
        arrow_type=UInt16(Int(ArrowType.INT64.type_id)),
        data_off=UInt32(data_off),
        data_len=UInt32(5 * 8),
        offsets_off=0,
        validity_off=0,
        null_count=0,
    )
    var child_descriptors = Slab[ColumnDescriptor].create(1)
    child_descriptors.append(child)

    var header = ColumnNativeBatchHeader(
        n_cols=1,
        row_count=3,
        schema_fingerprint=0,
        has_selection_vector=0,
        flags=0,
    )
    var sel: Optional[SharedAlignedBuffer[HeapRegion]] = None
    var batch = ColumnNativeBatch(
        header^, descriptors^, child_descriptors^, sab^, sel^, None,
        _empty_schema(),
    )

    # List cell access through the refinement trait surface.
    assert_equal(batch.cell_offset_begin(0, 0), 0)
    assert_equal(batch.cell_offset_end(0, 0), 2)
    assert_equal(batch.cell_offset_begin(0, 1), 2)
    assert_equal(batch.cell_offset_end(0, 1), 2)  # empty cell
    assert_equal(batch.cell_offset_begin(0, 2), 2)
    assert_equal(batch.cell_offset_end(0, 2), 5)

    # child values: cell 0 = [10,20], cell 2 = [30,40,50]
    assert_equal(batch.child_at[DType.int64](0, 0), Int64(10))
    assert_equal(batch.child_at[DType.int64](0, 1), Int64(20))
    assert_equal(batch.child_at[DType.int64](0, 2), Int64(30))
    assert_equal(batch.child_at[DType.int64](0, 4), Int64(50))
    assert_true(batch.cell_is_valid(0, 0))


def test_struct_column_refinement_trait() raises:
    # Hand-build a Struct{a: Int64, b: Float64} column with 3 rows.
    #   row0 = (100, 1.5), row1 = (200, 2.5), row2 = (300, 3.5)
    # Body layout: [child_a (3 x i64)][child_b (3 x f64)].
    var body = List[UInt8]()
    var a_off = len(body)
    for v in [Int64(100), Int64(200), Int64(300)]:
        _append_i64_le(body, v)
    var b_off = len(body)
    for v in [Float64(1.5), Float64(2.5), Float64(3.5)]:
        _append_f64_le(body, v)

    var sab = _sab_from_bytes(body)

    # parent Struct descriptor: data_off = child base index (0), data_len =
    # field count (2).
    var parent = ColumnDescriptor(
        arrow_type=UInt16(Int(ArrowType.STRUCT.type_id)),
        data_off=0,  # child base index
        data_len=2,  # field count
        offsets_off=0,
        validity_off=0,
        null_count=0,
    )
    var descriptors = Slab[ColumnDescriptor].create(1)
    descriptors.append(parent)

    var child_a = ColumnDescriptor(
        arrow_type=UInt16(Int(ArrowType.INT64.type_id)),
        data_off=UInt32(a_off),
        data_len=UInt32(3 * 8),
        offsets_off=0,
        validity_off=0,
        null_count=0,
    )
    var child_b = ColumnDescriptor(
        arrow_type=UInt16(Int(ArrowType.FLOAT64.type_id)),
        data_off=UInt32(b_off),
        data_len=UInt32(3 * 8),
        offsets_off=0,
        validity_off=0,
        null_count=0,
    )
    var child_descriptors = Slab[ColumnDescriptor].create(2)
    child_descriptors.append(child_a)
    child_descriptors.append(child_b)

    var header = ColumnNativeBatchHeader(
        n_cols=1,
        row_count=3,
        schema_fingerprint=0,
        has_selection_vector=0,
        flags=0,
    )
    var sel: Optional[SharedAlignedBuffer[HeapRegion]] = None
    var batch = ColumnNativeBatch(
        header^, descriptors^, child_descriptors^, sab^, sel^, None,
        _empty_schema(),
    )

    assert_equal(batch.struct_field_count(0), 2)
    assert_equal(batch.struct_child_at[DType.int64](0, 0, 0), Int64(100))
    assert_equal(batch.struct_child_at[DType.int64](0, 0, 2), Int64(300))
    assert_equal(batch.struct_child_at[DType.float64](0, 1, 0), Float64(1.5))
    assert_equal(batch.struct_child_at[DType.float64](0, 1, 2), Float64(3.5))


# =============================================================================
# (d) BatchFormat conformance + comptime-if format_kind gate (NO where-clause)
# =============================================================================


def _format_tag[F: BatchFormat]() -> Int:
    """Exercise the comptime-if format_kind gate INSIDE a generic body — the
    spike-correct dispatch shape (NO where-clause on the signature)."""
    comptime is_column = F.format_kind() == FormatKind.COLUMN
    comptime if is_column:
        return 0
    else:
        return 1


def test_batchformat_conformance_comptime_gate() raises:
    # ColumnNativeBatch conforms BatchFormat; the comptime-if gate compiles and
    # selects the COLUMN arm (tag 0).
    assert_equal(_format_tag[ColumnNativeBatch](), 0)
    assert_true(ColumnNativeBatch.supports_zero_copy_export_to_arrow())
    assert_true(ColumnNativeBatch.format_kind() == FormatKind.COLUMN)


def main() raises:
    test_roundtrip_int64_byte_identical()
    test_roundtrip_string_byte_identical()
    test_unified_column_format_numeric()
    test_unified_column_descriptor_string()
    test_list_column_refinement_trait()
    test_struct_column_refinement_trait()
    test_batchformat_conformance_comptime_gate()
    print("test_column_native_foundation: ALL PASS")
