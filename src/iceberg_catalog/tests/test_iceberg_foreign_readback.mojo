# =============================================================================
# The pinned DuckDB's iceberg extension reads the tables the write sink wrote
# =============================================================================
#
# A standalone test (src/iceberg_catalog/BUCK, `test_iceberg_foreign_readback`).
# `:iceberg_write_komira` ran iceberg_write_runner, which wrote db.appended,
# db.overwritten and db.emptied through write_table (the runner's header says
# which writes, with which ids). `:iceberg_readback_oracle` then scanned each
# table with `iceberg_scan(<metadata file>, allow_moved_paths = true)` in the
# pinned DuckDB and wrote `<table>.check.tsv` (tests/readback.sql): the rows
# the scan returned, the rows of a hand-written expected table, the rows in one
# and not the other (multisets, NULL equal to NULL), the columns as DuckDB
# reads them, and for each Parquet file the sink wrote the field id of the
# schema root and `name=id repetition` of each leaf. `root_<n>` and `leaves_<n>`
# are for the file of the write with uuid number n.
#
# What each test proves:
#   * test_the_appended_table_reads_back_as_written: after two appends the scan
#     returns the five rows written (3 + 2, one with nulls in every optional
#     column), with the columns id BIGINT, name VARCHAR, amount DOUBLE, flag
#     BOOLEAN, day DATE and qty INTEGER, and no row differs from the expected
#     ones either way; both Parquet files carry the table's field ids 10 to 15
#     on the leaves, `id` REQUIRED and the rest OPTIONAL, and none on the root.
#     Catches a table DuckDB cannot open, a manifest or manifest list it reads
#     as empty, a row or a null lost, a column read as another type, and a
#     file without its field ids or with a required column optional.
#   * test_the_overwritten_table_holds_only_the_overwrite: after an append and
#     an overwrite the scan returns only the overwrite's two rows (the first
#     with nulls), and the old file, which stays in the store, and the new one
#     both carry the field ids. Catches an overwrite that keeps the appended
#     rows in the snapshot DuckDB reads.
#   * test_the_emptied_table_reads_back_empty: after an overwrite with an empty
#     batch the scan returns no row, still with the table's columns, and the
#     file the table once had is still a valid Parquet file with its field ids.
#     Catches an emptied table DuckDB cannot open or still shows rows of.
#   * test_the_check_files_are_read_by_column_name: `_row` of a header alone is
#     empty, keeps only the cells a row has, and `_row` of a file with several
#     rows is its first. Catches a check file read by position or past its
#     first row.

from std.testing import TestSuite, assert_equal

from runtime_paths import read_data


comptime _COLUMNS: String = (
    "id BIGINT, name VARCHAR, amount DOUBLE, flag BOOLEAN, day DATE, qty INTEGER"
)

comptime _LEAVES: String = (
    "id=10 REQUIRED, name=11 OPTIONAL, amount=12 OPTIONAL, flag=13 OPTIONAL,"
    " day=14 OPTIONAL, qty=15 OPTIONAL"
)


def _row(tsv: String) -> Dict[String, String]:
    """The first data row of `tsv` (after its header row) by column name; a
    column with no cell in the row is absent."""
    var row = Dict[String, String]()
    var lines = tsv.split("\n")
    if len(lines) < 2:
        return row^
    var names = String(lines[0]).split("\t")
    var values = String(lines[1]).split("\t")
    for i in range(min(len(names), len(values))):
        row[String(names[i])] = String(values[i])
    return row^


def _check_rows(
    row: Dict[String, String], table: String, rows: String
) raises:
    """DuckDB read `rows` rows from `table`, as many as expected, none
    differing, with the table's columns."""
    assert_equal(row["scan_rows"], rows, table + ": rows scanned")
    assert_equal(row["want_rows"], rows, table + ": rows expected")
    assert_equal(row["differing_rows"], "0", table + ": differing rows")
    assert_equal(row["columns"], _COLUMNS, table + ": columns")


def _check_file(
    row: Dict[String, String], table: String, uuid_number: String
) raises:
    """The file of the write with uuid number `uuid_number` has no field id on
    its root and the table's on its leaves."""
    assert_equal(row["root_" + uuid_number], "none", table + ": root id")
    assert_equal(row["leaves_" + uuid_number], _LEAVES, table + ": leaf ids")


def test_the_appended_table_reads_back_as_written() raises:
    var row = _row(read_data("appended.check.tsv"))
    assert_equal(len(row), 8)
    _check_rows(row, "appended", "5")
    _check_file(row, "appended", "1")
    _check_file(row, "appended", "3")


def test_the_overwritten_table_holds_only_the_overwrite() raises:
    var row = _row(read_data("overwritten.check.tsv"))
    assert_equal(len(row), 8)
    _check_rows(row, "overwritten", "2")
    _check_file(row, "overwritten", "5")
    _check_file(row, "overwritten", "7")


def test_the_emptied_table_reads_back_empty() raises:
    var row = _row(read_data("emptied.check.tsv"))
    assert_equal(len(row), 6)
    _check_rows(row, "emptied", "0")
    _check_file(row, "emptied", "9")


def test_the_check_files_are_read_by_column_name() raises:
    assert_equal(len(_row("a\tb")), 0)
    assert_equal(len(_row("")), 0)
    var short = _row("a\tb\tc\n1\t2\n")
    assert_equal(len(short), 2)
    assert_equal(short["a"], "1")
    assert_equal(short["b"], "2")
    var two = _row("a\tb\n1\t2\n3\t4\n")
    assert_equal(len(two), 2)
    assert_equal(two["a"], "1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
