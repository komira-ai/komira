"""Every branch of the re-route policy in `row_column_reroute`: the format
table, the type envelope, the leaf's own work, the ROW-leaf census over
every node kind, the three-valued verdict at each arm, and the defaulted
entry points.

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

from komira_dispatch_scan.row_column_reroute import (
    REROUTE_DEMOTE,
    REROUTE_DIRECT_BATCH,
    REROUTE_NONE,
    ROW_COLUMN_REROUTE_DEFAULT_ON,
    ROW_COLUMN_REROUTE_DEMOTE_DEFAULT_ON,
    _CENSUS_VETO,
    _row_leaf_census,
    _scan_leaf_census,
    column_decode_is_parallel_and_schema_directed,
    declared_schema_is_column_decodable,
    row_column_reroute_verdict,
    row_column_reroute_verdict_for_arm,
    row_plan_prefers_column_decode,
    row_plan_prefers_column_decode_for_arm,
    scan_leaf_carries_no_own_work,
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
# The format table and the type envelope
# =============================================================================


def test_the_format_table_admits_the_three_footerless_formats() raises:
    """MUTANT: drop the AVRO operand and the third assert fails."""
    assert_true(column_decode_is_parallel_and_schema_directed(SOURCE_VARIANT_JSON))
    assert_true(column_decode_is_parallel_and_schema_directed(SOURCE_VARIANT_CSV))
    assert_true(column_decode_is_parallel_and_schema_directed(SOURCE_VARIANT_AVRO))
    assert_false(column_decode_is_parallel_and_schema_directed(SOURCE_VARIANT_PARQUET))


def test_the_type_envelope_is_checked_per_field() raises:
    """All six envelope types pass together; INT32, FLOAT32 and a nested
    type veto; an empty schema is not decodable.
    MUTANT: drop the DECIMAL128 operand and the all-types schema fails."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("i"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.BOOL, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("d"), ArrowType.DATE32, False))
    sb.add_field(Field(String("m"), ArrowType.DECIMAL128, False))
    assert_true(declared_schema_is_column_decodable(sb.build()))
    assert_false(declared_schema_is_column_decodable(_schema_of(ArrowType.INT32)))
    assert_false(declared_schema_is_column_decodable(_schema_of(ArrowType.FLOAT32)))
    assert_false(declared_schema_is_column_decodable(_schema_of(ArrowType.LIST)))
    var empty = SchemaBuilder()
    assert_false(declared_schema_is_column_decodable(empty.build()))


def test_a_leaf_with_a_projection_or_a_filter_carries_work() raises:
    """MUTANT: drop the filter check and a filtered leaf is returned whole."""
    assert_true(scan_leaf_carries_no_own_work(_json_scan()))
    var proj = LogicalPlan.scan_from_source(
        SourceVariant(JsonSource(String("t.jsonl"), _schema())), _schema(),
        projection=Optional[List[String]](_one_key()),
    )
    assert_false(scan_leaf_carries_no_own_work(proj))
    var filt = LogicalPlan.scan_from_source(
        SourceVariant(JsonSource(String("t.jsonl"), _schema())), _schema(),
        filter=Optional[Expr](Expr.col_ref("a")),
    )
    assert_false(scan_leaf_carries_no_own_work(filt))
    assert_false(scan_leaf_carries_no_own_work(_bare(PLAN_SCAN)))


# =============================================================================
# The census
# =============================================================================


def test_one_scan_leaf_census() raises:
    """A decodable ROW leaf counts 1, a columnar leaf 0; a ROW leaf of a
    format outside the table, with no declared schema, or with a type
    outside the envelope vetoes, and so does a scan without its payload.
    MUTANT: drop the `not sd.schema` check and the schema-less leaf counts
    1 (the test aborts on the empty Optional)."""
    assert_equal(_scan_leaf_census(_json_scan()), 1)
    assert_equal(_scan_leaf_census(_csv_scan()), 1)
    assert_equal(_scan_leaf_census(_avro_scan()), 1)
    assert_equal(_scan_leaf_census(_parquet_scan()), 0)
    assert_equal(_scan_leaf_census(_parquet_row_scan()), _CENSUS_VETO)
    assert_equal(_scan_leaf_census(_json_scan(ArrowType.INT32)), _CENSUS_VETO)
    var no_schema = _json_scan()
    no_schema._scan.value()[].schema = None
    assert_equal(_scan_leaf_census(no_schema), _CENSUS_VETO)
    assert_equal(_scan_leaf_census(_bare(PLAN_SCAN)), _CENSUS_VETO)


def test_the_census_descends_every_single_child_node() raises:
    """Each single-child node passes its child's census through, and each
    one without its payload vetoes.
    MUTANT: drop any arm and that node falls to the final veto."""
    var tags = _single_child_tags()
    for i in range(len(tags)):
        assert_equal(_row_leaf_census(_over(tags[i], _json_scan())), 1, String(Int(tags[i])))
        assert_equal(_row_leaf_census(_over(tags[i], _parquet_scan())), 0)
        assert_equal(_row_leaf_census(_bare(tags[i])), _CENSUS_VETO)


def test_the_census_of_two_sided_nodes_sums_and_any_veto_wins() raises:
    """JOIN and AS OF join add their sides, and a veto on either side wins;
    a UNION adds its children and a veto in any child wins; each without
    its payload vetoes, and so does a node the walk does not know.
    MUTANT: return `l` for a JOIN and the right side's ROW leaf is lost."""
    assert_equal(_row_leaf_census(_join(_json_scan(), _csv_scan())), 2)
    assert_equal(_row_leaf_census(_join(_parquet_row_scan(), _csv_scan())), _CENSUS_VETO)
    assert_equal(_row_leaf_census(_join(_csv_scan(), _parquet_row_scan())), _CENSUS_VETO)
    assert_equal(_row_leaf_census(_asof(_json_scan(), _parquet_scan())), 1)
    assert_equal(_row_leaf_census(_asof(_parquet_row_scan(), _csv_scan())), _CENSUS_VETO)
    assert_equal(_row_leaf_census(_asof(_csv_scan(), _parquet_row_scan())), _CENSUS_VETO)
    assert_equal(_row_leaf_census(_union(_json_scan(), _avro_scan())), 2)
    assert_equal(_row_leaf_census(_union(_json_scan(), _parquet_row_scan())), _CENSUS_VETO)
    assert_equal(_row_leaf_census(_bare(PLAN_JOIN)), _CENSUS_VETO)
    assert_equal(_row_leaf_census(_bare(PLAN_ASOF_JOIN)), _CENSUS_VETO)
    assert_equal(_row_leaf_census(_bare(PLAN_UNION)), _CENSUS_VETO)
    assert_equal(
        _row_leaf_census(LogicalPlan.view_ref(String("v"), _schema())), _CENSUS_VETO
    )


# =============================================================================
# The verdict
# =============================================================================


def test_the_verdict_at_each_arm() raises:
    """Off is NONE; no ROW leaf or a veto is NONE; a bare decodable leaf is
    DIRECT; a leaf with its own work is NONE; a plan above re-routable
    leaves is DEMOTE with the demote on and NONE with it off.
    MUTANT: drop the `scan_leaf_carries_no_own_work` check and the
    projected leaf is returned DIRECT."""
    assert_equal(row_column_reroute_verdict_for_arm(_json_scan(), False, True), REROUTE_NONE)
    assert_equal(row_column_reroute_verdict_for_arm(_parquet_scan(), True, True), REROUTE_NONE)
    assert_equal(
        row_column_reroute_verdict_for_arm(_parquet_row_scan(), True, True), REROUTE_NONE
    )
    assert_equal(
        row_column_reroute_verdict_for_arm(_json_scan(), True, False), REROUTE_DIRECT_BATCH
    )
    var proj = LogicalPlan.scan_from_source(
        SourceVariant(JsonSource(String("t.jsonl"), _schema())), _schema(),
        projection=Optional[List[String]](_one_key()),
    )
    assert_equal(row_column_reroute_verdict_for_arm(proj, True, True), REROUTE_NONE)
    var above = _over(PLAN_FILTER, _csv_scan())
    assert_equal(row_column_reroute_verdict_for_arm(above, True, True), REROUTE_DEMOTE)
    assert_equal(row_column_reroute_verdict_for_arm(above, True, False), REROUTE_NONE)
    var two = _union(_json_scan(), _json_scan())
    assert_equal(row_column_reroute_verdict_for_arm(two, True, True), REROUTE_DEMOTE)


def test_the_defaults_are_on_and_the_defaulted_entries_use_them() raises:
    """Both switches default ON, and the defaulted entries equal the named
    arm at those defaults.
    MUTANT: pass `demote_enabled=False` in `row_column_reroute_verdict`
    and the filtered plan reads NONE."""
    assert_true(ROW_COLUMN_REROUTE_DEFAULT_ON)
    assert_true(ROW_COLUMN_REROUTE_DEMOTE_DEFAULT_ON)
    var above = _over(PLAN_FILTER, _csv_scan())
    assert_equal(row_column_reroute_verdict(above), REROUTE_DEMOTE)
    assert_equal(row_column_reroute_verdict(_json_scan()), REROUTE_DIRECT_BATCH)
    assert_equal(row_column_reroute_verdict(_parquet_scan()), REROUTE_NONE)
    assert_true(row_plan_prefers_column_decode(above))
    assert_false(row_plan_prefers_column_decode(_parquet_scan()))


def test_the_one_bit_question_at_a_named_arm() raises:
    """MUTANT: compare with `== REROUTE_NONE` and every answer inverts."""
    var above = _over(PLAN_SORT, _avro_scan())
    assert_true(row_plan_prefers_column_decode_for_arm(above, True, True))
    assert_false(row_plan_prefers_column_decode_for_arm(above, True, False))
    assert_false(row_plan_prefers_column_decode_for_arm(above, False, True))
    assert_true(row_plan_prefers_column_decode_for_arm(_json_scan(), True, False))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
