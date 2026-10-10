# =============================================================================
# Tests for the partition_prune_scans optimizer
# rule (`komira_optimizer.partition_prune_scans`).
#
# Covers:
#   - partition-prune: a Filter on a partition column prunes the scan's
#     path list to the matching partitions; the conjunct is dropped.
# We assert the PRUNED PATH COUNT.
#
# Cases: ==, <, >=, !=, AND of two partition predicates, a mixed
# predicate (one partition conjunct + one residual conjunct), all-pruned
# (→ literal-FALSE filter), no-prunable-conjunct (plan unchanged), and a
# non-partitioned scan (plan unchanged).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_GE,
    BIN_AND,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_SCAN, PLAN_FILTER
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant
from komira_optimizer.partition_prune_scans import partition_prune_scans


# =============================================================================
# Builders
# =============================================================================


def _data_schema() -> Schema:
    """The DATA schema (columns in the parquet files)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, nullable=False))
    sb.add_field(Field("amount", ArrowType.FLOAT64, nullable=True))
    return sb.build()


def _full_schema(var partition_cols: List[Field]) -> Schema:
    """data schema + partition cols (the full scan output schema)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, nullable=False))
    sb.add_field(Field("amount", ArrowType.FLOAT64, nullable=True))
    for i in range(len(partition_cols)):
        sb.add_field(partition_cols[i].copy())
    return sb.build()


def _year_col() -> List[Field]:
    var c = List[Field]()
    c.append(Field("year", ArrowType.INT64, nullable=False))
    return c^


def _year_month_cols() -> List[Field]:
    var c = List[Field]()
    c.append(Field("year", ArrowType.INT64, nullable=False))
    c.append(Field("month", ArrowType.INT64, nullable=False))
    return c^


def _region_col() -> List[Field]:
    var c = List[Field]()
    c.append(Field("region", ArrowType.STRING, nullable=False))
    return c^


def _make_year_scan() raises -> LogicalPlan:
    """Scan over year=2022 .. 2025 (4 files), partition col `year:INT64`."""
    var paths = List[String]()
    paths.append(String("d/year=2022/f0.parquet"))
    paths.append(String("d/year=2023/f1.parquet"))
    paths.append(String("d/year=2024/f2.parquet"))
    paths.append(String("d/year=2025/f3.parquet"))
    var pvals = List[List[String]]()
    var v0 = List[String](); v0.append(String("2022")); pvals.append(v0^)
    var v1 = List[String](); v1.append(String("2023")); pvals.append(v1^)
    var v2 = List[String](); v2.append(String("2024")); pvals.append(v2^)
    var v3 = List[String](); v3.append(String("2025")); pvals.append(v3^)
    var pcols = _year_col()
    var full = _full_schema(pcols.copy())
    var src = ParquetSource.partitioned(
        paths^, _data_schema(), pcols^, pvals^, None, 0
    )
    return LogicalPlan.scan_from_source(SourceVariant(src^), full^)


def _make_year_month_scan() raises -> LogicalPlan:
    """Scan over (2023,01), (2023,06), (2024,01), (2024,12) — 4 files."""
    var paths = List[String]()
    paths.append(String("d/year=2023/month=01/a.parquet"))
    paths.append(String("d/year=2023/month=06/b.parquet"))
    paths.append(String("d/year=2024/month=01/c.parquet"))
    paths.append(String("d/year=2024/month=12/d.parquet"))
    var pvals = List[List[String]]()
    var v0 = List[String](); v0.append(String("2023")); v0.append(String("01")); pvals.append(v0^)
    var v1 = List[String](); v1.append(String("2023")); v1.append(String("06")); pvals.append(v1^)
    var v2 = List[String](); v2.append(String("2024")); v2.append(String("01")); pvals.append(v2^)
    var v3 = List[String](); v3.append(String("2024")); v3.append(String("12")); pvals.append(v3^)
    var pcols = _year_month_cols()
    var full = _full_schema(pcols.copy())
    var src = ParquetSource.partitioned(
        paths^, _data_schema(), pcols^, pvals^, None, 0
    )
    return LogicalPlan.scan_from_source(SourceVariant(src^), full^)


def _make_region_scan() raises -> LogicalPlan:
    var paths = List[String]()
    paths.append(String("d/region=us/a.parquet"))
    paths.append(String("d/region=eu/b.parquet"))
    paths.append(String("d/region=ap/c.parquet"))
    var pvals = List[List[String]]()
    var v0 = List[String](); v0.append(String("us")); pvals.append(v0^)
    var v1 = List[String](); v1.append(String("eu")); pvals.append(v1^)
    var v2 = List[String](); v2.append(String("ap")); pvals.append(v2^)
    var pcols = _region_col()
    var full = _full_schema(pcols.copy())
    var src = ParquetSource.partitioned(
        paths^, _data_schema(), pcols^, pvals^, None, 0
    )
    return LogicalPlan.scan_from_source(SourceVariant(src^), full^)


def _pruned_path_count(plan: LogicalPlan) raises -> Int:
    """Walk down to the (first) Scan and return its ParquetSource path count."""
    if plan.tag == PLAN_SCAN:
        return len(plan._scan.value()[].source._parquet.value().paths)
    if plan.tag == PLAN_FILTER:
        return _pruned_path_count(plan._filter.value()[].child[])
    raise Error("test: expected Filter-over-Scan or Scan, got tag=" + String(Int(plan.tag)))


def _eq_year(year: Int) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_int(year)))


# =============================================================================
# Prune cases
# =============================================================================


def test_prune_eq_keeps_one() raises:
    """`year == 2024` over 4 year-partitioned files → 1 file kept; Filter
    collapses (the only conjunct was the partition predicate)."""
    var scan = _make_year_scan()
    var filt = LogicalPlan.filter(_eq_year(2024), scan^)
    var out = partition_prune_scans(filt^)
    # Only conjunct was a partition predicate → Filter collapsed to Scan.
    assert_true(out.tag == PLAN_SCAN)
    assert_equal(_pruned_path_count(out), 1)
    assert_equal(out._scan.value()[].source._parquet.value().paths[0],
                 String("d/year=2024/f2.parquet"))


def test_prune_lt_keeps_two() raises:
    """`year < 2024` → 2022, 2023 kept (2 files)."""
    var scan = _make_year_scan()
    var pred = Expr.binary(BIN_LT, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_int(2024)))
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_true(out.tag == PLAN_SCAN)
    assert_equal(_pruned_path_count(out), 2)


def test_prune_ge_keeps_two() raises:
    """`year >= 2024` → 2024, 2025 kept (2 files)."""
    var scan = _make_year_scan()
    var pred = Expr.binary(BIN_GE, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_int(2024)))
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_equal(_pruned_path_count(out), 2)


def test_prune_ne_keeps_three() raises:
    """`year != 2023` → 2022, 2024, 2025 kept (3 files)."""
    var scan = _make_year_scan()
    var pred = Expr.binary(BIN_NE, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_int(2023)))
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_equal(_pruned_path_count(out), 3)


def test_prune_literal_on_left() raises:
    """`2024 == year` (literal on the left) — the op is flipped, still
    prunes to 1 file."""
    var scan = _make_year_scan()
    var pred = Expr.binary(BIN_EQ, Expr.literal(ScalarValue.from_int(2024)), Expr.col_ref(String("year")))
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_equal(_pruned_path_count(out), 1)


def test_prune_and_two_partition_cols() raises:
    """`year == 2024 AND month == "01"` (a string literal over the INT64
    `month`) over (year,month) partitions → 2 files."""
    var scan = _make_year_month_scan()
    var p1 = Expr.binary(BIN_EQ, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_int(2024)))
    var p2 = Expr.binary(BIN_EQ, Expr.col_ref(String("month")), Expr.literal(ScalarValue.from_string(String("01"))))
    # month col is INT64 here, but the literal is a string "01" → the rule
    # conservatively KEEPS files when the literal kind mismatches the col
    # type, so the month conjunct prunes nothing; only the year conjunct
    # prunes. Year==2024 keeps c.parquet + d.parquet → 2 files.
    var pred = Expr.binary(BIN_AND, p1^, p2^)
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_equal(_pruned_path_count(out), 2)


def test_prune_and_two_int_partition_cols() raises:
    """`year == 2024 AND month == 1` (both INT64 literals) → 1 file."""
    var scan = _make_year_month_scan()
    var p1 = Expr.binary(BIN_EQ, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_int(2024)))
    var p2 = Expr.binary(BIN_EQ, Expr.col_ref(String("month")), Expr.literal(ScalarValue.from_int(1)))
    var pred = Expr.binary(BIN_AND, p1^, p2^)
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    # Filter collapses (both conjuncts were partition predicates).
    assert_true(out.tag == PLAN_SCAN)
    assert_equal(_pruned_path_count(out), 1)
    assert_equal(out._scan.value()[].source._parquet.value().paths[0],
                 String("d/year=2024/month=01/c.parquet"))


def test_prune_string_partition() raises:
    """`region == 'eu'` over string-typed partition → 1 file."""
    var scan = _make_region_scan()
    var pred = Expr.binary(BIN_EQ, Expr.col_ref(String("region")), Expr.literal(ScalarValue.from_string(String("eu"))))
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_equal(_pruned_path_count(out), 1)
    assert_equal(out._scan.value()[].source._parquet.value().paths[0],
                 String("d/region=eu/b.parquet"))


def test_prune_with_residual_keeps_filter() raises:
    """`year == 2024 AND id > 100` — the `id > 100` conjunct is residual
    (not a partition col), so the Filter stays (with just `id > 100`) over
    the pruned (1-file) scan."""
    var scan = _make_year_scan()
    var p_part = Expr.binary(BIN_EQ, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_int(2024)))
    var p_resid = Expr.binary(BIN_GE, Expr.col_ref(String("id")), Expr.literal(ScalarValue.from_int(100)))
    var pred = Expr.binary(BIN_AND, p_part^, p_resid^)
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_true(out.tag == PLAN_FILTER)
    assert_equal(_pruned_path_count(out), 1)  # scan pruned to 1 file


def test_prune_all_files_pruned() raises:
    """`year == 1999` matches no partition → all files pruned. The rule
    keeps 1 (arbitrary) file + installs a literal-FALSE filter so the
    result is provably empty."""
    var scan = _make_year_scan()
    var filt = LogicalPlan.filter(_eq_year(1999), scan^)
    var out = partition_prune_scans(filt^)
    # No residual + all pruned → Filter kept with a FALSE predicate.
    assert_true(out.tag == PLAN_FILTER)
    assert_equal(_pruned_path_count(out), 1)


def test_no_prunable_conjunct_unchanged() raises:
    """`id > 100` (no partition col) → plan structurally unchanged: Filter
    over the full 4-file scan."""
    var scan = _make_year_scan()
    var pred = Expr.binary(BIN_GE, Expr.col_ref(String("id")), Expr.literal(ScalarValue.from_int(100)))
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_true(out.tag == PLAN_FILTER)
    assert_equal(_pruned_path_count(out), 4)


def test_non_partitioned_scan_unchanged() raises:
    """A Filter over a plain (non-partitioned) single-file scan is
    unchanged."""
    var src = ParquetSource(String("plain.parquet"), _data_schema())
    var scan = LogicalPlan.scan_from_source(SourceVariant(src^), _data_schema())
    var pred = Expr.binary(BIN_EQ, Expr.col_ref(String("id")), Expr.literal(ScalarValue.from_int(7)))
    var filt = LogicalPlan.filter(pred^, scan^)
    var out = partition_prune_scans(filt^)
    assert_true(out.tag == PLAN_FILTER)
    assert_equal(_pruned_path_count(out), 1)


def test_idempotent() raises:
    """Running the rule twice = running it once (no further pruning)."""
    var scan = _make_year_scan()
    var filt = LogicalPlan.filter(_eq_year(2024), scan^)
    var once = partition_prune_scans(filt^)
    var twice = partition_prune_scans(once^)
    assert_equal(_pruned_path_count(twice), 1)


def test_undecidable_conjunct_stays_on_the_filter() raises:
    """`year == '2032'` (a STRING literal) over an INT64 `year` partition
    with paths 2031 and 2032. The pass cannot compare the literal with the
    values, so it keeps both paths; the conjunct must then stay on the
    Filter, or the 2031 rows reach the output unfiltered.

    Catches: a conjunct dropped from the residual although no path's
    comparison was decided (wrong results, no error)."""
    var paths = List[String]()
    paths.append(String("d/year=2031/a.parquet"))
    paths.append(String("d/year=2032/b.parquet"))
    var pvals = List[List[String]]()
    var v0 = List[String](); v0.append(String("2031")); pvals.append(v0^)
    var v1 = List[String](); v1.append(String("2032")); pvals.append(v1^)
    var pcols = _year_col()
    var full = _full_schema(pcols.copy())
    var src = ParquetSource.partitioned(
        paths^, _data_schema(), pcols^, pvals^, None, 0
    )
    var scan = LogicalPlan.scan_from_source(SourceVariant(src^), full^)
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_string(String("2032")))
    )
    var out = partition_prune_scans(LogicalPlan.filter(pred^, scan^))
    assert_true(out.tag == PLAN_FILTER)
    assert_equal(_pruned_path_count(out), 2)
    ref kept = out._filter.value()[].predicate
    assert_true(kept.binary_op() == BIN_EQ)
    assert_equal(kept.binary_left_ref().col_ref_name(), String("year"))
    assert_true(kept.binary_right_ref().literal_value().is_string())

    # With a decidable conjunct beside it: the INT64 conjunct prunes 2031
    # and leaves the Filter; the undecidable one stays.
    var scan2 = _make_year_scan()
    var mixed = Expr.binary(
        BIN_AND,
        _eq_year(2024),
        Expr.binary(BIN_EQ, Expr.col_ref(String("year")), Expr.literal(ScalarValue.from_string(String("2024")))),
    )
    var out2 = partition_prune_scans(LogicalPlan.filter(mixed^, scan2^))
    assert_true(out2.tag == PLAN_FILTER)
    assert_equal(_pruned_path_count(out2), 1)
    ref kept2 = out2._filter.value()[].predicate
    assert_true(kept2.binary_op() == BIN_EQ)
    assert_true(kept2.binary_right_ref().literal_value().is_string())


def main() raises:
    var suite = TestSuite()
    suite.test[test_prune_eq_keeps_one]()
    suite.test[test_prune_lt_keeps_two]()
    suite.test[test_prune_ge_keeps_two]()
    suite.test[test_prune_ne_keeps_three]()
    suite.test[test_prune_literal_on_left]()
    suite.test[test_prune_and_two_partition_cols]()
    suite.test[test_prune_and_two_int_partition_cols]()
    suite.test[test_prune_string_partition]()
    suite.test[test_prune_with_residual_keeps_filter]()
    suite.test[test_prune_all_files_pruned]()
    suite.test[test_no_prunable_conjunct_unchanged]()
    suite.test[test_non_partitioned_scan_unchanged]()
    suite.test[test_idempotent]()
    suite.test[test_undecidable_conjunct_stays_on_the_filter]()
    suite^.run()
