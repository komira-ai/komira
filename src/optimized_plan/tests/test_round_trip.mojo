# =============================================================================
# test_round_trip.mojo
# =============================================================================
#
# `produce_optimized_plan` and `admit_optimized_plan` against each other
# (docs/design/optimized_plan.md §4.1, §7.1, §7.2). Plans are built by hand
# with the build side and group estimate an optimizer would record; the
# optimizer is not linked. What each test proves:
#
#   test_round_trip_nested_joins: a plan of an aggregate (with a recorded
#     group estimate) over a project over a filter over two nested joins,
#     one building LEFT and one RIGHT, is produced and admitted; the admitted
#     plan renders the same, its structural hash is the same, and its OPTIMIZED
#     encoding is byte-equal to the source plan's (so every join keeps its own
#     side and the estimate survives). The header comes back with format 1,
#     contract 1, the stamp's build, config digest and kind, bounded needs and
#     no write target.
#   test_round_trip_keeps_the_write_target: a write target given to the
#     producer is in the admitted header, field for field.
#   test_production_is_byte_stable: producing the same plan twice gives the
#     same bytes, and encoding the admitted header canonically again gives the
#     bytes that were admitted.
#   test_digest_binds_body_and_trailer: the header's digest is 32 bytes, equals
#     `optimized_plan_digest` of its own body and header, and differs between
#     two productions that differ only in the write target.
#   test_producer_sets_the_contract_version: a stamp that names contract
#     version 9 is written as version 1, the one this build writes, and is
#     admitted.
#   test_producer_refuses_a_join_with_no_build_side: a plan holding a join
#     whose side was never recorded is refused OPTIMIZED_JOIN_BUILD_SIDE_MISSING
#     by the producer, at the root and nested.
#   test_producer_refuses_scan_statistics: a scan with `row_count`, and one
#     with `table_stats`, is refused OPTIMIZED_FIELD_UNSUPPORTED naming the
#     field: the producer does not strip statistics, the caller's plan has none.
#   test_admission_returns_the_plan_it_decoded: a plan of one scan round trips
#     with its schema and source path.
# =============================================================================

from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from optimized_plan import (
    OPTIMIZED_BODY_UNBOUNDED_V1,
    admit_optimized_plan,
    encode_canonical,
    header_plan_digest,
    produce_optimized_plan,
)
from plan_expr.agg_expr import AGG_SUM, AggExpr
from plan_expr.expr import BIN_GT, Expr
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
    JOIN_INNER,
    SOURCE_PARQUET,
    AggExprArray,
    ExprArray,
    LogicalPlan,
)
from plan_ir.udf_ref import UdfRef
from plan_proto.optimized_plan import ProducerStamp
from plan_proto.plan import WireWriteTarget
from plan_proto.plan_vocabulary import WriteCompression, WriteFormat
from plan_stats.table_stats import ColumnStats, TableStats
from optimized_plan_header import (
    OPTIMIZED_PLAN_CONTRACT_VERSION_1,
    OPTIMIZED_PLAN_FORMAT_VERSION_1,
)
from plan_wire import (
    OPTIMIZED_FIELD_UNSUPPORTED,
    OPTIMIZED_JOIN_BUILD_SIDE_MISSING,
    optimized_plan_to_bytes,
)


def _bytes(n: Int, v: UInt8) -> List[UInt8]:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(v)
    return b^


def _stamp(contract: UInt32 = 1) -> ProducerStamp:
    return ProducerStamp(_bytes(32, 0xAB), contract, _bytes(32, 0x11), "komira/mojo-sdk")


def _no_revocations() -> List[List[UInt8]]:
    return List[List[UInt8]]()


def _schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, True))
    sb.add_field(Field(b, ArrowType.FLOAT64, True))
    return sb.build()


def _scan(path: String, a: String, b: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(a, b))


def _join_of(
    var left: LogicalPlan, var right: LogicalPlan, lo: String, ro: String, side: UInt8
) -> LogicalPlan:
    var lon: List[String] = [lo]
    var ron: List[String] = [ro]
    return LogicalPlan.join(left^, right^, lon^, ron^, JOIN_INNER, JOIN_ALGO_AUTO, None, side, False)


def _joins(inner: UInt8, outer: UInt8) -> LogicalPlan:
    """`(l JOIN r) JOIN t`, the inner join building `inner`, the outer `outer`."""
    var lr = _join_of(_scan("/d/l.parquet", "a", "b"), _scan("/d/r.parquet", "c", "d"), "a", "c", inner)
    return _join_of(lr^, _scan("/d/t.parquet", "e", "f"), "a", "e", outer)


def _plan() -> LogicalPlan:
    var filtered = LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(Int64(1)))),
        _joins(JOIN_BUILD_SIDE_LEFT, JOIN_BUILD_SIDE_RIGHT),
    )
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("a"))
    exprs.append(Expr.col_ref("d"))
    var project = LogicalPlan.project(exprs^, filtered^)
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("d")), Optional(String("t"))))
    var agg = LogicalPlan.aggregate(gb^, ax^, project^)
    agg.set_estimated_groups(Optional(7))
    return agg^


def _refusal_of_producing(plan: LogicalPlan) -> String:
    try:
        _ = produce_optimized_plan(plan, _stamp())
    except e:
        return String(e)
    return String("")


def test_round_trip_nested_joins() raises:
    var plan = _plan()
    var bytes = produce_optimized_plan(plan, _stamp())
    var admitted = admit_optimized_plan(bytes^, _no_revocations())
    assert_equal(String(admitted.plan), String(plan))
    assert_equal(admitted.plan.structural_hash(), plan.structural_hash())
    var want = optimized_plan_to_bytes(plan, List[UdfRef]())
    var got = optimized_plan_to_bytes(admitted.plan, List[UdfRef]())
    assert_true(want == got)
    ref h = admitted.header
    assert_equal(h.format_version, OPTIMIZED_PLAN_FORMAT_VERSION_1)
    assert_true(Bool(h.producer))
    assert_equal(h.producer.value().optimizer_contract_version, OPTIMIZED_PLAN_CONTRACT_VERSION_1)
    assert_true(h.producer.value().engine_build == _bytes(32, 0xAB))
    assert_true(h.producer.value().optimizer_config_digest == _bytes(32, 0x11))
    assert_equal(h.producer.value().kind, "komira/mojo-sdk")
    assert_true(Bool(h.needs))
    assert_equal(h.needs.value().unbounded, OPTIMIZED_BODY_UNBOUNDED_V1)
    assert_equal(len(h.needs.value().udfs), 0)
    assert_equal(len(h.needs.value().runtimes), 0)
    assert_equal(len(h.needs.value().data_scopes), 0)
    assert_true(not h.write_target)
    assert_true(not h.advice)


def test_round_trip_keeps_the_write_target() raises:
    var write = WireWriteTarget("out/", WriteFormat(1), WriteCompression(3))
    var bytes = produce_optimized_plan(_plan(), _stamp(), Optional(write^))
    var admitted = admit_optimized_plan(bytes^, _no_revocations())
    assert_true(Bool(admitted.header.write_target))
    ref w = admitted.header.write_target.value()
    assert_equal(w.path, "out/")
    assert_equal(Int(w.format.number()), 1)
    assert_equal(Int(w.codec.number()), 3)


def test_production_is_byte_stable() raises:
    var first = produce_optimized_plan(_plan(), _stamp())
    var second = produce_optimized_plan(_plan(), _stamp())
    assert_true(first == second)
    var admitted = admit_optimized_plan(first.copy(), _no_revocations())
    assert_true(encode_canonical(admitted.header) == first)


def test_digest_binds_body_and_trailer() raises:
    var plain = admit_optimized_plan(produce_optimized_plan(_plan(), _stamp()), _no_revocations())
    var write = WireWriteTarget("out/", WriteFormat(1), WriteCompression(3))
    var written = admit_optimized_plan(
        produce_optimized_plan(_plan(), _stamp(), Optional(write^)), _no_revocations()
    )
    assert_equal(len(plain.header.plan_digest), 32)
    assert_true(plain.header.plan_digest == header_plan_digest(plain.header))
    assert_true(plain.header.body == written.header.body)
    assert_true(plain.header.plan_digest != written.header.plan_digest)


def test_producer_sets_the_contract_version() raises:
    var bytes = produce_optimized_plan(_plan(), _stamp(9))
    var admitted = admit_optimized_plan(bytes^, _no_revocations())
    assert_equal(admitted.header.producer.value().optimizer_contract_version, 1)


def test_producer_refuses_a_join_with_no_build_side() raises:
    var root = _refusal_of_producing(_joins(JOIN_BUILD_SIDE_UNSET, JOIN_BUILD_SIDE_LEFT))
    assert_true(root.startswith(OPTIMIZED_JOIN_BUILD_SIDE_MISSING))
    var nested = _refusal_of_producing(_joins(JOIN_BUILD_SIDE_LEFT, JOIN_BUILD_SIDE_UNSET))
    assert_true(nested.startswith(OPTIMIZED_JOIN_BUILD_SIDE_MISSING))
    assert_true("JoinData.build_side is UNSET" in nested)


def test_producer_refuses_scan_statistics() raises:
    var counted = LogicalPlan.scan("/d/t.parquet", SOURCE_PARQUET, _schema("a", "b"), None, None, Optional(12))
    var m = _refusal_of_producing(counted)
    assert_true(m.startswith(OPTIMIZED_FIELD_UNSUPPORTED))
    assert_true("ScanData.row_count" in m)
    var stats = TableStats(7, List[String](), List[ColumnStats]())
    var statted = LogicalPlan.scan(
        "/d/t.parquet", SOURCE_PARQUET, _schema("a", "b"), None, None, None, Optional(stats^)
    )
    m = _refusal_of_producing(statted)
    assert_true(m.startswith(OPTIMIZED_FIELD_UNSUPPORTED))
    assert_true("ScanData.table_stats" in m)


def test_admission_returns_the_plan_it_decoded() raises:
    var scan = _scan("/d/only.parquet", "x", "y")
    var admitted = admit_optimized_plan(produce_optimized_plan(scan, _stamp()), _no_revocations())
    assert_true(admitted.plan.is_scan())
    assert_equal(admitted.plan.scan_data_ref().source_path, "/d/only.parquet")
    assert_equal(admitted.plan.output_schema.num_columns(), 2)


def main() raises:
    test_round_trip_nested_joins()
    test_round_trip_keeps_the_write_target()
    test_production_is_byte_stable()
    test_digest_binds_body_and_trailer()
    test_producer_sets_the_contract_version()
    test_producer_refuses_a_join_with_no_build_side()
    test_producer_refuses_scan_statistics()
    test_admission_returns_the_plan_it_decoded()
    print("test_round_trip: 8 passed")
