"""Every branch of `lower_untyped`'s three predicates: the multi-file
parquet scan shapes, the routing predicate that always answers False, and
the ROW-source signal walk over every node kind.

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

from komira_dispatch_scan.lower_untyped import (
    _has_row_source_signal,
    _is_multi_file_parquet_scan,
    route_plan_shape_row_streaming,
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


def _two_paths() -> List[String]:
    var p = List[String]()
    p.append(String("a.parquet"))
    p.append(String("b.parquet"))
    return p^


def _source_scan(var ps: ParquetSource) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(SourceVariant(ps^), _schema())


def _part_cols() -> List[Field]:
    var c = List[Field]()
    c.append(Field(String("year"), ArrowType.INT64, False))
    return c^


# =============================================================================
# _is_multi_file_parquet_scan
# =============================================================================


def test_multi_file_and_eager_hive_scans_are_multi_file() raises:
    """MUTANT: drop `or ps.is_partitioned()` and the one-file Hive scan
    reads False."""
    var multi = _source_scan(
        ParquetSource.partitioned(
            _two_paths(), _schema(), List[Field](), List[List[String]]()
        )
    )
    assert_true(_is_multi_file_parquet_scan(multi))
    var one_path = List[String]()
    one_path.append(String("year=2031/a.parquet"))
    var vals = List[List[String]]()
    var row = List[String]()
    row.append(String("2031"))
    vals.append(row^)
    var hive = _source_scan(
        ParquetSource.partitioned(one_path^, _schema(), _part_cols(), vals^)
    )
    assert_true(_is_multi_file_parquet_scan(hive))


def test_every_other_shape_is_not_multi_file() raises:
    """A single plain file, the lazy dir-scan Hive shape, a non-scan, a scan
    without its payload, a non-parquet scan, and a parquet-tag scan without
    its parquet arm.
    MUTANT: drop the `is_dir_scan_hive` check and the lazy shape reads True
    (it carries partition columns)."""
    assert_false(_is_multi_file_parquet_scan(_parquet_scan()))
    var lazy = _source_scan(
        ParquetSource.dir_scan_hive(String("base/"), _schema(), _part_cols())
    )
    assert_false(_is_multi_file_parquet_scan(lazy))
    assert_false(_is_multi_file_parquet_scan(_over(PLAN_LIMIT, _parquet_scan())))
    assert_false(_is_multi_file_parquet_scan(_bare(PLAN_SCAN)))
    assert_false(_is_multi_file_parquet_scan(_json_scan()))
    var no_arm = _parquet_scan()
    no_arm._scan.value()[].source._parquet = None
    assert_false(_is_multi_file_parquet_scan(no_arm))


# =============================================================================
# route_plan_shape_row_streaming
# =============================================================================


def test_no_plan_routes_to_a_row_executor() raises:
    """MUTANT: return `_has_row_source_signal(plan)` and the CSV plan reads
    True."""
    assert_false(route_plan_shape_row_streaming(_csv_scan()))
    assert_false(route_plan_shape_row_streaming(_over(PLAN_FILTER, _json_scan())))
    assert_false(route_plan_shape_row_streaming(_parquet_scan()))


# =============================================================================
# _has_row_source_signal
# =============================================================================


def test_a_row_scan_carries_the_signal_and_a_columnar_one_does_not() raises:
    """MUTANT: compare `source_kind != SOURCE_KIND_ROW` and both invert."""
    assert_true(_has_row_source_signal(_csv_scan()))
    assert_true(_has_row_source_signal(_parquet_row_scan()))
    assert_false(_has_row_source_signal(_parquet_scan()))
    assert_false(_has_row_source_signal(_bare(PLAN_SCAN)))


def test_the_signal_walk_descends_every_single_child_node() raises:
    """MUTANT: drop the CAST TO VARCHAR arm and a ROW scan under it is
    missed."""
    var tags = _single_child_tags()
    for i in range(len(tags)):
        assert_true(_has_row_source_signal(_over(tags[i], _json_scan())), String(Int(tags[i])))
        assert_false(_has_row_source_signal(_over(tags[i], _parquet_scan())))
        assert_false(_has_row_source_signal(_bare(tags[i])))


def test_the_signal_walk_reads_both_sides_and_every_union_child() raises:
    """MUTANT: return after the left side and a ROW right side is missed."""
    assert_true(_has_row_source_signal(_join(_csv_scan(), _parquet_scan())))
    assert_true(_has_row_source_signal(_join(_parquet_scan(), _csv_scan())))
    assert_false(_has_row_source_signal(_join(_parquet_scan(), _parquet_scan())))
    assert_true(_has_row_source_signal(_asof(_avro_scan(), _parquet_scan())))
    assert_true(_has_row_source_signal(_asof(_parquet_scan(), _avro_scan())))
    assert_false(_has_row_source_signal(_asof(_parquet_scan(), _parquet_scan())))
    assert_true(_has_row_source_signal(_union(_parquet_scan(), _json_scan())))
    assert_false(_has_row_source_signal(_union(_parquet_scan(), _parquet_scan())))
    assert_false(_has_row_source_signal(_bare(PLAN_JOIN)))
    assert_false(_has_row_source_signal(_bare(PLAN_ASOF_JOIN)))
    assert_false(_has_row_source_signal(_bare(PLAN_UNION)))
    assert_false(_has_row_source_signal(LogicalPlan.view_ref(String("v"), _schema())))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
