# =============================================================================
# Regression test: RecordBatchBuilder preserves Column.arrow_type for STRING
# =============================================================================
#
# Bug: Column.from_string() creates a column with arrow_type=STRING (type_id=13),
# but after passing through RecordBatchBuilder.build(), reading back shows
# type_id=192 (0xC0) -- a use-after-move/layout corruption bug.
#
# Root cause: Slab stores Column objects as raw bytes via List[UInt8] and
# uses bitcast to access them as Column*. After steal_slab() transfers the
# backing buffer, the Column.arrow_type field (UInt8 at offset 0) reads
# corrupted data. The fix ensures build() stamps each Column's arrow_type
# from the Schema after the slab transfer, guaranteeing type correctness.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow import (
    ArrowType,
    Column,
    Field,
    PrimitiveArray,
    RecordBatch,
    StringArray,
    Schema,
    SchemaBuilder,
)
from komira_core.arrow.schema import RecordBatchBuilder
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.io.heap_region import HeapRegion


# --- Helper: create a small StringArray with 3 strings ---

def _make_string_array() -> StringArray[]:
    """Build a 3-element StringArray: ["hello", "world", "mojo"]."""
    var offsets_buf = OwnedAlignedBuffer(4 * 4)  # 4 Int32 offsets
    var offsets_ptr = offsets_buf.view_typed_mut[DType.int32]()
    offsets_ptr[0] = 0
    offsets_ptr[1] = 5
    offsets_ptr[2] = 10
    offsets_ptr[3] = 14
    offsets_buf.set_length(4 * 4)

    var data_buf = OwnedAlignedBuffer(14)
    var data_ptr = data_buf.view_typed_mut[DType.uint8]()
    # "hello" = 68 65 6c 6c 6f
    data_ptr[0] = 0x68; data_ptr[1] = 0x65; data_ptr[2] = 0x6c
    data_ptr[3] = 0x6c; data_ptr[4] = 0x6f
    # "world" = 77 6f 72 6c 64
    data_ptr[5] = 0x77; data_ptr[6] = 0x6f; data_ptr[7] = 0x72
    data_ptr[8] = 0x6c; data_ptr[9] = 0x64
    # "mojo" = 6d 6f 6a 6f
    data_ptr[10] = 0x6d; data_ptr[11] = 0x6f; data_ptr[12] = 0x6a
    data_ptr[13] = 0x6f
    data_buf.set_length(14)

    return StringArray(
        offsets=offsets_buf^,
        data=data_buf^,
        validity=None,
        length=3,
        data_length=14,
        null_count=0,
    )


# =============================================================================
# Test 1: STRING column arrow_type preserved through RecordBatchBuilder
# =============================================================================

def test_string_column_arrow_type_preserved() raises:
    """Column.from_string -> RecordBatchBuilder.build -> column_at should
    preserve arrow_type == STRING (type_id == 13).

    This is the regression test for the use-after-move bug where type_id
    was corrupted to 192 (0xC0) after the Slab transfer.
    """
    var arr = _make_string_array()
    var col = Column.from_string(arr^)

    # Verify arrow_type BEFORE build
    assert_equal(Int(col.arrow_type.type_id), 13, "pre-build: type_id should be 13 (STRING)")

    var sb = SchemaBuilder()
    sb.add_field(Field("name", ArrowType.STRING, False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    # Verify arrow_type AFTER build -- this was the bug (returned 192)
    ref col_ref = batch.column_at(0)
    assert_equal(
        Int(col_ref.arrow_type.type_id),
        13,
        "post-build: Column.arrow_type should be STRING (13), got " + String(Int(col_ref.arrow_type.type_id)),
    )

    # Also verify the data is intact
    var retrieved = col_ref.as_string()
    assert_equal(retrieved.length, 3)


# =============================================================================
# Test 2: Multiple column types preserved through RecordBatchBuilder
# =============================================================================

def test_mixed_column_types_preserved() raises:
    """INT64 + STRING + FLOAT64 columns all preserve arrow_type through build()."""
    # INT64 column
    var int_vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
        Scalar[DType.int64](3),
    ]
    var int_col = Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(int_vals)^)

    # STRING column
    var str_col = Column.from_string(_make_string_array())

    # FLOAT64 column
    var f_vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.0),
        Scalar[DType.float64](2.0),
        Scalar[DType.float64](3.0),
    ]
    var f_col = Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(f_vals)^)

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    sb.add_field(Field("value", ArrowType.FLOAT64, False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(int_col^)
    builder.add_column(str_col^)
    builder.add_column(f_col^)
    var batch = builder.build(schema^)

    assert_equal(Int(batch.column_at(0).arrow_type.type_id), 5, "INT64 type_id should be 5")
    assert_equal(Int(batch.column_at(1).arrow_type.type_id), 13, "STRING type_id should be 13")
    assert_equal(Int(batch.column_at(2).arrow_type.type_id), 12, "FLOAT64 type_id should be 12")


# =============================================================================
# Test 3: column_arrow_type accessor uses Schema as source of truth
# =============================================================================

def test_column_arrow_type_accessor_uses_schema() raises:
    """RecordBatch.column_arrow_type() returns the Schema type, not the Column[HeapRegion] type."""
    var arr = _make_string_array()
    var col = Column.from_string(arr^)

    var sb = SchemaBuilder()
    sb.add_field(Field("name", ArrowType.STRING, False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    # column_arrow_type should always return STRING regardless of Column state
    var at = batch.column_arrow_type(0)
    assert_equal(Int(at.type_id), 13, "column_arrow_type should be STRING (13)")


# =============================================================================
# Main
# =============================================================================

def main() raises:
    print("--- test_string_column_arrow_type_preserved ---")
    test_string_column_arrow_type_preserved()
    print("PASS")

    print("--- test_mixed_column_types_preserved ---")
    test_mixed_column_types_preserved()
    print("PASS")

    print("--- test_column_arrow_type_accessor_uses_schema ---")
    test_column_arrow_type_accessor_uses_schema()
    print("PASS")

    print("All RecordBatchBuilder STRING type tests PASSED")
