# =============================================================================
# Tests for the single-pass lexicographic multi-key sort (sort_lex.mojo)
# =============================================================================
#
# `sort_batch_by_keys` routes 2+-key
# sorts where every key column is INT32 / INT64 / STRING through
# `sort_batch_lex` (one lexicographic pass; STRING keys dict-rank encoded;
# bit-packed Int64 + radix when the encoded ranks fit). These tests cover:
#
#   - The TPC-H Q16 ORDER BY shape: INT64 DESC primary, STRING ASC, STRING
#     ASC, INT64 ASC — with ties at every level to exercise the stable
#     tie-break + the per-key descending flag.
#   - STRING-primary with within-key ties (stability).
#   - Mixed INT32 / INT64 / STRING keys (the bit-pack fast path).
#   - 3-key STRING-only sort.
#   - Negative INT64 keys (bit-pack offset handling).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.string_array import StringArray
from komira_op_sort.sort_multi import sort_batch_by_keys
from komira_buffer.heap_region import HeapRegion


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _i64_col(var values: List[Int64]) -> Column[HeapRegion]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    return Column.from_primitive[DType.int64](arr^)


def _i32_col(var values: List[Int32]) -> Column[HeapRegion]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int32].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    return Column.from_primitive[DType.int32](arr^)


def _str_at(col: Column[HeapRegion], row: Int) raises -> String:
    var sa = col.as_string()
    return sa.get(row)


def _i64_at(col: Column[HeapRegion], row: Int) raises -> Int64:
    var arr = col.as_primitive[DType.int64]()
    return arr.get(row)


def _i32_at(col: Column[HeapRegion], row: Int) raises -> Int32:
    var arr = col.as_primitive[DType.int32]()
    return arr.get(row)


# =============================================================================
# Test 1 — TPC-H Q16 ORDER BY shape: INT64 DESC, STRING ASC, STRING ASC, INT64 ASC
# =============================================================================


def test_q16_order_by_shape() raises:
    """Mirrors q16's `ORDER BY supplier_cnt DESC, p_brand, p_type, p_size`.

    Input rows (cnt, brand, type, size), tracked by `id` in column 4:
      r0 (5, "B#2", "SMALL", 14)
      r1 (3, "B#1", "LARGE", 9)
      r2 (5, "B#1", "SMALL", 14)
      r3 (5, "B#1", "SMALL", 14)   <- exact dup of r2: keep r2 before r3 (stable)
      r4 (5, "B#1", "LARGE", 3)
      r5 (3, "B#1", "LARGE", 9)    <- exact dup of r1: keep r1 before r5
      r6 (7, "B#9", "MED", 36)

    Expected order (cnt DESC, brand ASC, type ASC, size ASC):
      r6 (7, ...)
      r4 (5, "B#1", "LARGE", 3)
      r2 (5, "B#1", "SMALL", 14)
      r3 (5, "B#1", "SMALL", 14)
      r0 (5, "B#2", "SMALL", 14)
      r1 (3, "B#1", "LARGE", 9)
      r5 (3, "B#1", "LARGE", 9)
    """
    var cnt: List[Int64] = [Int64(5), 3, 5, 5, 5, 3, 7]
    var brand: List[String] = ["B#2", "B#1", "B#1", "B#1", "B#1", "B#1", "B#9"]
    var typ: List[String] = ["SMALL", "LARGE", "SMALL", "SMALL", "LARGE", "LARGE", "MED"]
    var size: List[Int64] = [Int64(14), 9, 14, 14, 3, 9, 36]
    var ids: List[Int64] = [Int64(0), 1, 2, 3, 4, 5, 6]

    var sb = SchemaBuilder()
    sb.add_field(Field("supplier_cnt", ArrowType.INT64, False))
    sb.add_field(Field("p_brand", ArrowType.STRING, False))
    sb.add_field(Field("p_type", ArrowType.STRING, False))
    sb.add_field(Field("p_size", ArrowType.INT64, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(cnt^))
    rb.add_column(_str_col(brand))
    rb.add_column(_str_col(typ))
    rb.add_column(_i64_col(size^))
    rb.add_column(_i64_col(ids^))
    var batch = rb.build(sb.build())

    var keys: List[String] = ["supplier_cnt", "p_brand", "p_type", "p_size"]
    var desc: List[Bool] = [True, False, False, False]
    var sorted = sort_batch_by_keys(batch^, keys, desc)
    assert_equal(sorted.num_rows(), 7)

    var expect_ids: List[Int] = [6, 4, 2, 3, 0, 1, 5]
    for i in range(7):
        assert_equal(Int(_i64_at(sorted.column_at(4), i)), expect_ids[i])

    # Spot-check the actual key values too.
    assert_equal(Int(_i64_at(sorted.column_at(0), 0)), 7)
    assert_equal(_str_at(sorted.column_at(1), 1), String("B#1"))
    assert_equal(_str_at(sorted.column_at(2), 1), String("LARGE"))
    assert_equal(Int(_i64_at(sorted.column_at(3), 1)), 3)
    assert_equal(_str_at(sorted.column_at(2), 2), String("SMALL"))
    assert_equal(_str_at(sorted.column_at(1), 4), String("B#2"))


# =============================================================================
# Test 2 — STRING primary with within-key ties (stability)
# =============================================================================


def test_string_primary_stable_ties() raises:
    """All rows share the STRING primary key 'X'; the INT64 secondary
    determines order, ties on the secondary keep original (id) order."""
    var k0: List[String] = ["X", "X", "X", "X", "X"]
    var k1: List[Int64] = [Int64(20), 10, 20, 10, 30]
    var ids: List[Int64] = [Int64(0), 1, 2, 3, 4]

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.STRING, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_str_col(k0))
    rb.add_column(_i64_col(k1^))
    rb.add_column(_i64_col(ids^))
    var batch = rb.build(sb.build())

    var keys: List[String] = ["a", "b"]
    var desc: List[Bool] = [False, False]
    var sorted = sort_batch_by_keys(batch^, keys, desc)
    assert_equal(sorted.num_rows(), 5)
    # Expected (b ASC, stable): (10,r1), (10,r3), (20,r0), (20,r2), (30,r4)
    var expect_ids: List[Int] = [1, 3, 0, 2, 4]
    for i in range(5):
        assert_equal(Int(_i64_at(sorted.column_at(2), i)), expect_ids[i])


# =============================================================================
# Test 3 — mixed INT32 / INT64 / STRING keys (bit-pack fast path)
# =============================================================================


def test_mixed_i32_i64_string_keys() raises:
    """3-key sort over (INT32 ASC, STRING DESC, INT64 ASC)."""
    var k0: List[Int32] = [Int32(2), 1, 2, 1, 2]
    var k1: List[String] = ["alpha", "beta", "gamma", "alpha", "alpha"]
    var k2: List[Int64] = [Int64(100), 200, 300, 400, 50]
    var ids: List[Int64] = [Int64(0), 1, 2, 3, 4]

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT32, False))
    sb.add_field(Field("b", ArrowType.STRING, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i32_col(k0^))
    rb.add_column(_str_col(k1))
    rb.add_column(_i64_col(k2^))
    rb.add_column(_i64_col(ids^))
    var batch = rb.build(sb.build())

    var keys: List[String] = ["a", "b", "c"]
    var desc: List[Bool] = [False, True, False]
    var sorted = sort_batch_by_keys(batch^, keys, desc)
    assert_equal(sorted.num_rows(), 5)
    # a=1 group: ("beta",200,r1) then ("alpha",400,r3)  (b DESC: beta > alpha)
    # a=2 group: ("gamma",300,r2), ("alpha",50,r4), ("alpha",100,r0)
    var expect_ids: List[Int] = [1, 3, 2, 4, 0]
    for i in range(5):
        assert_equal(Int(_i64_at(sorted.column_at(3), i)), expect_ids[i])


# =============================================================================
# Test 4 — three STRING keys
# =============================================================================


def test_three_string_keys() raises:
    var k0: List[String] = ["b", "a", "b", "a"]
    var k1: List[String] = ["y", "z", "x", "x"]
    var k2: List[String] = ["m", "n", "n", "o"]
    var ids: List[Int64] = [Int64(0), 1, 2, 3]

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.STRING, False))
    sb.add_field(Field("b", ArrowType.STRING, False))
    sb.add_field(Field("c", ArrowType.STRING, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_str_col(k0))
    rb.add_column(_str_col(k1))
    rb.add_column(_str_col(k2))
    rb.add_column(_i64_col(ids^))
    var batch = rb.build(sb.build())

    var keys: List[String] = ["a", "b", "c"]
    var desc: List[Bool] = [False, False, False]
    var sorted = sort_batch_by_keys(batch^, keys, desc)
    assert_equal(sorted.num_rows(), 4)
    # ("a","x","o",r3), ("a","z","n",r1), ("b","x","n",r2), ("b","y","m",r0)
    var expect_ids: List[Int] = [3, 1, 2, 0]
    for i in range(4):
        assert_equal(Int(_i64_at(sorted.column_at(3), i)), expect_ids[i])


# =============================================================================
# Test 5 — negative INT64 keys (bit-pack offset handling)
# =============================================================================


def test_negative_int_keys() raises:
    var k0: List[Int64] = [Int64(-5), 3, -5, 0, -100, 3]
    var k1: List[Int64] = [Int64(2), 1, 1, 0, 7, 1]
    var ids: List[Int64] = [Int64(0), 1, 2, 3, 4, 5]

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(k0^))
    rb.add_column(_i64_col(k1^))
    rb.add_column(_i64_col(ids^))
    var batch = rb.build(sb.build())

    var keys: List[String] = ["a", "b"]
    var desc: List[Bool] = [False, False]
    var sorted = sort_batch_by_keys(batch^, keys, desc)
    assert_equal(sorted.num_rows(), 6)
    # a ASC: -100(r4), -5(r2,b=1), -5(r0,b=2), 0(r3), 3(r1,b=1 stable), 3(r5,b=1)
    var expect_ids: List[Int] = [4, 2, 0, 3, 1, 5]
    for i in range(6):
        assert_equal(Int(_i64_at(sorted.column_at(2), i)), expect_ids[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
