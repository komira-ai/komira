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
# 3. THE MARKS AND THE RULE'S REFUSALS: an engine retention with no mark
#    raises; `kci-retention=retain` is retained; a validation run id outside
#    the rule is named, and a stamp carrying one cannot be labelled; a key of
#    0 or 64 bytes, and a value of 64 bytes, are each refused (63 pass).
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_reconciler import CellScope, Label, OwnerStamp, Provenance, RETAIN_KEEP
from kci_cloud import (
    retain_labels,
    retained_by,
    retention_label_value,
    validation_run_labels,
    validation_run_problem,
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


# ---- 3. the marks and the rule's refusals --------------------------------------------


def test_the_marks_and_the_rules_refusals() raises:
    var why = String("")
    try:
        _ = retention_label_value(9)
    except e:
        why = String(e)
    assert_equal(why, "retention_label_value: engine retention 9 has no retention mark; state which side it is on")
    assert_true(retained_by(retain_labels(RETAIN_KEEP)))
    var bad = String("validation run id \"Run 1\" is not 1 to 63 bytes of [a-z0-9_-]; it would not be the same id on every cloud")
    assert_equal(validation_run_problem(String("Run 1")), bad)
    assert_equal(validation_run_problem(String("run-1")), "")
    why = String("")
    try:
        _ = validation_run_labels(
            OwnerStamp(String("shop"), String("blue"), String("api"), String("run"), validation_run_id=String("Run 1"))
        )
    except e:
        why = String(e)
    assert_equal(why, bad)
    var labels = List[Label]()
    labels.append(Label(String(""), String("v")))
    labels.append(Label(_repeat(String("k"), 64), String("v")))
    labels.append(Label(_repeat(String("k"), 63), String("v")))
    labels.append(Label(String("long"), _repeat(String("v"), 64)))
    labels.append(Label(String("edge"), _repeat(String("v"), 63)))
    var p = label_problems(labels)
    assert_equal(len(p), 3)
    assert_equal(p[0], "label key \"\" has a bad length")
    assert_equal(p[1], String("label key \"") + _repeat(String("k"), 64) + String("\" has a bad length"))
    assert_equal(p[2], "label \"long\" value is too long")
    print("  test_the_marks_and_the_rules_refusals: PASS")


def main() raises:
    print("test_cloud_label_role_encoding")
    test_the_label_rule_writes_slash_as_underscore()
    test_depth_n_ids_round_trip_the_owner_and_the_stamp()
    test_a_double_dash_role_label_is_never_an_owner()
    test_the_marks_and_the_rules_refusals()
    print("ALL kci_cloud LABEL ROLE ENCODING TESTS PASSED")
