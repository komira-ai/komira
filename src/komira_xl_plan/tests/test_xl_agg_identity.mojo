# =============================================================================
# test_xl_agg_identity.mojo — ★ A SPREADSHEET AGGREGATE OVER NOTHING IS **0**,
#                               AND OVER **TEXT** IT IS ALSO 0.
# =============================================================================
#
#     COUNT(<6 text cells>)          door 6      sql 6      sheet 0
#     SUMIF(g, "zzz", qty)           door None   sql None   sheet 0
#     SUM(<all-blank range>)         door None   sql None   sheet 0
#
# ⚠ THE ORACLES ARE ASSEMBLED FROM `komira_core`, never read back from the
# builder and never by calling `xl_agg_identity` itself. `String(built) ==
# String(built)` is green through any mutation, and an oracle that called the
# function under test would be exactly that.
#
# ⛔ NO `EngineContext`, NO FILE, NO FIXTURE ON DISK — this file is welded to
# `komira_xl_plan`, which downstream bindings link, so it is an
# INPUT to every package that links it
# gate. A slow or flaky member here blocks the shared library at random.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.plan.col_expr import col
from komira_core.plan.expr import (
    Expr,
    BIN_EQ,
    BIN_GT,
    UN_IS_NULL,
    WhenCaseData,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
)
from komira_core.plan.agg_expr import (
    sum as agg_sum,
    count as agg_count,
    mean as agg_mean,
    min as agg_min,
    max as agg_max,
)
from komira_core.source.parquet_source import ParquetSource
from komira_core.source.source_variant import SourceVariant

from komira_xl_plan.bound_relation import BoundRelation, NamedTable
from komira_xl_plan.formula_bindings import FormulaBindings
from komira_xl_plan.xl_agg_identity import (
    excel_bound_column_arrow_type,
    excel_cond_value_range_is_text,
    excel_range_has_no_numeric_cells,
    excel_range_is_text,
    excel_reads_numeric_cells_only,
)
from komira_xl_plan.xl_fn_table import (
    XLA_COUNT,
    XLA_COUNT_NONBLANK,
    XLA_MAX,
    XLA_MEAN,
    XLA_MEDIAN,
    XLA_MIN,
    XLA_SUM,
)
from komira_xl_plan.xl_plan_build import build_xl_plan


# =============================================================================
# THE FIXTURE — one column per decision this file's two envelopes turn on.
# =============================================================================
#
# ⭐ EVERY COLUMN IS HERE BECAUSE A DIFFERENT ARM READS IT, and a fixture of
# int64 columns alone would certify a wrap that is wrong for four of them:
#
#   qty      INT64       the ordinary numeric range; `sum` stays INT64
#   price    FLOAT64     `sum` stays FLOAT64 — the literal `0` must FOLLOW the
#                        aggregate's output type or the CASE overlay RAISES
#   small    INT32       `sum` PROMOTES to INT64, so a literal typed from the
#                        INPUT column would disagree with the aggregate itself
#   status   STRING      TEXT: no numeric cells at all
#   day      DATE32      NOT text and NOT `is_numeric()` — an Excel date IS a
#                        number, so this is the column that catches a text rule
#                        written as `not at.is_numeric()`
#   money    DECIMAL128  numeric, and OUTSIDE the CASE overlay's Int64/Float64
#                        envelope — the column that must stay UNWRAPPED
#   flag     BOOL        LOGICAL: no numeric cells to SUM/COUNT/MIN/MAX, twelve
#                        non-blank ones to COUNTA, and — for SUMIFS — a sum
#                        range whose TRUEs Microsoft says "evaluate to 1"
#
# ⚠ THE PATH NEED NOT EXIST AND IS NEVER READ — this file builds plans and
# never executes one. It is a FUNCTION rather than a module-level constant
# because a module-scope assignment is a file-scope EXPRESSION, which Mojo
# rejects outright ("expressions must not appear at file scope"), and
# `comptime` wants a compile-time value which a `String` is not. The package's
# other two plan tests spell it the same way.


def _path() -> String:
    return String("/nonexistent/door.parquet")


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("qty", ArrowType.INT64, False))
    sb.add_field(Field("price", ArrowType.FLOAT64, False))
    sb.add_field(Field("small", ArrowType.INT32, False))
    sb.add_field(Field("status", ArrowType.STRING, False))
    sb.add_field(Field("day", ArrowType.DATE32, False))
    sb.add_field(Field.decimal128("money", 12, 2, False))
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    return sb.build()


def _source() raises -> SourceVariant:
    return SourceVariant(ParquetSource(_path(), _schema()))


def _named(column: String) raises -> BoundRelation:
    return BoundRelation(
        NamedTable(String("door"), _schema(), _source()), column
    )


def _bindings() raises -> FormulaBindings:
    var b = FormulaBindings()
    b.bind_relation(String("qty"), _named(String("qty")))
    b.bind_relation(String("price"), _named(String("price")))
    b.bind_relation(String("small"), _named(String("small")))
    b.bind_relation(String("status"), _named(String("status")))
    b.bind_relation(String("day"), _named(String("day")))
    b.bind_relation(String("money"), _named(String("money")))
    b.bind_relation(String("flag"), _named(String("flag")))
    b.bind_relation(String("door"), _named(String("")))
    return b^


def _leaf() raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(_source(), _schema())


def _filtered_leaf() raises -> LogicalPlan:
    """`FILTER(qty > 25) <- SCAN` — the chain the conditional aggregates build.
    The literal is a FLOAT because `_operand_literal` coerces a numeric-looking
    criteria with `Float64(operand)`."""
    return LogicalPlan.filter(
        Expr.binary(
            BIN_GT,
            Expr.col_ref(String("qty")),
            Expr.literal(ScalarValue.from_float(25.0)),
        ),
        _leaf(),
    )


# =============================================================================
# THE TWO ORACLES — hand-assembled, `komira_core` only
# =============================================================================


def _oracle_zero_when_empty(
    var agg: LogicalPlan, name: String, float_typed: Bool
) raises -> String:
    """`PROJECT([CASE WHEN <name> IS NULL THEN 0 ELSE <name> END AS <name>]) <- agg`.

    ⚠ `float_typed` IS A PARAMETER AND NOT DERIVED, so a caller has to STATE
    which zero it expects. The whole claim of the FLOAT64 cell is that the
    literal follows the AGGREGATE's output type; an oracle that read that type
    off the plan would agree with the builder by construction."""
    var zero: ScalarValue
    if float_typed:
        zero = ScalarValue.from_float(0.0)
    else:
        zero = ScalarValue.from_int(0)
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.unary(UN_IS_NULL, Expr.col_ref(name)), Expr.literal(zero^)
        )
    )
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.when(cases^, Expr.col_ref(name)), name))
    return String(LogicalPlan.project(exprs^, agg^))


def _oracle_zero_cell(var child: LogicalPlan, name: String) raises -> String:
    """`PROJECT([0 AS <name>]) <- AGGREGATE([], [count(*)]) <- child`."""
    var aggs = AggExprArray()
    aggs.append(agg_count())
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.literal(ScalarValue.from_int(0)), name))
    return String(
        LogicalPlan.project(
            exprs^, LogicalPlan.aggregate(ExprArray(), aggs^, child^)
        )
    )


def _built(formula: String) raises -> String:
    var b = build_xl_plan(formula, _bindings())
    assert_true(
        b.is_built(),
        formula + " must build a plan; detail: " + b.detail(),
    )
    return String(b.take_plan())


# =============================================================================
# ARM (b) — AN EMPTY NUMERIC RANGE IS 0, NOT NULL
# =============================================================================


def test_SUM_over_an_int_range_carries_the_sheets_zero_identity() raises:
    """★ THE CENTRAL CLAIM OF ARM (b). `SUM(qty)` is no longer a bare
    aggregate: a 0-key `sum` is NULL exactly when it had no non-null input, and
    a sheet answers 0 there, so the lowering rewrites that one case and passes
    every other answer through untouched (`ELSE <a>`).

    ⚠ MEASURED SHEET DIVERGENCE, 2026-09-11: `SUM(<all-blank range>)` came back
    `None` through `komira_xl_stream` where a spreadsheet says 0."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col(String("qty"))))
    assert_equal(
        _built(String("SUM(qty)")),
        _oracle_zero_when_empty(
            LogicalPlan.aggregate(ExprArray(), aggs^, _leaf()),
            String("sum"),
            False,
        ),
        "SUM(qty) must be PROJECT(CASE WHEN sum IS NULL THEN 0 ELSE sum) over"
        " AGGREGATE(SUM(qty)) over SCAN, token for token",
    )


def test_the_zero_literal_FOLLOWS_the_aggregates_output_type_not_the_column()  raises:
    """⭐⭐ THE CELL THAT SEPARATES A CORRECT WRAP FROM ONE THAT RAISES AT RUN
    TIME, and it needs BOTH halves to say anything.

    `_run_case_overlay` requires every THEN arm to agree with the CASE's output
    type and RAISES on a mismatch — it does not decline. So the literal `0` has
    to carry the AGGREGATE's output type:

      * `SUM(price)`  FLOAT64 in, FLOAT64 out -> the zero must be `0.0`;
      * `SUM(small)`  INT32   in, **INT64** out (`_infer_agg_field` promotes
        the small integers to the accumulator width) -> the zero must be an
        INT64 `0`, i.e. NOT the input column's type.

    The second is the one that discriminates: a wrap that typed its literal
    from the COLUMN passes the first cell and fails this one."""
    var a_price = AggExprArray()
    a_price.append(agg_sum(col(String("price"))))
    assert_equal(
        _built(String("SUM(price)")),
        _oracle_zero_when_empty(
            LogicalPlan.aggregate(ExprArray(), a_price^, _leaf()),
            String("sum"),
            True,
        ),
        "SUM over a FLOAT64 column must carry a FLOAT64 zero",
    )

    var a_small = AggExprArray()
    a_small.append(agg_sum(col(String("small"))))
    assert_equal(
        _built(String("SUM(small)")),
        _oracle_zero_when_empty(
            LogicalPlan.aggregate(ExprArray(), a_small^, _leaf()),
            String("sum"),
            False,
        ),
        "SUM over an INT32 column promotes to INT64, so the zero is an INT64"
        " zero — the type comes from the AGGREGATE and not from the column",
    )


def test_the_CASE_is_asserted_STRUCTURALLY_because_the_render_hides_it() raises:
    """⛔⛔ THE RENDER CANNOT SEE THIS CELL'S SUBJECT, AND THAT IS WHY THE CELL
    EXISTS. `Expr.write_to`'s EXPR_WHEN arm prints the four characters
    `When(...)` and descends into NOTHING — so every CASE in this engine
    renders identically, and a `String(plan)` comparison cannot tell

        CASE WHEN sum IS NULL THEN 0   ELSE sum END      (correct)
        CASE WHEN sum IS NULL THEN 0.0 ELSE sum END      (RAISES at run time)
        CASE WHEN qty IS NULL THEN 0   ELSE sum END      (wrong column)

    apart. Every other cell in this file is a render comparison and is
    therefore BLIND to the CASE's internals; this one reads the `Expr` TREE.

    ⚠ THE LITERAL'S TYPE IS THE WHOLE HAZARD. `_run_case_overlay` requires the
    THEN arms to agree with the CASE's output type and RAISES on a mismatch —
    it does not decline — so a wrap whose zero was typed from the INPUT column
    would blow up at run time on every INT32 and FLOAT32 column, and on nothing
    in a render-only test suite."""
    # ⚠ THREE PARALLEL LISTS, NOT A LIST OF TUPLES — the house style in
    # `test_xl_condagg_build.mojo`'s operator sweep, and for the same reason:
    # tuple destructuring in a `for` header is not a shape this package's other
    # test files use, and a test file is the wrong place to find out.
    var formulas: List[String] = [
        String("SUM(qty)"),
        String("SUM(price)"),
        String("SUM(small)"),
        String("MIN(qty)"),
    ]
    var want_ats: List[ArrowType] = [
        ArrowType.INT64,
        ArrowType.FLOAT64,
        ArrowType.INT64,
        ArrowType.INT64,
    ]
    var want_names: List[String] = [
        String("sum"), String("sum"), String("sum"), String("min"),
    ]
    for ci in range(len(formulas)):
        var formula = formulas[ci].copy()
        var want_at = want_ats[ci]
        var want_name = want_names[ci].copy()
        var b = build_xl_plan(formula, _bindings())
        assert_true(b.is_built(), formula + " must build: " + b.detail())
        var plan = b.take_plan()

        # (1) the PROJECT's declared output type is the aggregate's own, which
        #     is what `_infer_expr_field` reads off the FIRST `THEN` clause —
        #     i.e. off the literal. A wrongly typed zero shows up HERE.
        assert_equal(
            Int(plan.output_schema.field_arrow_type(0).type_id),
            Int(want_at.type_id),
            formula
            + ": the identity projection's output arrow type must be the"
            " AGGREGATE's output type. `_infer_expr_field` types a CASE from"
            " its first THEN, so a mismatch here IS a wrongly typed zero",
        )
        assert_equal(
            plan.output_schema.field_name(0),
            want_name,
            formula + ": the wrap must keep the aggregate's output NAME",
        )

        # (2) the tree itself: Project([Alias(When([<col> IS NULL -> <lit 0>],
        #     default=<col>), <name>)]).
        ref pd = plan.project_data_ref()
        assert_equal(len(pd.exprs), 1, formula + ": one projected expr")
        ref aliased = pd.exprs[0]
        assert_true(aliased.is_alias(), formula + ": the expr is an Alias")
        assert_equal(aliased.alias_name(), want_name)
        ref when = aliased.alias_child_ref()
        assert_equal(
            when.when_num_cases(), 1, formula + ": exactly one WHEN arm"
        )
        ref cond = when.when_case_condition_ref(0)
        assert_equal(
            Int(cond.unary_op()),
            Int(UN_IS_NULL),
            formula + ": the condition must be IS NULL",
        )
        assert_equal(
            cond.unary_child_ref().col_ref_name(),
            want_name,
            formula
            + ": the IS NULL must test the AGGREGATE's own output column. A"
            " different column here selects the wrong rows to replace",
        )
        assert_equal(
            when.when_default_ref().col_ref_name(),
            want_name,
            formula
            + ": the ELSE must be a byte-for-byte passthrough of the"
            " aggregate. Anything else changes an answer that was right",
        )
        var lit = when.when_case_result_ref(0).literal_value()
        if want_at == ArrowType.FLOAT64:
            assert_true(
                lit.is_float() and lit.float_val == 0.0,
                formula
                + ": the THEN literal must be a FLOAT64 zero. An INT64 zero"
                " here is a THEN/ELSE dtype mismatch, which RAISES out of"
                " `_run_case_overlay` rather than declining",
            )
        else:
            assert_true(
                lit.is_int() and lit.int_val == 0,
                formula + ": the THEN literal must be an INT64 zero",
            )


def test_MIN_and_MAX_are_wrapped_and_AVERAGE_and_COUNT_are_NOT() raises:
    """★ THE PARTITION, IN ONE BODY, because each half is meaningless alone.

    ⛔ `AVERAGE` IS EXCLUDED BY NAME AND THAT IS NOT AN OVERSIGHT. Excel's
    `AVERAGE` over an empty range is `#DIV/0!` — an ERROR VALUE, not 0 — and
    the plan door has no way to return one (`komira_core.plan.
    excel_error_code` owns the code and calls the columnar carrier "a mapped
    follow-up frontier"). Wrapping it would replace one wrong answer with a
    more convincing one.

    ⛔ `COUNT` IS EXCLUDED BECAUSE IT IS NEVER NULL. `count(<col>)` is already
    0 over zero rows and 0 over an all-null column; a wrap there is pure cost
    and would hide the fact that the TEXT case needs a different arm."""
    var a_min = AggExprArray()
    a_min.append(agg_min(col(String("qty"))))
    assert_equal(
        _built(String("MIN(qty)")),
        _oracle_zero_when_empty(
            LogicalPlan.aggregate(ExprArray(), a_min^, _leaf()),
            String("min"),
            False,
        ),
        "MIN over an all-blank range is 0 in a sheet",
    )

    var a_max = AggExprArray()
    a_max.append(agg_max(col(String("qty"))))
    assert_equal(
        _built(String("MAX(qty)")),
        _oracle_zero_when_empty(
            LogicalPlan.aggregate(ExprArray(), a_max^, _leaf()),
            String("max"),
            False,
        ),
        "MAX over an all-blank range is 0 in a sheet",
    )

    var a_avg = AggExprArray()
    a_avg.append(agg_mean(col(String("qty"))))
    assert_equal(
        _built(String("AVERAGE(qty)")),
        String(LogicalPlan.aggregate(ExprArray(), a_avg^, _leaf())),
        "⛔ AVERAGE MUST NOT BE WRAPPED. Its empty answer is #DIV/0!, not 0,"
        " and a 0 here is a plausible average nobody would question",
    )

    var a_cnt = AggExprArray()
    a_cnt.append(agg_count(col(String("qty"))))
    assert_equal(
        _built(String("COUNT(qty)")),
        String(LogicalPlan.aggregate(ExprArray(), a_cnt^, _leaf())),
        "COUNT over a NUMERIC column is never NULL and must stay a bare"
        " count(<col>)",
    )


def test_a_DECIMAL_aggregate_is_left_UNWRAPPED_and_the_narrowing_is_stated() raises:
    """⚠ THE ENVELOPE'S EDGE, ASSERTED RATHER THAN ASSUMED. The CASE overlay
    supports Int64 and Float64 output types and nothing else, so `sum(<decimal
    128>)` keeps SQL's NULL — a wrong answer for a sheet, and still far better
    than a wrap that RAISES on a type nobody tested.

    ⇒ THIS CELL GOES RED AS GOOD NEWS the day the overlay grows a decimal arm
    and someone widens `excel_zero_when_empty`. That is the intended
    lifecycle; do not delete it by deleting the assertion."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col(String("money"))))
    assert_equal(
        _built(String("SUM(money)")),
        String(LogicalPlan.aggregate(ExprArray(), aggs^, _leaf())),
        "a DECIMAL128 sum is outside the CASE overlay's Int64/Float64 envelope"
        " and must be left exactly as the relational builder emitted it",
    )


# =============================================================================
# ARM (a) — A RANGE WITH NO NUMERIC CELLS IS 0
# =============================================================================


def test_COUNT_over_a_TEXT_range_is_ZERO_and_not_the_nonnull_count() raises:
    """⭐ THE UNFINISHED HALF OF A DEFECT THIS DOOR ALREADY FIXED ONCE.

    `COUNT(<column>)` lowered to `count(*)` until 2026-09-04; that fix made it
    `count(<col>)`, which is right for BLANKS and still wrong for TEXT —
    Excel's COUNT counts NUMERIC cells, and six text cells are 0 to a sheet and
    6 to `count(<col>)`. So the first fix moved it from one wrong answer to a
    different wrong answer, and only a spreadsheet oracle could see that.

    ⚠ THE AGGREGATE UNDER THE PROJECTION IS `count(*)`, NOT `count(status)`,
    and the difference is not cosmetic: a 0-key `count(<col>)` outside
    int/float was DECLINED BY NAME by `agg_node_exec` until 2026-09-11, so the
    plan would have been unexecutable as well as wrong."""
    assert_equal(
        _built(String("COUNT(status)")),
        _oracle_zero_cell(_leaf(), String("count")),
        "COUNT over a TEXT range is the literal 0 over a count(*) carrier",
    )


def test_MAX_over_a_TEXT_range_is_the_NUMBER_zero_not_the_lexicographic_max() raises:
    """⚠ A VALUE **AND** A TYPE DIVERGENCE, which is why it is its own cell.
    Excel's MIN/MAX ignore text entirely, so `MAX` over an all-text range is
    the NUMBER 0; this door answered the lexicographic maximum as a STRING. A
    cell that only compared numbers would be blind to half of it."""
    assert_equal(
        _built(String("MAX(status)")),
        _oracle_zero_cell(_leaf(), String("max")),
        "MAX over a TEXT range is the number 0, not the lexicographic maximum",
    )
    assert_equal(
        _built(String("MIN(status)")),
        _oracle_zero_cell(_leaf(), String("min")),
        "MIN is MAX's partner: a lowering that special-cased one extremum would"
        " pass whichever cell was written alone",
    )


def test_COUNTA_over_the_SAME_TEXT_range_is_UNTOUCHED() raises:
    """⭐⭐ THE DISCRIMINATING PARTNER, AND THE ONE THAT MAKES THE TEXT ARM A
    RULE RATHER THAN A BLANKET.

    `COUNTA` counts NON-BLANK cells of ANY type — a text range is its natural
    binding and its answer over six text cells is 6, in a sheet AND in SQL. It
    asks the SAME column the same way as the cell two above, and the two
    answers are 0 and 6. A text arm keyed on the COLUMN alone would return 0
    for both and pass every assertion written about COUNT."""
    var aggs = AggExprArray()
    aggs.append(agg_count(col(String("status"))))
    assert_equal(
        _built(String("COUNTA(status)")),
        String(LogicalPlan.aggregate(ExprArray(), aggs^, _leaf())),
        "⛔ COUNTA MUST STAY `count(<col>)` over a TEXT range — counting"
        " non-blank cells of any type is its only meaning",
    )


def test_a_DATE_range_is_NOT_text_because_an_Excel_date_IS_a_number() raises:
    """⭐⭐ THE CELL THAT CATCHES THE OBVIOUS WRONG PREDICATE.

    `not at.is_numeric()` is False for STRING and ALSO for DATE32, TIMESTAMP
    and DECIMAL128 — and all three ARE numbers to a spreadsheet (an Excel date
    is a serial number). A text arm written that way answers `MAX(<date
    column>)` with `0`, which is a NEW defect of exactly the shape this work
    removed. The rule is TEXT, spelled out, and this is its falsifier."""
    assert_false(
        excel_range_has_no_numeric_cells(ArrowType.DATE32),
        "a DATE32 range HAS numeric cells — an Excel date is a serial number",
    )
    assert_false(
        excel_range_has_no_numeric_cells(ArrowType.DECIMAL128),
        "a DECIMAL128 range HAS numeric cells",
    )
    assert_true(
        excel_range_has_no_numeric_cells(ArrowType.STRING),
        "a STRING range has none",
    )
    assert_true(
        excel_range_has_no_numeric_cells(ArrowType.LARGE_STRING),
        "LARGE_STRING is the same question with 64-bit offsets",
    )
    # ...and the end-to-end consequence, over the fixture's DATE column.
    #
    # ⚠ `MAX(day)` COMES OUT COMPLETELY UNTOUCHED, and it is worth saying which
    # of the two guards is what stops it, because they are different guards:
    # the TEXT arm declines it (a date HAS numeric cells) and the
    # empty-identity arm ALSO declines it, because `_infer_agg_field` types
    # `max(DATE32)` as DATE32 and the CASE overlay serves only Int64/Float64.
    # Either one alone would be enough here; the assertion is that the plan is
    # the bare aggregate, and a literal-0 projection reading DATE32 is the
    # failure this cell exists to catch.
    var aggs = AggExprArray()
    aggs.append(agg_max(col(String("day"))))
    assert_equal(
        _built(String("MAX(day)")),
        String(LogicalPlan.aggregate(ExprArray(), aggs^, _leaf())),
        "MAX over a DATE column must NOT take the text arm — an Excel date is"
        " a serial NUMBER — and its DATE32 output is outside the CASE"
        " overlay's envelope, so the plan is the bare aggregate",
    )


def test_SUM_COUNT_MIN_MAX_over_a_BOOL_range_are_the_NUMBER_zero() raises:
    """⭐⭐ A LOGICAL RANGE HOLDS NO NUMBERS EITHER — MEASURED, NOT ARGUED.

    Microsoft, SUM: "If an argument is an array or reference, only numbers in
    that array or reference are counted. Empty cells, logical values, or text
    in the array or reference are ignored." COUNT: "Empty cells, logical
    values, text, or error values in the array or reference are not counted."
    MIN/MAX: "Empty cells, logical values, or text in the array or reference
    are ignored." and "If the arguments contain no numbers, MIN returns 0."

    Through `plan_exec --xl`, `COUNT(<bool column>)` answered 12 — SQL's
    non-null count — where a sheet answers 0; and the engine serving
    `sum(<bool>)` (the TRUE count) would turn SUM's refusal into 9. So all four
    lower to the zero-cell plan, over the SAME scan, exactly as TEXT does."""
    var verbs: List[String] = [
        String("SUM"), String("COUNT"), String("MIN"), String("MAX"),
    ]
    var names: List[String] = [
        String("sum"), String("count"), String("min"), String("max"),
    ]
    for i in range(len(verbs)):
        assert_equal(
            _built(verbs[i] + String("(flag)")),
            _oracle_zero_cell(_leaf(), names[i]),
            verbs[i]
            + "(<bool column>) must be the literal 0 over a count(*) carrier."
            " A bare aggregate here is SQL's answer (COUNT 12, SUM the TRUE"
            " count), and a sheet ignores logical values in a reference",
        )
    assert_true(
        excel_range_has_no_numeric_cells(ArrowType.BOOL),
        "a BOOL range has no numeric cells to SUM / COUNT / MIN / MAX",
    )
    assert_true(
        excel_range_is_text(String("COUNT"), _named(String("flag"))),
        "the unconditional COUNT over a BOOL range takes the zero-cell arm",
    )


def test_COUNTA_and_AVERAGE_over_a_BOOL_range_are_UNTOUCHED() raises:
    """⭐ THE TWO PARTNERS THAT KEEP THE BOOL ARM A RULE AND NOT A BLANKET.

    `COUNTA` counts non-blank cells of ANY type ("counts cells containing any
    type of information"), so twelve booleans are 12 to it: the plan must stay
    `count(flag)`. `AVERAGE` over no numbers is `#DIV/0!`, which this door
    cannot return — the plan stays a bare MEAN, which the engine REFUSES by
    name over a BOOL input. A zero there would be a plausible average nobody
    would question."""
    var a_cnt = AggExprArray()
    a_cnt.append(agg_count(col(String("flag"))))
    assert_equal(
        _built(String("COUNTA(flag)")),
        String(LogicalPlan.aggregate(ExprArray(), a_cnt^, _leaf())),
        "⛔ COUNTA over a BOOL range MUST stay count(<col>) — TRUE and FALSE"
        " are non-blank cells",
    )
    var a_avg = AggExprArray()
    a_avg.append(agg_mean(col(String("flag"))))
    assert_equal(
        _built(String("AVERAGE(flag)")),
        String(LogicalPlan.aggregate(ExprArray(), a_avg^, _leaf())),
        "⛔ AVERAGE over a BOOL range must NOT become 0 — Excel's answer is"
        " #DIV/0!, and the bare MEAN is refused by the engine by name",
    )


def test_SUMIF_over_a_BOOL_VALUE_range_is_NOT_zero_because_SUMIFS_counts_TRUE() raises:
    """⛔⛔ THE CONDITIONAL FORMS DO NOT TAKE THE BOOL HALF, AND IT IS
    MICROSOFT'S SENTENCE, NOT A PREFERENCE. The SUMIFS page: "Cells in
    Sum_range that contain TRUE evaluate to 1. Those that contain FALSE
    evaluate to 0 (zero)." A zero-cell plan here would answer 0 where the
    documented answer is the count of matching TRUEs — so the plan stays the
    relational `sum(flag)` over the filtered scan, and the engine answers it.

    ⚠ THIS IS THE CELL A ONE-LINE WIDENING OF THE SHARED PREDICATE FAILS:
    `excel_cond_value_range_is_text` delegates to `excel_range_is_text`, so
    adding BOOL there without the exclusion turns this into a literal 0."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col(String("flag"))))
    assert_equal(
        _built(String('SUMIF(qty, ">25", flag)')),
        _oracle_zero_when_empty(
            LogicalPlan.aggregate(ExprArray(), aggs^, _filtered_leaf()),
            String("sum"),
            False,
        ),
        "SUMIF over a BOOL value range must be sum(flag) over the filtered"
        " scan under the INT64 zero identity — SUMIFS evaluates TRUE as 1,"
        " and over no matching row a sheet answers 0",
    )
    assert_false(
        excel_cond_value_range_is_text(String("SUMIF"), _named(String("flag"))),
        "a BOOL value range is not the conditional text arm's question",
    )
    assert_true(
        excel_cond_value_range_is_text(
            String("SUMIF"), _named(String("status"))
        ),
        "...while a TEXT value range still is (SUMIF ignores text)",
    )


def test_a_TWO_D_range_has_no_column_so_neither_arm_can_fire() raises:
    """`COUNT(door)` binds the WHOLE table and has no column selector, so there
    is no arrow type to classify. `excel_bound_column_arrow_type` answers None
    — "leave the plan alone" — and `count(*)` is returned untouched.

    ⛔ None MUST NOT MEAN "assume text". An unknown column is a formula defect
    the executor names precisely; guessing here would turn it into a confident
    0."""
    assert_false(
        Bool(excel_bound_column_arrow_type(_named(String("")))),
        "a selector-less binding has no column type to report",
    )
    assert_false(
        Bool(excel_bound_column_arrow_type(_named(String("no_such_col")))),
        "a column the schema does not carry has no type to report either",
    )
    var aggs = AggExprArray()
    aggs.append(agg_count())
    assert_equal(
        _built(String("COUNT(door)")),
        String(LogicalPlan.aggregate(ExprArray(), aggs^, _leaf())),
        "COUNT over a 2D range stays count(*) — the row count of the range",
    )


# =============================================================================
# THE CONDITIONAL FAMILY — and the ONE place the two COUNTs must not be confused
# =============================================================================


def test_SUMIF_carries_the_zero_identity_over_its_VALUE_range_type() raises:
    """★ THE MEASURED DIVERGENCE: `SUMIF(gcol,"zzz",qty)` over zero matching
    rows answered `None` through the C door where a sheet answers 0.

    The wrap types its zero from the VALUE range's aggregate, exactly as the
    unconditional form does — `price` is FLOAT64, so a FLOAT64 zero."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col(String("price"))))
    assert_equal(
        _built(String('SUMIF(qty, ">25", price)')),
        _oracle_zero_when_empty(
            LogicalPlan.aggregate(ExprArray(), aggs^, _filtered_leaf()),
            String("sum"),
            True,
        ),
        "SUMIF must be PROJECT(CASE ...) over AGGREGATE(SUM(price)) over"
        " FILTER(qty > 25) over SCAN",
    )


def test_COUNTIF_over_a_TEXT_RANGE_IS_NOT_ZERO() raises:
    """⭐⭐⭐ THE HIGHEST-VALUE GUARD IN THIS FILE, AND THE ONE A NAIVE
    IMPLEMENTATION FAILS.

    `COUNT` and `COUNTIF` share the `XLA_COUNT` tag because they share one
    lowering ladder, and they do NOT mean the same thing:

        COUNT(<range>)            counts the NUMERIC cells  -> 0 over text
        COUNTIF(<range>, <crit>)  counts the MATCHING cells -> any type

    So a text arm keyed on the tag alone answers `COUNTIF(status,"acme")` with
    0 — the commonest spelling a real sheet has, returned as a confident wrong
    number. `excel_cond_value_range_is_text` excludes COUNTIF BY NAME and this
    is its falsifier.

    ⚠ THE EXPECTED PLAN IS `count(*)` OVER THE FILTER, which is what
    `build_cond_agg_plan` has emitted since 2026-09-11 (a `count(<text col>)`
    was declined by the 0-key executor outright), and the predicate is the
    CASE-FOLDED text comparison the case-fold change introduced."""
    var pred = Expr.binary(
        BIN_EQ,
        Expr.lower(Expr.col_ref(String("status"))),
        Expr.literal(ScalarValue.from_string(String("acme"))),
    )
    var aggs = AggExprArray()
    aggs.append(agg_count())
    assert_equal(
        _built(String('COUNTIF(status, "acme")')),
        String(
            LogicalPlan.aggregate(
                ExprArray(), aggs^, LogicalPlan.filter(pred^, _leaf())
            )
        ),
        "⛔ COUNTIF OVER A TEXT RANGE MUST COUNT MATCHING CELLS, NOT ANSWER 0."
        " If this reads as a literal-0 projection, the text arm is keyed on the"
        " XLA_COUNT tag and has swallowed the conditional COUNT",
    )
    assert_false(
        excel_cond_value_range_is_text(
            String("COUNTIF"), _named(String("status"))
        ),
        "COUNTIF over a TEXT range is not the text arm's question",
    )
    assert_true(
        excel_range_is_text(String("COUNT"), _named(String("status"))),
        "the UNCONDITIONAL COUNT over the same range IS — the two differ",
    )


def test_AVERAGEIF_is_left_alone_for_the_same_reason_AVERAGE_is() raises:
    """Excel's `AVERAGEIF` over zero matching rows is `#DIV/0!`. NULL is wrong
    and 0 is worse — a spreadsheet user reads a 0 average as a real number. The
    divergence is REGISTERED in `test_xl_sheet_semantics_e2e` against the day
    the plan surface can carry an error value."""
    var aggs = AggExprArray()
    aggs.append(agg_mean(col(String("price"))))
    assert_equal(
        _built(String('AVERAGEIF(qty, ">25", price)')),
        String(
            LogicalPlan.aggregate(ExprArray(), aggs^, _filtered_leaf())
        ),
        "AVERAGEIF must stay a bare MEAN over the filtered scan",
    )


def test_SUMIF_over_a_TEXT_VALUE_range_is_zero() raises:
    """Excel sums only the numeric cells of its sum_range, so a TEXT sum_range
    contributes nothing and the answer is 0 — and the plan this replaces
    (`sum(<text col>)`) is one the executor declines outright, so the text arm
    turns an unexecutable plan into the right number."""
    assert_equal(
        _built(String('SUMIF(qty, ">25", status)')),
        _oracle_zero_cell(_filtered_leaf(), String("sum")),
        "SUMIF over a TEXT value range is 0 over the SAME filtered scan the"
        " aggregate form would have used",
    )


# =============================================================================
# THE PREDICATES, ASSERTED DIRECTLY — the tag partition is a claim
# =============================================================================


def test_the_numeric_cell_aggregates_are_exactly_SUM_COUNT_MIN_MAX() raises:
    """★ THE PARTITION IS ASSERTED IN BOTH DIRECTIONS, because a predicate that
    answered True for everything would pass every "is wrapped" cell above.

    ⛔ `XLA_COUNT_NONBLANK` (COUNTA) AND `XLA_MEAN` (AVERAGE) ARE THE TWO THAT
    MUST BE FALSE, and each for its own reason: COUNTA counts text ON PURPOSE,
    and AVERAGE's empty answer is an error value rather than an identity."""
    assert_true(excel_reads_numeric_cells_only(XLA_SUM))
    assert_true(excel_reads_numeric_cells_only(XLA_COUNT))
    assert_true(excel_reads_numeric_cells_only(XLA_MIN))
    assert_true(excel_reads_numeric_cells_only(XLA_MAX))
    assert_false(
        excel_reads_numeric_cells_only(XLA_MEAN),
        "AVERAGE over no numeric cells is #DIV/0!, not 0",
    )
    assert_false(
        excel_reads_numeric_cells_only(XLA_COUNT_NONBLANK),
        "COUNTA counts non-blank cells of ANY type — text included",
    )
    assert_false(
        excel_reads_numeric_cells_only(XLA_MEDIAN),
        "MEDIAN over an empty set is #NUM! in Excel, which this door cannot"
        " return either",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
