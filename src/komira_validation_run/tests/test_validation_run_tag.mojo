# =============================================================================
# test_validation_run_tag.mojo — the tag KEYS are legal on BOTH clouds for every
#   accepted prefix, and the id predicate refuses exactly the values that would
#   be silently mangled by one.
#
# ⛔ WHY A KEY NEEDS A TEST AT ALL. This key is stamped by two independent
# wire builders and READ by a third party (an external leak checker) that
# builds it the same way. Every one of those three is a place a mismatch
# fails SILENTLY: a key GCP rejects makes the create fail far from here; a key
# GCP TRUNCATES makes the two clouds carry different ids for one run; and a key
# the checker cannot parse makes it report a clean fleet forever. None of those
# is a compile error, so the assertion has to be written down.
# =============================================================================

from komira_validation_run.validation_run_tag import (
    TAG_KEY_MAX_LEN,
    VALIDATION_RUN_ID_MAX_LEN,
    is_valid_tag_key_prefix,
    is_valid_validation_run_id,
    resource_retention_tag_key,
    validation_run_tag_key,
)
from std.testing import assert_equal, assert_false, assert_true


def _is_gcp_label_key_legal(key: String) -> Bool:
    """GCP resource-label KEY rule, spelled out rather than imported: must start
    with a lowercase letter, then lowercase alphanumerics / `-` / `_`, <= 63.

    ⚠ SPELLED OUT ON PURPOSE. Asserting the constant against a predicate that
    lives beside it would be asserting the constant against itself; the rule is
    GCP's, so the test states GCP's rule."""
    var n = key.byte_length()
    if n == 0 or n > 63:
        return False
    var first = Int(key.as_bytes()[0])
    if not (first >= ord("a") and first <= ord("z")):
        return False
    for i in range(n):
        var c = Int(key.as_bytes()[i])
        var lower = c >= ord("a") and c <= ord("z")
        var digit = c >= ord("0") and c <= ord("9")
        var sep = c == ord("-") or c == ord("_")
        if not (lower or digit or sep):
            return False
    return True


def test_key_is_legal_as_a_gcp_label_key() raises:
    """⛔ THE CONSTRAINT THAT PICKED THIS SPELLING. Both tag-key conventions
    in use FAIL here — `example:owner` (colon) and the Kubernetes-style
    `example.dev/job-id` (dot + slash) — which is why neither was reused."""
    assert_true(_is_gcp_label_key_legal(validation_run_tag_key(String("example-ci"))))
    assert_true(
        _is_gcp_label_key_legal(resource_retention_tag_key(String("example-ci")))
    )
    # The two rejected incumbents, asserted as rejected so a future "just reuse
    # the existing convention" edit reds instead of shipping.
    assert_false(_is_gcp_label_key_legal(String("example:owner")))
    assert_false(_is_gcp_label_key_legal(String("example.dev/job-id")))


def test_key_is_legal_as_an_aws_tag_key() raises:
    """AWS tag keys accept far more than this (including the colon the EC2
    placement tag uses), so the only way to fail is to be empty or > 128."""
    var key = validation_run_tag_key(String("example-ci"))
    assert_true(key.byte_length() > 0)
    assert_true(key.byte_length() <= 128)


def test_key_does_not_collide_with_the_two_existing_run_id_meanings() raises:
    """⚠ `run_id` already names other things in a deploy system (a
    throwaway-run scope, a job-store partition key). Another meaning sharing
    the bare name makes a search for `run_id` useless for the question this
    key answers, so the key is deliberately NOT spelled `run-id`."""
    var key = validation_run_tag_key(String("example-ci"))
    assert_true(key != String("run-id"))
    assert_true(key != String("run_id"))


def test_id_predicate_refuses_empty() raises:
    """⛔ THE ABSENT-vs-EMPTY COLLAPSE, in the one place it deletes things. An
    empty id passed to the leak checker's auto-delete would mean 'delete every
    resource carrying an empty tag' — i.e. everything untagged."""
    assert_false(is_valid_validation_run_id(String("")))


def test_id_predicate_refuses_over_length() raises:
    """A value longer than the GCP cap is TRUNCATED by GCP and stamped in full
    by AWS — one run, two different ids, matching neither reliably."""
    var ok = String("")
    for _ in range(VALIDATION_RUN_ID_MAX_LEN):
        ok += String("a")
    assert_true(is_valid_validation_run_id(ok))
    var too_long = ok + String("a")
    assert_false(is_valid_validation_run_id(too_long))


def test_id_predicate_refuses_uppercase_and_punctuation() raises:
    """GCP is the strict side of the intersection: lowercase only. Validating
    against AWS alone would let a run mint an id GCP rejects at create time."""
    assert_false(is_valid_validation_run_id(String("Run-1")))
    assert_false(is_valid_validation_run_id(String("run.1")))
    assert_false(is_valid_validation_run_id(String("run/1")))
    assert_false(is_valid_validation_run_id(String("run:1")))
    assert_false(is_valid_validation_run_id(String("run 1")))


def test_id_predicate_accepts_the_shape_the_driver_scripts_mint() raises:
    """`<epoch>-<pid>-<rand>` in lowercase hex/decimal, bare or behind a short
    lowercase prefix — the shape a validation driver mints. If this ever reds, the minter and the predicate have drifted
    and every stamped resource is unmatchable."""
    assert_true(is_valid_validation_run_id(String("1788400000-31337-a3f9")))
    assert_true(is_valid_validation_run_id(String("cpm-1788400000-31337-a3f9")))


def test_keys_are_prefix_dash_suffix() raises:
    """The caller's prefix, a hyphen, then the fixed suffix: nothing else is
    added, so a reader that builds the key from the same prefix matches it."""
    assert_equal(
        validation_run_tag_key(String("example-ci")), String("example-ci-run-id")
    )
    assert_equal(
        resource_retention_tag_key(String("example-ci")),
        String("example-ci-retention"),
    )


def _raises_run_key(prefix: String) -> Bool:
    try:
        _ = validation_run_tag_key(prefix)
    except:
        return True
    return False


def _raises_retention_key(prefix: String) -> Bool:
    try:
        _ = resource_retention_tag_key(prefix)
    except:
        return True
    return False


def test_prefix_refusals() raises:
    """A prefix that would make either key illegal on one cloud is refused by
    the predicate, and both key builders RAISE on it instead of returning a
    key the cloud would reject at create time."""
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("Example"))
    bad.append(String("1ci"))
    bad.append(String("-ci"))
    bad.append(String("ex:ci"))
    bad.append(String("ex.ci"))
    bad.append(String("ex/ci"))
    bad.append(String("ex ci"))
    for i in range(len(bad)):
        assert_false(is_valid_tag_key_prefix(bad[i]))
        assert_true(_raises_run_key(bad[i]))
        assert_true(_raises_retention_key(bad[i]))
    assert_true(is_valid_tag_key_prefix(String("example-ci")))
    assert_true(is_valid_tag_key_prefix(String("a_b-9")))


def test_the_longest_accepted_prefix_fits_both_keys() raises:
    """The length bound is set by the LONGER key, `<prefix>-retention`: the
    longest accepted prefix gives two GCP-legal keys, one byte more is refused."""
    var longest = TAG_KEY_MAX_LEN - 1 - String("retention").byte_length()
    var p = String("")
    for _ in range(longest):
        p += String("a")
    assert_true(is_valid_tag_key_prefix(p))
    assert_true(_is_gcp_label_key_legal(validation_run_tag_key(p)))
    assert_true(_is_gcp_label_key_legal(resource_retention_tag_key(p)))
    assert_false(is_valid_tag_key_prefix(p + String("a")))
    assert_true(_raises_retention_key(p + String("a")))


def main() raises:
    test_key_is_legal_as_a_gcp_label_key()
    test_key_is_legal_as_an_aws_tag_key()
    test_key_does_not_collide_with_the_two_existing_run_id_meanings()
    test_id_predicate_refuses_empty()
    test_id_predicate_refuses_over_length()
    test_id_predicate_refuses_uppercase_and_punctuation()
    test_id_predicate_accepts_the_shape_the_driver_scripts_mint()
    test_keys_are_prefix_dash_suffix()
    test_prefix_refusals()
    test_the_longest_accepted_prefix_fits_both_keys()
    print("test_validation_run_tag: 10 tests PASSED")
