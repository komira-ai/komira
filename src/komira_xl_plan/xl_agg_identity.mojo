# =============================================================================
# xl_agg_identity.mojo — ★ A SPREADSHEET AGGREGATE OVER NOTHING IS **0**.
#                          SQL'S IS **NULL**. THIS FILE IS THE ONE PLACE THAT
#                          SAYS SO.
# =============================================================================
#
# `SUM` of an empty range is `0` in a spreadsheet and `NULL` in SQL:2016, in
# DuckDB and in this engine's 0-key aggregate — and BOTH are right for their own
# surface. SQL's NULL means "there was nothing to add"; Excel's 0 is the additive
# IDENTITY, which is what a sheet shows in a cell that sums an empty column.
#
# ⇒ SO THE DIFFERENCE IS SPENT HERE, IN THE LOWERING, EXACTLY AS THE CASE-FOLD
#   IS (`xl_text_compare.mojo`). Teaching the 0-key aggregate kernel to answer 0
#   would fix Excel by breaking SQL — the larger surface, which is currently
#   RIGHT — and `agg_scalar_fold.build_empty_scalar_agg_identity` says in its own
#   docstring that it is "the SQL-MANDATED 1-row identity". `komira_xl_plan` is
#   where an Excel formula stops being Excel and becomes an engine plan; a
#   semantics difference between two frontends has to be spent at that boundary
#   or it is spent in the shared engine, where it is wrong for everybody else.
#
# ================== ⭐ THE RULE, IN ONE SENTENCE ============================
#
#   **An Excel numeric aggregate sees only the NUMERIC cells of its range, and
#   over an EMPTY set of numeric cells SUM / MIN / MAX / COUNT are 0.**
#
# Two things follow from that one sentence, and they are two different lowerings
# because the plan cannot tell them apart at build time:
#
#   (a) THE RANGE HAS NO NUMERIC CELLS **BY TYPE**. A TEXT column holds no
#       numbers at all, and neither does a LOGICAL one (a sheet's SUM / COUNT /
#       MIN / MAX ignore TRUE/FALSE in a reference), so the answer is 0 whatever
#       the data is — knowable from the SCHEMA, at build time, with nothing
#       executed. `COUNT` over three text cells was `3`, and over twelve
#       booleans `12`; a sheet says `0` to both. ⇒ `excel_zero_cell_plan`.
#
#       ⭐ AND FOR `MIN` / `MAX` IT IS ALSO A CAPABILITY GAIN, WHICH IS NOT
#       WHAT THE PAPER ANALYSIS PREDICTED. The expectation was a wrong VALUE
#       and a wrong TYPE — the lexicographic extremum, as a string. MEASURED
#       2026-09-11 on origin/main, `MIN(<text range>)` and `MAX(<text range>)`
#       did not answer at all:
#
#           agg_node_exec: out-of-envelope 0-key scalar agg over a
#           FILTER?->SCAN(parquet) … SUM/MIN/MAX/MEAN need an int/float input
#           DType
#
#       So the plan this arm REPLACES was un-executable, exactly as
#       `COUNTIF`-over-text was before 2026-09-11. `count(*)` as the carrier is
#       what keeps the new plan inside the 0-key executor's envelope.
#
#   (b) THE RANGE IS NUMERIC AND THE AGGREGATE CAME BACK **NULL**. That happens
#       when no row survived the filter (`SUMIF(g,"zzz",qty)`) or when every
#       cell in the range is blank (`SUM(<all-null column>)`) — and the two are
#       the SAME question to the plan, which is why one mechanism serves both.
#       A 0-key SUM/MIN/MAX is NULL **exactly** when it had no non-null input,
#       so `CASE WHEN <a> IS NULL THEN 0 ELSE <a> END` is not an approximation
#       of Excel's rule, it IS the rule. ⇒ `excel_zero_when_empty`.
#
# ⚠ COUNT NEEDS NEITHER ARM ONCE ITS RANGE IS NUMERIC. `count(<col>)` is 0 over
# zero rows and 0 over an all-null column already, and it is never NULL — which
# is why (b) deliberately does not touch it, and why the fix for `COUNT` over
# TEXT is (a) and not a second null rule.
#
# ================ ⚠ THE ENVELOPES, AND WHY EACH IS NARROW ===================
#
# (a) "NO NUMERIC CELLS" means TEXT (`STRING` / `LARGE_STRING`) and LOGICAL
#     (`BOOL`), and nothing else. A DATE, a TIMESTAMP and a DECIMAL all ARE
#     numbers to a spreadsheet (an Excel date IS a serial number), so "not
#     `is_numeric()`" is the WRONG predicate here — it would answer
#     `MAX(<date column>)` with 0.
#
#     ⛔ BUT NOT FOR THE CONDITIONAL FORMS, AND THAT IS ALSO MICROSOFT'S
#     SENTENCE. The SUMIFS page says: "Cells in Sum_range that contain TRUE
#     evaluate to 1. Those that contain FALSE evaluate to 0 (zero)." So a
#     LOGICAL sum range is not "no numbers" to a conditional aggregate, and
#     `excel_cond_value_range_is_text` excludes BOOL by name.
#
# (b) Only an aggregate whose output is `INT64` or `FLOAT64` is wrapped, and
#     that bound is READ OFF THE BUILT PLAN rather than inferred from the
#     column: `_run_case_overlay` (`komira_compiler/compiler_eval_case.mojo`)
#     "currently supports Int64 and Float64 output types", and a THEN/ELSE
#     dtype disagreement RAISES out of it. So a `sum(<decimal>)` or a
#     `sum(<uint64>)` keeps today's plan exactly — a NULL answer that is wrong
#     for a sheet is still far better than a raise, and the narrowing is
#     visible in the plan rather than hidden in a kernel.
#
# ================ ⭐⭐ WHERE THE WRAP GOES, AND WHY NOT LOWER ===============
#
# ⛔ IT IS APPLIED BY `xl_plan_build`'s ARMS AND **NOT** INSIDE
# `rel_agg_build.build_rel_agg_plan` / `rel_condagg_build.build_cond_agg_plan`.
# The obvious place is the builder; it is the wrong one, for a MEASURED reason
# and not a stylistic one:
#
#   * ⭐ AND THE INLINE ARM DOES NOT NEED THE WRAP — IT IS ALREADY RIGHT, BY
#     A DIFFERENT MECHANISM. `materialize_scalar_agg_plan`'s own docstring
#     records that its fold *"returns the numeric ZERO for SUM/MIN/MAX ...
#     where a SQL aggregate returns NULL"*, and names the Excel consequence:
#     *"the zero happens to be the closer answer for SUM/MIN/MAX (`=SUM()` of
#     an empty range is 0 in Excel)"*. ⇒ THE TWO EXCEL EXECUTION PATHS
#     DISAGREED WITH EACH OTHER, and the one this file fixes is the PLAN door,
#     which runs on the general walker and therefore on SQL's identity. The
#     wrap makes the plan door agree with the inline arm AND with the sheet;
#     applying it to both would make the inline arm answer 0 twice and change
#     nothing else.
#
# ⇒ SO THE RELATIONAL BUILDERS STAY THE RELATIONAL BUILDERS — one expression,
#   shared by both arms, exactly as `xl_plan_build.mojo`'s header requires —
#   and `build_xl_plan` is where a formula stops being a relation and becomes
#   a CELL. Excel's identity/error semantics are cell semantics; that is the
#   boundary they belong on.
#
# Encapsulation rule : values only. No `UnsafePointer` in any
# signature, no wildcard origins, no `unsafe_from_address`.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.agg_expr import count as agg_count
from komira_core.plan.expr import Expr, UN_IS_NULL, WhenCaseData
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_AGGREGATE,
)
from komira_core.plan.scalar_value import ScalarValue

from .bound_relation import BoundRelation
from .xl_fn_table import (
    xl_plan_agg_tag,
    XLA_COUNT,
    XLA_MAX,
    XLA_MIN,
    XLA_SUM,
)


def excel_reads_numeric_cells_only(tag: UInt8) -> Bool:
    """True for the Excel aggregates that see ONLY the numeric cells of a range
    and answer `0` when there are none: `SUM`, `COUNT`, `MIN`, `MAX` (and the
    conditional forms, which carry the same `XLA_*` tag).

    ⛔ `XLA_MEAN` IS EXCLUDED BY NAME. `AVERAGE` over no numeric cells is
    `#DIV/0!`, a different answer of a different KIND — see the header. ⛔ And
    `XLA_COUNT_NONBLANK` (COUNTA) is excluded because it is the one aggregate
    here that is SUPPOSED to count text: `COUNTA` counts non-blank cells of any
    type, so a text range is its natural binding and `0` would be its wrong
    answer. `XLA_MEDIAN` / `XLA_STDDEV_SAMP` / `XLA_VAR_SAMP` / `XLA_CORR` are
    excluded because Excel answers `#NUM!` / `#DIV/0!` over an empty set, which
    this door cannot return either."""
    return (
        tag == XLA_SUM or tag == XLA_COUNT or tag == XLA_MIN or tag == XLA_MAX
    )


def excel_range_has_no_numeric_cells(at: ArrowType) -> Bool:
    """True if a column of arrow type `at` can hold NO number a spreadsheet's
    `SUM` / `COUNT` / `MIN` / `MAX` would aggregate — exactly TEXT and LOGICAL.

    ⛔ IT IS NOT `not at.is_numeric()`, AND THE DIFFERENCE IS A WRONG ANSWER.
    `is_numeric()` is False for `DATE32` / `TIMESTAMP` / `DECIMAL128`, and all
    three ARE numbers in a sheet — an Excel date is a serial number and a
    currency column is a number with a scale. Answering `MAX(<date column>)`
    with `0` would be a new defect of exactly the shape this file exists to
    remove.

    ⭐ BOOL IS A MEMBER SINCE 2026-09-25 — it was a stated residual until an
    executed grade measured `COUNT(<bool column>)` answering 12 where a sheet
    answers 0. Microsoft, SUM: "If an argument is an array or reference, only
    numbers in that array or reference are counted. Empty cells, logical
    values, or text in the array or reference are ignored." MIN and MAX
    ("Empty cells, logical values, or text in the array or reference are
    ignored") and COUNT ("Empty cells, logical values, text, or error values
    in the array or reference are not counted") say the same.

    ⚠ `COUNTA` NEVER ASKS THIS: `excel_reads_numeric_cells_only` excludes it
    by name, and a column of TRUE/FALSE is twelve non-blank cells to COUNTA.
    ⚠ AND THE CONDITIONAL FORMS DO NOT TAKE THE BOOL HALF — see
    `excel_cond_value_range_is_text`."""
    return (
        at == ArrowType.STRING
        or at == ArrowType.LARGE_STRING
        or at == ArrowType.BOOL
    )


def excel_bound_column_arrow_type(rel: BoundRelation) -> Optional[ArrowType]:
    """The arrow type of the column `rel` selects, or `None` when there is no
    answer to give: a selector-less (2D) range, a RESIDENT binding (which has no
    named table), or a column the table's schema does not carry.

    ⚠ `None` MEANS "LEAVE THE PLAN ALONE", never "assume text". An unknown
    column is a formula defect the executor will name precisely; guessing here
    would convert it into a confident `0`."""
    if not rel.has_column():
        return Optional[ArrowType]()
    try:
        var schema = rel.table_schema()
        var idx = schema.column_index(rel.column)
        return Optional[ArrowType](schema.field_arrow_type(idx))
    except:
        return Optional[ArrowType]()


def excel_range_is_text(up: String, rel: BoundRelation) -> Bool:
    """The (a) arm's whole question in one call: does `up` read only numeric
    cells, and does `rel` select a column that holds none?

    Both halves are needed and neither is sufficient: `COUNTA` over text must
    stay `count(<col>)`, and `SUM` over an INT64 column must stay `sum(<col>)`.

    ⚠ THE NAME PREDATES THE BOOL MEMBER: "text" here means "holds no number",
    which since 2026-09-25 is a TEXT **or a LOGICAL** column (see
    `excel_range_has_no_numeric_cells`). Kept rather than renamed: it and
    `excel_cond_value_range_is_text` are one naming family, and the latter is
    named inside a note STRING in `xl_fn_notes.mojo` that ships to hosts.
    """
    if not excel_reads_numeric_cells_only(xl_plan_agg_tag(up)):
        return False
    var at = excel_bound_column_arrow_type(rel)
    if not at:
        return False
    return excel_range_has_no_numeric_cells(at.value())


def excel_cond_value_range_is_text(
    up: String, value_rel: BoundRelation
) -> Bool:
    """The (a) arm's question for a CONDITIONAL aggregate — `SUMIF` /
    `AVERAGEIF` and the plural forms — over its VALUE range.

    ⛔⛔ `COUNTIF` IS EXCLUDED BY NAME AND THIS IS THE WHOLE REASON THIS
    FUNCTION IS NOT `excel_range_is_text`. The two `COUNT`s do not mean the
    same thing:

        COUNT(<range>)             counts the NUMERIC cells   -> 0 over text
        COUNTIF(<range>, <crit>)   counts the MATCHING cells  -> any type

    They share the `XLA_COUNT` tag because they share a lowering
    (`_agg_expr_for_name`), so a predicate keyed on the tag alone answers the
    wrong question for one of them. `COUNTIF(status, "acme")` over a TEXT
    column is the commonest spelling a real sheet has and its answer is the
    match count; routing it through the text arm would make it `0` — a
    confident wrong number, and precisely the class of defect this file was
    written to remove.

    ⛔ AND A **LOGICAL** VALUE RANGE IS EXCLUDED TOO, BY MICROSOFT'S OWN
    SENTENCE, where the unconditional forms take it. The SUMIFS page: "TRUE and
    FALSE values for Sum_range are evaluated differently, which may cause
    unexpected results when they're added. Cells in Sum_range that contain
    TRUE evaluate to 1. Those that contain FALSE evaluate to 0 (zero)." So
    `SUMIFS(<bool range>, ...)` is a count of the matching TRUEs, not 0, and
    the zero-cell plan would be a confident wrong number. The plan stays the
    relational one; today the engine refuses a `sum(<bool>)` by name, and the
    day it serves one its answer (the TRUE count) is the documented one.

    ⚠ AND THERE IS NO SECOND GATE NEEDED FOR THE (b) ARM: `count` is never
    NULL, so `excel_zero_when_empty` is never reached for a COUNT anyway."""
    if xl_plan_agg_tag(up) == XLA_COUNT:
        return False
    var at = excel_bound_column_arrow_type(value_rel)
    if at and at.value() == ArrowType.BOOL:
        return False
    return excel_range_is_text(up, value_rel)


def excel_zero_cell_plan(var agg_plan: LogicalPlan) raises -> LogicalPlan:
    """★ ARM (a) — `PROJECT([0 AS <name>]) <- AGGREGATE([], [count(*)]) <- <agg_plan's own child>`.

    The plan a spreadsheet's `SUM` / `COUNT` / `MIN` / `MAX` denotes over a
    range that holds no numbers: the answer is the literal `0`, known from the
    SCHEMA alone with nothing executed.

    ⚠⚠ IT TAKES THE PLAN THE BUILDER ALREADY PRODUCED AND KEEPS TWO THINGS OUT
    OF IT — THE OUTPUT **NAME** AND THE **CHILD** — RATHER THAN TAKING EITHER
    AS AN ARGUMENT. Both would otherwise be re-derived by the caller, and both
    have a named precedent for what re-derivation costs:

      * the NAME. A caller reads a result BY NAME, and
        `logical_plan.agg_func_base_name` exists because three producers each
        invented their own and `cb01_count` came back with three different
        column names for one number. `_infer_agg_field` is the authority; the
        aggregate this replaces carries its answer, so the fix structurally
        CANNOT rename anybody's column.
      * the CHILD. `rel_agg_build._named_scan` / `rel_filter_build.
        filtered_scan` are the ONE spelling of this package's leaves, and a
        second spelling here would be free to drift into a plan that scans (or
        filters) something other than what the executing arm scans. Lifting the
        builder's own child cannot drift.

    ⚠ THE `count(*)` IS A ONE-ROW CARRIER AND NOTHING ELSE READS IT. A scalar
    result needs a 1-row relation to project over, and `count(*)` is the one
    aggregate that (i) needs no column, so it cannot be declined for the input
    dtype that started this — `agg_node_exec` admits `COUNT(*)` BY NAME in the
    same sentence in which it declines a 0-key `count(<col>)` outside
    int/float — and (ii) is never NULL, so the projection above it needs no
    null handling of its own. ⇒ It also means `sum(<text col>)`, which the
    executor declines outright, never reaches the engine at all.

    ⚠ THE LITERAL IS AN **INT64** `0` AND THAT IS A REAL TYPE CHANGE for
    `MAX(<text column>)`, which answers a STRING today. It is the intended one:
    Excel's `MAX` over text is the NUMBER 0, so a string-typed result was the
    other half of the same defect.

    Raises when `agg_plan` is not the `PLAN_AGGREGATE` its callers build — a
    defect in the dispatch, never in the formula."""
    if agg_plan.tag != PLAN_AGGREGATE:
        raise Error(
            "excel_zero_cell_plan: expected the PLAN_AGGREGATE its caller just"
            " built and got plan tag "
            + String(Int(agg_plan.tag))
            + ". This function lifts the aggregate's own child and output name;"
            " it cannot do either over another node. Defect in the build."
        )
    var out_name = agg_plan.output_schema.field_name(0)
    var child = agg_plan.aggregate_data_ref().child[].copy()

    var aggs = AggExprArray()
    aggs.append(agg_count())
    var exprs = ExprArray()
    exprs.append(
        Expr.alias(Expr.literal(ScalarValue.from_int(0)), out_name)
    )
    return LogicalPlan.project(
        exprs^, LogicalPlan.aggregate(ExprArray(), aggs^, child^)
    )


def excel_zero_when_empty(var agg_plan: LogicalPlan) raises -> LogicalPlan:
    """★ ARM (b) — `PROJECT([CASE WHEN a IS NULL THEN 0 ELSE a END AS a]) <- agg_plan`,
    or `agg_plan` UNCHANGED when the wrap is outside the CASE overlay's dtype
    envelope.

    A 0-key `SUM` / `MIN` / `MAX` is NULL **exactly** when it had no non-null
    input, so this rewrites "there was nothing to aggregate" into Excel's
    additive identity and leaves every other answer alone — `ELSE a` is a
    byte-for-byte passthrough of the aggregate the plan already computed.

    ⛔ IT MUST NOT BE APPLIED TO `COUNT` OR `MEAN`. `count` is never NULL, so
    the wrap would be pure cost; `avg` IS NULL over an empty set and Excel's
    answer there is `#DIV/0!`, so turning it into `0` would replace one wrong
    answer with a more convincing one. The caller gates on
    `excel_reads_numeric_cells_only` and passes only SUM/MIN/MAX.

    ⚠ THE TYPE IS READ OFF THE BUILT PLAN, NOT INFERRED FROM THE COLUMN, and
    that is what keeps the two sides of the CASE in agreement:
    `_infer_agg_field` promotes (`sum(INT32)` is INT64, `sum(FLOAT32)` is
    FLOAT64), so a literal typed from the INPUT column would disagree with the
    aggregate's own output for four of the nine numeric types — and a THEN/ELSE
    dtype disagreement RAISES out of `_run_case_overlay` rather than declining.

    ⚠ ANYTHING OUTSIDE `INT64` / `FLOAT64` IS RETURNED UNCHANGED. That is the
    CASE overlay's stated envelope ("currently supports Int64 and Float64
    output types"), so `sum(<decimal128>)` and `sum(<uint64>)` keep SQL's NULL
    here. A narrowing that is visible in the plan is worth more than a wrap
    that raises on a type nobody tested."""
    if agg_plan.output_schema.num_columns() != 1:
        return agg_plan^
    var at = agg_plan.output_schema.field_arrow_type(0)
    if at != ArrowType.INT64 and at != ArrowType.FLOAT64:
        return agg_plan^
    var name = agg_plan.output_schema.field_name(0)

    var zero: ScalarValue
    if at == ArrowType.INT64:
        zero = ScalarValue.from_int(0)
    else:
        zero = ScalarValue.from_float(0.0)

    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.unary(UN_IS_NULL, Expr.col_ref(name)),
            Expr.literal(zero^),
        )
    )
    var exprs = ExprArray()
    exprs.append(
        Expr.alias(
            Expr.when(cases^, Expr.col_ref(name)),
            name,
        )
    )
    return LogicalPlan.project(exprs^, agg_plan^)
