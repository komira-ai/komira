# =============================================================================
# src/kci_api/tests/test_verbs.mojo
#   The verb table is exactly {run}: kci has one command, no alias, and no
#   `ci check` (the workflow check is library code `kci run` runs at
#   start-up). The step kinds are BUILD, PUBLISH and the reserved DEPLOY; the
#   validation kinds are CONDA_INSTALL_SMOKE.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_api import (
    STEP_KIND_BUILD,
    STEP_KIND_DEPLOY,
    STEP_KIND_PUBLISH,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    VALIDATION_KIND_DEPLOY_PROBE,
    VERB_RUN,
    all_step_kinds,
    all_validation_kinds,
    all_verbs,
    require_step_kind,
    require_validation_kind,
    require_verb,
)


def _verb(word: String) -> String:
    try:
        require_verb(word)
    except e:
        return String(e)
    return String("<ok>")


def test_verb_table_is_run_only() raises:
    var v = all_verbs()
    assert_equal(len(v), 1)
    assert_equal(v[0], String("run"))
    assert_equal(String(VERB_RUN), String("run"))
    assert_equal(_verb(String("run")), String("<ok>"))
    # the workflow check is not a command
    assert_equal(_verb(String("ci-check")), String("verb 'ci-check' is not a kci verb"))
    assert_equal(_verb(String("ci")), String("verb 'ci' is not a kci verb"))


def test_stage_verbs_and_aliases_refused() raises:
    var gone = List[String]()
    gone.append(String("build"))
    gone.append(String("publish"))
    gone.append(String("stages"))
    gone.append(String("deploy"))
    gone.append(String("validate"))
    gone.append(String("trust"))
    gone.append(String("leaks"))
    gone.append(String("cells"))
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


def test_validation_kinds() raises:
    var k = all_validation_kinds()
    assert_equal(len(k), 3)
    assert_equal(k[0], String("CONDA_INSTALL_SMOKE"))
    assert_equal(k[1], String("CONDA_INSTALL_ENV"))
    assert_equal(k[2], String("DEPLOY_PROBE"))
    assert_equal(String(VALIDATION_KIND_DEPLOY_PROBE), String("DEPLOY_PROBE"))
    require_validation_kind(String("DEPLOY_PROBE"))
    assert_equal(String(VALIDATION_KIND_CONDA_INSTALL_SMOKE), String("CONDA_INSTALL_SMOKE"))
    assert_equal(String(VALIDATION_KIND_CONDA_INSTALL_ENV), String("CONDA_INSTALL_ENV"))
    require_validation_kind(String("CONDA_INSTALL_SMOKE"))
    require_validation_kind(String("CONDA_INSTALL_ENV"))
    var refused = String("")
    try:
        require_validation_kind(String("SMOKE"))
    except e:
        refused = String(e)
    assert_equal(refused, String("validation kind 'SMOKE' is not CONDA_INSTALL_SMOKE, CONDA_INSTALL_ENV or DEPLOY_PROBE"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
