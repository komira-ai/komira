# =============================================================================
# A Hive tree registered by a glob, against DuckDB
# =============================================================================
#
# The tree is hive/yr=<int>/tag=<string>/dt=<date>/part-0.parquet: four leaf
# files, and the directory order (yr, tag, dt) is not the key order (dt, tag, yr).
#
# What this test proves:
#   * test_hive_queries_answer_duckdbs_rows: each h_* query of answers.tsv
#     (a filter on an integer, a string and a date partition column, which
#     prunes files; a filter on a data column; both; a partition column alone;
#     GROUP BY an integer and a string partition column; count(*); ORDER BY;
#     a filter that prunes every file) answers DuckDB's rows.
#     It also holds SELECT * to DuckDB's names, order and types: id, v, s, then
#     dt, tag, yr (DATE, VARCHAR, BIGINT), the partition columns after the data
#     columns in key order.

from std.testing import TestSuite

from komira_multifile_scan_conformance.checks import check_hive


def test_hive_queries_answer_duckdbs_rows() raises:
    check_hive()


def main() raises:
    var suite = TestSuite()
    suite.test[test_hive_queries_answer_duckdbs_rows]()
    suite^.run()
