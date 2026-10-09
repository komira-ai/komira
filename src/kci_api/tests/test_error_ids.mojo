# =============================================================================
# src/kci_api/tests/test_error_ids.mojo
#   Error ids: unique, well-formed, each with a meaning.
# =============================================================================

from std.testing import TestSuite, assert_false, assert_true

from kci_api import (
    OUTCOME_REFUSED,
    OUTCOME_VALIDATION_FAILED,
    error_table,
    exit_code_of,
    is_error_id,
    is_error_id_well_formed,
    require_error_id,
)


def test_ids_are_unique_and_well_formed() raises:
    var t = error_table()
    assert_true(len(t) > 0)
    for i in range(len(t)):
        assert_true(is_error_id_well_formed(t[i].id))
        assert_true(t[i].meaning.byte_length() > 0)
        for j in range(i):
            assert_true(t[i].id != t[j].id)
            assert_true(t[i].meaning != t[j].meaning)


def test_grammar() raises:
    assert_true(is_error_id_well_formed(String("KCI-E-USAGE")))
    assert_true(is_error_id_well_formed(String("KCI-E-WORKFLOW-MISMATCH")))
    assert_false(is_error_id_well_formed(String("KCI-E-")))
    assert_false(is_error_id_well_formed(String("KCI-E-usage")))
    assert_false(is_error_id_well_formed(String("KCI-E-A--B")))
    assert_false(is_error_id_well_formed(String("KCI-E-A-")))
    assert_false(is_error_id_well_formed(String("KCI-W-USAGE")))


def test_v13_ids() raises:
    # the alias refusal went with the aliases; the selector and image ids are new
    assert_false(is_error_id(String("KCI-E-STAGE-KIND")))
    assert_true(is_error_id(String("KCI-E-SELECTOR")))
    assert_true(is_error_id(String("KCI-E-SELECTOR-NO-MATCH")))
    assert_true(is_error_id(String("KCI-E-IMAGE-PLATFORM")))
    assert_true(is_error_id(String("KCI-E-IMAGE-PUSH")))


def test_one_command_ids() raises:
    # a new name is reported, never refused: its id is gone
    assert_false(is_error_id(String("KCI-E-PUBLISH-NEW-NAME")))
    assert_true(is_error_id(String("KCI-E-WORKFLOW-MISMATCH")))
    assert_true(is_error_id(String("KCI-E-VALIDATION")))
    # neither picks its own number: a mismatch refuses (3), a failed
    # validation is 7
    assert_true(exit_code_of(String(OUTCOME_REFUSED), String("KCI-E-WORKFLOW-MISMATCH")) == 3)
    assert_true(exit_code_of(String(OUTCOME_VALIDATION_FAILED), String("KCI-E-VALIDATION")) == 7)


def test_auto_promotion_ids() raises:
    # each refuses (3): neither picks its own number
    for id in [
        "KCI-E-SUPERSEDED", "KCI-E-NOT-ON-MAIN", "KCI-E-BREAK-GLASS-REASON", "KCI-E-BREAK-GLASS-REVISION",
        "KCI-E-PLAN-ON-RELEASE",
    ]:
        assert_true(is_error_id(String(id)))
        assert_true(exit_code_of(String(OUTCOME_REFUSED), String(id)) == 3)


def test_deploy_ids() raises:
    # a DEPLOY step's ids pick no number of their own: the outcome does
    # (REFUSED 3, FAILED 4, PARTIAL 6)
    for id in ["KCI-E-CLOUD", "KCI-E-DEPLOY"]:
        assert_true(is_error_id(String(id)))
        assert_true(exit_code_of(String(OUTCOME_REFUSED), String(id)) == 3)
        assert_true(exit_code_of(String("FAILED"), String(id)) == 4)
        assert_true(exit_code_of(String("PARTIAL"), String(id)) == 6)


def test_unknown_id_refused() raises:
    assert_true(is_error_id(String("KCI-E-STAGE-UNKNOWN")))
    var refused = False
    try:
        require_error_id(String("KCI-E-NOT-A-THING"))
    except e:
        refused = String(e).find(String("not in kci's error table")) >= 0
    assert_true(refused)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
