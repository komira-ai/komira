# =============================================================================
# The pinned DuckDB reads back the Parquet, CSV and JSON files COPY writes
# =============================================================================
#
# A test of the `copy_readback` library (src/sdk_exec/BUCK). `:copy_komira` ran
# every COPY line of tests/copy/cases.sql through run_sql and wrote
# `counts.tsv`, each case's `Count`. `:copy_readback_oracle` ran the same lines
# in the pinned DuckDB, which wrote its own file for each, then
# tests/copy/readback.sql compared komira's file with DuckDB's and wrote
# `<case>.check.tsv`: the rows of each file, the rows in one and not the other
# (multisets, NULL equal to NULL), each file's columns as DuckDB reads them
# (`name TYPE, ...`), and for an uncompressed CSV or JSON file whether the two
# files hold the same bytes (`same_bytes`).
#
# What each test proves:
#   * test_duckdb_reads_each_file_as_its_own: for every case of cases.sql (the
#     list is read from the file, so a case added there is checked here),
#     DuckDB reads komira's file with the same column names and types as its
#     own, finds no row in one file and not in the other, as many rows in each,
#     and as many as the `Count` komira's COPY answered; an uncompressed CSV
#     or JSON file holds the bytes of DuckDB's. The Parquet cases cover the
#     default codec and zstd, gzip, lz4_raw, uncompressed and snappy; the CSV
#     and JSON cases a `.csv`, `.json`, `.gz` and `.zst` destination and a
#     FORMAT named or inferred. Columns: BIGINT, DOUBLE, DATE, VARCHAR
#     (quotes, a comma, a line break, padding, a multi-byte character, the
#     empty string beside NULL) and BOOLEAN; NULLs in every column but one;
#     an aggregate with an integer sum; an empty result (Parquet and
#     CSV); and, read from a Parquet file DuckDB wrote (tests/copy/times.sql),
#     TIMESTAMP, TIMESTAMP_MS, TIMESTAMP_NS and TIMESTAMPTZ columns (the
#     epoch, a tick before it, fractions, BC years, each unit's extremes,
#     infinity and -infinity) and TINYINT, SMALLINT, UTINYINT, USMALLINT,
#     UINTEGER and UBIGINT at their extremes, to Parquet, CSV and JSON.
#     Catches a file DuckDB cannot open, a column it reads as another type
#     (a string without its UTF8 annotation reads as BLOB, a DATE without its
#     annotation as INTEGER, a CSV date written as a day count as BIGINT, a
#     JSON decimal written as a string as VARCHAR, a TIMESTAMPTZ without its
#     UTC flag as TIMESTAMP, an unsigned column without its annotation as a
#     signed one), a timestamp whose footer unit is off by 1000 (other
#     instants), a value or NULL lost (the empty string written unquoted
#     reads as NULL), a cell quoted, escaped or formatted otherwise than
#     DuckDB does it, and a `Count` that is not the rows written.
#   * test_the_readers_of_the_files: `case_files` keeps only `COPY (` lines
#     and ends a file name at its quote, `case_name` ends a name at its first
#     `.` (or keeps a name with none), `tsv_row` of a header alone is empty
#     and keeps only the cells a row has, and `tsv_pairs` skips a row that is
#     not two cells. Catches a comment or blank line of cases.sql read as a
#     case, and two cases of one file name read as one.

from std.testing import TestSuite, assert_equal, assert_true

from copy_readback.checks import case_files, case_name, tsv_pairs, tsv_row
from runtime_paths import read_data


def _uncompressed_text(file: String) -> Bool:
    return file.endswith(".csv") or file.endswith(".json")


def test_duckdb_reads_each_file_as_its_own() raises:
    var files = case_files(read_data("cases.sql"))
    assert_equal(len(files), 22)
    var counts = tsv_pairs(read_data("counts.tsv"))
    assert_equal(len(counts), len(files))
    var same_bytes = 0
    for i in range(len(files)):
        var c = case_name(files[i])
        var row = tsv_row(read_data(c + ".check.tsv"))
        if _uncompressed_text(files[i]):
            assert_equal(len(row), 6, c)
            assert_equal(row["same_bytes"], "true", c + ": the bytes of DuckDB's file")
            same_bytes += 1
        else:
            assert_equal(len(row), 5, c)
        assert_true(row["komira_columns"] != "", c + ": no columns read")
        assert_equal(row["komira_columns"], row["duckdb_columns"], c)
        assert_equal(row["differing_rows"], "0", c)
        assert_equal(row["komira_rows"], row["duckdb_rows"], c)
        assert_equal(counts[c], row["duckdb_rows"], c + ": Count")
    assert_equal(same_bytes, 10)
    assert_equal(tsv_row(read_data("empty.check.tsv"))["komira_rows"], "0")
    assert_equal(tsv_row(read_data("empty_csv.check.tsv"))["komira_rows"], "0")


def test_the_readers_of_the_files() raises:
    var files = case_files(
        "-- COPY (SELECT 1) TO 'comment.parquet';\n\n"
        "COPY (SELECT 1) TO 'one.parquet';\n"
        "COPY (SELECT * FROM read_csv('a.csv')) TO 'two.csv.gz' (FORMAT csv);\n"
    )
    assert_equal(len(files), 2)
    assert_equal(files[0], "one.parquet")
    assert_equal(files[1], "two.csv.gz")
    assert_equal(case_name(files[0]), "one")
    assert_equal(case_name(files[1]), "two")
    assert_equal(case_name("bare"), "bare")
    assert_equal(len(tsv_row("a\tb")), 0)
    var short = tsv_row("a\tb\tc\n1\t2\n")
    assert_equal(len(short), 2)
    assert_equal(short["b"], "2")
    var pairs = tsv_pairs("case\tcount\nx\t3\n\nbad\n")
    assert_equal(len(pairs), 1)
    assert_equal(pairs["x"], "3")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
