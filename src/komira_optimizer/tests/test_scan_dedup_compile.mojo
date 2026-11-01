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
    CORR_KIND_EXISTS,
)

from komira_optimizer.scan_dedup_compile import (
    detect_duplicate_subtree_groups,
    count_all_subtree_occurrences,
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

    Proves: both join sides are counted, one occurrence each."""
    var p = _join(_scan(), _scan())
    assert_equal(detect_duplicate_subtree_groups(p), 1)
    assert_equal(count_all_subtree_occurrences(p, _scan().structural_hash()), 2)


def test_a_repeated_project_over_filter_over_scan_is_three_groups() raises:
    """Join(P(F(S)), P(F(S))) repeats three subtrees: the Project, the Filter
    below it and the scan below that, each exactly twice.

    Proves: nested subtrees are counted at every level, once per occurrence."""
    var p = _join(_proj(_filt()), _proj(_filt()))
    assert_equal(detect_duplicate_subtree_groups(p), 3)
    assert_equal(
        count_all_subtree_occurrences(p, _proj(_filt()).structural_hash()), 2
    )
    assert_equal(count_all_subtree_occurrences(p, _filt().structural_hash()), 2)
    assert_equal(count_all_subtree_occurrences(p, p.structural_hash()), 1)


def test_filters_with_different_predicates_are_not_one_group() raises:
    """Filter(v>10, S) and Filter(v>50, S) render differently, so each is
    seen once; only the bare scan under both is a repeat.

    Proves: two Filters with different predicates are different groups."""
    var p = _join(_filt(10), _filt(50))
    assert_equal(count_all_subtree_occurrences(p, _filt(10).structural_hash()), 1)
    assert_equal(count_all_subtree_occurrences(p, _filt(50).structural_hash()), 1)
    assert_equal(detect_duplicate_subtree_groups(p), 1)


def test_scans_of_different_sources_are_no_group() raises:
    var p = _join(_scan("a.parquet"), _scan("b.parquet"))
    assert_equal(detect_duplicate_subtree_groups(p), 0)
    assert_equal(count_all_subtree_occurrences(p, UInt64(12345)), 0)


def test_union_branches_are_walked() raises:
    """Union(F, F) repeats the Filter and the scan: two groups.

    Proves: union branches are entered and counted."""
    var p = _union(_filt(), _filt())
    assert_equal(detect_duplicate_subtree_groups(p), 2)


def test_a_repeated_udf_subtree_is_still_reported() raises:
    """Detection reports what the plan repeats, so two identical UDF Filters
    are one group (and the scan under them a second), unlike the pure-only
    count that `plan_cse` takes.

    Proves: a repeated UDF subtree is reported, because detection does not
    apply the purity filter."""
    var p = _join(_udf_filter(), _udf_filter())
    assert_equal(detect_duplicate_subtree_groups(p), 2)


def test_each_call_counts_from_zero() raises:
    """Two calls on two plans each see only their own plan: the second plan
    has no repeat and reports none after the first reported one.

    Proves: counts are not kept between calls."""
    var a = _join(_scan(), _scan())
    var b = _join(_scan("a.parquet"), _scan("b.parquet"))
    assert_equal(detect_duplicate_subtree_groups(a), 1)
    assert_equal(detect_duplicate_subtree_groups(b), 0)
    assert_equal(detect_duplicate_subtree_groups(a), 1)


def _exists_filter(var inner: LogicalPlan) -> LogicalPlan:
    var refs = List[String]()
    refs.append(String("k"))
    return LogicalPlan.filter(
        Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS), _scan()
    )


def test_detection_counts_subquery_filters_by_their_render() raises:
    """Proves: detection reports by hash alone, so two Filters that differ
    only in the inner plan of a subquery count as one repeated group (the
    rewrite in `plan_cse` refuses to share them)."""
    var a = _exists_filter(_scan("inner_a.parquet"))
    var b = _exists_filter(_scan("inner_b.parquet"))
    var h = a.structural_hash()
    var p = _join(a^, b^)
    assert_equal(count_all_subtree_occurrences(p, h), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
