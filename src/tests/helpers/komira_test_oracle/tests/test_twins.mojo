# =============================================================================
# test_twins.mojo -- every oracle answer equals its HAND twin, by value.
# =============================================================================
#
# BUCK stages each oracle case's DuckDB answer at oracle/<shard>/<case>.tsv
# and its HAND twin at hand/<shard>/<case>.tsv in the working directory.
# The two are derived independently (DuckDB's run of the case's SQL, and a
# derivation from the query semantics document), so their agreement checks
# both: a wrong HAND file, a wrong oracle query, a DuckDB that answers
# otherwise. The planted defects of the check itself are in
# test_twin_checks.mojo.
# =============================================================================

from std.testing import TestSuite

from komira_test_oracle import check_twins


def test_every_answer_equals_its_twin() raises:
    var report = check_twins(String("."))
    if report.compared == 0:
        raise Error("twins: no oracle answer was compared (nothing staged under oracle/ and hand/)")
    if len(report.problems) > 0:
        var msg = String("twins: ") + String(len(report.problems)) + " problem(s) in " + String(report.compared) + " pairs:"
        for p in report.problems:
            msg += "\n  " + p
        raise Error(msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
