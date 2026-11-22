# =============================================================================
# The pinned DuckDB reads back the Parquet files COPY writes
# =============================================================================
#
# `:copy_komira` (src/sdk_exec/BUCK) ran every COPY line of tests/copy/cases.sql
# through run_sql and wrote `counts.tsv`, each case's `Count`. `:copy_readback`
# ran the same lines in the pinned DuckDB, which wrote its own file for each,
# then tests/copy/readback.sql compared komira's file with DuckDB's and wrote
# `<case>.check.tsv`: the rows of each file, the rows in one and not the other
# (multisets, NULL equal to NULL), and each file's columns as DuckDB reads them
# (`name TYPE, ...`).
#
# What the test proves:
#   * test_duckdb_reads_each_file_as_its_own: for every case of cases.sql (the
#     list is read from the file, so a case added there is checked here),
#     DuckDB reads komira's file with the same column names and types as its
#     own, finds no row in one file and not in the other, as many rows in each,
#     and as many as the `Count` komira's COPY answered. The cases cover the
#     default codec and zstd, gzip, lz4_raw, uncompressed and snappy; BIGINT,
#     DOUBLE, DATE, VARCHAR (quotes, a comma, a line break, padding, a
#     multi-byte character), BOOLEAN and DECIMAL(10,2) columns; NULLs in every
#     column but one; an aggregate; and an empty result. Catches a file DuckDB
#     cannot open, a column it reads as another type (a string without its
#     UTF8 annotation reads as BLOB, a DATE without its annotation as
#     INTEGER), a value or NULL lost, and a `Count` that is not the rows
#     written.

from std.testing import TestSuite, assert_equal, assert_true

from runtime_paths import read_data


def _cases() raises -> List[String]:
    """The case names of cases.sql: each COPY line's destination without
    `.parquet`."""
    var out = List[String]()
    var text = read_data("cases.sql")
    for raw in text.split("\n"):
        var line = String(raw)
        if not line.startswith("COPY ("):
            continue
        var to = line.rfind(") TO '")
        var ext = line.rfind(".parquet'")
        assert_true(to > 0 and ext > to, "a COPY line of cases.sql: " + line)
        out.append(String(line[byte = to + 6 : ext]))
    return out^


def _row(text: String) raises -> Dict[String, String]:
    """The one data row of a TSV with a header row, by column name."""
    var lines = text.split("\n")
    assert_true(len(lines) >= 2, "a header and a row: " + text)
    var names = String(lines[0]).split("\t")
    var values = String(lines[1]).split("\t")
    assert_equal(len(names), len(values), text)
    var row = Dict[String, String]()
    for i in range(len(names)):
        row[String(names[i])] = String(values[i])
    return row^


def _counts() raises -> Dict[String, String]:
    var out = Dict[String, String]()
    var text = read_data("counts.tsv")
    var lines = text.split("\n")
    assert_equal(String(lines[0]), "case\tcount")
    for i in range(1, len(lines)):
        var line = String(lines[i])
        if line == "":
            continue
        var cells = line.split("\t")
        assert_equal(len(cells), 2, line)
        out[String(cells[0])] = String(cells[1])
    return out^


def test_duckdb_reads_each_file_as_its_own() raises:
    var cases = _cases()
    assert_equal(len(cases), 7)
    var counts = _counts()
    assert_equal(len(counts), len(cases))
    for i in range(len(cases)):
        ref c = cases[i]
        var check = read_data(c + ".check.tsv")
        var row = _row(check)
        assert_equal(row["komira_columns"], row["duckdb_columns"], c)
        assert_true(row["komira_columns"] != "", c + ": no columns read")
        assert_equal(row["differing_rows"], "0", c)
        assert_equal(row["komira_rows"], row["duckdb_rows"], c)
        assert_equal(counts[c], row["duckdb_rows"], c + ": Count")
    var empty = read_data("empty.check.tsv")
    assert_equal(_row(empty)["komira_rows"], "0")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
