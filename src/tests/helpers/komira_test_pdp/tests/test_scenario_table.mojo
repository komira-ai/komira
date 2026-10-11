# =============================================================================
# test_scenario_table.mojo: every scenario of `pdp_scenarios()` passes on
# `TestPdp`, reason codes included.
# =============================================================================
#
# The table is the executable spec a decision point in the komira profile
# must pass (table.mojo says what each scenario proves). This test runs it
# on the test decision point with its fixture loaded, one fresh decision
# point per scenario, and collects every mismatch into one failure.
#
# Planted defect: in pdp.mojo, the subject taken from the body
# (`var subject = req.subject_id`) instead of the subject token
# (`token.sub`). "subject mismatch is refused" and "batch subject mismatch
# is refused" then answer 200 instead of 403, so this test is red.
#
# Guards against a vacuous green: the table's size, and that the scenarios
# the safety conditions rest on are present by name.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_test_pdp import pdp_scenarios, run_on_test_pdp


def _names() -> List[String]:
    var out = List[String]()
    var table = pdp_scenarios()
    for i in range(len(table)):
        out.append(table[i].name)
    return out^


def test_every_scenario_passes() raises:
    var table = pdp_scenarios()
    var report = String("")
    for i in range(len(table)):
        report += run_on_test_pdp(table[i])
    assert_equal(report, String(""), "scenario mismatches:\n" + report)


def test_table_is_not_vacuous() raises:
    var names = _names()
    assert_equal(len(names), 31)
    var needed = List[String]()
    needed.append(String("subject mismatch is refused"))
    needed.append(String("batch subject mismatch is refused"))
    needed.append(String("a revoke takes effect on the next request"))
    needed.append(String("an audience other than the bearer's client is refused"))
    needed.append(String("a subject token for another audience is refused"))
    for i in range(len(needed)):
        var found = False
        for j in range(len(names)):
            if names[j] == needed[i]:
                found = True
        assert_true(found, "missing scenario: " + needed[i])
    # Names are unique, so a report line names one scenario.
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            assert_true(names[i] != names[j], "repeated name: " + names[i])


def main() raises:
    test_table_is_not_vacuous()
    test_every_scenario_passes()
    print("PASS komira_test_pdp test_scenario_table")
