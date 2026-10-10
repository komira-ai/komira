# =============================================================================
# test_cloud_label_role_encoding.mojo
# =============================================================================
#
# How the standard label rule writes a node's role (labels.mojo), with no
# cloud:
#
# 1. THE LABEL RULE WRITES `/` AS `_`: one byte per separator, decoded
#    exactly; a value holding `_` is refused (it would decode as a `/`); the
#    63/64-byte boundary.
# 2. DEPTH-N IDS: a node `top/a/b/c/run` is owned by `top` and stamped with
#    role `a/b/c/run`, written `a_b_c_run`, and the stamp round-trips; a role
#    value holding `--` is an ordinary value, never split into segments.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_reconciler import CellScope, Label, Provenance
from kci_cloud import (
    decode_label_value,
    encode_label_value,
    label_problems,
    owner_of_node,
    standard_identity_of,
    standard_label_rule,
)


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _scope() -> CellScope:
    return CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1")))


# ---- 1. the label rule writes `/` as `_` -------------------------------------------


def _repeat(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def _raises_encoding(v: String, why: String) raises -> String:
    try:
        _ = encode_label_value(v)
    except e:
        return String(e)
    raise Error(String("not refused: ") + why)


def test_the_label_rule_writes_slash_as_underscore() raises:
    assert_equal(encode_label_value(String("a/b/c/run")), "a_b_c_run")
    assert_equal(decode_label_value(String("a_b_c_run")), "a/b/c/run")
    assert_equal(encode_label_value(String("run")), "run", "no separator, unchanged")
    assert_equal(encode_label_value(String("a-b/c-d")), "a-b_c-d", "a single '-' is kept")
    # A raw `_` would decode as a `/`: two different roles would read as one.
    var e = _raises_encoding(String("a_b"), "a value holding '_'")
    assert_true(_has(e, "'_'"), e)
    _ = _raises_encoding(String("x/a_b"), "a segment holding '_'")
    # The boundary: 63 bytes encoded is written, 64 is refused (never cut).
    var r63 = _repeat(String("a"), 31) + String("/") + _repeat(String("b"), 31)
    assert_equal(encode_label_value(r63).byte_length(), 63)
    var r64 = r63 + String("c")
    var e64 = _raises_encoding(r64, "a 64-byte value")
    assert_true(_has(e64, "64 bytes encoded; at most 63"), e64)
    print("  test_the_label_rule_writes_slash_as_underscore: PASS")


# ---- 2. depth-N ids -------------------------------------------------------------


def _label_value(labels: List[Label], key: String) -> String:
    for i in range(len(labels)):
        if labels[i].key == key:
            return labels[i].value.copy()
    return String("")


def test_depth_n_ids_round_trip_the_owner_and_the_stamp() raises:
    var scope = _scope()
    var stamp = scope.stamp(String("top"), String("top/a/b/c/run"))
    assert_equal(stamp.resource, "top", "the owner is the first segment")
    assert_equal(stamp.role, "a/b/c/run", "the role is the rest of the node id")
    var labels = standard_label_rule(stamp)
    assert_equal(_label_value(labels, String("kci_resource")), "top")
    assert_equal(_label_value(labels, String("kci_role")), "a_b_c_run")
    assert_equal(len(label_problems(labels)), 0)
    assert_equal(standard_identity_of(labels), stamp.identity(), "the stamp round-trips")
    assert_equal(owner_of_node(String("top/a/b/c/run")), "top", "the owner at depth 3")
    assert_equal(owner_of_node(String("top/run")), "top", "the owner at depth 0")
    print("  test_depth_n_ids_round_trip_the_owner_and_the_stamp: PASS")


def test_a_double_dash_role_label_is_never_an_owner() raises:
    """`--` was once the separator written for `/`. It was never deployed, so
    there is no compatibility: a role value written that way is an ordinary
    value that holds `--`, and no node's identity."""
    var scope = _scope()
    var want = scope.stamp(String("uses"), String("uses/jobs"))
    var labels = standard_label_rule(want)
    for i in range(len(labels)):
        if labels[i].key == "kci_role":
            labels[i] = Label(String("kci_role"), String("jobs--run"))
    assert_equal(decode_label_value(String("uses--jobs")), "uses--jobs", "no '/' is made of '--'")
    var got = standard_identity_of(labels)
    assert_true(got.byte_length() > 0, "a complete stamp still reads")
    assert_true(got != want.identity(), "it is not the node it resembles")
    assert_true(not _has(got, "jobs/run"), "its role is never split into segments")
    print("  test_a_double_dash_role_label_is_never_an_owner: PASS")


def main() raises:
    print("test_cloud_label_role_encoding")
    test_the_label_rule_writes_slash_as_underscore()
    test_depth_n_ids_round_trip_the_owner_and_the_stamp()
    test_a_double_dash_role_label_is_never_an_owner()
    print("ALL kci_cloud LABEL ROLE ENCODING TESTS PASSED")
