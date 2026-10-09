# =============================================================================
# fixtures: the payload-narrowing fixture set
# =============================================================================
#
# Each case is a plan whose scans carry their statistics on the plan
# (`ScanData.table_stats`), which is what the optimizer rule reads, and the
# same statistics as the footer list the host rule reads (`case_footers`, in
# scan pre-order). The set moves one input at a time away from a base join
# that narrows, so that every condition of the rule decides at least one case:
#   left  scan: key (INT64), pv (INT64, [1, 999]), qv (INT64, [5, 9])
#   right scan: key (INT64), bv (INT64, [1, 9999])
# =============================================================================

from std.memory import OwnedPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.payload_narrow import PayloadNarrowSpec
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UdfData, UDF_KIND_MAP, DTAG_I64
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
    SOURCE_PARQUET,
    SOURCE_CSV,
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
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_CAST_TO_VARCHAR,
)
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)


struct NarrowCase(Movable):
    """One fixture: a name (the golden file's key) and a plan."""

    var name: String
    var plan: LogicalPlan

    def __init__(out self, var name: String, var plan: LogicalPlan):
        self.name = name^
        self.plan = plan^


@fieldwise_init
struct Col(Copyable, Movable):
    """One column of a fixture scan: its declared field and its statistics."""

    var name: String
    var arrow_type: ArrowType
    var nullable: Bool
    var in_stats: Bool
    var lo: Optional[ScalarValue]
    var hi: Optional[ScalarValue]


def _int(name: String, lo: Int64, hi: Int64) -> Col:
    return Col(
        name, ArrowType.INT64, False, True,
        Optional[ScalarValue](ScalarValue.from_int64(lo)),
        Optional[ScalarValue](ScalarValue.from_int64(hi)),
    )


def _left() -> List[Col]:
    var c = List[Col]()
    c.append(_int("key", 0, 24999999))
    c.append(_int("pv", 1, 999))
    c.append(_int("qv", 5, 9))
    return c^


def _right() -> List[Col]:
    var c = List[Col]()
    c.append(_int("key", 0, 24999999))
    c.append(_int("bv", 1, 9999))
    return c^


def _scan(cols: List[Col], source_type: UInt8 = SOURCE_PARQUET, with_stats: Bool = True) -> LogicalPlan:
    var sb = SchemaBuilder()
    var names = List[String]()
    var stats = List[ColumnStats]()
    for i in range(len(cols)):
        sb.add_field(Field(cols[i].name, cols[i].arrow_type, cols[i].nullable))
        if cols[i].in_stats:
            names.append(cols[i].name)
            stats.append(ColumnStats(None, cols[i].lo.copy(), cols[i].hi.copy(), Optional[Int](0)))
    var ts: Optional[TableStats] = None
    if with_stats:
        ts = Optional[TableStats](TableStats(1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA))
    return LogicalPlan.scan("t.parquet", source_type, sb.build(), None, None, None, ts^)


def _keys(name: String) -> List[String]:
    var k = List[String]()
    k.append(name)
    return k^


def _join(var l: LogicalPlan, var r: LogicalPlan, join_type: UInt8 = JOIN_INNER) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _keys("key"), _keys("key"), join_type)


def _base() -> LogicalPlan:
    return _join(_scan(_left()), _scan(_right()))


def _with_left(var left: List[Col]) -> LogicalPlan:
    return _join(_scan(left), _scan(_right()))


def _filter(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(3))), child^
    )


def _project(var child: LogicalPlan, var exprs: ExprArray) -> LogicalPlan:
    return LogicalPlan.project(exprs^, child^)


def _cols(a: String, b: String, c: String) -> ExprArray:
    var pe = ExprArray()
    pe.append(Expr.col_ref(a))
    pe.append(Expr.col_ref(b))
    pe.append(Expr.col_ref(c))
    return pe^


def _asof(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.asof_join(
        l^, r^, List[String](), List[String](),
        String("key"), String("key"), ASOF_BACKWARD, AsofTolerance.none(),
    )


def _union2(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def _over(kind: UInt8, var child: LogicalPlan) raises -> LogicalPlan:
    var keys = _keys("pv")
    var desc = List[Bool]()
    desc.append(False)
    if kind == PLAN_FILTER:
        return _filter(child^)
    if kind == PLAN_PROJECT:
        return _project(child^, _cols("pv", "qv", "bv"))
    if kind == PLAN_AGGREGATE:
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("s")))
        return LogicalPlan.aggregate(ExprArray(), aggs^, child^)
    if kind == PLAN_SORT:
        return LogicalPlan.sort(keys^, desc^, child^)
    if kind == PLAN_LIMIT:
        return LogicalPlan.limit(5, child^)
    if kind == PLAN_TOPN:
        return LogicalPlan.topn(keys^, desc^, 5, child^)
    if kind == PLAN_DISTINCT:
        return LogicalPlan.distinct(None, child^)
    if kind == PLAN_PARTITION_BY:
        return LogicalPlan.partition_by(List[String](), keys^, desc^, List[PartitionExpr](), child^)
    if kind == PLAN_PARTITION_TOPN:
        return LogicalPlan.partition_topn(_keys("key"), keys^, desc^, 1, child^)
    if kind == PLAN_CAST_TO_VARCHAR:
        return LogicalPlan.cast_to_varchar(child^)
    raise Error("fixtures: no wrapper for plan tag " + String(Int(kind)))


# =============================================================================
# The cases
# =============================================================================


def _column_cases(mut out: List[NarrowCase]):
    out.append(NarrowCase("base", _base()))
    out.append(NarrowCase(
        "right_key_is_bv",
        LogicalPlan.join(_scan(_left()), _scan(_right()), _keys("key"), _keys("bv"), JOIN_INNER),
    ))
    var c = _left()
    c[2].arrow_type = ArrowType.INT32
    out.append(NarrowCase("qv_declared_int32", _with_left(c^)))
    c = _left()
    c[1].nullable = True
    out.append(NarrowCase("pv_nullable", _with_left(c^)))
    out.append(NarrowCase("left_without_stats", _join(_scan(_left(), with_stats=False), _scan(_right()))))
    c = _left()
    c[1].in_stats = False
    out.append(NarrowCase("pv_absent_from_stats", _with_left(c^)))
    c = _left()
    c[1].lo = None
    out.append(NarrowCase("pv_without_min", _with_left(c^)))
    c = _left()
    c[1].hi = None
    out.append(NarrowCase("pv_without_max", _with_left(c^)))
    c = _left()
    c[1].lo = Optional[ScalarValue](ScalarValue.from_float(1.0))
    out.append(NarrowCase("pv_float_min", _with_left(c^)))
    c = _left()
    c[1].lo = Optional[ScalarValue](ScalarValue.from_int64(-5))
    c[1].hi = Optional[ScalarValue](ScalarValue.from_float(999.0))
    out.append(NarrowCase("pv_float_max", _with_left(c^)))
    c = _left()
    c[1].lo = Optional[ScalarValue](ScalarValue.from_int32(1))
    c[1].hi = Optional[ScalarValue](ScalarValue.from_int32(999))
    out.append(NarrowCase("pv_int32_bounds", _with_left(c^)))
    c = _left()
    c[1].lo = Optional[ScalarValue](ScalarValue.from_string("1"))
    out.append(NarrowCase("pv_string_min", _with_left(c^)))

    var w = List[Col]()
    w.append(_int("key", 0, 24999999))
    w.append(_int("a", -10, 245))
    w.append(_int("b", 0, 256))
    w.append(_int("c", 7, 65543))
    w.append(_int("d", 0, 4294967296))
    w.append(_int("e", 0, 4294967295))
    w.append(_int("f", 10, 9))
    w.append(_int("g", (Int64(1) << 62) - 10, Int64(1) << 62))
    w.append(_int("h", -(Int64(1) << 62) - 1, 0))
    w.append(_int("i", 42, 42))
    out.append(NarrowCase("width_ladder", _with_left(w^)))


def _join_cases(mut out: List[NarrowCase]):
    out.append(NarrowCase("join_left", _join(_scan(_left()), _scan(_right()), JOIN_LEFT)))
    out.append(NarrowCase("join_right", _join(_scan(_left()), _scan(_right()), JOIN_RIGHT)))
    out.append(NarrowCase("join_full", _join(_scan(_left()), _scan(_right()), JOIN_FULL)))
    out.append(NarrowCase("join_semi", _join(_scan(_left()), _scan(_right()), JOIN_SEMI)))
    out.append(NarrowCase("join_anti", _join(_scan(_left()), _scan(_right()), JOIN_ANTI)))
    out.append(NarrowCase("join_cross", _join(_scan(_left()), _scan(_right()), JOIN_CROSS)))
    var residual = Optional[OwnedPointer[Expr]](
        OwnedPointer(Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("bv")))
    )
    out.append(NarrowCase(
        "join_residual",
        LogicalPlan.join(
            _scan(_left()), _scan(_right()), _keys("key"), _keys("key"), JOIN_INNER, residual=residual^
        ),
    ))
    var two = _keys("key")
    two.append("pv")
    var two_r = _keys("key")
    two_r.append("bv")
    out.append(NarrowCase(
        "join_two_keys",
        LogicalPlan.join(_scan(_left()), _scan(_right()), two.copy(), two_r.copy(), JOIN_INNER),
    ))
    out.append(NarrowCase(
        "join_two_left_keys",
        LogicalPlan.join(_scan(_left()), _scan(_right()), two^, _keys("key"), JOIN_INNER),
    ))
    out.append(NarrowCase(
        "join_two_right_keys",
        LogicalPlan.join(_scan(_left()), _scan(_right()), _keys("key"), two_r^, JOIN_INNER),
    ))
    out.append(NarrowCase(
        "join_no_keys",
        LogicalPlan.join(_scan(_left()), _scan(_right()), List[String](), List[String](), JOIN_INNER),
    ))


def _side_cases(mut out: List[NarrowCase]):
    out.append(NarrowCase("side_filter", _join(_filter(_scan(_left())), _scan(_right()))))
    out.append(NarrowCase(
        "side_pure_project", _join(_project(_scan(_left()), _cols("key", "pv", "qv")), _scan(_right()))
    ))
    var pe = ExprArray()
    pe.append(Expr.col_ref("key"))
    pe.append(Expr.alias(Expr.col_ref("pv"), String("pv")))
    var chain = _project(_filter(_project(_filter(_scan(_left())), _cols("key", "pv", "qv"))), pe^)
    out.append(NarrowCase("side_alias_project_chain", _join(chain^, _scan(_right()))))

    # A rename: output `qq` is the scan's `pv`, and the scan also has a
    # nullable `qq` with bounds [0, 3]. The rule judges the output column and
    # looks its bounds up by the output name, so `qq`'s bounds, unrelated to
    # `pv` and those of a nullable column, are used.
    var r = _left()
    var qq = _int("qq", 0, 3)
    qq.nullable = True
    r.append(qq^)
    var pr = ExprArray()
    pr.append(Expr.col_ref("key"))
    pr.append(Expr.alias(Expr.col_ref("pv"), String("qq")))
    out.append(NarrowCase("side_alias_rename", _join(_project(_scan(r), pr^), _scan(_right()))))

    var pc = ExprArray()
    pc.append(Expr.col_ref("key"))
    pc.append(Expr.col_ref("pv"))
    pc.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("pv"), Expr.literal(ScalarValue.from_int(1))), String("z")))
    out.append(NarrowCase("side_computed_project", _join(_project(_scan(_left()), pc^), _scan(_right()))))

    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append((String("pv"), DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append((String("pv"), DTAG_I64))
    var udf = OwnedPointer(UdfData(UDF_KIND_MAP, String("m"), in_cols^, out_cols^, 1, 1))
    var with_udf = LogicalPlan.project_with_udf(_cols("key", "pv", "qv"), _scan(_left()), udf^)
    out.append(NarrowCase("side_udf_project", _join(with_udf^, _scan(_right()))))

    var gb = ExprArray()
    gb.append(Expr.col_ref("key"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("pv")), Optional[String]("pv")))
    out.append(NarrowCase(
        "side_aggregate", _join(LogicalPlan.aggregate(gb^, aggs^, _scan(_left())), _scan(_right()))
    ))
    out.append(NarrowCase("side_csv_scan", _join(_scan(_left(), SOURCE_CSV), _scan(_right()))))


def _walk_cases(mut out: List[NarrowCase]) raises:
    var kinds = List[UInt8]()
    kinds.append(PLAN_FILTER)
    kinds.append(PLAN_PROJECT)
    kinds.append(PLAN_AGGREGATE)
    kinds.append(PLAN_SORT)
    kinds.append(PLAN_LIMIT)
    kinds.append(PLAN_TOPN)
    kinds.append(PLAN_DISTINCT)
    kinds.append(PLAN_PARTITION_BY)
    kinds.append(PLAN_PARTITION_TOPN)
    kinds.append(PLAN_CAST_TO_VARCHAR)
    var names = List[String]()
    names.append("under_filter")
    names.append("under_project")
    names.append("under_aggregate")
    names.append("under_sort")
    names.append("under_limit")
    names.append("under_topn")
    names.append("under_distinct")
    names.append("under_partition_by")
    names.append("under_partition_topn")
    names.append("under_cast_to_varchar")
    for i in range(len(kinds)):
        out.append(NarrowCase(names[i], _over(kinds[i], _base())))
    out.append(NarrowCase("under_union", _union2(_base(), _base())))
    out.append(NarrowCase("asof_of_joins", _asof(_base(), _base())))
    var o = List[Col]()
    o.append(_int("key", 0, 24999999))
    o.append(_int("ov", -5, 5))
    out.append(NarrowCase("join_of_join_and_scan", _join(_base(), _scan(o.copy()))))
    out.append(NarrowCase("join_of_filtered_join_and_scan", _join(_filter(_base()), _scan(o^))))
    out.append(NarrowCase("asof_union_then_join", _asof(_union2(_scan(_right()), _scan(_right())), _base())))
    out.append(NarrowCase(
        "asof_view_ref_then_join",
        _asof(LogicalPlan.view_ref("v", _scan(_right()).output_schema.copy()), _base()),
    ))
    out.append(NarrowCase(
        "asof_cse_ref_then_join",
        _asof(LogicalPlan.cse_ref(7, _scan(_right()).output_schema.copy()), _base()),
    ))
    out.append(NarrowCase("lone_scan", _scan(_left())))
    # A join two levels below a UNION or a CAST_TO_VARCHAR: the node between
    # them must pass the not-decided state down, not reset it.
    out.append(NarrowCase("union_asof_join", _union2(_asof(_base(), _base()), _base())))
    out.append(NarrowCase("union_filter_join", _union2(_filter(_base()), _base())))
    out.append(NarrowCase("cast_sort_join", _over(PLAN_CAST_TO_VARCHAR, _over(PLAN_SORT, _base()))))
    var o2 = List[Col]()
    o2.append(_int("key", 0, 24999999))
    o2.append(_int("ov", -5, 5))
    var jj = _join(_base(), _scan(o2.copy()))
    out.append(NarrowCase("union_join_of_join", _union2(jj^, _join(_base(), _scan(o2^)))))


def cases() raises -> List[NarrowCase]:
    """Every fixture, in the golden file's order."""
    var out = List[NarrowCase]()
    _column_cases(out)
    _join_cases(out)
    _side_cases(out)
    _walk_cases(out)
    return out^


# =============================================================================
# The footer list of a case, and the rendering
# =============================================================================


def _collect_stats(node: LogicalPlan, mut out: List[Optional[TableStats]]) raises:
    """Each scan's plan statistics in scan pre-order, by a walk written apart
    from the rule's (the tags the fixtures use)."""
    if node.tag == PLAN_SCAN:
        out.append(node.scan_data_ref().table_stats.copy())
    elif node.tag == PLAN_JOIN:
        _collect_stats(node.join_data_ref().left[], out)
        _collect_stats(node.join_data_ref().right[], out)
    elif node.tag == PLAN_ASOF_JOIN:
        _collect_stats(node.asof_join_data_ref().left[], out)
        _collect_stats(node.asof_join_data_ref().right[], out)
    elif node.tag == PLAN_UNION:
        ref kids = node.union_data_ref().children
        for i in range(len(kids)):
            _collect_stats(kids[i][], out)
    elif node.tag == PLAN_FILTER:
        _collect_stats(node.filter_data_ref().child[], out)
    elif node.tag == PLAN_PROJECT:
        _collect_stats(node.project_data_ref().child[], out)
    elif node.tag == PLAN_AGGREGATE:
        _collect_stats(node.aggregate_data_ref().child[], out)
    elif node.tag == PLAN_SORT:
        _collect_stats(node.sort_data_ref().child[], out)
    elif node.tag == PLAN_LIMIT:
        _collect_stats(node.limit_data_ref().child[], out)
    elif node.tag == PLAN_DISTINCT:
        _collect_stats(node.distinct_data_ref().child[], out)
    elif node.tag == PLAN_TOPN:
        _collect_stats(node.topn_data_ref().child[], out)
    elif node.tag == PLAN_PARTITION_BY:
        _collect_stats(node.partition_by_data_ref().child[], out)
    elif node.tag == PLAN_PARTITION_TOPN:
        _collect_stats(node.partition_topn_data_ref().child[], out)
    elif node.tag == PLAN_CAST_TO_VARCHAR:
        _collect_stats(node.cast_to_varchar_data_ref().child[], out)


def case_footers(plan: LogicalPlan) raises -> List[Optional[TableStats]]:
    """The footer list the host rule takes for `plan`: each scan's plan
    statistics, in scan pre-order."""
    var out = List[Optional[TableStats]]()
    _collect_stats(plan, out)
    return out^


def render_slot(specs: List[PayloadNarrowSpec]) -> String:
    """One scan's specs as `[name:bytes:base ...]`."""
    var out = String("[")
    for i in range(len(specs)):
        if i > 0:
            out += " "
        out += specs[i].column_name + ":" + String(Int(specs[i].target_bytes)) + ":" + String(specs[i].base)
    out += "]"
    return out^


def render(slots: List[List[PayloadNarrowSpec]]) -> String:
    """Every scan's slot in scan pre-order, separated by one space."""
    var out = String()
    for s in range(len(slots)):
        if s > 0:
            out += " "
        out += render_slot(slots[s])
    return out^
