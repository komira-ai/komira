# =============================================================================
# Globs and the Hive option in SQL text, against DuckDB
# =============================================================================
#
# What this test proves:
#   * test_globs_in_sql_text_answer_duckdbs_rows, with no table registered:
#     read_parquet('<dir>/*.parquet') and FROM '<dir>/*.parquet' read all three
#     files, a brace glob part-{0,2} reads two, read_parquet over the Hive tree
#     with `**` detects the partition columns with or without
#     hive_partitioning = true, and hive_partitioning = false reads the data
#     columns only; each answers the rows of DuckDB's read of the same files.

from std.testing import TestSuite

from komira_multifile_scan_conformance.checks import check_sql_globs


def test_globs_in_sql_text_answer_duckdbs_rows() raises:
    check_sql_globs()


def main() raises:
    var suite = TestSuite()
    suite.test[test_globs_in_sql_text_answer_duckdbs_rows]()
    suite^.run()
