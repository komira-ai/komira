# =============================================================================
# test_string_fn_n_kernels — `EXPR_STRING_FN_N` EXECUTED, cell for cell against
# DuckDB v1.5.3
# =============================================================================
#
# Seven ops — concat / concat_ws / replace /
# lpad / rpad / repeat / strpos — driven through `_eval_column_expr`, the
# projection-context DATA ladder, over a fixture chosen so that a wrong kernel
# cannot be green.
#
# ⭐ WHY THIS EXISTS AT ALL: without it, `EXPR_STRING_FN` has NO Mojo test that
# executes it — only the end-to-end plan matrix, and a kernel family whose only
# instrument is a whole-system matrix is an untested kernel family.
#
# ⛔ EVERY EXPECTED VALUE BELOW WAS MEASURED, not reasoned. They came out of
# DuckDB v1.5.3 over these exact seven rows, in one query, and were
# transcribed. Do not "correct" one by reading the kernel.
#
# ⛔⛔ AND NO EXPECTATION IS A PYTHON/MOJO STDLIB EQUIVALENT. Three of the
# obvious ones are WRONG against DuckDB:
#   * a `replace` with an EMPTY needle inserts at every position in Python and
#     matches NOTHING in DuckDB;
#   * `ljust`/`rjust`-shaped padding takes ONE fill character and never
#     truncates, where `lpad` CYCLES a multi-character pad AND truncates;
#   * a `str.upper`-shaped case fold is a Unicode mapping this engine
#     deliberately is not.
#
# ── THE FIXTURE, AND WHY EACH ROW IS THERE ──────────────────────────────────
#
#   0  "  Ab  "  leading AND trailing spaces, mixed case, 6 chars
#   1  "cD "     trailing only, 3 chars — pads by exactly ONE character, which
#                is where a pad that does not cycle still looks right
#   2  " ef"     leading only, 3 chars, and the only row whose `e` is at a
#                position a byte scan and a character scan agree on
#   3  ""        THE EMPTY STRING — pads by FOUR, which is the only row that
#                makes a multi-character pad CYCLE (`xyxy`)
#   4  "  "      whitespace only: `replace(' ','_')` maps it to `__`, so a
#                kernel that skipped blank rows is visible
#   5  "Straße"  ⛔ THE ROW THE WHOLE FIXTURE IS FOR. Its `e` is CHARACTER 6
#                and BYTE 7, so `strpos` = 6 separates a character-position
#                kernel from a byte-offset one; and `lpad(v,4,·)` truncating
#                to `Stra` is a CHARACTER operation that a byte-wise version
#                gets wrong (and can split `ß`)
#   6  NULL      the three DIFFERENT null rules, on one row
#
# ── THE THREE NULL RULES, WHICH ARE THE MOST EXPENSIVE THING TO GUESS ───────
#
#   concat      SKIPS nulls and NEVER returns one: row 6 is `"-"`, not NULL
#   concat_ws   NULL SEPARATOR -> NULL row; NULL VALUE skipped WITH its
#               separator: row 6 is `"z"`, not `"|z"`
#   the rest    any null in -> null out
#
# A kernel that hoisted a single "any argument null -> null" pre-pass over the
# family would be green on rows 0-5 and wrong on row 6, in two directions.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.schema import (
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_core.io.heap_region import HeapRegion
from komira_core.helpers.compiler_helpers import field_for_expr
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.expr import (
    Expr,
    STRFN_UPPER,
    STRFN_TRIM,
    STRFNN_CONCAT,
    STRFNN_CONCAT_WS,
    STRFNN_REPLACE,
    STRFNN_TRANSLATE,
    STRFNN_LPAD,
    STRFNN_RPAD,
    STRFNN_REPEAT,
    STRFNN_STRPOS,
    string_fn_n_arity_ok,
)
from komira_compiler.compiler_eval_column import _eval_column_expr


comptime N_ROWS: Int = 7


def _batch() raises -> RecordBatch:
    """`v` = the seven rows above; row 6 is NULL.

    ⚠ THE NULL ROW STORES `""` AS ITS VALUE, which is deliberate and is what
    makes the test able to fail: if a kernel read the value instead of the
    validity bit it would answer as if the row were the empty string — and row
    3 IS the empty string, with a DIFFERENT expected answer for every one of
    the seven ops. The two rows can therefore never be confused silently.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.STRING, True))

    var vals = List[String]()
    vals.append(String("  Ab  "))
    vals.append(String("cD "))
    vals.append(String(" ef"))
    vals.append(String(""))
    vals.append(String("  "))
    vals.append(String("Straße"))
    vals.append(String(""))

    var valid = List[Bool]()
    for i in range(N_ROWS):
        valid.append(i != 6)

    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    return rb.build(sb.build())


def _v() -> Expr:
    return Expr.col_ref(String("v"))


def _lit(s: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(s))


def _int(n: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(n)))


def _node(op: UInt8, var args: List[Expr]) -> Expr:
    return Expr.string_fn_n(op, args^)


def _assert_strings(
    label: String, var e: Expr, expect: List[String], null_at: Int
) raises:
    """Evaluate `e` and compare EVERY row, plus the declared output TYPE.

    ⭐ THE TYPE IS CHECKED BESIDE THE DATA ON PURPOSE. `MapOp.execute` pairs
    `_eval_column_expr` (this data) with `walk_expr_field` (this type), and a
    tag the DATA ladder can evaluate while the TYPE ladder answers `null`
    produces a batch whose values are RIGHT and whose schema is unexportable —
    `UnsupportedArrowCABIType: Arrow type 'null' (export)`. Asserting the
    value alone cannot see it.

    `null_at` is the single row expected NULL, or -1 for "no row is NULL".
    """
    var batch = _batch()
    var fld = field_for_expr(e, batch.schema)
    assert_equal(
        fld.arrow_type,
        ArrowType.STRING,
        label + ": declared output type must be STRING, not `null`",
    )
    var col = _eval_column_expr(e, batch)
    assert_equal(
        col.arrow_type, ArrowType.STRING, label + ": column type"
    )
    var sa = col.as_string()
    for i in range(N_ROWS):
        if i == null_at:
            assert_true(sa.is_null(i), label + ": row " + String(i) + " NULL")
        else:
            assert_true(
                not sa.is_null(i),
                label + ": row " + String(i) + " must NOT be null",
            )
            assert_equal(
                sa.get(i), expect[i], label + " @row " + String(i)
            )


def _assert_int64(
    label: String, var e: Expr, expect: List[Int], null_at: Int
) raises:
    var batch = _batch()
    var fld = field_for_expr(e, batch.schema)
    assert_equal(
        fld.arrow_type,
        ArrowType.INT64,
        label + ": declared output type must be INT64 — this family's type is"
        + " PER-OP and a site switching on the TAG would say STRING here",
    )
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.INT64, label + ": column type")
    var pa = col.as_primitive[DType.int64]()
    for i in range(N_ROWS):
        if i == null_at:
            assert_true(pa.is_null(i), label + ": row " + String(i) + " NULL")
        else:
            assert_equal(
                Int(pa.get(i)), expect[i], label + " @row " + String(i)
            )


# ---------------------------------------------------------------------------
# concat — the NULL-SKIPPING member, and the only one that never returns NULL.
# ---------------------------------------------------------------------------

def test_concat_three_args_skips_nulls() raises:
    """`concat(v, '-', v)`. MEASURED on DuckDB v1.5.3, all seven rows.

    ⛔ ROW 6 IS `"-"`, NOT NULL. Both `v` operands are NULL and contribute
    nothing; the literal survives and the row stays VALID. That single cell is
    the whole difference between `concat` and SQL `||`, and it is the cell a
    kernel copied from the `replace` arm gets wrong.

    THREE arguments, not two, with a literal in the MIDDLE: two is the arity a
    fixed-arity kernel happens to get right, and a middle literal makes an
    operand-reordering bug read as `"--vv"` rather than as something
    plausible."""
    var args = List[Expr]()
    args.append(_v())
    args.append(_lit(String("-")))
    args.append(_v())
    var expect: List[String] = [
        String("  Ab  -  Ab  "),
        String("cD -cD "),
        String(" ef- ef"),
        String("-"),
        String("  -  "),
        String("Straße-Straße"),
        String("-"),
    ]
    _assert_strings(
        String("concat(v,'-',v)"), _node(STRFNN_CONCAT, args^), expect, -1
    )


def test_concat_ws_skips_the_value_and_its_separator() raises:
    """`concat_ws('|', v, 'z')`. MEASURED.

    ⛔ ROW 6 IS `"z"`, NOT `"|z"`. The separator is emitted BETWEEN SURVIVING
    values, so a NULL value takes its separator with it — an implementation
    that joins first and strips nulls afterwards answers `"|z"` and is green on
    every other row.

    ⚠ ROW 3 IS `"|z"` AND THAT IS CORRECT. The EMPTY STRING is a value, not an
    absence, so it is emitted and its separator with it. Rows 3 and 6 are the
    pair; either alone proves nothing."""
    var args = List[Expr]()
    args.append(_lit(String("|")))
    args.append(_v())
    args.append(_lit(String("z")))
    var expect: List[String] = [
        String("  Ab  |z"),
        String("cD |z"),
        String(" ef|z"),
        String("|z"),
        String("  |z"),
        String("Straße|z"),
        String("z"),
    ]
    _assert_strings(
        String("concat_ws('|',v,'z')"),
        _node(STRFNN_CONCAT_WS, args^),
        expect,
        -1,
    )


def test_replace_propagates_null_and_maps_every_space() raises:
    """`replace(v, ' ', '_')`. MEASURED. Row 6 IS NULL — the ordinary rule,
    and the contrast with the two tests above is the point.

    Row 4 (`"  "`) becomes `"__"`, so a kernel that short-circuited on a
    whitespace-only or a no-alphanumeric row is visible. Row 5 is unchanged
    because `Straße` has no space — which also asserts that the byte-wise
    search did not match inside `ß`'s two bytes."""
    var args = List[Expr]()
    args.append(_v())
    args.append(_lit(String(" ")))
    args.append(_lit(String("_")))
    var expect: List[String] = [
        String("__Ab__"),
        String("cD_"),
        String("_ef"),
        String(""),
        String("__"),
        String("Straße"),
        String(""),
    ]
    _assert_strings(
        String("replace(v,' ','_')"), _node(STRFNN_REPLACE, args^), expect, 6
    )


def test_translate_is_CHARACTER_based_unlike_every_other_member() raises:
    """`translate(v, 'aß S', 'AZs')`.

    ⛔⛔ THE ARGUMENTS ARE NOT ARBITRARY AND AN OBVIOUS CHOICE DOES NOT WORK.
    `translate` is the ONLY CHARACTER-based member of this tag — `replace`
    above is byte-wise and substring-wise, and `levenshtein`, `damerau` and
    `hamming` below are all byte-based — so the defect to catch is a kernel
    written by analogy with its neighbours. MEASURED by compiling exactly that
    kernel and running it: with `from = 'aSß '` (the first ordering tried) the
    byte-wise and character-wise implementations return the SAME STRING ON
    EVERY ROW OF THIS FIXTURE, because the byte split runs out of `to`
    partners at the same place the character split does.

    THE ORDERING BELOW puts the SPACE inside the `to` range and leaves `S`
    hanging off the end — `from` is four CHARACTERS and FIVE BYTES against a
    three-character `to` — and then FIVE OF THE SIX rows separate the two:

        row          character (correct)   byte-wise (the defect)
        "  Ab  "     ssAbss                Ab
        "cD "        cDs                   cD
        " ef"        sef                   ef
        "  "         ss                    (empty)
        "Straße"     trAZe                 trAZse

    ⛔ ROW 5 ALSO CARRIES THE DELETION RULE: `S` has no partner in `to`, so it
    is DROPPED rather than padded or passed through, and `Straße` loses its
    leading capital. MEASURED on DuckDB v1.5.3:
    `translate('abcd','abc','xy')` = 'xyd'.

    ⚠ A byte-wise kernel would also emit `ß`'s lead byte replaced and its
    continuation byte stranded — INVALID UTF-8 out of valid input, which is
    worse than a wrong answer because the consumer cannot decode it.

    Row 6 is NULL: any null argument nulls the row, the same rule `replace`
    has.
    """
    var args = List[Expr]()
    args.append(_v())
    args.append(_lit(String("aß S")))
    args.append(_lit(String("AZs")))
    var expect: List[String] = [
        String("ssAbss"),
        String("cDs"),
        String("sef"),
        String(""),
        String("ss"),
        String("trAZe"),
        String(""),
    ]
    _assert_strings(
        String("translate(v,'aß S','AZs')"),
        _node(STRFNN_TRANSLATE, args^),
        expect,
        6,
    )


def test_lpad_truncates_cycles_and_counts_characters() raises:
    """`lpad(v, 4, 'xy')`. MEASURED, and it exercises all three branches.

    ⛔ ROW 5 IS `"Stra"`. `lpad` TRUNCATES when the target is shorter than the
    input, and it truncates to the first four CHARACTERS. A byte-wise version
    of the same rule on `Straße` still yields `Stra` here — so the discriminating
    cell for characters-vs-bytes is `strpos` below, and what THIS row proves is
    that truncation happens at all.

    ⛔ ROW 3 IS `"xyxy"` AND IT IS THE ONLY ROW THAT CYCLES THE PAD. The empty
    string needs four pad characters from a two-character pad; every other row
    needs one or zero, where a pad that repeats only its FIRST character is
    indistinguishable from a correct one."""
    var args = List[Expr]()
    args.append(_v())
    args.append(_int(4))
    args.append(_lit(String("xy")))
    var expect: List[String] = [
        String("  Ab"),
        String("xcD "),
        String("x ef"),
        String("xyxy"),
        String("xy  "),
        String("Stra"),
        String(""),
    ]
    _assert_strings(
        String("lpad(v,4,'xy')"), _node(STRFNN_LPAD, args^), expect, 6
    )


def test_rpad_pads_the_other_end_and_truncates_the_same_end() raises:
    """`rpad(v, 4, 'xy')`. MEASURED.

    ★ THE ASYMMETRY IS THE ASSERTION. `rpad` pads on the RIGHT (row 1 is
    `"cD x"` where `lpad` gave `"xcD "`) but TRUNCATES FROM THE SAME END as
    `lpad` — row 5 is `"Stra"` for BOTH, not `"raße"`. A reader who assumed
    `rpad` keeps the LAST n characters writes `"aße"`-shaped expectations and
    is wrong against DuckDB."""
    var args = List[Expr]()
    args.append(_v())
    args.append(_int(4))
    args.append(_lit(String("xy")))
    var expect: List[String] = [
        String("  Ab"),
        String("cD x"),
        String(" efx"),
        String("xyxy"),
        String("  xy"),
        String("Stra"),
        String(""),
    ]
    _assert_strings(
        String("rpad(v,4,'xy')"), _node(STRFNN_RPAD, args^), expect, 6
    )


def test_repeat_three_times() raises:
    """`repeat(v, 3)`. MEASURED. Row 3 is `""` (repeating nothing is nothing)
    and row 6 is NULL.

    Three rather than two: at two, a kernel that emitted the input twice
    whatever the count would be green."""
    var args = List[Expr]()
    args.append(_v())
    args.append(_int(3))
    var expect: List[String] = [
        String("  Ab    Ab    Ab  "),
        String("cD cD cD "),
        String(" ef ef ef"),
        String(""),
        String("      "),
        String("StraßeStraßeStraße"),
        String(""),
    ]
    _assert_strings(
        String("repeat(v,3)"), _node(STRFNN_REPEAT, args^), expect, 6
    )


def test_strpos_is_a_character_position_not_a_byte_offset() raises:
    """★★ `strpos(v, 'e')`. THE CELL THE WHOLE FIXTURE EXISTS FOR.

    ⛔ ROW 5 IS **6**, AND A BYTE SCAN ANSWERS 7. `Straße` is S-t-r-a-ß-e:
    six characters, seven bytes, because `ß` is two. MEASURED on DuckDB
    v1.5.3: 6. Every other row in this fixture answers the same for both
    kernels, and the default six-single-ASCII-letter corpus cannot distinguish
    them at all — this is the one cell that can.

    ⛔ AND `0` MEANS NOT FOUND, NOT "position 0": rows 0, 1, 3 and 4 have no
    `e`. `strpos` is 1-BASED, so 0 is unambiguous — a 0-based kernel would
    answer 1 for row 2 and 5 for row 5 and be plausible on both.

    ⚠ THIS IS ALSO THE PER-OP OUTPUT TYPE ASSERTION. `strpos` is the ONLY
    INT64-returning member of the family; `_assert_int64` checks the DECLARED
    field type as well as the data, so a site that switched on the TAG rather
    than the OP declares STRING here and reds."""
    var args = List[Expr]()
    args.append(_v())
    args.append(_lit(String("e")))
    var expect: List[Int] = [0, 0, 2, 0, 0, 6, 0]
    _assert_int64(
        String("strpos(v,'e')"), _node(STRFNN_STRPOS, args^), expect, 6
    )


def test_a_nested_variadic_over_the_unary_family_composes() raises:
    """`concat(upper(v), trim(v))` — the two string families NESTED, with a
    DIFFERENT function in each argument slot.

    ⚠ THE TWO ARGUMENTS MUST DIFFER. `concat(upper(v), upper(v))` evaluates
    cleanly through an arm that computed `args[0]` twice; `upper` beside `trim`
    cannot, and over this fixture they disagree on every row that has both a
    lower-case letter and a space.

    ⭐ ROW 5 IS NOW DuckDB'S ANSWER ON BOTH HALVES. It used to be the engine's:
    the ASCII-only `upper` left `ß` alone and answered `STRAßE` where DuckDB
    answers `STRAẞE`, and this docstring said so and told readers not to cite
    the test as parity for `upper`. `unicode_case.mojo` closed that on
    so `upper` is exact here too and the caveat is gone.
    """
    var args = List[Expr]()
    args.append(Expr.string_fn(STRFN_UPPER, _v()))
    args.append(Expr.string_fn(STRFN_TRIM, _v()))
    var expect: List[String] = [
        String("  AB  Ab"),
        String("CD cD"),
        String(" EFef"),
        String(""),
        String("  "),
        String("STRAẞEStraße"),
        String(""),
    ]
    _assert_strings(
        String("concat(upper(v),trim(v))"),
        _node(STRFNN_CONCAT, args^),
        expect,
        -1,
    )


def test_a_wrong_arity_node_is_REFUSED_BY_NAME_not_evaluated() raises:
    """⛔ THE FAIL-CLOSED HALF. A `replace` carrying two arguments is a node
    the binder and the wire decoder both refuse; the evaluator refuses it too,
    and that third refusal is what makes a node ANY producer mis-builds loud
    rather than silently two-thirds evaluated.

    The arity table is asserted here as well as the raise, because a raise
    whose condition is written at the call site is a fourth opinion about how
    many arguments `replace` takes."""
    assert_true(
        not string_fn_n_arity_ok(STRFNN_REPLACE, 2),
        "replace/2 must not satisfy the arity table",
    )
    assert_true(
        string_fn_n_arity_ok(STRFNN_CONCAT, 1),
        "concat is VARIADIC with a floor of 1 — a single argument is legal,"
        + " and a table that refused it would make `concat(x)` unreachable",
    )
    var args = List[Expr]()
    args.append(_v())
    args.append(_lit(String(" ")))
    var bad = _node(STRFNN_REPLACE, args^)
    var batch = _batch()
    var raised = False
    var msg = String("")
    try:
        var _c = _eval_column_expr(bad, batch)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a 2-argument `replace` must RAISE, not evaluate")
    assert_true(
        String("replace") in msg,
        "the refusal must NAME the function, not just the op number; got: "
        + msg,
    )


def main() raises:
    # ⛔ AUTO-DISCOVERY, NOT A HAND-WRITTEN ROSTER. The previous form
    # enumerated each test with `suite.test[...]`, and two
    # NEWLY ADDED value tests were left off that roster: they compiled,
    # they type-checked, the gate went GREEN, and their assertions never
    # ran. `assert_true(False)` as their first statement was measured
    # GREEN through this gate. A roster that must be edited in a second
    # place is a roster that will be forgotten; `__functions_in_module`
    # cannot be.
    TestSuite.discover_tests[__functions_in_module()]().run()
