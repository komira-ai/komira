# =============================================================================
# Tests for fuse_partition_topn optimizer rule — the PF_RANK extension
# =============================================================================
#
# `fuse_partition_topn` also
# recognizes PF_RANK above a Filter(rk <= K). The recognition + plan-shape
# emission is gated behind comptime `_ENABLE_PF_RANK_FUSE`, which is True.
# The optimizer pass MUST:
#   - fuse PF_RANK plans when the gate is ON, leave them unchanged when OFF
#   - leave PF_DENSE_RANK / PF_PERCENT_RANK / PF_NTILE / PF_LAG / PF_LEAD
#     completely unchanged (these are out-of-scope; they should never fire
#     whatever the gate)
#   - leave PF_ROW_NUMBER plans matched + fused (no regression)
#
# This file's PF_ROW_NUMBER coverage is intentionally minimal — the existing
# `test_optimizer_partition_topn.mojo` covers ROW_NUMBER end-to-end. This
# file focuses on the RANK additions:
#   - func + over_fetch_k now flow through the fused node
#   - the gate excludes PF_DENSE_RANK / PF_PERCENT_RANK / etc.
#   - the gate excludes empty-ORDER-BY plans
#   - K parsing is conservative (no col-ref, no negative literal, no wrong-direction)
#   - idempotence (running the pass twice is a no-op)
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_SCAN,
    PLAN_SORT,
)
from komira_plan_expr.expr import Expr, EXPR_COL_REF, BIN_LE, BIN_LT, BIN_GT, BIN_GE
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_expr import (
    PartitionExpr,
    PF_ROW_NUMBER,
    PF_RANK,
    PF_DENSE_RANK,
    PF_PERCENT_RANK,
    PF_NTILE,
    PF_LAG,
)
from komira_optimizer.optimizer_partition_topn import (
    fuse_partition_topn,
    _ENABLE_PF_RANK_FUSE,
    _PF_RANK_TIE_EPSILON,
)
from komira_runtime_paths import test_tmpdir


# =============================================================================
# Helpers
# =============================================================================


def _schema_3col() -> Schema:
    """Create a 3-column schema: pid(INT64), score(FLOAT64), val(INT64)."""
    var builder = SchemaBuilder()
    builder.add_field(Field("pid", ArrowType.INT64, False))
    builder.add_field(Field("score", ArrowType.FLOAT64, False))
    builder.add_field(Field("val", ArrowType.INT64, False))
    return builder.build()


def _scan_node() raises -> LogicalPlan:
    """Create a dummy scan node. Its path is under the runner's
    $TEST_TMPDIR (`test_tmpdir()` raises when that is unset), never a
    shared `/tmp`."""
    var schema = _schema_3col()
    return LogicalPlan.scan(
        (test_tmpdir() + String("/test.parquet")),
        0,  # SOURCE_PARQUET
        schema^,
        Optional[List[String]](None),
        Optional[Expr](None),
        Optional[Int](None),
    )


def _str_list1(s: String) -> List[String]:
    var l = List[String]()
    l.append(s)
    return l^


def _str_list_n(*args: String) -> List[String]:
    var l = List[String]()
    for a in args:
        l.append(a)
    return l^


def _bool_list1(b: Bool) -> List[Bool]:
    var l = List[Bool]()
    l.append(b)
    return l^


def _bool_list2(b1: Bool, b2: Bool) -> List[Bool]:
    var l = List[Bool]()
    l.append(b1)
    l.append(b2)
    return l^


def _empty_str_list() -> List[String]:
    return List[String]()


def _empty_bool_list() -> List[Bool]:
    return List[Bool]()


def _partition_by_func(
    var child: LogicalPlan,
    func: UInt8,
    var partition_keys: List[String],
    var order_keys: List[String],
    var descending: List[Bool],
) raises -> LogicalPlan:
    """Build a PartitionBy node with a single PartitionExpr of the given func."""
    var exprs = List[PartitionExpr]()
    if func == PF_ROW_NUMBER:
        exprs.append(PartitionExpr.row_number())
    elif func == PF_RANK:
        exprs.append(PartitionExpr.rank())
    elif func == PF_DENSE_RANK:
        exprs.append(PartitionExpr.dense_rank())
    elif func == PF_PERCENT_RANK:
        exprs.append(PartitionExpr.percent_rank())
    elif func == PF_NTILE:
        exprs.append(PartitionExpr.ntile(4))
    elif func == PF_LAG:
        exprs.append(PartitionExpr.lag(String("val"), 1))
    else:
        raise Error("test helper: unsupported func tag " + String(Int(func)))
    return LogicalPlan.partition_by(
        partition_keys^, order_keys^, descending^, exprs^, child^
    )


def _window_col_name(plan: LogicalPlan) -> String:
    """Return the synthesized window-output column name (last column)."""
    return plan.output_schema.field_name(plan.output_schema.num_columns() - 1)


# =============================================================================
# Positive cases — RANK
#
# These are the canonical RANK fuse shapes.
# Behavior depends on _ENABLE_PF_RANK_FUSE:
#   - When OFF: plan is left unchanged (PartitionBy + Filter).
#   - When ON (the current value): plan is fused into PartitionTopN with
#     func=PF_RANK and over_fetch_k = K + EPSILON.
# Each test asserts the correct branch based on the comptime gate.
# =============================================================================


def test_rank_canonical_le() raises:
    """RANK + Filter(rk <= 10) — canonical ranked top-K shape.

    Gate ON:  fused PartitionTopN(func=PF_RANK, K=10,
              over_fetch_k=K+EPSILON).
    Gate OFF: plan left unchanged.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var rk_name = _window_col_name(pb)

    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)

    comptime if _ENABLE_PF_RANK_FUSE:
        assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
        assert_equal(optimized._partition_topn.value()[].k, 10)
        assert_equal(
            Int(optimized._partition_topn.value()[].func), Int(PF_RANK)
        )
        assert_equal(
            optimized._partition_topn.value()[].over_fetch_k,
            10 + _PF_RANK_TIE_EPSILON,
        )
        assert_equal(
            optimized._partition_topn.value()[].partition_keys[0], String("pid")
        )
        assert_equal(optimized._partition_topn.value()[].descending[0], True)
    else:
        # Gate OFF: plan unchanged.
        assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
        assert_equal(
            Int(optimized._filter.value()[].child[].tag), Int(PLAN_PARTITION_BY)
        )
    print("PASS test_rank_canonical_le")


def test_rank_top1() raises:
    """RANK + Filter(rk <= 1) — degenerate top-1-per-partition shape."""
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var rk_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(1)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)

    comptime if _ENABLE_PF_RANK_FUSE:
        assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
        assert_equal(optimized._partition_topn.value()[].k, 1)
        assert_equal(
            Int(optimized._partition_topn.value()[].func), Int(PF_RANK)
        )
        assert_equal(
            optimized._partition_topn.value()[].over_fetch_k,
            1 + _PF_RANK_TIE_EPSILON,
        )
    else:
        assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_rank_top1")


def test_rank_lt_K_minus_one() raises:
    """RANK + Filter(rk < 11) -> K=10 (matches existing < parsing for ROW_NUMBER)."""
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var rk_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LT,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(11)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)

    comptime if _ENABLE_PF_RANK_FUSE:
        assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
        # `<` decrements K -> 11 - 1 = 10.
        assert_equal(optimized._partition_topn.value()[].k, 10)
        assert_equal(
            Int(optimized._partition_topn.value()[].func), Int(PF_RANK)
        )
        assert_equal(
            optimized._partition_topn.value()[].over_fetch_k,
            10 + _PF_RANK_TIE_EPSILON,
        )
    else:
        assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_rank_lt_K_minus_one")


def test_rank_multi_partition_keys_multi_order_keys() raises:
    """RANK + Filter(rk <= 100) with multi-key PARTITION BY + multi-key ORDER BY."""
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_RANK,
        _str_list_n("pid", "val"),
        _str_list_n("score", "val"),
        _bool_list2(True, False),
    )
    var rk_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(100)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)

    comptime if _ENABLE_PF_RANK_FUSE:
        assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
        assert_equal(optimized._partition_topn.value()[].k, 100)
        assert_equal(
            Int(optimized._partition_topn.value()[].func), Int(PF_RANK)
        )
        assert_equal(
            optimized._partition_topn.value()[].over_fetch_k,
            100 + _PF_RANK_TIE_EPSILON,
        )
        assert_equal(
            len(optimized._partition_topn.value()[].partition_keys), 2
        )
        assert_equal(len(optimized._partition_topn.value()[].sort_keys), 2)
    else:
        assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_rank_multi_partition_keys_multi_order_keys")


# =============================================================================
# Positive cases — ROW_NUMBER (regression coverage; must NOT regress with gate OFF)
# =============================================================================


def test_row_number_still_fires() raises:
    """ROW_NUMBER + Filter(rn <= 5) — must continue to fuse regardless of
    the PF_RANK gate (the RANK path must not regress the existing path).

    Validates that `func=PF_ROW_NUMBER` and `over_fetch_k=5` (no buffer)
    are correctly threaded into the fused node.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_ROW_NUMBER,
        _str_list1("pid"),
        _str_list1("score"),
        _bool_list1(True),
    )
    var rn_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(optimized._partition_topn.value()[].k, 5)
    assert_equal(
        Int(optimized._partition_topn.value()[].func), Int(PF_ROW_NUMBER)
    )
    # ROW_NUMBER doesn't need a tie buffer; over_fetch_k must equal k.
    assert_equal(optimized._partition_topn.value()[].over_fetch_k, 5)
    print("PASS test_row_number_still_fires")


# =============================================================================
# Negative cases — must NOT fire regardless of gate state
# =============================================================================


def test_no_fire_dense_rank() raises:
    """DENSE_RANK is out of scope — must NOT fire even when the gate is ON."""
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_DENSE_RANK,
        _str_list1("pid"),
        _str_list1("score"),
        _bool_list1(True),
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    # DENSE_RANK semantics differ from RANK (no gaps); cannot reuse the
    # K + EPSILON tie-buffer trick. Always bail out.
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    assert_equal(
        Int(optimized._filter.value()[].child[].tag), Int(PLAN_PARTITION_BY)
    )
    print("PASS test_no_fire_dense_rank")


def test_no_fire_percent_rank() raises:
    """PERCENT_RANK is out of scope — must NOT fire."""
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_PERCENT_RANK,
        _str_list1("pid"),
        _str_list1("score"),
        _bool_list1(True),
    )
    var col_name = _window_col_name(pb)
    # PERCENT_RANK output is FLOAT64 in [0, 1]; a "<= 10" filter wouldn't
    # bind to it semantically, but at the IR level we still emit a binary
    # op with an int literal RHS to test that the optimizer's bail is on
    # the func tag, not on the predicate type.
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_percent_rank")


def test_no_fire_ntile() raises:
    """NTILE is out of scope — must NOT fire."""
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_NTILE,
        _str_list1("pid"),
        _str_list1("score"),
        _bool_list1(True),
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(2)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_ntile")


def test_no_fire_lag() raises:
    """LAG is out of scope (offset function, not ranking) — must NOT fire."""
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_LAG,
        _str_list1("pid"),
        _str_list1("score"),
        _bool_list1(True),
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_lag")


def test_no_fire_rank_empty_order_by() raises:
    """RANK with EMPTY ORDER BY — must NOT fire (defensive correctness gate).

    Ranking without an ORDER BY is meaningless; the rule must bail out even
    if the gate is ON.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_RANK,
        _str_list1("pid"),
        _empty_str_list(),
        _empty_bool_list(),
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    # Must NOT fire even when _ENABLE_PF_RANK_FUSE is True.
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_rank_empty_order_by")


def test_row_number_empty_order_by_still_fires() raises:
    """ROW_NUMBER with EMPTY ORDER BY — fuses.

    The defensive empty-ORDER-BY bail is for RANK only. ROW_NUMBER
    without ORDER BY has non-deterministic output but is legal at the IR
    level; it still fuses, and this test guards
    against accidental regression of the existing ROW_NUMBER path.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_ROW_NUMBER,
        _str_list1("pid"),
        _empty_str_list(),
        _empty_bool_list(),
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    # Still fires for ROW_NUMBER even without ORDER BY.
    assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(optimized._partition_topn.value()[].k, 5)
    assert_equal(
        Int(optimized._partition_topn.value()[].func), Int(PF_ROW_NUMBER)
    )
    print("PASS test_row_number_empty_order_by_still_fires")


def test_no_fire_rank_negative_K() raises:
    """RANK + Filter(rk <= -5) — must NOT fire (defensive; negative K is
    nonsensical and must not crash).
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(-5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_rank_negative_K")


def test_no_fire_rank_K_zero() raises:
    """RANK + Filter(rk <= 0) — must NOT fire (K=0 means empty result; the
    optimizer's existing bail-out at K < 1 covers this for both funcs).
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(0)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_rank_K_zero")


def test_no_fire_rank_K_col_ref() raises:
    """RANK + Filter(rk <= other_col) — must NOT fire.

    The K extractor requires an integer literal RHS. A column-reference RHS
    means K is data-dependent, which can't be fused into a fixed-K heap.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(col_name),
        Expr.col_ref(String("val")),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_rank_K_col_ref")


def test_no_fire_rank_wrong_direction_gt() raises:
    """RANK + Filter(rk > 10) — wrong direction; must NOT fire.

    A `>` filter selects the bottom-N rows per partition, which is the
    inverse of TopN; not handled by the bounded-heap shape.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_rank_wrong_direction_gt")


def test_no_fire_rank_wrong_direction_ge() raises:
    """RANK + Filter(rk >= 10) — wrong direction; must NOT fire."""
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var col_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_GE,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_rank_wrong_direction_ge")


def test_no_fire_rank_wrong_column() raises:
    """RANK + Filter on a non-window column — must NOT fire.

    The K extractor requires the predicate's LHS column to match the
    rk synthesized output column. A filter on `pid` instead of `rk` is a
    real predicate (e.g. "rk on group=42 only") that the optimizer can't
    fuse into the heap-bounded operator.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(String("pid")),  # not the rk column
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_rank_wrong_column")


def test_no_fire_rank_multi_expr() raises:
    """RANK + a second PartitionExpr — must NOT fire.

    Multi-window PartitionBy nodes can't be fused into a single
    PartitionTopN; the second window output would be lost.
    """
    var scan = _scan_node()
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.rank())
    exprs.append(PartitionExpr.running_sum(String("val")))
    var pb = LogicalPlan.partition_by(
        _str_list1("pid"),
        _str_list1("score"),
        _bool_list1(True),
        exprs^,
        scan^,
    )
    # The rk column is the second-to-last (running_sum is last).
    var rk_name = pb.output_schema.field_name(
        pb.output_schema.num_columns() - 2
    )
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_rank_multi_expr")


# =============================================================================
# Idempotence
# =============================================================================


def test_idempotence_rank() raises:
    """Running fuse_partition_topn twice on a RANK plan is a no-op.

    Important regardless of gate state — the optimizer pipeline runs each
    rule once per pass; multiple passes must converge.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var rk_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var first = fuse_partition_topn(filter_plan^)
    var first_tag = Int(first.tag)
    var second = fuse_partition_topn(first^)
    assert_equal(Int(second.tag), first_tag)
    comptime if _ENABLE_PF_RANK_FUSE:
        # When gate is ON, both passes settle on PartitionTopN.
        assert_equal(Int(second.tag), Int(PLAN_PARTITION_TOPN))
        assert_equal(second._partition_topn.value()[].k, 10)
    else:
        # When gate is OFF, both passes leave the Filter+PartitionBy shape.
        assert_equal(Int(second.tag), Int(PLAN_FILTER))
    print("PASS test_idempotence_rank")


def test_idempotence_row_number() raises:
    """Running fuse_partition_topn twice on a ROW_NUMBER plan is a no-op.

    First pass fuses; second pass leaves the fused node unchanged
    (recurses into the PartitionTopN child without modification).
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_ROW_NUMBER,
        _str_list1("pid"),
        _str_list1("score"),
        _bool_list1(True),
    )
    var rn_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var first = fuse_partition_topn(filter_plan^)
    assert_equal(Int(first.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(first._partition_topn.value()[].k, 5)
    var second = fuse_partition_topn(first^)
    assert_equal(Int(second.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(second._partition_topn.value()[].k, 5)
    assert_equal(
        Int(second._partition_topn.value()[].func), Int(PF_ROW_NUMBER)
    )
    assert_equal(second._partition_topn.value()[].over_fetch_k, 5)
    print("PASS test_idempotence_row_number")


# =============================================================================
# Contract — explicit assertions about the fused-node shape
# =============================================================================


def test_row_number_func_field_is_zero() raises:
    """Contract: PF_ROW_NUMBER constant equals 0 in the fused node.

    Engine-side dispatch assumes this layout. Lock it in.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^,
        PF_ROW_NUMBER,
        _str_list1("pid"),
        _str_list1("score"),
        _bool_list1(True),
    )
    var rn_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(7)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
    # PF_ROW_NUMBER == 0 is the contract.
    assert_equal(Int(optimized._partition_topn.value()[].func), 0)
    # over_fetch_k == k for ROW_NUMBER (no tie buffer).
    assert_equal(optimized._partition_topn.value()[].over_fetch_k, 7)
    print("PASS test_row_number_func_field_is_zero")


def test_epsilon_value_locked() raises:
    """Contract: PF_RANK tie-buffer epsilon is 16.

    Lock in the value so a future change can't silently shift it without
    a corresponding correctness review.
    """
    assert_equal(_PF_RANK_TIE_EPSILON, 16)
    print("PASS test_epsilon_value_locked")


def test_gate_default_state() raises:
    """The RANK fusion gate `_ENABLE_PF_RANK_FUSE` is True.

    Every RANK test above asserts whichever branch the gate selects, so
    turning the gate off would leave them green while every RANK top-K plan
    silently lost the fused path. This assertion fails on that change, so
    turning the gate off has to edit this test deliberately.
    """
    assert_true(_ENABLE_PF_RANK_FUSE, "the RANK fusion gate must be on")
    print("PASS test_gate_default_state")


# =============================================================================
# Downstream-rk-reference safety pre-pass, and
# fuse-with-rk-emission instead of skip.
#
# When the rk/rn column is referenced by an operator ABOVE the consumer
# Filter, the fused PartitionTopN must emit the rk column so the
# downstream operator can resolve it. The safety pre-pass
# (`_collect_unsafe_window_cols`) detects this; the fuse reacts by
# fusing with `output_rank_col_name = Some(rk)` so the kernel emits
# the column.
#
# This is the canonical ranked top-K shape: the post-filter sort
# references rk. Without the pre-pass, fusion fired
# and the query failed at runtime with "no field named 'rk'". Skipping
# fusion when rk is referenced was correct but slow; extending
# PartitionTopN to optionally emit the rk column keeps the fused path.
# =============================================================================


def test_fires_with_rk_emission_when_rk_referenced_by_downstream_sort() raises:
    """RANK + Filter(rk <= 10) + Sort([pid, rk]) — fuses WITH rk emission.

    The downstream Sort references the rk column. The safety pre-pass
    detects this; the fuse reacts by fusing with
    `output_rank_col_name = Some("rk")` so the kernel emits rk for the
    downstream Sort to resolve. This is the canonical ranked top-K
    shape; this test asserts the fused path is wired up.

    Fusion fires with rk emission (it is not skipped).
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var rk_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    # Sort references rk → fuse with output_rank_col_name = Some(rk).
    var sort_keys = _str_list_n("pid", rk_name)
    var sort_desc = _bool_list2(False, False)
    var sort_plan = LogicalPlan.sort(sort_keys^, sort_desc^, filter_plan^)

    var optimized = fuse_partition_topn(sort_plan^)
    # Plan: Sort → PartitionTopN(func=RANK, output_rank_col_name=Some).
    assert_equal(Int(optimized.tag), Int(PLAN_SORT))
    ref sort_data = optimized._sort.value()[]
    ref pt_node = sort_data.child[]
    assert_equal(
        Int(pt_node.tag), Int(PLAN_PARTITION_TOPN),
        "Filter+PartitionBy must fuse into PartitionTopN even when "
        "downstream Sort references rk (with rk emission)",
    )
    ref pt_data = pt_node._partition_topn.value()[]
    assert_equal(Int(pt_data.func), Int(PF_RANK))
    assert_equal(pt_data.k, 10)
    assert_true(
        Bool(pt_data.output_rank_col_name),
        "output_rank_col_name must be Some when downstream Sort references rk",
    )
    assert_equal(
        pt_data.output_rank_col_name.value(),
        rk_name,
        "output_rank_col_name must be the rk column name",
    )
    # PartitionTopN's output schema has rk col appended (child schema +
    # 1 column).
    assert_equal(
        pt_node.output_schema.num_columns(), 4,
        "fused PartitionTopN output schema = 3 child cols + rk col = 4",
    )
    assert_equal(pt_node.output_schema.field_name(3), rk_name)
    print("PASS test_fires_with_rk_emission_when_rk_referenced_by_downstream_sort")


def test_fires_with_rk_emission_when_rk_referenced_by_downstream_project() raises:
    """RANK + Filter(rk <= 10) + Project([..., rk]) — fuses WITH rk emission.

    Same shape as the Sort case but exercised through a Project that
    re-emits the rk column.
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var rk_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)
    # Project includes rk col → fuse with rk emission.
    from komira_collections.slab import Slab
    var proj_exprs = Slab[Expr]()
    proj_exprs.append(Expr.col_ref(String("pid")))
    proj_exprs.append(Expr.col_ref(rk_name))
    var project = LogicalPlan.project(proj_exprs^, filter_plan^)

    var optimized = fuse_partition_topn(project^)
    assert_equal(Int(optimized.tag), Int(PLAN_PROJECT))
    ref proj_data = optimized._project.value()[]
    ref pt_node = proj_data.child[]
    assert_equal(
        Int(pt_node.tag), Int(PLAN_PARTITION_TOPN),
        "Filter+PartitionBy must fuse into PartitionTopN when "
        "downstream Project references rk (with rk emission)",
    )
    ref pt_data = pt_node._partition_topn.value()[]
    assert_true(
        Bool(pt_data.output_rank_col_name),
        "output_rank_col_name must be Some when downstream Project references rk",
    )
    assert_equal(
        pt_data.output_rank_col_name.value(),
        rk_name,
        "output_rank_col_name must be the rk column name",
    )
    print("PASS test_fires_with_rk_emission_when_rk_referenced_by_downstream_project")


def test_fires_when_rk_only_used_by_filter() raises:
    """RANK + Filter(rk <= 10) with NO downstream consumer of rk — fuses.

    The rk column is only referenced by the filter predicate; no operator
    above the Filter touches it. The safety pre-pass returns an empty
    unsafe set, so fusion proceeds with `output_rank_col_name = None`
    (no rk-column emission — saves the kernel one column-clone pass).

    When rk is NOT in unsafe_cols, fusion
    fires with `output_rank_col_name = None` (current behavior).
    """
    var scan = _scan_node()
    var pb = _partition_by_func(
        scan^, PF_RANK, _str_list1("pid"), _str_list1("score"), _bool_list1(True)
    )
    var rk_name = _window_col_name(pb)
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(10)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    comptime if _ENABLE_PF_RANK_FUSE:
        # rk only used by filter → fusion fires; output_rank_col_name stays None.
        assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
        assert_equal(
            Int(optimized._partition_topn.value()[].func), Int(PF_RANK)
        )
        assert_equal(optimized._partition_topn.value()[].k, 10)
        # When nothing above the Filter references rk,
        # the pre-pass returns an empty unsafe set; fusion uses None.
        assert_true(
            not Bool(optimized._partition_topn.value()[].output_rank_col_name),
            "output_rank_col_name must be None when rk is only "
            "referenced by the filter predicate",
        )
    else:
        assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_fires_when_rk_only_used_by_filter")


def main() raises:
    # Positive cases — RANK
    test_rank_canonical_le()
    test_rank_top1()
    test_rank_lt_K_minus_one()
    test_rank_multi_partition_keys_multi_order_keys()
    # Positive cases — ROW_NUMBER (regression coverage)
    test_row_number_still_fires()
    # Negative cases — out-of-scope window funcs
    test_no_fire_dense_rank()
    test_no_fire_percent_rank()
    test_no_fire_ntile()
    test_no_fire_lag()
    # Negative cases — gate-internal
    test_no_fire_rank_empty_order_by()
    test_row_number_empty_order_by_still_fires()
    test_no_fire_rank_negative_K()
    test_no_fire_rank_K_zero()
    test_no_fire_rank_K_col_ref()
    test_no_fire_rank_wrong_direction_gt()
    test_no_fire_rank_wrong_direction_ge()
    test_no_fire_rank_wrong_column()
    test_no_fire_rank_multi_expr()
    # Idempotence
    test_idempotence_rank()
    test_idempotence_row_number()
    # Contract assertions
    test_row_number_func_field_is_zero()
    test_epsilon_value_locked()
    test_gate_default_state()
    # Safety pre-pass / rk-emission tests
    test_fires_with_rk_emission_when_rk_referenced_by_downstream_sort()
    test_fires_with_rk_emission_when_rk_referenced_by_downstream_project()
    test_fires_when_rk_only_used_by_filter()
    print("All fuse_partition_topn(rank) tests passed")
