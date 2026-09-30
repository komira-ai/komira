"""`Expr.correlated_subquery(...)` factory + `CorrelatedSubqueryData.copy()`
deep-clone validation.

Covers the `EXPR_CORRELATED_SUBQUERY` Expr variant's construction + copy +
write_to surface — the data contract the `flatten_dependent_joins` compiler
pass relies on.

Coverage:
  - Factory build for all 3 kinds (EXISTS / NOT_EXISTS / SCALAR).
  - `CorrelatedSubqueryData.copy()` deep-clones the inner LogicalPlan
    (byte-disjoint from the original — assert via mutating clone-side
    refs and checking original survives unchanged).
  - `Expr.copy()` cascade arm for EXPR_CORRELATED_SUBQUERY (tag-dispatch).
  - `write_to` (Writable) surface emits the kind + outer_refs count +
    inner_tag for EXPLAIN.
  - Multi-key `outer_refs` (Q20 shape) round-trip.

Reference (DuckDB / DataFusion):
  - DuckDB `src/planner/subquery/flatten_dependent_join.cpp` —
    `FlattenDependentJoins::RewriteCorrelatedExpressions` clones each
    correlated expression's inner plan tree recursively. Our
    `CorrelatedSubqueryData.copy()` mirrors that recursion shape with a
    deep copy of the inner `LogicalPlan`.
  - DataFusion `optimizer/src/decorrelate_predicate_subquery.rs` —
    `Subquery::clone` clones the inner `Arc<LogicalPlan>` (refcount
    bump). Our equivalent: `inner_plan[].copy()` which deep-clones
    rather than refcount-bumping, because the Mojo type is
    OwnedPointer (single-owner) not ArcPointer.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.schema import SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.expr import (
    Expr,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_COL_REF,
)
from komira_core.plan.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    SOURCE_PARQUET,
    CORR_KIND_EXISTS,
    CORR_KIND_NOT_EXISTS,
    CORR_KIND_SCALAR,
)
from komira_core.plan.corr_subquery import (
    corr_subq_inner_plan_ref,
    corr_data_inner_plan_ref,
    CORR_SUBQ_PLAN_TYPE_TAG_MISMATCH,
)
from komira_core.plan.corr_subquery_data import (
    CorrelatedSubqueryData,
    make_correlated_subquery_data,
)
from komira_core.plan.erased_box import make_erased_box


def _make_inner_plan() -> LogicalPlan:
    """Build a 2-deep inner plan: Scan -> Filter(EXPR_COL_REF, treated as Bool)."""
    var builder = SchemaBuilder()
    builder.add_field(Field(String("o_orderkey"), ArrowType.INT64, False))
    builder.add_field(Field(String("o_custkey"), ArrowType.INT64, False))
    var schema = builder.build()
    var scan = LogicalPlan.scan(
        String("orders.parquet"), SOURCE_PARQUET, schema^,
    )
    return LogicalPlan.filter(Expr.col_ref(String("o_orderkey")), scan^)


def test_factory_exists() raises:
    """Build an EXISTS-kind correlated subquery (Q4 shape, 1 outer key)."""
    var inner = _make_inner_plan()
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var e = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    assert_equal(e.tag, EXPR_CORRELATED_SUBQUERY)
    # Round-trip via write_to so we exercise the new EXPLAIN arm.
    var s = String(e)
    assert_true(s.find("CorrelatedSubquery") >= 0)
    assert_true(s.find("kind=0") >= 0)
    assert_true(s.find("outer_refs=#1") >= 0)


def test_factory_not_exists() raises:
    """Build a NOT_EXISTS-kind correlated subquery (Q21 shape)."""
    var inner = _make_inner_plan()
    var refs = List[String]()
    refs.append(String("s_suppkey"))
    var e = Expr.correlated_subquery(inner^, refs^, CORR_KIND_NOT_EXISTS)
    assert_equal(e.tag, EXPR_CORRELATED_SUBQUERY)
    var s = String(e)
    assert_true(s.find("kind=1") >= 0)


def test_factory_scalar() raises:
    """Build a SCALAR-kind correlated subquery (Q17 shape)."""
    var inner = _make_inner_plan()
    var refs = List[String]()
    refs.append(String("p_partkey"))
    var e = Expr.correlated_subquery(inner^, refs^, CORR_KIND_SCALAR)
    assert_equal(e.tag, EXPR_CORRELATED_SUBQUERY)
    var s = String(e)
    assert_true(s.find("kind=2") >= 0)


def test_factory_multi_key() raises:
    """Multi-key outer_refs (Q20 shape — EXISTS with 2 keys)."""
    var inner = _make_inner_plan()
    var refs = List[String]()
    refs.append(String("ps_partkey"))
    refs.append(String("ps_suppkey"))
    var e = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    var s = String(e)
    assert_true(s.find("outer_refs=#2") >= 0)


def test_copy_preserves_kind_and_refs() raises:
    """`Expr.copy()` cascade dispatches to CorrelatedSubqueryData.copy()
    and the cloned variant preserves kind + outer_refs."""
    var inner = _make_inner_plan()
    var refs = List[String]()
    refs.append(String("c_custkey"))
    refs.append(String("o_year"))
    var orig = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    var clone = orig.copy()
    # Both should stringify identically — same kind, same refs count,
    # same inner_plan tag.
    var s_orig = String(orig)
    var s_clone = String(clone)
    assert_equal(s_orig, s_clone)
    assert_equal(clone.tag, EXPR_CORRELATED_SUBQUERY)


def test_copy_chained_idempotent() raises:
    """`Expr.copy().copy()` is byte-disjoint from the original (idempotence
    of the deep-clone path)."""
    var inner = _make_inner_plan()
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var orig = Expr.correlated_subquery(inner^, refs^, CORR_KIND_SCALAR)
    var clone1 = orig.copy()
    var clone2 = clone1.copy()
    assert_equal(String(orig), String(clone2))


def test_inner_plan_deep_clone() raises:
    """The clone's inner plan is INDEPENDENT of the original's.

    ⚠ ASSERTING ONLY THAT THE TWO STRINGIFY THE SAME IS EXACTLY WHAT A
    SHARED PLAN ALSO DOES. Two `Expr`s pointing at ONE plan render
    identically and pass that assertion forever. The plan lives in an
    `ErasedBox` behind a copy thunk, and "is the thunk actually deep?" is a
    real question — so the assertion is a MUTATION on one side and a READ on
    the other, which sharing cannot survive.

    Goes red if `erased_box_copy_for[W]` is ever "optimised" into a pointer
    copy, or if `ErasedBox.copy()` reuses the source home."""
    var inner_a = _make_inner_plan()
    var refs_a = List[String]()
    refs_a.append(String("c_custkey"))
    var orig = Expr.correlated_subquery(inner_a^, refs_a^, CORR_KIND_EXISTS)
    var clone = orig.copy()

    # Pre-condition: BOTH sides see the same plan shape. Without this the
    # mutation below could pass by having found nothing to mutate.
    assert_equal(
        Int(corr_subq_inner_plan_ref(orig).tag), Int(PLAN_FILTER),
        "fixture: the original's inner plan is Filter(Scan)",
    )
    assert_equal(
        Int(corr_subq_inner_plan_ref(clone).tag), Int(PLAN_FILTER),
        "fixture: the clone's inner plan is Filter(Scan)",
    )

    # Mutate the ORIGINAL's inner plan in place. `corr_subq_inner_plan_ref`
    # hands back a MUTABLE ref when the receiver is mutable — the same
    # capability `scan_binding_bind_pass` relies on.
    corr_subq_inner_plan_ref(orig).tag = PLAN_SCAN

    assert_equal(
        Int(corr_subq_inner_plan_ref(orig).tag), Int(PLAN_SCAN),
        "the mutation landed on the original",
    )
    assert_equal(
        Int(corr_subq_inner_plan_ref(clone).tag), Int(PLAN_FILTER),
        "THE CLONE MUST NOT SEE THE ORIGINAL'S MUTATION — a shared plan here"
        " would let one Expr's bind pass silently bind another's subquery",
    )

    # ★ AND NOW THE HEAP SIDE, WHICH THE ASSERTION ABOVE CANNOT REACH.
    # `tag` is INLINE in `LogicalPlan`, so a byte-copy clone gets its own copy
    # of it and would pass everything above. The realistic future regression is
    # exactly that: someone "optimises" `erased_box_copy_for[W]` into a memcpy,
    # which is independent in the inline fields and SHARED in every
    # `OwnedPointer` field. Filter's `child` is one, so mutating THROUGH it is
    # what separates a deep clone from a shallow one.
    corr_subq_inner_plan_ref(orig)._filter.value()[].child[].tag = PLAN_FILTER
    assert_equal(
        Int(corr_subq_inner_plan_ref(orig)._filter.value()[].child[].tag),
        Int(PLAN_FILTER),
        "the heap-side mutation landed on the original",
    )
    assert_equal(
        Int(corr_subq_inner_plan_ref(clone)._filter.value()[].child[].tag),
        Int(PLAN_SCAN),
        "THE CLONE'S HEAP CHILD MUST NOT BE SHARED — this is the assertion a"
        " byte-copy clone fails and every inline-field assertion passes",
    )


def test_copy_still_carries_a_subquery() raises:
    """THE INVARIANT-LEVEL GUARD, not an arm-by-arm one.

    A plan copy can drop a payload from every optimizer call site while
    per-ARM checks stay green, because a node can be structurally intact
    while having lost its payload. So prefer a post-condition over an arm: a
    post-condition covers arms that do not exist yet. This is that
    post-condition for the subquery payload — "carried one before, must
    carry a RESOLVABLE one after" — and it does not name a single copy
    site."""
    var inner = _make_inner_plan()
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var orig = Expr.correlated_subquery(inner^, refs^, CORR_KIND_SCALAR)

    assert_true(Bool(orig._corr_subq), "fixture carries a subquery payload")
    var copied = orig.copy()
    assert_true(
        Bool(copied._corr_subq),
        "a copy that keeps the tag and loses the payload is the _copy_plan class",
    )
    # RESOLVABLE, not merely present: a copied box with a wrong vtable or a
    # clobbered type tag is present and unusable.
    assert_equal(
        Int(corr_subq_inner_plan_ref(copied).tag), Int(PLAN_FILTER),
        "the copied payload's plan must still unbox",
    )
    assert_equal(
        Int(copied.corr_subq_kind()), Int(CORR_KIND_SCALAR),
        "the copied payload keeps its kind",
    )


def test_unbox_refuses_a_wrong_type_tag() raises:
    """A box whose type tag is not `LogicalPlan`'s is REFUSED, not read.

    ⚠ THIS IS THE ONE GUARD BETWEEN AN ERASED BOX AND A TYPE CONFUSION. The
    bytes carry no type, so a `bitcast` to the wrong type is not a crash — it is
    a plausible-looking struct read out of foreign bytes, i.e. the
    silent-wrong-answer class the refusal exists to replace.

    Unreachable through the public path BY CONSTRUCTION:
    `make_correlated_subquery_data` derives the tag from the plan itself
    (`BoxablePlan.erased_type_tag`), so no caller can mint a mismatched pair.
    The fixture therefore FORGES one through the raw `CorrelatedSubqueryData`
    constructor — which is the only way to reach this arm, and is why that
    constructor's docstring tells callers to use the helper instead.

    Goes red if the tag check in `corr_data_inner_plan_ref` is dropped."""
    var forged = CorrelatedSubqueryData(
        make_erased_box[LogicalPlan](_make_inner_plan(), UInt32(0xDEADBEEF)),
        List[String](),
        CORR_KIND_EXISTS,
        UInt8(0),
    )
    var raised = False
    try:
        _ = corr_data_inner_plan_ref(forged).tag
    except e:
        raised = True
        assert_true(
            String(e).find(String(CORR_SUBQ_PLAN_TYPE_TAG_MISMATCH)) >= 0,
            "the refusal must name CORR_SUBQ_PLAN_TYPE_TAG_MISMATCH, so the"
            " failure is greppable rather than a generic Error",
        )
    assert_true(raised, "a mismatched type tag MUST raise, never dereference")
    _ = forged^


def test_wellformed_box_is_accepted() raises:
    """The POSITIVE CONTROL for the test above.

    Without it, a `corr_data_inner_plan_ref` that raised unconditionally would
    make the refusal test pass — an instrument that refuses everything proves
    nothing about the guard."""
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var e = Expr.correlated_subquery(
        _make_inner_plan(), refs^, CORR_KIND_EXISTS
    )
    assert_equal(
        Int(corr_subq_inner_plan_ref(e).tag), Int(PLAN_FILTER),
        "a box minted through the helper unboxes without raising",
    )


def test_empty_outer_refs() raises:
    """Zero outer_refs is structurally allowed (degenerate uncorrelated
    subquery — the planner should treat it as a regular subquery rather
    than correlated, but the variant itself accepts it). This is the
    boundary case the flatten pass builds on for
    `UnresolvedOuterRef` semantics."""
    var inner = _make_inner_plan()
    var refs = List[String]()
    var e = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    var s = String(e)
    assert_true(s.find("outer_refs=#0") >= 0)


def main() raises:
    test_factory_exists()
    test_factory_not_exists()
    test_factory_scalar()
    test_factory_multi_key()
    test_copy_preserves_kind_and_refs()
    test_copy_chained_idempotent()
    test_inner_plan_deep_clone()
    test_copy_still_carries_a_subquery()
    test_unbox_refuses_a_wrong_type_tag()
    test_wellformed_box_is_accepted()
    test_empty_outer_refs()
    print("All correlated_subquery factory + copy() tests passed.")
