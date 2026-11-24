# =============================================================================
# The parser's limit on nesting
# =============================================================================
#
#   1. A statement nested to exactly `MAX_SQL_NESTING` levels parses, for each
#      construct that recurses: parentheses, prefix NOT, prefix `-`, `+` and
#      `@`, function calls, CASE, IN lists, scalar, IN and EXISTS subqueries,
#      and derived tables, also as a branch of a set operation.
#   2. One level more is refused with the same message, and a statement nested
#      100000 levels deep is refused rather than overflowing the stack.
#   3. Siblings at depth do not add up: the count returns when a level closes.

from std.testing import TestSuite, assert_equal

from sql.sql_nesting import MAX_SQL_NESTING
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


comptime _REFUSAL = "SQL syntax error: the statement nests deeper than 100 levels"


def _rep(unit: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += unit
    return out^


def _refusal(sql: String) -> String:
    try:
        _ = parse_sql(tokenize(sql))
    except e:
        return String(e)
    return String("")


def _parens(n: Int) -> String:
    return "SELECT " + _rep("(", n) + "1" + _rep(")", n)


def _nots(n: Int) -> String:
    return "SELECT " + _rep("NOT ", n) + "true"


def _minuses(n: Int) -> String:
    return "SELECT " + _rep("- ", n) + "1"


def _pluses(n: Int) -> String:
    return "SELECT " + _rep("+ ", n) + "1"


def _abs_ats(n: Int) -> String:
    return "SELECT " + _rep("@ ", n) + "1"


def _calls(n: Int) -> String:
    return "SELECT " + _rep("abs(", n) + "1" + _rep(")", n)


def _cases(n: Int) -> String:
    return "SELECT " + _rep("CASE WHEN ", n) + "true" + _rep(" THEN 1 END", n)


def _in_lists(n: Int) -> String:
    return "SELECT " + _rep("1 IN (", n) + "1" + _rep(")", n)


def _scalar_subqueries(n: Int) -> String:
    return "SELECT " + _rep("(SELECT ", n) + "1" + _rep(")", n)


def _in_subqueries(n: Int) -> String:
    return "SELECT 1 FROM t WHERE " + _rep("a IN (SELECT a FROM t WHERE ", n) + "true" + _rep(")", n)


def _exists_subqueries(n: Int) -> String:
    return "SELECT 1 FROM t WHERE " + _rep("EXISTS (SELECT 1 FROM t WHERE ", n) + "true" + _rep(")", n)


def _derived_tables(n: Int) -> String:
    return _rep("SELECT * FROM (", n) + "SELECT 1" + _rep(")", n)


def _derived_set_operations(n: Int, op: String) -> String:
    """`n` derived tables, each the second branch of a set operation inside
    the one around it."""
    return (
        "SELECT * FROM "
        + _rep("(SELECT 1 " + op + " SELECT * FROM ", n - 1)
        + "(SELECT 1)"
        + _rep(")", n - 1)
    )


def _accepted_at_the_maximum(sql: String) raises:
    assert_equal(_refusal(sql), "")


def test_the_limit_is_one_hundred() raises:
    assert_equal(MAX_SQL_NESTING, 100)


def test_parentheses_nest_to_the_maximum() raises:
    _accepted_at_the_maximum(_parens(100))
    assert_equal(_refusal(_parens(101)), _REFUSAL)


def test_prefix_not_nests_to_the_maximum() raises:
    _accepted_at_the_maximum(_nots(100))
    assert_equal(_refusal(_nots(101)), _REFUSAL)


def test_prefix_minus_nests_to_the_maximum() raises:
    _accepted_at_the_maximum(_minuses(100))
    assert_equal(_refusal(_minuses(101)), _REFUSAL)


def test_prefix_plus_and_at_nest_to_the_maximum() raises:
    _accepted_at_the_maximum(_pluses(100))
    assert_equal(_refusal(_pluses(101)), _REFUSAL)
    _accepted_at_the_maximum(_abs_ats(100))
    assert_equal(_refusal(_abs_ats(101)), _REFUSAL)


def test_function_calls_and_case_nest_to_the_maximum() raises:
    _accepted_at_the_maximum(_calls(100))
    assert_equal(_refusal(_calls(101)), _REFUSAL)
    _accepted_at_the_maximum(_cases(100))
    assert_equal(_refusal(_cases(101)), _REFUSAL)


def test_in_lists_nest_to_the_maximum() raises:
    _accepted_at_the_maximum(_in_lists(100))
    assert_equal(_refusal(_in_lists(101)), _REFUSAL)


def test_scalar_subqueries_nest_to_the_maximum() raises:
    _accepted_at_the_maximum(_scalar_subqueries(100))
    assert_equal(_refusal(_scalar_subqueries(101)), _REFUSAL)


def test_in_and_exists_subqueries_nest_to_the_maximum() raises:
    _accepted_at_the_maximum(_in_subqueries(100))
    assert_equal(_refusal(_in_subqueries(101)), _REFUSAL)
    _accepted_at_the_maximum(_exists_subqueries(100))
    assert_equal(_refusal(_exists_subqueries(101)), _REFUSAL)


def test_derived_tables_nest_to_the_maximum() raises:
    _accepted_at_the_maximum(_derived_tables(100))
    assert_equal(_refusal(_derived_tables(101)), _REFUSAL)


def test_derived_tables_in_set_operations_nest_to_the_maximum() raises:
    for op in [String("UNION ALL"), String("INTERSECT"), String("EXCEPT")]:
        _accepted_at_the_maximum(_derived_set_operations(100, op))
        assert_equal(_refusal(_derived_set_operations(101, op)), _REFUSAL)
        assert_equal(_refusal(_derived_set_operations(100000, op)), _REFUSAL)


def test_a_statement_nested_one_hundred_thousand_deep_is_refused() raises:
    assert_equal(_refusal(_parens(100000)), _REFUSAL)
    assert_equal(_refusal(_nots(100000)), _REFUSAL)
    assert_equal(_refusal(_minuses(100000)), _REFUSAL)
    assert_equal(_refusal(_scalar_subqueries(100000)), _REFUSAL)
    assert_equal(_refusal(_derived_tables(100000)), _REFUSAL)
    assert_equal(_refusal(_in_lists(100000)), _REFUSAL)
    assert_equal(_refusal(_calls(100000)), _REFUSAL)


def test_siblings_at_depth_do_not_add_up() raises:
    # 200 terms side by side, and two terms each nested 99 levels deep.
    var inner = _rep("(", 99) + "1" + _rep(")", 99)
    assert_equal(_refusal("SELECT " + inner + " + " + inner), "")
    assert_equal(_refusal("SELECT (1)" + _rep(" + (1)", 199)), "")
    var items = String("SELECT (1)")
    for _ in range(199):
        items += ", (1)"
    assert_equal(_refusal(items), "")
    assert_equal(_refusal("SELECT " + _rep("NOT true AND ", 199) + "true"), "")
    assert_equal(_refusal("SELECT " + _rep("-1 + ", 199) + "1"), "")
    assert_equal(_refusal("SELECT " + _rep("(SELECT 1) + ", 199) + "1"), "")
    assert_equal(_refusal("SELECT 1 IN (1, 2, 3, 4, 5) AND " + _rep("1 IN (1) AND ", 199) + "true"), "")


def test_a_level_closed_frees_its_room_for_the_next() raises:
    var deep = _rep("(", 100) + "1" + _rep(")", 100)
    assert_equal(_refusal("SELECT " + deep + " + " + deep), "")
    var sub = _rep("(SELECT ", 100) + "1" + _rep(")", 100)
    assert_equal(_refusal("SELECT " + sub + ", " + sub), "")


def test_a_token_list_that_ends_inside_parentheses_is_refused() raises:
    # With no EOF token the parser stays on the last token, the `(`, so each
    # `(` it reads opens one more level until the limit refuses it: the
    # guard for a `(` with no token after it holds.
    var tokens = tokenize("SELECT (")
    _ = tokens.pop()
    var message = String("")
    try:
        _ = parse_sql(tokens^)
    except e:
        message = String(e)
    assert_equal(message, _REFUSAL)


def test_a_token_list_that_ends_on_a_name_is_not_a_call() raises:
    # A name with no token after it is a column, not a call: the parser
    # reads it and refuses the missing end of the statement instead.
    var tokens = tokenize("SELECT x")
    _ = tokens.pop()
    var message = String("")
    try:
        _ = parse_sql(tokens^)
    except e:
        message = String(e)
    assert_equal(message, "SQL syntax error: unexpected trailing tokens after query")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
