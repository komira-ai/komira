"""Tests of `komira_optimizer.attach_hive_predicate`.

The pass attaches the partition predicate of a Filter (or an empty one) to a
lazy dir-scanning Hive scan and leaves the data residual on the Filter. Each
test names the defect it catches.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_AND, BIN_EQ, BIN_GT
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_S3
from komira_plan_stats.table_stats import TableStats, ColumnStats
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
    JOIN_INNER,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant, SOURCE_VARIANT_PARQUET

from komira_optimizer.attach_hive_predicate import (
    attach_hive_predicate,
    attach_hive_predicate_inplace,
    _stamp_fs_descriptor_on_scan,
)


# =============================================================================
# Fixtures
# =============================================================================


def _data_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, nullable=False))
    return sb.build()


def _full_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, nullable=False))
    sb.add_field(Field("p", ArrowType.INT64, nullable=False))
    return sb.build()


def _part_cols() -> List[Field]:
    var c = List[Field]()
    c.append(Field("p", ArrowType.INT64, nullable=False))
    return c^


def _hive_scan() raises -> LogicalPlan:
    var src = ParquetSource.dir_scan_hive("d/", _data_schema(), _part_cols())
    return LogicalPlan.scan_from_source(SourceVariant(src^), _full_schema())


def _plain_scan() raises -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _full_schema())


def _cmp(op: UInt8, col: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(v)))


def _p_and_v() -> Expr:
    return Expr.binary(BIN_AND, _cmp(BIN_EQ, "p", 1), _cmp(BIN_GT, "v", 3))


def _pod_constraints(scan: LogicalPlan) raises -> Int:
    """Constraint count of the scan's attached predicate; -1 when none."""
    assert_equal(scan.tag, PLAN_SCAN)
    ref psrc = scan._scan.value()[].source._parquet.value()
    if not psrc.hive_predicate:
        return -1
    return psrc.hive_predicate.value().num_constraints()


def _one(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


# =============================================================================
# The attach
# =============================================================================


def test_partition_conjunct_attached_residual_kept() raises:
    """Filter(p = 1 AND v > 3) over a dir-scan Hive scan partitioned by p: the
    scan gets a predicate with one constraint, on p, and the Filter keeps
    only `v > 3`.

    Catches: the residual not carved (the Filter keeps both conjuncts); the
    predicate not attached."""
    var out = attach_hive_predicate(LogicalPlan.filter(_p_and_v(), _hive_scan()))
    assert_equal(out.tag, PLAN_FILTER)
    ref fd = out._filter.value()[]
    assert_equal(fd.predicate.binary_op(), BIN_GT)
    assert_equal(fd.predicate.binary_left_ref().col_ref_name(), String("v"))
    assert_equal(_pod_constraints(fd.child[]), 1)
    ref pod = fd.child[]._scan.value()[].source._parquet.value().hive_predicate.value()
    assert_equal(pod.constraints[0].col, String("p"))


def test_partition_only_filter_collapses_to_the_scan() raises:
    """Filter(p = 1): the plan becomes the scan, carrying a one-constraint
    predicate.

    Catches: the Filter kept when nothing is left of it."""
    var out = attach_hive_predicate(LogicalPlan.filter(_cmp(BIN_EQ, "p", 1), _hive_scan()))
    assert_equal(out.tag, PLAN_SCAN)
    assert_equal(_pod_constraints(out), 1)


def test_bare_hive_scan_gets_an_empty_predicate() raises:
    """A dir-scan Hive scan with no Filter gets `PartitionPredicatePod.empty()`:
    0 constraints, not None.

    Catches: the bare-scan attach skipped (None)."""
    var out = attach_hive_predicate(_hive_scan())
    assert_equal(_pod_constraints(out), 0)


def test_plain_parquet_scan_is_unchanged() raises:
    """Filter(p = 1 AND v > 3) over a single-file Parquet scan, and the bare
    scan: no predicate attached and the Filter keeps both conjuncts.

    Catches: the dir-scan Hive guard removed (a plain scan gets a predicate
    and loses its filter conjunct)."""
    var out = attach_hive_predicate(LogicalPlan.filter(_p_and_v(), _plain_scan()))
    assert_equal(out.tag, PLAN_FILTER)
    assert_equal(out._filter.value()[].predicate.binary_op(), BIN_AND)
    assert_equal(_pod_constraints(out._filter.value()[].child[]), -1)
    assert_equal(_pod_constraints(attach_hive_predicate(_plain_scan())), -1)


def test_second_run_changes_nothing() raises:
    """Running the pass twice over Filter(p = 1 AND v > 3) and over
    Filter(p = 1) gives the same constraint counts and the same residual.

    Catches: the already-attached guard removed from either attach (the
    second run replaces the predicate with one split from the residual, or
    with `empty()`)."""
    var once = attach_hive_predicate(LogicalPlan.filter(_p_and_v(), _hive_scan()))
    var twice = attach_hive_predicate(once^)
    assert_equal(twice.tag, PLAN_FILTER)
    assert_equal(twice._filter.value()[].predicate.binary_op(), BIN_GT)
    assert_equal(_pod_constraints(twice._filter.value()[].child[]), 1)

    var collapsed = attach_hive_predicate(LogicalPlan.filter(_cmp(BIN_EQ, "p", 1), _hive_scan()))
    var again = attach_hive_predicate(collapsed^)
    assert_equal(_pod_constraints(again), 1)


def test_scan_fields_survive_the_reseat() raises:
    """A dir-scan Hive scan with a projection, a pushed filter, a row count
    and table stats keeps all four after the attach.

    Catches: the reseat dropping a field."""
    var src = ParquetSource.dir_scan_hive("d/", _data_schema(), _part_cols())
    var stats = TableStats(9, List[String](), List[ColumnStats]())
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(src^), _full_schema(), Optional(_one("v")), Optional(_cmp(BIN_GT, "v", 0)),
        Optional(9), Optional(stats^),
    )
    var out = attach_hive_predicate(scan^)
    ref sd = out._scan.value()[]
    assert_equal(sd.projection.value()[0], String("v"))
    assert_true(Bool(sd.filter))
    assert_equal(sd.row_count.value(), 9)
    assert_equal(sd.table_stats.value().row_count, 9)
    assert_true(Bool(sd.schema))
    assert_equal(_pod_constraints(out), 0)


# =============================================================================
# The walk and the shapes left alone
# =============================================================================


def test_walk_reaches_every_node_kind() raises:
    """Filter(p = 1 AND v > 3) over a Hive scan under Filter, Project,
    Aggregate, Sort, Limit, Distinct, TopN, PartitionBy, PartitionTopN and
    either side of a Join gets its predicate.

    Catches: any one recursion arm removed."""
    var desc = List[Bool]()
    desc.append(False)
    for kind in range(11):
        var f = LogicalPlan.filter(_p_and_v(), _hive_scan())
        var plan: LogicalPlan
        if kind == 0:
            plan = LogicalPlan.filter(_cmp(BIN_GT, "v", 0), f^)
        elif kind == 1:
            var e = ExprArray()
            e.append(Expr.col_ref("v"))
            plan = LogicalPlan.project(e^, f^)
        elif kind == 2:
            var aggs = AggExprArray()
            aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("v")), Optional(String("s"))))
            plan = LogicalPlan.aggregate(ExprArray(), aggs^, f^)
        elif kind == 3:
            plan = LogicalPlan.sort(_one("v"), desc.copy(), f^)
        elif kind == 4:
            plan = LogicalPlan.limit(2, f^)
        elif kind == 5:
            plan = LogicalPlan.distinct(None, f^)
        elif kind == 6:
            plan = LogicalPlan.topn(_one("v"), desc.copy(), 2, f^)
        elif kind == 7:
            plan = LogicalPlan.partition_by(_one("v"), _one("v"), desc.copy(), List[PartitionExpr](), f^)
        elif kind == 8:
            plan = LogicalPlan.partition_topn(_one("v"), _one("v"), desc.copy(), 1, f^)
        elif kind == 9:
            plan = LogicalPlan.join(f^, _plain_scan(), _one("v"), _one("v"), JOIN_INNER)
        else:
            plan = LogicalPlan.join(_plain_scan(), f^, _one("v"), _one("v"), JOIN_INNER)
        attach_hive_predicate_inplace(plan)
        var found: LogicalPlan
        if kind == 0:
            found = plan._filter.value()[].child[].copy()
        elif kind == 1:
            found = plan._project.value()[].child[].copy()
        elif kind == 2:
            found = plan._aggregate.value()[].child[].copy()
        elif kind == 3:
            found = plan._sort.value()[].child[].copy()
        elif kind == 4:
            found = plan._limit.value()[].child[].copy()
        elif kind == 5:
            found = plan._distinct.value()[].child[].copy()
        elif kind == 6:
            found = plan._topn.value()[].child[].copy()
        elif kind == 7:
            found = plan._partition_by.value()[].child[].copy()
        elif kind == 8:
            found = plan._partition_topn.value()[].child[].copy()
        elif kind == 9:
            found = plan._join.value()[].left[].copy()
        else:
            found = plan._join.value()[].right[].copy()
        assert_equal(found.tag, PLAN_FILTER, "kind " + String(kind))
        assert_equal(_pod_constraints(found._filter.value()[].child[]), 1, "kind " + String(kind))


def _parquet_tag_without_payload() raises -> LogicalPlan:
    """A scan whose SourceVariant says Parquet but holds no ParquetSource.

    The payload is cleared after construction: the ScanData constructor (and
    so any copy of this plan) reads it, so the plan is only ever moved."""
    var scan = _plain_scan()
    scan._scan.value()[].source._parquet = None
    return scan^


def test_shapes_left_alone() raises:
    """Unchanged, under a Filter and bare: a Filter over a Project; a scan
    node without scan data; an in-memory scan; a Parquet-tagged source
    without a Parquet payload.

    Catches: each guard removed (a non-scan read as a scan, an empty
    Optional read)."""
    var e = ExprArray()
    e.append(Expr.col_ref("v"))
    var over_project = attach_hive_predicate(LogicalPlan.filter(_p_and_v(), LogicalPlan.project(e^, _plain_scan())))
    assert_equal(over_project.tag, PLAN_FILTER)
    assert_equal(over_project._filter.value()[].predicate.binary_op(), BIN_AND)

    var no_data = attach_hive_predicate(LogicalPlan.filter(_p_and_v(), LogicalPlan(PLAN_SCAN, _full_schema())))
    assert_false(Bool(no_data._filter.value()[].child[]._scan))
    var bare_no_data = attach_hive_predicate(LogicalPlan(PLAN_SCAN, _full_schema()))
    assert_false(Bool(bare_no_data._scan))

    var mem = LogicalPlan.scan("m", SOURCE_IN_MEMORY, _full_schema())
    var over_mem = attach_hive_predicate(LogicalPlan.filter(_p_and_v(), mem.copy()))
    assert_equal(over_mem._filter.value()[].predicate.binary_op(), BIN_AND)
    var bare_mem = attach_hive_predicate(mem^)
    assert_false(Bool(bare_mem._scan.value()[].source._parquet))

    var over_empty = attach_hive_predicate(LogicalPlan.filter(_p_and_v(), _parquet_tag_without_payload()))
    assert_equal(over_empty._filter.value()[].predicate.binary_op(), BIN_AND)
    var bare_empty = attach_hive_predicate(_parquet_tag_without_payload())
    assert_equal(bare_empty._scan.value()[].source.tag, SOURCE_VARIANT_PARQUET)
    assert_false(Bool(bare_empty._scan.value()[].source._parquet))


# =============================================================================
# _stamp_fs_descriptor_on_scan
# =============================================================================


def _node_id(scan: LogicalPlan) -> Int:
    return scan._scan.value()[].source._parquet.value().fs_descriptor.node_id


def test_stamp_fs_descriptor_reaches_the_scan_through_project_and_filter() raises:
    """Project over Filter over a Parquet scan with a projection, a pushed
    filter, a row count and table stats: the scan gets the descriptor and
    keeps all four fields.

    Catches: the Project or Filter descent removed; the reseat dropping a
    field."""
    var stats = TableStats(7, List[String](), List[ColumnStats]())
    var scan = LogicalPlan.scan(
        "t.parquet", SOURCE_PARQUET, _full_schema(), Optional(_one("v")), Optional(_cmp(BIN_GT, "v", 0)),
        Optional(7), Optional(stats^),
    )
    var e = ExprArray()
    e.append(Expr.col_ref("v"))
    var plan = LogicalPlan.project(e^, LogicalPlan.filter(_cmp(BIN_GT, "v", 1), scan^))
    var out = _stamp_fs_descriptor_on_scan(plan^, FsDescriptorPod.cloud(FS_SCHEME_S3, "bkt", 42))
    ref s = out._project.value()[].child[]._filter.value()[].child[]
    assert_equal(_node_id(s), 42)
    ref sd = s._scan.value()[]
    assert_equal(sd.projection.value()[0], String("v"))
    assert_true(Bool(sd.filter))
    assert_equal(sd.row_count.value(), 7)
    assert_equal(sd.table_stats.value().row_count, 7)
    assert_true(Bool(sd.schema))


def test_stamp_fs_descriptor_leaves_other_shapes() raises:
    """Unchanged: a scan under a Limit (not descended); a scan node without
    scan data; an in-memory scan; a Parquet-tagged source without a payload;
    Filter- and Project-tagged nodes without payloads.

    Catches: each guard removed."""
    var d = FsDescriptorPod.cloud(FS_SCHEME_S3, "bkt", 42)
    var limited = _stamp_fs_descriptor_on_scan(LogicalPlan.limit(1, _plain_scan()), d.copy())
    assert_equal(_node_id(limited._limit.value()[].child[]), -1)
    var no_data = _stamp_fs_descriptor_on_scan(LogicalPlan(PLAN_SCAN, _full_schema()), d.copy())
    assert_false(Bool(no_data._scan))
    var mem = _stamp_fs_descriptor_on_scan(LogicalPlan.scan("m", SOURCE_IN_MEMORY, _full_schema()), d.copy())
    assert_false(Bool(mem._scan.value()[].source._parquet))
    var empty = _stamp_fs_descriptor_on_scan(_parquet_tag_without_payload(), d.copy())
    assert_false(Bool(empty._scan.value()[].source._parquet))
    var bare_filter = _stamp_fs_descriptor_on_scan(LogicalPlan(PLAN_FILTER, _full_schema()), d.copy())
    assert_false(Bool(bare_filter._filter))
    var bare_project = _stamp_fs_descriptor_on_scan(LogicalPlan(PLAN_PROJECT, _full_schema()), d.copy())
    assert_false(Bool(bare_project._project))


def main() raises:
    test_partition_conjunct_attached_residual_kept()
    test_partition_only_filter_collapses_to_the_scan()
    test_bare_hive_scan_gets_an_empty_predicate()
    test_plain_parquet_scan_is_unchanged()
    test_second_run_changes_nothing()
    test_scan_fields_survive_the_reseat()
    test_walk_reaches_every_node_kind()
    test_shapes_left_alone()
    test_stamp_fs_descriptor_reaches_the_scan_through_project_and_filter()
    test_stamp_fs_descriptor_leaves_other_shapes()
    print("All attach_hive_predicate tests passed.")
