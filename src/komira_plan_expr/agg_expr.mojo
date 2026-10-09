# =============================================================================
# AggExpr — aggregation expressions (separate from Expr)
# =============================================================================
#
# Aggregate functions have different semantics from scalar expressions:
# they consume multiple rows and produce one. Keeping them as a separate
# type prevents invalid nesting (e.g., sum(sum(col("x")))) at the type level.
#
# AggExpr is NOT an Expr variant. It is its own top-level type used in
# LogicalPlan.Aggregate nodes.
# =============================================================================

from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr import Expr, UN_IS_NULL
from komira_plan_expr.col_expr import ColExpr
from komira_plan_expr.render_text import write_quoted


# =============================================================================
# AggFunc constants
# =============================================================================

comptime AGG_SUM: UInt8 = 0
comptime AGG_COUNT: UInt8 = 1
comptime AGG_MIN: UInt8 = 2
comptime AGG_MAX: UInt8 = 3
comptime AGG_MEAN: UInt8 = 4
comptime AGG_COUNT_DISTINCT: UInt8 = 5
comptime AGG_FIRST: UInt8 = 6
comptime AGG_LAST: UInt8 = 7
comptime AGG_STDDEV_SAMP: UInt8 = 8
"""Sample standard deviation (Welford / Chan-merge family)."""

comptime AGG_CORR: UInt8 = 9
"""Bivariate Pearson correlation. An aggregate with TWO input expressions; the
`children` slots (`_child0` .. `_child3`) admit this and other bivariate /
multi-arg aggs (covariance, linear regression, UDAFs)."""

comptime AGG_MEDIAN: UInt8 = 10
"""The median, DuckDB `quantile_cont(x, 0.5)`. Output Float64 for every input
type.

★ EXACT AT EVERY GROUP SIZE on every route a plan reaches: the extended
fold's `_ext_median_inplace` (a `List` per group) — the route EVERY
customer door takes — and the typed catalog's `MedianOp[dt]` (a `List` per
group). See `median()` below for the evidence.

⛔ Two bounded finalize bodies (`MedianAggregator`, `MedianF64`, FIRST-64
retention) also carry this tag; no plan reaches them."""

comptime AGG_LARGEST_K: UInt8 = 11
"""Top-K-largest values per group. K is hardcoded to 2. Per-group state is
`LargestKState` (24 bytes: Int32 count + Int32 pad + InlineArray[Float64, 2]
min-heap) — no heap-owning fields, so no stale-pointer hazard. Output is a
single Float64 per group (the largest of the top-K, i.e. the heap max).
Generalizing K is deferred until a consumer needs it."""

comptime AGG_VAR_SAMP: UInt8 = 12
"""Sample variance (ddof=1). The M2-finalize-without-sqrt
sibling of `AGG_STDDEV_SAMP`: identical Welford `[count | mean | M2]` state +
Chan parallel-merge `combine`; finalize = `M2 / (count - 1)` for count > 1,
NaN otherwise (`stddev_samp = sqrt(var_samp)`). Output is always Float64.

Routes TYPED (the typed-ROW `RowVarSampAggOver{I64,F64}` driver + the
column-native `VarSampOp[dt]` op) via the `VarSampOf*` marker family. A
var_samp that fails to route typed (e.g. an unsupported DType) raises a clear
`UnsupportedByLowerUntyped` at lowering."""


# =============================================================================
# ★★ THE BIVARIATE FAMILY, 11 TAGS OVER **ONE** EXISTING STATE.
# =============================================================================
#
# ⭐ WHY ELEVEN TAGS AND NOT ELEVEN KERNELS. `CorrelationState`
# (`komira_engine_operators/unified/agg/storage/aggregators_struct_builtin.mojo`)
# carries `[n | mean_x | mean_y | C | Sx | Sy]` — the COMPLETE set of
# sufficient statistics for the whole `regr_*` / `covar_*` family, accumulated
# by the bivariate-Welford `update_bivariate` and merged by the Chan `combine`
# that `AGG_CORR` uses. Every one of the eleven names below
# is a different FINALIZE over those same six numbers. Nothing new accumulates,
# nothing new merges, and the parallel-merge proof `AGG_CORR` carries
# covers all of them BY CONSTRUCTION.
#
# ⛔ THE ARGUMENT ORDER IS THE TRAP, AND IT IS WHY THE BINDER SWAPS. SQL spells
# these `regr_slope(y, x)` — DEPENDENT FIRST, independent second — while the
# state's `x` is whatever reached `update_bivariate`'s first parameter. The SQL
# binder therefore binds `child = <the SECOND SQL argument>` for this family, so
# that `state.mean_x` IS `regr_avgx` and `state.Sx` IS `regr_sxx`. Get this
# backwards and `regr_slope` answers `C / Sy` instead of `C / Sx` — on the
# fixture below that is 1.714… where DuckDB v1.5.3 says 0.5714285714285714, a
# WRONG ANSWER rather than a missing one. `corr` is symmetric and cannot see the
# difference.
#
# MEASURED DuckDB v1.5.3, fixture (g,x,y) =
# (0,1,2),(0,2,3),(0,6,5),(1,10,1),(1,20,4),(1,30,1), per group 0 / 1 — the
# parity target every one of these tags is graded against in
# `test_sql_aggregate_served_value_parity.mojo`:
#
#   regr_count(y,x)      3                    3
#   regr_avgx(y,x)       3.0                  20.0
#   regr_avgy(y,x)       3.3333333333333335   2.0
#   regr_sxx(y,x)        14.0                 200.0
#   regr_syy(y,x)        4.666666666666666    6.0
#   regr_sxy(y,x)        8.0                  0.0
#   covar_pop(y,x)       2.6666666666666665   0.0
#   covar_samp(y,x)      3.9999999999999996   0.0
#   regr_slope(y,x)      0.5714285714285714   0.0
#   regr_intercept(y,x)  1.6190476190476193   2.0
#   regr_r2(y,x)         0.9795918367346939   0.0
#
comptime AGG_COVAR_POP: UInt8 = 13
"""`covar_pop(y, x)` = C / n. NULL when n = 0."""

comptime AGG_COVAR_SAMP: UInt8 = 14
"""`covar_samp(y, x)` = C / (n - 1). NULL when n < 2 — MEASURED v1.5.3, and it
is NOT the same NULL rule as `covar_pop`, which answers 0.0 on a singleton."""

comptime AGG_REGR_AVGX: UInt8 = 15
"""`regr_avgx(y, x)` = mean of the INDEPENDENT (second) argument. NULL at n = 0."""

comptime AGG_REGR_AVGY: UInt8 = 16
"""`regr_avgy(y, x)` = mean of the DEPENDENT (first) argument. NULL at n = 0."""

comptime AGG_REGR_COUNT: UInt8 = 17
"""`regr_count(y, x)` = the number of rows where BOTH arguments are non-NULL.
⛔ INT64 AND NEVER NULL — counting an empty multiset is 0, the same SQL:2016
asymmetry `AGG_COUNT` carries. DuckDB v1.5.3 declares it `UINTEGER`; this engine
emits INT64, which is a WIDTH difference and not a value one."""

comptime AGG_REGR_SXX: UInt8 = 18
"""`regr_sxx(y, x)` = Sx = sum of squared deviations of x. NULL at n = 0."""

comptime AGG_REGR_SXY: UInt8 = 19
"""`regr_sxy(y, x)` = C = sum of cross deviations. NULL at n = 0."""

comptime AGG_REGR_SYY: UInt8 = 20
"""`regr_syy(y, x)` = Sy = sum of squared deviations of y. NULL at n = 0."""

comptime AGG_REGR_SLOPE: UInt8 = 21
"""`regr_slope(y, x)` = C / Sx. NULL only at n = 0.

⚠ AT Sx = 0 IT IS A GENUINE NON-NULL NaN, NOT NULL — MEASURED v1.5.3 over a
group whose x is constant (`regr_slope(...) IS NULL` is `false` there, and the
printed value is `nan`). The IEEE 0/0 falls out of the division itself, so the
correct implementation is the bare quotient with NO guard. A guard that mapped
Sx = 0 to NULL would disagree with the parity target on exactly the groups a
small fixture is most likely to contain."""

comptime AGG_REGR_INTERCEPT: UInt8 = 22
"""`regr_intercept(y, x)` = mean_y - (C / Sx) * mean_x. NULL at n = 0 **OR** at
Sx = 0.

⛔⛔ THE Sx = 0 ARM IS AN ASYMMETRY WITH `AGG_REGR_SLOPE` AND IT IS MEASURED,
NOT INFERRED. On the same constant-x group v1.5.3 answers `nan` for the slope
and `NULL` for the intercept. Sharing one NULL rule across the two — the obvious
refactor — silently converts one of them."""

comptime AGG_REGR_R2: UInt8 = 23
"""`regr_r2(y, x)`. NULL at n = 0 or Sx = 0; **1.0** when Sy = 0 and Sx > 0;
otherwise C*C / (Sx * Sy) (= the square of Pearson r).

⚠ ALL THREE ARMS ARE MEASURED v1.5.3: a constant-x group is NULL, a constant-y
group with varying x is 1.0, and the ordinary case is `corr` squared
(0.9795918367346939 = 0.989743318610787², group 0). A single `C*C/(Sx*Sy)`
expression answers NaN on the first two."""


# =============================================================================
# ★★ THE POPULATION-FINALIZE FAMILY. THREE TAGS
#    OVER THE **WELFORD** STATE `AGG_STDDEV_SAMP` CARRIES.
# =============================================================================
#
# ⭐ WHY THREE TAGS AND NOT THREE KERNELS. `WelfordState`
# (`unified/agg/storage/aggregators_struct_builtin.mojo`) carries
# `[count | mean | m2]` — the complete sufficient statistics for the whole
# variance family — accumulated by the textbook Welford recurrence and merged
# by the Chan parallel-merge that `AGG_STDDEV_SAMP` and `AGG_VAR_SAMP` share.
# Each name below is a different FINALIZE over those three numbers. Nothing new
# accumulates, nothing new merges, and the parallel-merge proof is INHERITED.
#
# ⛔⛔ AND THE DIVISOR IS THE WHOLE CORRECTNESS ARGUMENT, WHICH IS WHY THESE
# THREE CANNOT SIMPLY BE ALIASED ONTO THE SAMPLE ONES. MEASURED v1.5.3 over
# the fixture `x`, per group 0 / 1:
#
#     var_samp     7.0                  100.0
#     var_pop      4.666666666666667    66.66666666666667
#     stddev_samp  2.6457513110645907   10.0
#     stddev_pop   2.160246899469287    8.16496580927726
#     sem          1.2472191289246473   4.714045207910317
#
# Every one of the five is distinct, so an alias onto a near neighbour is a
# WRONG ANSWER under a right-looking name rather than a missing one.
#
# ⛔⛔⛔ `sem` IS **POPULATION**-BASED ON DuckDB v1.5.3. The textbook
# standard error of the mean is `sqrt(M2 / (count - 1)) / sqrt(count)` —
# i.e. `stddev_samp / sqrt(n)`. MEASURED v1.5.3 over `{1, 2, 3, 4, 10}`:
# `sem` = 1.4142135623730951, which is `stddev_POP / sqrt(n)` =
# 1.4142135623730951 and NOT `stddev_samp / sqrt(n)` = 1.5811388300841895. An
# implementation written from the textbook formula ships a wrong answer on
# EVERY group of size > 1.
comptime AGG_VAR_POP: UInt8 = 24
"""`var_pop(x)` = m2 / count (ddof=0). NULL only at count = 0.

⚠ AT count = 1 IT IS A NON-NULL **0.0**, where `AGG_VAR_SAMP` is NULL —
MEASURED v1.5.3 over a singleton group. Sharing one NULL rule across the
sample and population halves converts one of them."""

comptime AGG_STDDEV_POP: UInt8 = 25
"""`stddev_pop(x)` = sqrt(m2 / count). NULL only at count = 0; 0.0 at count = 1."""

comptime AGG_SEM: UInt8 = 26
"""`sem(x)` = stddev_pop / sqrt(count) = sqrt(m2) / count. NULL only at
count = 0; 0.0 at count = 1.

⛔ THE DIVISOR IS `count`, NOT `count - 1`. See the banner above: DuckDB
v1.5.3's `sem` is built on the POPULATION standard deviation, and the sample
reading disagrees with it on every group of size > 1."""


# =============================================================================
# ★★ THE **MONOID-FOLD** FAMILY. FOUR TAGS OVER
#    STATE `_ExtAggState` ALREADY CARRIES (`f64_acc` + `i_count` + `have`) —
#    the same three scalars `AGG_MIN` / `AGG_MAX` / `AGG_SUM` fold into.
# =============================================================================
#
# ⭐ WHY FOUR TAGS AND NOT FOUR KERNELS. No existing tag is parameterised by a
# combine function — each tag names one fold — but that is not the same as
# EXPENSIVE: a tag naming one fold costs one `elif` in `_ext_fold_one_row` and
# one arm in the finalize, because the extended fold's per-group state is
# three scalars that any commutative monoid over a scalar can use.
#
# ⛔⛔ AND THE NULL RULE IS THE WHOLE FAMILY'S CORRECTNESS ARGUMENT. MEASURED
# DuckDB v1.5.3 over a group whose every row is NULL:
# `count_if` `bool_and` `bool_or` `product` are ALL **NULL**, not the monoid's
# identity. `count_if` in particular is NOT `count(*) FILTER (WHERE b)` and NOT
# `sum(CASE WHEN b THEN 1 ELSE 0 END)` — BOTH answer **0** where v1.5.3
# answers NULL. The one true equivalent is
# `sum(b::BIGINT)`, which carries the NULL-skip AND the empty-fold NULL.
comptime AGG_COUNT_IF: UInt8 = 27
"""`count_if(b)` / `countif(b)` — the number of rows whose (non-NULL) argument
is TRUE. NULL when the group has NO non-NULL row, **0** when it has some and
none is true.

⛔ IT IS NOT `AGG_COUNT`. MEASURED v1.5.3 over a group of one all-NULL row:
`count_star()` = 1, `count(b)` = 0, `count_if(b)` = NULL — three different
answers from the three names."""

comptime AGG_BOOL_AND: UInt8 = 28
"""`bool_and(b)` — TRUE iff every non-NULL row is true. NULL when the group has
no non-NULL row. Output type is **BOOLEAN**, not INT64."""

comptime AGG_BOOL_OR: UInt8 = 29
"""`bool_or(b)` — TRUE iff some non-NULL row is true. NULL when the group has
no non-NULL row. Output type is **BOOLEAN**, not INT64."""

comptime AGG_PRODUCT: UInt8 = 30
"""`product(x)` — the running product of the non-NULL rows. NULL when the group
has no non-NULL row.

⚠ ALWAYS **DOUBLE**, EVEN OVER AN INTEGER COLUMN, and that is v1.5.3's own
rule, not a widening this engine chose: `typeof(product(i))` = DOUBLE over a
BIGINT `i`. It also PRESERVES THE SIGN OF ZERO — MEASURED, `product` over
{-1, 0} is `-0.0`."""


# =============================================================================
# ★★ THE **ARRIVAL-ORDER PICK** FAMILY. `AGG_ANY_VALUE` JOINING
#    `AGG_FIRST` (= 6) AND `AGG_LAST` (= 7).
# =============================================================================
#
# ⛔⛔ THESE FOUR SQL NAMES ARE **THREE** STATISTICS, NOT ONE.
# MEASURED DuckDB v1.5.3 over g=3, x = {NULL, 4.0} — ONE
# group that separates all three at once:
#
#     first(x)      NULL      arbitrary(x)   NULL
#     last(x)       4.0       any_value(x)   4.0
#
# and over g=0, x = {NULL, 7.0, NULL, 9.0, NULL}, which separates `last` from
# `any_value` (the pair that coincided above):
#
#     first(x)      NULL      any_value(x)   7.0
#     last(x)       NULL      arbitrary(x)   NULL
#
# ⇒ `first` / `arbitrary` are the value AT the first ROW, NULL INCLUDED;
#   `last` is the value at the last row, NULL included; `any_value` is the
#   FIRST NON-NULL VALUE. One `AGG_FIRST` aliased across all four BINDS, RUNS
#   and is WRONG for `any_value` on every leading-NULL group — a wrong answer
#   under a right-looking name.
#
# ⭐ `arbitrary` -> `AGG_FIRST` IS NOT A JUDGEMENT CALL — IT IS DuckDB'S OWN
# CATALOG. `select function_name, alias_of from duckdb_functions()` records
# `arbitrary`'s `alias_of` as `first` (and NULL for the other three), so the
# two spellings land on ONE tag for the same reason `variance`/`var_samp` do.
#
# ⚠ THE ORDER IS THE INPUT ROW ORDER, AND BOTH ENGINES SAY SO. DuckDB
# documents `first`/`last`/`any_value` as order-dependent and formally
# unspecified without an `ORDER BY`; this engine's extended fold partitions
# ROWS BY GROUP-KEY HASH so every row of a group lands on ONE worker and is
# folded in ASCENDING ORIGINAL-ROW ORDER (see `agg_extended_grouped.mojo`'s
# header and `_ScatterLocal`), which makes the pick deterministic here and
# equal to the single-scan answer DuckDB produces. ⛔ THAT determinism is a
# property of the ROW-PARTITIONED fold and would NOT survive a
# per-worker-partial COMBINE that merged in partition-visit order — the same
# constraint MEDIAN carries, for the same reason.
comptime AGG_ANY_VALUE: UInt8 = 31
"""`any_value(x)` — the FIRST NON-NULL value per group, in input row order.
NULL only when the group has no non-NULL row.

⛔ IT IS NOT `AGG_FIRST`. MEASURED v1.5.3 over x = {NULL, 4.0}: `any_value` =
4.0 while `first` = `arbitrary` = NULL. The two coincide on every group whose
FIRST row is non-NULL, which is every group in a fixture nobody designed to
separate them."""


# =============================================================================
# ★★ TWO FAMILIES THAT ARE **ACCUMULATOR
#    REGISTERS**, NOT NEW MACHINERY: the KAHAN-COMPENSATED sums (32, 33) and
#    the HIGHER CENTRAL MOMENTS (34, 35, 36).
# =============================================================================
#
# ⭐⭐ HIGHER MOMENTS NEED NO MERGE PROOF ON THIS ROUTE. Chan's two-term
# combine does not extend to higher moments — but THE EXTENDED FOLD HAS NO
# MERGE. It partitions ROWS by group-key HASH so every row of a group lands on
# ONE worker and is folded in ascending original-row order
# (`agg_extended_grouped.mojo`'s header states it, and it is the same property
# MEDIAN and the arrival-order picks depend on). A per-group accumulation on
# this route is IDENTICAL to the serial fold, so a higher-moment update needs
# no combine correction terms and no merge proof — it needs TWO MORE Float64
# REGISTERS.
#
# ⛔ AND THE COMPENSATED FAMILY DEPENDS ON THE **SAME** PROPERTY FOR A
# DIFFERENT REASON. Kahan summation is ORDER-DEPENDENT by construction; a
# per-worker-partial combine would make `fsum` non-deterministic across a
# thread-count change. Because a group is whole on one worker in original-row
# order, this fold reproduces DuckDB's own single-scan order exactly — MEASURED
# v1.5.3 over {0.1 x 10}, `sum` = 0.9999999999999999 and `fsum` = 1.0, and this
# engine answers 1.0 at every thread count.

comptime AGG_KAHAN_SUM: UInt8 = 32
"""`kahan_sum(x)` / `fsum(x)` / `sumkahan(x)` — a Kahan-COMPENSATED sum.

⛔⛔ IT IS NOT `AGG_SUM` AND ALIASING IT SHIPS A WRONG ANSWER UNDER A
RIGHT-LOOKING NAME. MEASURED v1.5.3 over {1e16, 1, 1, 1, -1e16}: `sum` = 0.0
while `fsum` = 4.0; over {0.1 repeated ten times}: `sum` = 0.9999999999999999
while `fsum` = 1.0. Both are groups a fixture of small integers cannot contain,
which is why the parity fixture is built out of them.

⭐ THREE NAMES, ONE TAG, AND THAT PART IS DuckDB'S OWN CATALOG RATHER THAN A
JUDGEMENT: `select function_name, alias_of from duckdb_functions()` records
`fsum`.alias_of = `kahan_sum` and `sumkahan`.alias_of = `kahan_sum`. `favg`'s
`alias_of` is NULL, which is why it gets its own tag below.

⚠ THE ALGORITHM IS **CLASSIC KAHAN**, NOT NEUMAIER, AND THE TWO DISAGREE ON A
GROUP v1.5.3 ANSWERS. Over {1, 1e100, 1, -1e100} Neumaier gives 2.0 and classic
Kahan gives 0.0; MEASURED v1.5.3 answers **0.0**. "More accurate" is not a
licence to be more accurate than the oracle.

⚠ ALWAYS **DOUBLE**, EVEN OVER A BIGINT COLUMN — v1.5.3's only signature is
`(DOUBLE) -> DOUBLE` and an integer argument is implicitly widened
(`typeof(fsum(i))` = DOUBLE over a BIGINT `i`, MEASURED)."""

comptime AGG_KAHAN_AVG: UInt8 = 33
"""`favg(x)` — a Kahan-compensated mean: the compensated sum over the non-NULL
count.

⛔ IT IS NOT `AGG_MEAN`. MEASURED v1.5.3 over {0.1 repeated ten times}: `avg` =
0.09999999999999999 while `favg` = 0.1; over {1e16, 1, 1, 1, -1e16}: `avg` =
0.0 while `favg` = 0.8. ⛔ AND IT IS NOT `AGG_KAHAN_SUM` WITH A DIVISION
BOLTED ON AT THE CALL SITE EITHER — it is a separate tag because the plan IR
has one output cell per aggregate and a rewrite to `fsum(x)/count(x)` would
change the NULL rule (`count` is never NULL, `favg` over an all-NULL group
is)."""

comptime AGG_SKEWNESS: UInt8 = 34
"""`skewness(x)` — the SAMPLE (bias-corrected, type-2 / G1) skewness.

    G1 = [n / ((n-1)(n-2))] * M3 / stddev_samp^3

NULL when n < 3. ⚠ NaN — NOT NULL — when the group has zero variance and
n >= 3; the two are different cells and a null-blind test cannot tell them
apart.

⛔ THE BIAS CORRECTION IS THE WHOLE DIFFERENCE AND IT IS NOT COSMETIC. The
population form `M3/n / (M2/n)^1.5` over the fixture group 0 is
0.5951700641394972 where v1.5.3 answers 1.4578629673213062. Shipping the
population formula under this name BINDS, RUNS and is wrong by a factor of
2.45 — the same shape as aliasing `var_pop` to `var_samp`."""

comptime AGG_KURTOSIS: UInt8 = 35
"""`kurtosis(x)` — the SAMPLE (bias-corrected, type-2 / G2) EXCESS kurtosis.
DuckDB's own description: "excess kurtosis (Fisher's definition) ... with a
bias correction according to the sample size".

    G2 = [n(n+1) / ((n-1)(n-2)(n-3))] * M4/var_samp^2 - 3(n-1)^2/((n-2)(n-3))

NULL when n < 4, and NULL (not NaN) when var_samp is 0.

⛔ IT IS NOT `AGG_KURTOSIS_POP` AND THE TWO ARE FAR APART ON ORDINARY DATA:
MEASURED v1.5.3 over {1, 2, 3, 4, 10}, `kurtosis` = 3.151999999999994 and
`kurtosis_pop` = -0.21200000000000152. ⚠ AND THEIR **NULL RULES DIFFER TOO** —
over a 2-row group `kurtosis` is NULL while `kurtosis_pop` = -2.0 — so an alias
is wrong in the value cell AND in the null cell."""

comptime AGG_KURTOSIS_POP: UInt8 = 36
"""`kurtosis_pop(x)` — the POPULATION excess kurtosis, no bias correction.

    m4/m2^2 - 3,  where m2 = M2/n and m4 = M4/n

NULL when n < 2, and NULL when m2 is 0. MEASURED v1.5.3 over {1, 2, 3, 4}:
-1.36, against `kurtosis` = -1.200000000000001 on the same group."""


@always_inline
def agg_is_kahan_compensated(func: UInt8) -> Bool:
    """True iff `func` folds ONE numeric column through the COMPENSATED
    summation register (`_ExtAggState.kahan_c`) rather than a naive `+=`.

    ★ ONE PREDICATE, FOR THE SAME REASON `agg_is_bivariate` EXISTS: the two
    members share a fold (identical per-row Kahan step), an admission rule (a
    NULL row never reaches the accumulator), an always-FLOAT64 output and a
    `nothing was folded -> NULL` finalize. They differ ONLY in the divisor at
    finalize, exactly as the population-Welford trio differs from the sample
    pair."""
    return func == AGG_KAHAN_SUM or func == AGG_KAHAN_AVG


@always_inline
def agg_needs_higher_moments(func: UInt8) -> Bool:
    """True iff `func` reads the THIRD and/or FOURTH central moment — i.e. it
    needs `_ExtAggState.m3` / `.m4` folded alongside the Welford triple.

    ★ ONE PREDICATE so the per-row arm, the route gate and the finalize agree.
    ⛔ THE THREE MEMBERS SHARE AN ACCUMULATION AND SHARE NOTHING ELSE: their
    NULL thresholds are n < 3, n < 4 and n < 2 respectively, and their
    zero-variance cells are NaN, NULL and NULL. Folding them into one finalize
    arm with one guard is the collapse this docstring exists to stop."""
    return (
        func == AGG_SKEWNESS
        or func == AGG_KURTOSIS
        or func == AGG_KURTOSIS_POP
    )


@always_inline
def agg_picks_by_arrival_order(func: UInt8) -> Bool:
    """True iff `func` PICKS one input row's value rather than computing a
    statistic over the group — `first` / `arbitrary`, `last`, `any_value`.

    ★ ONE PREDICATE, FOR THE SAME REASON `agg_is_bivariate` EXISTS. The three
    members share a fold shape (one scalar + two flags), an output type rule
    (the INPUT column's type, not a widening) and a route (the extended fold is
    their ONLY column executor). A site that spells a three-term `or` goes
    stale the first time a fourth arrival-order name is served."""
    return (
        func == AGG_FIRST
        or func == AGG_LAST
        or func == AGG_ANY_VALUE
    )


@always_inline
def agg_pick_admits_null_rows(func: UInt8) -> Bool:
    """True iff `func` must SEE a NULL input row — i.e. a NULL row participates
    in the pick rather than being skipped.

    ⛔⛔ THIS PREDICATE IS THE FAMILY'S WHOLE CORRECTNESS ARGUMENT AND IT IS
    NOT `agg_picks_by_arrival_order`. Every other aggregate in this engine
    skips a NULL row before it reaches the accumulator, and `any_value` does
    too — but `first` and `last` DO NOT: MEASURED v1.5.3, `first(x)` over
    {NULL, 4.0} is NULL, so the NULL row is what was picked. An implementation
    that reuses the universal `if null: return` guard for all three serves
    `first` and `last` as `any_value` and is wrong on exactly the groups a
    fixture without leading/trailing NULLs cannot contain."""
    return func == AGG_FIRST or func == AGG_LAST


@always_inline
def agg_is_bool_valued(func: UInt8) -> Bool:
    """True iff `func` finalizes to a **BOOLEAN** output column.

    ★ ONE PREDICATE, FOR THE SAME REASON `agg_is_bivariate` exists. Before
    these two tags the extended fold had exactly TWO output cells (INT64 and
    FLOAT64) and every site that chose between them was a two-way `if`. A third
    cell added as a scattered `f == AGG_BOOL_AND or f == AGG_BOOL_OR` would go
    stale at the first site somebody forgot."""
    return func == AGG_BOOL_AND or func == AGG_BOOL_OR


@always_inline
def agg_folds_a_scalar_monoid(func: UInt8) -> Bool:
    """True iff `func` reduces ONE numeric column over a commutative monoid
    with a NULL-when-empty finalize, using only `_ExtAggState`'s three scalar
    fields. The four members share a fold shape, an admission rule (a NULL row
    never reaches the accumulator) and a `not have -> NULL` finalize."""
    return (
        func == AGG_COUNT_IF
        or func == AGG_BOOL_AND
        or func == AGG_BOOL_OR
        or func == AGG_PRODUCT
    )


@always_inline
def agg_accepts_bool_input(func: UInt8) -> Bool:
    """True iff `func` may fold a BOOL input column.

    ⚠ THE EXTENDED FOLD'S INPUT ENVELOPE IS INT-OR-FLOAT PLUS THESE, so
    serving `bool_and(b)` widens it. It is widened FOR THESE TAGS AND NOT
    GLOBALLY: `sum(b)` / `avg(b)` / `median(b)` are separate decisions with
    their own DuckDB answers, and admitting a BOOL column for them here would
    serve them by accident and ungraded.

    ⭐⭐ `AGG_COUNT` IS HERE TO CLOSE A ROUTE-DEPENDENT HOLE. `count(b)` over
    a BOOL column is served perfectly well by the ordinary fixed-cell
    descriptor route — COUNT reads the VALIDITY BITMAP and never the values,
    which `agg_scalar_fold.scalar_agg_input_dtype_servable` states in exactly
    those words — but the moment the SAME query also names an EXTENDED
    aggregate the whole plan routes HERE. Without this arm
    `SELECT g, count(b), median(x) ... GROUP BY g` would BIND and then DIE at
    execution with "out-of-envelope grouped extended agg", while
    `SELECT g, count(b) ... GROUP BY g` answers: the same call, the same
    column, two answers depending on what ELSE is in the SELECT list. Pinned
    by `test_count_star_and_count_and_count_if_are_THREE_DIFFERENT_ANSWERS`.

    ⭐ The three ARRIVAL-ORDER PICK tags join
    them, and unlike the four above this is not a widening of what a NUMBER
    means — a pick returns the input's own value, so a BOOL input yields a BOOL
    output (MEASURED v1.5.3, `typeof(arbitrary(b))` is BOOLEAN). Refusing BOOL
    here would make `first(b)` a route-dependent capability hole of exactly the
    `count(b)` shape recorded above."""
    return (
        func == AGG_COUNT_IF
        or func == AGG_BOOL_AND
        or func == AGG_BOOL_OR
        or func == AGG_COUNT
        or agg_picks_by_arrival_order(func)
    )


@always_inline
def agg_is_population_welford(func: UInt8) -> Bool:
    """True iff `func` finalizes the SAME `WelfordState` the sample family
    folds, but with the POPULATION divisor `n` rather than `n - 1`.

    ★ ONE PREDICATE, FOR THE SAME REASON `agg_is_bivariate` exists. The three
    members share a fold, a merge, an always-FLOAT64 output and a `count == 0`
    NULL rule; every site that must treat them alike asks here instead of
    spelling a three-term `or`, so a fourth member added to this function
    reaches those sites rather than folding as something else."""
    return (
        func == AGG_VAR_POP
        or func == AGG_STDDEV_POP
        or func == AGG_SEM
    )


@always_inline
def agg_accepts_decimal_input(func: UInt8) -> Bool:
    """True iff `func` may fold a DECIMAL128 input column through an F64 cell.

    ⚠ THE SET IS CHOSEN BY THE **OUTPUT TYPE**, NOT BY WHAT THE KERNEL COULD
    READ. Every aggregate in this tree that folds a DECIMAL source folds it
    into the same `Float64` accumulator, so the question the gate answers is
    "would publishing a FLOAT64 here be the RIGHT answer" and not "can the
    bytes be read". MEASURED, DuckDB v1.5.3, `typeof(<f>(v))` over a
    `DECIMAL(12,2)` column:

        avg          -> DOUBLE          stddev_samp  -> DOUBLE
        var_samp     -> DOUBLE          stddev_pop   -> DOUBLE
        var_pop      -> DOUBLE          sem          -> DOUBLE
        count        -> BIGINT
        ---- and the ones DELIBERATELY EXCLUDED ----
        sum          -> DECIMAL(38,2)
        min / max    -> DECIMAL(12,2)   first        -> DECIMAL(12,2)

    ⛔ `sum` / `min` / `max` / `first` ARE NOT HERE AND THE OMISSION IS THE
    POINT. Admitting them would turn a loud REFUSAL into a DOUBLE published
    under a column **THIS PLAN** says is a DECIMAL — `_infer_agg_field` types
    all four from the CHILD (SUM through its promotion table, MIN/MAX/FIRST as
    "same type as col"), so the declared output really is DECIMAL128 and a
    FLOAT64 answer would contradict it. A wrong answer that looks like a
    number, strictly worse than the refusal being fixed. Each needs a 128-bit
    accumulator cell plus a precision/scale-carrying output `Field`, which is a
    separate slice with its own oracle.

    ⭐⭐ `AGG_MEDIAN` **IS** HERE, AND THE ARGUMENT THAT EXCLUDES THE FOUR
    ABOVE IS **VACUOUS** FOR IT. DuckDB's median
    is type-preserving and the table above says so — but the test this gate
    applies is "would publishing a FLOAT64 here be the RIGHT answer", and the
    answer type is decided by `_infer_agg_field`, not by DuckDB.
    `AGG_MEDIAN` is in that function's ALWAYS-FLOAT64 branch, typed BEFORE the
    child is read, for EVERY input type — so there is no DECIMAL column for a
    DOUBLE to be published under. And that is not a quiet implementation
    detail: a repository lint parses the branch out of `_infer_agg_field` and
    asserts it EQUAL to `komira._ops._AGG_FLOAT64_FUNCS` and
    `komira._plan._AGG_ALWAYS_FLOAT64`, both of which name `median`.

    ⚠ THE DuckDB DISAGREEMENT IS REAL AND KNOWN: `median(v)` over a
    `decimal(12,2)` column is 35.37 (scale-preserving) on DuckDB vs
    `median(v::DOUBLE)` = 35.375 over the same six values. The cross-surface
    corpus asks THIS surface for 35.375 and for a `double` column; refusing
    the cell would satisfy neither oracle.
    Falsifier: `test_extended_agg_decimal_median.mojo` §1a/§2/§4b.

    ⭐ `AGG_COUNT` IS HERE FOR THE REASON IT IS IN `agg_accepts_bool_input`:
    it reads the VALIDITY BITMAP and never the values, the fixed-cell descriptor
    route already serves `count(<decimal>)`, and without this line
    `SELECT count(d), stddev_samp(d) FROM t` would refuse a column
    `SELECT count(d) FROM t` answers — a ROUTE-DEPENDENT capability hole of
    exactly the `count(b)` shape recorded above.

    ⛔ THE CONVERSION IS LOSSY ABOVE ~15 SIGNIFICANT DIGITS, which is the F64
    cell's pre-existing property (an INT64 source has always widened into the
    same cell) and not introduced by admitting DECIMAL. It is stated here
    because a DECIMAL(38,s) source can reach it with values an INT64 cannot."""
    return (
        func == AGG_MEAN
        or func == AGG_STDDEV_SAMP
        or func == AGG_VAR_SAMP
        or agg_is_population_welford(func)
        or func == AGG_COUNT
        # See the ⭐⭐ paragraph above. Median's
        # output type in THIS surface is FLOAT64 for every input, gated by
        # a repository lint.
        or func == AGG_MEDIAN
    )


@always_inline
def agg_is_bivariate(func: UInt8) -> Bool:
    """True iff `func` folds TWO input columns through `CorrelationState`.

    ★ ONE PREDICATE, ASKED BY EVERY SITE THAT WOULD OTHERWISE SPELL
    `f == AGG_CORR`. The bivariate SHAPE — slot 0 and slot 1 both populated,
    both read, a row skipped unless BOTH are non-NULL — is a property of the
    family and not of `corr`. A bivariate tag added against sites that named
    `AGG_CORR` directly would compile, bind, plan, and then fold as a
    UNIVARIATE aggregate over slot 0 with slot 1 silently discarded."""
    return (
        func == AGG_CORR
        or func == AGG_COVAR_POP
        or func == AGG_COVAR_SAMP
        or func == AGG_REGR_AVGX
        or func == AGG_REGR_AVGY
        or func == AGG_REGR_COUNT
        or func == AGG_REGR_SXX
        or func == AGG_REGR_SXY
        or func == AGG_REGR_SYY
        or func == AGG_REGR_SLOPE
        or func == AGG_REGR_INTERCEPT
        or func == AGG_REGR_R2
    )


comptime MAX_AGG_CHILDREN: Int = 4
"""Maximum number of input expressions per AggExpr.

Sized to cover:
  - 0 inputs: COUNT(*)
  - 1 input: SUM, COUNT(col), MIN, MAX, MEAN, STDDEV_SAMP, ...
  - 2 inputs: CORR(x, y), COVAR(x, y)
  - 3-4 inputs: future UDAFs (linear regression, weighted variants)

Stored as 4 named `Optional[Expr]` fields (`_child0` .. `_child3`)
because Mojo's `InlineArray[ElementType, N]` requires
`ElementType: Copyable`, and `Optional[Expr]` is only Movable
(`Expr` itself is only Movable due to `OwnedPointer[Expr]` recursive
fields). The named-field shape preserves no-heap-allocation semantics —
each slot is inline in the parent struct."""


# =============================================================================
# AggExpr struct
# =============================================================================

struct AggExpr(Movable, Writable):
    """An aggregation expression.

    Fields:
        func: UInt8 -- one of AGG_SUM, AGG_COUNT, etc.
        _child0 .. _child3: Optional[Expr] -- input expressions. Slot 0
            is the conventional unary input (e.g. col for SUM(col));
            higher slots populated only for multi-arg aggregates
            (CORR, COVAR, UDAFs). All slots None for COUNT(*).
            Access via the `children(i)` method or
            `child0()` / `child1()` accessors.
        alias_name: Optional[String] -- output column name override
    """

    var func: UInt8
    # Slot 0 is named `child` (no underscore) so `agg.child` /
    # `if agg.child:` / `agg.child.value()` read naturally for the
    # dominant unary shape.
    var child: Optional[Expr]
    var child1: Optional[Expr]
    var child2: Optional[Expr]
    var child3: Optional[Expr]
    var alias_name: Optional[String]

    def __init__(out self, func: UInt8, var child: Optional[Expr], var alias_name: Optional[String]):
        """1-input convenience: places `child` in slot 0; remaining slots None.

        This is the dominant constructor — all unary aggs (SUM, COUNT,
        MIN, MAX, MEAN, STDDEV_SAMP) and COUNT(*) (None) use this shape.
        """
        self.func = func
        self.child = child^
        self.child1 = Optional[Expr]()
        self.child2 = Optional[Expr]()
        self.child3 = Optional[Expr]()
        self.alias_name = alias_name^

    def __init__(out self, func: UInt8, var child0: Optional[Expr], var child1: Optional[Expr], var alias_name: Optional[String]):
        """2-input constructor for the bivariate family (`agg_is_bivariate`).

        ⚠ SLOT 0 IS THE ENGINE'S `x` — the INDEPENDENT variable — and slot 1
        is `y`: the REVERSE of SQL's `regr_slope(y, x)`. Prefer the named
        constructors (`regr_slope(y, x)`, `covar_pop(y, x)`, ...), which take
        SQL order and swap inside; spelling a regr_* tag through this
        initializer with `y` first answers a different statistic for six of
        the eleven tags."""
        self.func = func
        self.child = child0^
        self.child1 = child1^
        self.child2 = Optional[Expr]()
        self.child3 = Optional[Expr]()
        self.alias_name = alias_name^

    @always_inline
    def num_children(self) -> Int:
        """Number of populated child slots (0 for COUNT(*), 1 for unary, 2 for bivariate)."""
        var n = 0
        if self.child:
            n += 1
        else:
            return n
        if self.child1:
            n += 1
        else:
            return n
        if self.child2:
            n += 1
        else:
            return n
        if self.child3:
            n += 1
        return n

    def copy(self) -> AggExpr:
        """Create a deep copy of this AggExpr (all child slots)."""
        var alias_copy: Optional[String] = None
        if self.alias_name:
            alias_copy = self.alias_name.value()
        var slot0_copy: Optional[Expr] = None
        if self.child:
            slot0_copy = self.child.value().copy()
        var slot1_copy: Optional[Expr] = None
        if self.child1:
            slot1_copy = self.child1.value().copy()
        var slot2_copy: Optional[Expr] = None
        if self.child2:
            slot2_copy = self.child2.value().copy()
        var slot3_copy: Optional[Expr] = None
        if self.child3:
            slot3_copy = self.child3.value().copy()
        var result = AggExpr(self.func, slot0_copy^, alias_copy^)
        result.child1 = slot1_copy^
        result.child2 = slot2_copy^
        result.child3 = slot3_copy^
        return result^

    @always_inline
    def alias(self, name: String) -> AggExpr:
        """Set the output column name for this aggregation."""
        var copied = self.copy()
        copied.alias_name = Optional(name)
        return copied^

    # --- Writable ---

    def write_to[W: Writer](self, mut writer: W):
        """Human-readable representation."""
        _write_agg_func(writer, self.func)
        writer.write("(")
        var any_written = False
        if self.child:
            self.child.value().write_to(writer)
            any_written = True
        if self.child1:
            if any_written:
                writer.write(", ")
            self.child1.value().write_to(writer)
            any_written = True
        if self.child2:
            if any_written:
                writer.write(", ")
            self.child2.value().write_to(writer)
            any_written = True
        if self.child3:
            if any_written:
                writer.write(", ")
            self.child3.value().write_to(writer)
            any_written = True
        if not any_written:
            writer.write("*")
        writer.write(")")
        if self.alias_name:
            writer.write(".alias(")
            write_quoted(writer, self.alias_name.value())
            writer.write(")")


# =============================================================================
# Free functions — user-facing constructors
# =============================================================================

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

@always_inline
def sum(expr: ColExpr) -> AggExpr:
    """Create a SUM aggregation. Pass to `.agg(...)`; name the output with
    `.alias(...)`.

    Examples:
        ```mojo
        from komira_sdk import col, sum
        var out = ctx.materialize(
            df^.group_by("region")^.agg(sum(col("amount")).alias("revenue"))^
        )
        ```
    """
    return AggExpr(AGG_SUM, expr.copy_expr(), None)


@always_inline
def count() -> AggExpr:
    """Create a COUNT(*) aggregation (counts rows per group).

    Examples:
        ```mojo
        from komira_sdk import count
        var out = ctx.materialize(df^.group_by("region")^.agg(count().alias("n"))^)
        ```
    """
    var none_expr: Optional[Expr] = None
    return AggExpr(AGG_COUNT, none_expr^, None)


@always_inline
def count(expr: ColExpr) -> AggExpr:
    """Create a COUNT(column) aggregation (counts non-null values).

    Examples:
        ```mojo
        from komira_sdk import col, count
        var out = ctx.materialize(
            df^.group_by("region")^.agg(count(col("order_id")).alias("n_orders"))^
        )
        ```
    """
    return AggExpr(AGG_COUNT, expr.copy_expr(), None)


@always_inline
def min(expr: ColExpr) -> AggExpr:
    """Create a MIN aggregation.

    Examples:
        ```mojo
        from komira_sdk import col, min
        var out = ctx.materialize(
            df^.group_by("region")^.agg(min(col("price")).alias("lowest"))^
        )
        ```
    """
    return AggExpr(AGG_MIN, expr.copy_expr(), None)


@always_inline
def max(expr: ColExpr) -> AggExpr:
    """Create a MAX aggregation.

    Examples:
        ```mojo
        from komira_sdk import col, max
        var out = ctx.materialize(
            df^.group_by("region")^.agg(max(col("price")).alias("highest"))^
        )
        ```
    """
    return AggExpr(AGG_MAX, expr.copy_expr(), None)


@always_inline
def mean(expr: ColExpr) -> AggExpr:
    """Create a MEAN (average) aggregation.

    Examples:
        ```mojo
        from komira_sdk import col, mean
        var out = ctx.materialize(
            df^.group_by("counter_id")^.agg(mean(col("resolution_width")).alias("avg"))^
        )
        ```
    """
    return AggExpr(AGG_MEAN, expr.copy_expr(), None)


@always_inline
def count_distinct(expr: ColExpr) -> AggExpr:
    """Create a COUNT(DISTINCT column) aggregation.

    Examples:
        ```mojo
        from komira_sdk import col, count_distinct
        var out = ctx.materialize(
            df^.group_by("region")^.agg(count_distinct(col("customer_id")).alias("uniq"))^
        )
        ```
    """
    return AggExpr(AGG_COUNT_DISTINCT, expr.copy_expr(), None)


@always_inline
def first(expr: ColExpr) -> AggExpr:
    """Create a FIRST aggregation (first value per group in input order).

    Examples:
        ```mojo
        from komira_sdk import col, first
        var out = ctx.materialize(
            df^.group_by("session")^.agg(first(col("event")).alias("landing"))^
        )
        ```
    """
    return AggExpr(AGG_FIRST, expr.copy_expr(), None)


@always_inline
def last(expr: ColExpr) -> AggExpr:
    """Create a LAST aggregation (last value per group in input order).

    Examples:
        ```mojo
        from komira_sdk import col, last
        var out = ctx.materialize(
            df^.group_by("session")^.agg(last(col("event")).alias("exit"))^
        )
        ```
    """
    return AggExpr(AGG_LAST, expr.copy_expr(), None)


@always_inline
def stddev_samp(expr: ColExpr) -> AggExpr:
    """Create a STDDEV_SAMP aggregation (sample standard deviation, Welford)."""
    return AggExpr(AGG_STDDEV_SAMP, expr.copy_expr(), None)


@always_inline
def var_samp(expr: ColExpr) -> AggExpr:
    """Create a VAR_SAMP aggregation (sample variance, ddof=1, Welford).

    `var_samp = stddev_samp ** 2`: identical Welford state + Chan combine;
    finalize = M2/(count-1) for count > 1, NaN otherwise."""
    return AggExpr(AGG_VAR_SAMP, expr.copy_expr(), None)


@always_inline
def var_pop(expr: ColExpr) -> AggExpr:
    """Create a VAR_POP aggregation (population variance, ddof=0, Welford).

    ⛔ NOT AN ALIAS OF `var_samp`: the divisor is `count`, not `count - 1`.
    MEASURED DuckDB v1.5.3 over the fixture group 0, `var_samp` = 7.0
    and `var_pop` = 4.666666666666667."""
    return AggExpr(AGG_VAR_POP, expr.copy_expr(), None)


@always_inline
def stddev_pop(expr: ColExpr) -> AggExpr:
    """Create a STDDEV_POP aggregation (population standard deviation)."""
    return AggExpr(AGG_STDDEV_POP, expr.copy_expr(), None)


@always_inline
def sem(expr: ColExpr) -> AggExpr:
    """Create a SEM aggregation — DuckDB v1.5.3's standard error of the mean,
    which is `stddev_pop / sqrt(count)` and NOT `stddev_samp / sqrt(count)`."""
    return AggExpr(AGG_SEM, expr.copy_expr(), None)


@always_inline
def count_if(expr: ColExpr) -> AggExpr:
    """Create a COUNT_IF aggregation — rows whose non-NULL argument is TRUE.

    ⛔ NOT `count`: over a group whose every row is NULL, v1.5.3's `count_if`
    is NULL where `count` is 0."""
    return AggExpr(AGG_COUNT_IF, expr.copy_expr(), None)


def null_count(expr: ColExpr) -> AggExpr:
    """polars `col(c).null_count()` as an aggregate — the number of NULL
    rows: `count_if(c IS NULL)`. The
    argument `c IS NULL` is never NULL, so a group answers 0, never NULL; a
    NaN is not NULL and is not counted. ⚠ INT64 (this engine's count), where
    polars answers UInt32 — the VALUE is polars'."""
    return AggExpr(AGG_COUNT_IF, Expr.unary(UN_IS_NULL, expr.copy_expr()), None)


@always_inline
def bool_and(expr: ColExpr) -> AggExpr:
    """Create a BOOL_AND aggregation. BOOLEAN-valued; NULL over an all-NULL
    group."""
    return AggExpr(AGG_BOOL_AND, expr.copy_expr(), None)


@always_inline
def bool_or(expr: ColExpr) -> AggExpr:
    """Create a BOOL_OR aggregation. BOOLEAN-valued; NULL over an all-NULL
    group."""
    return AggExpr(AGG_BOOL_OR, expr.copy_expr(), None)


@always_inline
def product(expr: ColExpr) -> AggExpr:
    """Create a PRODUCT aggregation. ALWAYS FLOAT64, even over an INT64 input —
    v1.5.3's own rule, verified with `typeof(product(i))` = DOUBLE."""
    return AggExpr(AGG_PRODUCT, expr.copy_expr(), None)


@always_inline
def corr(col1: ColExpr, col2: ColExpr) -> AggExpr:
    """Create a CORR (Pearson correlation) aggregation. Bivariate."""
    return AggExpr(AGG_CORR, col1.copy_expr(), col2.copy_expr(), None)


@always_inline
def median(expr: ColExpr) -> AggExpr:
    """Create a MEDIAN aggregation.

    ★ EXACT AT EVERY GROUP SIZE, ON EVERY ROUTE A PLAN REACHES. Four finalize
    bodies carry this tag; only the two UNBOUNDED ones are reachable, and
    every customer door reaches ONE of them:

    | arm | capacity | reached by a customer door? |
    |---|---|---|
    | `_ext_median_inplace` (`komira_engine_operators/agg_extended_grouped.mojo`) | **unbounded — exact** | **YES — all five, every type, 0-key AND grouped** |
    | `MedianOp[dt].finalize` (`komira_eval/hash_agg_op_dt.mojo`) | **unbounded — exact** | no (the typed-marker route only) |
    | `MedianAggregator.finalize` (`aggregators_struct_builtin.mojo`) | 64, FIRST-64 retention | **NO — no plan** |
    | `MedianF64.finalize` (`komira_engine_operators/agg/agg_state_slab.mojo`) | 64, FIRST-64 retention | **NO — no plan** |

    ⭐ THE LAST COLUMN IS A MEASUREMENT, NOT A GREP: with
    `_ext_median_inplace` mutated to keep its FIRST 64 values, `MedianOp[dt]`
    its LAST 64, and the two capped bodies returning the sentinels 777777 /
    888888, every capacity cell of the cross-surface corpus went red with the
    FIRST-64 answer (above the exact median, the fixture arriving largest
    first) at every door (sql, pandas, polars, mojo) — and NOT ONE with
    a LAST-64 answer or a sentinel. (`MedianOp[dt]` is still exact and still
    unit-tested; no door in the matrix selects it.)

    The corpus's capacity axis — 189 to 389 values per set, LARGEST FIRST,
    ties, NULLs inside any retained prefix, five row groups, over 0-key and
    grouped median, nine numeric types — passes against the exact median at
    the sql, pandas, polars and mojo doors. The mojo-typed door cannot
    spell median. `test_sql_median_nan_and_over_64_door_parity.mojo`
    mutates `_ext_median_inplace` at the SQL door.

    ⛔ DO NOT STATE A CAP HERE: this is the constructor the SQL door calls
    through, and a repository check reads the
    `FIRST-<N>` / "capped at <N> values" forms in this docstring.

    ⚠ The two capped bodies are DEAD CODE with a live-looking name, and a
    re-wiring would ship FIRST-64 silently; the capacity axis above is the
    test that reds if one is ever reached.
    Kernel semantics (NaN-last total order, half-sum interpolation): see
    `_ext_median_inplace` and `MedianOp[dt].finalize`."""
    return AggExpr(AGG_MEDIAN, expr.copy_expr(), None)


@always_inline
def largest2(expr: ColExpr) -> AggExpr:
    """Create a LARGEST-2 (top-2-largest values) aggregation.

    K is hardcoded to 2. Per-group state holds the 2 largest values
    seen via a min-heap; output is the SCALAR max (i.e. the larger of
    the two). See `LargestKAggregator` for full semantics."""
    return AggExpr(AGG_LARGEST_K, expr.copy_expr(), None)


# =============================================================================
# ★★ THE NAMED CONSTRUCTORS FOR THE REST OF THE SERVED VOCABULARY
# =============================================================================
#
# Without named constructors the untyped Mojo surface could spell these tags
# only as the raw `AggExpr(AGG_*, ...)`. For the ONE-input tags that is merely
# unfriendly. For the BIVARIATE family it is a trap: the tags' own docstrings
# above read `regr_slope(y, x)` (dependent first, SQL's order), while the
# engine's slot 0 is the state's `x` — the INDEPENDENT variable
# (`_ExtAggPlan.src_col` -> `CorrelationAggregator.update_bivariate(x=cx,
# y=cy)`). A caller following the docstring would put `y` in slot 0 and get a
# different statistic from six of the eleven tags (slope, intercept, sxx, syy,
# avgx, avgy swap roles), with no error; `corr` is symmetric and so could
# never show it.
#
# ⇒ THE BIVARIATE CONSTRUCTORS TAKE `(y, x)` IN SQL ORDER AND DO THE SWAP
#   INSIDE, in ONE place (`_bivariate_y_x`), which is the swap
#   `sql_binder._bind_agg_from_sx_call` (args[1] -> slot 0) performs. A Mojo
#   call then reads exactly like the SQL it answers: `regr_slope(col("v"),
#   col("k"))` is `regr_slope(v, k)`. ⛔ Do NOT "fix" a disagreement by
#   flipping the ENGINE's slot order — the SQL door and every graded
#   bivariate row depend on it. `test_agg_expr_named_ctors.mojo` pins both slots per tag.
#
# `corr` keeps its `(col1, col2)` signature: Pearson r is symmetric.


@always_inline
def _bivariate_y_x(func: UInt8, y: ColExpr, x: ColExpr) -> AggExpr:
    """A bivariate `AggExpr` from SQL-ordered `(y, x)`: slot 0 = `x` (the
    INDEPENDENT variable, the state's `x`), slot 1 = `y`."""
    return AggExpr(func, x.copy_expr(), y.copy_expr(), None)


@always_inline
def any_value(expr: ColExpr) -> AggExpr:
    """Create an ANY_VALUE aggregation — the first NON-NULL value per group, in
    input row order. NULL only when the group has no non-NULL row.

    ⛔ NOT `first`: over x = {NULL, 4.0} `any_value` is 4.0 while `first` is
    NULL (DuckDB v1.5.3, see `AGG_ANY_VALUE`)."""
    return AggExpr(AGG_ANY_VALUE, expr.copy_expr(), None)


@always_inline
def kahan_sum(expr: ColExpr) -> AggExpr:
    """Create a KAHAN_SUM aggregation (SQL `kahan_sum` / `fsum` / `sumkahan`) —
    a classic-Kahan compensated sum, ALWAYS Float64.

    ⛔ NOT `sum`: over {0.1 x 10} `sum` is 0.9999999999999999 and `kahan_sum`
    is 1.0 (DuckDB v1.5.3, see `AGG_KAHAN_SUM`)."""
    return AggExpr(AGG_KAHAN_SUM, expr.copy_expr(), None)


@always_inline
def favg(expr: ColExpr) -> AggExpr:
    """Create a FAVG aggregation — the Kahan-compensated mean (tag
    `AGG_KAHAN_AVG`). NULL over an all-NULL group.

    ⛔ NOT `mean`: over {0.1 x 10} `avg` is 0.09999999999999999 and `favg` is
    0.1 (DuckDB v1.5.3)."""
    return AggExpr(AGG_KAHAN_AVG, expr.copy_expr(), None)


@always_inline
def skewness(expr: ColExpr) -> AggExpr:
    """Create a SKEWNESS aggregation — the SAMPLE (bias-corrected, G1)
    skewness. NULL when n < 3; NaN (not NULL) over a zero-variance group of
    three or more. See `AGG_SKEWNESS`."""
    return AggExpr(AGG_SKEWNESS, expr.copy_expr(), None)


@always_inline
def kurtosis(expr: ColExpr) -> AggExpr:
    """Create a KURTOSIS aggregation — the SAMPLE (bias-corrected, G2) EXCESS
    kurtosis. NULL when n < 4 or the sample variance is 0.

    ⛔ NOT `kurtosis_pop`: the value AND the NULL rule differ (see
    `AGG_KURTOSIS`)."""
    return AggExpr(AGG_KURTOSIS, expr.copy_expr(), None)


@always_inline
def kurtosis_pop(expr: ColExpr) -> AggExpr:
    """Create a KURTOSIS_POP aggregation — the POPULATION excess kurtosis, no
    bias correction. NULL when n < 2 or m2 is 0. See `AGG_KURTOSIS_POP`."""
    return AggExpr(AGG_KURTOSIS_POP, expr.copy_expr(), None)


@always_inline
def covar_pop(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a COVAR_POP aggregation, SQL order `covar_pop(y, x)` = C / n.
    NULL when n = 0. Bivariate: a row counts only if BOTH are non-NULL."""
    return _bivariate_y_x(AGG_COVAR_POP, y, x)


@always_inline
def covar_samp(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a COVAR_SAMP aggregation, SQL order `covar_samp(y, x)` =
    C / (n - 1). NULL when n < 2 (NOT `covar_pop`'s rule)."""
    return _bivariate_y_x(AGG_COVAR_SAMP, y, x)


@always_inline
def regr_count(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_COUNT aggregation, SQL order `regr_count(y, x)` — rows
    where BOTH are non-NULL. INT64 and never NULL (0 over zero pairs)."""
    return _bivariate_y_x(AGG_REGR_COUNT, y, x)


@always_inline
def regr_avgx(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_AVGX aggregation, SQL order `regr_avgx(y, x)` — the mean
    of `x`, the INDEPENDENT (second) argument. NULL at n = 0."""
    return _bivariate_y_x(AGG_REGR_AVGX, y, x)


@always_inline
def regr_avgy(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_AVGY aggregation, SQL order `regr_avgy(y, x)` — the mean
    of `y`, the DEPENDENT (first) argument. NULL at n = 0."""
    return _bivariate_y_x(AGG_REGR_AVGY, y, x)


@always_inline
def regr_sxx(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_SXX aggregation, SQL order `regr_sxx(y, x)` — the sum of
    squared deviations of `x`. NULL at n = 0."""
    return _bivariate_y_x(AGG_REGR_SXX, y, x)


@always_inline
def regr_syy(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_SYY aggregation, SQL order `regr_syy(y, x)` — the sum of
    squared deviations of `y`. NULL at n = 0."""
    return _bivariate_y_x(AGG_REGR_SYY, y, x)


@always_inline
def regr_sxy(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_SXY aggregation, SQL order `regr_sxy(y, x)` — the sum of
    cross deviations. NULL at n = 0."""
    return _bivariate_y_x(AGG_REGR_SXY, y, x)


@always_inline
def regr_slope(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_SLOPE aggregation, SQL order `regr_slope(y, x)` = C / Sxx
    — the least-squares slope of `y` on `x`. NULL only at n = 0; a non-NULL
    NaN when `x` is constant (see `AGG_REGR_SLOPE`)."""
    return _bivariate_y_x(AGG_REGR_SLOPE, y, x)


@always_inline
def regr_intercept(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_INTERCEPT aggregation, SQL order `regr_intercept(y, x)` =
    mean_y - slope * mean_x. NULL at n = 0 OR when `x` is constant (NOT the
    slope's rule — see `AGG_REGR_INTERCEPT`)."""
    return _bivariate_y_x(AGG_REGR_INTERCEPT, y, x)


@always_inline
def regr_r2(y: ColExpr, x: ColExpr) -> AggExpr:
    """Create a REGR_R2 aggregation, SQL order `regr_r2(y, x)`. NULL when n = 0
    or `x` is constant; 1.0 when `y` is constant and `x` is not; otherwise
    corr squared. See `AGG_REGR_R2`."""
    return _bivariate_y_x(AGG_REGR_R2, y, x)


# =============================================================================
# Helper: agg func name
# =============================================================================

def _write_agg_func[W: Writer](mut writer: W, func: UInt8):
    """Write the human-readable name of an `AggFunc` constant.

    ⚠ THIS WRITES; IT DOES NOT RETURN — see the banner over the same set of
    helpers in `plan_display.mojo`. As `-> String` this ladder's POINTER
    array is exactly what a crossed shared-library binding can hand another
    render site as its LENGTH operand.
    """
    if func == AGG_SUM:
        writer.write("SUM")
    elif func == AGG_COUNT:
        writer.write("COUNT")
    elif func == AGG_MIN:
        writer.write("MIN")
    elif func == AGG_MAX:
        writer.write("MAX")
    elif func == AGG_MEAN:
        writer.write("MEAN")
    elif func == AGG_COUNT_DISTINCT:
        writer.write("COUNT_DISTINCT")
    elif func == AGG_FIRST:
        writer.write("FIRST")
    elif func == AGG_LAST:
        writer.write("LAST")
    elif func == AGG_STDDEV_SAMP:
        writer.write("STDDEV_SAMP")
    elif func == AGG_VAR_SAMP:
        writer.write("VAR_SAMP")
    elif func == AGG_VAR_POP:
        writer.write("VAR_POP")
    elif func == AGG_STDDEV_POP:
        writer.write("STDDEV_POP")
    elif func == AGG_SEM:
        writer.write("SEM")
    elif func == AGG_COUNT_IF:
        writer.write("COUNT_IF")
    elif func == AGG_BOOL_AND:
        writer.write("BOOL_AND")
    elif func == AGG_BOOL_OR:
        writer.write("BOOL_OR")
    elif func == AGG_PRODUCT:
        writer.write("PRODUCT")
    elif func == AGG_ANY_VALUE:
        writer.write("ANY_VALUE")
    elif func == AGG_CORR:
        writer.write("CORR")
    elif func == AGG_MEDIAN:
        writer.write("MEDIAN")
    elif func == AGG_LARGEST_K:
        writer.write("LARGEST_K")
    elif func == AGG_COVAR_POP:
        writer.write("COVAR_POP")
    elif func == AGG_COVAR_SAMP:
        writer.write("COVAR_SAMP")
    elif func == AGG_REGR_AVGX:
        writer.write("REGR_AVGX")
    elif func == AGG_REGR_AVGY:
        writer.write("REGR_AVGY")
    elif func == AGG_REGR_COUNT:
        writer.write("REGR_COUNT")
    elif func == AGG_REGR_SXX:
        writer.write("REGR_SXX")
    elif func == AGG_REGR_SXY:
        writer.write("REGR_SXY")
    elif func == AGG_REGR_SYY:
        writer.write("REGR_SYY")
    elif func == AGG_REGR_SLOPE:
        writer.write("REGR_SLOPE")
    elif func == AGG_REGR_INTERCEPT:
        writer.write("REGR_INTERCEPT")
    elif func == AGG_REGR_R2:
        writer.write("REGR_R2")
    # ⛔ A MISSING ARM BELOW IS A SILENT WRONG ANSWER, NOT A COSMETIC ONE.
    # This ladder's `else` prints `UNKNOWN`, `AggExpr.write_to` is reached from
    # `plan_display`'s `aggs=[...]` field, and `LogicalPlan.structural_hash` is
    # the FNV-1a OF THAT TEXT — the `factory_hash` half of the plan-compile
    # cache key. With no arm, `skewness(v)` and `kurtosis(v)` and
    # `kurtosis_pop(v)` over one source would all render `UNKNOWN(col("v"))`
    # and share ONE cache key, so the second query to arrive would be served
    # the first one's compiled plan under its own column name.
    # Falsifier: `test_agg_render_is_plan_identity.mojo`; the class
    # is also gated by a repository render-coverage lint.
    elif func == AGG_KAHAN_SUM:
        writer.write("KAHAN_SUM")
    elif func == AGG_KAHAN_AVG:
        writer.write("KAHAN_AVG")
    elif func == AGG_SKEWNESS:
        writer.write("SKEWNESS")
    elif func == AGG_KURTOSIS:
        writer.write("KURTOSIS")
    elif func == AGG_KURTOSIS_POP:
        writer.write("KURTOSIS_POP")
    else:
        writer.write("UNKNOWN")
