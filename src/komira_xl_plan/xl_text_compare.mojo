# =============================================================================
# xl_text_compare.mojo — ★ EXCEL COMPARES TEXT CASE-INSENSITIVELY. SQL DOES
#                          NOT. THIS FILE IS THE ONE PLACE THAT SAYS SO.
# =============================================================================
#
# `"acme" = "ACME"` is TRUE in a spreadsheet and FALSE in SQL:2016, in DuckDB
# and in this engine's `BIN_EQ`. Both are correct for their own surface, and
# the difference is not a rounding error: it selects a DIFFERENT SET OF ROWS,
# silently, and returns a number the caller acts on.
#
# ⇒ SO THE FIX BELONGS AT THE EXCEL FRONTEND'S LOWERING AND NOWHERE ELSE.
#   Putting a case-fold in `BIN_EQ`, in the string compare kernels, or in the
#   predicate evaluator would fix Excel by breaking SQL — the larger surface,
#   which is currently RIGHT. `komira_xl_plan` is where an Excel formula stops
#   being Excel and becomes an engine plan; a semantics difference between two
#   frontends has to be spent HERE, in the lowering, or it is spent in the
#   shared engine where it does not belong.
#
# ================== ⭐ WHAT THE LOWERING IS, IN ONE LINE ====================
#
#     Excel   `status = "acme"`
#     plan    `lower(col("status")) = 'acme'`
#
# The COLUMN is folded by the engine's own `STRFN_LOWER` kernel and the
# OPERAND is folded HERE, so the two sides meet already folded and the
# comparison that runs is the ordinary byte-exact one. Nothing about `BIN_EQ`
# changes; what changes is what it is handed.
#
# ⚠ AND THE LITERAL SIDE IS NOT OPTIONAL — FOLDING ONLY THE COLUMN MOVES THE
# DEFECT RATHER THAN FIXING IT. `lower(status) = 'ACME'` matches nothing at
# all, which is a NEW wrong answer (0 where the old code at least found the
# exact-case rows). Both sides fold or neither does.
#
# ⚠ IT RIDES A SHAPE THE PREDICATE EVALUATOR ALREADY SERVES, and that is
# measured rather than assumed: `compiler_eval_predicate._eval_predicate`'s
# COMPUTED-LHS arm names `upper(name) = 'ACME'` BY NAME as the shape it gained
# on 2026-09-02, and dispatches all six comparison ops to the `column OP
# scalar` string kernels. ⛔ THE RHS MUST STAY A LITERAL: the same arm routes a
# non-literal RHS into `_eval_col_vs_col_promoted`, which REFUSES a string pair
# by name. So `lower(col) = lower('ACME')` — the spelling that would let ONE
# kernel fold both sides — does not execute, and that is why the operand is
# folded in Mojo here instead.
#
# ============ ⭐ THE OPERAND IS FOLDED BY THE COLUMN'S OWN KERNEL ===========
# ============    (2026-09-11 — this used to be an ASCII REFUSAL)  ===========
#
# `excel_text_lower` calls `komira_core.eval.unicode_case.unicode_lower_bytes`,
# which is the SAME function `komira_compiler/compiler_eval_column.mojo`'s
# `STRFN_LOWER` arm calls once per row of the column. So the two sides of the
# comparison are folded by ONE definition and cannot disagree — not "are kept
# in sync", which is a property nobody can check on a diff.
#
# ⚠ WHAT THIS REPLACED, AND WHY THE OLD CODE WAS RIGHT FOR ITS TIME. The
# operand fold here was ASCII (`A`-`Z` -> `a`-`z`) while the column's had been
# the Unicode simple case mapping since 2026-09-09. On a pure-ASCII operand the
# two are BYTE-IDENTICAL (`simple_lower_cp` opens with the ASCII branch), so
# that lowering was fully Unicode-correct there. On a NON-ASCII one they are
# not, and the mismatch loses rows silently: `lower('CAFÉ')` is `'café'` on the
# column side where an ASCII fold of the operand leaves `'cafÉ'`, which matches
# NOTHING — including the row it matched before the fold landed. So a non-ASCII
# operand was REFUSED, which was the correct failure mode (*a refusal is a
# `#NAME?`-shaped `NO_PLAN`; a wrong count is a number someone acts on*) and
# still a narrowing of reach that the fold itself had introduced.
#
# ================= WHAT IS **NOT** IN SCOPE, AND WHY ========================
#
# ⛔ A NUMERIC OPERAND NEVER TOUCHES ANY OF THIS. `COUNTIF(qty, "25")` means
# the NUMBER 25 (`rel_condagg_build._operand_literal` records Excel's rule),
# and `lower()` over an INT64 column is a type error the engine would raise.
# The discriminator is the LITERAL's own type, asked with `is_string()`, never
# the formula's spelling.
#
# ⛔ WILDCARDS ARE STILL REFUSED UPSTREAM. Excel's `"a*"` is a pattern; this
# file compares, it does not match. The refusal stays where it is.
#
# Encapsulation rule : values only. No `UnsafePointer` in any
# signature, no wildcard origins, no `unsafe_from_address`.
# =============================================================================

from komira_core.plan.expr import Expr
from komira_core.plan.scalar_value import ScalarValue
# ★ THE ENGINE'S OWN CASE MAPPING, AND THE IMPORT IS THE WHOLE FIX. This is the
# function `compiler_eval_column`'s `STRFN_LOWER` arm applies to the COLUMN; the
# OPERAND going through the same one is what makes a two-sided fold trustworthy.
# It lives in `komira_core` (not `komira_compiler`) precisely so this package
# can reach it — see the header.
from komira_core.eval.unicode_case import unicode_lower_bytes


def excel_text_lower(s: String) -> String:
    """`s` folded by the SIMPLE Unicode case mapping — byte-for-byte the fold
    the engine's `STRFN_LOWER` applies to the COLUMN side of this comparison.

    ⛔ IT DELEGATES, AND THE DELEGATION IS THE POINT. `unicode_lower_bytes` is
    the function `compiler_eval_column.mojo` calls per row; anything else here —
    an ASCII loop, a copied table, a "close enough" widening — is a SECOND
    implementation of one semantics, and two implementations of a comparison's
    two sides drift into a wrong ROW SET that nothing downstream can detect.
    `test_the_operand_fold_is_the_ENGINES_OWN_mapping_not_a_second_copy` asserts
    the identity directly rather than against hand-written expected strings.

    ⚠ THE BYTES ARE REASSEMBLED WITHOUT RE-ENCODING. `unicode_lower_bytes`
    returns `List[UInt8]` precisely so a caller cannot route them through a
    codepoint constructor and double-encode everything >= 0x80 (this tree's
    standing corruption trap, written up on `_hex_string_bytes`). Building the
    `String` from the byte span is the non-re-encoding path.

    ⚠ OUTPUT LENGTH IS NOT INPUT LENGTH — `lower` can shrink a sequence (`İ`
    U+0130 is two bytes and maps to one) — so nothing here may size a buffer
    from the input.
    """
    var out = unicode_lower_bytes(s)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def excel_comparison(
    op: UInt8, column: String, var lit: ScalarValue
) raises -> Optional[Expr]:
    """★ THE ONE LOWERING OF AN EXCEL `<column> <op> <literal>` COMPARISON.

        text     `status = "AcMe"`  ->  `lower(col("status")) = 'acme'`
        numeric  `qty    > 25`      ->  `col("qty") > 25`

    ⚠ IT IS ONE FUNCTION WITH TWO CALLERS BECAUSE EXCEL HAS ONE ANSWER.
    `rel_filter_build.build_filter_predicate` parses a BINOP node
    (`FILTER(ord, status="acme")`) and `rel_condagg_build.
    build_criteria_predicate` parses an operator INSIDE A STRING
    (`COUNTIF(status, "acme")`) — two grammars, and the divergence they were
    written against is the SAME one. Two copies of this fold would be free to
    drift, and the drift would be a wrong ROW SET that no schema check can see.

    ⚠ THE FOLD IS APPLIED FOR EVERY COMPARISON OP, NOT ONLY `=`. Excel's text
    comparison is case-insensitive for `<` `<=` `>` `>=` and `<>` as well, and
    a fold on the equality arm alone leaves `"<>acme"` selecting a LARGER row
    set than the correct answer — the direction an assertion on the `=` arm
    cannot see.

    ⚠ IT NO LONGER RETURNS None FOR ANY TEXT OPERAND. Until 2026-09-11 a
    NON-ASCII operand was refused, because the fold here was ASCII and the
    column's was Unicode; both sides now go through `unicode_lower_bytes`, so
    there is no operand this package can fold out of agreement with the kernel.
    The `Optional` return is kept — the two callers already handle a decline and
    a future envelope edge (a LOCALE-sensitive comparison, say) would need it
    back — but nothing reaches it today.
    """
    if lit.is_string():
        var text = lit.string_val.copy()
        # ⚠ NO ASCII GATE ANY MORE (2026-09-11). There used to be an
        # `excel_text_operand_is_ascii` refusal here, because the fold below was
        # ASCII and the column's was Unicode — two mappings that agree only on
        # ASCII. There is now ONE mapping, so every operand folds and the
        # refusal has nothing left to protect. Re-adding a narrowing gate here
        # would refuse a comparison this package can now answer correctly.
        return Optional[Expr](
            Expr.binary(
                op,
                Expr.lower(Expr.col_ref(column)),
                Expr.literal(ScalarValue.from_string(excel_text_lower(text))),
            )
        )
    return Optional[Expr](
        Expr.binary(op, Expr.col_ref(column), Expr.literal(lit^))
    )
