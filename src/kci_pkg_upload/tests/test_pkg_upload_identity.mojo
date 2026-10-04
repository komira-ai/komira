# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_identity.mojo — "the same
#   bytes" is decided field by field, and NO common field is never "the same".
# =============================================================================
#
# ROWS
#   (1) two DISJOINT identities (ours exposes only sha256, theirs only sha512)
#       are NO_COMMON_FIELD — never MATCH. This is the vacuous-equality defect
#       the kind exists to refuse;
#   (2) an identity exposing nothing, against a full one: NO_COMMON_FIELD;
#   (3) MATCH on the shared field; a witness-only overlap (sha512 + sha1, the
#       npm shape) MATCHES without a sha256;
#   (4) MISMATCH when any shared field differs, even if another shared field
#       agrees;
#   (5) hex compares case-insensitively; the SRI (base64) does not;
#   (6) `content_identity_of` computes all three from the bytes (FIPS 180
#       "abc" values), and a `PackageFile` carries exactly that identity;
#   (7) `presence_from_read_back` maps each read kind, and a PRESENT read-back
#       with no digest is NO_COMMON_FIELD, not PRESENT_IDENTICAL.
#
# Hermetic: no file, no network.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.identity import (
    IDENTITY_MATCH,
    IDENTITY_MISMATCH,
    IDENTITY_NO_COMMON_FIELD,
    ContentIdentity,
    content_identity_of,
    identity_matches,
)
from kci_pkg_upload.outcome import (
    PRESENCE_ABSENT,
    PRESENCE_AUTH_REFUSED,
    PRESENCE_NO_COMMON_FIELD,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    PRESENCE_RATE_LIMITED,
    PRESENCE_UNKNOWN,
    READ_ABSENT,
    READ_AUTH_REFUSED,
    READ_PRESENT,
    READ_RATE_LIMITED,
    READ_UNKNOWN,
    ReadBack,
)
from kci_pkg_upload.registry_set import presence_from_read_back
from kci_pkg_upload.wire import bytes_of


comptime _ABC_SHA256: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
comptime _ABC_SHA512_SRI: String = "sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw=="
comptime _ABC_SHA1: String = "a9993e364706816aba3e25717850c26c9cd0d89d"


def test_disjoint_identities_are_no_common_field_never_match() raises:
    var ours = ContentIdentity.of_sha256_hex(String(_ABC_SHA256))
    var theirs = ContentIdentity(String(""), String(_ABC_SHA512_SRI), String(""))
    assert_equal(identity_matches(ours, theirs), IDENTITY_NO_COMMON_FIELD)
    assert_equal(identity_matches(theirs, ours), IDENTITY_NO_COMMON_FIELD)
    print("  test_disjoint_identities_are_no_common_field_never_match: PASS")


def test_nothing_exposed_is_no_common_field() raises:
    var full = content_identity_of(bytes_of(String("abc")))
    assert_equal(identity_matches(full, ContentIdentity.none()), IDENTITY_NO_COMMON_FIELD)
    assert_equal(identity_matches(ContentIdentity.none(), full), IDENTITY_NO_COMMON_FIELD)
    assert_equal(
        identity_matches(ContentIdentity.none(), ContentIdentity.none()),
        IDENTITY_NO_COMMON_FIELD,
    )
    print("  test_nothing_exposed_is_no_common_field: PASS")


def test_match_on_shared_fields_including_witness_only() raises:
    var full = content_identity_of(bytes_of(String("abc")))
    assert_equal(
        identity_matches(full, ContentIdentity.of_sha256_hex(String(_ABC_SHA256))),
        IDENTITY_MATCH,
    )
    # The npm shape: the registry exposes sha512 + sha1 only.
    var npm = ContentIdentity(String(""), String(_ABC_SHA512_SRI), String(_ABC_SHA1))
    assert_equal(identity_matches(full, npm), IDENTITY_MATCH)
    print("  test_match_on_shared_fields_including_witness_only: PASS")


def test_any_shared_difference_is_mismatch() raises:
    var full = content_identity_of(bytes_of(String("abc")))
    var other = content_identity_of(bytes_of(String("abd")))
    assert_equal(identity_matches(full, other), IDENTITY_MISMATCH)
    # sha256 agrees, sha1 differs: still a MISMATCH.
    var half = ContentIdentity(String(_ABC_SHA256), String(""), other.sha1_hex.copy())
    assert_equal(identity_matches(full, half), IDENTITY_MISMATCH)
    print("  test_any_shared_difference_is_mismatch: PASS")


def test_hex_is_case_insensitive_sri_is_not() raises:
    var full = content_identity_of(bytes_of(String("abc")))
    var upper = ContentIdentity.of_sha256_hex(String(_ABC_SHA256).upper())
    assert_equal(identity_matches(full, upper), IDENTITY_MATCH)
    var sri_case = ContentIdentity(String(""), String(_ABC_SHA512_SRI).lower(), String(""))
    assert_equal(identity_matches(full, sri_case), IDENTITY_MISMATCH)
    print("  test_hex_is_case_insensitive_sri_is_not: PASS")


def test_content_identity_of_and_package_file() raises:
    var id = content_identity_of(bytes_of(String("abc")))
    assert_equal(id.sha256_hex, String(_ABC_SHA256))
    assert_equal(id.sha512_sri, String(_ABC_SHA512_SRI))
    assert_equal(id.sha1_hex, String(_ABC_SHA1))
    var f = PackageFile(
        PackageCoordinate(
            SUBSTRATE_PUBLIC_PYPI,
            String("test.pypi.org"),
            String("p"),
            String("1.1.1"),
            String("linux-64"),
            String("p-1.1.1-py3-none-any.whl"),
        ),
        bytes_of(String("abc")),
        String(""),
    )
    assert_equal(f.identity.sha256_hex, String(_ABC_SHA256))
    print("  test_content_identity_of_and_package_file: PASS")


def _rb(kind: Int, var observed: ContentIdentity) -> ReadBack:
    return ReadBack(kind, 200, observed^, String(""))


def test_presence_from_read_back() raises:
    var ours = content_identity_of(bytes_of(String("abc")))
    var theirs_same = ContentIdentity.of_sha256_hex(String(_ABC_SHA256))
    var theirs_diff = content_identity_of(bytes_of(String("xyz")))
    assert_equal(
        presence_from_read_back(_rb(READ_PRESENT, theirs_same^), ours).kind,
        PRESENCE_PRESENT_IDENTICAL,
    )
    var p_diff = presence_from_read_back(_rb(READ_PRESENT, theirs_diff^), ours)
    assert_equal(p_diff.kind, PRESENCE_PRESENT_DIFFERENT)
    # The refusal names BOTH identities.
    assert_true(p_diff.detail.find(String(_ABC_SHA256)) >= 0)
    assert_equal(
        presence_from_read_back(_rb(READ_PRESENT, ContentIdentity.none()), ours).kind,
        PRESENCE_NO_COMMON_FIELD,
    )
    assert_equal(
        presence_from_read_back(_rb(READ_ABSENT, ContentIdentity.none()), ours).kind,
        PRESENCE_ABSENT,
    )
    assert_equal(
        presence_from_read_back(_rb(READ_AUTH_REFUSED, ContentIdentity.none()), ours).kind,
        PRESENCE_AUTH_REFUSED,
    )
    assert_equal(
        presence_from_read_back(_rb(READ_RATE_LIMITED, ContentIdentity.none()), ours).kind,
        PRESENCE_RATE_LIMITED,
    )
    assert_equal(
        presence_from_read_back(_rb(READ_UNKNOWN, ContentIdentity.none()), ours).kind,
        PRESENCE_UNKNOWN,
    )
    print("  test_presence_from_read_back: PASS")


def main() raises:
    test_disjoint_identities_are_no_common_field_never_match()
    test_nothing_exposed_is_no_common_field()
    test_match_on_shared_fields_including_witness_only()
    test_any_shared_difference_is_mismatch()
    test_hex_is_case_insensitive_sri_is_not()
    test_content_identity_of_and_package_file()
    test_presence_from_read_back()
    print("test_pkg_upload_identity: ALL PASS")
