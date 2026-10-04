# =============================================================================
# Unit tests for the byte-identical RecordBatch comparator
# (`komira_arrow_ipc.record_batch_compare`).
#
# It exercises `record_batch_diff` / `record_batch_byte_equal` --
# the comparator the differential-correctness harness wraps -- across the
# divergence classes the harness must catch:
#   1. byte-identical batches -> equal
#   2. row-count mismatch     -> not equal, reason names counts
#   3. column-count mismatch  -> not equal
#   4. field-name mismatch    -> not equal
#   5. arrow-type mismatch    -> not equal
#   6. primitive value mismatch (int64)  -> not equal, names cell
#   7. float64 bit-exact: same value equal; ULP-distinct NOT equal;
#      +0.0 vs -0.0 NOT equal (the re-association-regression guard)
#   8. string value mismatch  -> not equal
#   9. validity (null bit) mismatch -> not equal
#
# Build batches via the public RecordBatchBuilder + typed arrays only (no raw
# pointers), mirroring the comparator's own access discipline.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal
from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, Schema, SchemaBuilder, RecordBatch
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import RecordBatchBuilder
from komira_arrow_ipc.record_batch_compare import (
    record_batch_diff,
    record_batch_byte_equal,
)
from komira_buffer.heap_region import HeapRegion


# --- helpers ----------------------------------------------------------------


def _i64_col(values: List[Int64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].from_list(values)
    return Column.from_primitive[DType.int64](arr^)


def _f64_col(values: List[Float64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float64].from_list(values)
    return Column.from_primitive[DType.float64](arr^)


def _f64_col_with_null(values: List[Float64], null_at: Int) raises -> Column[HeapRegion]:
    """Nullable float64 column; element `null_at` set null, others valid."""
    var n = len(values)
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, values[i])
    arr._set_null(null_at)
    return Column.from_primitive[DType.float64](arr^)


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    var arr = StringArray.from_strings(values)
    return Column.from_string(arr^)


def _batch_i64(name: String, values: List[Int64]) raises -> RecordBatch:
    var b = RecordBatchBuilder()
    b.add_column(_i64_col(values))
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    return b.build(sb.build())


def _batch_f64(name: String, values: List[Float64]) raises -> RecordBatch:
    var b = RecordBatchBuilder()
    b.add_column(_f64_col(values))
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, False))
    return b.build(sb.build())


# --- tests ------------------------------------------------------------------


def test_identical_int64_equal() raises:
    var a = _batch_i64("x", [Int64(1), Int64(2), Int64(3)])
    var b = _batch_i64("x", [Int64(1), Int64(2), Int64(3)])
    assert_true(record_batch_byte_equal(a, b), "identical int64 batches equal")


def test_row_count_mismatch() raises:
    var a = _batch_i64("x", [Int64(1), Int64(2), Int64(3)])
    var b = _batch_i64("x", [Int64(1), Int64(2)])
    var d = record_batch_diff(a, b)
    assert_false(d.equal, "differing row counts -> not equal")
    assert_true("row count differs" in d.reason, "reason names row count")


def test_column_count_mismatch() raises:
    var a = _batch_i64("x", [Int64(1)])
    # b: two columns
    var bb = RecordBatchBuilder()
    bb.add_column(_i64_col([Int64(1)]))
    bb.add_column(_i64_col([Int64(2)]))
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, False))
    sb.add_field(Field("y", ArrowType.INT64, False))
    var b = bb.build(sb.build())
    var d = record_batch_diff(a, b)
    assert_false(d.equal, "differing column counts -> not equal")
    assert_true("column count differs" in d.reason, "reason names column count")


def test_field_name_mismatch() raises:
    var a = _batch_i64("x", [Int64(1)])
    var b = _batch_i64("y", [Int64(1)])
    var d = record_batch_diff(a, b)
    assert_false(d.equal, "differing field names -> not equal")
    assert_true("field name differs" in d.reason, "reason names field name")


def test_arrow_type_mismatch() raises:
    var a = _batch_i64("x", [Int64(1)])
    var b = _batch_f64("x", [Float64(1.0)])
    var d = record_batch_diff(a, b)
    assert_false(d.equal, "differing arrow types -> not equal")
    assert_true("arrow type differs" in d.reason, "reason names arrow type")


def test_int64_value_mismatch() raises:
    var a = _batch_i64("x", [Int64(1), Int64(2), Int64(3)])
    var b = _batch_i64("x", [Int64(1), Int64(99), Int64(3)])
    var d = record_batch_diff(a, b)
    assert_false(d.equal, "differing values -> not equal")
    assert_true("value differs" in d.reason, "reason names value")
    assert_true("row 1" in d.reason, "reason names the divergent row")


def test_float64_bit_exact_equal() raises:
    var a = _batch_f64("rev", [Float64(123141078.22829995)])
    var b = _batch_f64("rev", [Float64(123141078.22829995)])
    assert_true(
        record_batch_byte_equal(a, b), "identical float64 equal (bit-exact)"
    )


def test_float64_ulp_distinct_not_equal() raises:
    # Two float64 values one ULP apart must NOT compare equal -- this is the
    # re-association-regression guard.
    var v0 = Float64(1.0)
    var bits = bitcast[DType.uint64, width=1](v0) + 1
    var v1 = bitcast[DType.float64, width=1](bits)
    var a = _batch_f64("v", [v0])
    var b = _batch_f64("v", [v1])
    var d = record_batch_diff(a, b)
    assert_false(d.equal, "one-ULP-apart floats -> not equal")
    assert_true("bit-exact" in d.reason, "reason flags bit-exact float diff")


def test_float64_signed_zero_not_equal() raises:
    # +0.0 and -0.0 are == in IEEE arithmetic but have distinct bit patterns;
    # a byte-identical gate must distinguish them.
    var a = _batch_f64("z", [Float64(0.0)])
    var neg_zero = (Float64(-1.0) * Float64(0.0))
    var b = _batch_f64("z", [neg_zero])
    var d = record_batch_diff(a, b)
    assert_false(d.equal, "+0.0 vs -0.0 -> not equal (bit-exact)")


def test_string_value_mismatch() raises:
    var ba = RecordBatchBuilder()
    ba.add_column(_str_col([String("A"), String("F")]))
    var sba = SchemaBuilder()
    sba.add_field(Field("flag", ArrowType.STRING, False))
    var a = ba.build(sba.build())

    var bb = RecordBatchBuilder()
    bb.add_column(_str_col([String("A"), String("O")]))
    var sbb = SchemaBuilder()
    sbb.add_field(Field("flag", ArrowType.STRING, False))
    var b = bb.build(sbb.build())

    var d = record_batch_diff(a, b)
    assert_false(d.equal, "differing strings -> not equal")
    assert_true("string value differs" in d.reason, "reason names string value")


def test_string_identical_equal() raises:
    var ba = RecordBatchBuilder()
    ba.add_column(_str_col([String("A"), String("F"), String("N")]))
    var sba = SchemaBuilder()
    sba.add_field(Field("flag", ArrowType.STRING, False))
    var a = ba.build(sba.build())

    var bb = RecordBatchBuilder()
    bb.add_column(_str_col([String("A"), String("F"), String("N")]))
    var sbb = SchemaBuilder()
    sbb.add_field(Field("flag", ArrowType.STRING, False))
    var b = bb.build(sbb.build())

    assert_true(record_batch_byte_equal(a, b), "identical string columns equal")


def test_validity_bit_mismatch() raises:
    # Same values, but one batch has a null where the other has a valid value.
    var ba = RecordBatchBuilder()
    ba.add_column(_f64_col_with_null([Float64(1.0), Float64(2.0), Float64(3.0)], 1))
    var sba = SchemaBuilder()
    sba.add_field(Field("v", ArrowType.FLOAT64, True))
    var a = ba.build(sba.build())

    var bb = RecordBatchBuilder()
    bb.add_column(_f64_col([Float64(1.0), Float64(2.0), Float64(3.0)]))
    var sbb = SchemaBuilder()
    # nullable flag differs too; but to isolate the validity-bit path, make
    # both nullable schemas: build b nullable with no nulls.
    sbb.add_field(Field("v", ArrowType.FLOAT64, True))
    var bcol = PrimitiveArray[DType.float64].allocate_nullable(3)
    bcol.set(0, Float64(1.0))
    bcol.set(1, Float64(2.0))
    bcol.set(2, Float64(3.0))
    var bb2 = RecordBatchBuilder()
    bb2.add_column(Column.from_primitive[DType.float64](bcol^))
    var b = bb2.build(sbb.build())

    var d = record_batch_diff(a, b)
    assert_false(d.equal, "validity-bit divergence -> not equal")
    assert_true("validity differs" in d.reason, "reason names validity")


def main() raises:
    print("--- test_identical_int64_equal ---")
    test_identical_int64_equal()
    print("PASS")

    print("--- test_row_count_mismatch ---")
    test_row_count_mismatch()
    print("PASS")

    print("--- test_column_count_mismatch ---")
    test_column_count_mismatch()
    print("PASS")

    print("--- test_field_name_mismatch ---")
    test_field_name_mismatch()
    print("PASS")

    print("--- test_arrow_type_mismatch ---")
    test_arrow_type_mismatch()
    print("PASS")

    print("--- test_int64_value_mismatch ---")
    test_int64_value_mismatch()
    print("PASS")

    print("--- test_float64_bit_exact_equal ---")
    test_float64_bit_exact_equal()
    print("PASS")

    print("--- test_float64_ulp_distinct_not_equal ---")
    test_float64_ulp_distinct_not_equal()
    print("PASS")

    print("--- test_float64_signed_zero_not_equal ---")
    test_float64_signed_zero_not_equal()
    print("PASS")

    print("--- test_string_value_mismatch ---")
    test_string_value_mismatch()
    print("PASS")

    print("--- test_string_identical_equal ---")
    test_string_identical_equal()
    print("PASS")

    print("--- test_validity_bit_mismatch ---")
    test_validity_bit_mismatch()
    print("PASS")

    print("All RecordBatch byte-compare tests PASSED")
