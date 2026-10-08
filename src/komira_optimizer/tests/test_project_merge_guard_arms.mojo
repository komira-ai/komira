# =============================================================================
# test_project_merge_guard_arms.mojo -- every arm of the Project-merge
# substitution, its safety mirror, and the predicate-below-Project decision.
# =============================================================================
#
# `substitute_project_refs` rewrites an expression through an inner Project;
# `projects_merge_safely` / `expr_substitutes_safely` must answer True exactly
# when that rewrite leaves no reference to a column the inner Project computes;
# `predicate_below_project` decides what a FILTER means below a Project. Each
# test names the defect it catches: an arm that stops recursing, an arm that
# answers a constant, or a decision that pushes a predicate it must keep above.
#
# The inner Project used throughout is
#     [k, x * 2 AS v, y AS w]    (names k, v, w)
# so `k` passes through, `v` is computed, `w` is a rename of `y`. A rewritten
# expression must name x / y where the original named v / w, and must never
# still name v or w (render check on `ColRef(<name>)`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_COL_REF,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_WHEN,
    EXPR_SUBSTRING,
    EXPR_STRING_OP,
    EXPR_STRING_FN,
    EXPR_IN_LIST,
    EXPR_REGEXP,
    BIN_ADD,
    BIN_MUL,
    BIN_GT,
    UN_NEGATE,
    STR_LIKE,
    STRFN_UPPER,
    MATH2_POW,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray
from komira_optimizer.optimizer_project_merge_guard import (
    substitute_project_refs,
    expr_substitutes_safely,
    projects_merge_safely,
    predicate_below_project,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _lit(n: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(n)))


def _names() -> List[String]:
    var n = List[String]()
    n.append("k")
    n.append("v")
    n.append("w")
    return n^


def _inner() -> ExprArray:
    """[k, x * 2 AS v, y AS w]."""
    var e = ExprArray()
    e.append(Expr.col_ref("k"))
    e.append(Expr.alias(Expr.binary(BIN_MUL, Expr.col_ref("x"), _lit(2)), "v"))
    e.append(Expr.alias(Expr.col_ref("y"), "w"))
    return e^


def _render(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s


def _sub(var e: Expr) -> Expr:
    return substitute_project_refs(e^, _names(), _inner())


def _has(e: Expr, name: String) -> Bool:
    return _render(e).find("ColRef(" + name + ")") >= 0


def _regexp_on(name: String) -> Expr:
    """A node `substitute_project_refs` returns AS BUILT."""
    return Expr.regexp_like(Expr.col_ref(name), "^Z")


def _safe(e: Expr) -> Bool:
    return expr_substitutes_safely(e, _names(), _inner())


# -----------------------------------------------------------------------------
# substitute_project_refs: one test per arm
# -----------------------------------------------------------------------------


def test_substitute_col_ref_found_and_not_found() raises:
    # Defect: the ColRef arm returns the ref unchanged (no substitution), or
    # replaces an unknown name instead of leaving it.
    var v = _sub(Expr.col_ref("v"))
    assert_true(_has(v, "x"), "v must become the inner x * 2")
    assert_false(_has(v, "v"))
    var z = _sub(Expr.col_ref("z"))
    assert_equal(Int(z.tag), Int(EXPR_COL_REF))
    assert_true(_has(z, "z"), "a name the inner Project lacks stays as built")


def test_substitute_binary_unary_cast_alias_recurse() raises:
    # Defect: any of these four arms returns its input without recursing.
    var b = _sub(Expr.binary(BIN_ADD, Expr.col_ref("v"), Expr.col_ref("w")))
    assert_equal(Int(b.tag), Int(EXPR_BINARY_OP))
    assert_true(_has(b, "x") and _has(b, "y"))
    assert_false(_has(b, "v") or _has(b, "w"))
    var u = _sub(Expr.unary(UN_NEGATE, Expr.col_ref("w")))
    assert_equal(Int(u.tag), Int(EXPR_UNARY_OP))
    assert_true(_has(u, "y") and not _has(u, "w"))
    var c = _sub(Expr.cast(Expr.col_ref("w"), DType.float64))
    assert_equal(Int(c.tag), Int(EXPR_CAST))
    assert_true(_has(c, "y") and not _has(c, "w"))
    var a = _sub(Expr.alias(Expr.col_ref("w"), "out"))
    assert_equal(Int(a.tag), Int(EXPR_ALIAS))
    assert_equal(a.alias_name(), "out", "the outer alias name is kept")
    assert_true(_has(a, "y") and not _has(a, "w"))


def test_substitute_when_rewrites_condition_result_and_default() raises:
    # Defect: the CASE arm skips the condition, a result or the default.
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(1)), Expr.col_ref("w")
        )
    )
    var e = _sub(Expr.when(cases^, Expr.col_ref("v")))
    assert_equal(Int(e.tag), Int(EXPR_WHEN))
    assert_true(_has(e, "x") and _has(e, "y"))
    assert_false(_has(e, "v") or _has(e, "w"))


def test_substitute_math_fn_and_math_fn2() raises:
    # Defect: the MathFn arm does not replace its child, or the MathFn2 arm
    # replaces only one side.
    var m = _sub(Expr.sqrt(Expr.col_ref("w")))
    assert_equal(Int(m.tag), Int(EXPR_MATH_FN))
    assert_true(_has(m, "y") and not _has(m, "w"))
    var m2 = _sub(Expr.math_fn2(MATH2_POW, Expr.col_ref("w"), Expr.col_ref("v")))
    assert_equal(Int(m2.tag), Int(EXPR_MATH_FN2))
    assert_true(_has(m2, "y") and _has(m2, "x"))
    assert_false(_has(m2, "w") or _has(m2, "v"))


def test_substitute_substring_string_op_string_fn_in_list() raises:
    # Defect: one of the single-child payload arms leaves its child as built,
    # or drops its payload (pattern, start/length, values).
    var s = _sub(Expr.substring(Expr.col_ref("w"), 2, 3))
    assert_equal(Int(s.tag), Int(EXPR_SUBSTRING))
    assert_true(_has(s, "y") and not _has(s, "w"))
    assert_equal(s.substring_start(), 2, "start is kept")
    var so = _sub(Expr.string_op(STR_LIKE, Expr.col_ref("w"), "%a%"))
    assert_equal(Int(so.tag), Int(EXPR_STRING_OP))
    assert_true(_has(so, "y") and not _has(so, "w"))
    assert_true(_render(so).find("%a%") >= 0, "the pattern is kept")
    var sf = _sub(Expr.string_fn(STRFN_UPPER, Expr.col_ref("w")))
    assert_equal(Int(sf.tag), Int(EXPR_STRING_FN))
    assert_true(_has(sf, "y") and not _has(sf, "w"))
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int64(Int64(1)))
    vals.append(ScalarValue.from_int64(Int64(2)))
    var il = _sub(Expr.in_list_node(Expr.col_ref("w"), vals^))
    assert_equal(Int(il.tag), Int(EXPR_IN_LIST))
    assert_true(_has(il, "y") and not _has(il, "w"))


def test_substitute_returns_other_nodes_as_built() raises:
    # The documented contract: a node outside the list (here a regexp) is
    # returned AS BUILT, still naming the outer column. Defect: a change that
    # makes it recurse would silently invalidate `projects_merge_safely`.
    var r = _sub(_regexp_on("w"))
    assert_equal(Int(r.tag), Int(EXPR_REGEXP))
    assert_true(_has(r, "w"))


# -----------------------------------------------------------------------------
# expr_substitutes_safely / projects_merge_safely: the mirror, arm by arm
# -----------------------------------------------------------------------------


def test_safe_leaves_and_substituted_arms() raises:
    # Defect: the mirror answers False for a shape the substitution handles.
    assert_true(_safe(Expr.col_ref("v")))
    assert_true(_safe(_lit(3)))
    assert_true(_safe(Expr.binary(BIN_ADD, Expr.col_ref("v"), _lit(1))))
    assert_true(_safe(Expr.sqrt(Expr.col_ref("v"))))


def test_safe_as_built_node_over_pass_through_and_computed() raises:
    # The fallback: an AS-BUILT node is safe only when every name it reads
    # passes through. k passes (ColRef(k)); v is computed; w is a rename (the
    # inner expr is ColRef(y), not ColRef(w)); z is not in the inner Project.
    # Defect: fallback returns True (merges a dangling ref) or ignores names.
    assert_true(_safe(_regexp_on("k")))
    assert_false(_safe(_regexp_on("v")))
    assert_false(_safe(_regexp_on("w")))
    assert_false(_safe(_regexp_on("z")))


def test_safe_alias_pass_through_spelling() raises:
    # A front end may author Alias(ColRef(k), "k") for every kept column (the
    # python skins, which are not in this tree, do);
    # `_is_col_named` must see through alias layers that keep the name, and
    # must refuse one that renames. Defect: alias layers treated as computed,
    # or any alias treated as a pass-through.
    var names = List[String]()
    names.append("k")
    names.append("r")
    var inner = ExprArray()
    inner.append(Expr.alias(Expr.alias(Expr.col_ref("k"), "k"), "k"))
    inner.append(Expr.alias(Expr.col_ref("k"), "r"))
    assert_true(expr_substitutes_safely(_regexp_on("k"), names, inner))
    assert_false(expr_substitutes_safely(_regexp_on("r"), names, inner))


def test_safe_recurses_through_every_listed_arm() raises:
    # Each arm must recurse: wrapping an unsafe AS-BUILT node in it must stay
    # unsafe. Defect: an arm that answers True without looking at its child.
    assert_false(_safe(Expr.binary(BIN_ADD, _regexp_on("v"), _lit(1))))
    assert_false(_safe(Expr.binary(BIN_ADD, _lit(1), _regexp_on("v"))))
    assert_false(_safe(Expr.unary(UN_NEGATE, _regexp_on("v"))))
    assert_false(_safe(Expr.cast(_regexp_on("v"), DType.int64)))
    assert_false(_safe(Expr.alias(_regexp_on("v"), "q")))
    assert_false(_safe(Expr.sqrt(_regexp_on("v"))))
    assert_false(_safe(Expr.math_fn2(MATH2_POW, _regexp_on("v"), _lit(2))))
    assert_false(_safe(Expr.math_fn2(MATH2_POW, _lit(2), _regexp_on("v"))))
    assert_false(_safe(Expr.substring(_regexp_on("v"), 1, 1)))
    assert_false(_safe(Expr.string_op(STR_LIKE, _regexp_on("v"), "%")))
    assert_false(_safe(Expr.string_fn(STRFN_UPPER, _regexp_on("v"))))
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int64(Int64(1)))
    assert_false(_safe(Expr.in_list_node(_regexp_on("v"), vals^)))


def test_safe_when_checks_condition_result_and_default() raises:
    # Defect: the CASE arm checks only some of its parts.
    var c1 = List[WhenCaseData]()
    c1.append(WhenCaseData(_regexp_on("v"), _lit(1)))
    assert_false(_safe(Expr.when(c1^, _lit(0))), "unsafe condition")
    var c2 = List[WhenCaseData]()
    c2.append(WhenCaseData(_regexp_on("k"), _regexp_on("v")))
    assert_false(_safe(Expr.when(c2^, _lit(0))), "unsafe result")
    var c3 = List[WhenCaseData]()
    c3.append(WhenCaseData(_regexp_on("k"), _lit(1)))
    assert_false(_safe(Expr.when(c3^, _regexp_on("v"))), "unsafe default")
    var c4 = List[WhenCaseData]()
    c4.append(WhenCaseData(_regexp_on("k"), Expr.col_ref("v")))
    assert_true(_safe(Expr.when(c4^, _lit(0))), "every part safe")


def test_projects_merge_safely_needs_every_outer_expr() raises:
    # Defect: the loop returns after the first expression, or ignores it.
    var ok = ExprArray()
    ok.append(Expr.col_ref("v"))
    ok.append(_regexp_on("k"))
    assert_true(projects_merge_safely(ok, _names(), _inner()))
    var bad = ExprArray()
    bad.append(Expr.col_ref("v"))
    bad.append(_regexp_on("v"))
    assert_false(projects_merge_safely(bad, _names(), _inner()))
    assert_true(projects_merge_safely(ExprArray(), _names(), _inner()))


# -----------------------------------------------------------------------------
# predicate_below_project
# -----------------------------------------------------------------------------


def _gt(var e: Expr, n: Int) -> Expr:
    return Expr.binary(BIN_GT, e^, _lit(n))


def _below(pred: Expr) -> Optional[Expr]:
    return predicate_below_project(pred, _names(), _inner())


def test_below_pass_through_returns_the_predicate_itself() raises:
    # Defect: a pass-through predicate is rewritten or refused.
    var got = _below(_gt(Expr.col_ref("k"), 1))
    assert_true(Bool(got))
    assert_equal(_render(got.value()), _render(_gt(Expr.col_ref("k"), 1)))


def test_below_computed_row_local_is_substituted_without_alias() raises:
    # `v > 8` over `x * 2 AS v` becomes `x * 2 > 8`, with the alias stripped.
    # Defect: pushed raw (reads the child's own v), or the alias left inside
    # the comparison (no column below the Project carries that name).
    var got = _below(_gt(Expr.col_ref("v"), 8))
    assert_true(Bool(got))
    var r = _render(got.value())
    assert_true(r.find("ColRef(x)") >= 0, r)
    assert_false(r.find("ColRef(v)") >= 0, r)
    assert_false(r.find("Alias(") >= 0, "alias must be stripped: " + r)


def test_below_strips_nested_aliases() raises:
    # `(x + 1 AS t) AS v`: the alias loop must strip BOTH layers. Defect: an
    # `if` in place of the `while` leaves the inner alias.
    var names = List[String]()
    names.append("v")
    var inner = ExprArray()
    inner.append(
        Expr.alias(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("x"), _lit(1)), "t"), "v")
    )
    var got = predicate_below_project(_gt(Expr.col_ref("v"), 0), names, inner)
    assert_true(Bool(got))
    assert_false(_render(got.value()).find("Alias(") >= 0)


def test_below_rename_and_unary_and_literal_are_row_local() raises:
    # `_row_local` admits col / literal / unary / alias / binary. Defect: one
    # of those arms answers False and a safe push is lost.
    var names = List[String]()
    names.append("n")
    names.append("c")
    var inner = ExprArray()
    inner.append(Expr.alias(Expr.unary(UN_NEGATE, Expr.col_ref("x")), "n"))
    inner.append(Expr.alias(_lit(7), "c"))
    var pred = Expr.binary(BIN_GT, Expr.col_ref("n"), Expr.col_ref("c"))
    var got = predicate_below_project(pred, names, inner)
    assert_true(Bool(got))
    assert_true(_render(got.value()).find("ColRef(x)") >= 0)


def test_below_refuses_raising_and_non_row_local_exprs() raises:
    # sqrt / cast can RAISE on rows a guard below excluded; a binary with a
    # sqrt leg is no better. Defect: `_row_local` admits MathFn, Cast, or
    # checks only the top tag of a binary.
    var names = List[String]()
    names.append("s")
    names.append("c")
    names.append("b")
    var inner = ExprArray()
    inner.append(Expr.alias(Expr.sqrt(Expr.col_ref("x")), "s"))
    inner.append(Expr.alias(Expr.cast(Expr.col_ref("x"), DType.int32), "c"))
    inner.append(
        Expr.alias(Expr.binary(BIN_ADD, _lit(1), Expr.sqrt(Expr.col_ref("x"))), "b")
    )
    assert_false(Bool(predicate_below_project(_gt(Expr.col_ref("s"), 1), names, inner)))
    assert_false(Bool(predicate_below_project(_gt(Expr.col_ref("c"), 1), names, inner)))
    assert_false(Bool(predicate_below_project(_gt(Expr.col_ref("b"), 1), names, inner)))


def test_below_refuses_unknown_name_and_short_expr_list() raises:
    # A name the Project does not output, and a name list longer than the
    # expression list. Defect: an unknown name is treated as a pass-through,
    # or the index check is dropped (an out-of-range read).
    assert_false(Bool(_below(_gt(Expr.col_ref("zz"), 1))))
    var names = _names()
    names.append("extra")
    var got = predicate_below_project(_gt(Expr.col_ref("extra"), 1), names, _inner())
    assert_false(Bool(got))


def test_below_refuses_when_substitution_would_leave_a_computed_ref() raises:
    # `v` is row-local, but a regexp over it is returned AS BUILT by the
    # substitution, so the pushed predicate would read the child's own v.
    # Defect: the `expr_substitutes_safely` check is skipped.
    assert_false(Bool(_below(_regexp_on("v"))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
