# =============================================================================
# run_sql: a refusal of the parse step says where the text stopped parsing
# =============================================================================
#
# What each test proves:
#   * test_parse_refusal_carries_the_position: a parser error mid-statement is
#     step `parse` with the parser's own message and the position of the token
#     it was looking at; the same on line 2; a tokenizer error names the
#     unterminated string's opening quote.
#   * test_other_steps_carry_no_position: a refusal at step `bind` has the
#     binder's message and no position, and the context answers the next query.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql


def test_parse_refusal_carries_the_position() raises:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var mid = run_sql(ctx, "SELECT city, count(*) FROM weather GROUP city")
    assert_false(mid.ok())
    ref r = mid.refusal.value()
    assert_equal(r.step, "parse")
    assert_equal(r.reason, "SQL syntax error: expected keyword 'by'")
    assert_true(Bool(r.position))
    assert_equal(r.position.value().line, 1)
    assert_equal(r.position.value().column, 42)

    var second = run_sql(ctx, "SELECT city\nFROM weather GROUP city")
    ref r2 = second.refusal.value()
    assert_equal(r2.step, "parse")
    assert_equal(r2.position.value().line, 2)
    assert_equal(r2.position.value().column, 20)

    var lex = run_sql(ctx, "SELECT 'abc")
    ref r3 = lex.refusal.value()
    assert_equal(r3.step, "parse")
    assert_equal(r3.reason, "SQL syntax error: unterminated string literal")
    assert_equal(r3.position.value().line, 1)
    assert_equal(r3.position.value().column, 8)


def test_other_steps_carry_no_position() raises:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var bind = run_sql(ctx, "select * from nosuch")
    assert_false(bind.ok())
    ref r = bind.refusal.value()
    assert_equal(r.step, "bind")
    assert_false(Bool(r.position))
    var ok = run_sql(ctx, "select 1 as n")
    assert_true(ok.ok())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
