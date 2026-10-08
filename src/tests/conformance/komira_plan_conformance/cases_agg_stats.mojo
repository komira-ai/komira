# =============================================================================
# komira_plan_conformance/cases_agg_stats.mojo -- shard agg_stats.
# =============================================================================
#
# AVG, the variance and standard-deviation family, MEDIAN, COUNT(DISTINCT)
# and MIN/MAX over strings, citing query semantics §2.1 to §2.5, §2.10 to
# §2.12, §4.6, and the result types of §8.5 to §8.7 and §8.16. Two datasets:
#   stat_rows  g = 1: i = 2, 5, 8; f = 1.0, 2.5, 4.0; s = "apple", "Zebra",
#              "app"; d = 4, 4, 9; plus one all-NULL row. g = 2: one row
#              (i = 7, f = -0.5, s = "pear", d = 4). g = 3: two all-NULL
#              rows. So each statistic is seen over n = 3, n = 1 and n = 0
#              non-NULL values.
#   avg_rows   g = 1: i = 2^53 + 1 and 1, f = 0.25, 0.5; g = 2: i = 1, 2,
#              3, 5, f = -1.5, 2.0, 0.5, 1.0, and an all-NULL row; g = 3: an
#              all-NULL row.
# Every expectation is HAND, its derivation in the .tsv. An aggregate root
# promises no order (§4.8), so every case compares its rows as a multiset.
#
# Floats. The inputs are chosen so the exact answers are doubles: AVG of i
# over g = 1 of stat_rows is 15 / 3 = 5; M2 (the sum of squared deviations)
# is 18 for i and 4.5 for f, so VAR_SAMP is 9 and 2.25, VAR_POP 6 and 1.5,
# STDDEV_SAMP 3 and 1.5. No n = 3 group can make both standard deviations
# rational (n / (n - 1) is not a square), so STDDEV_POP is sqrt(6) and
# sqrt(1.5): the expected cell is the double nearest the exact root, with its
# bits and the integer bounds that fix them in the derivation. Only float
# SUM and AVG may vary with summation order (§2.10), so only the float AVG
# columns carry a tolerance (ulps=1, the least that is not bit for bit);
# their inputs are dyadic with short mantissas, so every partial sum is exact
# in any order and the stated bits are the only answer. Every other float
# column is compared bit for bit.
#
# Not here, and why:
#   - MEDIAN of FLOAT32 or DECIMAL: the result type is UNDECIDED (§8.17).
#   - MEDIAN over an even count, and over a group with no non-NULL value:
#     the document fixes MEDIAN's type (§8.16) and its NULL skipping (§2.1)
#     but not its value between the two middle values, and §2.2's all-NULL
#     rule names SUM, AVG, MIN and MAX only. Every MEDIAN group here has an
#     odd count (median_odd_counts filters out g = 3); MEDIAN over empty
#     input is §2.3's "every other aggregate NULL".
#   - MEDIAN over NaN: UNDECIDED (§2.8). JSON cannot carry NaN anyway.
#   - VAR/STDDEV over floats whose sum varies with order: §2.10 names SUM
#     and AVG only, so no tolerance could be cited for them.
#
# The defect each case would catch once it executes:
#   avg_int_float          integer AVG accumulated in DOUBLE (2^53 + 1 reads
#                          as 2^53, so g = 1 gives 2^52, §2.12); AVG
#                          counting NULLs in the divisor (g = 2 as 11 / 5);
#                          an all-NULL AVG as 0 or NaN
#   var_stddev_by_count    VAR_SAMP/STDDEV_SAMP of one value as NaN or 0
#                          (§2.11; "Code that does not follow", item 7);
#                          VAR_POP of one value as NULL; population and
#                          sample divisors swapped; NULL counted as 0
#   median_odd_counts      the NULL in g = 1 taken as a value; an integer
#                          median truncated
#   min_max_strings        a case-insensitive or locale collation (min
#                          "app", max "Zebra"); a prefix sorting after its
#                          extension
#   count_distinct_nulls   COUNT(DISTINCT d) counting the NULL as a value,
#                          or counting duplicates
#   stats_empty_input      zero rows, or 0 for AVG/VAR/MEDIAN over empty input
# =============================================================================

from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MEDIAN,
    AGG_MIN,
    AGG_STDDEV_POP,
    AGG_STDDEV_SAMP,
    AGG_VAR_POP,
    AGG_VAR_SAMP,
    AggExpr,
)
from komira_plan_expr.expr import BIN_LT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy, FloatTolerance
from komira_plan_ir.logical_plan import AggExprArray, ExprArray, LogicalPlan

from .plan_case import Case
from .datasets import avg_rows, scan, stat_rows

comptime SHARD = "agg_stats"


def _agg(func: UInt8, column: String, name: String) -> AggExpr:
    """`func(column) AS name`; an empty `column` is COUNT(*)."""
    var child: Optional[Expr] = None
    if column.byte_length() > 0:
        child = Expr.col_ref(column)
    return AggExpr(func, child^, Optional(name))


def _by_g() -> ExprArray:
    var g = ExprArray()
    g.append(Expr.col_ref("g"))
    return g^


def _where_lt(column: String, bound: Int, var input: LogicalPlan) raises -> LogicalPlan:
    """`input WHERE column < bound`."""
    return LogicalPlan.filter(
        Expr.binary(
            BIN_LT,
            Expr.col_ref(column),
            Expr.literal(ScalarValue.from_int64(Int64(bound))),
        ),
        input^,
    )


def _float_avg_policy(*columns: String) -> CanonPolicy:
    """Multiset rows, bit-exact floats except the named float AVG columns,
    which §2.10 compares within a tolerance."""
    var p = CanonPolicy.unordered()
    for c in columns:
        p.set_column_tolerance(c, FloatTolerance.of_ulps(1))
    return p^


def _avg_int_float() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_MEAN, "i", "avg_i"))
    a.append(_agg(AGG_MEAN, "f", "avg_f"))
    return LogicalPlan.aggregate(_by_g(), a^, scan(avg_rows()))


def _var_stddev_by_count() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_COUNT, "i", "n"))
    a.append(_agg(AGG_VAR_SAMP, "i", "var_samp_i"))
    a.append(_agg(AGG_VAR_POP, "i", "var_pop_i"))
    a.append(_agg(AGG_STDDEV_SAMP, "i", "sd_samp_i"))
    a.append(_agg(AGG_STDDEV_POP, "i", "sd_pop_i"))
    a.append(_agg(AGG_VAR_SAMP, "f", "var_samp_f"))
    a.append(_agg(AGG_VAR_POP, "f", "var_pop_f"))
    a.append(_agg(AGG_STDDEV_SAMP, "f", "sd_samp_f"))
    a.append(_agg(AGG_STDDEV_POP, "f", "sd_pop_f"))
    return LogicalPlan.aggregate(_by_g(), a^, scan(stat_rows()))


def _median_odd_counts() raises -> LogicalPlan:
    """MEDIAN over g = 1 (three values) and g = 2 (one); g = 3, which has
    none, is filtered out (g < 3)."""
    var a = AggExprArray()
    a.append(_agg(AGG_MEDIAN, "i", "med_i"))
    a.append(_agg(AGG_MEDIAN, "f", "med_f"))
    return LogicalPlan.aggregate(_by_g(), a^, _where_lt("g", 3, scan(stat_rows())))


def _min_max_strings() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_MIN, "s", "lo"))
    a.append(_agg(AGG_MAX, "s", "hi"))
    return LogicalPlan.aggregate(_by_g(), a^, scan(stat_rows()))


def _count_distinct_nulls() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_COUNT, "", "n"))
    a.append(_agg(AGG_COUNT, "d", "nd"))
    a.append(_agg(AGG_COUNT_DISTINCT, "d", "nd_distinct"))
    return LogicalPlan.aggregate(_by_g(), a^, scan(stat_rows()))


def _stats_empty_input() raises -> LogicalPlan:
    """No grouping keys over stat_rows WHERE id < 0 (no row: ids are 1 to 7)."""
    var a = AggExprArray()
    a.append(_agg(AGG_COUNT, "", "n"))
    a.append(_agg(AGG_COUNT_DISTINCT, "d", "nd_distinct"))
    a.append(_agg(AGG_MEAN, "i", "avg_i"))
    a.append(_agg(AGG_MEAN, "f", "avg_f"))
    a.append(_agg(AGG_VAR_SAMP, "i", "var_samp_i"))
    a.append(_agg(AGG_VAR_POP, "i", "var_pop_i"))
    a.append(_agg(AGG_STDDEV_SAMP, "i", "sd_samp_i"))
    a.append(_agg(AGG_STDDEV_POP, "i", "sd_pop_i"))
    a.append(_agg(AGG_MEDIAN, "i", "med_i"))
    a.append(_agg(AGG_MIN, "s", "lo"))
    return LogicalPlan.aggregate(ExprArray(), a^, _where_lt("id", 0, scan(stat_rows())))


def cases() -> List[Case]:
    return [
        Case.hand("avg_int_float", SHARD, _avg_int_float, _float_avg_policy("avg_f")),
        Case.hand("var_stddev_by_count", SHARD, _var_stddev_by_count, CanonPolicy.unordered()),
        Case.hand("median_odd_counts", SHARD, _median_odd_counts, CanonPolicy.unordered()),
        Case.hand("min_max_strings", SHARD, _min_max_strings, CanonPolicy.unordered()),
        Case.hand("count_distinct_nulls", SHARD, _count_distinct_nulls, CanonPolicy.unordered()),
        Case.hand("stats_empty_input", SHARD, _stats_empty_input, _float_avg_policy("avg_f")),
    ]
