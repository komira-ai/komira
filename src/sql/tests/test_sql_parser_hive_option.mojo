# =============================================================================
# The `hive_partitioning` option of `read_parquet`
# =============================================================================
#
#   1. No option leaves the mode at AUTO; `hive_partitioning = true` is ON and
#      `= false` is OFF, for `read_parquet` and for a path that is a glob.
#   2. A value that is not a boolean literal is refused as a syntax error
#      naming the option.
#   3. The option on `read_csv`, `read_json` and `read_avro` is refused by name,
#      and a CSV relation keeps its AUTO mode.

from std.testing import TestSuite, assert_equal, assert_true

from sql.sql_ast import (
    HIVE_PARTITIONING_AUTO,
    HIVE_PARTITIONING_OFF,
    HIVE_PARTITIONING_ON,
)
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _mode(sql: String) raises -> UInt8:
    return parse_sql(tokenize(sql)).query.from_tables[0].tvf_opts.hive_partitioning


def _refusal(sql: String) -> String:
    try:
        _ = parse_sql(tokenize(sql))
    except e:
        return String(e)
    return String("")


def test_mode_defaults_to_auto_and_follows_the_option() raises:
    assert_equal(_mode("SELECT a FROM read_parquet('p.parquet')"), HIVE_PARTITIONING_AUTO)
    assert_equal(
        _mode("SELECT a FROM read_parquet('d/*.parquet', hive_partitioning = true)"),
        HIVE_PARTITIONING_ON,
    )
    assert_equal(
        _mode("SELECT a FROM read_parquet('d/*.parquet', hive_partitioning = false)"),
        HIVE_PARTITIONING_OFF,
    )
    assert_equal(_mode("SELECT a FROM 'd/*.parquet'"), HIVE_PARTITIONING_AUTO)


def test_a_non_boolean_value_is_refused() raises:
    assert_equal(
        _refusal("SELECT a FROM read_parquet('p.parquet', hive_partitioning = 'yes')"),
        "SQL syntax error: read_parquet option 'hive_partitioning' expects TRUE or FALSE",
    )
    assert_equal(
        _refusal("SELECT a FROM read_parquet('p.parquet', hive_partitioning = 1)"),
        "SQL syntax error: read_parquet option 'hive_partitioning' expects TRUE or FALSE",
    )


def test_the_option_is_refused_on_the_other_readers() raises:
    var csv = _refusal("SELECT a FROM read_csv('p.csv', hive_partitioning = true)")
    assert_true(csv.find("read_csv option 'hive_partitioning' is a read_parquet option") >= 0)
    var json = _refusal("SELECT a FROM read_json('p.jsonl', hive_partitioning = true)")
    assert_true(json.find("read_json option 'hive_partitioning' is a read_parquet option") >= 0)
    var avro = _refusal("SELECT a FROM read_avro('p.avro', hive_partitioning = true)")
    assert_true(avro.find("read_avro('p.avro', ...) takes NO options") >= 0)
    assert_equal(_mode("SELECT a FROM read_csv('p.csv')"), HIVE_PARTITIONING_AUTO)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
