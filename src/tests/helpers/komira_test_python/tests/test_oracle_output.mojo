# An oracle's output reaches a welded Mojo test as declared test data.
#
# The BUCK file stages `:golden_sums[sums.tsv]` (one named file of the
# python_oracle) at oracle/sums.tsv and `:golden_sums` (its whole output
# directory) at oracle_dir/. The expected text is worked out by hand from
# oracle_data/scores.csv (a: 3 + 5, b: 7 + 1, c: -2; five rows), not read from
# the oracle.
#
# What each test proves, and the defect it catches:
#   * test_named_file -- the named file arrives with DuckDB's sums, ordered by
#     team. Catches a sub-target that does not point at the file the oracle
#     wrote, or an oracle that answers wrongly.
#   * test_directory -- the whole directory arrives, its nested file included.
#     Catches an output directory that a consumer cannot stage.
from std.pathlib import Path
from std.testing import TestSuite, assert_equal


def test_named_file() raises:
    assert_equal(Path("oracle/sums.tsv").read_text(), "a\t8\nb\t8\nc\t-2\n")


def test_directory() raises:
    assert_equal(Path("oracle_dir/summary/count.txt").read_text(), "5\n")
    assert_equal(Path("oracle_dir/sums.tsv").read_text(), "a\t8\nb\t8\nc\t-2\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
