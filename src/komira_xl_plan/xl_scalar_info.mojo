# =============================================================================
# xl_scalar_info.mojo — ★ THE `IS*` PREDICATES, `NA()` AND `XOR`.
# =============================================================================
#
# ⛔⛔ THE ERROR CLASS OF THIS WHOLE FAMILY IS `ERRH_MANUAL`, AND REGISTERING
# ANY OF IT AS `ERRH_PROPAGATE_DOMINANT` WOULD MAKE IT USELESS RATHER THAN
# WRONG-BY-A-LITTLE. `ISERROR(1/0)` must be TRUE; under dominance the error
# argument would propagate and the answer would be `#DIV/0!` — a function whose
# entire purpose is to LOOK at an error, returning the error. The kernels below
# therefore never call the shared `_num`/`_text` argument readers, which are
# built around dominance; each one INSPECTS `args[0]` directly, and that
# difference is the reason this is its own file rather than three more
# functions in the text one.
#
# ⚠ `ISBLANK` IS ABOUT THE **BLANK** MEMBER OF THE VALUE LATTICE, NOT ABOUT THE
# EMPTY STRING. `ISBLANK("")` is FALSE in Excel — an empty cell and a cell
# containing a zero-length string are different things, and `FormulaValue`
# carries `FV_BLANK` separately from `FV_TEXT` precisely so this function can
# tell them apart. A kernel that tested `byte_length() == 0` would answer TRUE
# for both and there is no test of the "" case that a caller would think to
# write.
#
# Encapsulation rule : values only.
# =============================================================================

from komira_core.plan.excel_error_code import (
    XL_ERR_CALC,
    XL_ERR_DIV0,
    XL_ERR_NA,
    XL_ERR_NAME,
    XL_ERR_NULL,
    XL_ERR_NUM,
    XL_ERR_REF,
    XL_ERR_SPILL,
    XL_ERR_VALUE,
)

from .formula_value import FormulaValue


# =============================================================================
# The IS* predicates — every one of them MANUAL on errors.
# =============================================================================
def xl_isblank(imm args: List[FormulaValue]) raises -> FormulaValue:
    """TRUE only for the BLANK member. `ISBLANK("")` is FALSE — see the header."""
    return FormulaValue.logical_val(args[0].is_blank())


def xl_isnumber(imm args: List[FormulaValue]) raises -> FormulaValue:
    """⚠ TYPE, NOT COERCIBILITY. `ISNUMBER("3")` is FALSE in Excel even though
    `"3"+2` is 5 — the implicit text-to-number coercion happens in an
    ARITHMETIC context and `ISNUMBER` is not one. A kernel that asked
    `coerce_number().is_error()` would answer TRUE and be wrong on the one
    input anybody tests."""
    return FormulaValue.logical_val(args[0].is_number())


def xl_istext(imm args: List[FormulaValue]) raises -> FormulaValue:
    return FormulaValue.logical_val(args[0].is_text())


def xl_islogical(imm args: List[FormulaValue]) raises -> FormulaValue:
    """⚠ TYPE AGAIN. `ISLOGICAL(1)` is FALSE even though 1 coerces to TRUE."""
    return FormulaValue.logical_val(args[0].is_logical())


def xl_iserror(imm args: List[FormulaValue]) raises -> FormulaValue:
    """TRUE for ANY error value, `#N/A` included. `ISERR` — every error EXCEPT
    `#N/A` — is a different function and is deliberately not registered here
    rather than being aliased onto this one."""
    return FormulaValue.logical_val(args[0].is_error())


def xl_isna(imm args: List[FormulaValue]) raises -> FormulaValue:
    """TRUE for `#N/A` ONLY. The code-filtered half of the pair above, and the
    same split `IFNA` makes against `IFERROR`."""
    return FormulaValue.logical_val(
        args[0].is_error() and args[0].error_code == XL_ERR_NA
    )


def xl_iserr(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ISERR` — TRUE for every error EXCEPT `#N/A`. The THIRD member of the
    error-predicate triple, and the one that was absent until 2026-09-04.

    ⛔ ITS ABSENCE WAS JUSTIFIED BY A SENTENCE THAT IS A SPECIFICATION, NOT A
    REASON. `xl_absent_common_names` said: *"ISERR — every error EXCEPT #N/A.
    Deliberately NOT aliased onto ISERROR, which includes it."* Every word of
    that is true, it is a complete statement of what `ISERR` computes, and it
    was doing duty as an argument for not computing it. The correct reading is
    the opposite one: `xl_isna` above already computes
    `is_error() and error_code == XL_ERR_NA`, so this is the same three lines
    with `==` changed to `!=`. Aliasing onto `ISERROR` would have been the
    wrong fix and refusing was not the only alternative.

    ⚠ THE TRIPLE PARTITIONS THE VALUE SPACE, and the partition is what a test
    has to assert: over `#N/A` it is (ISERROR TRUE, ISNA TRUE, ISERR FALSE);
    over `#DIV/0!` it is (TRUE, FALSE, TRUE); over a plain number all three are
    FALSE. A kernel that returned `is_error()` — i.e. an alias for `ISERROR` —
    passes any test that only feeds it `#DIV/0!` and a number."""
    return FormulaValue.logical_val(
        args[0].is_error() and args[0].error_code != XL_ERR_NA
    )


def xl_na(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NA()` — the literal `#N/A` value, which is how a sheet marks "no data
    here" so that an aggregate over the column visibly refuses rather than
    silently skipping it.

    ⚠ ZERO ARGUMENTS, and it still takes the `args` list, because every
    registry thunk has one signature. `args` is empty and unread."""
    return FormulaValue.error(XL_ERR_NA)


# =============================================================================
# XOR
# =============================================================================
def xl_xor(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`XOR(logical1, ...)` — TRUE when an ODD number of arguments are TRUE.

    ⚠ IT IS PARITY, NOT "EXACTLY ONE". `XOR(TRUE,TRUE,TRUE)` is TRUE in Excel.
    The two definitions agree for two arguments, which is the arity everyone
    tests, so "exactly one" survives a two-argument suite intact.

    ⚠ AND ITS ERROR CLASS IS DOMINANCE, NOT MANUAL — unlike the rest of this
    file. XOR does not inspect errors, it computes over logicals, so a
    leftmost-error argument propagates exactly as `AND`/`OR` do. Blanks are
    skipped for the same reason they are in `AND`/`OR`."""
    var odd = False
    for i in range(len(args)):
        if args[i].is_error():
            return args[i].copy()
        if args[i].is_blank():
            continue
        var lg = args[i].coerce_logical()
        if lg.is_error():
            return lg^
        if lg.logical:
            odd = not odd
    return FormulaValue.logical_val(odd)


# =============================================================================
# ★ CHOOSE — and it is `ERRH_MANUAL` for a reason that is NOT the IS* family's.
# =============================================================================
def xl_choose(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHOOSE(index_num, value1, [value2], ...)` — the 1-based selection.

    ⛔⛔ ITS ERROR CLASS IS `ERRH_MANUAL`, AND THE REASON IS DIFFERENT FROM
    EVERY OTHER MANUAL FUNCTION IN THIS FILE. The `IS*` family is MANUAL
    because it INSPECTS errors. `CHOOSE` is MANUAL because in Excel it does not
    EVALUATE the arms it does not select: `CHOOSE(1, 5, 1/0)` is **5**, not
    `#DIV/0!`. Under `ERRH_PROPAGATE_DOMINANT` the leftmost error argument wins
    before the kernel is ever called, and the answer would be `#DIV/0!` — a
    refusal where Excel returns a number.

    ⚠ THE DIVERGENCE THAT REMAINS, AND IT IS ABOUT COST RATHER THAN VALUE: this
    registry evaluates EVERY argument before dispatch, where Excel evaluates
    only the selected one. For pure functions the observable RESULT is
    identical, which is why `ERRH_MANUAL` closes the gap. It is not identical
    for a VOLATILE argument (`CHOOSE(1, 5, NOW())` recomputes `NOW` here), and
    it is not identical in WORK DONE.

    ⚠ `index_num` IS TRUNCATED, NOT ROUNDED: `CHOOSE(2.9, "a", "b", "c")` is
    "b". Out of `1..n` — including 0 and any negative — is `#VALUE!`, which is
    Excel's error for it. An ERROR index PROPAGATES, since the selection cannot
    be made."""
    if args[0].is_error():
        return args[0].copy()
    var idx = args[0].coerce_number()
    if idx.is_error():
        return idx^
    var t = idx.num
    var k = Int(t) if t >= 0.0 else -Int(-t)
    if k < 1 or k > len(args) - 1:
        return FormulaValue.error(XL_ERR_VALUE)
    return args[k].copy()


# =============================================================================
# ★★ THE 2026-09-14 INFORMATION TRANCHE — and the two LOGICAL CONSTANTS.
# =============================================================================

def xl_isnontext(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ISNONTEXT(value)` — TRUE for everything that is not TEXT.

    ⚠ IT IS THE EXACT NEGATION OF `ISTEXT`, INCLUDING OVER ERRORS, and that
    last clause is the whole reason it is `ERRH_MANUAL` and not a one-line
    `NOT(ISTEXT(x))` wrapper registered under dominance. `ISNONTEXT(#N/A)` is
    **TRUE** in Excel; a row registered `ERRH_PROPAGATE_DOMINANT` never reaches
    this kernel at all and answers `#N/A`, which is the family-wide trap this
    file's header describes.

    ⚠ A BLANK IS NON-TEXT (TRUE) and the empty STRING is TEXT (FALSE) — the
    same `FV_BLANK` / `FV_TEXT` distinction `ISBLANK` turns on."""
    return FormulaValue.logical_val(not args[0].is_text())


def xl_type(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TYPE(value)` — Excel's type CODE: 1 number, 2 text, 4 logical, 16 error.

    ⚠ THE CODES ARE NOT 1,2,3,4 — they are 1, 2, 4, 16, 64 (array) and 128
    (compound data), a bit-flag layout inherited from Excel 4 macro sheets. A
    kernel that returned a dense ordinal answers 3 where Excel says 4 and 4
    where Excel says 16, which is a plausible wrong number for every input.

    ⚠ A BLANK IS **1**, NOT A CODE OF ITS OWN. Excel has no `TYPE` code for an
    empty cell: it reads as the number 0. So `TYPE` cannot be used to find
    blanks and `ISBLANK` is not redundant with it.

    ⛔ `ERRH_MANUAL`, FOR THE FAMILY'S REASON: code 16 exists only if the
    kernel is allowed to SEE the error. Under dominance `TYPE(#N/A)` would be
    `#N/A` — a function whose job is to name the error returning the error.

    64 (array) and 128 (compound data) are unreachable from this door: the
    scalar carrier has no array member. Stated rather than mapped, because a
    branch that cannot be taken is a branch nothing tests."""
    if args[0].is_error():
        return FormulaValue.number(16.0)
    if args[0].is_text():
        return FormulaValue.number(2.0)
    if args[0].is_logical():
        return FormulaValue.number(4.0)
    return FormulaValue.number(1.0)


def xl_error_type(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ERROR.TYPE(value)` — the ORDINAL of an error value.

    1 `#NULL!` · 2 `#DIV/0!` · 3 `#VALUE!` · 4 `#REF!` · 5 `#NAME?` ·
    6 `#NUM!` · 7 `#N/A`.

    ⛔⛔ A NON-ERROR ARGUMENT IS `#N/A`, NOT 0 AND NOT `#VALUE!`. That is the
    one case a plausible implementation gets wrong, and getting it wrong is
    expensive rather than cosmetic: the whole IDIOM of this function is
    `IF(ISERROR(x), CHOOSE(ERROR.TYPE(x), ...), x)`, so a 0 returned for a
    healthy value indexes a `CHOOSE` out of range and a `#VALUE!` replaces the
    caller's real answer with a refusal.

    ⛔ `ERRH_MANUAL`, and here dominance would make the function a tautology:
    every argument it is ever CALLED with is an error, so under dominance it
    would return its own argument unchanged, 100% of the time, and look like it
    was working.

    ⚠ `#SPILL!` AND `#CALC!` MAP TO 9 AND 14, which is Microsoft's MODERN
    extension of the table (8 `#GETTING_DATA`, 9 `#SPILL!`, 10 `#CONNECT!`,
    11 `#BLOCKED!`, 12 `#UNKNOWN!`, 13 `#FIELD!`, 14 `#CALC!`). Neither is
    reachable from this door today — no dynamic-array evaluation exists here —
    so neither carries a graded value cell, and the two ordinals are written
    down rather than measured. The engine's internal `XL_ERR_CIRCULAR` is not
    an Excel error VALUE at all and is deliberately not given an ordinal: it
    falls through to the non-error `#N/A`."""
    if not args[0].is_error():
        return FormulaValue.error(XL_ERR_NA)
    var c = args[0].error_code
    if c == XL_ERR_NULL:
        return FormulaValue.number(1.0)
    if c == XL_ERR_DIV0:
        return FormulaValue.number(2.0)
    if c == XL_ERR_VALUE:
        return FormulaValue.number(3.0)
    if c == XL_ERR_REF:
        return FormulaValue.number(4.0)
    if c == XL_ERR_NAME:
        return FormulaValue.number(5.0)
    if c == XL_ERR_NUM:
        return FormulaValue.number(6.0)
    if c == XL_ERR_NA:
        return FormulaValue.number(7.0)
    if c == XL_ERR_SPILL:
        return FormulaValue.number(9.0)
    if c == XL_ERR_CALC:
        return FormulaValue.number(14.0)
    return FormulaValue.error(XL_ERR_NA)


# =============================================================================
# ★★ TRUE() AND FALSE() — THE TWO NAMES THAT NEEDED A PARSER CHANGE
# =============================================================================
#
# ⇒ the parser now tests for `(` FIRST and only falls back to the literal when
# there is none, which is what makes these two rows reachable at all. Bare
# `TRUE` keeps its literal path, so `IF(FALSE,1)` is untouched.
# =============================================================================
def xl_true(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TRUE()` — the logical constant. ⚠ Zero arguments, and it still takes
    the `args` list because every registry thunk has one signature; `args` is
    empty and unread, exactly as in `xl_na` above."""
    return FormulaValue.logical_val(True)


def xl_false(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FALSE()` — the logical constant. The other half of the pair; carried
    separately rather than as one kernel with a flag, because a flag is a place
    for the two to be swapped."""
    return FormulaValue.logical_val(False)
