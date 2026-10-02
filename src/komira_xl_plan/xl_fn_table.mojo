# =============================================================================
# xl_fn_table.mojo — ★ THE AUTHORITATIVE EXCEL FUNCTION TABLE. ONE ROW PER
#                      NAME, ONE FILE, AND IT IS READABLE FROM OUTSIDE.
# =============================================================================
#
# ============ ⚠⚠ THE TWO ENVELOPES ARE DIFFERENT AND THAT IS A FACT, NOT A BUG
#
# `reach` is a BITMASK because a name is not simply "supported". Three surfaces
# recognise Excel names and they recognise DIFFERENT SETS, for reasons that are
# properties of the engine and not of this table:
#
#   XLR_PLAN        `build_xl_plan` — the ctx-free builder the C door
#                   (`komira_xl_bind`/`_render`/`_stream`) and the wire
#                   producer drive. Its terminal is `ctx.materialize_plan`, the
#                   GENERAL walker, which serves every aggregate the plan IR
#                   carries. This is the column that can widen today.
#
# ⇒ MEDIAN / STDEV / VAR / COUNTA carry `XLR_PLAN` and NOT `XLR_INLINE_REL`, and
# the asymmetry is stated HERE, in the row, rather than being an accident of
# which of four ladders someone remembered to edit.
#
# =================== ⚠ WHAT THIS FILE MAY NOT IMPORT ========================
#
# This module imports EXACTLY ONE THING, its own prose (`.xl_fn_notes`),
# which itself imports nothing. ⚠ IT USED TO IMPORT NOTHING AT ALL, and the
# 2026-09-04 notes split is the only reason that sentence changed: the pair
# is still a leaf of the import graph, which is the property the old line was
# actually claiming. Nothing else may be added.
#
# Encapsulation rule : POD rows and values only.
# =============================================================================


# =============================================================================
# `reach` — WHICH dispatch surface recognises the name. A BITMASK.
# =============================================================================
comptime XLR_SCALAR: UInt8 = 1
"""Has a row in the runtime `FnRegistry` (the scalar evaluator), which lives in
the scalar evaluator. ⚠ THIS REACH IS DRIVABLE FROM A NON-MOJO HOST as of ABI 11
(`komira_xl_eval`), and most of this table's rows carry it and nothing else.

⚠ RECOGNISED IS NOT EXECUTABLE, AND FOUR ROWS TURN ON THE DIFFERENCE. A
`rel_fn_descriptor` row (XLOOKUP / VLOOKUP / MATCH / INDEX, and the REL class
generally) is in the registry — so the scalar door answers it rather than
`#NAME?` — but its thunk needs a bound relation and an engine, which a ctx-free
door has not got. Those four carry `XLR_SCALAR | XLR_INLINE_REL` and no
`XLR_PLAN`, and they are the gap between the two ceiling figures."""

comptime XLR_INLINE_REL: UInt8 = 2
"""Recognised by the evaluator's relational lowering — the ENGINE-backed relational path."""

comptime XLR_PLAN: UInt8 = 4
"""Recognised by `komira_xl_plan.build_xl_plan` — the ctx-free plan builder,
reached from a non-Mojo host through `komira_xl_render` / `_stream`.
restated HERE and not only at the reader."""


# =============================================================================
# `family` — for the census reader, not for dispatch.
# =============================================================================
comptime XLF_LOGICAL: UInt8 = 0
comptime XLF_TEXT: UInt8 = 1
comptime XLF_DATE: UInt8 = 2
comptime XLF_AGG: UInt8 = 3
comptime XLF_CONDAGG: UInt8 = 4
comptime XLF_LOOKUP: UInt8 = 5
comptime XLF_DYNARRAY: UInt8 = 6
comptime XLF_BIVAR_AGG: UInt8 = 9
"""A BIVARIATE aggregate — one that consumes TWO columns (2026-09-04). ⚠ ITS
OWN FAMILY BECAUSE THE FAMILY IS THE ARM SELECTOR: `_build_rel_agg` reads
exactly one relation argument and `_agg_expr_for_name` builds a unary
`AggExpr`, so a bivariate name routed there is refused for its arity. See
`xl_plan_family`."""
comptime XLF_MATH: UInt8 = 7
"""Numeric scalar functions (2026-09-04). ⚠ SEPARATE FROM `XLF_AGG`: an
aggregate consumes ROWS, these consume ARGUMENT VALUES. `SUM` and `PRODUCT`
look like siblings and are not — `SUM` has a plan-IR tag and a relational
form; `PRODUCT` has neither."""
comptime XLF_FINANCIAL: UInt8 = 10
"""The time-value-of-money family (2026-09-14). ⚠ SEPARATE FROM `XLF_MATH`
AND THE DISTINCTION IS NOT COSMETIC: a math kernel is wrong in a way a reader
notices, and a financial one is not. `PMT` with the sign convention inverted,
`DB` without its documented three-decimal rate rounding and `DDB` without its
salvage clip each return a number of the right sign and the right magnitude,
so the family is tagged separately to say that its grading bar is different —
every row here earns a VALUE cell at an input where a plausible-but-wrong
kernel diverges, never a recognition cell."""
comptime XLF_STAT: UInt8 = 11
"""The statistical DISTRIBUTION family (2026-09-14).

⚠ 11 AND NOT 10, AND THE RENUMBER IS A LANDING FACT WORTH RECORDING: this
family and `XLF_FINANCIAL` were authored the same day in two worktrees and
BOTH CHOSE 10. Nothing in Starlark or Mojo would have caught it — two rows
would simply have rendered the same family name through
`komira_xl_functions`, and the census would have called every distribution
"financial". A family code is a wire value; pick the next FREE one by reading
this block, never by counting the entries. ⚠ SEPARATE FROM
`XLF_MATH` because the census reader's question is different: a math row's
risk is a rounding rule, a stat row's risk is that **the wrong answer is still
a probability**. `CHISQ.DIST` and `CHISQ.DIST.RT` both return a number in
[0,1] for the same arguments, so the family label is what tells a caller
which rows need a VALUE check rather than a recognition check.

⚠ IT IS NOT AN ARM SELECTOR. Every row carrying it is `XLR_SCALAR` only, so
`xl_plan_family` never returns it — the RANGE statistics that WOULD need a
plan arm are refused by name in `xl_absent_common_names`, for want of an array
kind in `FormulaValue`."""

comptime XLF_ENGINEERING: UInt8 = 12
"""The ENGINEERING category (2026-09-14).

⚠ 12, THE NEXT FREE CODE READ OFF THIS BLOCK — never a count of the entries.
`XLF_FINANCIAL` and `XLF_STAT` were authored the same day in two worktrees and
BOTH CHOSE 10; nothing in Starlark or Mojo would have caught it, and the census
would have printed one family name for two families.

⚠ SEPARATE FROM `XLF_MATH` because the census reader's question is different
again. A math row's risk is a rounding rule and a stat row's risk is that the
wrong answer is still a probability; an ENGINEERING row's risk is a **WIDTH** —
the naive kernel is exactly right over most of the domain and silently wrong at
one boundary. `HEX2DEC("FFFFFFFF")` is +4294967295 and `HEX2DEC("FFFFFFFFFF")`
is -1; a 32-bit kernel agrees with this one on every literal shorter than nine
digits. The family label is what tells a caller these rows need a cell AT THE
BOUNDARY rather than at 1+1.

⚠ IT IS NOT AN ARM SELECTOR. Every row carrying it is `XLR_SCALAR` only, so
`xl_plan_family` never returns it: these are functions of NUMBERS and TEXT and
they name no relation, so `build_xl_plan` refuses them `XL_BUILD_NO_PLAN` by
construction."""

comptime XLF_INFO: UInt8 = 8
"""The `IS*` predicates and `NA()` (2026-09-04). ⚠ SEPARATE FROM
`XLF_LOGICAL` because the whole family is `ERRH_MANUAL` — it INSPECTS error
values rather than propagating them, which is the opposite of every logical
function's error class."""


def xl_family_name(f: UInt8) -> String:
    """A family code's printable name. ⚠ TOTAL, and the fallback names the
    DEFECT rather than inventing a family — an unrecognised code is a bug in
    this build, not a new kind of function."""
    if f == XLF_LOGICAL:
        return String("logical")
    if f == XLF_TEXT:
        return String("text")
    if f == XLF_DATE:
        return String("date")
    if f == XLF_AGG:
        return String("agg")
    if f == XLF_CONDAGG:
        return String("condagg")
    if f == XLF_LOOKUP:
        return String("lookup")
    if f == XLF_DYNARRAY:
        return String("dynarray")
    if f == XLF_MATH:
        return String("math")
    if f == XLF_INFO:
        return String("info")
    if f == XLF_BIVAR_AGG:
        return String("bivar_agg")
    if f == XLF_FINANCIAL:
        return String("financial")
    if f == XLF_STAT:
        return String("stat")
    if f == XLF_ENGINEERING:
        return String("engineering")
    return String("UNRECOGNISED-FAMILY")


# =============================================================================
# `agg_tag` — the plan-time aggregate a REL-capable name denotes.
#
# ⚠ LOCAL CODES. `rel_agg_build._agg_expr_for_name` is the ONE mapping onto
# `komira_core.plan.agg_expr`'s `AGG_*`; see this file's header for why the
# import may not happen here.
# =============================================================================
comptime XLA_NONE: UInt8 = 0
comptime XLA_SUM: UInt8 = 1
comptime XLA_COUNT: UInt8 = 2
comptime XLA_MIN: UInt8 = 3
comptime XLA_MAX: UInt8 = 4
comptime XLA_MEAN: UInt8 = 5
comptime XLA_MEDIAN: UInt8 = 6
comptime XLA_STDDEV_SAMP: UInt8 = 7
comptime XLA_VAR_SAMP: UInt8 = 8
comptime XLA_CORR: UInt8 = 10
"""CORREL — the bivariate Pearson correlation, `AGG_CORR`. ⚠ THE ONLY TAG
`rel_agg_build._agg_expr_for_name` REFUSES TO BUILD: that function makes unary
aggregates, and this one has two children. `build_bivar_agg_plan` owns it."""

comptime XLA_COUNT_NONBLANK: UInt8 = 9
"""COUNTA — the count of NON-BLANK cells, i.e. `count(<col>)`, as distinct from
`XLA_COUNT`'s selector-less `count(*)`. See `_XL_COUNT_NOTE`."""

# =============================================================================
#
# ⚠ 11..15 READ OFF THIS BLOCK, NEVER COUNTED FROM THE ENTRIES. `XLA_CORR` is
# 10 and `XLA_COUNT_NONBLANK` is 9, so the list is NOT in numeric order and a
# count of the `comptime` lines would have reused 11 for two tags. The same
# collision `XLF_FINANCIAL`/`XLF_STAT` hit on 2026-09-14, one enum over.
#
# ⚠ EVERY ONE IS BIVARIATE, so `_agg_expr_for_name` — which builds UNARY
# aggregates from one column name — REFUSES all five by raising, exactly as it
# does for `XLA_CORR`. `build_bivar_agg_plan` is their builder and
# `XLF_BIVAR_AGG` is what routes them there.
# =============================================================================
comptime XLA_COVAR_POP: UInt8 = 11
"""COVARIANCE.P and the legacy COVAR — `covar_pop(y, x)` = C / n. ⛔ NOT an
alias of `XLA_COVAR_SAMP`; see `_covar_divisor_note`."""

comptime XLA_COVAR_SAMP: UInt8 = 12
"""COVARIANCE.S — `covar_samp(y, x)` = C / (n - 1)."""

comptime XLA_REGR_SLOPE: UInt8 = 13
"""SLOPE(known_ys, known_xs) — `regr_slope(y, x)` = C / Sx. ⚠ The argument
order is the same on both sides, DEPENDENT FIRST; see `_regr_arg_order_note`."""

comptime XLA_REGR_INTERCEPT: UInt8 = 14
"""INTERCEPT(known_ys, known_xs) — `regr_intercept(y, x)`."""

comptime XLA_REGR_R2: UInt8 = 15
"""RSQ(known_ys, known_xs) — `regr_r2(y, x)`, the SQUARE of Pearson's r. ⚠
Symmetric in its two arguments, so it is the one member of this family whose
value cell cannot discriminate argument order."""


# =============================================================================
# The row.
# =============================================================================
@fieldwise_init
struct XlFnRow(Copyable, Movable):
    """One Excel function name, and everything the census needs to say about it.

    `canonical` is UPPER-CASED — every dispatch site upper-cases before looking
    up, because a sheet sends whatever the user typed."""

    var canonical: String
    var family: UInt8
    var min_arity: UInt8
    var max_arity: UInt8
    """255 is the VARIADIC sentinel, matching `FnDescriptor.max_arity`."""
    var reach: UInt8
    var agg_tag: UInt8
    var note: String
    """Why the row is shaped as it is — a semantics divergence, a blocked
    widening, or empty. ⛔ NEVER A TODO: an empty note means "nothing to say",
    and a note that has gone stale is a lie the census prints."""

    def copy(self) -> Self:
        return Self(
            self.canonical.copy(),
            self.family,
            self.min_arity,
            self.max_arity,
            self.reach,
            self.agg_tag,
            self.note.copy(),
        )

    @always_inline
    def reaches(self, bit: UInt8) -> Bool:
        return (self.reach & bit) != UInt8(0)

    @always_inline
    def arity_ok(self, n: Int) -> Bool:
        if n < Int(self.min_arity):
            return False
        if self.max_arity == UInt8(255):
            return True
        return n <= Int(self.max_arity)


# =============================================================================
# THE NOTES — moved to `xl_fn_notes.mojo` on 2026-09-04.
#
# ⚠ THIS FILE PASSED 946 LINES WITH THE PROSE AT ROUGHLY 40% OF IT, so the
# notes moved to a sibling that imports nothing, exactly as this one does. The
# move was byte-identical; every note's own history stayed readable.
#
# ⛔ AND THE IMPORT LIST IS WHERE A DEAD NOTE BECOMES VISIBLE. Measured while
# splitting, 2026-09-04: `_plan_only_note` and `_scalar_only_note` were DEFINED,
# were named by BANNER COMMENTS in this file ("`_scalar_only_note` SAYS WHY IN
# THE ROW"), and were attached to ZERO rows — so the source claimed an
# explanation the rendered TSV did not contain. Both are attached now, and
# `test_every_defined_note_is_attached_to_some_row` walks `xl_all_notes()`
# against the rendered census so the next one REDs instead of shipping.
# =============================================================================
from .xl_fn_notes import (
    _address_note,
    _devsq_note,
    _nonarith_mean_note,
    _population_moment_note,
    _shape_moment_note,
    _acot_note,
    _also,
    _arabic_note,
    _atan2_note,
    _base_note,
    _base_width_note,
    _betadist_note,
    _bivar_unbound_note,
    _betainv_note,
    _beta_rescale_note,
    _binom_range_note,
    _bitwise_domain_note,
    _ceiling_note,
    _char_note,
    _complex_form_note,
    _chidist_note,
    _chiinv_note,
    _choose_note,
    _clean_note,
    _code_note,
    _combin_note,
    _combina_note,
    _compat_rename_note,
    _concatenate_note,
    _condif_note,
    _confidence_note,
    _condifs_note,
    _correl_note,
    _covar_divisor_note,
    _datevalue_note,
    _daycount_security_note,
    _days360_note,
    _count_note,
    _counta_note,
    _days_note,
    _decimal_note,
    _dist_inv_note,
    _dist_tail_note,
    _dynarray_note,
    _edate_note,
    _encodeurl_note,
    _error_type_note,
    _even_odd_note,
    _erf_arity_note,
    _exact_note,
    _exp_note,
    _annuity_note,
    _fact_note,
    _factdouble_note,
    _fdist_note,
    _filter_note,
    _finv_note,
    _gcd_lcm_note,
    _hyperlink_note,
    _hypgeomdist_note,
    _gamma_fn_note,
    _gammaln_note,
    _int_note,
    _hypgeom_note,
    _inverse_hyperbolic_note,
    _iso_ceiling_note,
    _inverse_trig_note,
    _isblank_note,
    _iserr_note,
    _isnontext_note,
    _isoweeknum_note,
    _istype_note,
    _log_domain_note,
    _log_note,
    _logical_constant_note,
    _lognormdist_note,
    _median_note,
    _mod_note,
    _mround_note,
    _multinomial_note,
    _n_fn_note,
    _negbinomdist_note,
    _norminv_category_note,
    _normsdist_note,
    _norm_dist_note,
    _norm_s_dist_note,
    _now_note,
    _parity_note,
    _pearson_note,
    _permut_note,
    _plan_only_note,
    _precise_round_note,
    _product_note,
    _quotient_note,
    _radians_note,
    _regr_arg_order_note,
    _rate_not_mean_note,
    _reciprocal_trig_note,
    _rept_note,
    _resident_note,
    _roman_note,
    _round_note,
    _sample_stat_note,
    _cum_note,
    _db_rate_rounding_note,
    _ddb_clip_note,
    _dollar_fraction_note,
    _effect_nominal_note,
    _ipmt_ppmt_note,
    _ispmt_note,
    _npv_note,
    _rate_solver_note,
    _rri_pduration_note,
    _sln_syd_note,
    _scalar_only_note,
    _search_note,
    _special_fn_note,
    _stat_scalar_note,
    _sqrtpi_note,
    _sumsq_note,
    _t_fn_note,
    _tdist_note,
    _textba_note,
    _time_note,
    _timevalue_note,
    _time_of_day_note,
    _tinv_note,
    _trunc_note,
    _type_note,
    _unichar_note,
    _unicode_note,
    _valuetotext_note,
    _volatile_note,
    _weekday_note,
    _xor_note,
    _yearfrac_note,
    _odf_only_note,
    _maxifs_note,
)

# =============================================================================
# ★★★ THE TABLE. THE CENSUS IS THIS FUNCTION.
# =============================================================================
#
# ⚠ ARITY IS THE **BROADEST** FORM'S, and for the aggregate family that is the
# scalar-over-args one (`SUM(1,2,3)`). The PLAN path takes EXACTLY ONE relation
# argument for every aggregate — `xl_plan_build._build_rel_agg` refuses more,
# because `SUM(a, b)` is a sum of ADDENDS, a scalar expression and not one
# plan. One arity column cannot carry both, so it carries the registry's and
# this paragraph carries the other.
#
# ⚠ A NAME'S ABSENCE FROM THIS TABLE IS A CLAIM. `MEDIAN` was absent from every
# Excel dispatch site in the tree while `AGG_MEDIAN` had a plan-IR tag, a wire
# vocabulary member, a 0-key executor arm and a SQL binding — reachable at
# every layer and unbound at exactly one. So the gap census has to be run over
# the NAME space, not the OP space; `xl_absent_common_names` below is that
# census, written down rather than re-derived.
#
# ⚠ IT ALLOCATES. ~40 rows of two `String`s each, built per call. Every caller
# is once-per-formula (a build) or once-per-process (the census render), and
# the alternative is the four hand-copied ladders this file replaced. If a hot
# path ever needs it, cache it on the caller — do NOT re-spell the set.
def xl_function_table() -> List[XlFnRow]:
    """★ EVERY EXCEL FUNCTION NAME THIS ENGINE RECOGNISES ANYWHERE, with the
    surface that recognises it. THE authoritative list."""
    var t = List[XlFnRow]()
    var none = String("")

    # ---- logical (scalar registry: fn_scalar_core.register_scalar_core) -----
    t.append(XlFnRow(String("IF"), XLF_LOGICAL, 2, 3, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("IFS"), XLF_LOGICAL, 2, 255, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("AND"), XLF_LOGICAL, 1, 255, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("OR"), XLF_LOGICAL, 1, 255, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("NOT"), XLF_LOGICAL, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("IFERROR"), XLF_LOGICAL, 2, 2, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("IFNA"), XLF_LOGICAL, 2, 2, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("XOR"), XLF_LOGICAL, 1, 255, XLR_SCALAR, XLA_NONE, _xor_note()))
    t.append(XlFnRow(String("CHOOSE"), XLF_LOGICAL, 2, 255, XLR_SCALAR, XLA_NONE, _choose_note()))
    # ---- ⭐ THE TWO LOGICAL CONSTANTS (2026-09-14) -------------------------
    # ⛔ THESE WERE A **PARSE ERROR**, NOT A `#NAME?`, AND THE DIFFERENCE IS
    # THE WHOLE FINDING. `formula_parser` folded the identifiers TRUE and FALSE
    # to boolean literals BEFORE testing for the `(` that makes an identifier a
    # call, so `=TRUE()` — Excel's own documented spelling — left the parens
    # unconsumed and raised out of the C door. See `_logical_constant_note`.
    t.append(XlFnRow(String("TRUE"), XLF_LOGICAL, 0, 0, XLR_SCALAR, XLA_NONE, _logical_constant_note()))
    t.append(XlFnRow(String("FALSE"), XLF_LOGICAL, 0, 0, XLR_SCALAR, XLA_NONE, _logical_constant_note()))

    # ---- text ---------------------------------------------------------------
    t.append(XlFnRow(String("LEN"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("LEFT"), XLF_TEXT, 1, 2, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("RIGHT"), XLF_TEXT, 1, 2, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("MID"), XLF_TEXT, 3, 3, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("TRIM"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("CONCAT"), XLF_TEXT, 1, 255, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("TEXTJOIN"), XLF_TEXT, 3, 255, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("SUBSTITUTE"), XLF_TEXT, 3, 4, XLR_SCALAR, XLA_NONE, none.copy()))
    # ---- ⭐ text breadth (2026-09-04; kernels in xl_scalar_text) ------------
    t.append(XlFnRow(String("UPPER"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("LOWER"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("PROPER"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("FIND"), XLF_TEXT, 2, 3, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("SEARCH"), XLF_TEXT, 2, 3, XLR_SCALAR, XLA_NONE, _search_note()))
    t.append(XlFnRow(String("REPLACE"), XLF_TEXT, 4, 4, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("EXACT"), XLF_TEXT, 2, 2, XLR_SCALAR, XLA_NONE, _exact_note()))
    t.append(XlFnRow(String("VALUE"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("REPT"), XLF_TEXT, 2, 2, XLR_SCALAR, XLA_NONE, _rept_note()))
    t.append(XlFnRow(String("CHAR"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, _char_note()))
    t.append(XlFnRow(String("CODE"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, _code_note()))
    t.append(XlFnRow(String("CLEAN"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, _clean_note()))
    t.append(XlFnRow(String("T"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, _t_fn_note()))
    t.append(XlFnRow(String("N"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, _n_fn_note()))
    t.append(XlFnRow(String("CONCATENATE"), XLF_TEXT, 1, 255, XLR_SCALAR, XLA_NONE, _concatenate_note()))
    t.append(XlFnRow(String("UNICHAR"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, _unichar_note()))
    t.append(XlFnRow(String("UNICODE"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, _unicode_note()))

    t.append(XlFnRow(String("TEXTBEFORE"), XLF_TEXT, 2, 6, XLR_SCALAR, XLA_NONE, _textba_note()))
    t.append(XlFnRow(String("TEXTAFTER"), XLF_TEXT, 2, 6, XLR_SCALAR, XLA_NONE, _textba_note()))
    t.append(XlFnRow(String("VALUETOTEXT"), XLF_TEXT, 1, 2, XLR_SCALAR, XLA_NONE, _valuetotext_note()))
    t.append(XlFnRow(String("ADDRESS"), XLF_LOOKUP, 2, 5, XLR_SCALAR, XLA_NONE, _address_note()))
    t.append(XlFnRow(String("HYPERLINK"), XLF_LOOKUP, 1, 2, XLR_SCALAR, XLA_NONE, _hyperlink_note()))

    t.append(XlFnRow(String("ROUND"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _also(_round_note(), _scalar_only_note())))
    t.append(XlFnRow(String("ROUNDUP"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("ROUNDDOWN"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("ABS"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("INT"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_int_note(), _scalar_only_note())))
    t.append(XlFnRow(String("SIGN"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("MOD"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_mod_note(), _scalar_only_note())))
    t.append(XlFnRow(String("POWER"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("SQRT"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("CEILING"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_ceiling_note(), _scalar_only_note())))
    t.append(XlFnRow(String("FLOOR"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_ceiling_note(), _scalar_only_note())))
    t.append(XlFnRow(String("PRODUCT"), XLF_MATH, 1, 255, XLR_SCALAR, XLA_NONE, _also(_product_note(), _scalar_only_note())))

    # ---- ⭐⭐ THE NUMERIC WAVE (2026-09-04; kernels in xl_scalar_numeric) ---
    # ★ TWENTY-ONE NAMES THE CENSUS WAS NOT ABLE TO SAY IT DID NOT HAVE. They
    # were in NEITHER the 83 rows NOR the 16 stated absences, so a non-Mojo
    # caller asking `komira_xl_functions` "does this engine do LN?" got no
    # answer at all — which is a different and worse thing than getting `no`.
    # ⛔ AND `test_no_absent_name_resolves` COULD NOT REPORT IT: it only REDs on
    # GOOD news (a listed name that starts resolving), so a name nobody wrote
    # down was invisible to the one instrument that walks what was written down.
    t.append(XlFnRow(String("EXP"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_exp_note(), _scalar_only_note())))
    t.append(XlFnRow(String("LN"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_log_domain_note(), _scalar_only_note())))
    t.append(XlFnRow(String("LOG10"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_log_domain_note(), _scalar_only_note())))
    t.append(XlFnRow(String("LOG"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _also(_log_note(), _log_domain_note())))
    t.append(XlFnRow(String("PI"), XLF_MATH, 0, 0, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("TRUNC"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _also(_trunc_note(), _scalar_only_note())))
    t.append(XlFnRow(String("EVEN"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_even_odd_note(), _scalar_only_note())))
    t.append(XlFnRow(String("ODD"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_even_odd_note(), _scalar_only_note())))
    t.append(XlFnRow(String("QUOTIENT"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_quotient_note(), _scalar_only_note())))
    # ---- trigonometry. ⚠ RADIANS THROUGHOUT, and ONE argument-order trap.
    t.append(XlFnRow(String("SIN"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _radians_note()))
    t.append(XlFnRow(String("COS"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _radians_note()))
    t.append(XlFnRow(String("TAN"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _radians_note()))
    t.append(XlFnRow(String("ASIN"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _inverse_trig_note()))
    t.append(XlFnRow(String("ACOS"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _inverse_trig_note()))
    t.append(XlFnRow(String("ATAN"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _radians_note()))
    # ⛔ THE ONE ROW IN THIS FILE WHOSE NOTE IS LOAD-BEARING FOR CORRECTNESS
    # RATHER THAN FOR DOCUMENTATION. Excel is ATAN2(x, y); libm and this repo's
    # own SQL `atan2` are atan2(y, x). Swapped, and silently.
    t.append(XlFnRow(String("ATAN2"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _atan2_note()))
    t.append(XlFnRow(String("SINH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("COSH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("TANH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _scalar_only_note()))
    t.append(XlFnRow(String("DEGREES"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _radians_note()))
    t.append(XlFnRow(String("RADIANS"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _radians_note()))
    t.append(XlFnRow(String("GCD"), XLF_MATH, 1, 255, XLR_SCALAR, XLA_NONE, _gcd_lcm_note()))
    t.append(XlFnRow(String("LCM"), XLF_MATH, 1, 255, XLR_SCALAR, XLA_NONE, _gcd_lcm_note()))
    t.append(XlFnRow(String("MROUND"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _mround_note()))
    # ---- ⭐⭐ THE EXACT-ANSWER WAVE (2026-09-14; xl_scalar_exact.mojo) ------
    # ★ WHAT MAKES THESE NINE ONE GROUP IS THAT EVERY ONE HAS A SINGLE
    # EXACTLY-REPRESENTABLE ANSWER AND NEEDS NO TOLERANCE — which is exactly
    # what the fourteen TRANSCENDENTAL rows above do NOT have, and why those
    # are a declared exclusion from the scalar VALUE sweep. Every row below
    # earns a graded value cell.
    # ⛔ AND SIX OF THE NINE HAVE A PLAUSIBLE WRONG TWIN ALREADY IN THIS TABLE:
    # FACTDOUBLE->FACT, COMBINA->COMBIN, CEILING.PRECISE->CEILING,
    # FLOOR.PRECISE->FLOOR, DECIMAL->a radix-blind parser, BASE->a lower-case
    # renderer. Each note names the input that separates the pair, and the
    # oracle carries that input as a `#pair` with its blind cell.
    t.append(XlFnRow(String("FACT"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_fact_note(), _scalar_only_note())))
    t.append(XlFnRow(String("FACTDOUBLE"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_factdouble_note(), _scalar_only_note())))
    t.append(XlFnRow(String("COMBIN"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_combin_note(), _scalar_only_note())))
    t.append(XlFnRow(String("COMBINA"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_combina_note(), _scalar_only_note())))
    t.append(XlFnRow(String("SUMSQ"), XLF_MATH, 1, 255, XLR_SCALAR, XLA_NONE, _also(_sumsq_note(), _scalar_only_note())))
    t.append(XlFnRow(String("BASE"), XLF_MATH, 2, 3, XLR_SCALAR, XLA_NONE, _also(_base_note(), _scalar_only_note())))
    t.append(XlFnRow(String("DECIMAL"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_decimal_note(), _scalar_only_note())))
    t.append(XlFnRow(String("CEILING.PRECISE"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _also(_precise_round_note(), _scalar_only_note())))
    t.append(XlFnRow(String("FLOOR.PRECISE"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _also(_precise_round_note(), _scalar_only_note())))
    #
    # ⚠ THE SIX RECIPROCAL ROWS SHARE ONE NOTE AND SPLIT ON THE ERROR CLASS:
    # SEC / SECH are TOTAL (cos and cosh have no exact zero); CSC / CSCH /
    # COT / COTH are `#DIV/0!` at 0. That split is the whole content of the
    # family, which is why one note carries all six.
    t.append(XlFnRow(String("SEC"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _reciprocal_trig_note()))
    t.append(XlFnRow(String("CSC"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _reciprocal_trig_note()))
    t.append(XlFnRow(String("COT"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _reciprocal_trig_note()))
    t.append(XlFnRow(String("SECH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _reciprocal_trig_note()))
    t.append(XlFnRow(String("CSCH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _reciprocal_trig_note()))
    t.append(XlFnRow(String("COTH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _reciprocal_trig_note()))
    # ⛔ ACOT HAS ITS OWN NOTE AND NOT THE FAMILY'S, because its defect is a
    # BRANCH and not an error class: ATAN(1/x) is right for every positive
    # argument and wrong by exactly pi for every negative one.
    t.append(XlFnRow(String("ACOT"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _acot_note()))
    # ⚠ FOUR DOMAINS, NOT ONE. ASINH total, ACOSH x>=1, ATANH |x|<1, ACOTH
    # |x|>1 — and the last two are exact MIRRORS, so one note covers the set
    # precisely because the set is what a per-function note would lose.
    t.append(XlFnRow(String("ASINH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _inverse_hyperbolic_note()))
    t.append(XlFnRow(String("ACOSH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _inverse_hyperbolic_note()))
    t.append(XlFnRow(String("ATANH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _inverse_hyperbolic_note()))
    t.append(XlFnRow(String("ACOTH"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _inverse_hyperbolic_note()))
    # ---- the exact-answer strays. Each earns a graded VALUE cell.
    t.append(XlFnRow(String("SQRTPI"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_sqrtpi_note(), _scalar_only_note())))
    t.append(XlFnRow(String("MULTINOMIAL"), XLF_MATH, 1, 255, XLR_SCALAR, XLA_NONE, _also(_multinomial_note(), _scalar_only_note())))
    t.append(XlFnRow(String("ROMAN"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _roman_note()))
    t.append(XlFnRow(String("ARABIC"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _arabic_note()))
    # ⚠ ARITY 1..2, MATCHING `CEILING.PRECISE` WHOSE KERNEL IT LITERALLY IS.
    t.append(XlFnRow(String("ISO.CEILING"), XLF_MATH, 1, 2, XLR_SCALAR, XLA_NONE, _also(_iso_ceiling_note(), _scalar_only_note())))

    # =====================================================================
    #
    # ⛔⛔ "COMPATIBILITY" DOES NOT MEAN "ALIAS", AND THE COUNT IS THE
    # FINDING: ELEVEN of these twenty-four return a DIFFERENT NUMBER from
    # their 2010 replacement at the same arguments. CHIDIST / CHIINV /
    # FDIST / FINV are RIGHT-tailed where the undotted modern name is the
    # LEFT tail; TINV is TWO-tailed where T.INV is one; TDIST carries a
    # `tails` selector AND refuses a negative x that T.DIST accepts;
    # BETADIST's optional bounds sit where BETA.DIST put `cumulative`; and
    # NORMSDIST / LOGNORMDIST / NEGBINOMDIST / HYPGEOMDIST have NO
    # `cumulative` argument at all. Wiring any of them to its modern twin
    # returns a plausible number of the right shape in the right range —
    # this effort's named vacuity, with a p-value attached.
    #
    # ⚠ THE THIRTEEN THAT ARE EXACT RENAMES SAY SO in `_compat_rename_note`
    # rather than carrying an empty note, because an empty note is
    # indistinguishable from an unchecked one.
    # =====================================================================
    # ---- the normal family ----------------------------------------------
    t.append(XlFnRow(String("NORMSDIST"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_normsdist_note(), _scalar_only_note())))
    t.append(XlFnRow(String("NORMSINV"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("NORMDIST"), XLF_MATH, 4, 4, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("NORM.INV"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_norminv_category_note(), _scalar_only_note())))
    t.append(XlFnRow(String("LOGNORMDIST"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_lognormdist_note(), _scalar_only_note())))
    t.append(XlFnRow(String("LOGINV"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("CONFIDENCE"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    # ---- the continuous distributions with a `cumulative` flag -----------
    t.append(XlFnRow(String("EXPONDIST"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("WEIBULL"), XLF_MATH, 4, 4, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("GAMMADIST"), XLF_MATH, 4, 4, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("GAMMAINV"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    # ---- ⛔ THE RIGHT-TAIL FAMILY ---------------------------------------
    t.append(XlFnRow(String("CHIDIST"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_chidist_note(), _scalar_only_note())))
    t.append(XlFnRow(String("CHIINV"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_chiinv_note(), _scalar_only_note())))
    t.append(XlFnRow(String("FDIST"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_fdist_note(), _scalar_only_note())))
    t.append(XlFnRow(String("FINV"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_finv_note(), _scalar_only_note())))
    t.append(XlFnRow(String("TDIST"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_tdist_note(), _scalar_only_note())))
    t.append(XlFnRow(String("TINV"), XLF_MATH, 2, 2, XLR_SCALAR, XLA_NONE, _also(_tinv_note(), _scalar_only_note())))
    # ---- the beta pair. ⚠ 3..5 — `A`/`B` are OPTIONAL BOUNDS and they sit
    #      where `BETA.DIST` put `cumulative`.
    t.append(XlFnRow(String("BETADIST"), XLF_MATH, 3, 5, XLR_SCALAR, XLA_NONE, _also(_betadist_note(), _scalar_only_note())))
    t.append(XlFnRow(String("BETAINV"), XLF_MATH, 3, 5, XLR_SCALAR, XLA_NONE, _also(_betainv_note(), _scalar_only_note())))
    # ---- the discrete family ---------------------------------------------
    t.append(XlFnRow(String("BINOMDIST"), XLF_MATH, 4, 4, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("NEGBINOMDIST"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_negbinomdist_note(), _scalar_only_note())))
    t.append(XlFnRow(String("HYPGEOMDIST"), XLF_MATH, 4, 4, XLR_SCALAR, XLA_NONE, _also(_hypgeomdist_note(), _scalar_only_note())))
    t.append(XlFnRow(String("POISSON"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("CRITBINOM"), XLF_MATH, 3, 3, XLR_SCALAR, XLA_NONE, _also(_compat_rename_note(), _scalar_only_note())))
    t.append(XlFnRow(String("ENCODEURL"), XLF_TEXT, 1, 1, XLR_SCALAR, XLA_NONE, _also(_encodeurl_note(), _scalar_only_note())))
    #
    # ⛔ THE SELECTION RULE IS STRICTER THAN THE REST OF THIS FILE'S, and the
    # reason is a property of the domain rather than of the code: a math
    # kernel is wrong in a way a reader notices and a financial one is not.
    # So the rule is not "the functions people ask for" — it is **the
    # functions whose answer can be graded EXACTLY against a published rule**.
    # `PMT` with the sign inverted, `DB` without its documented three-decimal
    # rate rounding and `DDB` without its salvage clip each return a number of
    # the right sign and the right magnitude.
    #
    # ⚠ ELEVEN OF THESE TWENTY-ONE ARE REARRANGEMENTS OF ONE EQUATION, which
    # is why they share `_annuity_note` — see it for the relation, the sign
    # convention, the `type` switch and the rate = 0 LIMIT arm that makes an
    # interest-free loan computable at all.
    t.append(XlFnRow(String("PV"), XLF_FINANCIAL, 3, 5, XLR_SCALAR, XLA_NONE, _also(_annuity_note(), _scalar_only_note())))
    t.append(XlFnRow(String("FV"), XLF_FINANCIAL, 3, 5, XLR_SCALAR, XLA_NONE, _also(_annuity_note(), _scalar_only_note())))
    t.append(XlFnRow(String("PMT"), XLF_FINANCIAL, 3, 5, XLR_SCALAR, XLA_NONE, _also(_annuity_note(), _scalar_only_note())))
    # ⚠ NPER'S SECOND ARGUMENT IS THE **PAYMENT** where every sibling's is
    # `nper`, because `nper` is what it solves for. A swap answers a plausible
    # number of periods for almost any input.
    t.append(XlFnRow(String("NPER"), XLF_FINANCIAL, 3, 5, XLR_SCALAR, XLA_NONE, _also(_annuity_note(), _scalar_only_note())))
    # ⭐ ARITY 3..6 — the SIXTH argument is `guess`, and it is load-bearing
    # rather than cosmetic: the residual can have several roots and the guess
    # is what SELECTS one. A 3..5 window would make the multi-root behaviour
    # unspellable through this door.
    t.append(XlFnRow(String("RATE"), XLF_FINANCIAL, 3, 6, XLR_SCALAR, XLA_NONE, _also(_rate_solver_note(), _scalar_only_note())))
    t.append(XlFnRow(String("IPMT"), XLF_FINANCIAL, 4, 6, XLR_SCALAR, XLA_NONE, _also(_ipmt_ppmt_note(), _scalar_only_note())))
    t.append(XlFnRow(String("PPMT"), XLF_FINANCIAL, 4, 6, XLR_SCALAR, XLA_NONE, _also(_ipmt_ppmt_note(), _scalar_only_note())))
    # ⚠ 6..6 ON BOTH, AND IT IS NOT A COPY OF IPMT'S WINDOW. `type` has NO
    # default on the cumulative pair; a 5-argument call is an arity refusal
    # rather than an assumed 0.
    t.append(XlFnRow(String("CUMIPMT"), XLF_FINANCIAL, 6, 6, XLR_SCALAR, XLA_NONE, _also(_cum_note(), _scalar_only_note())))
    t.append(XlFnRow(String("CUMPRINC"), XLF_FINANCIAL, 6, 6, XLR_SCALAR, XLA_NONE, _also(_cum_note(), _scalar_only_note())))
    t.append(XlFnRow(String("ISPMT"), XLF_FINANCIAL, 4, 4, XLR_SCALAR, XLA_NONE, _also(_ispmt_note(), _scalar_only_note())))
    # ⭐ NPV IS VARIADIC OVER LOOSE SCALARS AND THAT IS WHY IT IS HERE WHILE
    # IRR / MIRR / XIRR / XNPV / FVSCHEDULE ARE REFUSED: their published
    # signatures take an ARRAY OR RANGE, which this door cannot spell.
    t.append(XlFnRow(String("NPV"), XLF_FINANCIAL, 2, 255, XLR_SCALAR, XLA_NONE, _also(_npv_note(), _scalar_only_note())))
    # ---- rate conversion. Two inverse PAIRS, and each pair AGREES somewhere.
    t.append(XlFnRow(String("EFFECT"), XLF_FINANCIAL, 2, 2, XLR_SCALAR, XLA_NONE, _also(_effect_nominal_note(), _scalar_only_note())))
    t.append(XlFnRow(String("NOMINAL"), XLF_FINANCIAL, 2, 2, XLR_SCALAR, XLA_NONE, _also(_effect_nominal_note(), _scalar_only_note())))
    t.append(XlFnRow(String("RRI"), XLF_FINANCIAL, 3, 3, XLR_SCALAR, XLA_NONE, _also(_rri_pduration_note(), _scalar_only_note())))
    t.append(XlFnRow(String("PDURATION"), XLF_FINANCIAL, 3, 3, XLR_SCALAR, XLA_NONE, _also(_rri_pduration_note(), _scalar_only_note())))
    # ---- price notation. The fractional part is a NUMERATOR, not a decimal.
    t.append(XlFnRow(String("DOLLARDE"), XLF_FINANCIAL, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dollar_fraction_note(), _scalar_only_note())))
    t.append(XlFnRow(String("DOLLARFR"), XLF_FINANCIAL, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dollar_fraction_note(), _scalar_only_note())))
    # ---- depreciation. FOUR schedules, and TWO pairs that agree somewhere.
    t.append(XlFnRow(String("SLN"), XLF_FINANCIAL, 3, 3, XLR_SCALAR, XLA_NONE, _also(_sln_syd_note(), _scalar_only_note())))
    t.append(XlFnRow(String("SYD"), XLF_FINANCIAL, 4, 4, XLR_SCALAR, XLA_NONE, _also(_sln_syd_note(), _scalar_only_note())))
    t.append(XlFnRow(String("DB"), XLF_FINANCIAL, 4, 5, XLR_SCALAR, XLA_NONE, _also(_db_rate_rounding_note(), _scalar_only_note())))
    t.append(XlFnRow(String("DDB"), XLF_FINANCIAL, 4, 5, XLR_SCALAR, XLA_NONE, _also(_ddb_clip_note(), _scalar_only_note())))
    t.append(XlFnRow(String("ACCRINTM"), XLF_FINANCIAL, 4, 5, XLR_SCALAR, XLA_NONE, _also(_daycount_security_note(), _scalar_only_note())))
    t.append(XlFnRow(String("DISC"), XLF_FINANCIAL, 4, 5, XLR_SCALAR, XLA_NONE, _also(_daycount_security_note(), _scalar_only_note())))
    t.append(XlFnRow(String("INTRATE"), XLF_FINANCIAL, 4, 5, XLR_SCALAR, XLA_NONE, _also(_daycount_security_note(), _scalar_only_note())))
    t.append(XlFnRow(String("PRICEDISC"), XLF_FINANCIAL, 4, 5, XLR_SCALAR, XLA_NONE, _also(_daycount_security_note(), _scalar_only_note())))
    t.append(XlFnRow(String("RECEIVED"), XLF_FINANCIAL, 4, 5, XLR_SCALAR, XLA_NONE, _also(_daycount_security_note(), _scalar_only_note())))
    t.append(XlFnRow(String("YIELDDISC"), XLF_FINANCIAL, 4, 5, XLR_SCALAR, XLA_NONE, _also(_daycount_security_note(), _scalar_only_note())))
    t.append(XlFnRow(String("PRICEMAT"), XLF_FINANCIAL, 5, 6, XLR_SCALAR, XLA_NONE, _also(_daycount_security_note(), _scalar_only_note())))
    t.append(XlFnRow(String("YIELDMAT"), XLF_FINANCIAL, 5, 6, XLR_SCALAR, XLA_NONE, _also(_daycount_security_note(), _scalar_only_note())))
    #
    # ⛔⛔ AND THIS FAMILY IS THE WORST CASE IN THE WHOLE EXCEL SURFACE FOR THE
    # MIS-WIRING THIS CAMPAIGN IS NAMED FOR, BECAUSE **THE WRONG ANSWER IS
    # STILL A PROBABILITY**. CHISQ.DIST/CHISQ.DIST.RT, T.DIST.RT/T.DIST.2T,
    # F.INV/F.INV.RT, PHI/GAUSS and NORM.S.DIST's two arms all return a number
    # in [0,1] for the same arguments — so a range check, a finiteness check
    # and a loose tolerance all pass on the mis-wired row. THREE of the twins
    # are rows ALREADY IN THIS TABLE: `LN` (for GAMMALN), `FACT` (for GAMMA)
    # and `COMBIN` (for PERMUT).
    #
    # ⚠ ARITY IS A DISCRIMINATOR HERE AND NOT PAPERWORK: NORM.S.DIST is 2..2
    # where the legacy NORMSDIST is 1..1; every `.RT` drops the `cumulative`
    # argument its `.DIST` carries; BETA.DIST is 4..6 and BETA.INV 3..5.
    t.append(XlFnRow(String("GAMMALN"), XLF_STAT, 1, 1, XLR_SCALAR, XLA_NONE, _also(_gammaln_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("GAMMALN.PRECISE"), XLF_STAT, 1, 1, XLR_SCALAR, XLA_NONE, _also(_gammaln_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("GAMMA"), XLF_STAT, 1, 1, XLR_SCALAR, XLA_NONE, _also(_gamma_fn_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("PERMUT"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_permut_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("PERMUTATIONA"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_permut_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("FISHER"), XLF_STAT, 1, 1, XLR_SCALAR, XLA_NONE, _stat_scalar_note()))
    t.append(XlFnRow(String("FISHERINV"), XLF_STAT, 1, 1, XLR_SCALAR, XLA_NONE, _stat_scalar_note()))
    t.append(XlFnRow(String("STANDARDIZE"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _stat_scalar_note()))
    t.append(XlFnRow(String("NORM.S.DIST"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_norm_s_dist_note(), _special_fn_note())))
    t.append(XlFnRow(String("NORM.DIST"), XLF_STAT, 4, 4, XLR_SCALAR, XLA_NONE, _also(_norm_dist_note(), _special_fn_note())))
    t.append(XlFnRow(String("NORM.S.INV"), XLF_STAT, 1, 1, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _special_fn_note())))
    t.append(XlFnRow(String("NORMINV"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_norm_dist_note(), _dist_inv_note())))
    t.append(XlFnRow(String("PHI"), XLF_STAT, 1, 1, XLR_SCALAR, XLA_NONE, _also(_norm_s_dist_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("GAUSS"), XLF_STAT, 1, 1, XLR_SCALAR, XLA_NONE, _also(_norm_s_dist_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("LOGNORM.DIST"), XLF_STAT, 4, 4, XLR_SCALAR, XLA_NONE, _also(_norm_dist_note(), _special_fn_note())))
    t.append(XlFnRow(String("LOGNORM.INV"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _special_fn_note())))
    t.append(XlFnRow(String("EXPON.DIST"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_rate_not_mean_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("WEIBULL.DIST"), XLF_STAT, 4, 4, XLR_SCALAR, XLA_NONE, _also(_rate_not_mean_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("GAMMA.DIST"), XLF_STAT, 4, 4, XLR_SCALAR, XLA_NONE, _also(_rate_not_mean_note(), _special_fn_note())))
    t.append(XlFnRow(String("GAMMA.INV"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _special_fn_note())))
    t.append(XlFnRow(String("CHISQ.DIST"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_dist_tail_note(), _special_fn_note())))
    t.append(XlFnRow(String("CHISQ.DIST.RT"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dist_tail_note(), _special_fn_note())))
    t.append(XlFnRow(String("CHISQ.INV"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _dist_tail_note())))
    t.append(XlFnRow(String("CHISQ.INV.RT"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _dist_tail_note())))
    t.append(XlFnRow(String("POISSON.DIST"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_special_fn_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("BETA.DIST"), XLF_STAT, 4, 6, XLR_SCALAR, XLA_NONE, _also(_beta_rescale_note(), _special_fn_note())))
    t.append(XlFnRow(String("BETA.INV"), XLF_STAT, 3, 5, XLR_SCALAR, XLA_NONE, _also(_beta_rescale_note(), _dist_inv_note())))
    t.append(XlFnRow(String("T.DIST"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_dist_tail_note(), _special_fn_note())))
    t.append(XlFnRow(String("T.DIST.RT"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dist_tail_note(), _special_fn_note())))
    t.append(XlFnRow(String("T.DIST.2T"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dist_tail_note(), _special_fn_note())))
    t.append(XlFnRow(String("T.INV"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _dist_tail_note())))
    t.append(XlFnRow(String("T.INV.2T"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _dist_tail_note())))
    t.append(XlFnRow(String("F.DIST"), XLF_STAT, 4, 4, XLR_SCALAR, XLA_NONE, _also(_dist_tail_note(), _special_fn_note())))
    t.append(XlFnRow(String("F.DIST.RT"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_dist_tail_note(), _special_fn_note())))
    t.append(XlFnRow(String("F.INV"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _dist_tail_note())))
    t.append(XlFnRow(String("F.INV.RT"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_dist_inv_note(), _dist_tail_note())))
    t.append(XlFnRow(String("BINOM.DIST"), XLF_STAT, 4, 4, XLR_SCALAR, XLA_NONE, _also(_binom_range_note(), _special_fn_note())))
    t.append(XlFnRow(String("BINOM.DIST.RANGE"), XLF_STAT, 3, 4, XLR_SCALAR, XLA_NONE, _also(_binom_range_note(), _special_fn_note())))
    t.append(XlFnRow(String("BINOM.INV"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_binom_range_note(), _dist_inv_note())))
    t.append(XlFnRow(String("NEGBINOM.DIST"), XLF_STAT, 4, 4, XLR_SCALAR, XLA_NONE, _also(_binom_range_note(), _special_fn_note())))
    t.append(XlFnRow(String("HYPGEOM.DIST"), XLF_STAT, 5, 5, XLR_SCALAR, XLA_NONE, _also(_hypgeom_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("CONFIDENCE.NORM"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_confidence_note(), _special_fn_note())))
    t.append(XlFnRow(String("CONFIDENCE.T"), XLF_STAT, 3, 3, XLR_SCALAR, XLA_NONE, _also(_confidence_note(), _dist_inv_note())))

    # =====================================================================
    # ⭐ WAVE 8 (2026-09-15) — THE OOXML / ODF OpenFormula SPELLINGS.
    # =====================================================================
    t.append(XlFnRow(String("CHISQDIST"), XLF_STAT, 2, 3, XLR_SCALAR, XLA_NONE, _also(_odf_only_note(), _special_fn_note())))
    t.append(XlFnRow(String("CHISQINV"), XLF_STAT, 2, 2, XLR_SCALAR, XLA_NONE, _also(_odf_only_note(), _dist_inv_note())))
    t.append(XlFnRow(String("B"), XLF_STAT, 3, 4, XLR_SCALAR, XLA_NONE, _also(_odf_only_note(), _stat_scalar_note())))
    t.append(XlFnRow(String("NEG"), XLF_MATH, 1, 1, XLR_SCALAR, XLA_NONE, _also(_odf_only_note(), _scalar_only_note())))
    t.append(XlFnRow(String("EASTERSUNDAY"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, _also(_odf_only_note(), _scalar_only_note())))

    # ---- ⭐ info / IS* (2026-09-04; kernels in xl_scalar_info) --------------
    t.append(XlFnRow(String("ISBLANK"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _isblank_note()))
    t.append(XlFnRow(String("ISNUMBER"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _istype_note()))
    t.append(XlFnRow(String("ISTEXT"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _istype_note()))
    t.append(XlFnRow(String("ISLOGICAL"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _istype_note()))
    t.append(XlFnRow(String("ISERROR"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _istype_note()))
    t.append(XlFnRow(String("ISNA"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _istype_note()))
    t.append(XlFnRow(String("NA"), XLF_INFO, 0, 0, XLR_SCALAR, XLA_NONE, none.copy()))
    # ---- ⭐ the error-predicate triple completed, and the parity pair --------
    # ⚠ `ISERR` LEFT `xl_absent_common_names` ON 2026-09-04. Its stated reason
    # was "every error EXCEPT #N/A, deliberately NOT aliased onto ISERROR" — a
    # complete SPECIFICATION of the function, doing duty as an argument for not
    # writing it. `xl_isna` already computed the `== XL_ERR_NA` half.
    t.append(XlFnRow(String("ISERR"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _iserr_note()))
    # ⛔ ISODD / ISEVEN ARE THE TWO `IS*` ROWS WHOSE ERROR CLASS IS DOMINANCE
    # AND NOT `ERRH_MANUAL`. They ask an arithmetic question, so `ISODD(1/0)` is
    # `#DIV/0!` in Excel where every other member of this family INSPECTS.
    t.append(XlFnRow(String("ISODD"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _parity_note()))
    t.append(XlFnRow(String("ISEVEN"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _parity_note()))
    t.append(XlFnRow(String("ISNONTEXT"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _isnontext_note()))
    t.append(XlFnRow(String("TYPE"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _type_note()))
    t.append(XlFnRow(String("ERROR.TYPE"), XLF_INFO, 1, 1, XLR_SCALAR, XLA_NONE, _error_type_note()))

    # ---- date (1900 serial math) -------------------------------------------
    t.append(XlFnRow(String("TODAY"), XLF_DATE, 0, 0, XLR_SCALAR, XLA_NONE, _volatile_note()))
    t.append(XlFnRow(String("DATE"), XLF_DATE, 3, 3, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("YEAR"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("MONTH"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("DAY"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("EOMONTH"), XLF_DATE, 2, 2, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("DATEDIF"), XLF_DATE, 3, 3, XLR_SCALAR, XLA_NONE, none.copy()))
    # ---- ⭐ date breadth (2026-09-04; kernels in xl_scalar_date) ------------
    t.append(XlFnRow(String("NOW"), XLF_DATE, 0, 0, XLR_SCALAR, XLA_NONE, _now_note()))
    t.append(XlFnRow(String("WEEKDAY"), XLF_DATE, 1, 2, XLR_SCALAR, XLA_NONE, _weekday_note()))
    t.append(XlFnRow(String("EDATE"), XLF_DATE, 2, 2, XLR_SCALAR, XLA_NONE, _edate_note()))
    t.append(XlFnRow(String("DAYS"), XLF_DATE, 2, 2, XLR_SCALAR, XLA_NONE, _days_note()))
    # ---- ⭐⭐ the TIME-OF-DAY family (2026-09-04) --------------------------
    # ★ ALL FOUR WERE ON `xl_absent_common_names` UNDER A REASON THAT WAS A
    # CATEGORY ERROR: "they read the FRACTIONAL part of a serial and this engine
    # has no clock". `TIME` reads no serial — it PRODUCES a fraction from three
    # numeric arguments — and the other three are pure functions of whatever
    # value they are handed. The clock degrades exactly ONE call shape,
    # `HOUR(NOW())`, which is NOW's own documented divergence.
    # ⚠ `TIME` IS LISTED FIRST BECAUSE IT IS WHAT MAKES THE OTHER THREE
    # TESTABLE. It is the only one that can manufacture a fractional serial;
    # without it every HOUR assertion reads an INTEGER serial, where 0 is the
    # right answer whether the kernel works or not.
    t.append(XlFnRow(String("TIME"), XLF_DATE, 3, 3, XLR_SCALAR, XLA_NONE, _time_note()))
    t.append(XlFnRow(String("HOUR"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, _time_of_day_note()))
    t.append(XlFnRow(String("MINUTE"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, _time_of_day_note()))
    t.append(XlFnRow(String("SECOND"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, _time_of_day_note()))
    # ⚠ ISOWEEKNUM IS HERE AND `WEEKNUM` IS A STATED ABSENCE, and the split is
    # the point: WEEKNUM has TEN return_type values, ISOWEEKNUM has one
    # definition and no options. See `_isoweeknum_note`.
    t.append(XlFnRow(String("ISOWEEKNUM"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, _isoweeknum_note()))
    t.append(XlFnRow(String("DAYS360"), XLF_DATE, 2, 3, XLR_SCALAR, XLA_NONE, _days360_note()))
    t.append(XlFnRow(String("TIMEVALUE"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, _timevalue_note()))
    t.append(XlFnRow(String("DATEVALUE"), XLF_DATE, 1, 1, XLR_SCALAR, XLA_NONE, _datevalue_note()))
    t.append(XlFnRow(String("YEARFRAC"), XLF_DATE, 2, 3, XLR_SCALAR, XLA_NONE, _also(_yearfrac_note(), _scalar_only_note())))

    #
    # ⚠ ALL FORTY-NINE ARE `XLR_SCALAR` ONLY, and that is structural rather
    # than a staging decision: every one is a function of NUMBERS and TEXT and
    # names no relation, so `build_xl_plan` refuses them `XL_BUILD_NO_PLAN` and
    # always will. The door that answers them is `komira_xl_eval`.
    #
    # ⚠ THE ARITY WINDOWS ARE NOT COPIES OF EACH OTHER. `*2DEC` is 1..1 (no
    # `places`) where its ten siblings are 1..2; `ERF` is 1..2 (an optional
    # UPPER limit) where `ERF.PRECISE` is 1..1, and that difference is the
    # entire difference between the two names.

    # base conversion — THREE two's-complement widths, ten characters each
    t.append(XlFnRow(String("DEC2BIN"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("DEC2OCT"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("DEC2HEX"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("BIN2DEC"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("OCT2DEC"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("HEX2DEC"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("BIN2OCT"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("BIN2HEX"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("OCT2BIN"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("OCT2HEX"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("HEX2BIN"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))
    t.append(XlFnRow(String("HEX2OCT"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _base_width_note()))

    # bitwise — the domain is 2^48, checked on the RESULT too
    t.append(XlFnRow(String("BITAND"), XLF_ENGINEERING, 2, 2, XLR_SCALAR, XLA_NONE, _bitwise_domain_note()))
    t.append(XlFnRow(String("BITOR"), XLF_ENGINEERING, 2, 2, XLR_SCALAR, XLA_NONE, _bitwise_domain_note()))
    t.append(XlFnRow(String("BITXOR"), XLF_ENGINEERING, 2, 2, XLR_SCALAR, XLA_NONE, _bitwise_domain_note()))
    t.append(XlFnRow(String("BITLSHIFT"), XLF_ENGINEERING, 2, 2, XLR_SCALAR, XLA_NONE, _bitwise_domain_note()))
    t.append(XlFnRow(String("BITRSHIFT"), XLF_ENGINEERING, 2, 2, XLR_SCALAR, XLA_NONE, _bitwise_domain_note()))

    # comparison — GESTEP is an ORDERED compare: GESTEP(-4,-5) is 1
    t.append(XlFnRow(String("DELTA"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, none.copy()))
    t.append(XlFnRow(String("GESTEP"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, none.copy()))

    # the error function — the ERF/ERF.PRECISE arity split IS the pair
    t.append(XlFnRow(String("ERF"), XLF_ENGINEERING, 1, 2, XLR_SCALAR, XLA_NONE, _erf_arity_note()))
    t.append(XlFnRow(String("ERF.PRECISE"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _erf_arity_note()))
    t.append(XlFnRow(String("ERFC"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _erf_arity_note()))
    t.append(XlFnRow(String("ERFC.PRECISE"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _erf_arity_note()))

    # complex numbers — ONE text parser, and a bad literal is #NUM! not #VALUE!
    t.append(XlFnRow(String("COMPLEX"), XLF_ENGINEERING, 2, 3, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMREAL"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMAGINARY"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMABS"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMARGUMENT"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMCONJUGATE"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMSUM"), XLF_ENGINEERING, 1, 255, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMSUB"), XLF_ENGINEERING, 2, 2, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMPRODUCT"), XLF_ENGINEERING, 1, 255, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMDIV"), XLF_ENGINEERING, 2, 2, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMEXP"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMLN"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMLOG10"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMLOG2"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMPOWER"), XLF_ENGINEERING, 2, 2, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMSQRT"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMSIN"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMCOS"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMTAN"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMCOT"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMSEC"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMCSC"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMSINH"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMCOSH"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMSECH"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))
    t.append(XlFnRow(String("IMCSCH"), XLF_ENGINEERING, 1, 1, XLR_SCALAR, XLA_NONE, _complex_form_note()))


    # ---- aggregates: the FULL-REACH family ---------------------------------
    # Scalar-over-args AND inline-relational AND ctx-free plan. The only five
    # names `materialize_scalar_agg_plan` serves, which is why they are the
    # only five with `XLR_INLINE_REL`.
    var full = XLR_SCALAR | XLR_INLINE_REL | XLR_PLAN
    t.append(XlFnRow(String("SUM"), XLF_AGG, 1, 255, full, XLA_SUM, none.copy()))
    t.append(XlFnRow(String("AVERAGE"), XLF_AGG, 1, 255, full, XLA_MEAN, none.copy()))
    t.append(XlFnRow(String("COUNT"), XLF_AGG, 1, 255, full, XLA_COUNT, _count_note()))
    t.append(XlFnRow(String("MIN"), XLF_AGG, 1, 255, full, XLA_MIN, none.copy()))
    t.append(XlFnRow(String("MAX"), XLF_AGG, 1, 255, full, XLA_MAX, none.copy()))

    # ---- aggregates: the PLAN-ONLY family (2026-09-04) ----------------------
    # ★ REACHABLE-BUT-UNBOUND, all four: `AGG_MEDIAN` / `AGG_STDDEV_SAMP` /
    # `AGG_VAR_SAMP` and `count(<col>)` each already had a plan-IR tag, a
    # `plan_wire_vocabulary` member, a 0-key executor arm (# a SQL binding. What was missing was a NAME. That is the whole change.
    t.append(XlFnRow(String("COUNTA"), XLF_AGG, 1, 255, XLR_PLAN, XLA_COUNT_NONBLANK, _also(_counta_note(), _plan_only_note())))
    t.append(XlFnRow(String("MEDIAN"), XLF_AGG, 1, 255, XLR_PLAN, XLA_MEDIAN, _also(_median_note(), _plan_only_note())))
    # ⭐⭐ THE SAMPLE FOUR GAINED `XLR_SCALAR` ON 2026-09-14 AND WERE NOT
    # "PLAN-ONLY" IN ANY SENSE A SHEET AUTHOR WOULD RECOGNISE UNTIL THEN.
    # `STDEV(t.col)` through `komira_xl_stream` answered; `=STDEV(1,2,3)` —
    # the published variadic spelling, `STDEV(number1, [number2], ...)` —
    # was `#NAME?` on `komira_xl_eval`. The census counted the NAME served
    # the whole time, which is why the gap was invisible to every coverage
    # figure in this effort. ⚠ THEY KEEP `_plan_only_note` NO LONGER; the
    # inline-relational refusal it argued is still true and is still recorded
    # by the ABSENCE of `XLR_INLINE_REL` in the mask.
    var samp_both = XLR_SCALAR | XLR_PLAN
    t.append(XlFnRow(String("STDEV"), XLF_AGG, 1, 255, samp_both, XLA_STDDEV_SAMP, _sample_stat_note()))
    t.append(XlFnRow(String("STDEV.S"), XLF_AGG, 1, 255, samp_both, XLA_STDDEV_SAMP, _sample_stat_note()))
    t.append(XlFnRow(String("VAR"), XLF_AGG, 1, 255, samp_both, XLA_VAR_SAMP, _sample_stat_note()))
    t.append(XlFnRow(String("VAR.S"), XLF_AGG, 1, 255, samp_both, XLA_VAR_SAMP, _sample_stat_note()))

    t.append(XlFnRow(String("STDEV.P"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _population_moment_note()))
    t.append(XlFnRow(String("STDEVP"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _also(_population_moment_note(), _compat_rename_note())))
    t.append(XlFnRow(String("VAR.P"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _population_moment_note()))
    t.append(XlFnRow(String("VARP"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _also(_population_moment_note(), _compat_rename_note())))

    # ---- ⭐ THE EIGHT VARIADIC STATISTICS THIS FILE ALREADY SAID NEEDED NO
    #      NEW PRIMITIVE. The paragraph in `xl_absent_common_names()` naming
    #      them — "documented as F(number1, [number2], ...), which the scalar
    #      door already expresses ... they need NO new primitive and are simply
    #      not built yet" — was written on 2026-09-14 and was correct. These
    #      are the build. Every one is `XLR_SCALAR` only: none has a plan-IR
    #      aggregate tag and inventing one would bind a name that cannot run.
    t.append(XlFnRow(String("AVEDEV"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _devsq_note()))
    t.append(XlFnRow(String("DEVSQ"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _devsq_note()))
    t.append(XlFnRow(String("GEOMEAN"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _nonarith_mean_note()))
    t.append(XlFnRow(String("HARMEAN"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _nonarith_mean_note()))
    t.append(XlFnRow(String("SKEW"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _shape_moment_note()))
    t.append(XlFnRow(String("SKEW.P"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _shape_moment_note()))
    # ⚠ `SKEWP` IS IN NO MICROSOFT LIST. It is ODF 1.2 OpenFormula's spelling
    # of SKEW.P and is in the 532-name published UNION for that reason alone,
    # which is why the reference row reads `ODFF  (not in Microsoft's list)`.
    t.append(XlFnRow(String("SKEWP"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _also(_shape_moment_note(), _compat_rename_note())))
    t.append(XlFnRow(String("KURT"), XLF_AGG, 1, 255, XLR_SCALAR, XLA_NONE, _shape_moment_note()))

    # ---- ⭐ the BIVARIATE aggregate (2026-09-04) ----------------------------
    # ⚠ ITS OWN FAMILY, NOT `XLF_AGG`. Two relation arguments and a two-child
    # `AggExpr`; the unary arm can build neither.
    t.append(XlFnRow(String("CORREL"), XLF_BIVAR_AGG, 2, 2, XLR_PLAN, XLA_CORR, _correl_note()))

    # =====================================================================
    # ★★ THE REACHABLE-BUT-UNBOUND SCAN, 2026-09-15 — EXHAUSTIVE OVER EVERY
    #    `AGG_*` TAG, AND WRITTEN DOWN SO THE NEXT AGENT DOES NOT REDO IT.
    # =====================================================================
    #
    # METHOD: for each `AGG_*` constant in `komira_core/plan/agg_expr.mojo`,
    # check the five layers a plan-reaching Excel name needs — the plan-IR
    # constant, a `plan_wire_vocabulary` member, a `LogicalPlan` arm, a 0-KEY
    # arm in `agg_scalar_fold.mojo` and a grouped arm in
    # `agg_extended_grouped.mojo` — then ask whether Excel publishes a name for
    # it. ⚠ THE 0-KEY ARM IS THE ONE PEOPLE SKIP: a ctx-free Excel aggregate
    # plan has NO GROUP KEY, so the grouped arm alone does not make a name
    # runnable.
    #
    #   tag(s)                                  layers  Excel name   verdict
    #   --------------------------------------- ------  -----------  ----------
    #   AGG_CORR                                5/5     CORREL       served 09-04
    #                                                   PEARSON      BOUND TODAY
    #   AGG_COVAR_POP                           5/5     COVAR,       BOUND TODAY
    #                                                   COVARIANCE.P
    #   AGG_COVAR_SAMP                          5/5     COVARIANCE.S BOUND TODAY
    #   AGG_REGR_SLOPE                          5/5     SLOPE        BOUND TODAY
    #   AGG_REGR_INTERCEPT                      5/5     INTERCEPT    BOUND TODAY
    #   AGG_REGR_R2                             5/5     RSQ          BOUND TODAY
    #   AGG_REGR_{SXX,SXY,SYY,AVGX,AVGY,COUNT}  5/5     (none)       N/A — Excel
    #                                                                publishes no
    #                                                                worksheet name
    #   AGG_SEM                                 5/5     (none)       N/A
    #   AGG_MEDIAN                              5/5     MEDIAN       served 09-04
    #   AGG_VAR_POP, AGG_STDDEV_POP             5/5     VAR.P/VARP/  REFUSED on the
    #                                                   STDEV.P/     PLAN door —
    #                                                   STDEVP       see below
    #   AGG_LARGEST_K                           5/5     LARGE, SMALL REFUSED — K is
    #                                                                hardwired to 2
    #                                                                and finalize
    #                                                                returns the MAX
    #   AGG_PRODUCT                             4/5     PRODUCT      REFUSED — NO
    #                                                                0-key fold arm
    #   AGG_COUNT_DISTINCT                      3/5     (none)       N/A
    #   AGG_BOOL_AND/OR, AGG_ANY_VALUE          4/5     (none unary  N/A
    #                                                   over a range)
    #   (there is no AGG_PERCENTILE at all)     0/5     PERCENTILE,  REFUSED — the
    #                                                   QUARTILE*,   KERNEL EXISTS
    #                                                   PERCENTRANK* (PercentileAcc)
    #                                                                and is Excel-
    #                                                                exact; it is
    #                                                                reachable only
    #                                                                from
    #                                                                ColumnarAggMap,
    #                                                                never from a
    #                                                                LogicalPlan
    t.append(XlFnRow(String("COVAR"), XLF_BIVAR_AGG, 2, 2, XLR_PLAN, XLA_COVAR_POP, _also(_bivar_unbound_note(), _also(_covar_divisor_note(), _compat_rename_note()))))
    t.append(XlFnRow(String("COVARIANCE.P"), XLF_BIVAR_AGG, 2, 2, XLR_PLAN, XLA_COVAR_POP, _also(_bivar_unbound_note(), _covar_divisor_note())))
    t.append(XlFnRow(String("COVARIANCE.S"), XLF_BIVAR_AGG, 2, 2, XLR_PLAN, XLA_COVAR_SAMP, _also(_bivar_unbound_note(), _covar_divisor_note())))
    t.append(XlFnRow(String("SLOPE"), XLF_BIVAR_AGG, 2, 2, XLR_PLAN, XLA_REGR_SLOPE, _also(_bivar_unbound_note(), _regr_arg_order_note())))
    t.append(XlFnRow(String("INTERCEPT"), XLF_BIVAR_AGG, 2, 2, XLR_PLAN, XLA_REGR_INTERCEPT, _also(_bivar_unbound_note(), _regr_arg_order_note())))
    t.append(XlFnRow(String("RSQ"), XLF_BIVAR_AGG, 2, 2, XLR_PLAN, XLA_REGR_R2, _also(_bivar_unbound_note(), _regr_arg_order_note())))
    # ⚠ PEARSON IS `XLA_CORR`, THE SAME TAG CORREL CARRIES — an alias by TAG,
    # not by string rewriting, so the two cannot diverge.
    t.append(XlFnRow(String("PEARSON"), XLF_BIVAR_AGG, 2, 2, XLR_PLAN, XLA_CORR, _also(_pearson_note(), _correl_note())))

    # ---- conditional aggregates --------------------------------------------
    # ⚠ TWO GROUPS UNDER ONE FAMILY, AND THEY REACH DIFFERENT SURFACES. The
    # PLURAL forms bind a RESIDENT batch and run inline; the SINGULAR forms are
    # PLAN-ONLY and are the spelling far more sheets actually use.
    var inline_only = XLR_SCALAR | XLR_INLINE_REL
    var condagg_both = XLR_SCALAR | XLR_INLINE_REL | XLR_PLAN
    t.append(XlFnRow(String("SUMIFS"), XLF_CONDAGG, 3, 255, condagg_both, XLA_SUM, _condifs_note()))
    t.append(XlFnRow(String("COUNTIFS"), XLF_CONDAGG, 2, 255, condagg_both, XLA_COUNT, _condifs_note()))
    # ⚠ AVERAGEIFS HAS NO INLINE FORM. `fn_rel_condagg` lowers SUMIFS and
    # COUNTIFS only, so this name is PLAN-ONLY — the reach bitmask is what lets
    # the three plural forms sit next to each other and still say so.
    t.append(XlFnRow(String("AVERAGEIFS"), XLF_CONDAGG, 3, 255, XLR_PLAN, XLA_MEAN, _condifs_note()))
    var condagg_scalar_plan = XLR_SCALAR | XLR_PLAN
    t.append(XlFnRow(String("MAXIFS"), XLF_CONDAGG, 3, 255, condagg_scalar_plan, XLA_MAX, _also(_maxifs_note(), _condifs_note())))
    t.append(XlFnRow(String("MINIFS"), XLF_CONDAGG, 3, 255, condagg_scalar_plan, XLA_MIN, _also(_maxifs_note(), _condifs_note())))

    # ---- ⭐ the SINGULAR conditional aggregates (2026-09-04) ----------------
    # `rel_condagg_build.build_cond_agg_plan` — the first builder in
    # `komira_xl_plan` with NO executing twin, so it is the one definition of
    # what these names mean. The tag is the aggregate to apply; the FAMILY is
    # what selects the arm (`xl_plan_family`), because the tag alone would send
    # SUMIF to `_build_rel_agg`, which takes exactly one relation argument.
    t.append(XlFnRow(String("SUMIF"), XLF_CONDAGG, 2, 3, XLR_PLAN, XLA_SUM, _condif_note()))
    t.append(XlFnRow(String("COUNTIF"), XLF_CONDAGG, 2, 2, XLR_PLAN, XLA_COUNT, _condif_note()))
    t.append(XlFnRow(String("AVERAGEIF"), XLF_CONDAGG, 2, 3, XLR_PLAN, XLA_MEAN, _condif_note()))

    # ---- lookup (REL-only; resident batch) ---------------------------------
    t.append(XlFnRow(String("XLOOKUP"), XLF_LOOKUP, 3, 6, inline_only, XLA_NONE, _resident_note()))
    t.append(XlFnRow(String("VLOOKUP"), XLF_LOOKUP, 3, 4, inline_only, XLA_NONE, _resident_note()))
    t.append(XlFnRow(String("MATCH"), XLF_LOOKUP, 2, 3, inline_only, XLA_NONE, _resident_note()))
    t.append(XlFnRow(String("INDEX"), XLF_LOOKUP, 2, 3, inline_only, XLA_NONE, _resident_note()))

    # ---- dynamic arrays ----------------------------------------------------
    # ⚠ NOT IN THE `FnRegistry` AT ALL — `try_dynarray_relation` is a
    # ROOT-LEVEL router that runs BEFORE the fold pass, because these return a
    # RELATION and the fold pass folds REL subtrees into SCALAR leaves. So
    # `XLR_SCALAR` is correctly absent: they have no scalar form.
    t.append(XlFnRow(String("FILTER"), XLF_DYNARRAY, 2, 2, XLR_INLINE_REL | XLR_PLAN, XLA_NONE, _filter_note()))
    t.append(XlFnRow(String("SORT"), XLF_DYNARRAY, 1, 3, XLR_INLINE_REL, XLA_NONE, _dynarray_note()))
    t.append(XlFnRow(String("UNIQUE"), XLF_DYNARRAY, 1, 1, XLR_INLINE_REL, XLA_NONE, _dynarray_note()))
    t.append(XlFnRow(String("CHOOSECOLS"), XLF_DYNARRAY, 2, 255, XLR_INLINE_REL, XLA_NONE, _dynarray_note()))
    t.append(XlFnRow(String("GROUPBY"), XLF_DYNARRAY, 3, 255, XLR_INLINE_REL, XLA_NONE, _dynarray_note()))
    t.append(XlFnRow(String("TAKE"), XLF_DYNARRAY, 2, 2, XLR_INLINE_REL, XLA_NONE, _dynarray_note()))
    t.append(XlFnRow(String("MERGE"), XLF_DYNARRAY, 4, 5, XLR_INLINE_REL, XLA_NONE, _dynarray_note()))

    return t^


# =============================================================================
# Lookup.
# =============================================================================
def xl_fn_lookup(name: String) -> Optional[XlFnRow]:
    """Resolve a function name (ANY case) to its census row, or None.

    ⚠ NONE MEANS "THIS ENGINE HAS NEVER HEARD OF IT", which is `#NAME?` — not
    "it exists but is unsupported here". The difference matters to a caller
    deciding whether to rewrite the formula or to file a gap."""
    var up = name.upper()
    var t = xl_function_table()
    for i in range(len(t)):
        if t[i].canonical == up:
            return Optional[XlFnRow](t[i].copy())
    return Optional[XlFnRow]()


def xl_plan_agg_tag(name: String) -> UInt8:
    """★ THE ONE DEFINITION OF *"is this a name `build_xl_plan` can lower"*.

    Returns the row's `agg_tag` when the name is REL-capable on the PLAN
    surface, `XLA_NONE` otherwise. `xl_plan_build._is_rel_agg_name` and
    `rel_agg_build._agg_expr_for_name` both read this, so the dispatch
    predicate and the expression builder cannot disagree — which they could,
    silently, while each had its own five-comparison ladder.

    ⚠ IT CHECKS `XLR_PLAN`, NOT `agg_tag != XLA_NONE`. A future row could carry
    a tag for a surface the plan builder does not serve; the reach bit is the
    claim, the tag is the payload."""
    var row_opt = xl_fn_lookup(name)
    if not row_opt:
        return XLA_NONE
    var row = row_opt.value().copy()
    if not row.reaches(XLR_PLAN):
        return XLA_NONE
    return row.agg_tag


def xl_plan_reaches(name: String) -> Bool:
    """★ THE ONE QUESTION `build_xl_plan` ASKS BEFORE DISPATCHING: does this
    name have a ctx-free builder at all?

    ⚠ IT IS NOT `xl_plan_agg_tag(name) != XLA_NONE`, AND THE DIFFERENCE
    ARRIVED WITH THE SECOND BUILDER. Until 2026-09-04 every plan-reaching name
    was an aggregate, so the tag doubled as the predicate. `FILTER` reaches the
    plan surface with `XLA_NONE` — it is not an aggregate — and a caller that
    kept using the tag as the predicate would report it as an unrecognised
    verb while the table said otherwise."""
    var row_opt = xl_fn_lookup(name)
    if not row_opt:
        return False
    return row_opt.value().reaches(XLR_PLAN)


def xl_condagg_is_plural(name: String) -> Bool:
    """★ WHICH ARGUMENT LAYOUT A CONDITIONAL AGGREGATE USES — and it is a real
    difference in Excel, not a spelling one.

        SUMIF(crit_range, criteria, [sum_range])       aggregate range LAST,
                                                       and OPTIONAL
        SUMIFS(sum_range, crit_range1, crit1, ...)     aggregate range FIRST,
                                                       and REQUIRED

    ⛔ SO A BUILDER THAT READ ONE LAYOUT FOR BOTH WOULD AGGREGATE THE CRITERIA
    COLUMN AND FILTER ON THE VALUE COLUMN — a number, confidently wrong, from a
    plan that is perfectly well formed. Excel really did reverse the order
    between the two families, and this is where that fact is written down.

    ⚠ `COUNTIF`/`COUNTIFS` HAVE NO AGGREGATE RANGE IN EITHER LAYOUT — they
    count the rows the criteria select — so the caller checks the tag as well
    as this."""
    return name.upper().endswith(String("IFS"))


def xl_plan_family(name: String) -> Int:
    """★ WHICH ARM OF `build_xl_plan` SERVES THIS NAME — the row's `family` if
    it reaches the plan surface, `-1` otherwise.

    ⚠⚠ IT IS NOT `xl_plan_agg_tag`, AND THE DIFFERENCE ARRIVED WITH THE
    CONDITIONAL AGGREGATES. Until 2026-09-04 the tag doubled as the arm
    selector: every tag-carrying name was a plain `SUM(<name>)`-shaped
    aggregate, so `_is_rel_agg_name` could be `tag != XLA_NONE`. `SUMIF` carries
    `XLA_SUM` **as its payload** — it really does apply a SUM — while taking two
    or three arguments and needing a FILTER underneath. Dispatching it on the
    tag sends it to `_build_rel_agg`, which refuses any arity but one, so the
    census would advertise a verb the door refuses. The TAG says WHAT to
    compute; the FAMILY says WHICH BUILDER computes it.

    ⚠ AND IT IS WHY `agg_memo.xl_agg_kind` ALSO ASKS THE FAMILY. That function
    decides what the graph lowering may BATCH onto
    `materialize_scalar_agg_plan`, whose envelope is exactly the five
    unconditional aggregates; a batched SUMIF would reach a terminal that
    refuses an aggregate over a filter.

    Returns `Int` and not `UInt8` because `-1` is the "does not reach" answer
    and a `UInt8` has no room for one that is not also a family code."""
    var row_opt = xl_fn_lookup(name)
    if not row_opt:
        return -1
    var row = row_opt.value().copy()
    if not row.reaches(XLR_PLAN):
        return -1
    return Int(row.family)


def xl_agg_needs_column(tag: UInt8) -> Bool:
    """True iff the aggregate denoted by `tag` needs a COLUMN selector on its
    binding.

    ⚠ `XLA_COUNT` IS THE ONE FALSE, and it is why the column-less refusal lives
    in the CALLER rather than in the expression builder — see
    `rel_agg_build.build_rel_agg_plan`. COUNT over a selector-less binding is
    `count(*)`, the row count of a 2D range, which is legal Excel.

    ⚠ `XLA_COUNT_NONBLANK` (COUNTA) IS **TRUE**, which is the asymmetry worth
    reading twice: COUNTA measures blank-vs-not, and a selector-less COUNTA
    would be `count(*)` — a number that cannot tell a blank from a value, i.e.
    the one thing COUNTA exists to report."""
    return tag != XLA_COUNT


# =============================================================================
# ★ THE ABSENCE CENSUS — the gap list, written down.
# =============================================================================
def xl_absent_common_names() -> List[String]:
    """Common Excel functions this engine does NOT recognise, as of 2026-09-04.

    ⛔ IT IS AN ASSERTION, NOT A WISH LIST, and `test_xl_fn_table` REDs when a
    name here starts resolving. That inversion is deliberate: an absence list
    that silently keeps naming a function someone implemented is the same
    stale-reason failure `plan_matrix_doors._NO_0KEY_PANDAS` was — a written
    claim that had stopped being true and closed seven cells on it.

    ⚠ SCOPED TO THE COMMON SET A SPREADSHEET USER WOULD REACH FOR FIRST, not to
    all ~500 Excel functions. A complete list would be unmaintainable and would
    make the RED above meaningless.

    ⛔⛔ AND THAT SCOPING SENTENCE HID THE CENSUS'S REAL DEFECT UNTIL
    2026-09-04, SO READ IT WITH THIS. Between the table's rows and this list the
    census spoke about 99 names — and a probe of 73 further COMMON Excel names
    (EXP, LN, LOG, PI, TRUNC, REPT, CHAR, CODE, RANK, CHOOSE, the trig family,
    the whole Excel-365 dynamic-array family) found **73 of 73 in NEITHER SET**.
    A caller asking `komira_xl_functions` "does this engine do LN?" got NO
    ANSWER, which is a different and worse thing than getting `no`.

    ★ AND NO INSTRUMENT COULD REPORT IT. `test_no_absent_name_resolves` REDs
    only on GOOD news — a name HERE that starts resolving — so it walks what was
    written down and is structurally blind to what was not. There was no
    completeness test in the other direction, because there was no reference set
    of Excel names in this tree to hold the census against.

    ⛔ SO THE NUMBER THIS FILE SUPPORTS IS A FRACTION OF 532, NOT
    `103/161 = 64%`. That old fraction had `xl_function_table()` on top and this
    list plus that one underneath — the tree grading itself, and a metric that
    could not fall.

    ⛔⛔ AND THE FIGURES THAT STOOD HERE WERE STALE WITHIN HOURS, TWICE. This
    paragraph read "160/532 MENTIONED AND 121/532 SERVED ... 372 published Excel
    functions are in the backlog" while the live census was 450/251/82 and then
    466/263/66 — a prose number in a file whose whole subject is stale prose. ⇒
    NO COUNT IS WRITTEN HERE ANY MORE. Re-derive, every time, in one command:

    It prints `mentioned` / `served` / `absent` against the 532-name published
    union and REFUSES (does not pass) if the reference set cannot be read.

    ⇒ THE OPERATING RULE IS UNCHANGED AND IS NOW ENFORCED: when you REFUSE a
    name, ADD IT HERE WITH THE MEASURED REASON. An unwritten refusal is
    indistinguishable from never having considered it — except that the gate now
    says so out loud. The 2026-09-04 waves added 44 rows and the refusals
    below."""
    var out = List[String]()
    #
    #   TEXT(value, format)  needs a FORMAT-CODE engine ("0.00", "yyyy-mm-dd",
    #                        "#,##0;(#,##0)"). That is a real parser and a real
    #                        renderer, not a kernel — and a partial one that
    #                        handled two format codes and ignored the rest
    #                        would return a plausibly-formatted WRONG string.
    # ✅ ISERR LEFT THIS LIST ON 2026-09-04, and its stated reason is worth
    # keeping as a WARNING about the shape of a bad reason. It read: "every
    # error EXCEPT #N/A. Deliberately NOT aliased onto ISERROR, which includes
    # it." Every word true — and it is a complete SPECIFICATION of the function
    # being read as a justification for not having it. `xl_isna` already
    # computed `is_error() and error_code == XL_ERR_NA`; ISERR was the same
    # three lines with `==` changed to `!=`. ⛔ "NOT AN ALIAS FOR X" IS AN
    # ARGUMENT AGAINST ONE WRONG IMPLEMENTATION, NEVER AN ARGUMENT FOR ABSENCE.
    out.append(String("TEXT"))

    # =====================================================================
    # ⭐ THE 2026-09-14 TEXT + LOOKUP TRANCHE'S REFUSALS — 35 names, each with
    #   the reason it is not here. THEY WERE ALL IN `excel_function_backlog.tsv`,
    #   i.e. in NEITHER of this file's two lists, so a caller asking
    #   `komira_xl_functions` for `VLOOKUP`'s neighbour `COLUMNS` got no answer
    #   at all rather than `no`.
    #
    # ⛔ THESE ARE FIVE DISTINCT BLOCKERS AND A SHARED SENTENCE WOULD HIDE
    #   FOUR OF THEM. Grouped by what is actually missing.
    # =====================================================================
    out.append(String("AREAS"))
    out.append(String("COLUMNS"))
    out.append(String("ROWS"))
    out.append(String("TRANSPOSE"))
    out.append(String("CHOOSEROWS"))
    out.append(String("DROP"))
    out.append(String("EXPAND"))
    out.append(String("WRAPCOLS"))
    out.append(String("WRAPROWS"))
    out.append(String("TRIMRANGE"))
    out.append(String("ARRAYTOTEXT"))
    #
    # ---- (2) NO CALLING CELL ---------------------------------------------
    # ⚠ A DIFFERENT BLOCKER FROM (1), AND IT SURVIVES AN ARRAY VALUE. `ROW()`
    # and `COLUMN()` with NO argument return the coordinates of the cell the
    # formula is IN; this door evaluates a formula STRING with no cell. With an
    # argument they are case (1). Both readings are blocked, for two reasons.
    out.append(String("ROW"))
    out.append(String("COLUMN"))
    #
    # ---- (3) NO WORKBOOK ---------------------------------------------------
    # These read the workbook AROUND the value: `FORMULATEXT` returns a cell's
    # formula SOURCE, `PHONETIC` reads the furigana METADATA attached to a
    # cell (not derivable from the text — it is what the typist entered),
    # `GETPIVOTDATA` and `PIVOTBY` address a PivotTable, `IMAGE` and `RTD`
    # bind a live external object. None has a scalar spelling at all.
    out.append(String("FORMULATEXT"))
    out.append(String("PHONETIC"))
    out.append(String("GETPIVOTDATA"))
    out.append(String("PIVOTBY"))
    out.append(String("IMAGE"))
    out.append(String("RTD"))
    out.append(String("LENB"))
    out.append(String("LEFTB"))
    out.append(String("RIGHTB"))
    out.append(String("MIDB"))
    out.append(String("FINDB"))
    out.append(String("SEARCHB"))
    out.append(String("REPLACEB"))
    out.append(String("ASC"))
    out.append(String("JIS"))
    out.append(String("DBCS"))
    out.append(String("BAHTTEXT"))
    out.append(String("REGEXTEST"))
    out.append(String("REGEXEXTRACT"))
    out.append(String("REGEXREPLACE"))
    out.append(String("DETECTLANGUAGE"))
    out.append(String("TRANSLATE"))
    # ✅ THE WHOLE CONDITIONAL-AGGREGATE FAMILY LEFT THIS LIST ON 2026-09-04.
    # The singular forms gained `XLR_PLAN` through `rel_condagg_build`; the
    # plural ones followed the same day when the criteria list was generalised
    # to an AND-conjunction, which also gave SUMIFS and COUNTIFS a reach they
    # had never had (they bound a RESIDENT batch only) and made AVERAGEIFS
    # expressible at all.
    # ---- the statistics. ⚠ ONE LINE USED TO COVER ALL SIX -- "statistics with
    # no plan-IR tag (population forms, mode, rank)" -- and it was WRONG about
    # two of them and named a seventh that is not in the group. Each now
    # carries what was MEASURED about it on 2026-09-04, because the six are
    # blocked at four DIFFERENT layers and a shared reason cannot say so.
    #
    # ✅⛔ STDEV.P / VAR.P LEFT THIS LIST ON 2026-09-14, AND THE REASON THEY
    #   SAT HERE IS THE MOST INSTRUCTIVE ENTRY IN THIS FILE, SO IT IS KEPT.
    #   It read, and every clause of it is STILL TRUE:
    #
    #     "the reason STANDS and the scaffolding is ASYMMETRIC.
    #      AGG_STDDEV_POP_F64 exists at the ENGINE op layer with a full
    #      Welford, and WelfordState.variance_pop()/stddev_pop() exist -- but
    #      there is no AGG_VAR_POP_F64 at all, and _merge_agg_cells RAISES on
    #      STDDEV_POP because it is not combine-stable. ⛔ AND ddof CANNOT
    #      RIDE THE EXISTING TAG: AggExpr carries func + children + alias and
    #      no options field, so a ddof=0 added to an ALREADY-ENCODED tag is
    #      SILENTLY IGNORED by an old decoder, which then returns the SAMPLE
    #      statistic. pl.py:1331 states that ruling."
    out.append(String("MODE"))
    # ⛔⛔ LARGE -- AND THE OLD REASON WAS NOT MERELY INCOMPLETE, IT POINTED AT A
    #   TRAP. `AGG_LARGEST_K` EXISTS, has a plan-IR tag AND a wire vocabulary
    #   member ("AGG_LARGEST_K", plan_wire_vocabulary.mojo), so the wire is NOT
    #   the blocker. What it COMPUTES is: per-group state is a fixed
    #   `InlineArray[Float64, 2]` -- K is hardwired to 2 -- and finalize
    #   "returns the LARGER of the top-2" (agg_state_slab.mojo, LargestKF64),
    #   i.e. THE OVERALL MAX. So wiring LARGE onto it would not "ignore its k
    #   argument": `LARGE(range, 3)` would return `MAX(range)`, a real number
    #   from a well-formed plan. The blocker is variable-capacity per-group
    #   state in a byte-slab payload, and the fixed capacity was chosen for
    #   gap6 safety.
    out.append(String("LARGE"))
    # SMALL -- no smallest-K anything at any layer, the mirror of MODE.
    out.append(String("SMALL"))
    out.append(String("PERCENTILE"))
    # =====================================================================
    # ⭐⭐ THE 2026-09-14 STATISTICAL REFUSALS — ONE MISSING PRIMITIVE, AND
    #     IT IS NAMED. THIRTY NAMES, THREE DISTINCT WALLS.
    #
    # The DISTRIBUTION half of Statistical LANDED on this date (43 rows above,
    # `xl_scalar_stat.mojo`): those functions take three or four NUMBERS and
    # need no plan, no aggregate tag and no column. What did NOT land is every
    # statistic that consumes a RANGE, and the reason is one primitive:
    #
    #   ⛔ `FormulaValue` HAS FIVE KINDS — BLANK / NUMBER / TEXT / LOGICAL /
    #      ERROR — AND NO ARRAY KIND. `formula_value.mojo` is the scalar
    #      carrier for the whole `FnRegistry` surface, and no C entry point
    #      binds a range to a scalar ARGUMENT (`komira_xl_bind` binds a
    #      NAME to `<table>[.<column>]`, and a relation-bound name in a scalar
    #      context is `#VALUE!`). So `LARGE(array, k)` CANNOT BE SPELLED on
    #      the door that serves 104 of this table's rows.
    #
    # ⇒ THIS IS A MISSING PRIMITIVE, NOT THIRTY MISSING KERNELS. The
    # mathematics of every name below is a page of code; what is absent is a
    # way to hand it its data. Serving one of them by re-reading the variadic
    # argument list as "the array" would silently redefine the function —
    # `LARGE(1, 2, 3)` is not `LARGE({1,2,3}, 3)` — which is the shape of
    # wrongness this whole effort exists to stop.
    #
    # ✅⭐ AND THE VARIADIC-OVER-ARGUMENTS STATISTICS WERE **NOT** IN THIS
    # LIST, deliberately, on the grounds that "they need NO new primitive and
    # are simply not built yet". THAT PARAGRAPH WAS RIGHT AND IT IS NOW THE
    # BUILD ORDER FOR A LANDED TRANCHE: AVEDEV / DEVSQ / GEOMEAN / HARMEAN /
    # SKEW / SKEW.P (+ ODF's SKEWP) / KURT are ROWS in `xl_function_table()`
    # as of 2026-09-14, served by `xl_scalar_moments.mojo` over exactly the
    # `F(number1, [number2], ...)` argument list it named.
    #
    # ⛔ **EIGHT** OF ITS FIFTEEN NAMES ARE REFUSED INSTEAD, AND THE ARGUMENT
    # THAT EXEMPTED THE OTHER SEVEN IS WHAT REFUSES THESE. `MODE.SNGL` needs a
    # TIE-BREAK RULE Microsoft does not publish in a checkable form — which of
    # several equally-frequent values it returns — and `PERCENTILE`'s entry
    # above records what happens when a name is bound to a kernel that answers
    # for the wrong reason. ⚠ IT IS REFUSED **HERE** NOW RATHER THAN LEFT IN
    # `excel_function_backlog.tsv`, which is the whole difference between
    # "nobody has looked" and "this was measured"; `MODE` carries the same
    # reason earlier in this function, with a correction to its old one.
    out.append(String("AVERAGEA"))
    out.append(String("MAXA"))
    out.append(String("MINA"))
    out.append(String("VARA"))
    out.append(String("VARPA"))
    out.append(String("STDEVA"))
    out.append(String("STDEVPA"))
    out.append(String("MODE.SNGL"))
    # =====================================================================
    # -- (1) ONE array argument, k or q alongside it. The array is the first
    #    argument in every one, so there is nowhere for it to go.
    out.append(String("PERCENTILE.INC"))
    out.append(String("PERCENTILE.EXC"))
    out.append(String("QUARTILE.INC"))
    out.append(String("QUARTILE.EXC"))
    out.append(String("PERCENTRANK.INC"))
    out.append(String("PERCENTRANK.EXC"))
    out.append(String("RANK.EQ"))
    out.append(String("RANK.AVG"))
    out.append(String("TRIMMEAN"))
    out.append(String("MODE.MULT"))
    out.append(String("FREQUENCY"))
    out.append(String("PROB"))
    out.append(String("STEYX"))
    # FORECAST / FORECAST.LINEAR — `intercept + slope*x`, i.e. the SAME missing
    #   primitive STEYX names (two aggregates combined by a scalar expression)
    #   AND a third, scalar, argument `x` alongside the two ranges, which
    #   `_build_bivar_agg` has no arity for. Both halves, not one.
    out.append(String("FORECAST"))
    out.append(String("FORECAST.LINEAR"))
    out.append(String("CHISQ.TEST"))
    out.append(String("F.TEST"))
    out.append(String("T.TEST"))
    out.append(String("Z.TEST"))
    # -- (3) they RETURN an array (a coefficient vector, a fitted series).
    #    Blocked at BOTH ends: no array argument and no array RESULT. Excel
    #    spills these across cells, and this engine has no spill model in the
    #    scalar carrier at all — `XL_ERR_SPILL` exists as a code and nothing
    #    produces it.
    out.append(String("LINEST"))
    out.append(String("LOGEST"))
    out.append(String("TREND"))
    out.append(String("GROWTH"))
    # -- (4) the ETS family: a DIFFERENT and larger wall. Beyond arrays they
    #    need exponential-triple-smoothing with automatic seasonality
    #    DETECTION, i.e. a fitted model with its own hyper-parameters, and
    #    Microsoft does not publish the exact fitting procedure. A plausible
    #    reimplementation would return confident forecasts that are not
    #    Excel's, which no tolerance can adjudicate.
    out.append(String("FORECAST.ETS"))
    out.append(String("FORECAST.ETS.CONFINT"))
    out.append(String("FORECAST.ETS.SEASONALITY"))
    out.append(String("FORECAST.ETS.STAT"))
    # ✅ NOW / WEEKDAY / EDATE / DAYS LEFT THIS LIST ON 2026-09-04, and so did
    # HOUR / MINUTE / SECOND / TIME later the same day. ⛔ THE REASON THAT HELD
    # THOSE FOUR OUT WAS A CATEGORY ERROR AND IT IS RECORDED HERE SO THE SHAPE
    # IS RECOGNISABLE: "they read the FRACTIONAL part of a serial, and there is
    # no clock anywhere in this tree". TIME reads no serial at all — it takes
    # three numeric ARGUMENTS and PRODUCES a fraction — and the other three are
    # pure functions of whatever value they are handed. The clock degrades
    # EXACTLY ONE call shape, HOUR(NOW()), which NOW's own row has documented
    # since NOW landed. One degenerate argument was generalised into a refusal
    # of four functions.
    # lookup
    out.append(String("HLOOKUP"))
    out.append(String("LOOKUP"))
    out.append(String("OFFSET"))
    out.append(String("INDIRECT"))
    # =====================================================================
    # ★ THE 2026-09-04 REFUSALS — names MEASURED and deliberately not taken.
    #
    # ⛔ EVERY ONE OF THESE WAS INVISIBLE TO THIS CENSUS BEFORE TODAY: in
    # neither the table's rows nor this list, so the engine could not say it
    # did not have them. A refusal that is not written down is
    # indistinguishable from never having considered the name.
    # =====================================================================
    # -- WEEKNUM: TEN `return_type` values, selecting which day starts the
    #    week AND whether week 1 is the one containing Jan 1 or the one
    #    containing the first Thursday. `_weekday_note` already records what
    #    serving one of several return types costs. ISOWEEKNUM has exactly one
    #    definition and no options, so IT landed and this did not.
    out.append(String("WEEKNUM"))
    # -- CEILING.MATH / FLOOR.MATH: the `mode` argument interacts with the
    #    SIGN of `number` in a three-way table (default rounds a negative
    #    toward zero; a non-zero mode rounds it away), and that table is the
    #    whole function. It is not verifiable against a live Excel from here,
    #    and a plausible-looking wrong arm returns a confident wrong integer
    #    on exactly the negative inputs nobody fixtures. CEILING / FLOOR — the
    #    two-argument classic forms — ARE registered.
    out.append(String("CEILING.MATH"))
    out.append(String("FLOOR.MATH"))
    # -- RAND / RANDBETWEEN: VOLATILE, and there is no RNG anywhere in this
    #    tree. The same argument NOW's row makes: a deterministic stand-in is
    #    a wrong answer that never varies, not a smaller one. A real one needs
    #    a seed in `SemanticsProfile` and a recalc layer to make it mean
    #    anything.
    out.append(String("RAND"))
    out.append(String("RANDBETWEEN"))
    # -- SUMPRODUCT: takes ARRAYS and multiplies them elementwise before
    #    summing. The scalar registry has no array value in `FormulaValue`,
    #    and the relational path's terminal takes ONE aggregate over ONE
    #    column. A two-argument scalar version would be `a*b`, which is not
    #    the function.
    out.append(String("SUMPRODUCT"))
    # -- RANK / SUBTOTAL: both need a whole-column ORDERING at plan time.
    #    RANK has no plan-IR aggregate tag; SUBTOTAL additionally dispatches on
    #    a FUNCTION NUMBER and must skip rows hidden by other SUBTOTALs, which
    #    is sheet state this engine does not model at all.
    #    ⚠ THIS SENTENCE USED TO READ "the same wall STDEV.P and MODE hit
    #    below" AND HALF OF IT WENT FALSE ON 2026-09-14: STDEV.P is a SERVED
    #    row now, on the scalar door, because its blocker was only ever a
    #    property of the plan surface. MODE is still below. ⇒ A REFUSAL THAT
    #    CITES ANOTHER REFUSAL INHERITS ITS STALENESS, which is why the shared
    #    citation is gone and the reason is stated here on its own.
    out.append(String("RANK"))
    out.append(String("SUBTOTAL"))
    # -- COUNTBLANK: ⚠ NOT merely unimplemented — the value models DISAGREE.
    #    Excel's BLANK is a distinct member of the scalar lattice (`FV_BLANK`,
    #    which is why `ISBLANK("")` is FALSE), and the engine's columnar side
    #    has NULL. A `count(*) - count(<col>)` lowering counts NULLS and calls
    #    them blanks; over a column with real nulls that is a confidently wrong
    #    number, and the two doors would agree on it.
    out.append(String("COUNTBLANK"))
    out.append(String("SWITCH"))
    # -- LET / LAMBDA: a NAME-BINDING and a CLOSURE construct. The parser
    #    produces an arena AST with no scope chain and no user-defined callable
    #    in `FnRegistry`; these are a language feature, not a function.
    out.append(String("LET"))
    out.append(String("LAMBDA"))
    # -- DOLLAR / FIXED: TEXT's format-code engine again, wearing two hats —
    #    both RENDER a number to a formatted string. Same refusal, same reason.
    #    NUMBERVALUE is the inverse and needs LOCALE separators, which nothing
    #    in this tree carries.
    out.append(String("DOLLAR"))
    out.append(String("FIXED"))
    out.append(String("NUMBERVALUE"))
    out.append(String("WORKDAY"))
    out.append(String("NETWORKDAYS"))
    # =====================================================================
    #
    # ⛔ EVERY ONE OF THESE WAS IN `excel_function_backlog.tsv` — visible as
    # absent, but with no reason attached. A backlog row says "nobody has
    # looked"; these say what was measured.
    # =====================================================================
    out.append(String("SUMX2MY2"))
    out.append(String("SUMX2PY2"))
    out.append(String("SUMXMY2"))
    out.append(String("SERIESSUM"))
    # ⚠ THE FOUR MATRIX NAMES ARE THE SAME BLOCKER TWICE OVER: they take an
    #   array AND (MINVERSE / MMULT / MUNIT) RETURN one, so even a scalar
    #   `FormulaValue` that could HOLD a matrix would have nowhere to put the
    #   result. MDETERM alone returns a scalar and is the one that would land
    #   first if an array value ever arrives.
    out.append(String("MDETERM"))
    out.append(String("MINVERSE"))
    out.append(String("MMULT"))
    out.append(String("MUNIT"))
    # ---- PRIMITIVE 2: A HOLIDAY LIST IS A RANGE, plus a WEEKEND MODE TABLE.
    #      WORKDAY / NETWORKDAYS are already refused above for the range half.
    #      ⚠ THE `.INTL` PAIR ADDS A SECOND, INDEPENDENT REASON: `weekend` is
    #      either one of 17 numeric codes or a 7-character "0000011" string,
    #      and serving the default (Sat+Sun) while accepting the argument is
    #      the WEEKNUM failure — a confident wrong integer on exactly the
    #      non-default inputs nobody fixtures.
    out.append(String("NETWORKDAYS.INTL"))
    out.append(String("WORKDAY.INTL"))
    # ---- PRIMITIVE 3: A FUNCTION NUMBER + AN IGNORE MODE. ⚠ THE DENOMINATOR
    #      FOR `AGGREGATE` IS NOT THE NAME, IT IS THE MODE TABLE: 19 function
    #      numbers x 8 ignore options = 152 behaviours behind one name, and 6
    #      of the 19 (LARGE, SMALL, PERCENTILE.INC/.EXC, QUARTILE.INC/.EXC)
    #      name functions this engine refuses on their own account two
    #      paragraphs up. `SUBTOTAL` is the same shape with 11 function numbers
    #      x 2 (its 1xx forms skip manually-hidden rows, which is SHEET STATE).
    #      ⇒ COUNTING EITHER AS "one absent name" UNDERSTATES IT BY TWO ORDERS
    #      OF MAGNITUDE, and counting it as SERVED once a single mode worked
    #      would overstate it by the same.
    out.append(String("AGGREGATE"))
    out.append(String("MAKEARRAY"))
    out.append(String("MAP"))
    out.append(String("REDUCE"))
    out.append(String("SCAN"))
    # ---- PRIMITIVE 5: NO WORKBOOK. This engine evaluates ONE formula against
    #      a bound relation; there is no cell grid, no sheet list, no formula
    #      text for a neighbour cell and no environment. The eight
    #      `Information` names below each ask the workbook a question.
    #
    # ⛔⛔ AND `ISREF` IS THE ONE WHOSE IMPLEMENTATION WOULD BE WORSE THAN ITS
    #      ABSENCE, WHICH IS WHY IT IS CALLED OUT SEPARATELY. A reference is
    #      resolved to a value BEFORE any function sees it here, so the honest
    #      kernel is `return FALSE` — total, never an error, and WRONG for
    #      exactly the argument the function exists to recognise. It would pass
    #      every `ISREF("x") = FALSE` cell anybody would think to write. That
    #      is the registry-row-wired-to-the-wrong-kernel shape, arrived at
    #      honestly.
    out.append(String("ISREF"))
    # -- ISFORMULA needs the FORMULA TEXT of another cell, which is not even
    #    in the value lattice — the parser consumes formula text and produces
    #    an AST; nothing retains the source of a cell it did not evaluate.
    out.append(String("ISFORMULA"))
    # -- CELL(info_type, ref) is 12 info types over a cell's FORMAT, ADDRESS,
    #    PROTECTION and WIDTH; INFO(type) is 7 types over the OPERATING
    #    SYSTEM and recalculation mode. Both are mode tables over state that
    #    does not exist here, so both are AGGREGATE's shape as well as this
    #    one's.
    out.append(String("CELL"))
    out.append(String("INFO"))
    # -- SHEET / SHEETS count and index WORKSHEETS. One bound relation is not
    #    a workbook, and answering 1 would be a plausible constant.
    out.append(String("SHEET"))
    out.append(String("SHEETS"))
    # -- ISOMITTED is only meaningful INSIDE a LAMBDA (it asks whether an
    #    optional lambda parameter was supplied), so it is primitive 4 wearing
    #    an Information label. Outside one Excel itself errors.
    out.append(String("ISOMITTED"))
    # -- STOCKHISTORY fetches MARKET DATA over the network. Not a capability
    #    gap in the evaluator at all; it is a different product.
    out.append(String("STOCKHISTORY"))
    # -- PERCENTOF(data_subset, data_all) is Excel 365's newest arrival and
    #    takes two RANGES — primitive 1 again, listed here because its
    #    category (Math and trigonometry) would otherwise hide it.
    out.append(String("PERCENTOF"))
    # -- RANDARRAY is TWO refusals at once and neither is sufficient alone:
    #    it is VOLATILE with no RNG in this tree (RAND's reason, above) AND it
    #    RETURNS A RELATION (the dynamic-array router's, below).
    out.append(String("RANDARRAY"))
    out.append(String("SEQUENCE"))
    out.append(String("XMATCH"))
    out.append(String("SORTBY"))
    out.append(String("HSTACK"))
    out.append(String("VSTACK"))
    out.append(String("TOCOL"))
    out.append(String("TOROW"))
    out.append(String("TEXTSPLIT"))
    out.append(String("BYROW"))
    out.append(String("BYCOL"))
    # =====================================================================
    # ⭐⭐ THE 2026-09-14 COMPATIBILITY / DATABASE / CUBE / WEB / ADD-IN
    #     REFUSALS — 33 names, FOUR WHOLE PUBLISHED CATEGORIES THAT WERE AT
    #     ZERO. Every one of them was in NEITHER list before today, so
    #     `komira_xl_functions` could not tell a caller this engine lacks
    #     them, which is worse than telling them no.
    # =====================================================================
    #
    # ✅ STDEVP / VARP LEFT THIS LIST ON 2026-09-14 WITH THEIR REPLACEMENTS.
    #   ⭐ THE WARNING THIS ENTRY ALREADY CARRIED IS WHAT FOUND THEM, and it
    #   is worth keeping as the shape of a refusal that was ALMOST re-read in
    #   time: "⚠ RE-READ THAT REASON BEFORE ACTING ON IT ... what it says is
    #   absent is the `_F64` ENGINE op and the combine-stability, which is a
    #   narrower claim than a reader skimming it would take." The claim was
    #   narrower still — it was about ONE SURFACE — and the sentence stopped
    #   one step short of saying so.
    #   ⛔ AND A THIRD FILE STATED THE OPPOSITE OUTRIGHT:
    #   `xl_scalar_compat_stat.mojo`'s header listed STDEVP and VARP among
    #   "the nine Compatibility names that consume a RANGE ... they are
    #   aggregates, and the scalar `FormulaValue` lattice has no array member
    #   at all". Two of those nine are published as variadic argument lists;
    #   that header now says seven and names the two that left.
    # QUARTILE / PERCENTRANK — QUARTILE.INC is PERCENTILE.INC at k in
    #   {0,.25,.5,.75,1} and PERCENTRANK is its inverse, so both hit the wall
    #   `PERCENTILE` hits above VERBATIM: `PercentileAcc` is Excel-exact and
    #   there is no `AGG_PERCENTILE` plan-IR tag to reach it from a
    #   `LogicalPlan`. Adding the name without the tag binds a function that
    #   cannot run.
    out.append(String("QUARTILE"))
    out.append(String("PERCENTRANK"))
    out.append(String("TTEST"))
    out.append(String("FTEST"))
    out.append(String("CHITEST"))
    out.append(String("ZTEST"))
    out.append(String("DSUM"))
    out.append(String("DAVERAGE"))
    out.append(String("DCOUNT"))
    out.append(String("DCOUNTA"))
    out.append(String("DGET"))
    out.append(String("DMAX"))
    out.append(String("DMIN"))
    out.append(String("DPRODUCT"))
    out.append(String("DSTDEV"))
    out.append(String("DSTDEVP"))
    out.append(String("DVAR"))
    out.append(String("DVARP"))
    out.append(String("CUBEVALUE"))
    out.append(String("CUBEMEMBER"))
    out.append(String("CUBESET"))
    out.append(String("CUBESETCOUNT"))
    out.append(String("CUBERANKEDMEMBER"))
    out.append(String("CUBEKPIMEMBER"))
    out.append(String("CUBEMEMBERPROPERTY"))
    out.append(String("WEBSERVICE"))
    out.append(String("FILTERXML"))
    # ---- the whole `Add-in and Automation` category — 3 names -------------
    # ⛔⛔ `CALL` AND `REGISTER.ID` ARE ARBITRARY CODE EXECUTION DRIVEN BY
    # SHEET CONTENT. Both name a DLL or code resource and an entry point in
    # it; `REGISTER.ID` returns the identifier of a procedure already
    # registered and `CALL` invokes one. Microsoft itself disables them in
    # most modern contexts. There is no sandbox in this tree that could make
    # them safe and no reason to want one.
    # ⚠ `EUROCONVERT` IS A CAPABILITY REFUSAL AND A DELIBERATE ONE. The
    # conversion rates are FIXED BY LAW (Council Regulation 2866/98 and its
    # successors) and could simply be tabled, but the function also takes a
    # `full_precision` flag that rounds to the TARGET CURRENCY'S OWN decimal
    # count and a `triangulation_precision` that rounds the intermediate euro
    # amount to a stated number of significant digits. Neither rounding rule
    # is verifiable against a live Excel from here, and a plausible-looking
    # wrong arm returns a confidently wrong amount of MONEY. This is the
    # YEARFRAC refusal above with a currency attached.
    out.append(String("CALL"))
    out.append(String("REGISTER.ID"))
    out.append(String("EUROCONVERT"))
    #
    # THE 16 THAT STAY, AND THEY SPLIT INTO TWO REASONS THAT ARE NOT THE SAME:
    #
    # ---- 1a. A SECOND PRIMITIVE — THE COUPON SCHEDULE (13 names). Previous
    # and next coupon date from settlement, maturity and frequency: calendar
    # arithmetic over a basis-aware date, not a day count. The COUP* six ARE
    # that schedule; ACCRINT accrues across it; DURATION, MDURATION, PRICE and
    # YIELD discount a cash flow ON it. ⚠ ACCRINT IS NOT ACCRINTM — ACCRINTM's
    # security pays AT MATURITY and has no coupon dates at all, which is the
    # whole reason it could be served today and ACCRINT could not.
    #
    # ⚠⚠ AND THE REASON IS NOW SHARPER THAN "NOBODY HAS BUILT IT" — MEASURED
    # 2026-09-15 WHILE BUILDING `yearfrac`, SO THE NEXT SLICE DOES NOT REPEAT
    # THE SEARCH. The schedule is not month arithmetic: LibreOffice's `ScaDate`
    # (`analysishelper.cxx`, tag `libreoffice-25.2.5.2`) carries FOUR state
    # bits per date — `bLastDay`, `bLastDayMode`, `b30Days`, `bUSMode` — plus
    # an `nOrigDay` that survives every roll, so a maturity on the 31st becomes
    # the 30th in a 30-day month and COMES BACK to the 31st in the next long
    # one; `getDiff` then applies SEPARATE basis-0 and basis-4 February
    # corrections, and even `operator<` breaks ties on `bLastDay`. ⛔ THE
    # PUBLISHED EVIDENCE CANNOT GRADE ANY OF THAT. All four MS COUP* pages that
    # still resolve (COUPDAYBS 71, COUPNCD 15-May-11, COUPNUM 4, COUPPCD
    # 15-Nov-10) use the SAME bond — 2011-01-25 -> 2011-11-15, frequency 2,
    # basis 1 — whose maturity is MID-MONTH, so not one of them exercises the
    # end-of-month machinery or basis 0/4 at all; and COUPDAYS' and
    # COUPDAYSNC's pages return HTTP 404, so two of the six have NO published
    # cell whatsoever. ⇒ Serving them on that evidence would ship six functions
    # whose hardest arm is ungraded, in money. The blocker to clear FIRST is an
    # oracle, not a kernel.
    out.append(String("ACCRINT"))
    out.append(String("COUPDAYBS"))
    out.append(String("COUPDAYS"))
    out.append(String("COUPDAYSNC"))
    out.append(String("COUPNCD"))
    out.append(String("COUPNUM"))
    out.append(String("COUPPCD"))
    out.append(String("DURATION"))
    out.append(String("MDURATION"))
    out.append(String("PRICE"))
    out.append(String("YIELD"))
    # ---- 1c. ⛔ THE TREASURY-BILL THREE — REFUSED FOR A SHARPER REASON THAN
    # THE REST, AND IT IS NOT A MISSING PRIMITIVE. They need no basis argument
    # and no coupon schedule; `yearfrac` would serve them today. They are
    # refused because THE TWO PUBLISHED SOURCES DISAGREE BY ONE DAY IN DSM and
    # neither states which is Excel's. Microsoft defines TBILLEQ as
    # `(365 x rate) / (360 - rate x DSM)` with DSM "the number of days between
    # settlement and maturity"; LibreOffice at tag `libreoffice-25.2.5.2`
    # (`AnalysisAddIn::getTbilleq`, `getTbillprice`, `getTbillyield`)
    # INCREMENTS the maturity date — `nMat++` — before counting, on all three.
    # ⚠ MEASURED CONSEQUENCE: a 91-day bill priced at 98.75 yields
    # 0.05007650577 under DSM = 91 and 0.04953219593 under DSM = 92 — 1.099%
    # apart in a quoted yield, with no error on either side and both well
    # inside the spread a reader would attribute to a day-count convention. ⛔ PICKING ONE WOULD BE
    # EXACTLY THE FAILURE THIS FILE'S HEADER NAMES: a plausible wrong price.
    # Resolving it needs a live Excel, which is not reachable from this tree.
    out.append(String("TBILLEQ"))
    out.append(String("TBILLPRICE"))
    out.append(String("TBILLYIELD"))
    # ⛔ CLASS 1b — the ODD-period four need the basis AND the coupon schedule
    # AND a quasi-coupon-period subdivision of an irregular first or last
    # period. Three primitives deep, and the published formulas differ between
    # ECMA-376 and Microsoft's own documentation.
    out.append(String("ODDFPRICE"))
    out.append(String("ODDFYIELD"))
    out.append(String("ODDLPRICE"))
    out.append(String("ODDLYIELD"))
    # ⛔ CLASS 2 — NOT A MISSING KERNEL, A MISSING **SPELLING** (5 names).
    # IRR, MIRR, XIRR, XNPV and FVSCHEDULE take an ARRAY OR RANGE in their
    # published signatures and this door has NEITHER: `formula_parser` has no
    # `{...}` array literal, so `IRR({-100,50,60})` is a PARSE ERROR rather
    # than a `#NAME?`, and `komira_xl_bind` binds only `<table>[.<column>]`,
    # so `IRR(A1:A3)` has no range to name. ⚠ `NPV` IS SERVED AND THEY ARE NOT
    # FOR EXACTLY THIS REASON — Excel's NPV signature is variadic over loose
    # scalars. ⛔ WIDENING THEM TO A VARIADIC SPELLING WOULD BE AN EXTENSION TO
    # EXCEL, which is a worse outcome than a refusal: a workbook written
    # against it would not open in Excel.
    out.append(String("FVSCHEDULE"))
    out.append(String("IRR"))
    out.append(String("MIRR"))
    out.append(String("XIRR"))
    out.append(String("XNPV"))
    # ⛔ CLASS 3 — THE THREE DEPRECIATION SCHEDULES WITH UNPUBLISHED INTERNALS.
    # `VDB` needs the straight-line SWITCH-OVER with FRACTIONAL start and end
    # periods: Excel's own implementation carries a partial-period correction
    # (a half-life adjustment that adds one to the effective life when the
    # start period falls past life/2) that NO published formula states in
    # closed form, and a plausible sum-of-DDB answers a number for every input
    # it is given. `AMORDEGRC` and `AMORLINC` need the French fiscal
    # coefficient table, and `AMORDEGRC` additionally carries a documented
    # rounding wart in its LAST period that Microsoft describes only in prose.
    out.append(String("AMORDEGRC"))
    out.append(String("AMORLINC"))
    out.append(String("VDB"))
    # ⛔ THE FIVE ENGINEERING NAMES THE 2026-09-14 TRANCHE DID NOT SERVE, and
    # each names the MISSING PRIMITIVE rather than the name. 49 of the
    # category's 54 landed; these are what is left, and they are written down
    # here so that "we never considered it" and "we considered it and said no"
    # stop being the same output.
    out.append(String("BESSELI"))
    out.append(String("BESSELJ"))
    out.append(String("BESSELK"))
    out.append(String("BESSELY"))
    out.append(String("CONVERT"))

    # ⚠ BOTH BLOCKS BELOW THIS LINE ARE REFUSALS AND THEY ARE DISJOINT.
    # The Engineering five landed hours before the OOXML/ODFF five; a rebase
    # KEPT BOTH because they name DIFFERENT functions -- which is the one
    # case where an additive resolution is right. ⛔ THE COUNTS AROUND THEM
    # ARE STILL NOT ADDITIVE: re-derive `xl_absent_common_names()`'s size
    # from the function, never by adding two commits' figures.

    # =====================================================================
    # ⭐⭐ WAVE 8 (2026-09-14) — THE FIVE OOXML/ODFF-ONLY NAMES THAT ARE
    #     REFUSED BY NAME. ⛔ NOT ONE OF THEM IS A MISSING KERNEL: each is
    #     refused because it is NOT A VALUE FUNCTION AT ALL. That distinction
    #     is the whole content of this block -- a reader who sees "absent"
    #     and assumes "somebody has not got to it yet" would be wrong about
    #     all five.
    #
    # ⚠ THESE NAMES ARE NOT MICROSOFT'S. They are in the published 532-name
    # union because OOXML and/or ODF OpenFormula define them; six of their
    # eleven siblings ARE served (SKEWP, CHISQDIST, CHISQINV, B, NEG,
    # EASTERSUNDAY), each because the standard defines it in terms of a kernel
    # this table already has. Serving a name only the OTHER standard has is a
    # DECISION; so is refusing one, and this is where the refusals are stated
    # rather than left to the backlog, where they would read as an oversight.
    #
    # DDE(server, topic, item, [mode]) -- DYNAMIC DATA EXCHANGE. It reaches
    #   ANOTHER RUNNING PROCESS over an OS IPC channel and returns whatever
    #   that process is showing. ⛔ IT IS NOT A PURE FUNCTION OF ITS ARGUMENTS
    #   and it is not deterministic, so there is no oracle that could grade it
    #   and no plan that could carry it. Excel itself has no such function.
    out.append(String("DDE"))
    # FORMULA(reference) -- returns the FORMULA TEXT of another cell as a
    #   string. It needs a sheet model in which cells retain their unevaluated
    #   source, and `komira_xl_eval` evaluates ONE formula against a binding
    #   set: there is no other cell to ask, and `komira_xl_bind` binds a NAME
    #   to `<table>[.<column>]`, which carries values and never formula text.
    out.append(String("FORMULA"))
    # MULTIPLE.OPERATIONS(formula_cell, row_cell, row_replacement, ...) --
    #   Calc's "Multiple Operations" what-if feature. It RE-EVALUATES another
    #   cell's formula once per substituted input, i.e. it is a RECALCULATION
    #   DRIVER wearing a function's spelling. ⛔ A one-shot evaluator has
    #   nowhere to put an iteration over a sheet it does not have.
    out.append(String("MULTIPLE.OPERATIONS"))
    # TABLE(...) -- the OOXML what-if DATA TABLE marker. Same class as
    #   MULTIPLE.OPERATIONS and, like it, a spreadsheet-application feature
    #   rather than a value function; it is written into a cell by the data
    #   table UI and means "this cell is part of that table".
    out.append(String("TABLE"))
    out.append(String("MVALUE"))
    return out^


# =============================================================================
# ★★ THE RENDER — what a non-Mojo caller reads.
# =============================================================================
def xl_function_census() -> String:
    """The whole table as TSV, one row per name, plus the absence list.

    ★ THIS IS THE ANSWER TO *"which Excel functions does the formula path
    recognise"*, and the point of rendering it is that the question stops
    needing a Mojo reader. `komira_xl_functions` hands this string to the C
    door; the SQL surface's equivalent is `sql_fn_table.mojo`.

    Format — a header line, then one TAB-separated row per function:

        NAME  FAMILY  MIN  MAX  REACH  AGG_TAG  NOTE

    `REACH` is a `+`-joined subset of `scalar`/`inline_rel`/`plan`, so a reader
    can grep `plan` for exactly the set the C door serves. `MAX` of 255 is the
    variadic sentinel. Trailing sections list the absent common names.
    single-paragraph prose and `test_xl_fn_table` asserts it."""
    var out = String("#name\tfamily\tmin\tmax\treach\tagg_tag\tnote\n")
    var t = xl_function_table()
    for i in range(len(t)):
        var r = t[i].copy()
        var reach = String("")
        if r.reaches(XLR_SCALAR):
            reach += String("scalar")
        if r.reaches(XLR_INLINE_REL):
            if reach.byte_length() > 0:
                reach += String("+")
            reach += String("inline_rel")
        if r.reaches(XLR_PLAN):
            if reach.byte_length() > 0:
                reach += String("+")
            reach += String("plan")
        out += r.canonical
        out += String("\t")
        out += xl_family_name(r.family)
        out += String("\t")
        out += String(Int(r.min_arity))
        out += String("\t")
        out += String(Int(r.max_arity))
        out += String("\t")
        out += reach
        out += String("\t")
        out += String(Int(r.agg_tag))
        out += String("\t")
        out += r.note
        out += String("\n")

    out += String("#absent\n")
    var absent = xl_absent_common_names()
    for i in range(len(absent)):
        out += absent[i]
        out += String("\n")
    return out^
