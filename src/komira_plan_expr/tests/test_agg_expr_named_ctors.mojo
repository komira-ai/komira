"""Every `AGG_*` tag has a NAMED constructor, and the bivariate ones take SQL
order `(y, x)` and put `x` in slot 0.

⛔ WHY THE SLOT ASSERTIONS ARE THE POINT. The engine's bivariate state reads
slot 0 as its `x` — the INDEPENDENT variable (`_ExtAggPlan.src_col` ->
`CorrelationAggregator.update_bivariate(x=cx, y=cy)`) — while SQL spells the
family `regr_slope(y, x)`. The SQL binder swaps. Before
these constructors a Mojo caller had to spell `AggExpr(AGG_REGR_SLOPE, a, b,
None)` and do that swap by hand; putting `y` first there answers a DIFFERENT
statistic for six of the eleven tags (slope, intercept, sxx, syy, avgx, avgy)
with no error. So each bivariate case below is built from two DIFFERENTLY
NAMED columns and asserts which name lands in which slot — a constructor that
forgot the swap is red here by name, not merely "a bivariate aggregate".

⚠ THE COVERAGE LOOP IS BOUNDED BY `AGG_KURTOSIS_POP` (36), the highest tag
today. A new tag added without a constructor is NOT caught here unless this
bound moves with it — `plan_wire_vocabulary.agg_fn_is_declared` is where the
declared tag range lives.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_plan_expr.agg_expr import (
    AggExpr,
    AGG_ANY_VALUE,
    AGG_COVAR_POP,
    AGG_COVAR_SAMP,
    AGG_KAHAN_AVG,
    AGG_KAHAN_SUM,
    AGG_KURTOSIS,
    AGG_KURTOSIS_POP,
    AGG_REGR_AVGX,
    AGG_REGR_AVGY,
    AGG_REGR_COUNT,
    AGG_REGR_INTERCEPT,
    AGG_REGR_R2,
    AGG_REGR_SLOPE,
    AGG_REGR_SXX,
    AGG_REGR_SXY,
    AGG_REGR_SYY,
    AGG_SKEWNESS,
    agg_is_bivariate,
    any_value,
    bool_and,
    bool_or,
    corr,
    count,
    count_distinct,
    count_if,
    covar_pop,
    covar_samp,
    favg,
    first,
    kahan_sum,
    kurtosis,
    kurtosis_pop,
    largest2,
    last,
    max as agg_max,
    mean,
    median,
    min as agg_min,
    product,
    regr_avgx,
    regr_avgy,
    regr_count,
    regr_intercept,
    regr_r2,
    regr_slope,
    regr_sxx,
    regr_sxy,
    regr_syy,
    sem,
    skewness,
    stddev_pop,
    stddev_samp,
    sum as agg_sum,
    var_pop,
    var_samp,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import EXPR_COL_REF


def _assert_unary(agg: AggExpr, tag: UInt8, what: String) raises:
    assert_equal(agg.func, tag, what + ": wrong AGG_* tag")
    assert_equal(agg.num_children(), 1, what + ": one input expected")
    assert_equal(agg.child.value().tag, EXPR_COL_REF, what)
    assert_equal(agg.child.value().col_ref_name(), String("x"), what)
    assert_false(agg_is_bivariate(agg.func), what + ": must not be bivariate")


def _assert_sql_order(agg: AggExpr, tag: UInt8, what: String) raises:
    """`agg` was built as `<ctor>(col("y"), col("x"))` — SQL order."""
    assert_equal(agg.func, tag, what + ": wrong AGG_* tag")
    assert_equal(agg.num_children(), 2, what + ": two inputs expected")
    assert_true(agg_is_bivariate(agg.func), what + ": must be bivariate")
    assert_equal(
        agg.child.value().col_ref_name(),
        String("x"),
        what
        + ": slot 0 must hold the SECOND SQL argument (the independent x)"
        + " -- the constructor did not swap",
    )
    assert_equal(
        agg.child1.value().col_ref_name(),
        String("y"),
        what + ": slot 1 must hold the FIRST SQL argument (the dependent y)",
    )


def test_one_input_constructors() raises:
    _assert_unary(any_value(col("x")), AGG_ANY_VALUE, "any_value")
    _assert_unary(kahan_sum(col("x")), AGG_KAHAN_SUM, "kahan_sum")
    _assert_unary(favg(col("x")), AGG_KAHAN_AVG, "favg")
    _assert_unary(skewness(col("x")), AGG_SKEWNESS, "skewness")
    _assert_unary(kurtosis(col("x")), AGG_KURTOSIS, "kurtosis")
    _assert_unary(kurtosis_pop(col("x")), AGG_KURTOSIS_POP, "kurtosis_pop")


def test_bivariate_constructors_take_sql_order_and_swap() raises:
    _assert_sql_order(covar_pop(col("y"), col("x")), AGG_COVAR_POP, "covar_pop")
    _assert_sql_order(covar_samp(col("y"), col("x")), AGG_COVAR_SAMP, "covar_samp")
    _assert_sql_order(regr_count(col("y"), col("x")), AGG_REGR_COUNT, "regr_count")
    _assert_sql_order(regr_avgx(col("y"), col("x")), AGG_REGR_AVGX, "regr_avgx")
    _assert_sql_order(regr_avgy(col("y"), col("x")), AGG_REGR_AVGY, "regr_avgy")
    _assert_sql_order(regr_sxx(col("y"), col("x")), AGG_REGR_SXX, "regr_sxx")
    _assert_sql_order(regr_syy(col("y"), col("x")), AGG_REGR_SYY, "regr_syy")
    _assert_sql_order(regr_sxy(col("y"), col("x")), AGG_REGR_SXY, "regr_sxy")
    _assert_sql_order(regr_slope(col("y"), col("x")), AGG_REGR_SLOPE, "regr_slope")
    _assert_sql_order(
        regr_intercept(col("y"), col("x")), AGG_REGR_INTERCEPT, "regr_intercept"
    )
    _assert_sql_order(regr_r2(col("y"), col("x")), AGG_REGR_R2, "regr_r2")


def test_the_aliased_bivariate_keeps_both_slots() raises:
    """`.alias` must not drop the second slot the constructor filled."""
    var a = regr_slope(col("y"), col("x")).alias("slope")
    assert_equal(a.alias_name.value(), String("slope"))
    assert_equal(a.child.value().col_ref_name(), String("x"))
    assert_equal(a.child1.value().col_ref_name(), String("y"))


def test_every_tag_has_a_named_constructor() raises:
    """One named constructor per tag, 0 ..= AGG_KURTOSIS_POP."""
    var funcs = List[UInt8]()
    funcs.append(agg_sum(col("x")).func)
    funcs.append(count().func)
    funcs.append(agg_min(col("x")).func)
    funcs.append(agg_max(col("x")).func)
    funcs.append(mean(col("x")).func)
    funcs.append(count_distinct(col("x")).func)
    funcs.append(first(col("x")).func)
    funcs.append(last(col("x")).func)
    funcs.append(stddev_samp(col("x")).func)
    funcs.append(corr(col("x"), col("y")).func)
    funcs.append(median(col("x")).func)
    funcs.append(largest2(col("x")).func)
    funcs.append(var_samp(col("x")).func)
    funcs.append(covar_pop(col("y"), col("x")).func)
    funcs.append(covar_samp(col("y"), col("x")).func)
    funcs.append(regr_avgx(col("y"), col("x")).func)
    funcs.append(regr_avgy(col("y"), col("x")).func)
    funcs.append(regr_count(col("y"), col("x")).func)
    funcs.append(regr_sxx(col("y"), col("x")).func)
    funcs.append(regr_sxy(col("y"), col("x")).func)
    funcs.append(regr_syy(col("y"), col("x")).func)
    funcs.append(regr_slope(col("y"), col("x")).func)
    funcs.append(regr_intercept(col("y"), col("x")).func)
    funcs.append(regr_r2(col("y"), col("x")).func)
    funcs.append(var_pop(col("x")).func)
    funcs.append(stddev_pop(col("x")).func)
    funcs.append(sem(col("x")).func)
    funcs.append(count_if(col("x")).func)
    funcs.append(bool_and(col("x")).func)
    funcs.append(bool_or(col("x")).func)
    funcs.append(product(col("x")).func)
    funcs.append(any_value(col("x")).func)
    funcs.append(kahan_sum(col("x")).func)
    funcs.append(favg(col("x")).func)
    funcs.append(skewness(col("x")).func)
    funcs.append(kurtosis(col("x")).func)
    funcs.append(kurtosis_pop(col("x")).func)
    var hi = Int(AGG_KURTOSIS_POP)
    assert_equal(len(funcs), hi + 1, "one constructor per tag 0..=36")
    for t in range(hi + 1):
        var seen = 0
        for i in range(len(funcs)):
            if Int(funcs[i]) == t:
                seen += 1
        assert_equal(
            seen, 1, "AGG tag " + String(t) + " must have exactly one constructor"
        )


def main() raises:
    test_one_input_constructors()
    test_bivariate_constructors_take_sql_order_and_swap()
    test_the_aliased_bivariate_keeps_both_slots()
    test_every_tag_has_a_named_constructor()
    print("all agg_expr named-constructor tests passed")
