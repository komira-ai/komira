# =============================================================================
# test_optimizer_payload_narrow_parity -- the payload narrowing decisions,
# frozen as a table
# =============================================================================
#
# Runs `narrow_join_payload_inplace` on a set of fixture LogicalPlans and
# renders, for each fixture, every SCAN in pre-order (node, then children left
# to right; a UNION's children in order) as
#
#     scan#<i>: <column>:<bytes>:<base>,...
#
# with nothing after the colon when the scan carries no spec. Scans are joined
# by ` | `; a plan with no scan renders as the empty string. Each table row is
#
#     <fixture> => <rendering>
#
# The table (`_expected_table`) records what the rule does today, including
# the shapes it does not narrow. It is the parity oracle for moving the rule
# to host lowering: the host rule must reproduce every row from the same
# fixtures, after which this optimizer pass can be removed without changing
# a row. Rows are compared one by one and the row count is pinned. Each
# plan is built from its row's name, in table order, so a dropped row fails
# the count and a row with no builder fails with `no fixture named`;
# reordering rows does not fail and is not meant to.
#
# Fixture families:
#   hc4 / ladder_*  the hc4 shape and the width ladder boundaries, as payload
#                   ranges on the left side, next to a right side that narrows;
#   multi_* / key_* several payloads on one scan, and key exclusion by THIS
#                   side's key name only; payload_first_column puts the
#                   payload at schema and stats index 0;
#   refuse_*        one reason not to narrow, next to a sibling that narrows
#                   (on the same scan for a column refusal, on another join
#                   for a join refusal);
#   side_*          side shapes (Filter, pure Project, alias, computed, UDF);
#   walk_* / *_ref_* the walk: a join under every walked node kind, and under
#                   the kinds it does not walk (UNION, CAST_TO_VARCHAR). VIEW_REF
#                   and CSE_REF are leaves, so they appear as a leaf and as a
#                   join side;
#   nested_*        joins under joins, including an eligible join under a
#                   refused one (join type, residual, two keys);
#   multifile_*     stats folded by `merge_table_stats` (two files lose
#                   min/max and do not narrow; one file passes through).
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT, UN_NEGATE
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UdfData, UDF_KIND_MAP, DTAG_I64
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_TOPN,
    PLAN_DISTINCT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_CAST_TO_VARCHAR,
)
from komira_plan_stats.cardinality_estimator import merge_table_stats
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)

from komira_optimizer.optimizer_payload_narrow import (
    narrow_join_payload_inplace,
)


# =============================================================================
# The table
# =============================================================================

comptime _ROWS = 82


def _expected_table() -> String:
    return """
hc4 => scan#0: probe_val:2:1 | scan#1: build_val:2:1
ladder_0_255 => scan#0: pv:1:0 | scan#1: bv:2:1
ladder_0_256 => scan#0: pv:2:0 | scan#1: bv:2:1
ladder_0_65535 => scan#0: pv:2:0 | scan#1: bv:2:1
ladder_0_65536 => scan#0: pv:4:0 | scan#1: bv:2:1
ladder_0_4294967295 => scan#0: pv:4:0 | scan#1: bv:2:1
ladder_0_4294967296 => scan#0: | scan#1: bv:2:1
ladder_max_below_min => scan#0: | scan#1: bv:2:1
ladder_point => scan#0: pv:1:7 | scan#1: bv:2:1
ladder_far_base => scan#0: pv:1:1000000 | scan#1: bv:2:1
ladder_negative_base => scan#0: pv:2:-300 | scan#1: bv:2:1
ladder_pos_2p62 => scan#0: pv:1:4611686018427387904 | scan#1: bv:2:1
ladder_pos_over_2p62 => scan#0: | scan#1: bv:2:1
ladder_neg_2p62 => scan#0: pv:1:-4611686018427387904 | scan#1: bv:2:1
ladder_neg_over_2p62 => scan#0: | scan#1: bv:2:1
multi_payload_widths => scan#0: a:1:0,b:2:0,c:4:0 | scan#1: bv:2:1
key_names_per_side => scan#0: rk:1:0 | scan#1: x:2:0
payload_first_column => scan#0: pv:2:1 | scan#1: bv:2:1
refuse_nullable => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_stats_entry_missing => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_no_min => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_no_max => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_float_bounds => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_mixed_bounds_float_max => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_mixed_bounds_float_min => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_int32_declared => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_uint64_declared => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_float64_declared => scan#0: gv:2:5 | scan#1: bv:2:1
refuse_no_table_stats => scan#0: | scan#1: bv:2:1
refuse_non_parquet_side => scan#0: | scan#1: bv:2:1
refuse_left_join => scan#0: | scan#1: | scan#2: ov:2:1
refuse_semi_join => scan#0: | scan#1: | scan#2: ov:2:1
refuse_right_join => scan#0: | scan#1: | scan#2: ov:2:1
refuse_full_join => scan#0: | scan#1: | scan#2: ov:2:1
refuse_anti_join => scan#0: | scan#1: | scan#2: ov:2:1
refuse_cross_join => scan#0: | scan#1: | scan#2: ov:2:1
refuse_cross_join_no_keys => scan#0: | scan#1: | scan#2: ov:2:1
refuse_residual => scan#0: | scan#1: | scan#2: ov:2:1
refuse_two_key => scan#0: | scan#1: | scan#2: ov:2:1
refuse_two_left_keys => scan#0: | scan#1: | scan#2: ov:2:1
refuse_two_right_keys => scan#0: | scan#1: | scan#2: ov:2:1
refuse_no_keys => scan#0: | scan#1: | scan#2: ov:2:1
side_filter => scan#0: pv:2:1 | scan#1: bv:2:1
side_pure_project => scan#0: pv:2:1 | scan#1: bv:2:1
side_alias_same_name => scan#0: pv:2:1 | scan#1: bv:2:1
side_alias_rename => scan#0: | scan#1: bv:2:1
side_filter_project_filter => scan#0: pv:2:1 | scan#1: bv:2:1
side_project_project => scan#0: pv:2:1 | scan#1: bv:2:1
side_computed_project => scan#0: | scan#1: bv:2:1
side_computed_project_unaliased => scan#0: | scan#1: bv:2:1
side_computed_project_first => scan#0: | scan#1: bv:2:1
side_udf_project => scan#0: | scan#1: bv:2:1
side_aggregate => scan#0: | scan#1: bv:2:1
walk_filter => scan#0: pv:2:1 | scan#1: bv:2:1
walk_project => scan#0: pv:2:1 | scan#1: bv:2:1
walk_aggregate => scan#0: pv:2:1 | scan#1: bv:2:1
walk_sort => scan#0: pv:2:1 | scan#1: bv:2:1
walk_limit => scan#0: pv:2:1 | scan#1: bv:2:1
walk_topn => scan#0: pv:2:1 | scan#1: bv:2:1
walk_distinct => scan#0: pv:2:1 | scan#1: bv:2:1
walk_partition_by => scan#0: pv:2:1 | scan#1: bv:2:1
walk_partition_topn => scan#0: pv:2:1 | scan#1: bv:2:1
walk_asof_left => scan#0: pv:2:1 | scan#1: bv:2:1 | scan#2:
walk_asof_right => scan#0: | scan#1: pv:2:1 | scan#2: bv:2:1
walk_union => scan#0: | scan#1: | scan#2: | scan#3:
walk_union_one_branch => scan#0: | scan#1:
walk_cast_to_varchar => scan#0: | scan#1:
walk_union_under_join_side => scan#0: | scan#1: bv:2:1
view_ref_leaf =>
cse_ref_leaf =>
view_ref_side => scan#0: bv:2:1
cse_ref_side => scan#0: pv:2:1
nested_left => scan#0: pv:2:1 | scan#1: bv:2:1 | scan#2: ov:2:1
nested_right => scan#0: ov:2:1 | scan#1: pv:2:1 | scan#2: bv:2:1
nested_both => scan#0: pv:2:1 | scan#1: bv:2:1 | scan#2: qv:1:0 | scan#3: cv:2:0
nested_three_deep => scan#0: a:2:1 | scan#1: b:2:1 | scan#2: c:2:1 | scan#3: d:2:1
nested_under_left_join => scan#0: pv:2:1 | scan#1: bv:2:1 | scan#2:
nested_under_right_join => scan#0: | scan#1: pv:2:1 | scan#2: bv:2:1
nested_under_residual_join => scan#0: pv:2:1 | scan#1: bv:2:1 | scan#2:
nested_under_two_key_join => scan#0: | scan#1: k2:1:0,pv:2:1 | scan#2: bv:2:1
multifile_two_merged => scan#0: | scan#1: bv:2:1
multifile_one_passthrough => scan#0: pv:2:1 | scan#1: bv:2:1
"""


def _table_rows() -> List[String]:
    var out = List[String]()
    var parts = _expected_table().split("\n")
    for i in range(len(parts)):
        var line = String(parts[i])
        if line.byte_length() == 0:
            continue
        out.append(line^)
    return out^


def _row_name(row: String) raises -> String:
    var parts = row.split(" =>")
    if len(parts) != 2:
        raise Error("table row `" + row + "`: expected exactly one ` =>`")
    return String(parts[0])


# =============================================================================
# Rendering
# =============================================================================


def _collect(imm node: LogicalPlan, mut out: List[String]) raises:
    """Append one rendered line per SCAN under `node`, in pre-order."""
    if node.tag == PLAN_SCAN:
        var line = String("scan#") + String(len(out)) + String(":")
        if node._scan:
            ref pn = node.scan_data_ref().payload_narrow
            for i in range(len(pn)):
                line += String(" ") if i == 0 else String(",")
                line += (
                    pn[i].column_name + String(":")
                    + String(Int(pn[i].target_bytes)) + String(":")
                    + String(pn[i].base)
                )
        out.append(line^)
        return
    if node.tag == PLAN_FILTER and node._filter:
        _collect(node.filter_data_ref().child[], out)
    elif node.tag == PLAN_PROJECT and node._project:
        _collect(node.project_data_ref().child[], out)
    elif node.tag == PLAN_AGGREGATE and node._aggregate:
        _collect(node.aggregate_data_ref().child[], out)
    elif node.tag == PLAN_JOIN and node._join:
        _collect(node.join_data_ref().left[], out)
        _collect(node.join_data_ref().right[], out)
    elif node.tag == PLAN_SORT and node._sort:
        _collect(node.sort_data_ref().child[], out)
    elif node.tag == PLAN_LIMIT and node._limit:
        _collect(node.limit_data_ref().child[], out)
    elif node.tag == PLAN_TOPN and node._topn:
        _collect(node.topn_data_ref().child[], out)
    elif node.tag == PLAN_DISTINCT and node._distinct:
        _collect(node.distinct_data_ref().child[], out)
    elif node.tag == PLAN_PARTITION_BY and node._partition_by:
        _collect(node.partition_by_data_ref().child[], out)
    elif node.tag == PLAN_PARTITION_TOPN and node._partition_topn:
        _collect(node.partition_topn_data_ref().child[], out)
    elif node.tag == PLAN_ASOF_JOIN and node._asof_join:
        _collect(node.asof_join_data_ref().left[], out)
        _collect(node.asof_join_data_ref().right[], out)
    elif node.tag == PLAN_UNION and node._union:
        ref ch = node.union_data_ref().children
        for i in range(len(ch)):
            _collect(ch[i][], out)
    elif node.tag == PLAN_CAST_TO_VARCHAR and node._cast_to_varchar:
        _collect(node.cast_to_varchar_data_ref().child[], out)
    # VIEW_REF and CSE_REF are leaves with no scan under them.


def _render(imm plan: LogicalPlan) raises -> String:
    var lines = List[String]()
    _collect(plan, lines)
    var s = String()
    for i in range(len(lines)):
        if i > 0:
            s += String(" | ")
        s += lines[i]
    return s^


def _row(name: String, rendering: String) -> String:
    if rendering.byte_length() == 0:
        return name + String(" =>")
    return name + String(" => ") + rendering


# =============================================================================
# Scan builders
# =============================================================================


@fieldwise_init
struct Col(Copyable, Movable):
    """One scan column: declared type, nullability, and its footer stats
    entry (None: the column has no entry in `table_stats`)."""

    var name: String
    var t: ArrowType
    var nullable: Bool
    var stats: Optional[ColumnStats]


def _int_stats(lo: Int64, hi: Int64) -> ColumnStats:
    return ColumnStats(
        None,
        Optional[ScalarValue](ScalarValue.from_int64(lo)),
        Optional[ScalarValue](ScalarValue.from_int64(hi)),
        Optional[Int](0),
    )


def _c(name: String, lo: Int64, hi: Int64) -> Col:
    """A non-nullable INT64 column with integer footer bounds [lo, hi]."""
    return Col(name, ArrowType.INT64, False, Optional[ColumnStats](_int_stats(lo, hi)))


def _key() -> Col:
    return _c("key", 0, 24999999)


def _cols2(var a: Col, var b: Col) -> List[Col]:
    var l = List[Col]()
    l.append(a^)
    l.append(b^)
    return l^


def _cols3(var a: Col, var b: Col, var c: Col) -> List[Col]:
    var l = _cols2(a^, b^)
    l.append(c^)
    return l^


def _table_stats(imm cols: List[Col]) -> TableStats:
    var names = List[String]()
    var stats = List[ColumnStats]()
    for i in range(len(cols)):
        if cols[i].stats:
            names.append(cols[i].name)
            stats.append(cols[i].stats.value().copy())
    return TableStats(1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA)


def _schema(imm cols: List[Col]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(cols)):
        sb.add_field(Field(cols[i].name, cols[i].t, cols[i].nullable))
    return sb.build()


def _scan_ts(
    path: String, imm cols: List[Col], var ts: Optional[TableStats],
    source: UInt8 = SOURCE_PARQUET,
) -> LogicalPlan:
    return LogicalPlan.scan(path, source, _schema(cols), None, None, None, ts^)


def _scan(path: String, imm cols: List[Col], source: UInt8 = SOURCE_PARQUET) -> LogicalPlan:
    return _scan_ts(path, cols, Optional[TableStats](_table_stats(cols)), source)


def _side(path: String, pay: String, lo: Int64, hi: Int64) -> LogicalPlan:
    """A Parquet scan `(key, pay)` whose payload has footer bounds [lo, hi]."""
    return _scan(path, _cols2(_key(), _c(pay, lo, hi)))


def _keys() -> List[String]:
    var k = List[String]()
    k.append(String("key"))
    return k^


def _join(var l: LogicalPlan, var r: LogicalPlan, join_type: UInt8 = JOIN_INNER) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _keys(), _keys(), join_type)


def _good_right() -> LogicalPlan:
    return _side("b.parquet", "bv", 1, 9999)


def _hc4p() -> LogicalPlan:
    return _join(_side("p.parquet", "pv", 1, 999), _good_right())


def _ladder(lo: Int64, hi: Int64) -> LogicalPlan:
    return _join(_side("p.parquet", "pv", lo, hi), _good_right())


def _refused(var bad: Col) -> LogicalPlan:
    """Left scan `(key, rv, gv)`: `rv` has one reason not to narrow, `gv`
    [5, 300] narrows on the same scan; the right side narrows too."""
    var left = _scan("l.parquet", _cols3(_key(), bad^, _c("gv", 5, 300)))
    return _join(left^, _good_right())


def _outer(var inner: LogicalPlan) -> LogicalPlan:
    """`inner` as the left side of an INNER join whose right side narrows."""
    return _join(inner^, _side("o.parquet", "ov", 1, 999))


def _gt3() -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(3)))


def _project_key_pv(var child: LogicalPlan, var pv_expr: Expr) -> LogicalPlan:
    var pe = ExprArray()
    pe.append(Expr.col_ref("key"))
    pe.append(pv_expr^)
    return LogicalPlan.project(pe^, child^)


def _p() -> LogicalPlan:
    return _side("p.parquet", "pv", 1, 999)


def _pv_plus_1() -> Expr:
    return Expr.binary(BIN_ADD, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(1)))


# =============================================================================
# Fixtures, by table name
# =============================================================================


def _ladder_fixture(name: String) raises -> Optional[LogicalPlan]:
    var p62: Int64 = Int64(1) << 62
    if name == "ladder_0_255":
        return _ladder(0, 255)
    if name == "ladder_0_256":
        return _ladder(0, 256)
    if name == "ladder_0_65535":
        return _ladder(0, 65535)
    if name == "ladder_0_65536":
        return _ladder(0, 65536)
    if name == "ladder_0_4294967295":
        return _ladder(0, 4294967295)
    if name == "ladder_0_4294967296":
        return _ladder(0, 4294967296)
    if name == "ladder_max_below_min":
        return _ladder(10, 9)
    if name == "ladder_point":
        return _ladder(7, 7)
    if name == "ladder_far_base":
        return _ladder(1000000, 1000100)
    if name == "ladder_negative_base":
        return _ladder(-300, -1)
    if name == "ladder_pos_2p62":
        return _ladder(p62, p62)
    if name == "ladder_pos_over_2p62":
        return _ladder(p62 + 1, p62 + 1)
    if name == "ladder_neg_2p62":
        return _ladder(-p62, -p62)
    if name == "ladder_neg_over_2p62":
        return _ladder(-p62 - 1, -p62 - 1)
    if name == "payload_first_column":
        # The payload at schema and stats index 0, ahead of the key.
        return _join(_scan("p.parquet", _cols2(_c("pv", 1, 999), _key())), _good_right())
    if name == "multi_payload_widths":
        var cols = _cols3(_key(), _c("a", 0, 10), _c("b", 0, 1000))
        cols.append(_c("c", 0, 70000))
        cols.append(_c("d", 0, 4294967296))
        return _join(_scan("p.parquet", cols), _good_right())
    if name == "key_names_per_side":
        # Left keyed on `lk` carries a payload named `rk`, the RIGHT side's key.
        var left = _scan("l.parquet", _cols2(_c("lk", 0, 24999999), _c("rk", 0, 10)))
        var right = _scan("r.parquet", _cols2(_c("rk", 0, 24999999), _c("x", 0, 300)))
        var lk = List[String]()
        lk.append(String("lk"))
        var rk = List[String]()
        rk.append(String("rk"))
        return LogicalPlan.join(left^, right^, lk^, rk^, JOIN_INNER)
    return None


def _refusal_fixture(name: String) raises -> Optional[LogicalPlan]:
    var some = Optional[ColumnStats](_int_stats(1, 9))
    if name == "refuse_nullable":
        return _refused(Col("rv", ArrowType.INT64, True, some.copy()))
    if name == "refuse_stats_entry_missing":
        return _refused(Col("rv", ArrowType.INT64, False, None))
    if name == "refuse_no_min":
        var cs = ColumnStats(
            None, None, Optional[ScalarValue](ScalarValue.from_int64(9)), Optional[Int](0)
        )
        return _refused(Col("rv", ArrowType.INT64, False, Optional[ColumnStats](cs^)))
    if name == "refuse_no_max":
        var cs = ColumnStats(
            None, Optional[ScalarValue](ScalarValue.from_int64(1)), None, Optional[Int](0)
        )
        return _refused(Col("rv", ArrowType.INT64, False, Optional[ColumnStats](cs^)))
    if name == "refuse_float_bounds":
        var cs = ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_float(1.0)),
            Optional[ScalarValue](ScalarValue.from_float(9.0)),
            Optional[Int](0),
        )
        return _refused(Col("rv", ArrowType.INT64, False, Optional[ColumnStats](cs^)))
    if name == "refuse_mixed_bounds_float_max":
        var cs = ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_int64(1)),
            Optional[ScalarValue](ScalarValue.from_float(9.0)),
            Optional[Int](0),
        )
        return _refused(Col("rv", ArrowType.INT64, False, Optional[ColumnStats](cs^)))
    if name == "refuse_mixed_bounds_float_min":
        var cs = ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_float(1.0)),
            Optional[ScalarValue](ScalarValue.from_int64(9)),
            Optional[Int](0),
        )
        return _refused(Col("rv", ArrowType.INT64, False, Optional[ColumnStats](cs^)))
    if name == "refuse_int32_declared":
        return _refused(Col("rv", ArrowType.INT32, False, some.copy()))
    if name == "refuse_uint64_declared":
        return _refused(Col("rv", ArrowType.UINT64, False, some.copy()))
    if name == "refuse_float64_declared":
        return _refused(Col("rv", ArrowType.FLOAT64, False, some.copy()))
    if name == "refuse_no_table_stats":
        var cols = _cols2(_key(), _c("pv", 1, 999))
        return _join(_scan_ts("p.parquet", cols, None), _good_right())
    if name == "refuse_non_parquet_side":
        var cols = _cols2(_key(), _c("pv", 1, 999))
        return _join(_scan("mem", cols, SOURCE_IN_MEMORY), _good_right())
    if name == "refuse_left_join":
        return _outer(_join(_p(), _good_right(), JOIN_LEFT))
    if name == "refuse_semi_join":
        return _outer(_join(_p(), _good_right(), JOIN_SEMI))
    if name == "refuse_right_join":
        return _outer(_join(_p(), _good_right(), JOIN_RIGHT))
    if name == "refuse_full_join":
        return _outer(_join(_p(), _good_right(), JOIN_FULL))
    if name == "refuse_anti_join":
        return _outer(_join(_p(), _good_right(), JOIN_ANTI))
    if name == "refuse_cross_join":
        # One key per side, so only the join-type check refuses it.
        return _outer(_join(_p(), _good_right(), JOIN_CROSS))
    if name == "refuse_cross_join_no_keys":
        return _outer(
            LogicalPlan.join(
                _p(), _good_right(), List[String](), List[String](), JOIN_CROSS
            )
        )
    if name == "refuse_residual":
        var residual = Optional[OwnedPointer[Expr]](
            OwnedPointer(Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("bv")))
        )
        return _outer(
            LogicalPlan.join(
                _p(), _good_right(), _keys(), _keys(), JOIN_INNER, residual=residual^
            )
        )
    if name == "refuse_two_key":
        # Keys (key, k2) on both sides; pv and bv are payloads, not keys.
        var lcols = _cols3(_key(), _c("k2", 0, 9), _c("pv", 1, 999))
        var rcols = _cols3(_key(), _c("k2", 0, 9), _c("bv", 1, 9999))
        var l = _keys()
        l.append(String("k2"))
        var r = _keys()
        r.append(String("k2"))
        return _outer(
            LogicalPlan.join(
                _scan("l.parquet", lcols), _scan("r.parquet", rcols), l^, r^, JOIN_INNER
            )
        )
    if name == "refuse_two_left_keys":
        # (key, k2) on the left, one key on the right.
        var lcols = _cols3(_key(), _c("k2", 0, 9), _c("pv", 1, 999))
        var l = _keys()
        l.append(String("k2"))
        return _outer(
            LogicalPlan.join(_scan("l.parquet", lcols), _good_right(), l^, _keys(), JOIN_INNER)
        )
    if name == "refuse_two_right_keys":
        # One key on the left, (key, k2) on the right.
        var rcols = _cols3(_key(), _c("k2", 0, 9), _c("bv", 1, 9999))
        var r = _keys()
        r.append(String("k2"))
        return _outer(
            LogicalPlan.join(_p(), _scan("r.parquet", rcols), _keys(), r^, JOIN_INNER)
        )
    if name == "refuse_no_keys":
        # An INNER join with no equi-keys (a predicate join's shape).
        return _outer(
            LogicalPlan.join(
                _p(), _good_right(), List[String](), List[String](), JOIN_INNER
            )
        )
    return None


def _side_fixture(name: String) raises -> Optional[LogicalPlan]:
    if name == "side_filter":
        return _join(LogicalPlan.filter(_gt3(), _p()), _good_right())
    if name == "side_pure_project":
        return _join(_project_key_pv(_p(), Expr.col_ref("pv")), _good_right())
    if name == "side_alias_same_name":
        var e = Expr.alias(Expr.col_ref("pv"), String("pv"))
        return _join(_project_key_pv(_p(), e^), _good_right())
    if name == "side_alias_rename":
        var e = Expr.alias(Expr.col_ref("pv"), String("pv2"))
        return _join(_project_key_pv(_p(), e^), _good_right())
    if name == "side_filter_project_filter":
        var inner = _project_key_pv(LogicalPlan.filter(_gt3(), _p()), Expr.col_ref("pv"))
        return _join(LogicalPlan.filter(_gt3(), inner^), _good_right())
    if name == "side_project_project":
        var inner = _project_key_pv(_p(), Expr.col_ref("pv"))
        return _join(_project_key_pv(inner^, Expr.col_ref("pv")), _good_right())
    if name == "side_computed_project":
        # `-pv` aliased back to `pv`: type-preserving, so the Project field is
        # a non-nullable INT64 named like the scanned column.
        var e = Expr.alias(Expr.unary(UN_NEGATE, Expr.col_ref("pv")), String("pv"))
        return _join(_project_key_pv(_p(), e^), _good_right())
    if name == "side_computed_project_first":
        # The computed expr at Project index 0, ahead of the key.
        var pe = ExprArray()
        pe.append(Expr.alias(Expr.unary(UN_NEGATE, Expr.col_ref("pv")), String("pv")))
        pe.append(Expr.col_ref("key"))
        return _join(LogicalPlan.project(pe^, _p()), _good_right())
    if name == "side_computed_project_unaliased":
        var e = _pv_plus_1()
        return _join(_project_key_pv(_p(), e^), _good_right())
    if name == "side_udf_project":
        var in_cols = List[Tuple[String, UInt8]]()
        in_cols.append((String("pv"), DTAG_I64))
        var out_cols = List[Tuple[String, UInt8]]()
        out_cols.append((String("pv"), DTAG_I64))
        var udf = OwnedPointer(UdfData(UDF_KIND_MAP, String("m"), in_cols^, out_cols^, 1, 1))
        var pe = ExprArray()
        pe.append(Expr.col_ref("key"))
        pe.append(Expr.col_ref("pv"))
        return _join(LogicalPlan.project_with_udf(pe^, _p(), udf^), _good_right())
    if name == "side_aggregate":
        var gb = ExprArray()
        gb.append(Expr.col_ref("key"))
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("pv")))
        return _join(LogicalPlan.aggregate(gb^, aggs^, _p()), _good_right())
    return None


def _sort_keys() -> List[String]:
    var keys = List[String]()
    keys.append(String("pv"))
    return keys^


def _asc() -> List[Bool]:
    var desc = List[Bool]()
    desc.append(False)
    return desc^


def _asof(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.asof_join(
        l^, r^, List[String](), List[String](),
        String("key"), String("key"), ASOF_BACKWARD, AsofTolerance.none(),
    )


def _union_of_hc4(n: Int) -> LogicalPlan:
    var schema = _hc4p().output_schema.copy()
    var ch = List[OwnedPointer[LogicalPlan]]()
    for _ in range(n):
        ch.append(OwnedPointer(_hc4p()))
    return LogicalPlan.union(ch^, schema^)


def _walk_fixture(name: String) raises -> Optional[LogicalPlan]:
    if name == "walk_filter":
        return LogicalPlan.filter(Expr.col_ref("pv"), _hc4p())
    if name == "walk_project":
        var pe = ExprArray()
        pe.append(Expr.col_ref("pv"))
        return LogicalPlan.project(pe^, _hc4p())
    if name == "walk_aggregate":
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("s")))
        return LogicalPlan.aggregate(ExprArray(), aggs^, _hc4p())
    if name == "walk_sort":
        return LogicalPlan.sort(_sort_keys(), _asc(), _hc4p())
    if name == "walk_limit":
        return LogicalPlan.limit(5, _hc4p())
    if name == "walk_topn":
        return LogicalPlan.topn(_sort_keys(), _asc(), 5, _hc4p())
    if name == "walk_distinct":
        return LogicalPlan.distinct(None, _hc4p())
    if name == "walk_partition_by":
        return LogicalPlan.partition_by(
            List[String](), _sort_keys(), _asc(), List[PartitionExpr](), _hc4p()
        )
    if name == "walk_partition_topn":
        return LogicalPlan.partition_topn(_keys(), _sort_keys(), _asc(), 1, _hc4p())
    if name == "walk_asof_left":
        return _asof(_hc4p(), _side("r.parquet", "rv", 1, 999))
    if name == "walk_asof_right":
        return _asof(_side("r.parquet", "rv", 1, 999), _hc4p())
    if name == "walk_union":
        return _union_of_hc4(2)
    if name == "walk_union_one_branch":
        return _union_of_hc4(1)
    if name == "walk_cast_to_varchar":
        return LogicalPlan.cast_to_varchar(_hc4p())
    if name == "walk_union_under_join_side":
        var ch = List[OwnedPointer[LogicalPlan]]()
        ch.append(OwnedPointer(_p()))
        var schema = _p().output_schema.copy()
        return _join(LogicalPlan.union(ch^, schema^), _good_right())
    if name == "view_ref_leaf":
        return LogicalPlan.view_ref(String("v"), _p().output_schema.copy())
    if name == "cse_ref_leaf":
        return LogicalPlan.cse_ref(UInt64(42), _p().output_schema.copy())
    if name == "view_ref_side":
        var v = LogicalPlan.view_ref(String("v"), _p().output_schema.copy())
        return _join(v^, _good_right())
    if name == "cse_ref_side":
        var c = LogicalPlan.cse_ref(UInt64(42), _good_right().output_schema.copy())
        return _join(_p(), c^)
    return None


def _nested_fixture(name: String) raises -> Optional[LogicalPlan]:
    if name == "hc4":
        # The hc4 cell's measured ranges.
        return _join(
            _side("probe.parquet", "probe_val", 1, 999),
            _side("build.parquet", "build_val", 1, 9999),
        )
    if name == "nested_left":
        return _join(_hc4p(), _side("o.parquet", "ov", 1, 999))
    if name == "nested_right":
        return _join(_side("o.parquet", "ov", 1, 999), _hc4p())
    if name == "nested_both":
        var other = _join(_side("q.parquet", "qv", 0, 200), _side("c.parquet", "cv", 0, 300))
        return _join(_hc4p(), other^)
    if name == "nested_three_deep":
        var ab = _join(_side("a.parquet", "a", 1, 999), _side("b.parquet", "b", 1, 999))
        var abc = _join(ab^, _side("c.parquet", "c", 1, 999))
        return _join(abc^, _side("d.parquet", "d", 1, 999))
    # An eligible INNER join below a join the rule refuses: the inner join
    # still narrows and the refused join's own sides do not.
    if name == "nested_under_left_join":
        return _join(_hc4p(), _side("o.parquet", "ov", 1, 999), JOIN_LEFT)
    if name == "nested_under_right_join":
        return _join(_side("o.parquet", "ov", 1, 999), _hc4p(), JOIN_RIGHT)
    if name == "nested_under_residual_join":
        var residual = Optional[OwnedPointer[Expr]](
            OwnedPointer(Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("ov")))
        )
        return LogicalPlan.join(
            _hc4p(), _side("o.parquet", "ov", 1, 999), _keys(), _keys(), JOIN_INNER,
            residual=residual^,
        )
    if name == "nested_under_two_key_join":
        # Outer keys (key, k2); the inner join on the right joins on key
        # alone, so its k2 and pv are payloads.
        var ocols = _cols3(_key(), _c("k2", 0, 9), _c("ov", 1, 999))
        var pcols = _cols3(_key(), _c("k2", 0, 9), _c("pv", 1, 999))
        var inner = _join(_scan("p.parquet", pcols), _good_right())
        var l = _keys()
        l.append(String("k2"))
        var r = _keys()
        r.append(String("k2"))
        return LogicalPlan.join(_scan("o.parquet", ocols), inner^, l^, r^, JOIN_INNER)
    if name == "multifile_two_merged" or name == "multifile_one_passthrough":
        var per_file = List[TableStats]()
        per_file.append(_table_stats(_cols2(_key(), _c("pv", 1, 999))))
        if name == "multifile_two_merged":
            per_file.append(_table_stats(_cols2(_key(), _c("pv", 500, 1500))))
        var cols = _cols2(_key(), _c("pv", 1, 999))
        var ts = Optional[TableStats](merge_table_stats(per_file))
        return _join(_scan_ts("p.parquet", cols, ts^), _good_right())
    return None


def _build(name: String) raises -> LogicalPlan:
    var p = _ladder_fixture(name)
    if not p:
        p = _refusal_fixture(name)
    if not p:
        p = _side_fixture(name)
    if not p:
        p = _walk_fixture(name)
    if not p:
        p = _nested_fixture(name)
    if not p:
        raise Error("no fixture named `" + name + "`")
    return p.take()


# =============================================================================
# Tests
# =============================================================================


def _check_table(passes: Int) raises:
    """Build every fixture, run the rule `passes` times, compare to the table."""
    var rows = _table_rows()
    assert_equal(len(rows), _ROWS, "the table has a pinned number of rows")
    var actual = List[String]()
    for i in range(len(rows)):
        var name = _row_name(rows[i])
        var plan = _build(name)
        for _ in range(passes):
            _ = narrow_join_payload_inplace(plan)
        actual.append(_row(name, _render(plan)))
    # Print the whole actual table first, so a red run shows every row.
    for i in range(len(actual)):
        print("actual:", actual[i])
    for i in range(len(rows)):
        assert_equal(actual[i], rows[i], "parity row " + String(i))


def test_payload_narrow_parity_table() raises:
    _check_table(1)


def test_payload_narrow_parity_table_is_idempotent() raises:
    # A second pass replaces the stamp with the same verdict: same table.
    _check_table(2)


def test_table_names_are_unique() raises:
    var rows = _table_rows()
    for i in range(len(rows)):
        for j in range(i + 1, len(rows)):
            assert_equal(
                _row_name(rows[i]) == _row_name(rows[j]), False,
                "duplicate fixture name in row " + String(j),
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
