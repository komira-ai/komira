"""Every branch of `udf_expr_routing`: the servability question at the root,
each expression site of the five node kinds that hold one (all four
aggregate slots), the enumerated expression-free kinds, the refusal of an
unmodelled tag, and the presence and first-node walks over every node kind.

Each test names the mutant it catches in its docstring.
"""

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ASOF_BACKWARD,
    AsofTolerance,
    ExprArray,
    JOIN_INNER,
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_ASOF_JOIN,
    PLAN_CAST_TO_VARCHAR,
    PLAN_CSE_REF,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    SOURCE_IN_MEMORY,
    SOURCE_KIND_ROW,
    SOURCE_PARQUET,
)
from komira_scan_source.avro_source import AvroSource
from komira_scan_source.csv_source import CsvSource
from komira_scan_source.json_source import JsonSource
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_AVRO,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_JSON,
    SOURCE_VARIANT_PARQUET,
)

from komira_dispatch_scan.udf_expr_routing import (
    first_udf_carrying_node_tag,
    node_own_exprs_carry_udf_expr,
    plan_carries_udf_expr,
    plan_root_carries_udf_expr,
)


# =============================================================================
# Plan fixtures: scans of each source kind, and every node kind over a child
# =============================================================================


def _schema_of(at: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), at, False))
    return sb.build()


def _schema() -> Schema:
    return _schema_of(ArrowType.INT64)


def _csv_scan(path: String = "t.csv") raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(CsvSource(path, _schema())), _schema()
    )


def _json_scan(at: ArrowType = ArrowType.INT64) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(JsonSource(String("t.jsonl"), _schema_of(at))), _schema_of(at)
    )


def _avro_scan() raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(AvroSource(String("t.avro"), _schema())), _schema()
    )


def _parquet_scan() -> LogicalPlan:
    """A COLUMNAR parquet scan."""
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _schema())


def _parquet_row_scan() raises -> LogicalPlan:
    """The legacy CSV form: a parquet-tag scan stated as a ROW source."""
    return LogicalPlan.scan_from_source(
        SourceVariant(ParquetSource(String("legacy.csv"), _schema())),
        _schema(),
        source_kind=SOURCE_KIND_ROW,
    )


def _one_key() -> List[String]:
    var k = List[String]()
    k.append(String("a"))
    return k^


def _one_desc() -> List[Bool]:
    var d = List[Bool]()
    d.append(False)
    return d^


def _single_child_tags() -> List[UInt8]:
    var t = List[UInt8]()
    t.append(PLAN_FILTER)
    t.append(PLAN_PROJECT)
    t.append(PLAN_AGGREGATE)
    t.append(PLAN_SORT)
    t.append(PLAN_LIMIT)
    t.append(PLAN_DISTINCT)
    t.append(PLAN_TOPN)
    t.append(PLAN_PARTITION_BY)
    t.append(PLAN_PARTITION_TOPN)
    t.append(PLAN_CAST_TO_VARCHAR)
    return t^


def _over(tag: UInt8, var child: LogicalPlan) raises -> LogicalPlan:
    """A node of kind `tag` over `child`, built with its own factory."""
    if tag == PLAN_FILTER:
        return LogicalPlan.filter(Expr.col_ref("a"), child^)
    if tag == PLAN_PROJECT:
        var ex = ExprArray()
        ex.append(Expr.col_ref("a"))
        return LogicalPlan.project(ex^, child^)
    if tag == PLAN_AGGREGATE:
        var gb = ExprArray()
        gb.append(Expr.col_ref("a"))
        var ax = AggExprArray()
        ax.append(AggExpr(AGG_COUNT, Optional[Expr](), None))
        return LogicalPlan.aggregate(gb^, ax^, child^)
    if tag == PLAN_SORT:
        return LogicalPlan.sort(_one_key(), _one_desc(), child^)
    if tag == PLAN_LIMIT:
        return LogicalPlan.limit(5, child^)
    if tag == PLAN_DISTINCT:
        return LogicalPlan.distinct(None, child^)
    if tag == PLAN_TOPN:
        return LogicalPlan.topn(_one_key(), _one_desc(), 3, child^)
    if tag == PLAN_PARTITION_BY:
        return LogicalPlan.partition_by(
            _one_key(), _one_key(), _one_desc(), List[PartitionExpr](), child^
        )
    if tag == PLAN_PARTITION_TOPN:
        return LogicalPlan.partition_topn(_one_key(), _one_key(), _one_desc(), 2, child^)
    if tag == PLAN_CAST_TO_VARCHAR:
        return LogicalPlan.cast_to_varchar(child^)
    raise Error("fixture: not a single-child tag " + String(Int(tag)))


def _join(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _one_key(), _one_key(), JOIN_INNER)


def _asof(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.asof_join(
        l^, r^, List[String](), List[String](), String("a"), String("a"),
        ASOF_BACKWARD, AsofTolerance.none(),
    )


def _union(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, _schema())


def _bare(tag: UInt8) -> LogicalPlan:
    """A node of kind `tag` whose payload is absent."""
    return LogicalPlan(tag, _schema())


# =============================================================================
# Expression fixtures
# =============================================================================


def _u() -> Expr:
    """`u(a)`: a registered scalar UDF call."""
    return Expr.udf_call(
        String("u"), Optional[Int](7), ArrowType.INT64, ArrowType.INT64,
        Expr.col_ref("a"),
    )


def _filter_by(var pred: Expr, var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.filter(pred^, child^)


def _project_of(var e: Expr, var child: LogicalPlan) -> LogicalPlan:
    var ex = ExprArray()
    ex.append(Expr.col_ref("a"))
    ex.append(e^)
    return LogicalPlan.project(ex^, child^)


def _scan_filtered(var pred: Expr) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(ParquetSource(String("t.parquet"), _schema())), _schema(),
        filter=Optional[Expr](pred^),
    )


def _agg(var key: Expr, var ae: AggExpr) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(key^)
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_COUNT, Optional[Expr](), None))
    ax.append(ae^)
    return LogicalPlan.aggregate(gb^, ax^, _parquet_scan())


def _ae_slots(slot: Int) -> AggExpr:
    """An AggExpr with a plain column in every slot, and `u(a)` in `slot`
    (-1: none)."""
    var ae = AggExpr(AGG_COUNT, Optional[Expr](Expr.col_ref("a")), None)
    ae.child1 = Optional[Expr](Expr.col_ref("a"))
    ae.child2 = Optional[Expr](Expr.col_ref("a"))
    ae.child3 = Optional[Expr](Expr.col_ref("a"))
    if slot == 0:
        ae.child = Optional[Expr](_u())
    elif slot == 1:
        ae.child1 = Optional[Expr](_u())
    elif slot == 2:
        ae.child2 = Optional[Expr](_u())
    elif slot == 3:
        ae.child3 = Optional[Expr](_u())
    return ae^


def _join_with(var residual: Optional[Expr]) -> LogicalPlan:
    var r: Optional[OwnedPointer[Expr]] = None
    if residual:
        r = Optional[OwnedPointer[Expr]](OwnedPointer(residual.take()))
    return LogicalPlan.join(
        _parquet_scan(), _parquet_scan(), _one_key(), _one_key(), JOIN_INNER,
        residual=r^,
    )


def _udf_leaf() raises -> LogicalPlan:
    """A FILTER holding `u(a)` over a scan: the node a walk should find."""
    return _filter_by(_u(), _parquet_scan())


# =============================================================================
# plan_root_carries_udf_expr
# =============================================================================


def test_only_a_project_or_filter_root_is_servable() raises:
    """MUTANT: answer `plan_carries_udf_expr` here and the aggregate over a
    UDF filter reads True."""
    assert_true(plan_root_carries_udf_expr(_project_of(_u(), _parquet_scan())))
    assert_false(plan_root_carries_udf_expr(_project_of(Expr.col_ref("a"), _parquet_scan())))
    assert_true(plan_root_carries_udf_expr(_udf_leaf()))
    assert_false(plan_root_carries_udf_expr(_over(PLAN_FILTER, _parquet_scan())))
    assert_false(plan_root_carries_udf_expr(_bare(PLAN_PROJECT)))
    assert_false(plan_root_carries_udf_expr(_bare(PLAN_FILTER)))
    assert_false(plan_root_carries_udf_expr(_over(PLAN_AGGREGATE, _udf_leaf())))


# =============================================================================
# node_own_exprs_carry_udf_expr
# =============================================================================


def test_scan_filter_and_project_sites() raises:
    """MUTANT: skip the scan's pushed-down filter and the first assert
    fails."""
    assert_true(node_own_exprs_carry_udf_expr(_scan_filtered(_u())))
    assert_false(node_own_exprs_carry_udf_expr(_scan_filtered(Expr.col_ref("a"))))
    assert_false(node_own_exprs_carry_udf_expr(_parquet_scan()))
    assert_false(node_own_exprs_carry_udf_expr(_bare(PLAN_SCAN)))
    assert_true(node_own_exprs_carry_udf_expr(_udf_leaf()))
    assert_false(node_own_exprs_carry_udf_expr(_over(PLAN_FILTER, _parquet_scan())))
    assert_false(node_own_exprs_carry_udf_expr(_bare(PLAN_FILTER)))
    assert_true(node_own_exprs_carry_udf_expr(_project_of(_u(), _parquet_scan())))
    assert_false(node_own_exprs_carry_udf_expr(_over(PLAN_PROJECT, _parquet_scan())))
    assert_false(node_own_exprs_carry_udf_expr(_bare(PLAN_PROJECT)))


def test_every_aggregate_slot_is_read() raises:
    """The group-by keys and all four AggExpr slots, past a COUNT(*) whose
    slots are empty.
    MUTANT: walk `num_children()` slots, or drop the `child3` check, and the
    slot-3 UDF is missed."""
    assert_true(node_own_exprs_carry_udf_expr(_agg(_u(), _ae_slots(-1))))
    assert_false(node_own_exprs_carry_udf_expr(_agg(Expr.col_ref("a"), _ae_slots(-1))))
    for s in range(4):
        assert_true(
            node_own_exprs_carry_udf_expr(_agg(Expr.col_ref("a"), _ae_slots(s))),
            "slot " + String(s),
        )
    assert_false(node_own_exprs_carry_udf_expr(_bare(PLAN_AGGREGATE)))


def test_a_join_residual_is_read() raises:
    """MUTANT: return False for every JOIN and the residual UDF is missed."""
    assert_true(node_own_exprs_carry_udf_expr(_join_with(Optional[Expr](_u()))))
    assert_false(node_own_exprs_carry_udf_expr(_join_with(Optional[Expr](Expr.col_ref("a")))))
    assert_false(node_own_exprs_carry_udf_expr(_join_with(None)))
    assert_false(node_own_exprs_carry_udf_expr(_bare(PLAN_JOIN)))


def test_the_expression_free_kinds_are_enumerated_and_others_refused() raises:
    """Each of the eleven expression-free kinds answers False; a tag the
    walk does not model raises and names it.
    MUTANT: drop PLAN_CSE_REF from the list and it raises."""
    var tags = List[UInt8]()
    tags.append(PLAN_SORT); tags.append(PLAN_LIMIT); tags.append(PLAN_DISTINCT)
    tags.append(PLAN_TOPN); tags.append(PLAN_PARTITION_BY)
    tags.append(PLAN_PARTITION_TOPN); tags.append(PLAN_CAST_TO_VARCHAR)
    tags.append(PLAN_ASOF_JOIN); tags.append(PLAN_UNION)
    tags.append(PLAN_VIEW_REF); tags.append(PLAN_CSE_REF)
    for i in range(len(tags)):
        assert_false(node_own_exprs_carry_udf_expr(_bare(tags[i])), String(Int(tags[i])))
    var msg = String("")
    try:
        _ = node_own_exprs_carry_udf_expr(_bare(UInt8(250)))
    except e:
        msg = String(e)
    assert_true("UDF_ROUTING_UNMODELLED_PLAN_TAG" in msg, msg)
    assert_true("plan tag 250" in msg, msg)


# =============================================================================
# plan_carries_udf_expr / first_udf_carrying_node_tag
# =============================================================================


def test_presence_and_first_node_through_every_single_child_node() raises:
    """A UDF filter under each single-child node is present and is the first
    UDF node; a plain child is absent; a node without its payload is a leaf.
    MUTANT: drop the PARTITION_TOPN arm of either walk and that chain
    misses the UDF."""
    var tags = _single_child_tags()
    for i in range(len(tags)):
        var name = String(Int(tags[i]))
        assert_true(plan_carries_udf_expr(_over(tags[i], _udf_leaf())), name)
        assert_false(plan_carries_udf_expr(_over(tags[i], _parquet_scan())), name)
        assert_false(plan_carries_udf_expr(_bare(tags[i])), name)
        assert_equal(first_udf_carrying_node_tag(_over(tags[i], _udf_leaf())), Int(PLAN_FILTER), name)
        assert_equal(first_udf_carrying_node_tag(_over(tags[i], _parquet_scan())), -1, name)
        assert_equal(first_udf_carrying_node_tag(_bare(tags[i])), -1, name)


def test_presence_and_first_node_read_both_sides_and_every_child() raises:
    """MUTANT: walk only the left side of an AS OF join and the right-side
    UDF is missed by both walks."""
    assert_true(plan_carries_udf_expr(_join(_udf_leaf(), _parquet_scan())))
    assert_true(plan_carries_udf_expr(_join(_parquet_scan(), _udf_leaf())))
    assert_false(plan_carries_udf_expr(_join(_parquet_scan(), _parquet_scan())))
    assert_true(plan_carries_udf_expr(_asof(_udf_leaf(), _parquet_scan())))
    assert_true(plan_carries_udf_expr(_asof(_parquet_scan(), _udf_leaf())))
    assert_false(plan_carries_udf_expr(_asof(_parquet_scan(), _parquet_scan())))
    assert_true(plan_carries_udf_expr(_union(_parquet_scan(), _udf_leaf())))
    assert_false(plan_carries_udf_expr(_union(_parquet_scan(), _parquet_scan())))
    assert_false(plan_carries_udf_expr(_bare(PLAN_JOIN)))
    assert_false(plan_carries_udf_expr(_bare(PLAN_ASOF_JOIN)))
    assert_false(plan_carries_udf_expr(_bare(PLAN_UNION)))
    assert_false(plan_carries_udf_expr(_parquet_scan()))
    assert_true(plan_carries_udf_expr(_join_with(Optional[Expr](_u()))))

    var j = _join(_project_of(_u(), _parquet_scan()), _udf_leaf())
    assert_equal(first_udf_carrying_node_tag(j), Int(PLAN_PROJECT), "left first")
    assert_equal(first_udf_carrying_node_tag(_join(_parquet_scan(), _udf_leaf())), Int(PLAN_FILTER))
    assert_equal(first_udf_carrying_node_tag(_join(_parquet_scan(), _parquet_scan())), -1)
    var a = _asof(_project_of(_u(), _parquet_scan()), _udf_leaf())
    assert_equal(first_udf_carrying_node_tag(a), Int(PLAN_PROJECT), "asof left first")
    assert_equal(first_udf_carrying_node_tag(_asof(_parquet_scan(), _udf_leaf())), Int(PLAN_FILTER))
    assert_equal(first_udf_carrying_node_tag(_asof(_parquet_scan(), _parquet_scan())), -1)
    assert_equal(first_udf_carrying_node_tag(_union(_parquet_scan(), _udf_leaf())), Int(PLAN_FILTER))
    assert_equal(first_udf_carrying_node_tag(_union(_parquet_scan(), _parquet_scan())), -1)
    assert_equal(first_udf_carrying_node_tag(_bare(PLAN_JOIN)), -1)
    assert_equal(first_udf_carrying_node_tag(_bare(PLAN_ASOF_JOIN)), -1)
    assert_equal(first_udf_carrying_node_tag(_bare(PLAN_UNION)), -1)
    assert_equal(first_udf_carrying_node_tag(_parquet_scan()), -1)
    assert_equal(first_udf_carrying_node_tag(_scan_filtered(_u())), Int(PLAN_SCAN))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
