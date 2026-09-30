# =============================================================================
# Tests for MapArray and IPC serialization
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.sys import size_of

from komira_core.arrow.map_array import MapArray
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.schema import (
    Field,
    Schema,
    SchemaBuilder,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_core.arrow.ipc import serialize_primitive_batch, deserialize_primitive_batch


# =============================================================================
# MapArray tests
# =============================================================================


def test_map_from_string_int_maps_basic() raises:
    """Create a MapArray from string->int maps and verify length."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append(("a", 1))
    m0.append(("b", 2))
    var m1 = List[Tuple[String, Int]]()
    m1.append(("c", 3))
    maps.append(m0^)
    maps.append(m1^)
    var arr = MapArray.from_string_int_maps(maps)
    assert_equal(len(arr), 2)
    assert_equal(arr.null_count, 0)
    assert_equal(arr.total_entries(), 3)
    assert_false(arr.keys_sorted)


def test_map_get_offset() raises:
    """Verify get_offset returns correct entry start indices."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append(("x", 10))
    m0.append(("y", 20))
    m0.append(("z", 30))
    var m1 = List[Tuple[String, Int]]()
    m1.append(("w", 40))
    var m2 = List[Tuple[String, Int]]()
    m2.append(("v", 50))
    m2.append(("u", 60))
    maps.append(m0^)
    maps.append(m1^)
    maps.append(m2^)
    var arr = MapArray.from_string_int_maps(maps)
    assert_equal(arr.get_offset(0), 0)
    assert_equal(arr.get_offset(1), 3)
    assert_equal(arr.get_offset(2), 4)


def test_map_get_length() raises:
    """Verify get_length returns correct entry counts per map."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append(("a", 1))
    m0.append(("b", 2))
    m0.append(("c", 3))
    var m1 = List[Tuple[String, Int]]()
    m1.append(("d", 4))
    var m2 = List[Tuple[String, Int]]()
    m2.append(("e", 5))
    m2.append(("f", 6))
    maps.append(m0^)
    maps.append(m1^)
    maps.append(m2^)
    var arr = MapArray.from_string_int_maps(maps)
    assert_equal(arr.get_length(0), 3)
    assert_equal(arr.get_length(1), 1)
    assert_equal(arr.get_length(2), 2)


def test_map_empty_map_element() raises:
    """An empty map {} has length 0 and correct offsets."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append(("a", 1))
    var m1 = List[Tuple[String, Int]]()  # empty map
    var m2 = List[Tuple[String, Int]]()
    m2.append(("b", 2))
    maps.append(m0^)
    maps.append(m1^)
    maps.append(m2^)
    var arr = MapArray.from_string_int_maps(maps)
    assert_equal(len(arr), 3)
    assert_equal(arr.get_length(0), 1)
    assert_equal(arr.get_length(1), 0)  # empty map
    assert_equal(arr.get_length(2), 1)
    assert_equal(arr.get_offset(1), 1)  # starts right after map 0
    assert_equal(arr.get_offset(2), 1)  # same offset since map 1 was empty
    assert_equal(arr.total_entries(), 2)


def test_map_single_entry_maps() raises:
    """Each map contains exactly one key-value pair."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append(("k1", 100))
    var m1 = List[Tuple[String, Int]]()
    m1.append(("k2", 200))
    var m2 = List[Tuple[String, Int]]()
    m2.append(("k3", 300))
    maps.append(m0^)
    maps.append(m1^)
    maps.append(m2^)
    var arr = MapArray.from_string_int_maps(maps)
    assert_equal(len(arr), 3)
    for i in range(3):
        assert_equal(arr.get_length(i), 1)
    assert_equal(arr.total_entries(), 3)


def test_map_is_null_no_bitmap() raises:
    """All elements report non-null when no validity bitmap."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append(("a", 1))
    var m1 = List[Tuple[String, Int]]()
    m1.append(("b", 2))
    maps.append(m0^)
    maps.append(m1^)
    var arr = MapArray.from_string_int_maps(maps)
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))


def test_map_is_null_with_bitmap() raises:
    """Null elements report correctly when validity bitmap is present."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append(("a", 1))
    var m1 = List[Tuple[String, Int]]()
    m1.append(("b", 2))
    var m2 = List[Tuple[String, Int]]()
    m2.append(("c", 3))
    maps.append(m0^)
    maps.append(m1^)
    maps.append(m2^)
    var mask: List[Bool] = [True, False, True]
    var arr = MapArray.from_string_int_maps_nullable(maps, mask)
    assert_false(arr.is_null(0))
    assert_true(arr.is_null(1))
    assert_false(arr.is_null(2))
    assert_equal(arr.null_count, 1)


def test_map_len() raises:
    """Verify __len__ returns the number of maps."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append(("a", 1))
    var m1 = List[Tuple[String, Int]]()
    m1.append(("b", 2))
    var m2 = List[Tuple[String, Int]]()
    m2.append(("c", 3))
    var m3 = List[Tuple[String, Int]]()
    m3.append(("d", 4))
    maps.append(m0^)
    maps.append(m1^)
    maps.append(m2^)
    maps.append(m3^)
    var arr = MapArray.from_string_int_maps(maps)
    assert_equal(len(arr), 4)


def test_map_empty_array() raises:
    """A MapArray with zero maps is valid."""
    var maps = List[List[Tuple[String, Int]]]()
    var arr = MapArray.from_string_int_maps(maps)
    assert_equal(len(arr), 0)
    assert_equal(arr.total_entries(), 0)
    assert_equal(arr.null_count, 0)


def test_map_arrow_type() raises:
    """MAP ArrowType has type_id 28 and format string '+m'."""
    assert_equal(Int(ArrowType.MAP.type_id), 28)
    assert_equal(ArrowType.MAP.format_string(), "+m")
    assert_true(ArrowType.MAP.is_nested())


# =============================================================================
# IPC serialization tests
#
# Note: We use RecordBatch.column_value() and raw data pointer reads to verify
# deserialized data. Calling _column_ref(i)[].as_primitive[...]() can trigger
# a Mojo compiler issue where the pointer escapes the expression scope and
# self.arrow_type reads garbage. column_value() works correctly because it
# accesses the column within the RecordBatch method scope.
# =============================================================================


def test_ipc_serialize_single_int64_column() raises:
    """Serialize a single-column int64 RecordBatch, deserialize, verify values."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](10),
        Scalar[DType.int64](20),
        Scalar[DType.int64](30),
    ]
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var col = Column.from_primitive[DType.int64](arr)

    var schema = Schema.from_fields_1(
        Field("x", ArrowType.INT64, nullable=False)
    )
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)

    var serialized = serialize_primitive_batch(batch)
    var restored = deserialize_primitive_batch(serialized)

    assert_equal(restored.num_columns(), 1)
    assert_equal(restored.num_rows(), 3)

    # Use column_value for int64 columns (works around pointer-escape issue)
    assert_equal(Int(restored.column_value(0, 0)), 10)
    assert_equal(Int(restored.column_value(0, 1)), 20)
    assert_equal(Int(restored.column_value(0, 2)), 30)


def test_ipc_serialize_multi_column_int64() raises:
    """Serialize multi-column (int64 + int64), deserialize, verify."""
    var vals_a: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
    ]
    var vals_b: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](100),
        Scalar[DType.int64](200),
    ]
    var arr_a = PrimitiveArray[DType.int64].from_list(vals_a)
    var arr_b = PrimitiveArray[DType.int64].from_list(vals_b)
    var col_a = Column.from_primitive[DType.int64](arr_a)
    var col_b = Column.from_primitive[DType.int64](arr_b)

    var schema = Schema.from_fields_2(
        Field("a", ArrowType.INT64, nullable=False),
        Field("b", ArrowType.INT64, nullable=False),
    )
    var batch = RecordBatch.from_typed_columns_2(schema^, col_a^, col_b^)

    var serialized = serialize_primitive_batch(batch)
    var restored = deserialize_primitive_batch(serialized)

    assert_equal(restored.num_columns(), 2)
    assert_equal(restored.num_rows(), 2)

    # Verify both columns via raw data buffer reads
    var cp0 = restored._column_ref(0)
    var typed0 = cp0[]._data.view_typed_ro[DType.int64]()
    assert_equal(Int((typed0 + 0)[]), 1)
    assert_equal(Int((typed0 + 1)[]), 2)

    var cp1 = restored._column_ref(1)
    var typed1 = cp1[]._data.view_typed_ro[DType.int64]()
    assert_equal(Int((typed1 + 0)[]), 100)
    assert_equal(Int((typed1 + 1)[]), 200)


def test_ipc_serialize_int32_float64() raises:
    """Serialize mixed types (int32 + float64), verify raw data correct."""
    var int_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](42),
        Scalar[DType.int32](99),
    ]
    var float_vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](3.14),
        Scalar[DType.float64](2.71),
    ]
    var int_arr = PrimitiveArray[DType.int32].from_list(int_vals)
    var float_arr = PrimitiveArray[DType.float64].from_list(float_vals)
    var col0 = Column.from_primitive[DType.int32](int_arr)
    var col1 = Column.from_primitive[DType.float64](float_arr)

    var schema = Schema.from_fields_2(
        Field("i", ArrowType.INT32, nullable=False),
        Field("f", ArrowType.FLOAT64, nullable=False),
    )
    var batch = RecordBatch.from_typed_columns_2(schema^, col0^, col1^)

    var serialized = serialize_primitive_batch(batch)
    var restored = deserialize_primitive_batch(serialized)

    assert_equal(restored.num_columns(), 2)
    assert_equal(restored.num_rows(), 2)

    # Read int32 raw data
    var cp0 = restored._column_ref(0)
    var int_ptr = cp0[]._data.view_typed_ro[DType.int32]()
    assert_equal(Int((int_ptr + 0)[]), 42)
    assert_equal(Int((int_ptr + 1)[]), 99)

    # Read float64 raw data
    var cp1 = restored._column_ref(1)
    var float_ptr = cp1[]._data.view_typed_ro[DType.float64]()
    assert_true(Float64((float_ptr + 0)[]) > 3.13)
    assert_true(Float64((float_ptr + 0)[]) < 3.15)
    assert_true(Float64((float_ptr + 1)[]) > 2.70)
    assert_true(Float64((float_ptr + 1)[]) < 2.72)


def test_ipc_serialize_empty_batch() raises:
    """Serialize a batch with 0 rows, deserialize, verify."""
    var vals: List[Scalar[DType.int64]] = List[Scalar[DType.int64]]()
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var col = Column.from_primitive[DType.int64](arr)

    var schema = Schema.from_fields_1(
        Field("empty", ArrowType.INT64, nullable=False)
    )
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)

    var serialized = serialize_primitive_batch(batch)
    var restored = deserialize_primitive_batch(serialized)

    assert_equal(restored.num_columns(), 1)
    assert_equal(restored.num_rows(), 0)


def test_ipc_serialize_nullable_column() raises:
    """Serialize a batch with a nullable column, verify nulls survive round-trip."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(3)
    arr.set(0, Scalar[DType.int64](100))
    arr.set(1, Scalar[DType.int64](200))
    # Mark element 2 as null
    arr.validity.value().clear(2)
    arr.null_count = 1

    var col = Column.from_primitive[DType.int64](arr)

    var schema = Schema.from_fields_1(
        Field("val", ArrowType.INT64, nullable=True)
    )
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)

    var serialized = serialize_primitive_batch(batch)
    var restored = deserialize_primitive_batch(serialized)

    assert_equal(restored.num_columns(), 1)
    assert_equal(restored.num_rows(), 3)

    # Verify the column has a validity bitmap and values are correct
    var cp = restored._column_ref(0)
    assert_true(cp[]._validity.__bool__())
    assert_equal(cp[]._null_count, 1)

    # Read raw int64 values
    var typed = cp[]._data.view_typed_ro[DType.int64]()
    assert_equal(Int((typed + 0)[]), 100)
    assert_equal(Int((typed + 1)[]), 200)

    # Check validity bitmap: elements 0 and 1 are valid, element 2 is null
    assert_true(cp[]._validity.value().test(0))
    assert_true(cp[]._validity.value().test(1))
    assert_false(cp[]._validity.value().test(2))


def test_ipc_roundtrip_values_match() raises:
    """Round-trip: original values == deserialized values for int64."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](42),
        Scalar[DType.int64](-7),
        Scalar[DType.int64](0),
        Scalar[DType.int64](999999),
    ]
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var col = Column.from_primitive[DType.int64](arr)

    var schema = Schema.from_fields_1(
        Field("data", ArrowType.INT64, nullable=False)
    )
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)

    var serialized = serialize_primitive_batch(batch)
    var restored = deserialize_primitive_batch(serialized)

    # Verify via column_value (safe accessor)
    assert_equal(Int(restored.column_value(0, 0)), 42)
    assert_equal(Int(restored.column_value(0, 1)), -7)
    assert_equal(Int(restored.column_value(0, 2)), 0)
    assert_equal(Int(restored.column_value(0, 3)), 999999)


def test_ipc_magic_bytes_validated() raises:
    """Deserialize rejects buffers with wrong magic bytes."""
    from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
    from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer

    var bad_buf = OwnedAlignedBuffer(64)
    bad_buf.zero()
    bad_buf.set_length(64)

    # Write wrong magic
    bad_buf.view_typed_mut[DType.uint8]()[] = UInt8(0x00)

    # deserialize_primitive_batch takes SharedAlignedBuffer[HeapRegion];
    # promote the owned builder buffer.
    var shared_bad = SharedAlignedBuffer.from_owned(bad_buf^)

    var raised = False
    try:
        var batch = deserialize_primitive_batch(shared_bad)
    except:
        raised = True
    assert_true(raised)


def test_ipc_too_short_buffer_rejected() raises:
    """Deserialize rejects buffers that are too short."""
    from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
    from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer

    var short_buf = OwnedAlignedBuffer(4)
    short_buf.set_length(4)

    var shared_short = SharedAlignedBuffer.from_owned(short_buf^)

    var raised = False
    try:
        var batch = deserialize_primitive_batch(shared_short)
    except:
        raised = True
    assert_true(raised)


def test_ipc_column_metadata_preserved() raises:
    """Serialized column count and row count match original."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
        Scalar[DType.int64](3),
        Scalar[DType.int64](4),
        Scalar[DType.int64](5),
    ]
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var col = Column.from_primitive[DType.int64](arr)
    var schema = Schema.from_fields_1(
        Field("nums", ArrowType.INT64, nullable=False)
    )
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)

    var serialized = serialize_primitive_batch(batch)
    var restored = deserialize_primitive_batch(serialized)

    assert_equal(restored.num_columns(), 1)
    assert_equal(restored.num_rows(), 5)
    # Verify data length matches
    var cp = restored._column_ref(0)
    assert_equal(cp[]._data.len(), 5 * 8)  # 5 int64 = 40 bytes
    assert_equal(cp[]._length, 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
