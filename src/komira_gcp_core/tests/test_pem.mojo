# =============================================================================
# komira_gcp_core/tests/test_pem.mojo -- PEM armor to DER.
# =============================================================================
#
# The decoder on synthetic blocks: what it accepts (CRLF, surrounding text,
# indentation) and what it refuses (no armor, a mismatched or missing END, an
# empty body, the PKCS#1 and encrypted labels, a body that is not base64, a
# body that is not a DER SEQUENCE). The real key, Google's published dummy
# service account, is decoded and signed with in test_v4_sign_conformance.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_gcp_core import (
    PEM_PKCS8_PRIVATE_KEY_LABEL,
    pem_decode,
    pkcs8_private_key_der_from_pem,
)


# base64 of the bytes 30 03 02 01 05: a DER SEQUENCE holding INTEGER 5.
comptime _BODY = "MAMCAQU="


def _bytes() -> List[UInt8]:
    var out = List[UInt8]()
    out.append(0x30)
    out.append(0x03)
    out.append(0x02)
    out.append(0x01)
    out.append(0x05)
    return out^


def _block(label: String, body: String) -> String:
    return (
        "-----BEGIN " + label + "-----\n" + body + "\n-----END " + label + "-----\n"
    )


def _assert_equal_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _refused(pem: String) -> Bool:
    try:
        _ = pkcs8_private_key_der_from_pem(pem)
    except:
        return True
    return False


def _refusal(pem: String) -> String:
    try:
        _ = pkcs8_private_key_der_from_pem(pem)
    except e:
        return String(e)
    return String()


def test_accepts_a_pkcs8_block() raises:
    _assert_equal_bytes(
        pkcs8_private_key_der_from_pem(_block("PRIVATE KEY", _BODY)), _bytes()
    )
    assert_equal(String(PEM_PKCS8_PRIVATE_KEY_LABEL), "PRIVATE KEY")


def test_accepts_crlf_indentation_split_body_and_surrounding_text() raises:
    var pem = (
        "a key follows\r\n  -----BEGIN PRIVATE KEY-----\r\n MAMC \r\n\tAQU=\r\n"
        "-----END PRIVATE KEY-----\r\ntrailing text\r\n"
    )
    _assert_equal_bytes(pkcs8_private_key_der_from_pem(pem), _bytes())
    # No final newline.
    _assert_equal_bytes(
        pkcs8_private_key_der_from_pem(
            "-----BEGIN PRIVATE KEY-----\nMAMCAQU=\n-----END PRIVATE KEY-----"
        ),
        _bytes(),
    )


def test_pem_decode_takes_any_label() raises:
    _assert_equal_bytes(pem_decode(_block("CERTIFICATE", _BODY), "CERTIFICATE"), _bytes())


def test_refusals() raises:
    # No armor.
    assert_true(_refused(_BODY))
    assert_true(_refused(""))
    # The PKCS#1 and encrypted forms, by name.
    assert_true(_refusal(_block("RSA PRIVATE KEY", _BODY)).find("PKCS#1") >= 0)
    assert_true(
        _refusal(_block("ENCRYPTED PRIVATE KEY", _BODY)).find("ENCRYPTED") >= 0
    )
    # Another label.
    assert_true(_refused(_block("CERTIFICATE", _BODY)))
    # END with another label, and no END at all.
    assert_true(
        _refused(
            "-----BEGIN PRIVATE KEY-----\n" + _BODY + "\n-----END PUBLIC KEY-----\n"
        )
    )
    assert_true(_refused("-----BEGIN PRIVATE KEY-----\n" + _BODY + "\n"))
    # A second BEGIN before the END.
    assert_true(
        _refused(
            "-----BEGIN PRIVATE KEY-----\n"
            + _BODY
            + "\n"
            + _block("PRIVATE KEY", _BODY)
        )
    )
    # A malformed boundary.
    assert_true(
        _refused("-----BEGIN PRIVATE KEY\n" + _BODY + "\n-----END PRIVATE KEY-----\n")
    )
    # An empty body.
    assert_true(_refused(_block("PRIVATE KEY", "")))
    # A legacy header line, and a body that is not base64.
    assert_true(_refused(_block("PRIVATE KEY", "Proc-Type: 4,ENCRYPTED\n" + _BODY)))
    assert_true(_refused(_block("PRIVATE KEY", "MAMCAQU")))
    # Not a DER SEQUENCE: base64 of 02 01 05.
    assert_true(_refused(_block("PRIVATE KEY", "AgEF")))


def test_refusals_carry_no_body_byte() raises:
    var secret = "c2VjcmV0LWtleS1ib2R5"  # base64 of "secret-key-body"
    var msgs = List[String]()
    msgs.append(_refusal(_block("PRIVATE KEY", secret + "!")))
    msgs.append(_refusal(_block("PRIVATE KEY", secret)))
    msgs.append(_refusal("-----BEGIN PRIVATE KEY-----\n" + secret + "\n"))
    for i in range(len(msgs)):
        assert_true(msgs[i].byte_length() > 0)
        assert_true(msgs[i].find("c2VjcmV0") < 0, msgs[i])
        assert_true(msgs[i].find("secret") < 0, msgs[i])


def main() raises:
    test_accepts_a_pkcs8_block()
    test_accepts_crlf_indentation_split_body_and_surrounding_text()
    test_pem_decode_takes_any_label()
    test_refusals()
    test_refusals_carry_no_body_byte()
    print("all pem tests passed")
