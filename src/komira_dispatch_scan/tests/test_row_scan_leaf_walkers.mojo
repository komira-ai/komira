"""Every branch of the three scan-leaf walkers: the source path and the
source variant (`row_column_reroute`) and the CSV dialect
(`row_source_csv_options`), over every source arm, every chain node, a node
without its payload, and the nodes the walks do not descend.

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
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_AVRO,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_JSON,
    SOURCE_VARIANT_PARQUET,
)
from komira_csv.csv_options import QUOTE_STYLE_TAG_RFC4180

from komira_dispatch_scan.row_column_reroute import (
    _row_source_path_for_dispatch,
    _row_source_variant_for_dispatch,
)
from komira_dispatch_scan.row_source_csv_options import (
    _row_source_csv_options_for_dispatch,
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


def _chain_tags() -> List[UInt8]:
    """The single-child nodes all three walks descend (not CAST TO VARCHAR)."""
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
    return t^


def _path_raises(p: LogicalPlan) -> String:
    try:
        _ = _row_source_path_for_dispatch(p)
    except e:
        return String(e)
    return String("")


def _variant_raises(p: LogicalPlan) -> String:
    try:
        _ = _row_source_variant_for_dispatch(p)
    except e:
        return String(e)
    return String("")


def _csv_raises(p: LogicalPlan) -> String:
    try:
        _ = _row_source_csv_options_for_dispatch(p)
    except e:
        return String(e)
    return String("")


def _csv_scan_with(delim: UInt8, header: Bool, quote: Int) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(
            CsvSource(
                String("p.csv"), _schema(), quote_style_tag=quote,
                delimiter=delim, has_header=header,
            )
        ),
        _schema(),
    )


def _csv_scan_without_params() raises -> LogicalPlan:
    """A CSV leaf whose binding carries no dialect params, built through the
    kw-only constructor the plan wire decoder uses (an older encoder's
    plan)."""
    var sv = SourceVariant(CsvSource(String("old.csv"), _schema()))
    var b = sv.binding_ref().copy()
    b.params = ScanParams()
    return LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_CSV, binding=b^), _schema()
    )


# =============================================================================
# The source path
# =============================================================================


def test_the_path_of_each_row_source_arm() raises:
    """CSV, JSON and AVRO read the binding's name; the legacy parquet-tag
    ROW scan reads the parquet path.
    MUTANT: return the CSV arm's name for the parquet arm and the legacy
    path is wrong."""
    assert_equal(_row_source_path_for_dispatch(_csv_scan(String("c.csv"))), String("c.csv"))
    assert_equal(_row_source_path_for_dispatch(_json_scan()), String("t.jsonl"))
    assert_equal(_row_source_path_for_dispatch(_avro_scan()), String("t.avro"))
    assert_equal(_row_source_path_for_dispatch(_parquet_row_scan()), String("legacy.csv"))


def test_the_path_walk_refuses_what_has_no_row_path() raises:
    """A scan without its payload, a columnar scan, a parquet-tag scan
    without its parquet arm, and an in-memory ROW scan all raise, each with
    its own message.
    MUTANT: drop the `source_kind` check and the columnar scan returns its
    path."""
    var msg = _path_raises(_bare(PLAN_SCAN))
    assert_true("PLAN_SCAN missing ScanData" in msg, msg)
    msg = _path_raises(_parquet_scan())
    assert_true("scan leaf is not SOURCE_KIND_ROW" in msg, msg)
    var no_arm = _parquet_row_scan()
    no_arm._scan.value()[].source._parquet = None
    msg = _path_raises(no_arm)
    assert_true("has no on-wire path arm" in msg, msg)
    var mem = LogicalPlan.scan(String("mem"), SOURCE_IN_MEMORY, _schema())
    mem._scan.value()[].source_kind = SOURCE_KIND_ROW
    msg = _path_raises(mem)
    assert_true("has no on-wire path arm" in msg, msg)


def test_the_path_walk_descends_every_chain_node_and_no_other() raises:
    """Each chain node passes through to the leaf; each without its payload,
    CAST TO VARCHAR, and a JOIN raise.
    MUTANT: drop the PARTITION_TOPN arm and that chain raises."""
    var tags = _chain_tags()
    for i in range(len(tags)):
        assert_equal(
            _row_source_path_for_dispatch(_over(tags[i], _csv_scan(String("deep.csv")))),
            String("deep.csv"),
            String(Int(tags[i])),
        )
        var msg = _path_raises(_bare(tags[i]))
        assert_true("not a row-streaming single-child chain node" in msg, msg)
    var msg = _path_raises(_over(PLAN_CAST_TO_VARCHAR, _csv_scan()))
    assert_true("source path" in msg, msg)
    msg = _path_raises(_join(_csv_scan(), _csv_scan()))
    assert_true("source path" in msg, msg)


# =============================================================================
# The source variant
# =============================================================================


def test_the_variant_of_each_source_and_through_every_chain_node() raises:
    """The leaf's tag comes back unchanged, through every chain node.
    MUTANT: return SOURCE_VARIANT_CSV for every ROW leaf and the JSON and
    AVRO asserts fail."""
    assert_equal(_row_source_variant_for_dispatch(_csv_scan()), SOURCE_VARIANT_CSV)
    assert_equal(_row_source_variant_for_dispatch(_json_scan()), SOURCE_VARIANT_JSON)
    assert_equal(_row_source_variant_for_dispatch(_avro_scan()), SOURCE_VARIANT_AVRO)
    assert_equal(_row_source_variant_for_dispatch(_parquet_row_scan()), SOURCE_VARIANT_PARQUET)
    var tags = _chain_tags()
    for i in range(len(tags)):
        assert_equal(
            _row_source_variant_for_dispatch(_over(tags[i], _json_scan())),
            SOURCE_VARIANT_JSON,
            String(Int(tags[i])),
        )
        var msg = _variant_raises(_bare(tags[i]))
        assert_true("source variant" in msg, msg)


def test_the_variant_walk_refusals() raises:
    """MUTANT: drop the payload check on the scan and the bare scan aborts."""
    var msg = _variant_raises(_bare(PLAN_SCAN))
    assert_true("PLAN_SCAN missing ScanData" in msg, msg)
    msg = _variant_raises(_over(PLAN_CAST_TO_VARCHAR, _json_scan()))
    assert_true("source variant" in msg, msg)
    msg = _variant_raises(_union(_json_scan(), _json_scan()))
    assert_true("source variant" in msg, msg)


# =============================================================================
# The CSV dialect
# =============================================================================


def test_the_dialect_params_are_read_back_off_a_csv_leaf() raises:
    """MUTANT: read `delimiter` with the default and the pipe is lost."""
    var o = _row_source_csv_options_for_dispatch(
        _csv_scan_with(UInt8(ord("|")), False, 1)
    )
    assert_equal(Int(o.delimiter), ord("|"))
    assert_false(o.has_header)
    assert_equal(o.quote_style_tag, 1)
    var d = _row_source_csv_options_for_dispatch(
        _csv_scan_with(UInt8(ord(",")), True, 0)
    )
    assert_true(d.has_header)


def test_a_csv_leaf_missing_the_dialect_params_dispatches_comma_and_header() raises:
    """MUTANT: `get_i64`'s own default 0 for the delimiter and this reads a
    NUL delimiter with no header."""
    var o = _row_source_csv_options_for_dispatch(_csv_scan_without_params())
    assert_equal(Int(o.delimiter), ord(","))
    assert_true(o.has_header)
    assert_equal(o.quote_style_tag, Int(QUOTE_STYLE_TAG_RFC4180))


def test_a_leaf_without_a_csv_binding_takes_the_defaults() raises:
    """The legacy parquet-tag form and a JSON leaf carry no dialect.
    MUTANT: read the params of any binding and the JSON leaf raises."""
    var o = _row_source_csv_options_for_dispatch(_parquet_row_scan())
    assert_equal(Int(o.delimiter), ord(","))
    assert_true(o.has_header)
    var j = _row_source_csv_options_for_dispatch(_json_scan())
    assert_equal(j.quote_style_tag, Int(QUOTE_STYLE_TAG_RFC4180))


def test_the_dialect_walk_descends_every_chain_node_and_no_other() raises:
    """MUTANT: drop the TOPN arm and that chain raises."""
    var tags = _chain_tags()
    for i in range(len(tags)):
        var o = _row_source_csv_options_for_dispatch(
            _over(tags[i], _csv_scan_with(UInt8(ord(";")), True, 0))
        )
        assert_equal(Int(o.delimiter), ord(";"), String(Int(tags[i])))
        var msg = _csv_raises(_bare(tags[i]))
        assert_true("recover the CSV dialect" in msg, msg)
    var msg = _csv_raises(_bare(PLAN_SCAN))
    assert_true("PLAN_SCAN missing ScanData" in msg, msg)
    msg = _csv_raises(_over(PLAN_CAST_TO_VARCHAR, _csv_scan()))
    assert_true("recover the CSV dialect" in msg, msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
