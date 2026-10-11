# =============================================================================
# Residual decompose vs user-written keys: per-column edge equivalence
# =============================================================================
#
# Validates:
#
#   A join constructed with `predicate=(l.a == r.b) & (l.c == r.d)` (a
#   raw residual shape) should produce, AFTER running the
#   `join_predicate_decompose` pass, a LogicalPlan with `left_on=[a,c]`
#   and `right_on=[b,d]` that is STRUCTURALLY IDENTICAL to a user-
#   written INNER `LogicalPlan.join` with `left_on=["a","c"]`, `right_on=["b","d"]`.
#
#   The chain extractor's per-column split must produce IDENTICAL
#   per-column edge sets for the two shapes — proving that the decompose
#   pass and the per-column split compose cleanly.
#
# This test exists because the decompose pass's lift-equi-conjuncts step
# is the upstream producer of the composite `left_on`/`right_on` shape
# that the chain extractor splits per-column. If the two paths diverged
# (different key ORDER, different relation routing, etc.), a decomposed
# two-clause residual would not benefit from the split.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    Expr,
)
from komira_plan_ir.logical_plan import (
    JOIN_INNER,
    LogicalPlan,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_reorder import (
    JoinRelation,
    JoinEdge,
    JoinChain,
    extract_join_chain,
)
from komira_optimizer.join_predicate_decompose import join_predicate_decompose


def _two_int_schema(c1: String, c2: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(c1, ArrowType.INT64, False))
    b.add_field(Field(c2, ArrowType.INT64, False))
    return b.build()


def _scan_with_schema(path: String, var schema: Schema, n: Int) -> LogicalPlan:
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, schema^, none_proj^, none_filt^, rc^
    )


def _build_user_written_composite_join(
    var left: LogicalPlan,
    var right: LogicalPlan,
    var lkeys: List[String],
    var rkeys: List[String],
) -> LogicalPlan:
    """User-written shape: classic `on=` composite INNER join with
    `left_on`/`right_on` populated directly."""
    return LogicalPlan.join(left^, right^, lkeys^, rkeys^, JOIN_INNER)


def _build_bk7_residual_composite_join(
    var left: LogicalPlan,
    var right: LogicalPlan,
    la: String,
    rb: String,
    lc: String,
    rd: String,
) -> LogicalPlan:
    """Raw residual shape: a JOIN with empty `left_on`/`right_on` and a
    raw side-qualified predicate residual:
        (Expr.left(la) == Expr.right(rb)) AND (Expr.left(lc) == Expr.right(rd))
    """
    # First conjunct: la = rb (left-side la == right-side rb)
    var conj1 = Expr.binary(
        BIN_EQ, Expr.left(la), Expr.right(rb)
    )
    # Second conjunct: lc = rd
    var conj2 = Expr.binary(
        BIN_EQ, Expr.left(lc), Expr.right(rd)
    )
    var pred = Expr.binary(BIN_AND, conj1^, conj2^)

    # JoinData carries residual as Optional[OwnedPointer[Expr]].
    var residual: Optional[OwnedPointer[Expr]] = OwnedPointer(pred^)
    var empty_lk: List[String] = []
    var empty_rk: List[String] = []
    # LogicalPlan.join signature: (left, right, left_on, right_on, jt,
    #                              algo_hint=AUTO, residual=None)
    return LogicalPlan.join(
        left^, right^, empty_lk^, empty_rk^, JOIN_INNER,
        algo_hint=plan_default_algo(),
        residual=residual^,
    )


def plan_default_algo() -> UInt8:
    """Default join algo hint constant (JOIN_ALGO_AUTO = 0).

    Local constant rather than importing JOIN_ALGO_AUTO from
    `komira_plan_ir.logical_plan`; the wire format is a UInt8 and AUTO is 0
    by contract."""
    return UInt8(0)


# =============================================================================
# Tests
# =============================================================================


def test_bk7_decompose_lifts_to_left_on_right_on() raises:
    """The decompose pass turns a `(l.a == r.b) AND (l.c == r.d)`
    residual into `left_on=[a,c], right_on=[b,d]` with residual=None."""
    var l_schema = _two_int_schema("a", "c")
    var r_schema = _two_int_schema("b", "d")
    var left = _scan_with_schema("l.parquet", l_schema^, 100)
    var right = _scan_with_schema("r.parquet", r_schema^, 200)
    var plan = _build_bk7_residual_composite_join(
        left^, right^, "a", "b", "c", "d"
    )

    # Pre-decompose: left_on/right_on empty, residual carries the AND.
    assert_equal(plan.tag, PLAN_JOIN)
    ref pre_jd = plan._join.value()[]
    assert_equal(len(pre_jd.left_on), 0,
                 "pre-decompose: left_on empty (raw predicate shape)")
    assert_equal(len(pre_jd.right_on), 0)
    assert_true(pre_jd.has_residual(), "pre-decompose: residual is set")

    var decomposed = join_predicate_decompose(plan^)

    # Post-decompose: both equi-conjuncts lifted, residual=None.
    assert_equal(decomposed.tag, PLAN_JOIN)
    ref post_jd = decomposed._join.value()[]
    assert_equal(len(post_jd.left_on), 2,
                 "post-decompose: two equi-keys lifted")
    assert_equal(len(post_jd.right_on), 2)
    assert_false(post_jd.has_residual(),
                 "post-decompose: residual drained (pure equi-join)")
    # Index order from conjunct order: (a=b, c=d).
    assert_equal(post_jd.left_on[0], "a")
    assert_equal(post_jd.right_on[0], "b")
    assert_equal(post_jd.left_on[1], "c")
    assert_equal(post_jd.right_on[1], "d")


def test_bk7_decompose_vs_user_written_identical_edge_set() raises:
    """A residual-then-decomposed join and a user-written composite
    join with the same key order produce IDENTICAL per-column edge
    sets through the chain extractor. This proves the decompose pass
    and the per-column split compose cleanly: the residual decomposition
    is the upstream producer of the composite shape the split works on.
    """
    var l_schema_a = _two_int_schema("a", "c")
    var r_schema_a = _two_int_schema("b", "d")
    var left_a = _scan_with_schema("l.parquet", l_schema_a^, 100)
    var right_a = _scan_with_schema("r.parquet", r_schema_a^, 200)
    # User-written shape:
    var user_lkeys: List[String] = ["a", "c"]
    var user_rkeys: List[String] = ["b", "d"]
    var user_plan = _build_user_written_composite_join(
        left_a^, right_a^, user_lkeys^, user_rkeys^
    )

    var l_schema_b = _two_int_schema("a", "c")
    var r_schema_b = _two_int_schema("b", "d")
    var left_b = _scan_with_schema("l.parquet", l_schema_b^, 100)
    var right_b = _scan_with_schema("r.parquet", r_schema_b^, 200)
    # Raw-residual shape:
    var bk7_plan_raw = _build_bk7_residual_composite_join(
        left_b^, right_b^, "a", "b", "c", "d"
    )
    var bk7_plan = join_predicate_decompose(bk7_plan_raw^)

    # Extract chains for both.
    var user_chain_maybe = extract_join_chain(user_plan^)
    var bk7_chain_maybe = extract_join_chain(bk7_plan^)
    assert_true(Bool(user_chain_maybe), "user-written chain extracts")
    assert_true(Bool(bk7_chain_maybe), "decomposed chain extracts")
    var user_chain = user_chain_maybe.take()
    var bk7_chain = bk7_chain_maybe.take()

    # Same number of relations.
    assert_equal(len(user_chain.relations), len(bk7_chain.relations))
    # Same number of edges (the per-column split should fire
    # equally on both shapes).
    assert_equal(len(user_chain.edges), len(bk7_chain.edges),
                 "both shapes produce the SAME number of edges")
    assert_equal(len(user_chain.edges), 2,
                 "2 per-column edges for the 2-key composite")

    # Edge-by-edge equivalence: per-column keys + relation ids match.
    for i in range(len(user_chain.edges)):
        ref u = user_chain.edges[i]
        ref b = bk7_chain.edges[i]
        assert_equal(u.left_relation, b.left_relation,
                     "edge[i] left_relation matches")
        assert_equal(u.right_relation, b.right_relation,
                     "edge[i] right_relation matches")
        assert_equal(len(u.left_keys), len(b.left_keys),
                     "edge[i] left key count matches")
        assert_equal(len(u.right_keys), len(b.right_keys))
        for k in range(len(u.left_keys)):
            assert_equal(u.left_keys[k], b.left_keys[k],
                         "edge[i] left key matches per-element")
            assert_equal(u.right_keys[k], b.right_keys[k])


def test_bk7_decompose_idempotent_chain_shape() raises:
    """Running the decompose pass twice on a residual-bearing plan
    should produce the same shape as running it once — and the chain
    extractor should produce the SAME per-column edge set in both
    cases. Idempotence is a decompose-pass invariant; this test exercises it
    through the chain-extractor lens."""
    var l_schema = _two_int_schema("a", "c")
    var r_schema = _two_int_schema("b", "d")
    var left = _scan_with_schema("l.parquet", l_schema^, 100)
    var right = _scan_with_schema("r.parquet", r_schema^, 200)
    var plan = _build_bk7_residual_composite_join(
        left^, right^, "a", "b", "c", "d"
    )
    # Decompose once.
    var once = join_predicate_decompose(plan^)
    # Decompose again — must be a no-op (both conjuncts lifted, so the
    # residual on `once` is None).
    var once_copy = once.copy()
    var twice = join_predicate_decompose(once_copy^)

    # Extract both — same shape.
    var once_chain_maybe = extract_join_chain(once^)
    var twice_chain_maybe = extract_join_chain(twice^)
    assert_true(Bool(once_chain_maybe))
    assert_true(Bool(twice_chain_maybe))
    var once_chain = once_chain_maybe.take()
    var twice_chain = twice_chain_maybe.take()

    assert_equal(len(once_chain.relations), len(twice_chain.relations))
    assert_equal(len(once_chain.edges), len(twice_chain.edges))
    for i in range(len(once_chain.edges)):
        assert_equal(once_chain.edges[i].left_keys[0],
                     twice_chain.edges[i].left_keys[0])
        assert_equal(once_chain.edges[i].right_keys[0],
                     twice_chain.edges[i].right_keys[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
