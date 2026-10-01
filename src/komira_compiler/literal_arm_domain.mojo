# =============================================================================
# ★★ EVAL_INCOMPARABLE_LITERAL — THE EXECUTOR'S OWN ANSWER TO "IS THERE AN ARM
#    FOR THIS (COLUMN TYPE, LITERAL) PAIR?"
# =============================================================================
#
# ⛔ THE DEFECT THIS EXISTS FOR IS A SILENT WRONG ANSWER, NOT A MISSING FEATURE.
# Over a 210-row `lineitem` fixture:
#
#     SELECT count(l_orderkey) AS c FROM t WHERE l_shipmode > 5   ->  {'c': [210]}
#
# and 210 is EXACTLY the table's row count. That reads like a DROPPED
# predicate. It is not dropped — it is EVALUATED, against the WRONG VALUE.
# `_eval_predicate`'s STRING arm reads `lit.string_val`, and a `ScalarValue`
# built by `from_int(5)` carries `string_val == ""`, so the engine ran
# `l_shipmode > ''` — true for every non-empty string, i.e. every row. The same
# read is what makes `l_shipmode < 5` answer ZERO rows rather than refusing.
#
# ⚠ THE FAILURE MODE IS THE FAMILY'S, NOT THIS ONE ARM'S. Every arm in the
# comparison ladder and in the IN-list kernel selects a FIELD of `ScalarValue`
# from the COLUMN's type alone, and every unpopulated field of a `ScalarValue`
# reads as a well-formed zero (`0`, `0.0`, `""`, `False`) rather than as an
# error. So "the literal is of the wrong kind" and "the literal is 0 / empty /
# false" are the same bytes to every one of them.
#
# ★ WHY THE FIX IS HERE AND NOT AT A DOOR. `komira_plan_wire.plan_wire_values.
# _refuse_if_incomparable` ALREADY refuses this pair with
# `PLAN_WIRE_INCOMPARABLE_LITERAL`, and its own header calls itself "A MIRROR of
# `compiler_eval_predicate`'s ARM SET". That door covers the plan-wire ingress
# (`komira_plan_stream`) and it is why the DataFrame spellings of this probe —
# `P31_string_vs_number` / `P32_number_vs_string` — are graded CLEAR-ERROR.
# P31b reaches the engine through `komira_sql_stream`, a DIFFERENT ingress,
# where no such walk runs. Adding a second door-side copy would make the tree
# hold a mirror of a mirror; making the EXECUTOR refuse makes the existing
# mirror TRUE and covers every ingress at once — SQL, plan-wire, a
# spreadsheet front end, and a direct Mojo caller.
#
# ⚠ THE REFUSAL TOKEN IS DELIBERATELY *NOT* `PLAN_WIRE_INCOMPARABLE_LITERAL`.
# A test that asserted on the door's wording would still pass with this check
# deleted, because the door refuses the same pair in nearly the same words on
# the OTHER ingress. `EVAL_INCOMPARABLE_LITERAL` is reachable only from here,
# so an assertion on it is an assertion about THIS gate.
#
# =============================== THE ORACLE ==================================
#
# DuckDB v1.5.3, measured:
#
#   VARCHAR > 5      Binder Error: Cannot compare values of type VARCHAR and
#                    type INTEGER_LITERAL - an explicit cast is required
#   VARCHAR > 5.5    Binder Error: ... VARCHAR and type DECIMAL(2,1) ...
#   VARCHAR > true   Binder Error: ... VARCHAR and type BOOLEAN ...
#   VARCHAR = 5      Conversion Error: Could not convert string 'AIR' to INT32
#   INTEGER > 'x'    Conversion Error: Could not convert string 'x' to INT32
#   DOUBLE  > 'x'    Conversion Error: Could not convert string "x" to DECIMAL
#
# Every one of them is an ERROR. ⛔ SO **REFUSE** IS THE CHOSEN OUTCOME AND
# **COERCE** IS NOT. DuckDB does cast a string literal that happens to parse
# (`INTEGER > '2'` answers), so a refusal is narrower than DuckDB on exactly
# that one shape — and that shape is a WRONG ANSWER today (`i > '2'` evaluates
# `i > 0`), so refusing it is strictly an improvement. Inventing a coercion
# this engine does not have elsewhere would be a semantics DuckDB only
# partially shares; the opponent is latest DuckDB and the rule is "slower OK,
# wrong not".
#
# ============================ WHAT IS *NOT* JUDGED ===========================
#
# * A NULL literal. `col OP NULL` is NULL for every row under 3VL and both
#   callers have a dedicated all-false arm for it. Judging it by TYPE would refuse a
#   shape that is expressible and correct.
# * A column type with no arm at all (LIST, STRUCT, BINARY, ...). The caller's
#   own `else: raise` owns that message; saying it twice, differently, would
#   make the envelope limit look like a type error.
# * A TEMPORAL column against an INTEGER literal, which IS admitted — a DATE32
#   column is physically int32 days-since-epoch and
#   `temporal_literal_value._temporal_literal_i64` has an explicit `is_int`
#   branch for it. See `plan_wire_values._temporal_column_reads_int_literal`,
#   which carries the measurement that made the door stop refusing it.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.scalar_value import ScalarValue


def literal_is_readable_by_column(
    col_at: ArrowType, lit: ScalarValue, numeric_dict: Bool
) -> Bool:
    """Does an executor arm selected by `col_at` read a field `lit` populates?

    ⚠ THIS IS A STATEMENT ABOUT WHICH **FIELD** THE ARM READS, not about Arrow's
    type taxonomy. Each branch below names the arm it mirrors.

    Args:
        col_at: The column's Arrow type, as the arm ladder sees it.
        lit: The literal the arm is about to read a field out of.
        numeric_dict: `Column.is_numeric_dict` — a DICTIONARY column is a
            TEXT arm or a NUMBER arm depending on it, and the Arrow type alone
            cannot say which.

    Returns:
        False only when the pair is KNOWN to have no arm. Unknown pairs answer
        True, because "I did not judge this" must not become "this is bad".
    """
    # A typed NULL has its own arm in both callers; see the header.
    if lit.is_null():
        return True

    # TEXT arms — `_eval_predicate`'s STRING / LARGE_STRING / string-DICTIONARY
    # branches and `_eval_in_list_string` / `_eval_in_list_dictionary`. All of
    # them read `lit.string_val`.
    if (
        col_at == ArrowType.STRING
        or col_at == ArrowType.LARGE_STRING
        or (col_at == ArrowType.DICTIONARY and not numeric_dict)
    ):
        return lit.is_string()

    # TEMPORAL arms — `_eval_temporal_col_vs_literal` and the physical int
    # IN-list kernels, both of which read through `_temporal_literal_i64` /
    # `_comparable_literal_i64`: date32 -> `date32_val`, timestamp ->
    # `ts_micros`, int / time / duration -> `int_val`.
    if (
        col_at == ArrowType.DATE32
        or col_at == ArrowType.DATE64
        or col_at.is_timestamp()
        or col_at.is_time()
        or col_at.is_duration()
    ):
        return (
            lit.is_int()
            or lit.is_date32()
            or lit.is_timestamp()
            or lit.is_time()
            or lit.is_duration()
        )

    # DECIMAL arms — `_eval_decimal_col_vs_literal` scale-aligns an INT or a
    # FLOAT literal as well as a DECIMAL one, so a decimal COLUMN accepts a
    # number. (The converse does not hold; see the NUMBER arm below.)
    if col_at == ArrowType.DECIMAL128 or col_at == ArrowType.DECIMAL256:
        return (
            lit.is_any_integer()
            or lit.is_float()
            or lit.is_decimal128()
            or lit.is_decimal256()
        )

    # BOOL arms — `_eval_in_list_bool` reads `lit.bool_val`. (The comparison
    # ladder has no BOOL arm at all and raises its own envelope message.)
    if col_at == ArrowType.BOOL:
        return lit.is_bool()

    # NUMBER arms — every branch that reads `int_val` or `float_val`, plus the
    # INT<->FLOAT promotion between them and the numeric-dictionary LUT. A
    # date32 / timestamp literal is admitted because `_eval_predicate` routes
    # THAT pair to the temporal helper before the numeric arms are reached.
    if col_at.is_numeric() or (col_at == ArrowType.DICTIONARY and numeric_dict):
        return (
            lit.is_any_integer()
            or lit.is_float()
            or lit.is_date32()
            or lit.is_timestamp()
        )

    # Everything else: not judged here. See the header.
    return True


def refuse_incomparable_literal(
    col_at: ArrowType, lit: ScalarValue, where: String
) raises:
    """Raise the `EVAL_INCOMPARABLE_LITERAL` refusal for a pair with no arm.

    ⚠ THE TOKEN IS LOAD-BEARING AND IS NOT THE DOOR'S. See the header: a test
    asserting on `PLAN_WIRE_INCOMPARABLE_LITERAL` would pass with this check
    replaced by `if False`, because the plan-wire door refuses the same pair on
    a different ingress in nearly the same words.
    """
    raise Error(
        "EVAL_INCOMPARABLE_LITERAL: "
        + where
        + " compares a column of Arrow type "
        + String(col_at)
        + " against the literal "
        + String(lit)
        + ", and this engine has no comparison kernel that reads a literal of"
        " that kind at that column type. ⚠ REFUSED RATHER THAN ANSWERED: the"
        " arm is selected by the COLUMN's type and reads the `ScalarValue`"
        " field that type stores its values in, so a literal carrying its"
        " value in a different field is read as that field's ZERO —"
        " `shipmode > 5` becomes `shipmode > \"\"`, which is TRUE for every"
        " non-empty string, and `id > TRUE` becomes `id > 0`. ★ SEND A LITERAL"
        " OF THE COLUMN'S OWN TYPE. ⛔ A CAST ON THE **LITERAL** SIDE IS NOT A"
        " GENERAL WAY OUT: `id > CAST(<a date or decimal literal> AS INT64)`"
        " returns the same wrong rows, because"
        " `broadcast_scalar` has no arm for those kinds and turns the literal"
        " into an INT64 zero BEFORE the cast is applied; those spellings are"
        " refused in their own right by"
        " `plan_wire_values._literal_is_materializable`. A BOOL literal cast"
        " (`id > CAST(TRUE AS INT64)`) is refused one layer down by"
        " `compiler_eval_column`'s EXPR_CAST ladder instead. Still fail-closed."
        " ⚠ Some frontends DEFINE parts of this (DuckDB casts a string"
        " literal that happens to parse) — this engine does not have that"
        " conversion, which is why it says so instead of guessing."
    )


def check_literal_against_column(
    col_at: ArrowType, lit: ScalarValue, numeric_dict: Bool, where: String
) raises:
    """`refuse_incomparable_literal` iff `literal_is_readable_by_column` says no.
    """
    if not literal_is_readable_by_column(col_at, lit, numeric_dict):
        refuse_incomparable_literal(col_at, lit, where)
