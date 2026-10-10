# =============================================================================
# test_physical_plan_purity_gate — THE FALSIFIER for the correlated-subquery
# refusal that keeps a LOGICAL plan out of the PHYSICAL one.
# =============================================================================
#
# The physical plan must not carry a logical one: that is the precondition for
# shipping the optimizer and the engine as separate binaries.
# `SegmentDescPod` can reach a whole `LogicalPlan` through
# `Expr._corr_subq -> CorrelatedSubqueryData._plan`. Without this gate the
# property rests on a dynamic invariant (`flatten_dependent_joins` leaves zero
# `EXPR_CORRELATED_SUBQUERY` nodes) that an unchecked `@extern` seam cannot
# carry.
#
# ⛔ WHAT GOES RED WITHOUT THE GATE. Every refusal case here calls the door and
# requires it to RAISE; against no gate at all the module does not exist and
# this file does not compile, and against a gate that walks only the tags the
# fail-open walker walks, the TWELVE non-WHEN container cases in
# `test_gate_finds_a_subquery_under_every_container_a_fail_open_walk_skips`
# return False and this file fails.
#
# ⚠ AND THE POSITIVE CONTROLS ARE NOT DECORATION. A gate that refused
# EVERYTHING would satisfy every refusal case here while refusing every query. `test_gate_accepts_an_ordinary_plan` and
# `test_walker_says_no_to_an_ordinary_expression_tree` are what tell those two
# apart — and the first of them asserts the SITE COUNT, not merely the absence
# of a raise, because "checked, found nothing" and "checked nothing" are
# otherwise the same observation.
#
# ⚠ THE EXHAUSTIVENESS CLAIM IS TESTED, NOT ASSERTED IN PROSE.
# `test_walker_has_an_arm_for_every_expr_tag` instantiates EVERY tag id in
# `[0, EXPR_TAG_COUNT)` and requires the walk to answer rather than raise, and
# `test_walker_raises_on_a_tag_it_does_not_model` proves that raise arm is live
# rather than unreachable. Raising `EXPR_TAG_COUNT` for a new tag without an
# arm here turns the first one red.
#
# What this file does NOT prove: that anything CALLS the door. Its intended
# caller, `segment_cutter.cut_and_admit`, is not in this tree, and nothing in
# this tree calls the door except this file.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_GT,
    EXPR_BINARY_OP,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_TAG_COUNT,
    EXTRACT_YEAR,
    MATH2_POW,
    MATH_SQRT,
    STRFN_UPPER,
    STRFNN_CONCAT,
    STR_LIKE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    CORR_KIND_EXISTS,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import CorrelatedSubqueryData
# `CorrelatedSubqueryData(...)` is no longer directly constructible: it takes an
# already-boxed `ErasedBox`, and the ONE place a plan is boxed is
# `make_correlated_subquery_data`, which reads `inner_tag` and the box's type
# tag off the plan before consuming it so the two cannot disagree.
from komira_plan_expr.corr_subquery_data import make_correlated_subquery_data
from komira_physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_BATCH,
    SegmentDescPod,
    SourceSpecPod,
)
from komira_physical_plan.physical_plan_purity_gate import (
    assert_physical_plan_carries_no_logical_plan,
    expr_carries_correlated_subquery,
)


# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------
def _inner_plan() raises -> LogicalPlan:
    """A minimal subquery body. Its SHAPE is irrelevant — the gate refuses the
    presence of a plan under an expression, never anything about the plan."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), ArrowType.INT64, True))
    return LogicalPlan.scan(String("inner.parquet"), SOURCE_PARQUET, sb.build())


def _outer_refs() -> List[String]:
    var refs = List[String]()
    refs.append(String("outer_k"))
    return refs^


def _corr() raises -> Expr:
    """An `EXISTS (subquery)` expression — the cross-edge itself."""
    return Expr.correlated_subquery(
        _inner_plan(), _outer_refs(), CORR_KIND_EXISTS
    )


def _plain() raises -> Expr:
    """`a > 1` — an ordinary predicate carrying no plan."""
    return Expr.binary(
        BIN_GT,
        Expr.col_ref(String("a")),
        Expr.literal(ScalarValue.from_int64(1)),
    )


def _keys(name: String) -> List[String]:
    var k = List[String]()
    k.append(name)
    return k^


def _seg(
    seg_id: Int,
    var source_spec: SourceSpecPod,
    var ops: Slab[MorselOp],
) raises -> SegmentDescPod:
    return SegmentDescPod(
        seg_id=seg_id,
        source_kind=SOURCE_BATCH,
        source_spec=source_spec^,
        ops=ops^,
        sink_kind=SINK_COLLECT,
        sink_key_dtype=KEY_DTYPE_NONE,
        sink_orientation=SINK_ORIENT_COLUMNAR,
        sink_param_id=seg_id,
        sink_state_id=seg_id,
        deps=List[Int](),
        edge_tags=List[UInt8](),
    )


def _clean_seg(seg_id: Int) raises -> SegmentDescPod:
    """A segment with ONE ordinary filter op — a positive-control segment that
    still gives the walk something to inspect."""
    var ops = Slab[MorselOp]()
    ops.append(MorselOp.filter(_plain()))
    return _seg(seg_id, SourceSpecPod.batch(-1), ops^)


def _refusal_message(imm segs: List[SegmentDescPod]) -> String:
    """Call the door and RETURN what it refused with; empty string = accepted.
    Returning the message rather than a Bool is what lets each case assert the
    refusal is the one it meant to provoke — a door raising for some OTHER
    reason would otherwise read as a pass."""
    try:
        _ = assert_physical_plan_carries_no_logical_plan(segs)
    except e:
        return String(e)
    return String("")


def _walk(imm e: Expr) -> String:
    """`"T"` / `"F"` for the walker's answer, or the raised message. Collapsing
    all three outcomes into one return keeps a RAISE from being mistaken for a
    False by a test that only looked at a Bool."""
    try:
        if expr_carries_correlated_subquery(e):
            return String("T")
        return String("F")
    except err:
        return String(err)


# ===========================================================================
# THE EXPRESSION WALKER — exhaustiveness.
# ===========================================================================


def test_walker_has_an_arm_for_every_expr_tag() raises:
    """EVERY tag id in `[0, EXPR_TAG_COUNT)` must be ANSWERED, not raised on.

    A bare `Expr(tag)` carries no payload, so this exercises exactly the thing
    the claim is about: does an arm EXIST for the tag. A tag with no arm falls
    through to the `PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG` raise, which is
    the whole point — a hole in a safety check must be loud — and this test is
    what makes it loud AT DEVELOPMENT TIME instead of on a customer's plan.

    Goes red the moment `EXPR_TAG_COUNT` grows past 27 for a new tag in
    `expr.mojo` that has no arm here."""
    for t in range(EXPR_TAG_COUNT):
        var e = Expr(UInt8(t))
        var got = _walk(e)
        var expect = String("T") if UInt8(t) == EXPR_CORRELATED_SUBQUERY else String("F")
        assert_equal(
            got,
            expect,
            "tag "
            + String(t)
            + " must be answered '"
            + expect
            + "' by an arm, not raised on; got: "
            + got,
        )
        _ = e^


def test_walker_raises_on_a_tag_it_does_not_model() raises:
    """THE RAISE ARM IS LIVE. Without this the exhaustiveness test above could
    pass against a walk whose fallthrough silently returned False — i.e.
    against the fail-open shape this gate exists to replace.

    `EXPR_TAG_COUNT` is by construction one past the last real tag."""
    var e = Expr(UInt8(EXPR_TAG_COUNT))
    var got = _walk(e)
    assert_true(
        String("PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG") in got,
        "an unmodelled tag must RAISE by name, never answer False; got: " + got,
    )
    _ = e^


# ===========================================================================
# THE EXPRESSION WALKER — a subquery hidden under each container.
# ===========================================================================


def test_gate_finds_a_subquery_under_every_container_a_fail_open_walk_skips() raises:
    """`flatten_dependent_joins._expr_contains_correlated_subquery` models 9 of
    the 27 tags and returns False for the rest. Each case below hides the SAME
    `EXISTS (subquery)` under a container. The three `EXPR_WHEN` cases (the
    condition, the result, the default) are ones that walk also descends;
    every other case is under a container it does not descend, is False under
    that walk, and must be True here.

    This is the test that would have to be deleted, not merely adjusted, to
    reuse the fail-open walker as the gate."""
    # EXPR_WHEN — the condition. `CASE WHEN EXISTS (...) THEN 1 ELSE 0 END`.
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_corr(), Expr.literal(ScalarValue.from_int64(1))))
    assert_equal(
        _walk(Expr.when(cases^, Expr.literal(ScalarValue.from_int64(0)))), String("T"),
        "WHEN *condition* must be descended",
    )

    # EXPR_WHEN — the result. Same node, different slot; a walk that descended
    # only conditions would pass the case above and fail here.
    var cases2 = List[WhenCaseData]()
    cases2.append(WhenCaseData(_plain(), _corr()))
    assert_equal(
        _walk(Expr.when(cases2^, Expr.literal(ScalarValue.from_int64(0)))), String("T"),
        "WHEN *result* must be descended",
    )

    # EXPR_WHEN — the ELSE default.
    var cases3 = List[WhenCaseData]()
    cases3.append(WhenCaseData(_plain(), Expr.literal(ScalarValue.from_int64(1))))
    assert_equal(
        _walk(Expr.when(cases3^, _corr())), String("T"),
        "WHEN *default* must be descended",
    )

    # EXPR_SUBSTRING / EXPR_REGEXP / EXPR_EXTRACT — one-child containers the
    # fail-open walk has no arm for at all.
    assert_equal(
        _walk(Expr.substring(_corr(), 1, 2)), String("T"), "SUBSTRING child"
    )
    assert_equal(
        _walk(Expr.regexp_like(_corr(), String("^a"))), String("T"),
        "REGEXP child",
    )
    assert_equal(
        _walk(Expr.extract(EXTRACT_YEAR, _corr())), String("T"), "EXTRACT child"
    )

    # EXPR_MATH_FN2 — BOTH sides. Hidden on the RIGHT, which is what catches a
    # two-child arm that descends only the left.
    assert_equal(
        _walk(Expr.math_fn2(MATH2_POW, _plain(), _corr())), String("T"),
        "MATH_FN2 right",
    )

    # EXPR_MAP_GET — the KEY, not the parent. A Map key is itself an `Expr`.
    assert_equal(
        _walk(Expr.map_get(Expr.col_ref(String("m")), _corr())), String("T"),
        "MAP_GET key",
    )

    # EXPR_STRUCT_FIELD / EXPR_STRUCT_FIELD_IDX / EXPR_JSON_EXTRACT — the
    # nested-compute parents.
    assert_equal(
        _walk(Expr.struct_field(_corr(), String("f"))), String("T"),
        "STRUCT_FIELD parent",
    )
    assert_equal(
        _walk(Expr.struct_field_idx(_corr(), 0)), String("T"),
        "STRUCT_FIELD_IDX parent",
    )
    assert_equal(
        _walk(Expr.json_extract_json(_corr(), String("$.a"))), String("T"),
        "JSON_EXTRACT parent",
    )

    # EXPR_MATH_FN / EXPR_STRING_FN — the one-child scalar function families.
    assert_equal(
        _walk(Expr.math_fn(MATH_SQRT, _corr())), String("T"), "MATH_FN child"
    )
    assert_equal(
        _walk(Expr.string_fn(STRFN_UPPER, _corr())), String("T"),
        "STRING_FN child",
    )

    # EXPR_STRING_FN_N — hidden in the THIRD argument, which is what catches an
    # arm that reads a fixed number of arguments instead of looping over all.
    var concat_args = List[Expr]()
    concat_args.append(Expr.col_ref(String("a")))
    concat_args.append(Expr.col_ref(String("b")))
    concat_args.append(_corr())
    assert_equal(
        _walk(Expr.string_fn_n(STRFNN_CONCAT, concat_args^)), String("T"),
        "STRING_FN_N third argument",
    )

    # EXPR_UDF_CALL — the UDF's one argument. `affine((SELECT ...))`.
    assert_equal(
        _walk(
            Expr.udf_call(
                String("affine"),
                Optional[Int](7),
                ArrowType.INT64,
                ArrowType.INT64,
                _corr(),
            )
        ),
        String("T"),
        "UDF_CALL child",
    )

    # And one the fail-open walker DOES model, so the fixture is not selecting
    # only its blind spots: nested three deep under arms it has.
    assert_equal(
        _walk(
            Expr.alias(
                Expr.binary(BIN_GT, Expr.col_ref(String("a")), _corr()),
                String("k"),
            )
        ),
        String("T"),
        "ALIAS -> BINARY right -> subquery",
    )


def test_walker_finds_a_payload_whose_tag_was_rewritten() raises:
    """THE TAG AND THE PAYLOAD CAN DISAGREE, and the payload is what owns the
    plan. A pass that rewrites `tag` and forgets to clear `_corr_subq` leaves a
    node reading as an ordinary binary op while still holding a whole
    `LogicalPlan`. A gate that inspected only the tag is blind to it.

    Goes red if the per-node `if expr._corr_subq:` check is dropped in favour of
    a tag-only test."""
    var e = _plain()
    e._corr_subq = OwnedPointer(
        make_correlated_subquery_data[LogicalPlan](
            _inner_plan(), _outer_refs(), CORR_KIND_EXISTS
        )
    )
    assert_equal(Int(e.tag), Int(EXPR_BINARY_OP), "fixture keeps the wrong tag")
    assert_equal(
        _walk(e), String("T"),
        "a payload under a rewritten tag still owns a LogicalPlan",
    )
    _ = e^


def test_walker_says_no_to_an_ordinary_expression_tree() raises:
    """POSITIVE CONTROL for the walker. Without it, a walk that answered True
    unconditionally would satisfy every case above while refusing every
    query."""
    var deep = Expr.alias(
        Expr.substring(
            Expr.string_op(
                STR_LIKE,
                Expr.binary(BIN_GT, Expr.col_ref(String("a")), Expr.literal(ScalarValue.from_int64(1))),
                String("%x%"),
            ),
            1,
            3,
        ),
        String("k"),
    )
    assert_equal(
        _walk(deep), String("F"),
        "an ordinary tree must be ACCEPTED, not refused",
    )
    _ = deep^


# ===========================================================================
# THE DOOR — the four expression sites a `SegmentDescPod` reaches.
# ===========================================================================


def test_door_refuses_a_subquery_on_the_pushed_parquet_filter() raises:
    """SITE 1 of 4: `source_spec.parquet_filter`. This one is reached through
    the SOURCE, not through `ops`, so a walk that enumerated only the ops would
    be green here."""
    var segs = List[SegmentDescPod]()
    segs.append(
        _seg(
            0,
            SourceSpecPod.parquet(
                String("f.parquet"), None, Optional[Expr](_corr())
            ),
            Slab[MorselOp](),
        )
    )
    var msg = _refusal_message(segs)
    assert_false(msg == String(""), "a subquery on the pushed filter must be REFUSED")
    assert_true(
        String("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN") in msg,
        "the refusal must name PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN; got: " + msg,
    )
    assert_true(
        String("source_spec.parquet_filter") in msg,
        "the refusal must name the SITE; got: " + msg,
    )


def test_door_refuses_a_subquery_on_a_filter_op() raises:
    """SITE 2 of 4: `ops[i].filter_predicate`, which `MorselOp.filter` sets —
    the field a filter predicate is held in, so the one an undecorrelated
    `WHERE EXISTS (...)` would occupy."""
    var ops = Slab[MorselOp]()
    ops.append(MorselOp.filter(_corr()))
    var segs = List[SegmentDescPod]()
    segs.append(_seg(7, SourceSpecPod.batch(-1), ops^))
    var msg = _refusal_message(segs)
    assert_true(
        String("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN") in msg,
        "a subquery on a filter op must be refused; got: " + msg,
    )
    assert_true(
        String("ops[i].filter_predicate") in msg,
        "the refusal must name the SITE; got: " + msg,
    )
    assert_true(
        String("seg_id=7") in msg,
        "the refusal must name the SEGMENT; got: " + msg,
    )


def test_door_refuses_a_subquery_in_a_project_expr_array() raises:
    """SITE 3 of 4: `ops[i].project_exprs`, an `ExprArray`. The subquery is the
    SECOND element, so a walk that inspected `exprs[0]` and stopped — the same
    short-circuit the version door's own loop test guards against — is green
    here."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    exprs.append(_corr())
    var names = List[String]()
    names.append(String("a"))
    names.append(String("e"))
    var ops = Slab[MorselOp]()
    ops.append(MorselOp.project(exprs^, names^, False))
    var segs = List[SegmentDescPod]()
    segs.append(_seg(0, SourceSpecPod.batch(-1), ops^))
    var msg = _refusal_message(segs)
    assert_true(
        String("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN") in msg,
        "a subquery in a NON-FIRST project expr must be refused; got: " + msg,
    )
    assert_true(
        String("ops[i].project_exprs") in msg,
        "the refusal must name the SITE; got: " + msg,
    )


def test_door_refuses_a_subquery_in_a_probe_residual() raises:
    """SITE 4 of 4: `ops[i].probe_residual` — the non-equi join residual that
    `MorselOp.join_probe_with_residual` sets on the probe op."""
    var ops = Slab[MorselOp]()
    ops.append(
        MorselOp.join_probe_with_residual(
            1,
            _keys(String("l")),
            _keys(String("r")),
            0,
            _corr(),
            None,
        )
    )
    var segs = List[SegmentDescPod]()
    segs.append(_seg(0, SourceSpecPod.batch(-1), ops^))
    var msg = _refusal_message(segs)
    assert_true(
        String("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN") in msg,
        "a subquery in a probe residual must be refused; got: " + msg,
    )
    assert_true(
        String("ops[i].probe_residual") in msg,
        "the refusal must name the SITE; got: " + msg,
    )


def test_door_checks_every_segment_not_just_the_first() raises:
    """THE OUTER LOOP IS LOAD-BEARING. Segments 0 and 1 are clean; segment 2
    carries the subquery. A door that read `segments[0]` is green on this
    fixture and blind to a plan whose BUILD SIDE came from an optimizer that did
    not decorrelate — and the build side is exactly where a dim subtree's
    predicate lives."""
    var ops = Slab[MorselOp]()
    ops.append(MorselOp.filter(_corr()))
    var segs = List[SegmentDescPod]()
    segs.append(_clean_seg(0))
    segs.append(_clean_seg(1))
    segs.append(_seg(2, SourceSpecPod.batch(-1), ops^))
    var msg = _refusal_message(segs)
    assert_true(
        String("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN") in msg,
        "a subquery on a NON-FIRST segment must be refused; got: " + msg,
    )
    assert_true(
        String("seg_id=2") in msg,
        "the refusal must name the OFFENDING segment, not the first; got: " + msg,
    )


def test_door_refuses_an_empty_plan_rather_than_passing_it() raises:
    """AN EMPTY PLAN IS NOT CHECKABLE AND IS NOT A PASS — the version door's
    reason, restated here so this gate's non-vacuity does not depend on that
    door still being called first."""
    var segs = List[SegmentDescPod]()
    var msg = _refusal_message(segs)
    assert_true(
        String("PHYSICAL_PLAN_PURITY_UNCHECKABLE") in msg,
        "an empty plan must be a REFUSAL, not a vacuous pass; got: " + msg,
    )


def test_gate_accepts_an_ordinary_plan() raises:
    """THE POSITIVE CONTROL, and it asserts the SITE COUNT rather than merely
    the absence of a raise.

    A door that walked nothing would also "accept" this plan; the count is what
    distinguishes *checked, found nothing* from *checked nothing*. Three
    segments, SIX sites: two clean filter segments (1 each) + one carrying a
    pushed parquet filter (1), a project of 2 exprs (2) and a residual probe
    (1). ⚠ The count is deliberately spelled out per segment: an exact number
    catches an arithmetic error in the expectation itself as well as one in the
    gate, which is the argument for asserting a number rather than a Bool."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    exprs.append(_plain())
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var ops = Slab[MorselOp]()
    ops.append(MorselOp.project(exprs^, names^, False))
    ops.append(
        MorselOp.join_probe_with_residual(
            1,
            _keys(String("l")),
            _keys(String("r")),
            0,
            _plain(),
            None,
        )
    )
    var segs = List[SegmentDescPod]()
    segs.append(_clean_seg(0))
    segs.append(_clean_seg(1))
    segs.append(
        _seg(
            2,
            SourceSpecPod.parquet(
                String("f.parquet"), None, Optional[Expr](_plain())
            ),
            ops^,
        )
    )
    var sites = assert_physical_plan_carries_no_logical_plan(segs)
    assert_equal(
        sites, 6, "the door must inspect all SIX expression sites, not fewer"
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_walker_has_an_arm_for_every_expr_tag]()
    suite.test[test_walker_raises_on_a_tag_it_does_not_model]()
    suite.test[
        test_gate_finds_a_subquery_under_every_container_a_fail_open_walk_skips
    ]()
    suite.test[test_walker_finds_a_payload_whose_tag_was_rewritten]()
    suite.test[test_walker_says_no_to_an_ordinary_expression_tree]()
    suite.test[test_door_refuses_a_subquery_on_the_pushed_parquet_filter]()
    suite.test[test_door_refuses_a_subquery_on_a_filter_op]()
    suite.test[test_door_refuses_a_subquery_in_a_project_expr_array]()
    suite.test[test_door_refuses_a_subquery_in_a_probe_residual]()
    suite.test[test_door_checks_every_segment_not_just_the_first]()
    suite.test[test_door_refuses_an_empty_plan_rather_than_passing_it]()
    suite.test[test_gate_accepts_an_ordinary_plan]()
    suite^.run()
