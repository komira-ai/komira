"""Every branch of `refuse_udf_carrying_node`: the refusal on each of the
three UDF-carrying node kinds, and the descent through every node kind that
has children, including a node without its payload.

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
from komira_plan_expr.udf_data import (
    DTAG_I64,
    UDF_KIND_AGG,
    UDF_KIND_FILTER,
    UDF_KIND_MAP,
    UdfData,
)

from komira_dispatch_scan.udf_execution_refusal import (
    UDF_NODE_REFUSAL_TOKEN,
    refuse_udf_carrying_node,
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
# UDF fixtures
# =============================================================================


def _udf_data(kind: UInt8) -> OwnedPointer[UdfData]:
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append(("a", DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append(("r", DTAG_I64))
    return OwnedPointer(UdfData(
        kind=kind,
        name=String("u"),
        input_columns=in_cols^,
        output_columns=out_cols^,
        operator_factory_id=UInt32(1),
        call_site_salt=UInt32(2),
    ))


def _udf_filter(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.filter_with_udf(
        Expr.col_ref("a"), child^, _udf_data(UDF_KIND_FILTER)
    )


def _udf_project(var child: LogicalPlan) -> LogicalPlan:
    var ex = ExprArray()
    ex.append(Expr.col_ref("a"))
    return LogicalPlan.project_with_udf(ex^, child^, _udf_data(UDF_KIND_MAP))


def _udf_aggregate(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.aggregate_with_udf(
        ExprArray(), AggExprArray(), child^, _udf_data(UDF_KIND_AGG)
    )


def _refusal(p: LogicalPlan) -> String:
    """The refusal's message, or "" when the plan passes."""
    try:
        refuse_udf_carrying_node(p, String("the column path"))
    except e:
        return String(e)
    return String("")


def test_each_udf_carrying_node_is_refused_by_name() raises:
    """The message leads with the frozen token and names the node kind and
    the caller.
    MUTANT: name every node "Filter" and the Project and Aggregate asserts
    fail."""
    var msg = _refusal(_udf_filter(_parquet_scan()))
    assert_true(msg.startswith(UDF_NODE_REFUSAL_TOKEN + ": "), msg)
    assert_true("the column path received a Filter node" in msg, msg)
    msg = _refusal(_udf_project(_parquet_scan()))
    assert_true("received a Project node" in msg, msg)
    msg = _refusal(_udf_aggregate(_parquet_scan()))
    assert_true("received a Aggregate node" in msg, msg)
    assert_equal(UDF_NODE_REFUSAL_TOKEN, String("PLAN_ENDPOINT_UNSUPPORTED_UDF(11)"))


def test_a_plan_without_a_udf_passes() raises:
    """MUTANT: raise on any FILTER and the ordinary filter is refused."""
    assert_equal(_refusal(_parquet_scan()), String(""))
    assert_equal(_refusal(_over(PLAN_FILTER, _parquet_scan())), String(""))
    assert_equal(_refusal(_join(_parquet_scan(), _parquet_scan())), String(""))


def test_the_walk_descends_every_single_child_node() raises:
    """A UDF filter under each single-child node is found, and each node
    without its payload ends the walk quietly.
    MUTANT: drop the CAST TO VARCHAR arm and the UDF under it is missed."""
    var tags = _single_child_tags()
    for i in range(len(tags)):
        var msg = _refusal(_over(tags[i], _udf_filter(_parquet_scan())))
        assert_true("received a Filter node" in msg, String(Int(tags[i])) + ": " + msg)
        assert_equal(_refusal(_bare(tags[i])), String(""))


def test_the_walk_reads_both_sides_and_every_union_child() raises:
    """MUTANT: walk only the left side of a JOIN and the right-side UDF is
    missed."""
    assert_true(_refusal(_join(_udf_project(_parquet_scan()), _parquet_scan())) != "")
    assert_true(_refusal(_join(_parquet_scan(), _udf_project(_parquet_scan()))) != "")
    assert_true(_refusal(_asof(_udf_filter(_parquet_scan()), _parquet_scan())) != "")
    assert_true(_refusal(_asof(_parquet_scan(), _udf_filter(_parquet_scan()))) != "")
    assert_equal(_refusal(_asof(_parquet_scan(), _parquet_scan())), String(""))
    assert_true(_refusal(_union(_parquet_scan(), _udf_aggregate(_parquet_scan()))) != "")
    assert_equal(_refusal(_union(_parquet_scan(), _parquet_scan())), String(""))
    assert_equal(_refusal(_bare(PLAN_JOIN)), String(""))
    assert_equal(_refusal(_bare(PLAN_ASOF_JOIN)), String(""))
    assert_equal(_refusal(_bare(PLAN_UNION)), String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
