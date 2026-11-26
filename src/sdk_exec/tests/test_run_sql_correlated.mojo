# =============================================================================
# test_run_sql_correlated: correlated subqueries and EXISTS answer what DuckDB
# answers
# =============================================================================
#
# Covers: run_sql over eight TPC-H-typed Parquet tables DuckDB wrote (the
# :correlated_oracle action in BUCK; orders with no lineitem, customers with no
# order, NULL keys, ties) answers what the pinned DuckDB answers for each case
# of tests/correlated/cases.sql, on one and three workers: the corpus texts of
# TPC-H Q4, Q17, Q20 and Q22, and Q2's body without its ORDER BY and LIMIT;
# correlated scalars over no row (count 0, NULL), with NULL outer and inner
# keys, two keys, two in one WHERE, under OR and BETWEEN (in a WHERE anywhere),
# in a SELECT list and a derived table; a DECIMAL compared with a DOUBLE;
# EXISTS and NOT EXISTS with NULL keys. Q21 and an EXISTS correlated by > are
# refused at lower, Q2 (its ORDER BY is a DECIMAL key, which the sort sink
# refuses) at execute, an EXISTS over a join and the unserved correlated scalar
# shapes at bind, each by name at its step; the TPC-H cases are the corpus
# texts; every case is run.
#
# The pinned DuckDB writes the eight tables of the TPC-H schema
# (tests/correlated/data.sql: small row groups, orders with no lineitem,
# customers with no order, a NULL o_custkey and l_suppkey, ties at q2's
# minimum cost) and answers each query of tests/correlated/cases.sql as a
# build action (`sql_oracle`). This test reads the same cases.sql for the
# query text, runs it through `run_sql` over the same Parquet files, each
# registered under its table name, and compares the answer with DuckDB's by
# value: in DuckDB's row order on the query's ORDER BY keys, or as a multiset
# when it has none (komira_plan_harness). Every case runs on one worker and on
# three. Derived from TPC-H; not comparable to published TPC-H results.
#
#   test_tpch_queries_with_correlated_subqueries_equal_duckdb
#       q4 (EXISTS), q17 (a correlated avg compared with a DECIMAL), q20 (an
#       IN whose body holds an IN and a correlated sum over two keys) and q22
#       (NOT EXISTS in a derived table, beside an uncorrelated avg compared
#       with a DECIMAL) as the corpus writes them, in DuckDB's row order; and
#       q2's body (a correlated min over a four-table body, ties at the
#       minimum) without its ORDER BY and LIMIT, as a multiset.
#   test_correlated_scalars_in_a_where_equal_duckdb
#       a count over no row is 0 (alone, in arithmetic, count(column) against
#       count(*)); avg, min and max over no row are NULL, so a comparison with
#       them keeps no row and IS NULL keeps every row; a NULL outer key
#       matches no group (avg NULL, count 0) and a NULL inner key is no group
#       any outer row matches; two keys; the subquery on the left; two in one
#       WHERE and two in one comparison; under OR; under BETWEEN (which
#       repeats its operand); a qualified outer column
#       of a joined table; a self-correlation through aliases; a DECIMAL
#       column compared with a DOUBLE expression (DuckDB casts the DECIMAL).
#   test_correlated_scalars_in_a_select_list_equal_duckdb
#       one per outer row, NULL where no row matches (a DECIMAL max, a DATE
#       max) and 0 for a count, and one in a derived table's SELECT list
#       filtered outside it.
#   test_exists_and_not_exists_with_null_keys_equal_duckdb
#       EXISTS drops and NOT EXISTS keeps an outer row with a NULL or an
#       unmatched key; NOT EXISTS over a body holding NULL keys; a count over
#       NOT EXISTS.
#   test_shapes_not_served_yet_are_refused_by_name
#       q21 (without its `limit 100`) and an EXISTS correlated by `>` need a
#       SEMI / ANTI join with a residual predicate, refused at step `lower`;
#       an EXISTS over a join is refused at step `bind`; q2 (without its
#       `limit 100`) orders by a DECIMAL, which the sort sink refuses at step
#       `execute`. DuckDB answers each.
#   test_unserved_correlated_scalar_shapes_are_refused_at_bind
#       a correlation that is not `inner = outer`, a body that does not
#       aggregate, a GROUP BY body, an outer column in the SELECT list, a
#       LEFT JOIN body and a correlated scalar in a HAVING, each refused at
#       step `bind` with its own message.
#   test_the_tpch_cases_are_the_corpus_texts
#       each tpch_* line of cases.sql is the bench_corpus text of its query.
#   test_every_case_is_run
#       each case of cases.sql belongs to one of the tests above.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from bench_corpus.catalog import find_query
from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from runtime_paths import data_path, read_data
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_EXECUTE, STEP_LOWER, run_sql


comptime _LIMIT_100 = " limit 100"
comptime _RESIDUAL = "LOWERING_JOIN_UNSERVED: Join (a residual predicate) is not served by the hash join"
comptime _CORR = "SQL not supported: a correlated scalar subquery "


def _tables() -> List[String]:
    return [
        "region", "nation", "supplier", "part", "partsupp", "customer",
        "orders", "lineitem",
    ]


struct _Case(Copyable, Movable):
    var name: String
    var query: String

    def __init__(out self, var name: String, var query: String):
        self.name = name^
        self.query = query^


def _cases() raises -> List[_Case]:
    """Every `COPY (<query>) TO '<name>.tsv' ...;` line of cases.sql."""
    var out = List[_Case]()
    var text = read_data("cases.sql")
    for line in text.split("\n"):
        var l = String(line)
        if not l.startswith("COPY ("):
            continue
        var to = l.rfind(") TO '")
        var tsv = l.rfind(".tsv'")
        assert_true(to > 0 and tsv > to, "a COPY line of cases.sql: " + l)
        out.append(_Case(String(l[byte = to + 6 : tsv]), String(l[byte=6:to])))
    return out^


def _query(name: String, cases: List[_Case]) raises -> String:
    for i in range(len(cases)):
        if cases[i].name == name:
            return cases[i].query
    raise Error("cases.sql holds no case " + name)


def _without_limit_100(query: String) raises -> String:
    """`query` without the `limit 100` it ends with."""
    assert_true(query.endswith(_LIMIT_100), "ends with limit 100: " + query)
    return String(query[byte = 0 : query.byte_length() - String(_LIMIT_100).byte_length()])


def _context(workers: Int) raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    var tables = _tables()
    for i in range(len(tables)):
        register_parquet(ctx, tables[i], data_path(tables[i] + ".parquet"))
    return ctx^


def _keys(var names: List[String]) -> List[String]:
    return names^


def _check(
    name: String,
    query: String,
    var policy: CanonPolicy,
    workers: Int,
    mut problems: List[String],
) raises:
    var label = name + " on " + String(workers) + " workers"
    var ctx = _context(workers)
    var out = run_sql(ctx, query)
    if out.refusal:
        problems.append(
            label + ": refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason
        )
        return
    if len(out.batches) != 1:
        problems.append(label + ": " + String(len(out.batches)) + " batches")
        return
    var actual = render_batch(out.batches[0], policy^)
    try:
        var expected = duckdb_tsv_canon(
            parse_duckdb_tsv(read_data(name + ".tsv")), actual
        )
        var report = compare_canon(expected, actual)
        if not report.ok():
            problems.append(label + ": " + String(report))
    except e:
        problems.append(label + ": " + String(e))


def _report(problems: List[String]) raises:
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def _check_unordered(var names: List[String]) raises:
    var problems = List[String]()
    var cases = _cases()
    for i in range(len(names)):
        var q = _query(names[i], cases)
        _check(names[i], q, CanonPolicy.unordered(), 1, problems)
        _check(names[i], q, CanonPolicy.unordered(), 3, problems)
    _report(problems)


def _duckdb_rows(name: String) raises -> Int:
    """The number of rows DuckDB answered case `name` with."""
    var lines = 0
    for line in read_data(name + ".tsv").split("\n"):
        if String(line) != "":
            lines += 1
    return lines - 1


def _tpch_names() -> List[String]:
    return ["tpch_q2_body", "tpch_q4", "tpch_q17", "tpch_q20", "tpch_q22"]


def _scalar_in_where() -> List[String]:
    return [
        "scalar_count_no_match",
        "scalar_count_compare",
        "scalar_count_expr",
        "scalar_count_column_nulls",
        "scalar_avg_no_match",
        "scalar_empty_body",
        "scalar_null_outer_key_avg",
        "scalar_null_outer_key_count",
        "scalar_null_inner_key",
        "scalar_two_keys",
        "scalar_left_operand",
        "scalar_two_in_where",
        "scalar_under_or",
        "scalar_qualified_outer",
        "decimal_vs_double",
        "scalar_between_count",
        "scalar_between_max",
    ]


def _scalar_in_select() -> List[String]:
    return [
        "scalar_select_item",
        "scalar_select_date",
        "scalar_select_count",
        "scalar_in_derived",
    ]


def _exists() -> List[String]:
    return [
        "exists_null_outer_key",
        "not_exists_null_outer_key",
        "not_exists_null_inner_key",
        "not_exists_count",
    ]


def _refused_names() -> List[String]:
    return ["tpch_q2", "tpch_q21", "exists_non_equi", "exists_join_body"]


def test_tpch_queries_with_correlated_subqueries_equal_duckdb() raises:
    var problems = List[String]()
    var cases = _cases()
    for workers in [1, 3]:
        _check(
            "tpch_q2_body", _query("tpch_q2_body", cases), CanonPolicy.unordered(),
            workers, problems,
        )
        _check(
            "tpch_q4", _query("tpch_q4", cases),
            CanonPolicy.keyed(_keys(["o_orderpriority"])), workers, problems,
        )
        _check(
            "tpch_q17", _query("tpch_q17", cases), CanonPolicy.unordered(),
            workers, problems,
        )
        _check(
            "tpch_q20", _query("tpch_q20", cases),
            CanonPolicy.keyed(_keys(["s_name"])), workers, problems,
        )
        _check(
            "tpch_q22", _query("tpch_q22", cases),
            CanonPolicy.keyed(_keys(["cntrycode"])), workers, problems,
        )
    _report(problems)


def test_correlated_scalars_in_a_where_equal_duckdb() raises:
    _check_unordered(_scalar_in_where())


def test_correlated_scalars_in_a_select_list_equal_duckdb() raises:
    _check_unordered(_scalar_in_select())


def test_exists_and_not_exists_with_null_keys_equal_duckdb() raises:
    _check_unordered(_exists())


def _refused(query: String, step: String, reason: String) raises:
    """`query` is refused at `step` with exactly `reason`, and the context
    runs the next query."""
    var ctx = _context(2)
    var out = run_sql(ctx, query)
    assert_false(out.ok(), "expected a refusal: " + query)
    assert_equal(out.refusal.value().step, step, query)
    assert_equal(out.refusal.value().reason, reason, query)
    assert_equal(len(out.batches), 0)
    var next = run_sql(ctx, "SELECT count(*) AS n FROM region")
    assert_true(next.ok(), "the context runs on after a refusal")


def test_shapes_not_served_yet_are_refused_by_name() raises:
    var cases = _cases()
    var names = _refused_names()
    for i in range(len(names)):
        assert_true(_duckdb_rows(names[i]) > 0, "DuckDB answers " + names[i])
    _refused(
        _without_limit_100(_query("tpch_q21", cases)), String(STEP_LOWER), _RESIDUAL
    )
    _refused(_query("exists_non_equi", cases), String(STEP_LOWER), _RESIDUAL)
    var ctx = _context(2)
    var q2 = run_sql(ctx, _without_limit_100(_query("tpch_q2", cases)))
    assert_false(q2.ok(), "q2 orders by a DECIMAL")
    assert_equal(q2.refusal.value().step, String(STEP_EXECUTE))
    var why = q2.refusal.value().reason
    assert_true(why.startswith("pipeline_exec: the sort sink of segment "), why)
    assert_true(
        why.endswith("sorts by 's_acctbal', of unsupported sort key type decimal128"), why
    )
    _refused(
        _query("exists_join_body", cases),
        String(STEP_BIND),
        "SQL not supported: a predicate subquery must have a single-table FROM",
    )


def test_unserved_correlated_scalar_shapes_are_refused_at_bind() raises:
    var bind = String(STEP_BIND)
    _refused(
        "SELECT p_partkey FROM part WHERE p_size > (SELECT count(*) FROM lineitem WHERE l_partkey < p_partkey)",
        bind,
        _CORR + "whose WHERE names an outer column other than in an `inner_column = outer_column` conjunct",
    )
    _refused(
        "SELECT o_orderkey FROM orders WHERE o_totalprice > (SELECT l_extendedprice FROM lineitem WHERE l_orderkey = o_orderkey)",
        bind,
        _CORR + "whose SELECT list holds no aggregate (its value could be several rows)",
    )
    _refused(
        "SELECT p_partkey FROM part WHERE p_size > (SELECT max(l_quantity) FROM lineitem WHERE l_partkey = p_partkey GROUP BY l_suppkey)",
        bind,
        _CORR + "with GROUP BY, HAVING, DISTINCT, ORDER BY, LIMIT or OFFSET in its body",
    )
    _refused(
        "SELECT p_partkey FROM part WHERE p_size > (SELECT max(l_quantity) + p_size FROM lineitem WHERE l_partkey = p_partkey)",
        bind,
        _CORR + "with an outer column in its SELECT list",
    )
    _refused(
        "SELECT p_partkey FROM part WHERE p_size > (SELECT max(l_quantity) FROM lineitem LEFT JOIN orders ON l_orderkey = o_orderkey WHERE l_partkey = p_partkey)",
        bind,
        _CORR + "whose FROM has a JOIN other than a comma or CROSS join",
    )
    _refused(
        "SELECT p_size, count(*) AS n FROM part GROUP BY p_size HAVING count(*) > (SELECT count(*) FROM lineitem WHERE l_partkey = p_size)",
        bind,
        _CORR + "in a HAVING clause or in the SELECT list of a grouped query",
    )


def _collapse_space(text: String) -> String:
    """`text` with each run of spaces, tabs and newlines made one space."""
    var out = String("")
    var gap = False
    for b in text.as_bytes():
        if b == UInt8(ord(" ")) or b == UInt8(ord("\n")) or b == UInt8(ord("\t")):
            gap = True
            continue
        if gap and out != "":
            out += " "
        gap = False
        out += chr(Int(b))
    return out^


def test_the_tpch_cases_are_the_corpus_texts() raises:
    var cases = _cases()
    var ids = ["q2", "q4", "q17", "q20", "q21", "q22"]
    for i in range(len(ids)):
        var corpus = find_query("tpch/" + ids[i]).text
        assert_equal(
            _query("tpch_" + ids[i], cases), _collapse_space(corpus), ids[i]
        )


def test_every_case_is_run() raises:
    var known = _tpch_names()
    known.extend(_scalar_in_where())
    known.extend(_scalar_in_select())
    known.extend(_exists())
    known.extend(_refused_names())
    var cases = _cases()
    assert_equal(len(cases), len(known), "cases in cases.sql")
    for i in range(len(cases)):
        var found = False
        for j in range(len(known)):
            if cases[i].name == known[j]:
                found = True
        assert_true(found, cases[i].name + " belongs to no test")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
