# =============================================================================
# sql_parser: the `iceberg_scan` table function
# =============================================================================
#
# What each test proves:
#   1. test_iceberg_scan_binds_kind_path_and_alias: `iceberg_scan('<path>')`
#      is a TVF_ICEBERG relation carrying its path, answering to the function
#      name when unaliased and to its alias otherwise, with the defaults
#      `allow_moved_paths = false` and no snapshot id.
#   2. test_iceberg_options_are_recorded: `allow_moved_paths = true | false`
#      and `snapshot_from_id = <integer>` are recorded, in either order, and
#      the largest BIGINT is kept whole.
#   3. test_iceberg_scan_refuses_the_options_of_other_readers: every CSV,
#      JSON and Parquet option on `iceberg_scan` is refused by exact message.
#   4. test_the_iceberg_options_are_refused_on_other_readers: both Iceberg
#      options on read_parquet, read_csv and read_json are refused by exact
#      message.
#   5. test_iceberg_options_duckdb_has_are_refused_by_name: version,
#      version_name_format, mode, metadata_compression_codec,
#      skip_schema_inference and snapshot_from_timestamp are refused by exact
#      message, as is any other name.
#   6. test_malformed_iceberg_calls_are_refused: a non-string path, a bare
#      option name, a non-boolean, a non-integer, a negative or a too large
#      snapshot id, and an unclosed call are refused by exact message.
#   7. test_the_iceberg_kind_is_not_a_parquet_kind: `is_parquet_tvf_kind` is
#      false for TVF_ICEBERG and still true for TVF_PARQUET.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from sql.sql_ast import SqlStatement, TVF_ICEBERG, TVF_PARQUET
from sql.sql_bind_parquet import is_parquet_tvf_kind
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize

comptime _TAIL: String = (
    " It is REJECTED rather than ignored — an ignored option can change the"
    " result silently."
)
comptime _ICEBERG_WHY: String = (
    " An Iceberg table's metadata names its schema and its files, so there is"
    " no dialect for this option to steer."
)
comptime _PARQUET_WHY: String = (
    " A parquet file is SELF-DESCRIBING: its footer carries the column names,"
    " the physical types and the per-column-chunk codec, so there is no header"
    " line, delimiter, quote character or type-inference pass for this option"
    " to steer (and the codec is per chunk, not per file)."
)


def _parse(sql: String) raises -> SqlStatement:
    return parse_sql(tokenize(sql))


def _ice(call: String) raises -> SqlStatement:
    return _parse("SELECT * FROM " + call)


def _refusal(sql: String) raises -> String:
    try:
        _ = _parse(sql)
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + sql)


def _on_iceberg(options: String) raises -> String:
    return _refusal("SELECT * FROM iceberg_scan('t', " + options + ")")


def test_iceberg_scan_binds_kind_path_and_alias() raises:
    var st = _ice("iceberg_scan('warehouse/db/orders')")
    ref rel = st.query.from_tables[0]
    assert_equal(Int(rel.tvf_kind), Int(TVF_ICEBERG))
    assert_equal(rel.tvf_path.value(), "warehouse/db/orders")
    assert_equal(rel.rel_alias, "iceberg_scan")
    assert_equal(rel.name, "")
    assert_false(rel.tvf_opts.allow_moved_paths)
    assert_false(Bool(rel.tvf_opts.snapshot_from_id))
    var aliased = _ice("iceberg_scan('t.metadata.json') AS o")
    assert_equal(aliased.query.from_tables[0].rel_alias, "o")
    assert_equal(
        aliased.query.from_tables[0].tvf_path.value(), "t.metadata.json"
    )
    # Without `(` the name is an ordinary table.
    var plain = _ice("iceberg_scan")
    assert_equal(plain.query.from_tables[0].name, "iceberg_scan")
    assert_equal(Int(plain.query.from_tables[0].tvf_kind), 0)


def test_iceberg_options_are_recorded() raises:
    var moved = _ice("iceberg_scan('t', allow_moved_paths = true)")
    assert_true(moved.query.from_tables[0].tvf_opts.allow_moved_paths)
    assert_false(Bool(moved.query.from_tables[0].tvf_opts.snapshot_from_id))
    var off = _ice("iceberg_scan('t', allow_moved_paths = false)")
    assert_false(off.query.from_tables[0].tvf_opts.allow_moved_paths)
    var snap = _ice("iceberg_scan('t', snapshot_from_id = 123)")
    assert_equal(snap.query.from_tables[0].tvf_opts.snapshot_from_id.value(), Int64(123))
    assert_false(snap.query.from_tables[0].tvf_opts.allow_moved_paths)
    var both = _ice(
        "iceberg_scan('t', snapshot_from_id = 7, allow_moved_paths = true)"
    )
    assert_true(both.query.from_tables[0].tvf_opts.allow_moved_paths)
    assert_equal(both.query.from_tables[0].tvf_opts.snapshot_from_id.value(), Int64(7))
    var other_order = _ice(
        "iceberg_scan('t', allow_moved_paths = true, snapshot_from_id = 0)"
    )
    assert_true(other_order.query.from_tables[0].tvf_opts.allow_moved_paths)
    assert_equal(
        other_order.query.from_tables[0].tvf_opts.snapshot_from_id.value(),
        Int64(0),
    )
    var big = _ice("iceberg_scan('t', snapshot_from_id = 9223372036854775807)")
    assert_equal(
        big.query.from_tables[0].tvf_opts.snapshot_from_id.value(),
        Int64(9223372036854775807),
    )


def test_iceberg_scan_refuses_the_options_of_other_readers() raises:
    var csv_names: List[String] = [
        "header = true", "has_header = true",
        "delim = '|'", "sep = '|'", "delimiter = '|'",
        "quote = '\"'", "escape = '\"'", "parallel = true", "skip = 1",
    ]
    var keys: List[String] = [
        "header", "has_header", "delim", "sep", "delimiter", "quote", "escape",
        "parallel", "skip",
    ]
    for i in range(len(csv_names)):
        assert_equal(
            _on_iceberg(csv_names[i]),
            "SQL not supported: iceberg_scan option '" + keys[i]
            + "' is a read_csv option and means nothing here." + _ICEBERG_WHY
            + _TAIL,
        )
    assert_equal(
        _on_iceberg("auto_detect = true"),
        "SQL not supported: iceberg_scan option 'auto_detect' is a read_csv /"
        " read_json option and means nothing here." + _ICEBERG_WHY + _TAIL,
    )
    assert_equal(
        _on_iceberg("compression = 'gzip'"),
        "SQL not supported: iceberg_scan option 'compression' is a read_csv /"
        " read_json option and means nothing here." + _ICEBERG_WHY + _TAIL,
    )
    assert_equal(
        _on_iceberg("hive_partitioning = true"),
        "SQL not supported: iceberg_scan option 'hive_partitioning' is a"
        " read_parquet option and means nothing here." + _ICEBERG_WHY + _TAIL,
    )
    assert_equal(
        _on_iceberg("all_varchar = true"),
        "SQL not supported: 'all_varchar' is a read_csv option",
    )
    assert_equal(
        _on_iceberg("format = 'auto'"),
        "SQL not supported: 'format' is a read_json option",
    )


def test_the_iceberg_options_are_refused_on_other_readers() raises:
    assert_equal(
        _refusal("SELECT * FROM read_parquet('f', allow_moved_paths = true)"),
        "SQL not supported: read_parquet option 'allow_moved_paths' is a"
        " iceberg_scan option and means nothing here." + _PARQUET_WHY + _TAIL,
    )
    assert_equal(
        _refusal("SELECT * FROM read_parquet('f', snapshot_from_id = 1)"),
        "SQL not supported: read_parquet option 'snapshot_from_id' is a"
        " iceberg_scan option and means nothing here." + _PARQUET_WHY + _TAIL,
    )
    assert_equal(
        _refusal("SELECT * FROM read_csv('f', allow_moved_paths = true)"),
        "SQL not supported: read_csv option 'allow_moved_paths' is a"
        " iceberg_scan option and means nothing here." + _TAIL,
    )
    assert_equal(
        _refusal("SELECT * FROM read_csv('f', snapshot_from_id = 1)"),
        "SQL not supported: read_csv option 'snapshot_from_id' is a"
        " iceberg_scan option and means nothing here." + _TAIL,
    )
    assert_equal(
        _refusal("SELECT * FROM read_json('f', snapshot_from_id = 1)"),
        "SQL not supported: read_json option 'snapshot_from_id' is a"
        " iceberg_scan option and means nothing here. JSONL records are"
        " SELF-DELIMITING — one JSON object per line, with every value tagged"
        " by the JSON grammar itself — so there is no header line, delimiter or"
        " quote character for this option to steer." + _TAIL,
    )


def test_iceberg_options_duckdb_has_are_refused_by_name() raises:
    var names: List[String] = [
        "version", "version_name_format", "mode", "metadata_compression_codec",
        "skip_schema_inference", "snapshot_from_timestamp", "no_such_option",
    ]
    for i in range(len(names)):
        assert_equal(
            _on_iceberg(names[i] + " = 'x'"),
            "SQL not supported: iceberg_scan option '" + names[i]
            + "' is not implemented." + _TAIL,
        )


def test_malformed_iceberg_calls_are_refused() raises:
    assert_equal(
        _refusal("SELECT * FROM iceberg_scan(5)"),
        "SQL syntax error: iceberg_scan expects a string path",
    )
    assert_equal(
        _on_iceberg("allow_moved_paths"),
        "SQL syntax error: iceberg_scan option 'allow_moved_paths' must be"
        " written name=value",
    )
    assert_equal(
        _on_iceberg("allow_moved_paths = 1"),
        "SQL syntax error: iceberg_scan option 'allow_moved_paths' expects"
        " TRUE or FALSE",
    )
    assert_equal(
        _on_iceberg("snapshot_from_id = 'x'"),
        "SQL syntax error: iceberg_scan option 'snapshot_from_id' expects an"
        " integer snapshot id",
    )
    assert_equal(
        _on_iceberg("snapshot_from_id = 1.5"),
        "SQL syntax error: iceberg_scan option 'snapshot_from_id' expects an"
        " integer snapshot id",
    )
    assert_equal(
        _on_iceberg("snapshot_from_id = -5"),
        "SQL syntax error: iceberg_scan option 'snapshot_from_id' expects an"
        " integer snapshot id",
    )
    assert_equal(
        _on_iceberg("snapshot_from_id = 18446744073709551616"),
        "SQL bind error: the snapshot_from_id 18446744073709551616 is out of"
        " range for BIGINT (DuckDB v1.5.3 raises a Conversion Error: the value"
        " is out of range for the destination type INT64)",
    )
    assert_equal(
        _refusal("SELECT * FROM iceberg_scan('t', allow_moved_paths = true"),
        "SQL syntax error: expected ')'",
    )
    assert_equal(
        _refusal("SELECT * FROM iceberg_scan('t', 5)"),
        "SQL syntax error: expected an option name inside iceberg_scan(...)",
    )


def test_the_iceberg_kind_is_not_a_parquet_kind() raises:
    assert_false(is_parquet_tvf_kind(TVF_ICEBERG))
    assert_true(is_parquet_tvf_kind(TVF_PARQUET))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
