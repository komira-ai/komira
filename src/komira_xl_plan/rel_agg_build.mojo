# =============================================================================
# rel_agg_build.mojo — ★ SCAN -> AGGREGATE, WITH NO ENGINE. The one builder
#                        `komira_xl_plan`'s envelope is made of.
# =============================================================================
#
# Encapsulation rule : values only. The plan leaves by move.
# =============================================================================

from komira_core.plan.col_expr import col
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
)
from komira_core.plan.agg_expr import (
    AggExpr,
    sum as agg_sum,
    count as agg_count,
    min as agg_min,
    max as agg_max,
    mean as agg_mean,
    median as agg_median,
    stddev_samp as agg_stddev_samp,
    var_samp as agg_var_samp,
    agg_is_bivariate,
    AGG_CORR,
    AGG_COVAR_POP,
    AGG_COVAR_SAMP,
    AGG_REGR_SLOPE,
    AGG_REGR_INTERCEPT,
    AGG_REGR_R2,
)

from .bound_relation import BoundRelation
from .xl_fn_table import (
    xl_plan_agg_tag,
    XLA_CORR,
    XLA_COVAR_POP,
    XLA_COVAR_SAMP,
    XLA_REGR_SLOPE,
    XLA_REGR_INTERCEPT,
    XLA_REGR_R2,
    xl_agg_needs_column,
    XLA_NONE,
    XLA_SUM,
    XLA_COUNT,
    XLA_MIN,
    XLA_MAX,
    XLA_MEAN,
    XLA_MEDIAN,
    XLA_STDDEV_SAMP,
    XLA_VAR_SAMP,
    XLA_COUNT_NONBLANK,
)


def _named_scan(rel: BoundRelation) raises -> LogicalPlan:
    """★ THE SCAN LEAF OF THE NAMED ARM — and the reason an Excel plan can reach
    `plan_to_bytes` at all.

    Byte-for-byte the leaf `SqlCatalog.build_scan(name)` builds for the same
    table (`sql_catalog.mojo`): `LogicalPlan.scan_from_source(source, schema)`.
    Over a parquet path that is `ParquetSource(path, schema, None)`, which is
    arm 1 of `plan_wire_codec._source_to_wire` and encodes with no codec change.

    ⚠ IT LIVES HERE AND NOT ON `BoundRelation`: putting it on the struct would
    put `LogicalPlan` into `bound_relation.mojo`, which the scalar evaluator
    imports."""
    var t = rel.named_table()
    return LogicalPlan.scan_from_source(t.source.copy(), t.schema.copy())


def _bivariate_agg_func(tag: UInt8) -> Optional[UInt8]:
    """★ THE ONE MAPPING FROM A BIVARIATE `XLA_*` TAG TO ITS `AGG_*` CODE —
    and the ONE place that knows which Excel tags are bivariate at all.

    ⛔ IT RETURNS THE CODE, NOT A BOOL, BECAUSE TWO SITES NEED DIFFERENT HALVES
    OF ONE ANSWER AND MUST NOT BE ABLE TO DISAGREE. `build_bivar_agg_plan`
    needs the `AGG_*` code to build with; `_agg_expr_for_name` needs only to
    know that the tag is bivariate so it can raise instead of building a unary
    aggregate. Before 2026-09-15 the second was spelled `tag == XLA_CORR` and
    the first `if xl_plan_agg_tag(up) != XLA_CORR: return None` — two literals
    over one set, in one file, and adding a sixth name would have had to edit
    both. It did not have to edit both; nothing would have caught the miss.

    ⚠ THE `AGG_*` CONSTANTS ARE NAMED **HERE** AND NOT IN `xl_fn_table`, which
    is the import ban that whole file's header is about: naming `AggExpr`'s
    constants in a module `formula_eval.mojo` imports pulls the `Expr`
    machinery into the engine-FREE scalar evaluator. This module already
    imports `agg_expr`.

    ⚠ `agg_is_bivariate` (`agg_expr.mojo`) IS THE AUTHORITY ON WHAT BIVARIATE
    MEANS and this function is checked against it by
    `test_every_bivariate_xla_tag_maps_to_a_bivariate_agg_func` — it lists
    twelve `AGG_*` codes and this maps six Excel tags onto five of them, so the
    two sets are DIFFERENT SIZES on purpose and equality would be the wrong
    assertion."""
    if tag == XLA_CORR:
        return Optional[UInt8](AGG_CORR)
    if tag == XLA_COVAR_POP:
        return Optional[UInt8](AGG_COVAR_POP)
    if tag == XLA_COVAR_SAMP:
        return Optional[UInt8](AGG_COVAR_SAMP)
    if tag == XLA_REGR_SLOPE:
        return Optional[UInt8](AGG_REGR_SLOPE)
    if tag == XLA_REGR_INTERCEPT:
        return Optional[UInt8](AGG_REGR_INTERCEPT)
    if tag == XLA_REGR_R2:
        return Optional[UInt8](AGG_REGR_R2)
    return Optional[UInt8]()


def _agg_expr_for_name(up: String, column: String) raises -> Optional[AggExpr]:
    """The aggregate expression `up` denotes over `column`, or None if `up` is
    not a REL-capable aggregate name on the PLAN surface.

    ⚠ COUNT IS TWO DIFFERENT AGGREGATES DEPENDING ON THE BINDING, and that is
    the Excel semantics rather than a convenience:

        COUNT over a SELECTOR-LESS binding  -> count(*)      the row count of
                                                             a 2D range
        COUNT over a COLUMN binding         -> count(<col>)  non-null count

    Excel's COUNT counts NUMERIC cells, and a blank cell is not one. Until
    2026-09-04 both forms lowered to `count(*)`, so `COUNT(qty)` over a column
    with nulls answered the ROW COUNT — wrong by Excel's semantics AND by
    SQL's, which is the combination that makes it a defect rather than a
    surface difference. ⭐ AND THAT FIX WAS ONLY HALF OF ONE: right for BLANKS,
    still wrong for TEXT, where Excel's COUNT is 0 and `count(<col>)` is the
    non-null count. The TEXT half is closed as of 2026-09-11 and NOT in this
    function — `xl_plan_build`'s arms apply it, because it is a CELL-value rule
    and this builder is shared with an inline arm whose narrow terminal admits
    only a bare aggregate (`xl_agg_identity.mojo`, "WHERE THE WRAP GOES").
    COUNTA is the non-blank count of any type and is still the one to reach for
    when that is the question.

    ⚠ THE COLUMN-LESS REFUSAL STILL LIVES IN THE CALLER, not here — see
    `build_rel_agg_plan`. Splitting it that way is what keeps the refusal ORDER
    identical between the named and the resident arms."""
    var tag = xl_plan_agg_tag(up)
    if tag == XLA_NONE:
        return Optional[AggExpr]()
    if tag == XLA_COUNT:
        # ★ The one tag whose expression depends on the BINDING and not only on
        # the name. An empty selector is the whole-table (2D range) form.
        if column.byte_length() == 0:
            return Optional[AggExpr](agg_count())
        return Optional[AggExpr](agg_count(col(column)))
    if tag == XLA_COUNT_NONBLANK:
        return Optional[AggExpr](agg_count(col(column)))
    if tag == XLA_SUM:
        return Optional[AggExpr](agg_sum(col(column)))
    if tag == XLA_MEAN:
        return Optional[AggExpr](agg_mean(col(column)))
    if tag == XLA_MIN:
        return Optional[AggExpr](agg_min(col(column)))
    if tag == XLA_MAX:
        return Optional[AggExpr](agg_max(col(column)))
    if tag == XLA_MEDIAN:
        return Optional[AggExpr](agg_median(col(column)))
    if tag == XLA_STDDEV_SAMP:
        return Optional[AggExpr](agg_stddev_samp(col(column)))
    if tag == XLA_VAR_SAMP:
        return Optional[AggExpr](agg_var_samp(col(column)))
    var biv = _bivariate_agg_func(tag)
    if biv:
        # ⛔ NOT AN OVERSIGHT AND NOT A REFUSAL. Every bivariate `AGG_*` has TWO
        # children, and every arm above builds a UNARY `AggExpr` from one column
        # name. Silently returning None here would report the name as `#NAME?` —
        # the formula's fault — when in fact it reached the wrong builder.
        #
        # ⚠ IT ASKS `_bivariate_agg_func` RATHER THAN SPELLING `tag == XLA_CORR`,
        # AND THAT IS THE WHOLE REASON THAT HELPER EXISTS. Until 2026-09-15 this
        # arm named ONE tag; the five tags added that day would each have fallen
        # through to the trailing "no arm for that tag" raise, which says
        # *"Add the arm here"* — sending the next reader to build a unary
        # aggregate out of a bivariate name. Two guards keyed off one function
        # cannot disagree.
        raise Error(
            "`" + up + "` is a BIVARIATE aggregate (AGG code "
            + String(Int(biv.value())) + ") and reached `_agg_expr_for_name`,"
            " which builds unary aggregates from ONE column. Its builder is"
            " `build_bivar_agg_plan`, dispatched on the XLF_BIVAR_AGG family by"
            " `xl_plan_build._build_bivar_agg`. This is a defect in the"
            " dispatch, not in the formula."
        )
    # ⚠ NOT A REFUSAL — a DEFECT in this build. The table said this name reaches
    # the plan surface and this mapping has no arm for its tag, which means the
    # two halves of one definition have gone out of step. Returning None would
    # report it as `#NAME?`, i.e. as the formula's fault.
    raise Error(
        "xl_fn_table says `"
        + up
        + "` reaches the plan surface with aggregate tag "
        + String(Int(tag))
        + ", but `_agg_expr_for_name` has no arm for that tag. Add the arm"
        " here — this is a defect in the build, not in the formula."
    )


def build_rel_agg_plan(
    up: String, rel: BoundRelation
) raises -> Optional[LogicalPlan]:
    """★ **THE FIRST `build_*_plan`.** The
    SCAN -> AGGREGATE plan that `up` (SUM/AVERAGE/COUNT/MIN/MAX) denotes over a
    relation bound BY NAME to a catalog table, or `None` if the formula is
    refused before any query exists.

    ⚠ COUNT IGNORES THE COLUMN. That asymmetry lives in the first guard rather
    than in `_agg_expr_for_name` for the reason that function states: splitting
    it that way is what keeps the refusal ORDER identical between the arms.

    ⚠ IT IS THE **NAMED** ARM'S BUILDER AND IT SAYS SO BY RAISING. `_named_scan`
    raises on a resident binding (`BoundRelation.named_table`), naming what to do
    instead. A resident leaf cannot be built here even in principle — it needs a
    context — which is exactly why it cannot serve a resident binding."""
    # THE TWO PURE REFUSALS — no plan, no query, no engine.
    #
    # ⚠ THE COLUMN-LESS GUARD ASKS THE TABLE, and it is no longer a
    # `up != "COUNT"` test. COUNTA also has no selector-less form — for the
    # OPPOSITE reason to COUNT's exemption, since a selector-less COUNTA would
    # be `count(*)`, a number that cannot tell a blank from a value, which is
    # the one thing COUNTA reports. `xl_agg_needs_column` states both.
    var tag = xl_plan_agg_tag(up)
    if tag != XLA_NONE and xl_agg_needs_column(tag) and not rel.has_column():
        return Optional[LogicalPlan]()
    var expr_opt = _agg_expr_for_name(up, rel.column)
    if not expr_opt:
        return Optional[LogicalPlan]()

    var aggs = AggExprArray()
    aggs.append(expr_opt.take())
    return Optional[LogicalPlan](
        LogicalPlan.aggregate(ExprArray(), aggs^, _named_scan(rel))
    )

def build_bivar_agg_plan(
    up: String, rel_x: BoundRelation, rel_y: BoundRelation
) raises -> Optional[LogicalPlan]:
    """★ `SCAN(<named table>) -> AGGREGATE(<bivariate agg>)` — the plan a
    BIVARIATE Excel aggregate (`CORREL` / `PEARSON` / `COVAR` / `COVARIANCE.P`
    / `COVARIANCE.S` / `SLOPE` / `INTERCEPT` / `RSQ`) denotes over two bound
    columns, with NO `EngineContext` in the signature.

    ⚠⚠ `rel_x` IS THE FORMULA'S **FIRST** ARGUMENT AND IT IS NOT THE `x` OF
    `AggExpr`'s CHILD SLOTS. Excel writes `SLOPE(known_ys, known_xs)`,
    dependent first, and slot 0 is the INDEPENDENT variable; the body swaps and
    says why at length. The parameter names are Excel's, kept because that is
    the order a caller writes.

    ★★ THE WHOLE CHANGE WAS A NAME. `AGG_CORR` already had every layer it
    needs: a plan-IR tag (`agg_expr.mojo`), a plan-wire vocabulary member
    (wire 10, so no vocabulary bump), a SQL binding (`corr`) and — since the a NULL-semantics change, 2026-09-01) — a working **0-KEY** executor arm, which
    is the one this plan uses and which RAISED before that change. Excel simply
    had no name pointing at it. That is the same finding MEDIAN / STDEV / VAR /
    COUNTA were on 2026-09-04, one layer over.

    ⚠ ONE SCAN LEAF, SO ONE TABLE. The two columns are paired by ROW, which is
    what Excel's positional pairing means over a table; two different catalog
    tables would have no row correspondence at all. The caller enforces it
    (`same_relation`) for the same reason `_build_cond_agg` does.

    ⚠ **THE SIGNATURE IS THE CLAIM** — no context parameter, asserted at
    COMPILE time by `test_build_bivar_agg_plan_needs_no_engine_constructed_at_all`.

    Returns None when either range carries no COLUMN selector — a correlation
    of a whole 2D range against another has no meaning here — or when `up` is
    not the bivariate name."""
    var func_opt = _bivariate_agg_func(xl_plan_agg_tag(up))
    if not func_opt:
        return Optional[LogicalPlan]()
    if not rel_x.has_column() or not rel_y.has_column():
        return Optional[LogicalPlan]()
    var func = func_opt.value()
    if not agg_is_bivariate(func):
        # ⛔ A DEFECT IN THIS BUILD, NOT IN THE FORMULA, AND IT IS CHEAP TO
        # CATCH HERE. `agg_is_bivariate` is `agg_expr.mojo`'s own authority on
        # which `AGG_*` codes fold TWO columns through `CorrelationState`; its
        # docstring records what happens without it — *"a twelfth bivariate
        # added against those six would have compiled, bound, planned, and then
        # folded as a UNIVARIATE aggregate over slot 0 with slot 1 silently
        # discarded."* `_bivariate_agg_func` maps an Excel tag onto one of
        # those codes by hand; this is the one line that says the hand was
        # right, and a mapping onto (say) `AGG_MEAN` would otherwise produce a
        # plausible number with the second column thrown away.
        raise Error(
            "`" + up + "` maps to AGG code " + String(Int(func)) + ", which"
            " `agg_is_bivariate` does not recognise as bivariate. The"
            " XLA_* -> AGG_* arm in `_bivariate_agg_func` is wrong: a"
            " univariate code here would fold slot 0 and DISCARD the second"
            " column. This is a defect in the build, not in the formula."
        )
    # ⛔⛔ THE TWO ARGUMENTS ARE **SWAPPED** INTO THE CHILD SLOTS, AND A
    # PASS-THROUGH HERE WOULD BE A WRONG ANSWER UNDER A RIGHT-LOOKING NAME.
    #
    # Microsoft publishes SLOPE / INTERCEPT / RSQ as `F(known_ys, known_xs)` —
    # DEPENDENT FIRST — so `rel_x` (this function's first argument, and the
    # formula's) is y and `rel_y` is x. The `AggExpr` CHILD SLOTS are the other
    # way round: `agg_extended_grouped._ext_finalize` states it outright —
    # *"slot 0 — the one `update_bivariate` receives as `x` — is the SQL
    # independent variable"* — which is why `st.corr.Sx` is `regr_sxx` and
    # `st.corr.mean_x` is `regr_avgx`. `sql_binder` does the same swap for the
    # same reason (`args[1] = the INDEPENDENT variable -> child slot 0`).
    #
    # ⇒ child 0 = `rel_y.column` (Excel's known_xs), child 1 = `rel_x.column`
    # (Excel's known_ys). Getting this backwards answers `C / Sy` instead of
    # `C / Sx`: a real number of a plausible magnitude, from a well-formed
    # plan, which no recognition cell can see.
    #
    # ⚠ `AggExpr(func, child0, child1, None)` IS THE SAME SHAPE `agg_corr`
    # BUILDS. It is spelled out here rather than through a per-name constructor
    # because `agg_expr.mojo` has a constructor for `corr` and for none of the
    # other five — `sql_binder` builds them the same way, from the tag.
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(
            func,
            col(rel_y.column).copy_expr(),
            col(rel_x.column).copy_expr(),
            None,
        )
    )
    return Optional[LogicalPlan](
        LogicalPlan.aggregate(ExprArray(), aggs^, _named_scan(rel_x))
    )
