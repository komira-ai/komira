# =============================================================================
# src/kci_contract/tests/test_error_ids.mojo
#   Error ids: unique, well-formed, each with a meaning.
# =============================================================================

from std.testing import TestSuite, assert_false, assert_true

from kci_contract import error_table, is_error_id, is_error_id_well_formed, require_error_id


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
    assert_true(is_error_id_well_formed(String("KCI-E-PUBLISH-NEW-NAME")))
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
