"""plan_cse ACTIVE REWRITE tests.

The active rewrite: a PURE duplicated subtree's 2nd..Nth occurrence is
replaced with a `PLAN_CSE_REF(canonical_hash)` leaf pointing at the
canonical (first-in-compile-order) occurrence.

These tests assert the IR-LEVEL rewrite via `force_rewrite=True` + the
structural differential (un-CSE'd vs CSE'd plan shape): the duplicate
subtree is replaced by a ref node, so the plan has 1 instance + 1 ref
instead of 2 instances.

Coverage:
  Test 1: detection + rewrite — Join(filter(scan), filter(scan)) with
          identical filters → after force-rewrite, the plan has 1
          filter(scan) instance + 1 PLAN_CSE_REF (not 2 instances).
  Test 2: the CSE ref's canonical_hash == the original subtree's
          structural_hash; the ref node's own structural_hash == its
          canonical_hash (re-CSE idempotence).
  Test 3: structural differential — the un-CSE'd plan still has 2
          PLAN_SCAN instances; the CSE'd plan has 1 PLAN_SCAN + 1
          PLAN_CSE_REF.
  Test 4: gate OFF (default) → plan_cse_eliminate is a NO-OP (returns the
          plan unchanged).
  Test 5: no duplicates → plan unchanged even with force_rewrite=True.
  Test 6: purity guard — a synthetic out-of-allowlist tag is NOT pure
          (and never a CSE candidate), so its subtree is never CSE'd.
  Test 7: PLAN_UNION recursion — a Union whose two children share a
          sub-subtree → the shared sub-subtree gets CSE'd (proves the
          walker recurses through union children).
"""

from std.testing import assert_equal, assert_true
from std.collections import Optional
from std.memory import OwnedPointer
from komira_core.collections.slab import Slab

from komira_core.arrow.schema import SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.expr import (
    Expr,
    BIN_GT,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_JOIN,
    PLAN_UNION,
    PLAN_CSE_REF,
)

from komira_compiler.plan_cse import (
    plan_cse_eliminate,
    detect_cse_candidates,
    count_subtree_occurrences,
    _subtree_is_pure,
)


# =============================================================================
# Test helpers
# =============================================================================


def _make_lineitem() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(
        String("lineitem.parquet"), SOURCE_PARQUET, schema^
    )


def _filter_lineitem() -> LogicalPlan:
    """`Filter(l_quantity > 10, Scan(lineitem))` — the duplicated subtree."""
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    return LogicalPlan.filter(pred^, _make_lineitem()^)


def _count_tag(plan: LogicalPlan, target_tag: UInt8) -> Int:
    """Recursively count nodes with `tag == target_tag` (DFS walk).

    Handles the node shapes used by these tests: SCAN / FILTER / PROJECT /
    JOIN / UNION / CSE_REF. CSE_REF / SCAN are leaves.
    """
    var n = 0
    if plan.tag == target_tag:
        n += 1
    if plan.tag == PLAN_FILTER:
        n += _count_tag(plan._filter.value()[].child[], target_tag)
    elif plan.tag == PLAN_PROJECT:
        n += _count_tag(plan._project.value()[].child[], target_tag)
    elif plan.tag == PLAN_JOIN:
        n += _count_tag(plan._join.value()[].left[], target_tag)
        n += _count_tag(plan._join.value()[].right[], target_tag)
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            n += _count_tag(ud.children[i][], target_tag)
    # PLAN_SCAN / PLAN_CSE_REF — leaves.
    return n


def _maybe_cse_ref_canonical_hash(plan: LogicalPlan) -> Optional[UInt64]:
    """The `canonical_hash` of the first PLAN_CSE_REF found (DFS), or None."""
    if plan.tag == PLAN_CSE_REF:
        return Optional(plan._cse_ref.value()[].canonical_hash)
    if plan.tag == PLAN_FILTER:
        return _maybe_cse_ref_canonical_hash(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return _maybe_cse_ref_canonical_hash(plan._project.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        var lh = _maybe_cse_ref_canonical_hash(plan._join.value()[].left[])
        if lh:
            return lh
        return _maybe_cse_ref_canonical_hash(plan._join.value()[].right[])
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            var ch = _maybe_cse_ref_canonical_hash(ud.children[i][])
            if ch:
                return ch
    return Optional[UInt64](None)


def _first_cse_ref_canonical_hash(plan: LogicalPlan) raises -> UInt64:
    var h = _maybe_cse_ref_canonical_hash(plan)
    if not h:
        raise Error("test: no PLAN_CSE_REF found in plan")
    return h.value()


def _maybe_cse_ref_node_hash(plan: LogicalPlan) -> Optional[UInt64]:
    """`structural_hash` of the first PLAN_CSE_REF node (DFS), or None."""
    if plan.tag == PLAN_CSE_REF:
        return Optional(plan.structural_hash())
    if plan.tag == PLAN_FILTER:
        return _maybe_cse_ref_node_hash(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return _maybe_cse_ref_node_hash(plan._project.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        var l = _maybe_cse_ref_node_hash(plan._join.value()[].left[])
        if l:
            return l
        return _maybe_cse_ref_node_hash(plan._join.value()[].right[])
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            var c = _maybe_cse_ref_node_hash(ud.children[i][])
            if c:
                return c
    return Optional[UInt64](None)


def _first_cse_ref_node_hash(plan: LogicalPlan) raises -> UInt64:
    var h = _maybe_cse_ref_node_hash(plan)
    if not h:
        raise Error("test: no PLAN_CSE_REF found in plan")
    return h.value()


def _two_lineitem_self_join() -> LogicalPlan:
    """`Join(filter(scan), filter(scan))` — identical filter subtrees on
    both sides. This is the canonical 2-occurrence CSE fixture."""
    var left_on = List[String]()
    left_on.append(String("l_orderkey"))
    var right_on = List[String]()
    right_on.append(String("l_orderkey"))
    return LogicalPlan.join(
        _filter_lineitem()^, _filter_lineitem()^,
        left_on^, right_on^, JOIN_INNER, JOIN_ALGO_AUTO,
    )


# =============================================================================
# Tests
# =============================================================================


def test_detection_and_rewrite_2_occurrences() raises:
    """Join(filter(scan), filter(scan)) → after force-rewrite, 1
    filter(scan) instance + 1 PLAN_CSE_REF (not 2 filter instances)."""
    var p = _two_lineitem_self_join()
    # Detection: at least one candidate group (filter(scan), plus bare scan).
    assert_true(detect_cse_candidates(p) >= 1)
    # The filter(scan) subtree should occur exactly twice.
    var sub_h = _filter_lineitem().structural_hash()
    assert_equal(count_subtree_occurrences(p, sub_h), 2)

    var rewritten = plan_cse_eliminate(p^, force_rewrite=True)
    # Exactly 1 PLAN_FILTER (the canonical occurrence) + 1 PLAN_CSE_REF.
    assert_equal(_count_tag(rewritten, PLAN_FILTER), 1)
    assert_equal(_count_tag(rewritten, PLAN_CSE_REF), 1)
    # Exactly 1 PLAN_SCAN (inside the canonical filter).
    assert_equal(_count_tag(rewritten, PLAN_SCAN), 1)


def test_cse_ref_hashes() raises:
    """The CSE ref's canonical_hash == the original subtree's
    structural_hash; the ref node's own structural_hash == canonical_hash
    (re-CSE idempotence)."""
    var sub_h = _filter_lineitem().structural_hash()
    var p = _two_lineitem_self_join()
    var rewritten = plan_cse_eliminate(p^, force_rewrite=True)
    assert_equal(_first_cse_ref_canonical_hash(rewritten), sub_h)
    # PLAN_CSE_REF.structural_hash is special-cased to its canonical_hash.
    assert_equal(_first_cse_ref_node_hash(rewritten), sub_h)


def test_structural_differential() raises:
    """The un-CSE'd plan still has 2 PLAN_SCAN; the CSE'd plan has 1
    PLAN_SCAN + 1 PLAN_CSE_REF. (The runtime differential — both plans
    materialize to identical results — is deferred to the engine-multi-
    consumer follow-up slot, since a CSE'd plan cannot currently be
    materialized.)"""
    var p_uncsed = _two_lineitem_self_join()
    assert_equal(_count_tag(p_uncsed, PLAN_SCAN), 2)
    assert_equal(_count_tag(p_uncsed, PLAN_CSE_REF), 0)

    var p_csed = plan_cse_eliminate(_two_lineitem_self_join()^, force_rewrite=True)
    assert_equal(_count_tag(p_csed, PLAN_SCAN), 1)
    assert_equal(_count_tag(p_csed, PLAN_CSE_REF), 1)


def test_force_rewrite_false_is_noop() raises:
    """plan_cse_eliminate with `force_rewrite=False` explicitly is a no-op
    regardless of the `_ENABLE_CSE_REWRITE` gate (which is ON)."""
    var p = _two_lineitem_self_join()
    var before_h = p.structural_hash()
    var after = plan_cse_eliminate(p^, force_rewrite=False)
    assert_equal(after.structural_hash(), before_h)
    assert_equal(_count_tag(after, PLAN_CSE_REF), 0)
    assert_equal(_count_tag(after, PLAN_SCAN), 2)


def test_default_gate_now_rewrites() raises:
    """The default `force_rewrite` (== `_ENABLE_CSE_REWRITE`) is ON, so
    `plan_cse_eliminate(p^)`
    with no explicit flag DOES rewrite a duplicated subtree."""
    var after = plan_cse_eliminate(_two_lineitem_self_join()^)
    assert_equal(_count_tag(after, PLAN_CSE_REF), 1)
    assert_equal(_count_tag(after, PLAN_SCAN), 1)


def test_no_duplicates_unchanged() raises:
    """A plan with no PURE duplicated subtree is returned unchanged even
    with force_rewrite=True."""
    var p = _filter_lineitem()  # single filter(scan), no dup
    var before_h = p.structural_hash()
    var after = plan_cse_eliminate(p^, force_rewrite=True)
    assert_equal(after.structural_hash(), before_h)
    assert_equal(_count_tag(after, PLAN_CSE_REF), 0)


def test_purity_guard() raises:
    """`_subtree_is_pure` is fail-closed: a node whose tag is NOT in the
    known-pure allowlist is treated as NOT pure (and is never a CSE
    candidate). We exercise the allowlist directly: known tags are pure,
    an out-of-range synthetic tag is not.

    (There is no side-effect-bearing LogicalPlan node today, so we cannot
    build a real impure subtree — this test locks in the fail-closed
    semantics so a future impure node defaults to "do not CSE".)"""
    # Known-pure shapes.
    assert_true(_subtree_is_pure(_make_lineitem()))
    assert_true(_subtree_is_pure(_filter_lineitem()))
    assert_true(_subtree_is_pure(_two_lineitem_self_join()))
    # A synthetic out-of-allowlist tag (200 is well past PLAN_CSE_REF=14):
    # construct a bare LogicalPlan with that tag and assert it is NOT pure.
    var b = SchemaBuilder()
    b.add_field(Field(String("x"), ArrowType.INT64, False))
    var schema = b.build()
    var fake = LogicalPlan(UInt8(200), schema^)
    assert_true(not _subtree_is_pure(fake))


def test_union_recursion() raises:
    """A PLAN_UNION whose two branches share a sub-subtree → the shared
    sub-subtree gets CSE'd (proves the walker recurses through union
    children).

    Fixture: Union(Project(filter(scan)), Project(filter(scan))) — both
    branches wrap the SAME `filter(scan)` subtree (different Projects on
    top, so the branches themselves differ but the inner filter(scan) is
    shared). After force-rewrite: 1 filter(scan) instance + 1 PLAN_CSE_REF.
    """
    # Project that keeps just l_orderkey (left branch) and one keeping
    # just l_quantity (right branch) — so the two branches are NOT
    # structurally identical (no whole-branch CSE), only the inner
    # filter(scan) is shared.
    var left_exprs = ExprArray()
    left_exprs.append(Expr.col_ref(String("l_orderkey")))
    var b_left = SchemaBuilder()
    b_left.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    var left_proj = LogicalPlan.project(left_exprs^, _filter_lineitem())

    var right_exprs = ExprArray()
    right_exprs.append(Expr.col_ref(String("l_quantity")))
    var right_proj = LogicalPlan.project(right_exprs^, _filter_lineitem())

    # Union output schema: l_orderkey (the engine doesn't coerce; for this
    # IR-only test the schema just needs to be present).
    var b_union = SchemaBuilder()
    b_union.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    var union_schema = b_union.build()

    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(left_proj^))
    children.append(OwnedPointer(right_proj^))
    var p = LogicalPlan.union(children^, union_schema^)

    # Detection: the inner filter(scan) occurs twice.
    var sub_h = _filter_lineitem().structural_hash()
    assert_equal(count_subtree_occurrences(p, sub_h), 2)
    assert_true(detect_cse_candidates(p) >= 1)

    var rewritten = plan_cse_eliminate(p^, force_rewrite=True)
    # The shared filter(scan): 1 canonical instance + 1 ref.
    assert_equal(_count_tag(rewritten, PLAN_FILTER), 1)
    assert_equal(_count_tag(rewritten, PLAN_CSE_REF), 1)
    assert_equal(_count_tag(rewritten, PLAN_SCAN), 1)
    # Both Projects survive (the branches themselves were not deduplicated).
    assert_equal(_count_tag(rewritten, PLAN_PROJECT), 2)
    # The ref points at the filter(scan) subtree hash.
    assert_equal(_first_cse_ref_canonical_hash(rewritten), sub_h)


def main() raises:
    test_detection_and_rewrite_2_occurrences()
    test_cse_ref_hashes()
    test_structural_differential()
    test_force_rewrite_false_is_noop()
    test_default_gate_now_rewrites()
    test_no_duplicates_unchanged()
    test_purity_guard()
    test_union_recursion()
    print("test_plan_cse_rewrite: all 7 cases PASS")
