# =============================================================================
# sql_copy_partition: the PARTITION_BY option of COPY ... TO
# =============================================================================
#
# What each test proves:
#   * test_partition_by_is_read_into_the_statement: `PARTITION_BY (a, b)`
#     keeps both names in their order (a composite key), with FORMAT and
#     COMPRESSION before or after it; one name without parentheses and a
#     quoted name are accepted as DuckDB accepts them; an unquoted name is
#     lower-folded and a quoted one kept as written; a COPY without the
#     option has no names. Catches the list reordered, a name after the first
#     dropped, or the option swallowing the option after it.
#   * test_partition_by_refusals: an empty list, a name that is not one
#     (a number, an expression), a list without its `)`, a name listed twice
#     (in either case), the option given twice and the option with FORMAT
#     json are refused by name, each with its whole message; DuckDB's
#     OVERWRITE, OVERWRITE_OR_IGNORE, APPEND, WRITE_PARTITION_COLUMNS,
#     FILE_SIZE_BYTES, PER_THREAD_OUTPUT and FILENAME_PATTERN stay refused
#     by name. Catches a duplicate key accepted (DuckDB itself stops with an
#     internal error on it), and a partitioned JSON write that DuckDB
#     refuses.
#   * test_partition_columns_resolve_against_the_result: a listed name
#     matches the result column of that exact name first, else the first one
#     equal without regard to case, and comes back spelled as the result
#     spells it, in list order; a name the result does not have and a list
#     that covers every column are bind errors whose whole message names the
#     result's columns. Catches a case-folded name written as a directory
#     the result does not spell, and a COPY that would write files with no
#     column.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.write_target import WCOMP_GZIP, WFMT_CSV, WFMT_PARQUET
from sql.sql_ast import STMT_COPY, SqlStatement
from sql.sql_copy_partition import partition_columns_of
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _parse(sql: String) raises -> SqlStatement:
    return parse_sql(tokenize(sql))


def _err(sql: String) raises -> String:
    try:
        _ = _parse(sql)
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + sql)


def _names(st: SqlStatement) -> String:
    var s = String("")
    for i in range(len(st.partition_by)):
        if i > 0:
            s += ","
        s += st.partition_by[i]
    return s^


def _schema(names: List[String]) raises -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    return sb.build()


def test_partition_by_is_read_into_the_statement() raises:
    var st = _parse(
        "COPY (SELECT * FROM t) TO 'out' (FORMAT parquet, PARTITION_BY (year, month))"
    )
    assert_equal(Int(st.kind), Int(STMT_COPY))
    assert_equal(st.dest_path, "out")
    assert_equal(Int(st.fmt), Int(WFMT_PARQUET))
    assert_equal(_names(st), "year,month")
    var csv = _parse(
        "COPY t TO 'out' (PARTITION_BY (Month, Year), FORMAT csv, COMPRESSION gzip)"
    )
    assert_equal(Int(csv.fmt), Int(WFMT_CSV))
    assert_equal(Int(csv.codec), Int(WCOMP_GZIP))
    assert_equal(_names(csv), "month,year")
    assert_equal(_names(_parse("COPY t TO 'o.parquet' (PARTITION_BY k)")), "k")
    assert_equal(_names(_parse("COPY t TO 'o.parquet' (PARTITION_BY ('Year'))")), "Year")
    assert_equal(_names(_parse("COPY t TO 'o.parquet' (PARTITION_BY 'k', FORMAT parquet)")), "k")
    assert_equal(len(_parse("COPY t TO 'o.parquet' (FORMAT parquet)").partition_by), 0)
    assert_equal(len(_parse("COPY t TO 'o.parquet'").partition_by), 0)


def test_partition_by_refusals() raises:
    var name_wanted = String(
        "SQL syntax error: COPY option PARTITION_BY expects a column name"
        " or a parenthesised list of column names"
    )
    assert_equal(_err("COPY t TO 'o.parquet' (PARTITION_BY ())"), name_wanted)
    assert_equal(_err("COPY t TO 'o.parquet' (PARTITION_BY 5)"), name_wanted)
    assert_equal(_err("COPY t TO 'o.parquet' (PARTITION_BY (a, 1))"), name_wanted)
    assert_equal(
        _err("COPY t TO 'o.parquet' (PARTITION_BY (a + 1))"),
        "SQL syntax error: expected ')' to close the PARTITION_BY column list",
    )
    assert_equal(
        _err("COPY t TO 'o.parquet' (PARTITION_BY (a, b"),
        "SQL syntax error: expected ')' to close the PARTITION_BY column list",
    )
    assert_equal(
        _err("COPY t TO 'o.parquet' (PARTITION_BY (a, b, A))"),
        "SQL not supported: COPY ... PARTITION_BY names the column 'a' twice",
    )
    assert_equal(
        _err("COPY t TO 'o.parquet' (PARTITION_BY (a, 'A'))"),
        "SQL not supported: COPY ... PARTITION_BY names the column 'A' twice",
    )
    assert_equal(
        _err("COPY t TO 'o.parquet' (PARTITION_BY (a), PARTITION_BY (b))"),
        "SQL syntax error: the COPY option PARTITION_BY is given twice",
    )
    assert_equal(
        _err("COPY t TO 'o.json' (PARTITION_BY (a))"),
        "SQL not supported: COPY option PARTITION_BY applies to FORMAT"
        " 'parquet' or 'csv', not 'json' (DuckDB refuses it for JSON too)",
    )
    var refused = List[String]()
    refused.append("overwrite")
    refused.append("overwrite_or_ignore")
    refused.append("append")
    refused.append("write_partition_columns")
    refused.append("file_size_bytes")
    refused.append("per_thread_output")
    refused.append("filename_pattern")
    for i in range(len(refused)):
        assert_equal(
            _err(
                "COPY t TO 'out' (FORMAT parquet, PARTITION_BY (a), "
                + refused[i].upper() + " true)"
            ),
            "SQL not supported: COPY option '" + refused[i] + "' (FORMAT /"
            " COMPRESSION / COMPRESSION_LEVEL / HEADER / ARRAY / PARTITION_BY)",
        )
    assert_equal(
        _err("COPY t TO 'o.parquet' (5)"),
        "SQL syntax error: expected a COPY option (FORMAT / COMPRESSION /"
        " COMPRESSION_LEVEL / HEADER / ARRAY / PARTITION_BY)",
    )


def test_partition_columns_resolve_against_the_result() raises:
    var cols = List[String]()
    cols.append("id")
    cols.append("Year")
    cols.append("month")
    cols.append("MONTH")
    var schema = _schema(cols)
    var asked = List[String]()
    asked.append("year")
    asked.append("MONTH")
    var got = partition_columns_of(asked, schema)
    assert_equal(len(got), 2)
    assert_equal(got[0], "Year")
    assert_equal(got[1], "MONTH")
    var folded = List[String]()
    folded.append("Month")
    assert_equal(partition_columns_of(folded, schema)[0], "month")
    var missing = List[String]()
    missing.append("day")
    try:
        _ = partition_columns_of(missing, schema)
        assert_true(False, "a missing column was accepted")
    except e:
        assert_equal(
            String(e),
            "SQL bind error: COPY ... PARTITION_BY names column 'day', which is"
            " not a column of the query's result (id, Year, month, MONTH)",
        )
    var two = List[String]()
    two.append("a")
    two.append("b")
    var every = List[String]()
    every.append("b")
    every.append("a")
    try:
        _ = partition_columns_of(every, _schema(two))
        assert_true(False, "every column was accepted")
    except e:
        assert_equal(
            String(e),
            "SQL bind error: COPY ... PARTITION_BY names every column of the"
            " result (a, b): no column is left to write in the files",
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
