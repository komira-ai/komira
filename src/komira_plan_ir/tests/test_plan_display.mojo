# =============================================================================
# The plan render: `plan_display._write_plan_node` and its name ladders
# =============================================================================
#
# The render is EXPLAIN's text and the input to `LogicalPlan.structural_hash`
# (the plan-compile cache key), so every case here asserts the WHOLE rendered
# text, worked out from the code: the node's own line, its fields in order,
# the two-space indent per depth and each child's line.
#
# Values a node does not own are taken from their owner: an in-memory scan's
# `inmem_id=` is `SourceVariant.structural_id()`, a binding's `bid=` is
# `ScanBinding.identity_hash()`, a UDF's text is `UdfData`'s own render and a
# window function's is `PartitionExpr`'s. The render's contract is that it
# writes those values at those positions; their own computation is tested by
# their own modules.
#
# THE CHEAP KEY. `placeholder_inmem_id=True` replaces the kind-supplied
# content identity (`inmem_id=`, `bsid=`) with `*` and changes nothing else.
# Each node kind with a child is rendered both ways over an in-memory leaf (a
# join and an as-of join with the leaf on each side), so a recursive call that
# drops the flag shows up as a real id under that node kind.
#
# Test groups:
#   1. The scan leaf: parquet, projection and filter, in-memory, binding
#      backed (and one declaring IN_MEMORY), every source type and kind name.
#   2. Every node kind: each field it writes, each optional field present and
#      absent, every name ladder value including the one with no name.
#   3. The unknown tag and the indent argument.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM
from komira_plan_expr.expr import Expr
from komira_plan_expr.partition_expr import PartitionExpr, PF_RANK
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_AGG,
    UDF_NULL_PROPAGATE,
    UDF_STABILITY_IMMUTABLE,
    UDF_PAR_MERGEABLE,
    DTAG_I64,
    DTAG_F64,
)
from komira_plan_ir.logical_plan import (
    AsofTolerance,
    LogicalPlan,
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_ALGO_HASH,
    JOIN_ALGO_SORT_MERGE,
    SOURCE_PARQUET,
    SOURCE_CSV,
    SOURCE_NDJSON,
    SOURCE_IN_MEMORY,
    SOURCE_JSON,
    SOURCE_ORC,
    SOURCE_AVRO,
    SOURCE_ARROW,
)
from komira_plan_ir.plan_display import _write_plan_node
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_LEGACY_SOURCE_TYPE_NONE,
    SCAN_ORIENTATION_COLUMNAR,
    SCAN_ORIENTATION_ROW,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import SourceVariant


# =============================================================================
# Fixtures
# =============================================================================


comptime P = 'Scan(path="t.parquet", type=PARQUET, source_kind=COLUMNAR)\n'
"""The render of `_parquet()`."""

comptime IM_CHEAP = (
    'Scan(path="reg", type=IN_MEMORY, inmem_id=*, source_kind=COLUMNAR)\n'
)
"""The placeholdered render of `_im()`."""


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.INT64, nullable=False))
    return sb.build()


def _parquet() -> LogicalPlan:
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _schema())


def _im() -> LogicalPlan:
    """An in-memory scan named `reg` with no batches. Every `_im()` has the
    same content, so the same `structural_id()`."""
    return LogicalPlan.scan(String("reg"), SOURCE_IN_MEMORY, _schema())


def _im_real() -> String:
    """The unplaceholdered render of `_im()`: its id is the source's own."""
    var leaf = _im()
    return (
        String('Scan(path="reg", type=IN_MEMORY, inmem_id=')
        + String(leaf._scan.value()[].source.structural_id())
        + String(", source_kind=COLUMNAR)\n")
    )


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _render(plan: LogicalPlan) -> String:
    return String(plan)


def _cheap(plan: LogicalPlan) -> String:
    var s = String()
    _write_plan_node(s, plan, 0, placeholder_inmem_id=True)
    return s^


def _both(plan: LogicalPlan, head: String) raises:
    """`plan` renders as `head` over one in-memory leaf at depth 1, with the
    leaf's real id, and with `*` under the cheap key."""
    assert_equal(_render(plan), head + String("  ") + _im_real())
    assert_equal(_cheap(plan), head + String("  ") + String(IM_CHEAP))


def _keys() -> List[String]:
    var k = List[String]()
    k.append(String("a"))
    k.append(String("b"))
    return k^


def _asc_desc() -> List[Bool]:
    var d = List[Bool]()
    d.append(False)
    d.append(True)
    return d^


def _binding(
    legacy: UInt8 = SCAN_LEGACY_SOURCE_TYPE_NONE,
    orientation: UInt8 = SCAN_ORIENTATION_COLUMNAR,
) -> ScanBinding:
    return ScanBinding(
        kind_id=scan_kind_id(String("example.disp.kind")),
        kind_name=String("example.disp.kind"),
        name=String("leaf1"),
        params=ScanParams(),
        schema=_schema(),
        fingerprint=UInt64(41),
        structural_id=UInt64(4242),
        gate=PushdownGate.reject_all(),
        orientation=orientation,
        legacy_source_type=legacy,
    )


def _bscan(var b: ScanBinding) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(SourceVariant.from_binding(b^), _schema())


def _bid() -> String:
    return String(_binding().identity_hash())


# =============================================================================
# 1. The scan leaf
# =============================================================================


def test_a_parquet_scan_renders_path_type_and_kind() raises:
    assert_equal(_render(_parquet()), String(P))
    # A file scan has no kind-supplied identity: the cheap key is the same.
    assert_equal(_cheap(_parquet()), String(P))


def test_a_scan_renders_its_projection_and_filter() raises:
    var proj = List[String]()
    proj.append(String("b"))
    proj.append(String("a"))
    var plan = LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _schema(),
        projection=Optional[List[String]](proj^),
        filter=Optional[Expr](_col("a")),
    )
    assert_equal(
        _render(plan),
        String(
            'Scan(path="t.parquet", type=PARQUET, source_kind=COLUMNAR,'
            " projection=[b, a], filter=ColRef(a))\n"
        ),
    )
    var one = List[String]()
    one.append(String("a"))
    var p1 = LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _schema(),
        projection=Optional[List[String]](one^),
    )
    assert_equal(
        _render(p1),
        String(
            'Scan(path="t.parquet", type=PARQUET, source_kind=COLUMNAR,'
            " projection=[a])\n"
        ),
    )


def test_an_inmem_scan_renders_its_content_id_or_the_placeholder() raises:
    assert_equal(_render(_im()), _im_real())
    assert_equal(_cheap(_im()), String(IM_CHEAP))


def test_a_binding_backed_scan_renders_binding_bsid_and_bid() raises:
    var plan = _bscan(_binding())
    assert_equal(
        _render(plan),
        String('Scan(path="leaf1", type=BINDING, binding=example.disp.kind(leaf1),')
        + String(" bsid=4242, bid=")
        + _bid()
        + String(", source_kind=COLUMNAR)\n"),
    )
    # `bsid=` is placeholdered; `bid=` never is.
    assert_equal(
        _cheap(plan),
        String('Scan(path="leaf1", type=BINDING, binding=example.disp.kind(leaf1),')
        + String(" bsid=*, bid=")
        + _bid()
        + String(", source_kind=COLUMNAR)\n"),
    )


def test_a_binding_declaring_in_memory_emits_its_identity_once() raises:
    """`type=IN_MEMORY`, yet no `inmem_id=`: the binding's `bsid=` is its one
    content identity."""
    var plan = _bscan(_binding(legacy=SOURCE_IN_MEMORY))
    assert_equal(
        _render(plan),
        String('Scan(path="leaf1", type=IN_MEMORY, binding=example.disp.kind(leaf1),')
        + String(" bsid=4242, bid=")
        + String(_binding(legacy=SOURCE_IN_MEMORY).identity_hash())
        + String(", source_kind=COLUMNAR)\n"),
    )


def _type_line(
    legacy: UInt8, orientation: UInt8, type_name: String, kind_name: String
) raises:
    """A binding declaring `legacy` renders `type=<type_name>` and
    `source_kind=<kind_name>`."""
    var b = _binding(legacy=legacy, orientation=orientation)
    var bid = String(b.identity_hash())
    assert_equal(
        _render(_bscan(b^)),
        String('Scan(path="leaf1", type=')
        + type_name
        + String(", binding=example.disp.kind(leaf1), bsid=4242, bid=")
        + bid
        + String(", source_kind=")
        + kind_name
        + String(")\n"),
    )


def test_every_source_type_and_kind_has_its_name() raises:
    _type_line(SOURCE_PARQUET, SCAN_ORIENTATION_COLUMNAR, "PARQUET", "COLUMNAR")
    _type_line(SOURCE_CSV, SCAN_ORIENTATION_ROW, "CSV", "ROW")
    _type_line(SOURCE_NDJSON, SCAN_ORIENTATION_ROW, "NDJSON", "ROW")
    _type_line(SOURCE_JSON, SCAN_ORIENTATION_ROW, "JSON", "ROW")
    _type_line(SOURCE_ORC, SCAN_ORIENTATION_COLUMNAR, "ORC", "COLUMNAR")
    _type_line(SOURCE_AVRO, SCAN_ORIENTATION_ROW, "AVRO", "ROW")
    _type_line(SOURCE_ARROW, SCAN_ORIENTATION_COLUMNAR, "ARROW", "COLUMNAR")
    # A declared type with no name.
    _type_line(UInt8(99), SCAN_ORIENTATION_COLUMNAR, "UNKNOWN", "COLUMNAR")


def test_a_source_kind_with_no_name_renders_unknown() raises:
    """A non-binding arm keeps a stated kind verbatim (the plan wire decoder
    states one)."""
    var ps = ParquetSource(String("t.parquet"), _schema(), Optional[String](None))
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(ps^), _schema(), source_kind=UInt8(7)
    )
    assert_equal(
        _render(plan),
        String('Scan(path="t.parquet", type=PARQUET, source_kind=UNKNOWN)\n'),
    )


# =============================================================================
# 2. Node kinds
# =============================================================================


def test_filter() raises:
    _both(LogicalPlan.filter(_col("a"), _im()), "Filter(predicate=ColRef(a))\n")


def test_project_renders_every_expr() raises:
    var exprs = Slab[Expr].create(2)
    exprs.append(_col("a"))
    exprs.append(_col("b"))
    _both(
        LogicalPlan.project(exprs^, _im()),
        "Project(exprs=[ColRef(a), ColRef(b)])\n",
    )


def _agg_udf() -> UdfData:
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append(("b", DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append(("o", DTAG_F64))
    return UdfData(
        kind=UDF_KIND_AGG,
        name=String("g"),
        input_columns=in_cols^,
        output_columns=out_cols^,
        operator_factory_id=UInt32(3),
        call_site_salt=UInt32(1),
        null_mode=UDF_NULL_PROPAGATE,
        stability=UDF_STABILITY_IMMUTABLE,
        parallelism_tag=UDF_PAR_MERGEABLE,
    )


def _two_aggs() -> Slab[AggExpr]:
    var aggs = Slab[AggExpr].create(2)
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](_col("a")), Optional[String]("s")))
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]()))
    return aggs^


def test_aggregate_renders_keys_aggs_and_udf() raises:
    var gb = Slab[Expr].create(2)
    gb.append(_col("a"))
    gb.append(_col("b"))
    _both(
        LogicalPlan.aggregate(gb^, _two_aggs(), _im()),
        'Aggregate(group_by=[ColRef(a), ColRef(b)], aggs=[SUM(ColRef(a)).alias("s"), COUNT(*)])\n',
    )
    var gb2 = Slab[Expr].create(1)
    gb2.append(_col("a"))
    var udf_text = String()
    _agg_udf().write_to(udf_text)
    _both(
        LogicalPlan.aggregate_with_udf(
            gb2^, _two_aggs(), _im(), OwnedPointer(_agg_udf())
        ),
        String('Aggregate(group_by=[ColRef(a)], aggs=[SUM(ColRef(a)).alias("s"), COUNT(*)], ')
        + udf_text
        + String(")\n"),
    )


def _join(jt: UInt8, algo: UInt8 = UInt8(0)) -> LogicalPlan:
    var on = List[String]()
    on.append(String("a"))
    return LogicalPlan.join(_parquet(), _parquet(), on.copy(), on.copy(), jt, algo)


def test_join_type_names() raises:
    var names = List[String]()
    names.append("INNER")
    names.append("LEFT")
    names.append("RIGHT")
    names.append("FULL")
    names.append("SEMI")
    names.append("ANTI")
    names.append("CROSS")
    var types = List[UInt8]()
    types.append(JOIN_INNER)
    types.append(JOIN_LEFT)
    types.append(JOIN_RIGHT)
    types.append(JOIN_FULL)
    types.append(JOIN_SEMI)
    types.append(JOIN_ANTI)
    types.append(JOIN_CROSS)
    for i in range(len(types)):
        assert_equal(
            _render(_join(types[i])),
            String("Join(type=") + names[i] + String(", on=[a=a])\n  ")
            + String(P) + String("  ") + String(P),
        )
    assert_equal(
        _render(_join(UInt8(99))),
        String("Join(type=UNKNOWN, on=[a=a])\n  ") + String(P) + String("  ") + String(P),
    )


def test_join_algo_hint_names() raises:
    """AUTO is the absent hint and writes no `algo=`."""
    assert_equal(
        _render(_join(JOIN_INNER, JOIN_ALGO_HASH)),
        String("Join(type=INNER, algo=HASH, on=[a=a])\n  ") + String(P) + String("  ") + String(P),
    )
    assert_equal(
        _render(_join(JOIN_INNER, JOIN_ALGO_SORT_MERGE)),
        String("Join(type=INNER, algo=SORT_MERGE, on=[a=a])\n  ") + String(P) + String("  ") + String(P),
    )
    assert_equal(
        _render(_join(JOIN_INNER, UInt8(9))),
        String("Join(type=INNER, algo=UNKNOWN, on=[a=a])\n  ") + String(P) + String("  ") + String(P),
    )


def test_join_renders_every_key_pair_the_residual_and_both_sides() raises:
    var lo = List[String]()
    lo.append(String("a"))
    lo.append(String("b"))
    var ro = List[String]()
    ro.append(String("x"))
    ro.append(String("y"))
    var plan = LogicalPlan.join(
        _parquet(),
        _im(),
        lo^,
        ro^,
        JOIN_LEFT,
        residual=Optional[OwnedPointer[Expr]](OwnedPointer(_col("b"))),
    )
    var head = String("Join(type=LEFT, on=[a=x, b=y], residual=ColRef(b))\n  ") + String(P)
    _both(plan, head)
    # The left side forwards the flag too.
    var l = List[String]()
    var flipped = LogicalPlan.join(_im(), _parquet(), l.copy(), l.copy(), JOIN_INNER)
    assert_equal(
        _cheap(flipped),
        String("Join(type=INNER, on=[])\n  ") + String(IM_CHEAP) + String("  ") + String(P),
    )


def test_sort_renders_direction_and_a_deviating_null_placement() raises:
    _both(
        LogicalPlan.sort(_keys(), _asc_desc(), _im()),
        "Sort(keys=[a ASC, b DESC])\n",
    )
    # NULLS LAST is the derived placement in both directions, so only a
    # NULLS FIRST override deviates and is written.
    var nf = List[Bool]()
    nf.append(True)
    nf.append(False)
    _both(
        LogicalPlan.sort(_keys(), _asc_desc(), _im(), Optional[List[Bool]](nf^)),
        "Sort(keys=[a ASC NULLS FIRST, b DESC])\n",
    )
    var nf2 = List[Bool]()
    nf2.append(False)
    nf2.append(True)
    assert_equal(
        _render(LogicalPlan.sort(_keys(), _asc_desc(), _parquet(), Optional[List[Bool]](nf2^))),
        String("Sort(keys=[a ASC, b DESC NULLS FIRST])\n  ") + String(P),
    )


def test_a_short_null_placement_list_writes_no_placement() raises:
    """An optimizer-rebuilt node may carry fewer placements than keys: the
    keys past the list's end render with none."""
    var nf = List[Bool]()
    nf.append(True)
    nf.append(True)
    var plan = LogicalPlan.sort(_keys(), _asc_desc(), _parquet(), Optional[List[Bool]](nf^))
    var short = List[Bool]()
    short.append(True)
    plan._sort.value()[].nulls_first = short^
    assert_equal(
        _render(plan),
        String("Sort(keys=[a ASC NULLS FIRST, b DESC])\n  ") + String(P),
    )


def test_limit_with_and_without_offset() raises:
    _both(LogicalPlan.limit(3, _im()), "Limit(n=3)\n")
    _both(LogicalPlan.limit(3, _im(), offset=2), "Limit(n=3, offset=2)\n")


def test_distinct_columns_or_all() raises:
    _both(LogicalPlan.distinct(None, _im()), "Distinct(all)\n")
    _both(
        LogicalPlan.distinct(Optional[List[String]](_keys()), _im()),
        "Distinct(columns=[a, b])\n",
    )


def test_topn() raises:
    _both(
        LogicalPlan.topn(_keys(), _asc_desc(), 2, _im()),
        "TopN(n=2, keys=[a ASC, b DESC])\n",
    )
    var nf = List[Bool]()
    nf.append(True)
    nf.append(True)
    _both(
        LogicalPlan.topn(_keys(), _asc_desc(), 2, _im(), Optional[List[Bool]](nf^)),
        "TopN(n=2, keys=[a ASC NULLS FIRST, b DESC NULLS FIRST])\n",
    )


def _pexpr(label: String) -> PartitionExpr:
    return PartitionExpr(
        PF_RANK,
        String("a"),
        0,
        ScalarValue.from_int(0),
        False,
        PartitionFrame(0, 0, 0, 0, 0),
        String(label),
    )


def test_partition_by_renders_keys_directions_and_every_function() raises:
    var fs = List[PartitionExpr]()
    fs.append(_pexpr(String("r1")))
    fs.append(_pexpr(String("r2")))
    var head = (
        String("PartitionBy(partition=[a, b], order=[a ASC, b DESC], funcs=[")
        + String(_pexpr(String("r1")))
        + String(", ")
        + String(_pexpr(String("r2")))
        + String("])\n")
    )
    _both(
        LogicalPlan.partition_by(_keys(), _keys(), _asc_desc(), fs^, _im()), head
    )
    # An order key with no direction is written bare.
    var one_dir = List[Bool]()
    one_dir.append(True)
    assert_equal(
        _render(
            LogicalPlan.partition_by(
                List[String](), _keys(), one_dir^, List[PartitionExpr](), _parquet()
            )
        ),
        String("PartitionBy(partition=[], order=[a DESC, b], funcs=[])\n  ") + String(P),
    )


def test_partition_topn_function_names_and_rank_column() raises:
    _both(
        LogicalPlan.partition_topn(_keys(), _keys(), _asc_desc(), 1, _im()),
        "PartitionTopN(k=1, func=ROW_NUMBER, over_fetch_k=1, partition=[a, b], sort=[a ASC, b DESC])\n",
    )
    _both(
        LogicalPlan.partition_topn(
            _keys(), _keys(), _asc_desc(), 2, _im(), func=1, over_fetch_k=18,
            output_rank_col_name=Optional[String]("rk"),
        ),
        "PartitionTopN(k=2, func=RANK, over_fetch_k=18, partition=[a, b], sort=[a ASC, b DESC], output_rank_col=rk)\n",
    )
    _both(
        LogicalPlan.partition_topn(
            _keys(), _keys(), _asc_desc(), 3, _im(), func=5, over_fetch_k=3
        ),
        "PartitionTopN(k=3, func=FUNC_5, over_fetch_k=3, partition=[a, b], sort=[a ASC, b DESC])\n",
    )


def _asof(
    var left: LogicalPlan,
    var right: LogicalPlan,
    strategy: UInt8,
    tol: AsofTolerance,
) -> LogicalPlan:
    var lk = List[String]()
    lk.append(String("k"))
    lk.append(String("m"))
    var rk = List[String]()
    rk.append(String("k2"))
    rk.append(String("m2"))
    return LogicalPlan.asof_join(
        left^, right^, lk^, rk^, String("ts"), String("ts2"), strategy, tol
    )


def test_asof_join_strategy_and_tolerance_names() raises:
    var tail = String("  ") + String(P) + String("  ") + String(P)
    assert_equal(
        _render(_asof(_parquet(), _parquet(), ASOF_BACKWARD, AsofTolerance.none())),
        String("AsofJoin(strategy=BACKWARD, on=ts=ts2, by=[k=k2, m=m2])\n") + tail,
    )
    # A set tolerance names its payload kind. The render does not carry the
    # tolerance VALUE today, so two as-of joins differing only in it render
    # alike (komira-ai/komira#960): only the field's presence and kind are
    # asserted, which hold with or without the value.
    var fwd = _render(_asof(_parquet(), _parquet(), ASOF_FORWARD, AsofTolerance.int64(5)))
    assert_true(
        fwd.startswith("AsofJoin(strategy=FORWARD, on=ts=ts2, by=[k=k2, m=m2], tolerance=INT64"),
        fwd,
    )
    var near = _render(_asof(_parquet(), _parquet(), ASOF_NEAREST, AsofTolerance.float64(0.5)))
    assert_true(
        near.startswith("AsofJoin(strategy=NEAREST, on=ts=ts2, by=[k=k2, m=m2], tolerance=FLOAT64"),
        near,
    )
    var odd = AsofTolerance(tag=UInt8(9), int_val=Int64(0), float_val=Float64(0.0))
    assert_equal(
        _render(_asof(_parquet(), _parquet(), UInt8(9), odd)),
        String("AsofJoin(strategy=UNKNOWN, on=ts=ts2, by=[k=k2, m=m2], tolerance=UNKNOWN)\n") + tail,
    )


def test_asof_join_forwards_the_flag_to_both_sides() raises:
    var head = String("AsofJoin(strategy=BACKWARD, on=ts=ts2, by=[k=k2, m=m2])\n")
    assert_equal(
        _cheap(_asof(_im(), _parquet(), ASOF_BACKWARD, AsofTolerance.none())),
        head + String("  ") + String(IM_CHEAP) + String("  ") + String(P),
    )
    assert_equal(
        _cheap(_asof(_parquet(), _im(), ASOF_BACKWARD, AsofTolerance.none())),
        head + String("  ") + String(P) + String("  ") + String(IM_CHEAP),
    )


def test_union_renders_its_branch_count_and_every_branch() raises:
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_parquet()))
    children.append(OwnedPointer(_im()))
    var plan = LogicalPlan.union(children^, _schema())
    _both(plan, String("Union(branches=2)\n  ") + String(P))


def test_view_ref_and_cse_ref_are_leaves() raises:
    assert_equal(
        _render(LogicalPlan.view_ref(String("v1"), _schema())),
        String('ViewRef(name="v1")\n'),
    )
    assert_equal(
        _render(LogicalPlan.cse_ref(UInt64(42), _schema())),
        String("CseRef(canonical_hash=42)\n"),
    )


def test_cast_to_varchar() raises:
    _both(LogicalPlan.cast_to_varchar(_im()), "CastToVarchar()\n")


# =============================================================================
# 3. The unknown tag and the indent
# =============================================================================


def test_a_tag_with_no_arm_renders_unknown() raises:
    var plan = LogicalPlan(UInt8(200), _schema())
    assert_equal(_render(plan), String("Unknown(tag=200)\n"))
    var under = LogicalPlan.limit(1, LogicalPlan(UInt8(201), _schema()))
    assert_equal(_render(under), String("Limit(n=1)\n  Unknown(tag=201)\n"))


def test_the_indent_argument_and_depth() raises:
    var s = String()
    _write_plan_node(s, _parquet(), 2)
    assert_equal(s, String("    ") + String(P))
    # Three levels deep: two spaces per level.
    var plan = LogicalPlan.limit(1, LogicalPlan.cast_to_varchar(_parquet()))
    assert_equal(
        _render(plan),
        String("Limit(n=1)\n  CastToVarchar()\n    ") + String(P),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
