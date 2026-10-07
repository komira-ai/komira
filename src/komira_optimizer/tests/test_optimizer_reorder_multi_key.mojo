# =============================================================================
# Per-column edge split unit tests
# =============================================================================
#
# Validates that `_extract_join_chain_inner` emits ONE JoinEdge per
# composite-key index (`left_on[i]`, `right_on[i]`) when each per-column
# key resolves to a distinct base leaf in the recursed slice. The
# contract:
#
#   For each key INDEX i in [0, len(left_on)):
#       per-column resolve via find_relation_owning_columns([left_on[i]])
#       if both sides resolve: append one per-column JoinEdge
#       else: defer to leftover composite (covered by sibling test)
#
# These tests assert on EDGE-SHAPE behavior only (count, keys per edge,
# index order). Cost ranking belongs to the TDOM cost model's tests;
# this file validates the split itself.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
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


# =============================================================================
# Plan-construction helpers — local copies (kept self-contained to avoid
# cross-test imports). The shape we exercise is: TWO base relations each
# carrying multiple distinctly-named columns, joined under a composite
# `left_on`/`right_on` so that find_relation_owning_columns resolves
# per-column on each side.
# =============================================================================


def _two_int_schema(c1: String, c2: String) -> Schema:
    """Schema with two INT64 columns. Both distinct so per-column
    find_relation_owning_columns succeeds against THIS schema only."""
    var b = SchemaBuilder()
    b.add_field(Field(c1, ArrowType.INT64, False))
    b.add_field(Field(c2, ArrowType.INT64, False))
    return b.build()


def _three_int_schema(c1: String, c2: String, c3: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(c1, ArrowType.INT64, False))
    b.add_field(Field(c2, ArrowType.INT64, False))
    b.add_field(Field(c3, ArrowType.INT64, False))
    return b.build()


def _scan_with_schema(path: String, var schema: Schema, n: Int) -> LogicalPlan:
    """Scan with a custom schema and explicit row_count."""
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, schema^, none_proj^, none_filt^, rc^
    )


def _scan_one(path: String, key: String, n: Int) -> LogicalPlan:
    """Single-column Scan helper for the no-change baseline test."""
    var b = SchemaBuilder()
    b.add_field(Field(key, ArrowType.INT64, False))
    var schema = b.build()
    return _scan_with_schema(path, schema^, n)


def _inner_composite(
    var left: LogicalPlan,
    var right: LogicalPlan,
    var lkeys: List[String],
    var rkeys: List[String],
) -> LogicalPlan:
    return LogicalPlan.join(left^, right^, lkeys^, rkeys^, JOIN_INNER)


# =============================================================================
# Tests — per-column emit shape
# =============================================================================


def test_two_key_composite_emits_two_per_column_edges() raises:
    """A 2-relation INNER join with composite `(la, lb) = (ra, rb)` keys
    should produce TWO JoinEdges, one per key INDEX, with single-key
    left_keys / right_keys.

    Legacy composite-edge path: 1 edge with both keys.
    Per-column split: 2 edges, one per index.
    """
    var l_schema = _two_int_schema("la", "lb")
    var r_schema = _two_int_schema("ra", "rb")
    var left = _scan_with_schema("l.parquet", l_schema^, 100)
    var right = _scan_with_schema("r.parquet", r_schema^, 200)
    var lkeys: List[String] = ["la", "lb"]
    var rkeys: List[String] = ["ra", "rb"]
    var j = _inner_composite(left^, right^, lkeys^, rkeys^)

    var maybe = extract_join_chain(j^)
    assert_true(Bool(maybe), "composite INNER join extracts")
    var chain = maybe.take()

    # Two leaf relations.
    assert_equal(len(chain.relations), 2)
    # Per-column split: TWO edges (was 1 before the split).
    assert_equal(len(chain.edges), 2,
                 "per-column split produces 2 edges from 2-key composite")

    # Each edge carries a SINGLE key.
    for i in range(len(chain.edges)):
        ref e = chain.edges[i]
        assert_equal(len(e.left_keys), 1,
                     "per-column edge has single left key")
        assert_equal(len(e.right_keys), 1,
                     "per-column edge has single right key")

    # M1 invariant — edges in INDEX ORDER. The composite was
    # (la, lb) = (ra, rb); edges should be appended as
    # e0 = (la, ra), e1 = (lb, rb).
    assert_equal(chain.edges[0].left_keys[0], "la")
    assert_equal(chain.edges[0].right_keys[0], "ra")
    assert_equal(chain.edges[1].left_keys[0], "lb")
    assert_equal(chain.edges[1].right_keys[0], "rb")


def test_three_key_composite_emits_three_per_column_edges() raises:
    """3-key composite `(la, lb, lc) = (ra, rb, rc)` produces three
    per-column edges contiguously, all with single-key left_keys /
    right_keys, in INDEX ORDER."""
    var l_schema = _three_int_schema("la", "lb", "lc")
    var r_schema = _three_int_schema("ra", "rb", "rc")
    var left = _scan_with_schema("l3.parquet", l_schema^, 100)
    var right = _scan_with_schema("r3.parquet", r_schema^, 200)
    var lkeys: List[String] = ["la", "lb", "lc"]
    var rkeys: List[String] = ["ra", "rb", "rc"]
    var j = _inner_composite(left^, right^, lkeys^, rkeys^)

    var maybe = extract_join_chain(j^)
    assert_true(Bool(maybe), "3-key composite INNER join extracts")
    var chain = maybe.take()

    assert_equal(len(chain.relations), 2)
    assert_equal(len(chain.edges), 3, "3-key composite produces 3 edges")

    # Single key per edge.
    for i in range(len(chain.edges)):
        assert_equal(len(chain.edges[i].left_keys), 1)
        assert_equal(len(chain.edges[i].right_keys), 1)

    # M1 invariant — INDEX ORDER preserved.
    assert_equal(chain.edges[0].left_keys[0], "la")
    assert_equal(chain.edges[0].right_keys[0], "ra")
    assert_equal(chain.edges[1].left_keys[0], "lb")
    assert_equal(chain.edges[1].right_keys[0], "rb")
    assert_equal(chain.edges[2].left_keys[0], "lc")
    assert_equal(chain.edges[2].right_keys[0], "rc")


def test_single_key_composite_unchanged() raises:
    """Single-key INNER join (the common case): the legacy behavior is
    preserved — ONE JoinEdge with a single-key left_keys / right_keys."""
    var a = _scan_one("a.parquet", "ak", 100)
    var b = _scan_one("b.parquet", "bk", 200)
    var lkeys: List[String] = ["ak"]
    var rkeys: List[String] = ["bk"]
    var j = _inner_composite(a^, b^, lkeys^, rkeys^)

    var maybe = extract_join_chain(j^)
    assert_true(Bool(maybe))
    var chain = maybe.take()

    assert_equal(len(chain.relations), 2)
    assert_equal(len(chain.edges), 1,
                 "single-key composite still produces 1 edge "
                 "(no behavior change for non-composite)")
    assert_equal(len(chain.edges[0].left_keys), 1)
    assert_equal(len(chain.edges[0].right_keys), 1)
    assert_equal(chain.edges[0].left_keys[0], "ak")
    assert_equal(chain.edges[0].right_keys[0], "bk")


def test_q5_like_three_relation_chain_edge_count() raises:
    """Critical edge-count check.

    A 3-relation chain where the top join is composite `(la, lb) =
    (ra, rb)` and `la` resolves to the LEFT-subtree's first relation,
    `lb` resolves to a DIFFERENT relation in the LEFT subtree.

    Shape:
        ((left1 INNER left2) ON [left1.la = left2.lb_join])
        INNER
        right ON [(left1.la, left2.lb) = (right.ra, right.rb)]

    Legacy: 2 edges total (one inner edge + one composite top edge).
    Split: 3 edges total (one inner edge + TWO per-column top edges
    splitting across the two sub-leaves).

    This is the minimal proxy for the Q5 5-edges → 6-edges shape
    transformation.
    """
    # left1 has cols (la, l1_join)
    var l1_schema = _two_int_schema("la", "l1_join")
    var left1 = _scan_with_schema("l1.parquet", l1_schema^, 100)
    # left2 has cols (lb, l2_join). Its `l2_join` matches l1.l1_join
    # under the inner join.
    var l2_schema = _two_int_schema("lb", "l2_join")
    var left2 = _scan_with_schema("l2.parquet", l2_schema^, 200)
    # Inner join: left1 INNER left2 on l1_join = l2_join.
    var inner_lk: List[String] = ["l1_join"]
    var inner_rk: List[String] = ["l2_join"]
    var inner = _inner_composite(left1^, left2^, inner_lk^, inner_rk^)

    # right has cols (ra, rb).
    var r_schema = _two_int_schema("ra", "rb")
    var right = _scan_with_schema("r.parquet", r_schema^, 300)
    # Top join: inner INNER right on (la, lb) = (ra, rb). Note la is
    # in left1's schema, lb is in left2's schema — a composite that
    # CROSSES base-leaf boundaries on the left side.
    var top_lk: List[String] = ["la", "lb"]
    var top_rk: List[String] = ["ra", "rb"]
    var top = _inner_composite(inner^, right^, top_lk^, top_rk^)

    var maybe = extract_join_chain(top^)
    assert_true(Bool(maybe))
    var chain = maybe.take()

    assert_equal(len(chain.relations), 3, "3-leaf chain")
    # 1 (inner edge l1_join=l2_join) + 2 (per-column la=ra, lb=rb) = 3.
    assert_equal(len(chain.edges), 3,
                 "per-column split yields 3 edges for "
                 "1-inner + 1-composite (2-key) chain")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
