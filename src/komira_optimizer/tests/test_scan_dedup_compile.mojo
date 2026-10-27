# =============================================================================
# test_scan_dedup_compile.mojo -- detection of identical scan-bearing subtrees:
# what counts as a duplicate group and what does not.
#
# The detection never changes a plan, so each test builds a plan, asks for a
# count and compares it with an expected number worked out from the shape.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UdfData, UDF_KIND_FILTER
from komira_plan_ir.logical_plan import (
    ExprArray,
    LogicalPlan,
    JOIN_INNER,
    SOURCE_PARQUET,
)

from komira_optimizer.scan_dedup_compile import (
    detect_duplicate_subtree_groups,
    count_subtree_occurrences,
)


def _schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(String("k"), ArrowType.INT64, False))
    b.add_field(Field(String("v"), ArrowType.INT64, False))
    return b.build()


def _scan(path: String = String("t.parquet")) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema())


def _filt(n: Int = 10, path: String = String("t.parquet")) -> LogicalPlan:
    return LogicalPlan.filter(
        Expr.binary(
            BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(n))
        ),
        _scan(path),
    )


def _proj(var child: LogicalPlan) -> LogicalPlan:
    var ex = ExprArray()
    ex.append(Expr.col_ref("k"))
    return LogicalPlan.project(ex^, child^)


def _one(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _join(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(a^, b^, _one("k"), _one("k"), JOIN_INNER)


def _union(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def _udf_filter() -> LogicalPlan:
    var ic = List[Tuple[String, UInt8]]()
    ic.append((String("v"), UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append((String("y"), UInt8(2)))
    return LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)),
        _scan(),
        OwnedPointer(UdfData(UDF_KIND_FILTER, String("f"), ic^, oc^, 7101, 3)),
    )


def test_two_identical_scans_are_one_group_of_two() raises:
    """Join(S, S) holds one repeated group, the scan, seen twice.

    Defects caught: a count that skips one join side, or counts the scan once
    per parent."""
    var p = _join(_scan(), _scan())
    assert_equal(detect_duplicate_subtree_groups(p), 1)
    assert_equal(count_subtree_occurrences(p, _scan().structural_hash()), 2)


def test_a_repeated_project_over_filter_over_scan_is_three_groups() raises:
    """Join(P(F(S)), P(F(S))) repeats three subtrees: the Project, the Filter
    below it and the scan below that, each exactly twice.

    Defects caught: a walk that stops at the first level, or one that counts a
    nested subtree more often than it occurs."""
    var p = _join(_proj(_filt()), _proj(_filt()))
    assert_equal(detect_duplicate_subtree_groups(p), 3)
    assert_equal(
        count_subtree_occurrences(p, _proj(_filt()).structural_hash()), 2
    )
    assert_equal(count_subtree_occurrences(p, _filt().structural_hash()), 2)
    assert_equal(count_subtree_occurrences(p, p.structural_hash()), 1)


def test_filters_with_different_predicates_are_not_one_group() raises:
    """Filter(v>10, S) and Filter(v>50, S) render differently, so each is
    seen once; only the bare scan under both is a repeat.

    Defects caught: a key that ignores the predicate, which would merge two
    different row sets."""
    var p = _join(_filt(10), _filt(50))
    assert_equal(count_subtree_occurrences(p, _filt(10).structural_hash()), 1)
    assert_equal(count_subtree_occurrences(p, _filt(50).structural_hash()), 1)
    assert_equal(detect_duplicate_subtree_groups(p), 1)


def test_scans_of_different_sources_are_no_group() raises:
    var p = _join(_scan("a.parquet"), _scan("b.parquet"))
    assert_equal(detect_duplicate_subtree_groups(p), 0)
    assert_equal(count_subtree_occurrences(p, UInt64(12345)), 0)


def test_union_branches_are_walked() raises:
    """Union(F, F) repeats the Filter and the scan: two groups.

    Defects caught: a walk that does not enter union branches."""
    var p = _union(_filt(), _filt())
    assert_equal(detect_duplicate_subtree_groups(p), 2)


def test_a_repeated_udf_subtree_is_still_reported() raises:
    """Detection reports what the plan repeats, so two identical UDF Filters
    are one group (and the scan under them a second), unlike the pure-only
    count that `plan_cse` takes.

    Defects caught: detection silently applying the purity filter, which
    would hide a repeated UDF subtree from the report."""
    var p = _join(_udf_filter(), _udf_filter())
    assert_equal(detect_duplicate_subtree_groups(p), 2)


def test_each_call_counts_from_zero() raises:
    """Two calls on two plans each see only their own plan: the second plan
    has no repeat and reports none after the first reported one.

    Defects caught: counts kept between calls."""
    var a = _join(_scan(), _scan())
    var b = _join(_scan("a.parquet"), _scan("b.parquet"))
    assert_equal(detect_duplicate_subtree_groups(a), 1)
    assert_equal(detect_duplicate_subtree_groups(b), 0)
    assert_equal(detect_duplicate_subtree_groups(a), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
