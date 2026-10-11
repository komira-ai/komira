# =============================================================================
# extra_fixtures: the cases this package adds to the optimizer's table
# =============================================================================
#
# Built with the builders of fixtures.mojo. Each is a shape the optimizer's
# table does not hold, named for what it varies:
#   side_computed_*        a computed PROJECT expression first and in the
#                          middle, next to a pass-through `pv`: every
#                          expression of a PROJECT is checked;
#   side_*_scan            CSV, NDJSON (whose scan carries SOURCE_JSON) and
#                          ORC scans, each with a footer entry: only Parquet is
#                          admitted;
#   bounds_* / refuse_*    int32 scalar bounds (integers, so they narrow) and
#                          a string min (not an integer);
#   side_alias_rename_onto_scan_column
#                          `pv AS qq` over a scan that also has a nullable `qq`:
#                          the output column takes the bounds of the scan's
#                          `qq`, by name;
#   asof_*_then_join       a union, VIEW_REF or CSE_REF ahead of a join, so the
#                          join's scans sit at later pre-order indexes;
#   lone_scan, join_of_filtered_join_and_scan
#                          a plan without a join; a FILTER over a join as a side;
#   union_* / cast_sort_join
#                          a join two levels below a UNION or a CAST_TO_VARCHAR:
#                          the node between passes the not-decided state down;
#   refuse_no_*_key        no key on one side only, one on the other;
#   side_limit, side_sort  a LIMIT and a SORT side, which keep the scan's
#                          schema: only FILTER and PROJECT reach the scan.
# =============================================================================

from std.memory import OwnedPointer

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    SOURCE_CSV,
    SOURCE_NDJSON,
    JOIN_INNER,
)
from komira_plan_stats.table_stats import ColumnStats, TableStats
from komira_scan_source.orc_source import OrcSource
from komira_scan_source.source_variant import SourceVariant

from komira_lowering_rules_conformance.fixtures import (
    Col,
    parity_fixture,
    _int_stats,
    _c,
    _key,
    _cols2,
    _cols3,
    _scan,
    _schema,
    _table_stats,
    _side,
    _join,
    _keys,
    _outer,
    _good_right,
    _hc4p,
    _refused,
    _gt3,
    _p,
    _pv_plus_1,
    _asof,
    _sort_keys,
    _asc,
)


def extra_names() -> List[String]:
    """The names of the extra cases, in the golden file's order."""
    var n = List[String]()
    n.append("side_computed_first_passthrough")
    n.append("side_computed_middle")
    n.append("side_csv_scan")
    n.append("side_ndjson_scan")
    n.append("side_orc_scan")
    n.append("bounds_int32_scalar")
    n.append("refuse_string_min")
    n.append("side_alias_rename_onto_scan_column")
    n.append("asof_union_then_join")
    n.append("asof_view_ref_then_join")
    n.append("asof_cse_ref_then_join")
    n.append("lone_scan")
    n.append("join_of_filtered_join_and_scan")
    n.append("union_asof_join")
    n.append("union_filter_join")
    n.append("cast_sort_join")
    n.append("union_join_of_join")
    n.append("refuse_no_left_key")
    n.append("refuse_no_right_key")
    n.append("side_limit")
    n.append("side_sort")
    return n^


def _union2(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var ch = List[OwnedPointer[LogicalPlan]]()
    ch.append(OwnedPointer(a^))
    ch.append(OwnedPointer(b^))
    return LogicalPlan.union(ch^, schema^)


def _o() -> LogicalPlan:
    return _side("o.parquet", "ov", 1, 999)


def _non_parquet(source: UInt8) -> LogicalPlan:
    return _join(_scan("p", _cols2(_key(), _c("pv", 1, 999)), source), _good_right())


def _orc() raises -> LogicalPlan:
    """An ORC scan `(key, pv)` with footer bounds, built from its source
    variant (the positional `LogicalPlan.scan` has no ORC arm)."""
    var cols = _cols2(_key(), _c("pv", 1, 999))
    var src = SourceVariant(OrcSource(String("p.orc"), _schema(cols), List[Int]()))
    var scan = LogicalPlan.scan_from_source(
        src^, _schema(cols), table_stats=Optional[TableStats](_table_stats(cols))
    )
    return _join(scan^, _good_right())


def _computed(at: Int) -> LogicalPlan:
    """`[key, pv]` with `pv + 1 AS z` inserted at index `at`."""
    var pe = ExprArray()
    var plain = List[String]()
    plain.append(String("key"))
    plain.append(String("pv"))
    for i in range(3):
        if i == at:
            pe.append(Expr.alias(_pv_plus_1(), String("z")))
        else:
            pe.append(Expr.col_ref(plain[i if i < at else i - 1]))
    return _join(LogicalPlan.project(pe^, _p()), _good_right())


def _extra_fixture(name: String) raises -> Optional[LogicalPlan]:
    if name == "side_computed_first_passthrough":
        return _computed(0)
    if name == "side_computed_middle":
        return _computed(1)
    if name == "side_csv_scan":
        return _non_parquet(SOURCE_CSV)
    if name == "side_ndjson_scan":
        return _non_parquet(SOURCE_NDJSON)
    if name == "side_orc_scan":
        return _orc()
    if name == "bounds_int32_scalar":
        var cs = ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_int32(1)),
            Optional[ScalarValue](ScalarValue.from_int32(9)),
            Optional[Int](0),
        )
        return _refused(Col("rv", ArrowType.INT64, False, Optional[ColumnStats](cs^)))
    if name == "refuse_string_min":
        var cs = ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_string("1")),
            Optional[ScalarValue](ScalarValue.from_int64(9)),
            Optional[Int](0),
        )
        return _refused(Col("rv", ArrowType.INT64, False, Optional[ColumnStats](cs^)))
    if name == "side_alias_rename_onto_scan_column":
        var qq = Col("qq", ArrowType.INT64, True, Optional[ColumnStats](_int_stats(0, 3)))
        var scan = _scan("p.parquet", _cols3(_key(), _c("pv", 1, 999), qq^))
        var pe = ExprArray()
        pe.append(Expr.col_ref("key"))
        pe.append(Expr.alias(Expr.col_ref("pv"), String("qq")))
        return _join(LogicalPlan.project(pe^, scan^), _good_right())
    if name == "asof_union_then_join":
        return _asof(_union2(_good_right(), _good_right()), _hc4p())
    if name == "asof_view_ref_then_join":
        var v = LogicalPlan.view_ref(String("v"), _good_right().output_schema.copy())
        return _asof(v^, _hc4p())
    if name == "asof_cse_ref_then_join":
        var c = LogicalPlan.cse_ref(UInt64(7), _good_right().output_schema.copy())
        return _asof(c^, _hc4p())
    if name == "lone_scan":
        return _p()
    if name == "join_of_filtered_join_and_scan":
        return _join(LogicalPlan.filter(_gt3(), _hc4p()), _o())
    if name == "union_asof_join":
        return _union2(_asof(_hc4p(), _hc4p()), _hc4p())
    if name == "union_filter_join":
        return _union2(LogicalPlan.filter(_gt3(), _hc4p()), _hc4p())
    if name == "cast_sort_join":
        return LogicalPlan.cast_to_varchar(LogicalPlan.sort(_sort_keys(), _asc(), _hc4p()))
    if name == "union_join_of_join":
        return _union2(_join(_hc4p(), _o()), _join(_hc4p(), _o()))
    if name == "refuse_no_left_key":
        return _outer(LogicalPlan.join(_p(), _good_right(), List[String](), _keys(), JOIN_INNER))
    if name == "refuse_no_right_key":
        return _outer(LogicalPlan.join(_p(), _good_right(), _keys(), List[String](), JOIN_INNER))
    if name == "side_limit":
        return _join(LogicalPlan.limit(5, _p()), _good_right())
    if name == "side_sort":
        return _join(LogicalPlan.sort(_sort_keys(), _asc(), _p()), _good_right())
    return None


def build(name: String) raises -> LogicalPlan:
    """The fixture named `name`: one of the optimizer table's, or an extra."""
    var p = parity_fixture(name)
    if not p:
        p = _extra_fixture(name)
    if not p:
        raise Error("no fixture named `" + name + "`")
    return p.take()
