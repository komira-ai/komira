# =============================================================================
# The shared-relation fingerprint must separate relations that produce
# different ROWS.
# =============================================================================
#
# `optimizer_shared_relation_cse` folds the two relations under a decorrelated
# scalar-subquery CROSS join into ONE materialized batch when their
# projection-insensitive fingerprints (`_relation_fingerprint`) are equal and
# one side's columns cover the other's. There is no second equality check: an
# equal fingerprint IS the decision, and `install_shared_cross_source` then
# replaces EVERY aggregate child with that fingerprint. Two relations that
# fingerprint equal but differ in rows give one aggregate the other's input --
# a silent wrong answer.
#
# Each test builds a CROSS of two aggregates whose relations differ in exactly
# one field the fingerprint used to skip; `detect_shared_cross_canonical` must
# DECLINE (return None):
#
#   * TopN `n` (and keys/direction): the TopN arm folded only its child.
#   * Limit `offset`: only `n` was folded.
#   * Sort direction under a Limit: only the key names were folded.
#   * TopN / Sort NULL placement (`nulls_first`): under a LIMIT, NULLS FIRST
#     and NULLS LAST keep different rows.
#   * Distinct over different projections: projection-insensitivity is only
#     sound when nothing above the pruned columns depends on them, and
#     DISTINCT does -- distinct (pk, v) rows are not distinct (v) rows.
#   * join keys whose concatenation agrees (`ab`=`c` vs `a`=`bc`): key names
#     were folded as raw bytes with no length or boundary.
#   * the UDF a Filter, Project or Aggregate carries: a UDF node's exprs are
#     placeholders (`lit(true)`, bare col-refs), so a fingerprint that reads
#     only the exprs gave two different UDFs, or a UDF and a plain
#     `lit(true)` Filter, one fingerprint. The other side's UDF never ran.
#
# The q11 positive cases (the fold still fires) live in
# `test_optimizer_shared_relation_cse_detect.mojo`.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import sum as agg_sum
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_KIND_FILTER,
    UDF_KIND_AGG,
)
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
    JOIN_CROSS,
    JOIN_INNER,
)
from komira_optimizer.optimizer_shared_relation_cse import (
    detect_shared_cross_canonical,
)


def _t_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return sb.build()


def _scan_t(var proj: List[String]) -> LogicalPlan:
    return LogicalPlan.scan(
        String("t.parquet"), SOURCE_PARQUET, _t_schema(), projection=Optional(proj^)
    )


def _wide() -> LogicalPlan:
    var p: List[String] = ["pk", "v"]
    return _scan_t(p^)


def _narrow() -> LogicalPlan:
    var p: List[String] = ["v"]
    return _scan_t(p^)


def _grouped(var rel: LogicalPlan) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("pk"))
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")).alias("pv"))
    return LogicalPlan.aggregate(gb^, aggs^, rel^)


def _total(var rel: LogicalPlan) -> LogicalPlan:
    var gb = ExprArray()
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")).alias("tot"))
    return LogicalPlan.aggregate(gb^, aggs^, rel^)


def _cross(var left: LogicalPlan, var right: LogicalPlan) -> LogicalPlan:
    var j = LogicalPlan.join(left^, right^, List[String](), List[String](), JOIN_CROSS)
    var pred = Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("tot"))
    return LogicalPlan.filter(pred^, j^)


def _keys_v() -> List[String]:
    var k: List[String] = ["v"]
    return k^


def _asc() -> List[Bool]:
    var d: List[Bool] = [False]
    return d^


def _desc() -> List[Bool]:
    var d: List[Bool] = [True]
    return d^


def _declines(plan: LogicalPlan, what: String) raises:
    var rel = detect_shared_cross_canonical(plan)
    assert_false(Bool(rel), what + ": the two relations produce different rows")


def test_topn_n_is_identity() raises:
    var plan = _cross(
        _grouped(LogicalPlan.topn(_keys_v(), _asc(), 5, _wide())),
        _total(LogicalPlan.topn(_keys_v(), _asc(), 10, _narrow())),
    )
    _declines(plan, "TopN 5 vs TopN 10")


def test_topn_direction_is_identity() raises:
    var plan = _cross(
        _grouped(LogicalPlan.topn(_keys_v(), _asc(), 5, _wide())),
        _total(LogicalPlan.topn(_keys_v(), _desc(), 5, _narrow())),
    )
    _declines(plan, "TopN ASC vs TopN DESC")


def test_limit_offset_is_identity() raises:
    var plan = _cross(
        _grouped(LogicalPlan.limit(5, _wide(), offset=0)),
        _total(LogicalPlan.limit(5, _narrow(), offset=5)),
    )
    _declines(plan, "LIMIT 5 vs LIMIT 5 OFFSET 5")


def test_sort_direction_under_a_limit_is_identity() raises:
    var plan = _cross(
        _grouped(LogicalPlan.limit(5, LogicalPlan.sort(_keys_v(), _asc(), _wide()))),
        _total(LogicalPlan.limit(5, LogicalPlan.sort(_keys_v(), _desc(), _narrow()))),
    )
    _declines(plan, "ORDER BY v ASC LIMIT 5 vs ORDER BY v DESC LIMIT 5")


def _nulls(first: Bool) -> Optional[List[Bool]]:
    var nf: List[Bool] = [first]
    return Optional(nf^)


def test_topn_nulls_first_is_identity() raises:
    var plan = _cross(
        _grouped(LogicalPlan.topn(_keys_v(), _asc(), 5, _wide(), _nulls(True))),
        _total(LogicalPlan.topn(_keys_v(), _asc(), 5, _narrow(), _nulls(False))),
    )
    _declines(plan, "TopN NULLS FIRST vs TopN NULLS LAST")


def test_sort_nulls_first_under_a_limit_is_identity() raises:
    var plan = _cross(
        _grouped(LogicalPlan.limit(5, LogicalPlan.sort(_keys_v(), _asc(), _wide(), _nulls(True)))),
        _total(LogicalPlan.limit(5, LogicalPlan.sort(_keys_v(), _asc(), _narrow(), _nulls(False)))),
    )
    _declines(plan, "ORDER BY v NULLS FIRST LIMIT 5 vs ORDER BY v NULLS LAST LIMIT 5")


def test_distinct_over_different_projections_is_identity() raises:
    var plan = _cross(
        _grouped(LogicalPlan.distinct(None, _wide())),
        _total(LogicalPlan.distinct(None, _narrow())),
    )
    _declines(plan, "DISTINCT (pk, v) vs DISTINCT (v)")


def _ab_c_schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, False))
    sb.add_field(Field(b, ArrowType.INT64, False))
    return sb.build()


def _keyed_join(l: String, r: String) -> LogicalPlan:
    # Left scan has columns a, ab; right scan has bc, c. Both joins output the
    # same four columns, so only the key pair tells them apart.
    var lon: List[String] = [l]
    var ron: List[String] = [r]
    return LogicalPlan.join(
        LogicalPlan.scan(String("l.parquet"), SOURCE_PARQUET, _ab_c_schema("a", "ab")),
        LogicalPlan.scan(String("r.parquet"), SOURCE_PARQUET, _ab_c_schema("bc", "c")),
        lon^,
        ron^,
        JOIN_INNER,
    )


def _agg_over(var rel: LogicalPlan, out_name: String, grouped: Bool) -> LogicalPlan:
    var gb = ExprArray()
    if grouped:
        gb.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("c")).alias(out_name))
    return LogicalPlan.aggregate(gb^, aggs^, rel^)


def test_join_keys_are_delimited() raises:
    var j = LogicalPlan.join(
        _agg_over(_keyed_join("ab", "c"), "pv", True),
        _agg_over(_keyed_join("a", "bc"), "tot", False),
        List[String](),
        List[String](),
        JOIN_CROSS,
    )
    var pred = Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("tot"))
    var plan = LogicalPlan.filter(pred^, j^)
    _declines(plan, "JOIN ON ab = c vs JOIN ON a = bc")


def test_equal_relations_still_fold() raises:
    # Control: the same TopN on both sides is one relation.
    var plan = _cross(
        _grouped(LogicalPlan.topn(_keys_v(), _asc(), 5, _wide())),
        _total(LogicalPlan.topn(_keys_v(), _asc(), 5, _narrow())),
    )
    assert_true(Bool(detect_shared_cross_canonical(plan)), "equal TopN relations fold")


# -----------------------------------------------------------------------------
# UDF identity. `_mk_udf` takes no variadic (a forwarded variadic String built
# a UdfData that crashed a later pass in another file's fixtures).
# -----------------------------------------------------------------------------


def _mk_udf(kind: UInt8, factory_id: UInt32, handle: Int) -> OwnedPointer[UdfData]:
    var ic = List[Tuple[String, UInt8]]()
    ic.append((String("v"), UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append((String("y"), UInt8(2)))
    return OwnedPointer(
        UdfData(
            kind=kind,
            name=String("f"),
            input_columns=ic^,
            output_columns=oc^,
            operator_factory_id=factory_id,
            call_site_salt=UInt32(5),
            registered_handle_id=Optional(handle),
        )
    )


def _true() -> Expr:
    return Expr.literal(ScalarValue.from_bool(True))


def _udf_filter(var rel: LogicalPlan, factory_id: UInt32, handle: Int) -> LogicalPlan:
    return LogicalPlan.filter_with_udf(_true(), rel^, _mk_udf(UDF_KIND_FILTER, factory_id, handle))


def _udf_project(var rel: LogicalPlan, wide: Bool, factory_id: UInt32) -> LogicalPlan:
    var exprs = ExprArray()
    if wide:
        exprs.append(Expr.col_ref("pk"))
    exprs.append(Expr.col_ref("v"))
    return LogicalPlan.project_with_udf(exprs^, rel^, _mk_udf(UDF_KIND_MAP, factory_id, 6))


def _udf_agg(var rel: LogicalPlan, factory_id: UInt32) -> LogicalPlan:
    """Aggregate[udf](pk; sum v AS v) over `rel`: outputs (pk, v), so the
    aggregates above it read it as they read the scan."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("pk"))
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")).alias("v"))
    return LogicalPlan.aggregate_with_udf(gb^, aggs^, rel^, _mk_udf(UDF_KIND_AGG, factory_id, 6))


def test_udf_filters_with_different_udfs_do_not_fold() raises:
    """Filter[udf 7101](lit true) vs Filter[udf 7102](lit true) over one
    table. Catches: the Filter arm not folding `FilterData.udf` (both sides
    read as `lit(true)`)."""
    var plan = _cross(
        _grouped(_udf_filter(_wide(), UInt32(7101), 6)),
        _total(_udf_filter(_narrow(), UInt32(7102), 6)),
    )
    _declines(plan, "Filter[udf 7101] vs Filter[udf 7102]")


def test_udf_filter_does_not_fold_with_a_plain_filter() raises:
    """Filter[udf](lit true) vs a plain Filter(lit true). Catches: the
    Filter arm not folding `FilterData.udf` (the UDF side reads as the
    plain filter, whose rows are every row)."""
    var plan = _cross(
        _grouped(_udf_filter(_wide(), UInt32(7101), 6)),
        _total(LogicalPlan.filter(_true(), _narrow())),
    )
    _declines(plan, "Filter[udf] vs Filter(lit true)")


def test_udf_projects_with_different_udfs_do_not_fold() raises:
    """Project[udf 7101](pk, v) vs Project[udf 7102](v). Catches: the
    Project arm not folding `ProjectData.udf` (its col-ref placeholders are
    skipped, so the two read as pure selects)."""
    var plan = _cross(
        _grouped(_udf_project(_wide(), True, UInt32(7101))),
        _total(_udf_project(_narrow(), False, UInt32(7102))),
    )
    _declines(plan, "Project[udf 7101] vs Project[udf 7102]")


def test_udf_aggregates_with_different_udfs_do_not_fold() raises:
    """Aggregate[udf 7101](pk; sum v) vs Aggregate[udf 7102](pk; sum v)
    under the two consumers. Catches: the Aggregate arm not folding
    `AggregateData.udf`."""
    var plan = _cross(
        _grouped(_udf_agg(_wide(), UInt32(7101))),
        _total(_udf_agg(_wide(), UInt32(7102))),
    )
    _declines(plan, "Aggregate[udf 7101] vs Aggregate[udf 7102]")


def test_udf_registered_handle_is_identity() raises:
    """The same UDF description bound to registered handles 6 and 9.
    Catches: the handle not folded (`UdfData.structural_hash` leaves it out,
    and two handles can name two different chains)."""
    var plan = _cross(
        _grouped(_udf_filter(_wide(), UInt32(7101), 6)),
        _total(_udf_filter(_narrow(), UInt32(7101), 9)),
    )
    _declines(plan, "the same UDF under handles 6 and 9")


def test_the_same_udf_and_plain_filters_still_fold() raises:
    """Controls, so the UDF tests above can fail: the same UDF Filter on
    both sides is one relation, and so are two plain `lit(true)` Filters.
    Catches: a fold that declines every UDF relation or folds an unstable
    value (an address)."""
    var same = _cross(
        _grouped(_udf_filter(_wide(), UInt32(7101), 6)),
        _total(_udf_filter(_narrow(), UInt32(7101), 6)),
    )
    assert_true(Bool(detect_shared_cross_canonical(same)), "the same UDF Filter folds")
    var plain = _cross(
        _grouped(LogicalPlan.filter(_true(), _wide())),
        _total(LogicalPlan.filter(_true(), _narrow())),
    )
    assert_true(Bool(detect_shared_cross_canonical(plain)), "plain lit(true) Filters fold")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
