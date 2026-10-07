# =============================================================================
# The name tables of komira_sql.sql_ast
# =============================================================================
#
# Every name each table answers for, and one name it does not:
#   1. sql_call_is_aggregate: all 37 statistical aggregate names are True;
#      the six fast-path names and a scalar are False.
#      (mutant caught: any one name dropped from the `or` chain)
#   2. sql_agg_code: the six fast-path names map to their SXAGG_* codes
#      (`mean` is `avg`); anything else is -1.
#      (mutant caught: `mean` mapped to another code, a name dropped)
#   3. The two halves are disjoint: no name is in both.
#      (mutant caught: a fast-path name added to the statistical set)
#   4. sql_win_ranking_code, sql_win_dist_code, sql_win_value_code: each name
#      maps to its SXWIN_* code (`rank_dense` is `dense_rank`); anything else
#      is -1.
#      (mutant caught: a code swapped between two names)
#   5. sql_name_claimed_by_grammar: one name per namespace, in the order the
#      function asks (fast path, statistical, ranking, grammar form, reserved
#      word, free), and the names it deliberately leaves free.
#      (mutant caught: a namespace arm removed or returning another code)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_sql.sql_ast import (
    sql_agg_code,
    sql_call_is_aggregate,
    sql_name_claimed_by_grammar,
    sql_win_dist_code,
    sql_win_ranking_code,
    sql_win_value_code,
    SQLNAME_FREE,
    SQLNAME_AGG_FASTPATH,
    SQLNAME_AGG_STATISTICAL,
    SQLNAME_WINDOW_RANKING,
    SQLNAME_GRAMMAR_FORM,
    SQLNAME_RESERVED_WORD,
    SXAGG_SUM,
    SXAGG_COUNT,
    SXAGG_MIN,
    SXAGG_MAX,
    SXAGG_AVG,
    SXWIN_ROW_NUMBER,
    SXWIN_RANK,
    SXWIN_DENSE_RANK,
    SXWIN_LAG,
    SXWIN_LEAD,
    SXWIN_FIRST_VALUE,
    SXWIN_LAST_VALUE,
    SXWIN_NTH_VALUE,
    SXWIN_PERCENT_RANK,
    SXWIN_CUME_DIST,
    SXWIN_NTILE,
)


def _statistical_names() -> List[String]:
    return [
        "median", "stddev", "stddev_samp", "corr", "var_samp", "variance",
        "covar_pop", "covar_samp", "regr_avgx", "regr_avgy", "regr_count",
        "regr_intercept", "regr_r2", "regr_slope", "regr_sxx", "regr_sxy",
        "regr_syy", "var_pop", "stddev_pop", "sem", "count_star", "count_if",
        "countif", "bool_and", "bool_or", "product", "any_value", "arbitrary",
        "first", "last", "fsum", "kahan_sum", "sumkahan", "favg", "skewness",
        "kurtosis", "kurtosis_pop",
    ]


def _fast_path_names() -> List[String]:
    return ["sum", "count", "min", "max", "avg", "mean"]


def test_every_statistical_aggregate_name() raises:
    var names = _statistical_names()
    assert_equal(len(names), 37)
    for i in range(len(names)):
        assert_true(sql_call_is_aggregate(names[i]), names[i])
    assert_false(sql_call_is_aggregate("upper"))
    assert_false(sql_call_is_aggregate(""))
    # The match is exact: no prefix, no case folding (callers pass folded text).
    assert_false(sql_call_is_aggregate("medians"))
    assert_false(sql_call_is_aggregate("MEDIAN"))


def test_fast_path_aggregate_codes() raises:
    assert_equal(sql_agg_code("sum"), Int(SXAGG_SUM))
    assert_equal(sql_agg_code("count"), Int(SXAGG_COUNT))
    assert_equal(sql_agg_code("min"), Int(SXAGG_MIN))
    assert_equal(sql_agg_code("max"), Int(SXAGG_MAX))
    assert_equal(sql_agg_code("avg"), Int(SXAGG_AVG))
    assert_equal(sql_agg_code("mean"), Int(SXAGG_AVG))
    assert_equal(sql_agg_code("median"), -1)
    assert_equal(sql_agg_code(""), -1)


def test_the_two_aggregate_halves_are_disjoint() raises:
    var fast = _fast_path_names()
    for i in range(len(fast)):
        assert_false(sql_call_is_aggregate(fast[i]), fast[i])
    var stat = _statistical_names()
    for i in range(len(stat)):
        assert_equal(sql_agg_code(stat[i]), -1, stat[i])


def test_window_function_codes() raises:
    assert_equal(sql_win_ranking_code("rank"), Int(SXWIN_RANK))
    assert_equal(sql_win_ranking_code("row_number"), Int(SXWIN_ROW_NUMBER))
    assert_equal(sql_win_ranking_code("dense_rank"), Int(SXWIN_DENSE_RANK))
    assert_equal(sql_win_ranking_code("rank_dense"), Int(SXWIN_DENSE_RANK))
    assert_equal(sql_win_ranking_code("ntile"), -1)

    assert_equal(sql_win_dist_code("percent_rank"), Int(SXWIN_PERCENT_RANK))
    assert_equal(sql_win_dist_code("cume_dist"), Int(SXWIN_CUME_DIST))
    assert_equal(sql_win_dist_code("ntile"), Int(SXWIN_NTILE))
    assert_equal(sql_win_dist_code("rank"), -1)

    assert_equal(sql_win_value_code("lag"), Int(SXWIN_LAG))
    assert_equal(sql_win_value_code("lead"), Int(SXWIN_LEAD))
    assert_equal(sql_win_value_code("first_value"), Int(SXWIN_FIRST_VALUE))
    assert_equal(sql_win_value_code("last_value"), Int(SXWIN_LAST_VALUE))
    assert_equal(sql_win_value_code("nth_value"), Int(SXWIN_NTH_VALUE))
    assert_equal(sql_win_value_code("first"), -1)


def test_names_the_grammar_claims() raises:
    var fast = _fast_path_names()
    for i in range(len(fast)):
        assert_equal(sql_name_claimed_by_grammar(fast[i]), SQLNAME_AGG_FASTPATH, fast[i])
    var stat = _statistical_names()
    for i in range(len(stat)):
        assert_equal(sql_name_claimed_by_grammar(stat[i]), SQLNAME_AGG_STATISTICAL, stat[i])
    var ranking: List[String] = ["rank", "row_number", "dense_rank", "rank_dense"]
    for i in range(len(ranking)):
        assert_equal(sql_name_claimed_by_grammar(ranking[i]), SQLNAME_WINDOW_RANKING, ranking[i])
    var forms: List[String] = ["case", "extract", "cast", "try_cast"]
    for i in range(len(forms)):
        assert_equal(sql_name_claimed_by_grammar(forms[i]), SQLNAME_GRAMMAR_FORM, forms[i])
    var reserved: List[String] = ["not", "exists", "distinct"]
    for i in range(len(reserved)):
        assert_equal(sql_name_claimed_by_grammar(reserved[i]), SQLNAME_RESERVED_WORD, reserved[i])
    # Claimed only under another following token, so free in `name(arg)`
    # shape: date, timestamp, true; and the value / distribution windows,
    # which are windows only when OVER follows.
    var free: List[String] = [
        "upper", "date", "timestamp", "timestamptz", "true", "false", "lag", "ntile",
    ]
    for i in range(len(free)):
        assert_equal(sql_name_claimed_by_grammar(free[i]), SQLNAME_FREE, free[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
