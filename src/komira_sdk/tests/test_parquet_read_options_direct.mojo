# =============================================================================
# ParquetReadOptions: the defaults, the constructor, and the three copies.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * `default()` is union-by-name, fail on an empty glob, Hive auto-detect,
#     lazy Hive lowering and no partition filter (any default flipped);
#   * the three-argument constructor defaults the last two fields (a changed
#     default);
#   * `copy()` carries every field and deep-copies the filter, with and
#     without one (a dropped field, a shared filter, a filter lost on copy);
#   * `with_eager_hive_lowering()` turns lazy lowering off and keeps the
#     other fields and the filter (the flag left on, the filter dropped);
#   * `with_partition_filter()` sets the filter and keeps the flags.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_expr.expr import Expr, BIN_EQ
from komira_plan_expr.scalar_value import ScalarValue

from komira_sdk.parquet_read_options import ParquetReadOptions


def _dt_is(v: String) -> Expr:
    return Expr.binary(
        BIN_EQ, Expr.col_ref("dt"), Expr.literal(ScalarValue.from_string(v))
    )


def _filter_text(o: ParquetReadOptions) -> String:
    return String(o.partition_filter.value())


def test_default() raises:
    var o = ParquetReadOptions.default()
    assert_true(o.union_by_name)
    assert_false(o.allow_empty_glob)
    assert_true(o.hive_partitioning)
    assert_true(o.lazy_hive_lowering)
    assert_false(Bool(o.partition_filter))


def test_three_argument_constructor() raises:
    var o = ParquetReadOptions(False, True, False)
    assert_false(o.union_by_name)
    assert_true(o.allow_empty_glob)
    assert_false(o.hive_partitioning)
    assert_true(o.lazy_hive_lowering, "lazy lowering defaults on")
    assert_false(Bool(o.partition_filter), "no filter by default")


def test_copy_without_and_with_filter() raises:
    var plain = ParquetReadOptions(False, True, False, False)
    var c = plain.copy()
    assert_false(c.union_by_name)
    assert_true(c.allow_empty_glob)
    assert_false(c.hive_partitioning)
    assert_false(c.lazy_hive_lowering)
    assert_false(Bool(c.partition_filter))

    var with_f = ParquetReadOptions(
        True, False, True, True, Optional[Expr](_dt_is("2026-10-01"))
    )
    var want = _filter_text(with_f)
    var c2 = with_f.copy()
    assert_true(Bool(c2.partition_filter), "the filter is copied")
    assert_equal(_filter_text(c2), want)
    # A deep copy: replacing the original's filter leaves the copy's alone.
    with_f.partition_filter = Optional[Expr](_dt_is("other"))
    assert_equal(_filter_text(c2), want)


def test_with_eager_hive_lowering() raises:
    var o = ParquetReadOptions(False, True, True)
    var e = o.with_eager_hive_lowering()
    assert_false(e.lazy_hive_lowering, "lowering is eager")
    assert_false(e.union_by_name)
    assert_true(e.allow_empty_glob)
    assert_true(e.hive_partitioning)
    assert_false(Bool(e.partition_filter))
    assert_true(o.lazy_hive_lowering, "the original is unchanged")

    var f = ParquetReadOptions.default().with_partition_filter(_dt_is("x"))
    var ef = f.with_eager_hive_lowering()
    assert_false(ef.lazy_hive_lowering)
    assert_true(Bool(ef.partition_filter), "the filter is preserved")
    assert_equal(_filter_text(ef), _filter_text(f))


def test_with_partition_filter() raises:
    var o = ParquetReadOptions(False, True, False, False)
    var f = o.with_partition_filter(_dt_is("2026-10-02"))
    assert_true(Bool(f.partition_filter))
    assert_equal(_filter_text(f), String(_dt_is("2026-10-02")))
    assert_false(f.union_by_name)
    assert_true(f.allow_empty_glob)
    assert_false(f.hive_partitioning)
    assert_false(f.lazy_hive_lowering, "the flags are kept")
    assert_false(Bool(o.partition_filter), "the original has none")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
