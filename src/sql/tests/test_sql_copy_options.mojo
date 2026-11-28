# =============================================================================
# COPY ... TO's CSV options: DELIMITER, QUOTE, ESCAPE, NULL, HEADER and the
# date formats, parsed and refused as DuckDB does
# =============================================================================
#
# Covers: `sql_copy_options` through the parser (`parse_sql` on a whole
# COPY statement): each CSV option and its DuckDB spellings land in the
# statement's `CsvWriteDialect`; the options combine in any order; an option
# DuckDB refuses, or this engine cannot honour, is refused by name with its
# exact message; the option list as a whole (duplicates, unknown names, a CSV
# option on Parquet or JSON).
#
# What each test proves:
#   * test_each_option_and_its_spellings: DELIMITER, DELIM and SEP are one
#     option (`;`, a tab spelled `\t` or as the byte); QUOTE, ESCAPE, NULL
#     and NULLSTR, DATEFORMAT and DATE_FORMAT, TIMESTAMPFORMAT and
#     TIMESTAMP_FORMAT each set their field, with the value's case kept
#     (`NA`, `%d/%m/%Y`); a statement with no option list, or no CSV option,
#     has DuckDB's defaults. Catches an alias left out, a value lower-cased
#     and a default changed.
#   * test_options_in_any_order: HEADER false and NULL 'NA' before FORMAT
#     csv mean what they mean after it; a `.csv` destination needs no
#     FORMAT; COMPRESSION gzip beside DELIMITER keeps both.
#   * test_refused_option_lists: an unknown option (`FORCE_QUOTE`) and
#     DuckDB's CSV options this engine does not write are refused by name,
#     the message listing the options it takes; an option given twice, or
#     under two spellings (DELIMITER and SEP, NULL and NULLSTR), is refused;
#     a CSV option on Parquet or JSON is refused naming the format, and a
#     date format on JSON says the JSON writer takes none; a bare word or a
#     number as a CSV option value is refused by name; DuckDB's refusals
#     (a delimiter over 4 bytes, a two-byte QUOTE, QUOTE inside DELIMITER,
#     the delimiter inside NULL) and this engine's (a 2-byte delimiter, an
#     empty one) come through the parser with their exact messages. Catches
#     an option accepted and ignored, the last of two values silently kept,
#     and a CSV option accepted for a format that has no use for it.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.write_target import WCOMP_GZIP, WFMT_CSV
from sql.sql_ast import SqlStatement
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _csv(opts: String) raises -> SqlStatement:
    return parse_sql(tokenize("COPY t TO 'out.csv' " + opts))


def _err(sql: String) raises -> String:
    try:
        _ = parse_sql(tokenize(sql))
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + sql)


def _refused(opts: String, want: String) raises:
    assert_equal(_err("COPY t TO 'out.csv' " + opts), want, opts)


def test_each_option_and_its_spellings() raises:
    assert_equal(Int(_csv("(DELIMITER ';')").csv.delimiter), 0x3B)
    assert_equal(Int(_csv("(DELIM ';')").csv.delimiter), 0x3B)
    assert_equal(Int(_csv("(SEP ';')").csv.delimiter), 0x3B)
    assert_equal(Int(_csv("(DELIM '\\t')").csv.delimiter), 0x09)
    assert_equal(Int(_csv("(SEP '\t')").csv.delimiter), 0x09)
    assert_equal(Int(_csv("(QUOTE '''')").csv.quote.value()), 0x27)
    assert_false(Bool(_csv("(QUOTE '')").csv.quote))
    assert_equal(Int(_csv("(ESCAPE '\\')").csv.escape.value()), 0x5C)
    assert_equal(_csv("(NULL 'NA')").csv.null_text, "NA")
    assert_equal(_csv("(NULLSTR 'NA')").csv.null_text, "NA")
    assert_equal(_csv("(DATEFORMAT '%d/%m/%Y')").csv.date_format.value(), "%d/%m/%Y")
    assert_equal(_csv("(DATE_FORMAT '%d/%m/%Y')").csv.date_format.value(), "%d/%m/%Y")
    assert_equal(_csv("(TIMESTAMPFORMAT '%c')").csv.timestamp_format.value(), "%c")
    assert_equal(_csv("(TIMESTAMP_FORMAT '%c')").csv.timestamp_format.value(), "%c")
    # A format is not parsed here: the writer parses it when a column uses it.
    assert_equal(_csv("(DATEFORMAT '%Q')").csv.date_format.value(), "%Q")
    var plain = _csv("")
    assert_equal(Int(plain.fmt), Int(WFMT_CSV))
    assert_equal(Int(plain.csv.delimiter), 0x2C)
    assert_equal(Int(plain.csv.quote.value()), 0x22)
    assert_equal(plain.csv.null_text, "")
    assert_true(plain.csv.header)
    assert_false(Bool(plain.csv.date_format))
    var gz = _csv("(COMPRESSION gzip)")
    assert_equal(Int(gz.codec), Int(WCOMP_GZIP))
    assert_equal(Int(gz.csv.delimiter), 0x2C)


def _assert_semicolon_na_no_header(st: SqlStatement) raises:
    assert_false(st.csv.header)
    assert_equal(st.csv.null_text, "NA")
    assert_equal(Int(st.csv.delimiter), 0x3B)


def test_options_in_any_order() raises:
    var a = parse_sql(
        tokenize("COPY t TO 'out.txt' (HEADER false, NULL 'NA', FORMAT csv, DELIMITER ';')")
    )
    var b = parse_sql(
        tokenize("COPY t TO 'out.txt' (FORMAT csv, DELIMITER ';', NULL 'NA', HEADER false)")
    )
    _assert_semicolon_na_no_header(a)
    _assert_semicolon_na_no_header(b)
    var c = _csv("(DELIMITER '|', COMPRESSION gzip, HEADER false)")
    assert_equal(Int(c.codec), Int(WCOMP_GZIP))
    assert_equal(Int(c.csv.delimiter), 0x7C)
    assert_false(c.csv.header)


comptime _TAKES = (
    "(FORMAT / COMPRESSION / COMPRESSION_LEVEL / HEADER / ARRAY / DELIMITER /"
    " QUOTE / ESCAPE / NULL / DATEFORMAT / TIMESTAMPFORMAT)"
)


def test_refused_option_lists() raises:
    _refused("(FORCE_QUOTE x)", "SQL not supported: COPY option 'force_quote' " + _TAKES)
    _refused("(DECIMAL_SEPARATOR ',')", "SQL not supported: COPY option 'decimal_separator' " + _TAKES)
    _refused("(5)", "SQL syntax error: expected a COPY option " + _TAKES)
    _refused("(DELIMITER ';', DELIMITER '|')", "SQL syntax error: COPY option DELIMITER repeats DELIMITER; give each option once")
    _refused("(DELIMITER ';', SEP '|')", "SQL syntax error: COPY option SEP repeats DELIMITER; give each option once")
    _refused("(DELIM ';', DELIMITER '|')", "SQL syntax error: COPY option DELIMITER repeats DELIM; give each option once")
    _refused("(NULL 'x', NULLSTR 'y')", "SQL syntax error: COPY option NULLSTR repeats NULL; give each option once")
    _refused("(HEADER false, HEADER true)", "SQL syntax error: COPY option HEADER repeats HEADER; give each option once")
    _refused("(FORMAT csv, FORMAT csv)", "SQL syntax error: COPY option FORMAT repeats FORMAT; give each option once")
    _refused("(DATEFORMAT '%Y', DATE_FORMAT '%m')", "SQL syntax error: COPY option DATE_FORMAT repeats DATEFORMAT; give each option once")
    _refused("(FORMAT parquet, DELIMITER ';')", "SQL not supported: COPY option DELIMITER applies to FORMAT 'csv', not 'parquet'")
    _refused("(FORMAT json, NULL 'NA')", "SQL not supported: COPY option NULL applies to FORMAT 'csv', not 'json'")
    _refused("(FORMAT parquet, QUOTE '|')", "SQL not supported: COPY option QUOTE applies to FORMAT 'csv', not 'parquet'")
    _refused("(FORMAT parquet, ESCAPE '|')", "SQL not supported: COPY option ESCAPE applies to FORMAT 'csv', not 'parquet'")
    _refused("(FORMAT parquet, DATEFORMAT '%Y')", "SQL not supported: COPY option DATEFORMAT applies to FORMAT 'csv', not 'parquet'")
    _refused("(FORMAT json, HEADER false)", "SQL not supported: COPY option HEADER applies to FORMAT 'csv', not 'json'")
    _refused(
        "(FORMAT json, DATEFORMAT '%Y')",
        "SQL not supported: COPY ... (FORMAT 'json', DATEFORMAT) — the JSON writer writes dates and timestamps in DuckDB's default text only",
    )
    _refused(
        "(FORMAT json, TIMESTAMP_FORMAT '%c')",
        "SQL not supported: COPY ... (FORMAT 'json', TIMESTAMPFORMAT) — the JSON writer writes dates and timestamps in DuckDB's default text only",
    )
    _refused(
        "(NULL NA)",
        "SQL not supported: COPY option NULL na — write the value quoted (NULL '...'); a bare word is read lower-cased, which is not the text DuckDB would write",
    )
    _refused(
        "(DELIMITER 1)",
        "SQL bind error: COPY option DELIMITER expects a VARCHAR, not the integer 1 (DuckDB refuses it too)",
    )
    _refused("(HEADER 1)", "SQL syntax error: expected a COPY option value")
    _refused(
        "(DELIMITER 'abcde')",
        "CSV_DIALECT_INVALID: COPY ... (DELIMITER 'abcde'): the delimiter option cannot exceed a size of 4 bytes, as DuckDB refuses it",
    )
    _refused(
        "(QUOTE 'ab')",
        "CSV_DIALECT_INVALID: COPY ... (QUOTE 'ab'): the quote option cannot exceed a size of 1 byte, as DuckDB refuses it",
    )
    _refused(
        "(DELIMITER ';', QUOTE ';')",
        "CSV_DIALECT_INVALID: COPY ... (DELIMITER ';'): QUOTE must not appear in the DELIMITER specification and vice versa",
    )
    _refused(
        "(NULL ',')",
        "CSV_DIALECT_INVALID: COPY ... (NULL ','): DELIMITER must not appear in the NULL specification and vice versa",
    )
    _refused(
        "(SEP 'ab')",
        "CSV_DIALECT_UNSUPPORTED: COPY ... (DELIMITER 'ab'): a delimiter of 2 bytes; DuckDB writes only its first byte between the cells, so the delimiter is one byte",
    )
    _refused(
        "(DELIMITER '')",
        "CSV_DIALECT_UNSUPPORTED: COPY ... (DELIMITER ''): an empty delimiter; DuckDB writes the cells with nothing between them",
    )
    _refused("(DELIMITER ';'", "SQL syntax error: expected ')' to close COPY options")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
