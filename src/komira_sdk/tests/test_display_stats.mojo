# =============================================================================
# Tests for table display formatting and statistical accumulators
# =============================================================================
#
# Feature 1: format_table() -- ASCII table rendering of RecordBatch
# Feature 2: StddevAccumulator -- Welford's online standard deviation
# Feature 3: PercentileAccumulator -- exact percentile via sort
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder, Field
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.string_array import StringArray

from komira_sdk.table_display import format_table
from komira_op_agg_state.aggregate import StddevAccumulator, PercentileAccumulator
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Helpers
# =============================================================================

def _assert_float_close(actual: Float64, expected: Float64, tol: Float64 = 1e-9) raises:
    """Assert that two Float64 values are approximately equal."""
    var diff = actual - expected
    if diff < 0:
        diff = -diff
    assert_true(
        diff < tol,
        "Expected " + String(expected) + " but got " + String(actual)
        + " (diff=" + String(diff) + ", tol=" + String(tol) + ")",
    )


def _make_int64_column(vals: List[Int]) -> Column[HeapRegion]:
    """Create a Column[HeapRegion] from a list of Int values (as int64)."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var ptr = arr._typed_ptr_mut()
    for i in range(n):
        ptr.store[width=1](i, Scalar[DType.int64](vals[i]))
    return Column.from_primitive[DType.int64](arr)


def _make_float64_column(vals: List[Float64]) -> Column[HeapRegion]:
    """Create a Column[HeapRegion] from a list of Float64 values."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate(n)
    var ptr = arr._typed_ptr_mut()
    for i in range(n):
        ptr.store[width=1](i, Scalar[DType.float64](vals[i]))
    return Column.from_primitive[DType.float64](arr)


def _make_string_column(vals: List[String]) raises -> Column[HeapRegion]:
    """Create a Column[HeapRegion] from a list of String values."""
    var arr = StringArray.from_strings(vals)
    return Column.from_string(arr)


# =============================================================================
# TABLE DISPLAY TESTS
# =============================================================================


# --- Test 1: Single-column int64 RecordBatch ---

def test_display_single_column() raises:
    """format_table renders a single int64 column correctly."""
    var vals: List[Int] = [10, 20, 30]
    var sb = SchemaBuilder()
    sb.add_field(Field("value", ArrowType.INT64, False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(_make_int64_column(vals))
    var batch = builder.build(schema^)

    var table = format_table(batch)

    # Check key structural elements
    assert_true(table.find("value") != -1, "Table should contain column name 'value'")
    assert_true(table.find("i64") != -1, "Table should contain type 'i64'")
    assert_true(table.find("10") != -1, "Table should contain value '10'")
    assert_true(table.find("20") != -1, "Table should contain value '20'")
    assert_true(table.find("30") != -1, "Table should contain value '30'")
    assert_true(table.find("3 rows") != -1, "Table should show '3 rows'")
    # Check separator characters
    assert_true(table.find("+") != -1, "Table should have + separators")
    assert_true(table.find("|") != -1, "Table should have | separators")
    assert_true(table.find("-") != -1, "Table should have - separators")


# --- Test 2: Multi-column with mixed types (int + string) ---

def test_display_mixed_types() raises:
    """format_table renders mixed int64 + string columns correctly."""
    var names_list: List[String] = ["alice", "bob"]
    var ages: List[Int] = [30, 25]

    var sb = SchemaBuilder()
    sb.add_field(Field("name", ArrowType.STRING, False))
    sb.add_field(Field("age", ArrowType.INT64, False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(_make_string_column(names_list))
    builder.add_column(_make_int64_column(ages))
    var batch = builder.build(schema^)

    var table = format_table(batch)

    # Column names
    assert_true(table.find("name") != -1, "Table should contain column 'name'")
    assert_true(table.find("age") != -1, "Table should contain column 'age'")
    # Types
    assert_true(table.find("str") != -1, "Table should contain type 'str'")
    assert_true(table.find("i64") != -1, "Table should contain type 'i64'")
    # Values
    assert_true(table.find("alice") != -1, "Table should contain 'alice'")
    assert_true(table.find("bob") != -1, "Table should contain 'bob'")
    assert_true(table.find("30") != -1, "Table should contain '30'")
    assert_true(table.find("25") != -1, "Table should contain '25'")
    assert_true(table.find("2 rows") != -1, "Table should show '2 rows'")


# --- Test 3: Truncation with max_rows ---

def test_display_truncation() raises:
    """format_table truncates output when data exceeds max_rows."""
    var vals: List[Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(_make_int64_column(vals))
    var batch = builder.build(schema^)

    var table = format_table(batch, max_rows=3)

    # Should show first 3 values
    assert_true(table.find("1") != -1, "Table should contain '1'")
    assert_true(table.find("2") != -1, "Table should contain '2'")
    assert_true(table.find("3") != -1, "Table should contain '3'")
    # Should show total row count and truncation notice
    assert_true(table.find("10 rows") != -1, "Table should show total '10 rows'")
    assert_true(table.find("7 more rows") != -1, "Table should show '7 more rows'")


# --- Test 4: Empty RecordBatch ---

def test_display_empty_batch() raises:
    """format_table handles a 0-row RecordBatch gracefully."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    var schema = sb.build()

    var vals: List[Int] = []
    var builder = RecordBatchBuilder()
    builder.add_column(_make_int64_column(vals))
    var batch = builder.build(schema^)

    var table = format_table(batch)

    # Should still have header
    assert_true(table.find("a") != -1, "Table should contain column name 'a'")
    assert_true(table.find("i64") != -1, "Table should contain type 'i64'")
    # Should show 0 rows
    assert_true(table.find("0 rows") != -1, "Table should show '0 rows'")


# =============================================================================
# STDDEV ACCUMULATOR TESTS
# =============================================================================


# --- Test 5: Known values: stddev of [2,4,4,4,5,5,7,9] = 2.0 (population) ---

def test_stddev_known_values() raises:
    """Population stddev of [2,4,4,4,5,5,7,9] = 2.0 exactly."""
    var acc = StddevAccumulator.create()
    var vals: List[Float64] = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
    for v in vals:
        acc.update(v)

    _assert_float_close(acc.stddev_pop(), 2.0)
    _assert_float_close(acc.variance_pop(), 4.0)

    # Sample stddev: sqrt(32/7) ~= 2.13809
    from std.math import sqrt
    var expected_sample = sqrt(32.0 / 7.0)
    _assert_float_close(acc.stddev_sample(), expected_sample, tol=1e-6)


# --- Test 6: Single value: stddev = 0 ---

def test_stddev_single_value() raises:
    """Stddev of a single value is 0 (population) and 0 (sample, n<2)."""
    var acc = StddevAccumulator.create()
    acc.update(42.0)

    _assert_float_close(acc.stddev_pop(), 0.0)
    _assert_float_close(acc.stddev_sample(), 0.0)
    _assert_float_close(acc.variance_pop(), 0.0)
    _assert_float_close(acc.variance_sample(), 0.0)


# --- Test 7: Welford stability with large offset values ---

def test_stddev_welford_stability() raises:
    """Welford's algorithm stays stable with large offset values.

    Naive formula (sum_sq - n*mean^2) would suffer catastrophic cancellation
    for values like [1e9+1, 1e9+2, 1e9+3]. Welford should be exact.
    """
    var acc = StddevAccumulator.create()
    var base = 1e9
    acc.update(base + 1.0)
    acc.update(base + 2.0)
    acc.update(base + 3.0)

    # stddev of [1,2,3] population = sqrt(2/3)
    from std.math import sqrt
    var expected_pop = sqrt(2.0 / 3.0)
    _assert_float_close(acc.stddev_pop(), expected_pop, tol=1e-6)

    # variance_pop = 2/3
    _assert_float_close(acc.variance_pop(), 2.0 / 3.0, tol=1e-6)

    # mean should be base + 2.0
    _assert_float_close(acc.mean, base + 2.0, tol=1e-6)


# --- Test 8: Empty accumulator ---

def test_stddev_empty() raises:
    """Stddev of zero values returns 0.0 (not NaN or error)."""
    var acc = StddevAccumulator.create()
    _assert_float_close(acc.stddev_pop(), 0.0)
    _assert_float_close(acc.stddev_sample(), 0.0)
    _assert_float_close(acc.variance_pop(), 0.0)
    _assert_float_close(acc.variance_sample(), 0.0)


# =============================================================================
# PERCENTILE ACCUMULATOR TESTS
# =============================================================================


# --- Test 9: Median (p=0.5) of [1,2,3,4,5] = 3 ---

def test_percentile_median() raises:
    """Median of [1,2,3,4,5] is 3.0 (nearest-rank method)."""
    var acc = PercentileAccumulator.create(0.5)
    var vals: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0]
    for v in vals:
        acc.insert(v)

    var result = acc.result()
    _assert_float_close(result, 3.0)


# --- Test 10: P25 and P75 of known distribution ---

def test_percentile_p25_p75() raises:
    """P25 and P75 of [1,2,3,4,5,6,7,8] using nearest-rank method."""
    # P25 with nearest-rank: ceil(0.25 * 8) = 2, so index 1 -> value 2
    var acc25 = PercentileAccumulator.create(0.25)
    var vals: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
    for v in vals:
        acc25.insert(v)
    var result25 = acc25.result()
    _assert_float_close(result25, 2.0)

    # P75: ceil(0.75 * 8) = 6, so index 5 -> value 6
    var acc75 = PercentileAccumulator.create(0.75)
    var vals2: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
    for v in vals2:
        acc75.insert(v)
    var result75 = acc75.result()
    _assert_float_close(result75, 6.0)


# --- Test 11: Single value percentile ---

def test_percentile_single_value() raises:
    """Any percentile of a single value returns that value."""
    var acc = PercentileAccumulator.create(0.99)
    acc.insert(42.0)
    var result = acc.result()
    _assert_float_close(result, 42.0)


# --- Test 12: Percentile with unsorted input ---

def test_percentile_unsorted_input() raises:
    """Percentile works correctly when values are inserted out of order."""
    var acc = PercentileAccumulator.create(0.5)
    # Insert [5,3,1,4,2] -- median should still be 3
    acc.insert(5.0)
    acc.insert(3.0)
    acc.insert(1.0)
    acc.insert(4.0)
    acc.insert(2.0)

    var result = acc.result()
    _assert_float_close(result, 3.0)


# --- Test 13: P0 and P100 (min and max) ---

def test_percentile_extremes() raises:
    """P0 returns the minimum, P100 returns the maximum."""
    # P0 (actually p=0.01 since 0.0 would give index -1 -> clamped to 0)
    # For p=0.0: ceil(0.0 * 5) = 0, index = -1, clamped to 0 -> value 1
    var acc_min = PercentileAccumulator.create(0.0)
    var vals: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0]
    for v in vals:
        acc_min.insert(v)
    _assert_float_close(acc_min.result(), 1.0)

    # P100 (p=1.0): ceil(1.0 * 5) = 5, index = 4 -> value 5
    var acc_max = PercentileAccumulator.create(1.0)
    var vals2: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0]
    for v in vals2:
        acc_max.insert(v)
    _assert_float_close(acc_max.result(), 5.0)


# =============================================================================
# Main entry point
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
