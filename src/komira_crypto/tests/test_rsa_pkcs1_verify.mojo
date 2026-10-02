# =============================================================================
# komira_crypto/tests/test_rsa_pkcs1_verify.mojo — RSASSA-PKCS1-v1_5-SHA-256
#   (RFC 7518 §3.3 RS256) VERIFY, against a PUBLISHED third-party vector.
# =============================================================================
#
# RS256 needs a VERIFY as well as a SIGN: `komira_crypto/rsa.mojo`'s
# `rsa_sha256_sign` alone is not enough, and RSA-**PSS** is a different
# signature scheme. This pins the verify primitive.
#
# ★ THE PRIMARY VECTOR IS NOT OURS. It is **RFC 7515 Appendix A.2** — the IETF's
# own published RS256 JWS example, key and all. That matters more than a
# locally-generated KAT would: a vector we generate is verified against the same
# library we call, so it cannot detect a whole-scheme error (a wrong DigestInfo
# NID, PSS instead of PKCS#1 v1.5, the wrong hash). The RFC's signature was
# produced by neither our code nor AWS-LC, and it verifies only if we implement
# the scheme the standard describes.
#
# The negative cases are constructed FROM that same vector, so each one differs
# from a known-good input in exactly one way.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from komira_encoding import base64_url_decode
from komira_crypto.rsa import rsa_pkcs1_sha256_verify


# -----------------------------------------------------------------------------
# RFC 7515 Appendix A.2 — "Example JWS Using RSASSA-PKCS1-v1_5 SHA-256".
# The JWK's `n` (A.2.1), the signing input (A.2.1's header + payload), and the
# signature (A.2.2). `e` is "AQAB" = 65537.
# -----------------------------------------------------------------------------


def _rfc7515_a2_n_b64() -> String:
    return String(
        "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw"
        + "-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b3269"
        + "0r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS"
        + "-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aG"
        + "hyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXp"
        + "oQ"
    )


def _rfc7515_a2_signing_input() -> String:
    return String(
        "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQo"
        + "gImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ"
    )


def _rfc7515_a2_sig_b64() -> String:
    return String(
        "cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuH"
        + "Im4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdi"
        + "uB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN"
        + "9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2"
        + "w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77"
        + "Rw"
    )


# A DIFFERENT 2048-bit modulus (generated independently) — the wrong-key case.
def _other_n_b64() -> String:
    return String(
        "xKwDizIK4EB8qv6WrWyzsLzTqMAOic92dQcR1FueXLmql01gYlzO4QzGqJzmQqD8krnC"
        + "FCa4ze248i8D0VYEheWlIneoJBM22y2IFQnKZ5DF8vmW1O4dgthwRI_5ifXLY18XM5H0"
        + "hCPEgT4PuN5HnJefx63w_JakjBTweBGMJKoWLvg6TXB1IvIccWIxIychpR1J-q0tjW7g"
        + "75qoBfbbkQmFt2OJKyLme_rIb1tgX_EjkuYj1PGLvrJYzy_ZYN95X2pCGXfjG-LwobKB"
        + "ZQgwTm9GauTLxnem8mSsxzDrrIXX8nqtIyhMBqWmVo4f-3RLoZZ5yqx4cUQFSfKt2c1N"
        + "JQ"
    )


def test_rfc7515_a2_rs256_verifies() raises:
    """THE CONTROL. Without this every refusal below would be vacuous."""
    var n = base64_url_decode(_rfc7515_a2_n_b64())
    var sig = base64_url_decode(_rfc7515_a2_sig_b64())
    assert_equal(len(n), 256, "RFC 7515 A.2 is a 2048-bit key")
    assert_equal(len(sig), 256, "an RS256 signature is modulus-length")
    var si = _rfc7515_a2_signing_input()
    assert_true(
        rsa_pkcs1_sha256_verify(
            Span[UInt8, origin_of(n)](n),
            UInt64(65537),
            si.as_bytes(),
            Span[UInt8, origin_of(sig)](sig),
        ),
        "the PUBLISHED RFC 7515 A.2 RS256 signature MUST verify — if this fails"
        " the scheme is wrong (PSS vs PKCS#1 v1.5, or the wrong DigestInfo NID),"
        " not the vector",
    )


def test_tampered_message_fails() raises:
    """One character changed in the signed input -> refused."""
    var n = base64_url_decode(_rfc7515_a2_n_b64())
    var sig = base64_url_decode(_rfc7515_a2_sig_b64())
    var si = _rfc7515_a2_signing_input()
    # Flip the LAST payload character. `w` -> `x` keeps it valid base64url, so
    # this is a tampered CLAIM, not a malformed token.
    var tampered = String(si[byte=0 : si.byte_length() - 1]) + String("x")
    assert_false(
        rsa_pkcs1_sha256_verify(
            Span[UInt8, origin_of(n)](n),
            UInt64(65537),
            tampered.as_bytes(),
            Span[UInt8, origin_of(sig)](sig),
        ),
        "a tampered payload MUST NOT verify",
    )


def test_tampered_signature_fails() raises:
    var n = base64_url_decode(_rfc7515_a2_n_b64())
    var sig = base64_url_decode(_rfc7515_a2_sig_b64())
    sig[100] = sig[100] ^ UInt8(0x01)
    var si = _rfc7515_a2_signing_input()
    assert_false(
        rsa_pkcs1_sha256_verify(
            Span[UInt8, origin_of(n)](n),
            UInt64(65537),
            si.as_bytes(),
            Span[UInt8, origin_of(sig)](sig),
        ),
        "a one-bit signature change MUST NOT verify",
    )


def test_truncated_signature_fails() raises:
    """255 bytes against a 256-byte modulus. RFC 8017 §8.2.2 step 1."""
    var n = base64_url_decode(_rfc7515_a2_n_b64())
    var sig = base64_url_decode(_rfc7515_a2_sig_b64())
    var si = _rfc7515_a2_signing_input()
    assert_false(
        rsa_pkcs1_sha256_verify(
            Span[UInt8, origin_of(n)](n),
            UInt64(65537),
            si.as_bytes(),
            Span[UInt8, origin_of(sig)](sig)[0:255],
        ),
        "a signature shorter than the modulus MUST NOT verify",
    )


def test_wrong_key_fails() raises:
    """A DIFFERENT, equally valid 2048-bit key -> refused. This is the case a
    JWKS `kid` mix-up produces, and the one a verifier that 'tries every key'
    would eventually get wrong."""
    var other = base64_url_decode(_other_n_b64())
    var sig = base64_url_decode(_rfc7515_a2_sig_b64())
    assert_equal(len(other), 256, "the wrong key must be the SAME SIZE — a"
        " length mismatch would be refused for the wrong reason")
    var si = _rfc7515_a2_signing_input()
    assert_false(
        rsa_pkcs1_sha256_verify(
            Span[UInt8, origin_of(other)](other),
            UInt64(65537),
            si.as_bytes(),
            Span[UInt8, origin_of(sig)](sig),
        ),
        "a valid signature under a DIFFERENT key MUST NOT verify",
    )


def test_wrong_exponent_fails() raises:
    var n = base64_url_decode(_rfc7515_a2_n_b64())
    var sig = base64_url_decode(_rfc7515_a2_sig_b64())
    var si = _rfc7515_a2_signing_input()
    assert_false(
        rsa_pkcs1_sha256_verify(
            Span[UInt8, origin_of(n)](n),
            UInt64(3),
            si.as_bytes(),
            Span[UInt8, origin_of(sig)](sig),
        ),
        "the right modulus with the wrong exponent MUST NOT verify",
    )


def test_empty_inputs_are_refused_not_crashes() raises:
    """The verifier is fed attacker-controlled documents, so degenerate input
    must CUT rather than reach AWS-LC with a zero-length key."""
    var empty = List[UInt8]()
    var sig = base64_url_decode(_rfc7515_a2_sig_b64())
    var si = _rfc7515_a2_signing_input()
    assert_false(
        rsa_pkcs1_sha256_verify(
            Span[UInt8, origin_of(empty)](empty),
            UInt64(65537),
            si.as_bytes(),
            Span[UInt8, origin_of(sig)](sig),
        ),
        "an empty modulus MUST NOT verify",
    )
    var n = base64_url_decode(_rfc7515_a2_n_b64())
    assert_false(
        rsa_pkcs1_sha256_verify(
            Span[UInt8, origin_of(n)](n),
            UInt64(65537),
            si.as_bytes(),
            Span[UInt8, origin_of(empty)](empty),
        ),
        "an empty signature MUST NOT verify",
    )


def main() raises:
    test_rfc7515_a2_rs256_verifies()
    test_tampered_message_fails()
    test_tampered_signature_fails()
    test_truncated_signature_fails()
    test_wrong_key_fails()
    test_wrong_exponent_fails()
    test_empty_inputs_are_refused_not_crashes()
    print("OK")
