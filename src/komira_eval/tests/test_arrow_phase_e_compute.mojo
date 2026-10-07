# =============================================================================
# Arrow compute — Float16 + Time/Duration/Interval generic
# compute kernels via PrimitiveArray-shaped accessors.
#
# Strategy: temporal types share storage DType with INT32/INT64 (e.g.
# TIME32_S stores Int32 buffer); `Column.as_primitive[
# DType.int32]()` accepts these storage-compatible Columns, so the
# existing generic compute kernels in `komira_column_kernels.comparison`,
# `arithmetic.mojo`, etc. operate on them without per-type wrappers.
#
# This test file exercises:
#   * Float16 filter / compare / arith / cast (first-class fp16).
#   * Time32 / Time64 / Duration / Interval — int32/int64 view + filter
#     via the generic comparison kernels.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_column_kernels.comparison import eval_gt, eval_lt, eval_eq, filter_to_indices
from komira_column_kernels.arithmetic import eval_add, eval_sub, eval_mul
from komira_column_kernels.cast_null import eval_cast
from komira_arrow.selection_vector import SelectionVector


# --- Float16 compute ---------------------------------------------------------


def test_float16_filter_via_eval_gt() raises:
    """eval_gt operates on PrimitiveArray[float16] (filter by threshold)."""
    var values: List[Scalar[DType.float16]] = [
        Scalar[DType.float16](1.0),
        Scalar[DType.float16](2.5),
        Scalar[DType.float16](3.75),
        Scalar[DType.float16](0.5),
    ]
    var arr = PrimitiveArray[DType.float16].from_list(values)
    var mask = eval_gt[DType.float16](arr, Scalar[DType.float16](2.0))
    assert_equal(mask.length, 4)
    assert_false(Bool(mask.get(0)), "1.0 > 2.0 false")
    assert_true(Bool(mask.get(1)), "2.5 > 2.0 true")
    assert_true(Bool(mask.get(2)), "3.75 > 2.0 true")
    assert_false(Bool(mask.get(3)), "0.5 > 2.0 false")


def test_float16_arith_add() raises:
    """eval_add on PrimitiveArray[float16]."""
    var left_vals: List[Scalar[DType.float16]] = [
        Scalar[DType.float16](1.5),
        Scalar[DType.float16](2.5),
    ]
    var right_vals: List[Scalar[DType.float16]] = [
        Scalar[DType.float16](0.5),
        Scalar[DType.float16](0.5),
    ]
    var l = PrimitiveArray[DType.float16].from_list(left_vals)
    var r = PrimitiveArray[DType.float16].from_list(right_vals)
    var res = eval_add[DType.float16](l, r)
    assert_equal(Float64(res.get(0)), 2.0)
    assert_equal(Float64(res.get(1)), 3.0)


def test_float16_cast_to_float32() raises:
    """eval_cast Float16 -> Float32."""
    var values: List[Scalar[DType.float16]] = [
        Scalar[DType.float16](1.5),
        Scalar[DType.float16](2.5),
    ]
    var arr = PrimitiveArray[DType.float16].from_list(values)
    var out = eval_cast[DType.float16, DType.float32](arr)
    assert_equal(Float64(out.get(0)), 1.5)
    assert_equal(Float64(out.get(1)), 2.5)


# --- Time32 compute via int32 view ------------------------------------------


def test_time32_filter_via_int32_view() raises:
    """A Column carrying TIME32_S can be viewed as int32 for compute."""
    var values = PrimitiveArray[DType.int32].from_list(
        [Int32(3600), Int32(7200), Int32(43200), Int32(86399)]
    )
    var col = Column.from_primitive_with_arrow_type[DType.int32](
        values^, ArrowType.TIME32_S
    )
    # The Column is TIME32_S; pull an int32 view via the storage-compat path.
    var int_view = col.as_primitive[DType.int32]()
    # Filter: clock_s > 5000 (i.e. after 1:23:20)
    var mask = eval_gt[DType.int32](int_view, Int32(5000))
    assert_equal(mask.length, 4)
    assert_false(Bool(mask.get(0)), "3600 > 5000 false")
    assert_true(Bool(mask.get(1)), "7200 > 5000 true")
    assert_true(Bool(mask.get(2)), "43200 > 5000 true")


# --- Time64 / Duration via int64 view ---------------------------------------


def test_duration_us_filter_via_int64_view() raises:
    """DURATION_US column viewed as int64 for compute."""
    var values = PrimitiveArray[DType.int64].from_list(
        [Int64(1_000_000), Int64(60_000_000), Int64(3_600_000_000)]
    )
    var col = Column.from_primitive_with_arrow_type[DType.int64](
        values^, ArrowType.DURATION_US
    )
    var int_view = col.as_primitive[DType.int64]()
    var mask = eval_gt[DType.int64](int_view, Int64(30_000_000))
    # 1s false; 60s true; 1h true
    assert_false(Bool(mask.get(0)))
    assert_true(Bool(mask.get(1)))
    assert_true(Bool(mask.get(2)))


def test_time64_ns_compare_via_int64_view() raises:
    """TIME64_NS column viewed as int64 for comparison."""
    var values = PrimitiveArray[DType.int64].from_list(
        [Int64(1), Int64(86_400_000_000_000), Int64(999_999_999)]
    )
    var col = Column.from_primitive_with_arrow_type[DType.int64](
        values^, ArrowType.TIME64_NS
    )
    var int_view = col.as_primitive[DType.int64]()
    var mask = eval_lt[DType.int64](int_view, Int64(86_400_000_000_000))
    assert_true(Bool(mask.get(0)), "1 < ns/day")
    assert_false(Bool(mask.get(1)), "ns/day !< ns/day")
    assert_true(Bool(mask.get(2)), "999.. < ns/day")


# --- Interval compute --------------------------------------------------------


def test_interval_year_month_filter_via_int32_view() raises:
    """INTERVAL_YEAR_MONTH column (Int32 months) filtered."""
    var values = PrimitiveArray[DType.int32].from_list(
        [Int32(0), Int32(12), Int32(24), Int32(-6)]
    )
    var col = Column.from_primitive_with_arrow_type[DType.int32](
        values^, ArrowType.INTERVAL_YEAR_MONTH
    )
    var int_view = col.as_primitive[DType.int32]()
    # months > 0
    var mask = eval_gt[DType.int32](int_view, Int32(0))
    assert_false(Bool(mask.get(0)))
    assert_true(Bool(mask.get(1)))
    assert_true(Bool(mask.get(2)))
    assert_false(Bool(mask.get(3)))


# --- SelectionVector integration --------------------------------------------


def test_time32_selection_vector_gather() raises:
    """SelectionVector.gather on a TIME32_S-typed Int32 view."""
    var values = PrimitiveArray[DType.int32].from_list(
        [Int32(0), Int32(3600), Int32(7200), Int32(43200)]
    )
    var col = Column.from_primitive_with_arrow_type[DType.int32](
        values^, ArrowType.TIME32_S
    )
    var int_view = col.as_primitive[DType.int32]()
    var mask = eval_gt[DType.int32](int_view, Int32(3600))
    var sv = SelectionVector.from_bool_mask(mask)
    assert_equal(sv.length(), 2)
    var gathered = sv.gather[DType.int32](int_view)
    assert_equal(gathered.length, 2)
    assert_equal(Int(gathered.get(0)), 7200)
    assert_equal(Int(gathered.get(1)), 43200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
