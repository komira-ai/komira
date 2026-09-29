# =============================================================================
# komira_crypto/tests/test_root_store.mojo
# =============================================================================
#
# RootStore
# smoke tests. Verifies the 10 vendored Mozilla CA roots parse correctly
# and expose the expected subject DN CN strings.
#
# Acceptance gate (a): RootStore parses + exposes 5-10 trusted Mozilla
# CA roots.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false

from komira_crypto.cert import (
    mozilla_root_store,
    root_store_verify,
    X509Certificate,
)


# -----------------------------------------------------------------------------
# Helper: look up a DnAttribute's value by OID prefix (e.g. 2.5.4.3 for CN).
# Mojo 1.0.0b1 idiom: don't copy the heap-owning struct; index directly.
# -----------------------------------------------------------------------------


def _cn_of(cert: X509Certificate) -> String:
    """Returns the subject's commonName string, or empty if none found.

    commonName OID is 2.5.4.3 — sequence [2, 5, 4, 3].

    Mojo 1.0.0b1 idiom: List[UInt32] is not ImplicitlyCopyable; we
    index directly into cert.subject[i].oid rather than copying to
    a local.
    """
    for i in range(len(cert.subject)):
        if (
            len(cert.subject[i].oid) == 4
            and cert.subject[i].oid[0] == UInt32(2)
            and cert.subject[i].oid[1] == UInt32(5)
            and cert.subject[i].oid[2] == UInt32(4)
            and cert.subject[i].oid[3] == UInt32(3)
        ):
            return cert.subject[i].value
    return String("")


# -----------------------------------------------------------------------------
# Test 1: mozilla_root_store() parses exactly 10 roots.
# -----------------------------------------------------------------------------


def test_root_store_has_10_roots() raises:
    var roots = mozilla_root_store()
    assert_equal(len(roots), 10, "mozilla_root_store must return exactly 10 roots")


# -----------------------------------------------------------------------------
# Test 2: every root parses + subject DN is non-empty.
# -----------------------------------------------------------------------------


def test_root_store_subjects_non_empty() raises:
    var roots = mozilla_root_store()
    for i in range(len(roots)):
        assert_true(
            len(roots[i].subject) > 0,
            "root " + String(i) + " has empty subject DN",
        )
        # tbs_raw must be populated (signature verification uses it).
        assert_true(
            len(roots[i].tbs_raw) > 0,
            "root " + String(i) + " has empty tbs_raw",
        )
        # subject_pubkey must be populated.
        assert_true(
            len(roots[i].subject_pubkey) > 0,
            "root " + String(i) + " has empty subject_pubkey",
        )


# -----------------------------------------------------------------------------
# Test 3: each root has the expected subject-CN.
# -----------------------------------------------------------------------------


def test_root_store_expected_cns() raises:
    var roots = mozilla_root_store()
    var expected = List[String]()
    expected.append(String("ISRG Root X1"))
    expected.append(String("ISRG Root X2"))
    expected.append(String("DigiCert Global Root CA"))
    expected.append(String("DigiCert Global Root G2"))
    expected.append(String("Amazon Root CA 1"))
    expected.append(String("USERTrust RSA Certification Authority"))
    expected.append(String("USERTrust ECC Certification Authority"))
    expected.append(String("GTS Root R1"))
    expected.append(String("Microsoft RSA Root Certificate Authority 2017"))
    # GlobalSign Root CA - R6's literal subject CN is "GlobalSign" — the
    # Mozilla label "GlobalSign Root CA - R6" actually refers to the OU
    # attribute. Verified via `openssl x509 -noout -subject`:
    #   subject=OU=GlobalSign Root CA - R6, O=GlobalSign, CN=GlobalSign
    expected.append(String("GlobalSign"))
    for i in range(len(roots)):
        var cn = _cn_of(roots[i])
        assert_equal(
            cn,
            expected[i],
            "root " + String(i) + " subject-CN mismatch (expected " + expected[i] + ", got " + cn + ")",
        )


# -----------------------------------------------------------------------------
# Test 4: every root is self-issued (issuer DN == subject DN). All
# trust anchors are self-signed by construction.
# -----------------------------------------------------------------------------


def test_root_store_all_self_issued() raises:
    var roots = mozilla_root_store()
    for i in range(len(roots)):
        # Compare issuer DN to subject DN length + byte-equal value at each
        # index. We use the same byte-equal DN compare as chain.mojo's
        # _dn_equal (RFC 5280 §7.1 canonical deferred).
        assert_equal(
            len(roots[i].issuer),
            len(roots[i].subject),
            "root " + String(i) + " issuer-len != subject-len (not self-issued)",
        )
        for j in range(len(roots[i].issuer)):
            # OID equality + value equality
            assert_equal(
                len(roots[i].issuer[j].oid),
                len(roots[i].subject[j].oid),
                "root " + String(i) + " issuer/subject OID len mismatch at attr " + String(j),
            )
            for k in range(len(roots[i].issuer[j].oid)):
                assert_equal(
                    roots[i].issuer[j].oid[k],
                    roots[i].subject[j].oid[k],
                    "root " + String(i) + " issuer/subject OID byte mismatch at attr " + String(j) + " pos " + String(k),
                )
            assert_equal(
                roots[i].issuer[j].value,
                roots[i].subject[j].value,
                "root " + String(i) + " issuer/subject value mismatch at attr " + String(j),
            )


# -----------------------------------------------------------------------------
# Test 5: empty chain to root_store_verify raises.
# -----------------------------------------------------------------------------


def test_root_store_verify_empty_chain_raises() raises:
    var chain = List[X509Certificate]()
    var caught = False
    try:
        # 2027-05-23 12:00:00 UTC
        var _ok = root_store_verify(chain, (UInt16(2027), UInt8(5), UInt8(23), UInt8(12), UInt8(0), UInt8(0)))
    except _:
        caught = True
    assert_true(caught, "empty chain to root_store_verify must raise")


# -----------------------------------------------------------------------------
# Main: gate runner.
# -----------------------------------------------------------------------------


def main() raises:
    test_root_store_has_10_roots()
    test_root_store_subjects_non_empty()
    test_root_store_expected_cns()
    test_root_store_all_self_issued()
    test_root_store_verify_empty_chain_raises()
    print("test_root_store.mojo: 5/5 GREEN")
