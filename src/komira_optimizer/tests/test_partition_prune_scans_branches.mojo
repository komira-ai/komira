"""Branch tests of `komira_optimizer.partition_prune_scans`.

`test_partition_prune_scans` covers the main pruning cases on a Filter at
the plan root. These tests reach the rest: the walk under every node kind,
the shapes the pass must leave alone, the comparison flips, the all-pruned
case with a residual, the scan fields the rebuild must carry over, and the
value parser and comparators directly. Each test names the defect it
catches.
"""

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_LITERAL,
    BIN_ADD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
)
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import TableStats, ColumnStats
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ScanData,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    SOURCE_IN_MEMORY,
    JOIN_INNER,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant

from komira_optimizer.partition_prune_scans import (
    partition_prune_scans,
    partition_prune_scans_inplace,
    _classify_partition_conjunct,
    _flip_cmp,
    _value_satisfies,
    _parse_int64,
    _cmp_i64,
    _cmp_str,
)


# =============================================================================
# Fixtures
# =============================================================================


def _data_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, nullable=False))
    return sb.build()


def _full_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, nullable=False))
    sb.add_field(Field("year", ArrowType.INT64, nullable=False))
    return sb.build()


def _year_cols() -> List[Field]:
    var c = List[Field]()
    c.append(Field("year", ArrowType.INT64, nullable=False))
    return c^


def _year_source(var name: Optional[String] = None, mtime: UInt64 = 0) raises -> ParquetSource:
    """year=2022 .. 2025, one file each."""
    var paths = List[String]()
    var pvals = List[List[String]]()
    for y in range(2022, 2026):
        paths.append("d/year=" + String(y) + "/f.parquet")
        var row = List[String]()
        row.append(String(y))
        pvals.append(row^)
    return ParquetSource.partitioned(paths^, _data_schema(), _year_cols(), pvals^, name^, mtime)


def _year_scan() raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(SourceVariant(_year_source()), _full_schema())


def _cmp(op: UInt8, col: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(v)))


def _cmp_lit_left(op: UInt8, v: Int) -> Expr:
    return Expr.binary(op, Expr.literal(ScalarValue.from_int(v)), Expr.col_ref("year"))


def _paths_of_scan(scan: LogicalPlan) raises -> Int:
    assert_equal(scan.tag, PLAN_SCAN)
    return len(scan._scan.value()[].source._parquet.value().paths)


def _paths(plan: LogicalPlan) raises -> Int:
    """Path count of the scan at `plan` or directly under its Filter."""
    if plan.tag == PLAN_FILTER:
        return _paths_of_scan(plan._filter.value()[].child[])
    return _paths_of_scan(plan)


def _one(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


# =============================================================================
# The plan walk
# =============================================================================


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    var desc = List[Bool]()
    desc.append(False)
    if kind == 0:
        var exprs = ExprArray()
        exprs.append(Expr.col_ref("id"))
        return LogicalPlan.project(exprs^, child^)
    if kind == 1:
        var gb = ExprArray()
        gb.append(Expr.col_ref("id"))
        return LogicalPlan.aggregate(gb^, AggExprArray(), child^)
    if kind == 2:
        return LogicalPlan.sort(_one("id"), desc^, child^)
    if kind == 3:
        return LogicalPlan.limit(5, child^)
    if kind == 4:
        return LogicalPlan.distinct(None, child^)
    if kind == 5:
        return LogicalPlan.topn(_one("id"), desc^, 5, child^)
    if kind == 6:
        return LogicalPlan.join(child^, _year_scan(), _one("id"), _one("id"), JOIN_INNER)
    if kind == 7:
        return LogicalPlan.join(_year_scan(), child^, _one("id"), _one("id"), JOIN_INNER)
    if kind == 8:
        return LogicalPlan.partition_by(_one("id"), _one("id"), desc^, List[PartitionExpr](), child^)
    if kind == 9:
        return LogicalPlan.partition_topn(_one("id"), _one("id"), desc^, 1, child^)
    raise Error("test: unknown wrapper kind " + String(kind))


def _child_of(plan: LogicalPlan, kind: Int) -> LogicalPlan:
    if kind == 0:
        return plan._project.value()[].child[].copy()
    if kind == 1:
        return plan._aggregate.value()[].child[].copy()
    if kind == 2:
        return plan._sort.value()[].child[].copy()
    if kind == 3:
        return plan._limit.value()[].child[].copy()
    if kind == 4:
        return plan._distinct.value()[].child[].copy()
    if kind == 5:
        return plan._topn.value()[].child[].copy()
    if kind == 6:
        return plan._join.value()[].left[].copy()
    if kind == 7:
        return plan._join.value()[].right[].copy()
    if kind == 8:
        return plan._partition_by.value()[].child[].copy()
    return plan._partition_topn.value()[].child[].copy()


def test_walk_prunes_under_every_node_kind() raises:
    """`Filter(year = 2024)` over the 4-file scan, under Project, Aggregate,
    Sort, Limit, Distinct, TopN, either input of a Join, PartitionBy and
    PartitionTopN, is pruned to 1 file and the Filter collapses.

    Catches: any one recursion arm removed (that scan keeps 4 files); a
    Join arm walking one input only."""
    for kind in range(10):
        var plan = _wrap(kind, LogicalPlan.filter(_cmp(BIN_EQ, "year", 2024), _year_scan()))
        partition_prune_scans_inplace(plan)
        assert_equal(_paths(_child_of(plan, kind)), 1)


# =============================================================================
# Shapes the pass leaves alone
# =============================================================================


def test_filters_it_cannot_prune_are_unchanged() raises:
    """Left as they are: a Filter over a Project (not directly over the
    scan); a Filter over a scan-tagged node without scan data; a Filter over
    an in-memory scan; a partitioned scan whose path list is empty; a lazy
    dir-scanning Hive scan.

    Catches: each guard removed. Without the Scan guard the Project is read
    as a scan; without the payload guard an empty Optional is read; without
    the Parquet guard an in-memory source is read as Parquet; without the empty
    path guard `paths[0]` is read past the end; without the Hive guard the
    base directory is "pruned" and the predicate dropped although the
    attach_hive_predicate pass (not in this tree) is designed to own it."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("year"))
    var over_project = LogicalPlan.filter(
        _cmp(BIN_EQ, "year", 2024), LogicalPlan.project(exprs^, _year_scan())
    )
    var out = partition_prune_scans(over_project^)
    assert_equal(out.tag, PLAN_FILTER)
    assert_equal(_paths_of_scan(out._filter.value()[].child[]._project.value()[].child[]), 4)

    var bare = LogicalPlan(PLAN_SCAN, _full_schema())
    var out2 = partition_prune_scans(LogicalPlan.filter(_cmp(BIN_EQ, "year", 2024), bare^))
    assert_equal(out2.tag, PLAN_FILTER)
    if out2._filter.value()[].child[]._scan:
        raise Error("test: the payload-less scan node gained scan data")

    var mem = LogicalPlan.scan("t", SOURCE_IN_MEMORY, _full_schema())
    var out3 = partition_prune_scans(LogicalPlan.filter(_cmp(BIN_EQ, "year", 2024), mem^))
    assert_equal(out3.tag, PLAN_FILTER)

    var src = _year_source()
    src.paths = List[String]()
    src.partition_values = List[List[String]]()
    var no_paths = LogicalPlan.scan_from_source(SourceVariant(src^), _full_schema())
    var out4 = partition_prune_scans(LogicalPlan.filter(_cmp(BIN_EQ, "year", 2024), no_paths^))
    assert_equal(out4.tag, PLAN_FILTER)
    assert_equal(_paths(out4), 0)

    var hive = ParquetSource.dir_scan_hive("d/", _data_schema(), _year_cols())
    var hscan = LogicalPlan.scan_from_source(SourceVariant(hive^), _full_schema())
    var out5 = partition_prune_scans(LogicalPlan.filter(_cmp(BIN_EQ, "year", 2024), hscan^))
    assert_equal(out5.tag, PLAN_FILTER)
    assert_equal(_paths(out5), 1)
    assert_equal(
        out5._filter.value()[].child[]._scan.value()[].source._parquet.value().paths[0],
        String("d/"),
    )


def test_conjuncts_that_are_not_prunable_stay() raises:
    """None of these prunes, so the Filter and all 4 files stay:
    `year = 2022 OR year = 2023`; `NOT(year = 2022)`; `year = id` (two
    columns); `100 <= id` (literal on the left, not a partition column).

    Catches: an OR (or any non-comparison op) treated as a comparison; a
    non-binary conjunct classified; a column-to-column comparison read as
    a literal one; the literal-on-left case skipping its partition-column
    check."""
    var preds = ExprArray()
    preds.append(Expr.binary(BIN_OR, _cmp(BIN_EQ, "year", 2022), _cmp(BIN_EQ, "year", 2023)))
    preds.append(Expr.unary(UN_NOT, _cmp(BIN_EQ, "year", 2022)))
    preds.append(Expr.binary(BIN_EQ, Expr.col_ref("year"), Expr.col_ref("id")))
    preds.append(Expr.binary(BIN_LE, Expr.literal(ScalarValue.from_int(100)), Expr.col_ref("id")))
    for i in range(len(preds)):
        var out = partition_prune_scans(LogicalPlan.filter(preds[i].copy(), _year_scan()))
        assert_equal(out.tag, PLAN_FILTER)
        assert_equal(_paths(out), 4)


# =============================================================================
# Comparison flips and the all-pruned case
# =============================================================================


def test_literal_on_the_left_flips_each_comparison() raises:
    """With the literal on the left: `2024 > year` keeps 2022, 2023;
    `2024 >= year` keeps 2022..2024; `2023 < year` keeps 2024, 2025;
    `2023 <= year` keeps 2023..2025.

    Catches: any flip missing or wrong (`2024 > year` read as
    `year > 2024` keeps 1 file, not 2); the LE / GT comparators wrong."""
    assert_equal(_paths(partition_prune_scans(LogicalPlan.filter(_cmp_lit_left(BIN_GT, 2024), _year_scan()))), 2)
    assert_equal(_paths(partition_prune_scans(LogicalPlan.filter(_cmp_lit_left(BIN_GE, 2024), _year_scan()))), 3)
    assert_equal(_paths(partition_prune_scans(LogicalPlan.filter(_cmp_lit_left(BIN_LT, 2023), _year_scan()))), 2)
    assert_equal(_paths(partition_prune_scans(LogicalPlan.filter(_cmp_lit_left(BIN_LE, 2023), _year_scan()))), 3)
    assert_equal(_flip_cmp(BIN_EQ), BIN_EQ)
    assert_equal(_flip_cmp(BIN_NE), BIN_NE)


def test_all_pruned_installs_false_with_and_without_a_residual() raises:
    """`year = 1999` alone leaves the Filter with predicate literal FALSE
    over one kept file. `year = 1999 AND id >= 100 AND id < 900` keeps the
    two residual conjuncts AND-ed in order and appends `AND FALSE`.

    Catches: the FALSE predicate not installed (every row of the kept file
    would pass); FALSE not appended to a residual; a residual conjunct
    dropped or reordered."""
    var out = partition_prune_scans(LogicalPlan.filter(_cmp(BIN_EQ, "year", 1999), _year_scan()))
    assert_equal(out.tag, PLAN_FILTER)
    assert_equal(_paths(out), 1)
    ref p = out._filter.value()[].predicate
    assert_equal(p.tag, EXPR_LITERAL)
    assert_false(p.literal_value().bool_val)

    var pred = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_AND, _cmp(BIN_EQ, "year", 1999), _cmp(BIN_GE, "id", 100)),
        _cmp(BIN_LT, "id", 900),
    )
    var out2 = partition_prune_scans(LogicalPlan.filter(pred^, _year_scan()))
    assert_equal(out2.tag, PLAN_FILTER)
    assert_equal(_paths(out2), 1)
    ref p2 = out2._filter.value()[].predicate
    assert_equal(p2.binary_op(), BIN_AND)
    assert_equal(p2.binary_right_ref().tag, EXPR_LITERAL)
    assert_false(p2.binary_right_ref().literal_value().bool_val)
    ref chain = p2.binary_left_ref()
    assert_equal(chain.binary_op(), BIN_AND)
    assert_equal(chain.binary_left_ref().binary_op(), BIN_GE)
    assert_equal(chain.binary_right_ref().binary_op(), BIN_LT)


def test_rebuild_keeps_every_scan_field() raises:
    """`year >= 2024` over a scan carrying a source name, an mtime, a
    projection, a pushed-down filter, a row count, table stats and its
    explicit schema: the pruned scan keeps every one of them, and each kept
    path keeps its own partition values.

    Catches: any field dropped by the ScanData rebuild (the projection, the
    pushed filter, the row count, the stats, the schema); the source name
    or mtime lost; partition values not kept aligned with their paths."""
    var src = _year_source(Optional(String("events")), UInt64(77))
    var stats = TableStats(40, List[String](), List[ColumnStats]())
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(src^), _full_schema(),
        Optional(_one("year")),
        Optional(_cmp(BIN_GT, "id", 0)),
        Optional(40),
        Optional(stats^),
    )
    var out = partition_prune_scans(LogicalPlan.filter(_cmp(BIN_GE, "year", 2024), scan^))
    assert_equal(out.tag, PLAN_SCAN)
    ref sd = out._scan.value()[]
    ref ps = sd.source._parquet.value()
    assert_equal(len(ps.paths), 2)
    assert_equal(ps.paths[0], String("d/year=2024/f.parquet"))
    assert_equal(ps.partition_values[0][0], String("2024"))
    assert_equal(ps.paths[1], String("d/year=2025/f.parquet"))
    assert_equal(ps.partition_values[1][0], String("2025"))
    assert_equal(len(ps.partition_cols), 1)
    assert_equal(ps.name.value(), String("events"))
    assert_equal(ps._mtime_ns, UInt64(77))
    assert_equal(len(sd.projection.value()), 1)
    assert_equal(sd.projection.value()[0], String("year"))
    assert_equal(sd.filter.value().binary_op(), BIN_GT)
    assert_equal(sd.row_count.value(), 40)
    assert_equal(sd.table_stats.value().row_count, 40)
    assert_equal(sd.schema.value().num_columns(), 2)

    # A ScanData with no explicit schema, pushed filter, projection, row
    # count or stats stays without them (the None arm of each copy).
    var bare = LogicalPlan(PLAN_SCAN, _full_schema())
    bare._scan = OwnedPointer(ScanData(SourceVariant(_year_source()), None, None, None))
    var out2 = partition_prune_scans(LogicalPlan.filter(_cmp(BIN_GE, "year", 2024), bare^))
    ref sd2 = out2._scan.value()[]
    assert_equal(len(sd2.source._parquet.value().paths), 2)
    assert_true(not sd2.schema)
    assert_true(not sd2.projection)
    assert_true(not sd2.filter)
    assert_true(not sd2.row_count)
    assert_true(not sd2.table_stats)


# =============================================================================
# Classifier, parser and comparators, called directly
# =============================================================================


def test_classify_orients_and_reports() raises:
    """`_classify_partition_conjunct` over partition columns [year]:
    `year < 5` gives (0, LT, 5); `5 < year` gives (0, GT, 5); `id < 5` and
    `5 < id` are refused.

    Catches: the out-parameters not written; the literal-left case not
    flipping; a non-partition column accepted on either side."""
    var names = _one("year")
    var idx = -1
    var op: UInt8 = 0
    var lit = ScalarValue.from_bool(False)
    assert_true(_classify_partition_conjunct(_cmp(BIN_LT, "year", 5), names, idx, op, lit))
    assert_equal(idx, 0)
    assert_equal(op, BIN_LT)
    assert_equal(lit.int_val, Int64(5))
    assert_true(_classify_partition_conjunct(
        Expr.binary(BIN_LT, Expr.literal(ScalarValue.from_int(5)), Expr.col_ref("year")),
        names, idx, op, lit,
    ))
    assert_equal(op, BIN_GT)
    assert_false(_classify_partition_conjunct(_cmp(BIN_LT, "id", 5), names, idx, op, lit))
    assert_false(_classify_partition_conjunct(
        Expr.binary(BIN_LT, Expr.literal(ScalarValue.from_int(5)), Expr.col_ref("id")),
        names, idx, op, lit,
    ))


def test_value_satisfies_keeps_what_it_cannot_judge() raises:
    """`_value_satisfies` compares an INT64 value numerically and DATE32 /
    STRING values as text, and answers True (keep the path) for a literal
    of the wrong kind, an unparseable INT64 value, or another column type.

    Catches: a DATE32 or STRING value compared as a number, or not compared
    at all; a type mismatch or parse failure answered False (a path pruned
    on a guess)."""
    var i2024 = ScalarValue.from_int(2024)
    assert_true(_value_satisfies("2024", BIN_EQ, i2024, ArrowType.INT64))
    assert_false(_value_satisfies("2023", BIN_EQ, i2024, ArrowType.INT64))
    assert_true(_value_satisfies("abc", BIN_EQ, i2024, ArrowType.INT64))
    assert_true(_value_satisfies("2023", BIN_EQ, ScalarValue.from_string("x"), ArrowType.INT64))

    var d = ScalarValue.from_string("2027-02-01")
    assert_true(_value_satisfies("2027-01-31", BIN_LT, d, ArrowType.DATE32))
    assert_false(_value_satisfies("2027-02-02", BIN_LT, d, ArrowType.DATE32))
    assert_true(_value_satisfies("2027-02-02", BIN_LT, i2024, ArrowType.DATE32))

    var eu = ScalarValue.from_string("eu")
    assert_true(_value_satisfies("eu", BIN_EQ, eu, ArrowType.STRING))
    assert_false(_value_satisfies("us", BIN_EQ, eu, ArrowType.STRING))
    assert_true(_value_satisfies("us", BIN_EQ, i2024, ArrowType.STRING))

    assert_true(_value_satisfies("1.5", BIN_EQ, i2024, ArrowType.FLOAT64))


def _parse_raises(s: String) -> Bool:
    try:
        _ = _parse_int64(s)
    except:
        return True
    return False


def test_parse_int64() raises:
    """`_parse_int64` reads signed decimals of up to 18 digits and raises on
    an empty string, a bare sign, a non-digit and a 19th digit.

    Catches: a sign ignored; `+` rejected; a bad byte accepted; the
    overflow guard removed or off by one."""
    assert_equal(_parse_int64("0"), Int64(0))
    assert_equal(_parse_int64("-17"), Int64(-17))
    assert_equal(_parse_int64("+42"), Int64(42))
    assert_equal(_parse_int64("999999999999999999"), Int64(999999999999999999))
    assert_true(_parse_raises(""))
    assert_true(_parse_raises("-"))
    assert_true(_parse_raises("+"))
    assert_true(_parse_raises("12a"))
    assert_true(_parse_raises("1000000000000000000"))


def _add3(mut out: List[Bool], a: Bool, b: Bool, c: Bool):
    out.append(a)
    out.append(b)
    out.append(c)


def test_comparators_every_op() raises:
    """`_cmp_i64` and `_cmp_str`: each of the six comparisons at a value
    below, at and above the other side, and True for an op that is not a
    comparison.

    Catches: any comparison wired to the wrong operator; an unknown op
    answered False (a path pruned)."""
    var ops = List[UInt8]()
    ops.append(BIN_EQ)
    ops.append(BIN_NE)
    ops.append(BIN_LT)
    ops.append(BIN_LE)
    ops.append(BIN_GT)
    ops.append(BIN_GE)
    # Expected results for a = 1, 2, 3 against b = 2, per op.
    var want = List[Bool]()
    _add3(want, False, True, False)  # EQ
    _add3(want, True, False, True)  # NE
    _add3(want, True, False, False)  # LT
    _add3(want, True, True, False)  # LE
    _add3(want, False, False, True)  # GT
    _add3(want, False, True, True)  # GE
    var strs = List[String]()
    strs.append("a")
    strs.append("b")
    strs.append("c")
    for k in range(6):
        for a in range(3):
            assert_equal(_cmp_i64(Int64(a + 1), ops[k], Int64(2)), want[k * 3 + a])
            assert_equal(_cmp_str(strs[a], ops[k], "b"), want[k * 3 + a])
    assert_true(_cmp_i64(Int64(1), BIN_ADD, Int64(2)))
    assert_true(_cmp_str("a", BIN_ADD, "b"))


def main() raises:
    test_walk_prunes_under_every_node_kind()
    test_filters_it_cannot_prune_are_unchanged()
    test_conjuncts_that_are_not_prunable_stay()
    test_literal_on_the_left_flips_each_comparison()
    test_all_pruned_installs_false_with_and_without_a_residual()
    test_rebuild_keeps_every_scan_field()
    test_classify_orients_and_reports()
    test_value_satisfies_keeps_what_it_cannot_judge()
    test_parse_int64()
    test_comparators_every_op()
    print("All partition_prune_scans branch tests passed.")
