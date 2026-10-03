# =============================================================================
# src/kci_contract/tests/test_verbs.mojo
#   The verb table is exactly {run, ci-check}: one verb runs a stage, and no
#   alias exists. The step kinds are BUILD, PUBLISH and the reserved DEPLOY.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_contract import (
    STEP_KIND_BUILD,
    STEP_KIND_DEPLOY,
    STEP_KIND_PUBLISH,
    VERB_CI_CHECK,
    VERB_RUN,
    all_step_kinds,
    all_verbs,
    require_step_kind,
    require_verb,
)


def _verb(word: String) -> String:
    try:
        require_verb(word)
    except e:
        return String(e)
    return String("<ok>")


def test_verb_table_is_run_and_ci_check() raises:
    var v = all_verbs()
    assert_equal(len(v), 2)
    assert_equal(v[0], String("run"))
    assert_equal(v[1], String("ci-check"))
    assert_equal(String(VERB_RUN), String("run"))
    assert_equal(String(VERB_CI_CHECK), String("ci-check"))
    assert_equal(_verb(String("run")), String("<ok>"))
    assert_equal(_verb(String("ci-check")), String("<ok>"))


def test_stage_verbs_and_aliases_refused() raises:
    var gone = List[String]()
    gone.append(String("build"))
    gone.append(String("publish"))
    gone.append(String("stages"))
    gone.append(String("deploy"))
    gone.append(String("validate"))
    for i in range(len(gone)):
        assert_equal(_verb(gone[i]), String("verb '") + gone[i] + String("' is not a kci verb"))


def test_step_kinds() raises:
    var k = all_step_kinds()
    assert_equal(len(k), 3)
    assert_equal(k[0], String(STEP_KIND_BUILD))
    assert_equal(k[1], String(STEP_KIND_PUBLISH))
    assert_equal(k[2], String(STEP_KIND_DEPLOY))
    assert_equal(String(STEP_KIND_BUILD), String("BUILD"))
    require_step_kind(String("PUBLISH"))
    var refused = String("")
    try:
        require_step_kind(String("SHIP"))
    except e:
        refused = String(e)
    assert_equal(refused, String("step kind 'SHIP' is not BUILD, PUBLISH or DEPLOY"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
