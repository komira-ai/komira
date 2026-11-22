# =============================================================================
# The pinned DuckDB reads back the Parquet files COPY writes
# =============================================================================
#
# A test of the `copy_readback` library (src/sdk_exec/BUCK). `:copy_komira` ran
# every COPY line of tests/copy/cases.sql through run_sql and wrote
# `counts.tsv`, each case's `Count`. `:copy_readback_oracle` ran the same lines
# in the pinned DuckDB, which wrote its own file for each, then
# tests/copy/readback.sql compared komira's file with DuckDB's and wrote
# `<case>.check.tsv`: the rows of each file, the rows in one and not the other
# (multisets, NULL equal to NULL), and each file's columns as DuckDB reads them
# (`name TYPE, ...`).
#
# What each test proves:
#   * test_duckdb_reads_each_file_as_its_own: for every case of cases.sql (the
#     list is read from the file, so a case added there is checked here),
#     DuckDB reads komira's file with the same column names and types as its
#     own, finds no row in one file and not in the other, as many rows in each,
#     and as many as the `Count` komira's COPY answered. The cases cover the
#     default codec and zstd, gzip, lz4_raw, uncompressed and snappy; BIGINT,
#     DOUBLE, DATE, VARCHAR (quotes, a comma, a line break, padding, a
#     multi-byte character) and BOOLEAN columns; NULLs in every column but
#     one; an aggregate; and an empty result. Catches a file DuckDB cannot
#     open, a column it reads as another type (a string without its UTF8
#     annotation reads as BLOB, a DATE without its annotation as INTEGER), a
#     value or NULL lost, and a `Count` that is not the rows written.
#   * test_the_readers_of_the_files: `case_names` keeps only `COPY (` lines,
#     `tsv_row` of a header alone is empty and keeps only the cells a row
#     has, and `tsv_pairs` skips a row that is not two cells. Catches a
#     comment or blank line of cases.sql read as a case.

from std.testing import TestSuite, assert_equal, assert_true

from copy_readback.checks import case_names, tsv_pairs, tsv_row
from runtime_paths import read_data


def test_duckdb_reads_each_file_as_its_own() raises:
    var cases = case_names(read_data("cases.sql"))
    assert_equal(len(cases), 7)
    var counts = tsv_pairs(read_data("counts.tsv"))
    assert_equal(len(counts), len(cases))
    for i in range(len(cases)):
        ref c = cases[i]
        var row = tsv_row(read_data(c + ".check.tsv"))
        assert_equal(len(row), 5, c)
        assert_true(row["komira_columns"] != "", c + ": no columns read")
        assert_equal(row["komira_columns"], row["duckdb_columns"], c)
        assert_equal(row["differing_rows"], "0", c)
        assert_equal(row["komira_rows"], row["duckdb_rows"], c)
        assert_equal(counts[c], row["duckdb_rows"], c + ": Count")
    assert_equal(tsv_row(read_data("empty.check.tsv"))["komira_rows"], "0")


def test_the_readers_of_the_files() raises:
    var names = case_names(
        "-- COPY (SELECT 1) TO 'comment.parquet';\n\n"
        "COPY (SELECT 1) TO 'one.parquet';\n"
        "COPY (SELECT * FROM read_csv('a.csv')) TO 'two.parquet' (COMPRESSION zstd);\n"
    )
    assert_equal(len(names), 2)
    assert_equal(names[0], "one")
    assert_equal(names[1], "two")
    assert_equal(len(tsv_row("a\tb")), 0)
    var short = tsv_row("a\tb\tc\n1\t2\n")
    assert_equal(len(short), 2)
    assert_equal(short["b"], "2")
    var pairs = tsv_pairs("case\tcount\nx\t3\n\nbad\n")
    assert_equal(len(pairs), 1)
    assert_equal(pairs["x"], "3")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
