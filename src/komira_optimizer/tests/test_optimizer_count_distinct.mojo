# =============================================================================
# optimizer_count_distinct: every accept and refuse of
# detect_count_distinct_agg_shape
# =============================================================================
#
# The scan below outputs k (INT64), k32 (INT32), d (DATE32), v (INT64) and
# s (STRING). DATE32 is the type that tells the two gates apart: a DATE32
# value is counted (int32 storage, an Int64 key channel), a DATE32 key is
# refused (the sink emits a key as INT32 or INT64 only).
#
# Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT_DISTINCT, AGG_SUM
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_AGGREGATE,
    PLAN_SCAN,
    SOURCE_CSV,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_count_distinct import (
    detect_count_distinct_agg_shape,
)


# =============================================================================
# Helpers
# =============================================================================


def _schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field("k", ArrowType.INT64, False))
    b.add_field(Field("k32", ArrowType.INT32, False))
    b.add_field(Field("d", ArrowType.DATE32, False))
    b.add_field(Field("v", ArrowType.INT64, False))
    b.add_field(Field("s", ArrowType.STRING, False))
    return b.build()


def _scan(source: UInt8 = SOURCE_PARQUET) -> LogicalPlan:
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rc: Optional[Int] = 100
    return LogicalPlan.scan("t", source, _schema(), proj^, filt^, rc^)


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _lit() -> Expr:
    return Expr.literal(ScalarValue.from_int(5))


def _cd(var arg: Expr) -> AggExpr:
    return AggExpr(AGG_COUNT_DISTINCT, Optional[Expr](arg^), Optional[String](String("n")))


def _aggs(var a: AggExpr) -> AggExprArray:
    var out = AggExprArray()
    out.append(a^)
    return out^


def _keys(names: List[String]) -> ExprArray:
    var out = ExprArray()
    for i in range(len(names)):
        out.append(_col(names[i]))
    return out^


def _agg(var keys: ExprArray, var aggs: AggExprArray, var child: LogicalPlan) raises -> LogicalPlan:
    return LogicalPlan.aggregate(keys^, aggs^, child^)


def _cd_of(var arg: Expr, var keys: ExprArray) raises -> LogicalPlan:
    """COUNT(DISTINCT arg) grouped by `keys` over the Parquet scan."""
    return _agg(keys^, _aggs(_cd(arg^)), _scan())


def _cd_by(key: Expr) raises -> LogicalPlan:
    """COUNT(DISTINCT v) grouped by the one key expression `key`."""
    var keys = ExprArray()
    keys.append(key.copy())
    return _cd_of(_col("v"), keys^)


# =============================================================================
# Accepted shapes
# =============================================================================


def test_accepts_ungrouped_and_single_integer_keys() raises:
    """COUNT(DISTINCT v) with no key, keyed by k (INT64), keyed by k32
    (INT32); two COUNT(DISTINCT)s (v and the DATE32 d) together. Catches:
    the ungrouped shape refused, either key type refused, a DATE32 value
    refused (the key gate applied to values), and a second aggregate
    refused."""
    assert_true(detect_count_distinct_agg_shape(_cd_of(_col("v"), ExprArray())))
    assert_true(detect_count_distinct_agg_shape(_cd_by(_col("k"))))
    assert_true(detect_count_distinct_agg_shape(_cd_by(_col("k32"))))
    var aggs = AggExprArray()
    aggs.append(_cd(_col("v")))
    aggs.append(_cd(_col("d")))
    assert_true(detect_count_distinct_agg_shape(_agg(ExprArray(), aggs^, _scan())))


def test_accepts_aliased_columns() raises:
    """The counted column and the key may each be an alias over a column.
    Catches: the alias arm of the column-name read removed."""
    assert_true(detect_count_distinct_agg_shape(
        _cd_of(Expr.alias(_col("v"), "vv"), ExprArray())
    ))
    assert_true(detect_count_distinct_agg_shape(_cd_by(Expr.alias(_col("k"), "kk"))))


# =============================================================================
# Refused: the node and the aggregate list
# =============================================================================


def test_refuses_a_node_that_is_not_an_aggregate() raises:
    """A scan, and an Aggregate node without its payload. Catches: the tag
    check removed, and the payload read without a presence check."""
    assert_false(detect_count_distinct_agg_shape(_scan()))
    assert_false(detect_count_distinct_agg_shape(LogicalPlan(PLAN_AGGREGATE, _schema())))


def test_refuses_two_keys_no_aggregate_and_a_mixed_list() raises:
    """Keys (k, k32); no aggregate; COUNT(DISTINCT v) beside SUM(v), in
    either order. Catches: the key-count limit widened, an empty aggregate
    list accepted, and the all-COUNT(DISTINCT) check reading only the
    first aggregate."""
    assert_false(detect_count_distinct_agg_shape(_cd_of(_col("v"), _keys(["k", "k32"]))))
    assert_false(detect_count_distinct_agg_shape(_agg(ExprArray(), AggExprArray(), _scan())))
    var cd_sum = AggExprArray()
    cd_sum.append(_cd(_col("v")))
    cd_sum.append(AggExpr(AGG_SUM, Optional[Expr](_col("v")), Optional[String](String("t"))))
    assert_false(detect_count_distinct_agg_shape(_agg(ExprArray(), cd_sum^, _scan())))
    var sum_cd = AggExprArray()
    sum_cd.append(AggExpr(AGG_SUM, Optional[Expr](_col("v")), Optional[String](String("t"))))
    sum_cd.append(_cd(_col("v")))
    assert_false(detect_count_distinct_agg_shape(_agg(ExprArray(), sum_cd^, _scan())))


# =============================================================================
# Refused: the counted columns
# =============================================================================


def test_refuses_a_counted_value_the_sink_cannot_read() raises:
    """COUNT(DISTINCT) of nothing, of a literal, of an alias over a
    literal, of a column the scan lacks, of the STRING s; and v then s
    (the second argument decides). Catches: a missing argument
    dereferenced or accepted, a non-column argument accepted, an unknown
    column accepted, the value-type gate removed, and the argument loop
    stopping at the first aggregate."""
    var none_arg: Optional[Expr] = None
    var no_arg = _aggs(AggExpr(AGG_COUNT_DISTINCT, none_arg^, Optional[String](String("n"))))
    assert_false(detect_count_distinct_agg_shape(_agg(ExprArray(), no_arg^, _scan())))
    assert_false(detect_count_distinct_agg_shape(_cd_of(_lit(), ExprArray())))
    assert_false(detect_count_distinct_agg_shape(_cd_of(Expr.alias(_lit(), "x"), ExprArray())))
    assert_false(detect_count_distinct_agg_shape(_cd_of(_col("absent"), ExprArray())))
    assert_false(detect_count_distinct_agg_shape(_cd_of(_col("s"), ExprArray())))
    var v_s = AggExprArray()
    v_s.append(_cd(_col("v")))
    v_s.append(_cd(_col("s")))
    assert_false(detect_count_distinct_agg_shape(_agg(ExprArray(), v_s^, _scan())))


def test_a_non_column_never_matches_an_unnamed_field() raises:
    """A scan whose only field is named "" (INT64): COUNT(DISTINCT 5) over
    it is refused. Catches: the empty-name guard removed (the literal's
    empty column name would match the unnamed field and be counted)."""
    var b = SchemaBuilder()
    b.add_field(Field("", ArrowType.INT64, False))
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rc: Optional[Int] = 10
    var scan = LogicalPlan.scan("u", SOURCE_PARQUET, b.build(), proj^, filt^, rc^)
    assert_false(detect_count_distinct_agg_shape(
        _agg(ExprArray(), _aggs(_cd(_lit())), scan^)
    ))


# =============================================================================
# Refused: the key
# =============================================================================


def test_refuses_a_key_the_sink_cannot_emit() raises:
    """Keyed by a literal, by a column the scan lacks, by the DATE32 d, by
    the STRING s. Catches: a non-column key accepted, an unknown key
    accepted, and the key-type gate removed or replaced by the value gate
    (which admits DATE32)."""
    assert_false(detect_count_distinct_agg_shape(_cd_by(_lit())))
    assert_false(detect_count_distinct_agg_shape(_cd_by(_col("absent"))))
    assert_false(detect_count_distinct_agg_shape(_cd_by(_col("d"))))
    assert_false(detect_count_distinct_agg_shape(_cd_by(_col("s"))))


# =============================================================================
# Refused: the child
# =============================================================================


def test_refuses_a_child_that_is_not_a_parquet_scan() raises:
    """A Filter between the scan and the aggregate, a CSV scan, and a scan
    node without its payload. Catches: the direct-scan check removed, the
    source check removed, and the scan payload read without a presence
    check."""
    var pred = Expr.binary(BIN_GT, _col("v"), _lit())
    var filtered = LogicalPlan.filter(pred^, _scan())
    assert_false(detect_count_distinct_agg_shape(
        _agg(ExprArray(), _aggs(_cd(_col("v"))), filtered^)
    ))
    assert_false(detect_count_distinct_agg_shape(
        _agg(ExprArray(), _aggs(_cd(_col("v"))), _scan(SOURCE_CSV))
    ))
    assert_false(detect_count_distinct_agg_shape(
        _agg(ExprArray(), _aggs(_cd(_col("v"))), LogicalPlan(PLAN_SCAN, _schema()))
    ))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
