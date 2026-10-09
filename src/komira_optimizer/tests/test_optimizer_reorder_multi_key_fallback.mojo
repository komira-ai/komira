# =============================================================================
# Leftover composite fallback unit tests
# =============================================================================
#
# Validates the M2 invariant:
#
#   When some per-key indices fail to resolve (i.e.
#   find_relation_owning_columns returns -1 for the single-key lookup),
#   those keys are deferred to a single composite-fallback JoinEdge.
#   collect_connecting_keys still aggregates correctly because per-column
#   edges contribute their single keys + leftover edge contributes the
#   remaining keys = the original composite. No key duplication because
#   leftover_lk only contains keys whose per-column lookup FAILED.
#
# These tests build synthetic plans where SOME composite key indices
# resolve per-column (each side's single key appears in exactly ONE
# leaf) and OTHERS do not (the key name is absent from every leaf in
# the recursed slice).
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
    RelationSet,
    JoinRelation,
    JoinEdge,
    JoinChain,
    extract_join_chain,
    collect_connecting_keys,
)


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


def _scan_one(path: String, key: String, n: Int) -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(key, ArrowType.INT64, False))
    return _scan_with_schema(path, b.build()^, n)


def _inner_composite(
    var left: LogicalPlan,
    var right: LogicalPlan,
    var lkeys: List[String],
    var rkeys: List[String],
) -> LogicalPlan:
    return LogicalPlan.join(left^, right^, lkeys^, rkeys^, JOIN_INNER)


# =============================================================================
# Tests — leftover composite fallback
# =============================================================================


def test_partial_resolve_yields_per_column_plus_leftover() raises:
    """3-key composite where the THIRD key has no owning leaf.

    Setup:
      - left: schema (la, lb) — owns "la" and "lb" individually
      - right: schema (ra, rb) — owns "ra" and "rb" individually
      - composite keys: (la, lb, lc) = (ra, rb, rc)

    The per-column lookup succeeds for indices 0 and 1 (single-key
    "la" / "ra" / "lb" / "rb" each resolve to a single base leaf), and
    FAILS for index 2 ("lc" / "rc" are absent from both schemas).

    Expected edge sequence (M2 invariant):
      e0: (left, right, ["la"], ["ra"])    — per-column from index 0
      e1: (left, right, ["lb"], ["rb"])    — per-column from index 1
      e2: (left, right, ["lc"], ["rc"])    — leftover composite (1 key)
    """
    var l_schema = _two_int_schema("la", "lb")
    var r_schema = _two_int_schema("ra", "rb")
    var left = _scan_with_schema("l.parquet", l_schema^, 100)
    var right = _scan_with_schema("r.parquet", r_schema^, 200)

    # lc / rc don't appear in either leaf's schema — find_relation_
    # owning_columns will return -1 for those single-key lookups.
    var lkeys: List[String] = ["la", "lb", "lc"]
    var rkeys: List[String] = ["ra", "rb", "rc"]
    var j = _inner_composite(left^, right^, lkeys^, rkeys^)

    var maybe = extract_join_chain(j^)
    assert_true(Bool(maybe))
    var chain = maybe.take()

    assert_equal(len(chain.relations), 2)
    # 2 per-column + 1 leftover = 3 edges total.
    assert_equal(len(chain.edges), 3,
                 "2 per-column resolves + 1 leftover composite")

    # First two edges should be per-column from indices 0 and 1.
    assert_equal(len(chain.edges[0].left_keys), 1)
    assert_equal(chain.edges[0].left_keys[0], "la")
    assert_equal(chain.edges[0].right_keys[0], "ra")
    assert_equal(len(chain.edges[1].left_keys), 1)
    assert_equal(chain.edges[1].left_keys[0], "lb")
    assert_equal(chain.edges[1].right_keys[0], "rb")
    # Third edge is the leftover. Single-key here because only one
    # index failed to resolve; the leftover composite carries
    # whatever indices didn't resolve, in INDEX ORDER.
    assert_equal(len(chain.edges[2].left_keys), 1)
    assert_equal(chain.edges[2].left_keys[0], "lc")
    assert_equal(chain.edges[2].right_keys[0], "rc")

    # Aggregation via collect_connecting_keys: reconstruct the full
    # composite. The aggregation walks edges in slab insertion order;
    # all three connect set{0} → set{1} → final lk == [la, lb, lc] in
    # index order, rk likewise.
    var ls = RelationSet.singleton(chain.relations[0].id)
    var rs = RelationSet.singleton(chain.relations[1].id)
    var keys = collect_connecting_keys(ls, rs, chain.edges)
    assert_equal(len(keys.left), 3,
                 "aggregation reconstructs the full 3-key composite")
    assert_equal(len(keys.right), 3)
    assert_equal(keys.left[0], "la")
    assert_equal(keys.left[1], "lb")
    assert_equal(keys.left[2], "lc")
    assert_equal(keys.right[0], "ra")
    assert_equal(keys.right[1], "rb")
    assert_equal(keys.right[2], "rc")


def test_all_keys_unresolved_yields_single_composite() raises:
    """Sibling case: NONE of the composite keys resolve per-column —
    fall back to a single composite edge with all keys, matching the
    legacy behavior (no regression for the all-fail case).

    Setup:
      - left: schema (only "left_only") — owns nothing matching the
        composite keys.
      - right: schema (only "right_only") — same.
      - composite keys: (kx, ky) = (rx, ry) — all 4 are absent from
        both schemas.
    """
    var l_schema = _two_int_schema("left_only_a", "left_only_b")
    var r_schema = _two_int_schema("right_only_a", "right_only_b")
    var left = _scan_with_schema("l.parquet", l_schema^, 100)
    var right = _scan_with_schema("r.parquet", r_schema^, 200)

    # All keys absent from both leaves.
    var lkeys: List[String] = ["kx", "ky"]
    var rkeys: List[String] = ["rx", "ry"]
    var j = _inner_composite(left^, right^, lkeys^, rkeys^)

    var maybe = extract_join_chain(j^)
    assert_true(Bool(maybe))
    var chain = maybe.take()

    assert_equal(len(chain.relations), 2)
    # All-fail → exactly 1 leftover composite edge with all keys.
    assert_equal(len(chain.edges), 1,
                 "all-keys-unresolved falls back to single composite edge")
    assert_equal(len(chain.edges[0].left_keys), 2,
                 "leftover composite preserves both keys")
    assert_equal(len(chain.edges[0].right_keys), 2)
    assert_equal(chain.edges[0].left_keys[0], "kx")
    assert_equal(chain.edges[0].left_keys[1], "ky")
    assert_equal(chain.edges[0].right_keys[0], "rx")
    assert_equal(chain.edges[0].right_keys[1], "ry")


def test_middle_index_unresolved() raises:
    """Mixed case where the MIDDLE index fails to resolve — confirms
    the leftover-collection logic correctly preserves index identity,
    not just position.

    Setup:
      - left: (la, lc) — owns la and lc individually
      - right: (ra, rc) — owns ra and rc individually
      - composite keys: (la, lb, lc) = (ra, rb, rc) — only index 1
        ("lb"/"rb") is absent from both leaves.

    Expected edges (M2 + M1 invariants):
      e0: per-column ["la"]/["ra"]   ← index 0
      e1: per-column ["lc"]/["rc"]   ← index 2 (NB: NOT lb)
      e2: leftover composite ["lb"]/["rb"]   ← index 1 deferred

    Importantly, the leftover edge carries the UNRESOLVED keys only,
    so the leftover slot here is `lb`/`rb`, NOT all-three.
    """
    var l_schema = _two_int_schema("la", "lc")
    var r_schema = _two_int_schema("ra", "rc")
    var left = _scan_with_schema("l.parquet", l_schema^, 100)
    var right = _scan_with_schema("r.parquet", r_schema^, 200)

    var lkeys: List[String] = ["la", "lb", "lc"]
    var rkeys: List[String] = ["ra", "rb", "rc"]
    var j = _inner_composite(left^, right^, lkeys^, rkeys^)

    var maybe = extract_join_chain(j^)
    assert_true(Bool(maybe))
    var chain = maybe.take()

    assert_equal(len(chain.edges), 3,
                 "2 per-column resolves + 1 leftover (middle deferred)")

    # First per-column edge from index 0.
    assert_equal(chain.edges[0].left_keys[0], "la")
    assert_equal(chain.edges[0].right_keys[0], "ra")
    # Second per-column edge from index 2 (index 1 was deferred).
    assert_equal(chain.edges[1].left_keys[0], "lc")
    assert_equal(chain.edges[1].right_keys[0], "rc")
    # Leftover composite — single key (the deferred middle index).
    assert_equal(len(chain.edges[2].left_keys), 1)
    assert_equal(chain.edges[2].left_keys[0], "lb")
    assert_equal(chain.edges[2].right_keys[0], "rb")

    # Aggregation: full composite is preserved via M2 even with a
    # middle deferral. Order in the aggregated list reflects edge
    # walk order, not original index order — that's a known property
    # of the leftover-composite path. (When the leftover edge needs
    # to preserve original index ORDER strictly, callers must rely on
    # the per-column-only path. With deferrals, the rebuilt composite
    # may permute the deferred keys to the end, which is
    # acceptable because the join is conjunctive
    # and equi: permuting key positions does not change the joined
    # row set.)
    var ls = RelationSet.singleton(chain.relations[0].id)
    var rs = RelationSet.singleton(chain.relations[1].id)
    var keys = collect_connecting_keys(ls, rs, chain.edges)
    assert_equal(len(keys.left), 3)
    assert_equal(len(keys.right), 3)
    # All three keys present, no duplication.
    var found_la = False
    var found_lb = False
    var found_lc = False
    for i in range(len(keys.left)):
        var k = keys.left[i]
        if k == "la": found_la = True
        if k == "lb": found_lb = True
        if k == "lc": found_lc = True
    assert_true(found_la and found_lb and found_lc,
                "aggregation contains all 3 composite keys exactly once")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
