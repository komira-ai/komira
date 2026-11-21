# =============================================================================
# A directory of three Parquet files as one table, against DuckDB
# =============================================================================
#
# What this test proves:
#   * test_a_directory_of_files_answers_duckdbs_rows: register_parquet of
#     dir3/ (three files of ten rows) gives SELECT * the names, order and types
#     of DuckDB's read of the three files, and each d_* query of answers.tsv
#     (SELECT *, count(*), GROUP BY an integer and a string key, a filter, a
#     projection, ORDER BY) answers DuckDB's rows.

from std.testing import TestSuite

from komira_multifile_scan_conformance.checks import check_directory


def test_a_directory_of_files_answers_duckdbs_rows() raises:
    check_directory()


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_directory_of_files_answers_duckdbs_rows]()
    suite^.run()
