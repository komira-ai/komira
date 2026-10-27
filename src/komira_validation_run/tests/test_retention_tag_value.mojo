# =============================================================================
# test_retention_tag_value.mojo -- the projection of a manifest `Retention`
# ordinal onto the mark's value, and the predicate for a mark's value
# =============================================================================
#
# The projection has NO default arm: UNSPECIFIED (0) and DELETE (1) are
# `delete`, RETAIN_KEEP (2) is `retain`, and any other ordinal raises, so a
# retained resource is never reported as a leak and a leak is never read as
# retained. The predicate accepts exactly the two values the projection emits.

from komira_validation_run.validation_run_tag import (
    RETENTION_TAG_VALUE_DELETE,
    RETENTION_TAG_VALUE_RETAIN,
    is_valid_retention_tag_value,
    retention_tag_value,
)
from std.testing import assert_equal, assert_false, assert_true


def _ordinals(*values: Int) -> List[Int]:
    """Ordinals built at run time, so no call is folded to a constant."""
    var out = List[Int]()
    for v in values:
        out.append(v)
    return out^


def test_unspecified_and_delete_project_to_delete() raises:
    for o in _ordinals(0, 1):
        assert_equal(retention_tag_value(o), String(RETENTION_TAG_VALUE_DELETE))


def test_retain_keep_projects_to_retain() raises:
    for o in _ordinals(2):
        assert_equal(retention_tag_value(o), String(RETENTION_TAG_VALUE_RETAIN))


def test_an_ordinal_outside_the_enum_raises_whatever_its_side() raises:
    for o in _ordinals(3, 4, 99, -1, -2147483648):
        var got = String()
        try:
            _ = retention_tag_value(o)
        except e:
            got = String(e)
        assert_true("unknown Retention ordinal " + String(o) in got, "ordinal " + String(o) + " did not raise: '" + got + "'")


def test_the_predicate_accepts_the_two_emitted_values_only() raises:
    assert_true(is_valid_retention_tag_value(String(RETENTION_TAG_VALUE_DELETE)))
    assert_true(is_valid_retention_tag_value(String(RETENTION_TAG_VALUE_RETAIN)))
    assert_true(is_valid_retention_tag_value("delete"))
    assert_true(is_valid_retention_tag_value("retain"))
    for v in ["", "Delete", "RETAIN", "keep", "delete ", " retain", "retain,delete", "true"]:
        assert_false(is_valid_retention_tag_value(String(v)), "accepted '" + String(v) + "'")


def test_every_emitted_value_is_valid() raises:
    for o in _ordinals(0, 1, 2):
        assert_true(is_valid_retention_tag_value(retention_tag_value(o)))


def main() raises:
    test_unspecified_and_delete_project_to_delete()
    test_retain_keep_projects_to_retain()
    test_an_ordinal_outside_the_enum_raises_whatever_its_side()
    test_the_predicate_accepts_the_two_emitted_values_only()
    test_every_emitted_value_is_valid()
    print("test_retention_tag_value: 5 tests PASSED")
