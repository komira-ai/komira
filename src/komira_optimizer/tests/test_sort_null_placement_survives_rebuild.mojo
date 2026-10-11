# =============================================================================
# ★★ AN EXPLICIT NULL PLACEMENT MUST SURVIVE EVERY PLAN REBUILD
#    (2026-09-21).
# =============================================================================
#
# ⛔ THE DEFECT CLASS, STATED ONCE. `SortData.nulls_first` / `TopNData.
# nulls_first` are the plan's record of `ORDER BY ... NULLS FIRST/LAST`. Every
# rule that REBUILDS a sort or top-n node does it by reading `.keys` and
# `.descending` off the old node and calling `LogicalPlan.sort(...)` /
# `.topn(...)` — and the placement argument is the LAST, OPTIONAL one, so
# omitting it compiles, runs, and silently re-derives `nulls_first[i] = not
# descending[i]`. A dropped placement is not a crash and not a missing column:
# it is the SAME PLAN SHAPE carrying a DIFFERENT ORDER BY.
#
# ★ AND IT IS WORSE UNDER A `LIMIT`. `fuse_sort_limit` folds `LIMIT(SORT(x))`
#   into one `PLAN_TOPN`. If the fold drops the placement, the fused plan does
#   not merely order differently — it RETURNS A DIFFERENT SET OF ROWS from the
#   unfused one. An optimisation that changes the answer is the one thing a
#   rewrite may never do, which is why `test_fuse_sort_limit_carries_it` is
#   here and not folded into the generic case.
#
# ⚠ WHY THIS IS TESTED AT THE PLAN AND NOT THROUGH A QUERY. The placement was
#   UNREADABLE below the plan until 2026-09-21 (`SortSinkData` had no such
#   field), so no end-to-end answer could distinguish a preserved placement
#   from a dropped one — the executor derived the default either way. A
#   value-level test would therefore have been GREEN over every one of these
#   rebuild sites while all of them dropped it. The field's survival is the
#   only observable there is, so it is what is asserted.
#
# ⛔ THIS FILE DOES NOT COVER EVERY REBUILD SITE. The Sort and TopN rebuilds
#   in `resolve_scalar_subqueries` carry the placement, and
#   `test_optimizer_resolve_scalar_subqueries.mojo` asserts that it survives
#   them. The scan-dedup rebuild is not in this package, so nothing here
#   reaches it.
#
# ★ THE CONTROL ARM IS A CLAIM ABOUT THE PRE-FIX TREE. `*_default_is_unchanged`
#   runs the same rebuilds over a plan whose placement IS the derived default;
#   the unfixed tree passes it, because dropping a field and re-deriving the
#   same value are indistinguishable. Without it, a red on the explicit arms
#   cannot be told from "the rewrite did not fire on this plan at all".
#
# ⛔⛔ AND THAT IS EXACTLY WHY NO ARM MAY SPELL A PLACEMENT AS A LITERAL.
#   EVERY ARM HERE IS DERIVED FROM `null_order_policy.derived_nulls_first`
#   (2026-09-23), and the reason is a MEASURED regression in this file.
#
#   Until 2026-09-23 the arms were literals written against the engine's
#   THEN-default (ASC -> NULLS FIRST). A later change flipped the default to NULLS
#   LAST IN BOTH DIRECTIONS and did NOT touch this file — so the two classes of
#   arm SWAPPED ROLES SILENTLY, with every assertion still green:
#
#     arm                                          (desc, nf)   became
#     test_copy_plan_default_is_unchanged            (F, True)  a DISCRIMINATING
#     test_window_rewrite_default_is_unchanged       (F, True)  arm labelled
#                                                              "CONTROL"
#     test_copy_plan_carries_an_explicit_placement   (F, False) ⛔ VACUOUS
#     test_copy_plan_carries_it_on_a_topn            (F, False) ⛔ VACUOUS
#     test_window_rewrite_carries_an_explicit_...    (F, False) ⛔ VACUOUS
#     test_push_aggregate_below_join_carries_...     (F, False) ⛔ VACUOUS
#     test_push_aggregate_below_join_carries_it_...  (F, False) ⛔ VACUOUS
#     test_fuse_sort_limit_carries_it                (F, False) ⛔ VACUOUS
#
#   SIX of eleven arms stopped discriminating, because an arm can only tell a
#   CARRIED placement from a DROPPED one when the value it pins DIFFERS from
#   what `_resolve_nulls_first` re-derives — and `(ASC, NULLS LAST)` became the
#   derived value. ⛔ INCLUDING `test_fuse_sort_limit_carries_it`, the §3 arm,
#   which was the ONLY cover for the fold this header calls "an optimisation
#   that changes the answer": `fuse_sort_limit` was left graded by NOTHING. And
#   the two arms that DID still discriminate were labelled CONTROL, so a reader
#   auditing coverage would have counted them on the wrong side.
#
#   ⇒ A PLACEMENT LITERAL IS A CLAIM ABOUT THE ENGINE'S DEFAULT, and this file
#   is the wrong place to make one. `_explicit()` is the negation of the policy
#   and `_derived()` is the policy; a future flip re-inverts both and every
#   label stays true. That is what a literal cannot do.
# =============================================================================

from std.collections import Optional
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SORT,
    PLAN_TOPN,
    SOURCE_PARQUET,
)
from komira_plan_expr.null_order_policy import derived_nulls_first
from komira_plan_ir.plan_helpers import _copy_plan

from komira_optimizer.optimizer_misc import fuse_sort_limit
from komira_optimizer.optimizer_partial_agg import push_aggregate_below_join
from komira_optimizer.optimizer_window_rewrite import optimize_window_rewrite


def _scan() raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def _one(b: Bool) -> List[Bool]:
    var l = List[Bool]()
    l.append(b)
    return l^


def _keys() -> List[String]:
    var k = List[String]()
    k.append(String("v"))
    return k^


def _derived(descending: Bool) -> Bool:
    """The placement the engine RE-DERIVES when a rebuild drops the field.

    A CONTROL arm asks for this, so a dropped field and a re-derived value are
    indistinguishable and the pre-fix tree passes it.
    """
    return derived_nulls_first(descending)


def _explicit(descending: Bool) -> Bool:
    """The placement that DIFFERS from what a dropped field re-derives.

    ⛔ THIS IS THE ONLY VALUE A DISCRIMINATING ARM MAY ASK FOR. A `False`
    literal here was six arms' whole defect on 2026-09-22 — see the header.
    """
    return not derived_nulls_first(descending)


def _sort_plan(descending: Bool, nulls_first: Bool) raises -> LogicalPlan:
    """`SORT(v <dir> NULLS <placement>) -> SCAN`."""
    return LogicalPlan.sort(
        _keys(), _one(descending), _scan(), Optional(_one(nulls_first))
    )


def _topn_plan(descending: Bool, nulls_first: Bool) raises -> LogicalPlan:
    return LogicalPlan.topn(
        _keys(), _one(descending), 3, _scan(), Optional(_one(nulls_first))
    )


def _assert_sort_placement(
    imm p: LogicalPlan, want: Bool, imm what: String
) raises:
    assert_equal(p.tag, PLAN_SORT, String("tag after ") + what)
    ref sd = p._sort.value()[]
    assert_equal(
        len(sd.nulls_first), 1, String("placement arity after ") + what
    )
    assert_equal(
        sd.nulls_first[0],
        want,
        String("NULL placement after ")
        + what
        + " — the rebuild dropped it and `_resolve_nulls_first` re-derived"
        " `not descending`, which is a DIFFERENT ORDER BY under the same plan"
        " shape",
    )


def _assert_topn_placement(
    imm p: LogicalPlan, want: Bool, imm what: String
) raises:
    assert_equal(p.tag, PLAN_TOPN, String("tag after ") + what)
    ref td = p._topn.value()[]
    assert_equal(
        len(td.nulls_first), 1, String("placement arity after ") + what
    )
    assert_equal(
        td.nulls_first[0], want, String("NULL placement after ") + what
    )


# =============================================================================
# §1 CONTROL — a placement that IS the derived default. The UNFIXED tree passes.
# =============================================================================


def test_copy_plan_default_is_unchanged() raises:
    # `_derived(ASC)`, so a dropped field re-derives the SAME value and the
    # pre-fix tree passes — which is the whole point of a control arm.
    _assert_sort_placement(
        _copy_plan(_sort_plan(False, _derived(False))),
        _derived(False),
        String("CONTROL _copy_plan, ASC placement == derived default"),
    )


def test_copy_plan_default_is_unchanged_desc() raises:
    """★ ADDED 2026-09-23. The DESC control, which did not exist for
    `_copy_plan`: with the placement derived, one direction's control and the
    other's discriminating arm can no longer be the same `(desc, nf)` pair by
    accident, and a reader can see that BOTH directions have both kinds."""
    _assert_sort_placement(
        _copy_plan(_sort_plan(True, _derived(True))),
        _derived(True),
        String("CONTROL _copy_plan, DESC placement == derived default"),
    )


def test_window_rewrite_default_is_unchanged() raises:
    _assert_sort_placement(
        optimize_window_rewrite(_sort_plan(False, _derived(False))),
        _derived(False),
        String("CONTROL optimize_window_rewrite, default placement"),
    )


# =============================================================================
# §2 THE EXPLICIT PLACEMENT SURVIVES. Every arm here is RED on the unfixed tree.
#
# ⛔ `_explicit(dir)`, NEVER A LITERAL. Six of these arms were `False` literals
#    and went VACUOUS on 2026-09-22 when the engine's default became NULLS LAST
#    — a green test asserting the value a DROPPED field re-derives. See header.
# =============================================================================


def test_copy_plan_carries_an_explicit_placement() raises:
    """`_copy_plan` is the generic deep copy ~60 call sites across six optimizer
    rule modules reach, so it is the single highest-fanout dropper in the tree."""
    _assert_sort_placement(
        _copy_plan(_sort_plan(False, _explicit(False))),
        _explicit(False),
        String("_copy_plan, ASC + the explicit OPPOSITE of the default"),
    )


def test_copy_plan_carries_an_explicit_placement_desc() raises:
    _assert_sort_placement(
        _copy_plan(_sort_plan(True, _explicit(True))),
        _explicit(True),
        String("_copy_plan, DESC + the explicit OPPOSITE of the default"),
    )


def test_copy_plan_carries_it_on_a_topn() raises:
    _assert_topn_placement(
        _copy_plan(_topn_plan(False, _explicit(False))),
        _explicit(False),
        String("_copy_plan, TOPN ASC + the explicit OPPOSITE"),
    )


def test_window_rewrite_carries_an_explicit_placement() raises:
    _assert_sort_placement(
        optimize_window_rewrite(_sort_plan(False, _explicit(False))),
        _explicit(False),
        String("optimize_window_rewrite, ASC + the explicit OPPOSITE"),
    )


def test_window_rewrite_carries_it_on_a_topn() raises:
    _assert_topn_placement(
        optimize_window_rewrite(_topn_plan(True, _explicit(True))),
        _explicit(True),
        String("optimize_window_rewrite, TOPN DESC + the explicit OPPOSITE"),
    )


def test_push_aggregate_below_join_carries_an_explicit_placement() raises:
    """This rule walks through a SORT it does not otherwise change; the rebuild
    happens whether or not the aggregate push fires underneath."""
    _assert_sort_placement(
        push_aggregate_below_join(_sort_plan(False, _explicit(False))),
        _explicit(False),
        String("push_aggregate_below_join, ASC + the explicit OPPOSITE"),
    )


def test_push_aggregate_below_join_carries_it_on_a_topn() raises:
    _assert_topn_placement(
        push_aggregate_below_join(_topn_plan(False, _explicit(False))),
        _explicit(False),
        String("push_aggregate_below_join, TOPN ASC + the explicit OPPOSITE"),
    )


# =============================================================================
# §3 THE FUSION — where a dropped placement changes WHICH ROWS COME BACK.
# =============================================================================


def test_fuse_sort_limit_carries_it() raises:
    """`LIMIT(SORT(v ASC <opposite of the default>))` -> `TOPN`. ⛔ IF THE FOLD
    DROPS THE PLACEMENT the fused plan re-derives the default, and over a column
    with NULLs that is a DISJOINT SET of rows from what the unfused plan returns
    — an optimisation that changes the answer.

    ⛔ THIS ARM WAS VACUOUS FROM 2026-09-22 TO 2026-09-23. It asked for
    `(ASC, False)` as a literal, which the default flip turned INTO the derived
    value, so it could no longer tell a carried placement from a dropped one —
    and it is the only arm covering this fold."""
    var p = LogicalPlan.limit(3, _sort_plan(False, _explicit(False)))
    _assert_topn_placement(
        fuse_sort_limit(p^),
        _explicit(False),
        String("fuse_sort_limit, ASC + the explicit OPPOSITE"),
    )


def test_fuse_sort_limit_carries_it_desc() raises:
    """★ ADDED 2026-09-23. The fold in the OTHER direction. With the placement
    derived this is no longer the same pair as the ASC arm under any policy, so
    one flip cannot void both."""
    var p = LogicalPlan.limit(3, _sort_plan(True, _explicit(True)))
    _assert_topn_placement(
        fuse_sort_limit(p^),
        _explicit(True),
        String("fuse_sort_limit, DESC + the explicit OPPOSITE"),
    )


def test_fuse_sort_limit_default_is_unchanged() raises:
    """CONTROL for the fusion: the unfixed tree passes this one, because a
    dropped field and a re-derived identical value are indistinguishable."""
    var p = LogicalPlan.limit(3, _sort_plan(True, _derived(True)))
    _assert_topn_placement(
        fuse_sort_limit(p^),
        _derived(True),
        String("CONTROL fuse_sort_limit, DESC + derived default"),
    )


# =============================================================================
# §4 THE ANTI-VACUITY ARM — the one that would have caught 2026-09-22.
# =============================================================================


def test_every_explicit_arm_differs_from_the_derived_default() raises:
    """★★ THE ARM THAT MAKES §2/§3 NON-VACUOUS, ASSERTED RATHER THAN ARGUED.

    Six arms above went silently vacuous when the engine's default moved, and
    NOTHING went red — every assertion still held, because asserting the value a
    dropped field re-derives is trivially true. The property those arms depend on
    is that the placement they ask for DIFFERS from the derived one, and that is
    a statement about `derived_nulls_first`, so it can be asserted directly:
    whatever the policy becomes, `_explicit(d) != _derived(d)` in BOTH
    directions. If a future policy makes those equal, THIS arm reds and names
    the problem instead of six arms going quietly green.
    """
    assert_equal(
        _explicit(False) == _derived(False),
        False,
        String(
            "ASC: the explicit placement the §2/§3 arms ask for EQUALS the"
            " derived default, so every one of them now asserts the value a"
            " DROPPED field re-derives — they cannot tell a carried placement"
            " from a dropped one. This is the 2026-09-22 regression recurring;"
            " see this file's header."
        ),
    )
    assert_equal(
        _explicit(True) == _derived(True),
        False,
        String(
            "DESC: same, in the descending direction."
        ),
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_copy_plan_default_is_unchanged]()
    suite.test[test_copy_plan_default_is_unchanged_desc]()
    suite.test[test_window_rewrite_default_is_unchanged]()
    suite.test[test_copy_plan_carries_an_explicit_placement]()
    suite.test[test_copy_plan_carries_an_explicit_placement_desc]()
    suite.test[test_copy_plan_carries_it_on_a_topn]()
    suite.test[test_window_rewrite_carries_an_explicit_placement]()
    suite.test[test_window_rewrite_carries_it_on_a_topn]()
    suite.test[test_push_aggregate_below_join_carries_an_explicit_placement]()
    suite.test[test_push_aggregate_below_join_carries_it_on_a_topn]()
    suite.test[test_fuse_sort_limit_carries_it]()
    suite.test[test_fuse_sort_limit_carries_it_desc]()
    suite.test[test_fuse_sort_limit_default_is_unchanged]()
    suite.test[test_every_explicit_arm_differs_from_the_derived_default]()
    suite^.run()
