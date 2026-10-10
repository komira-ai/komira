# PEM armor (RFC 7468): what the decoder accepts (CRLF, explanatory text,
# indentation, lax whitespace in the body, any well-formed label) and what it
# refuses (no armor, a malformed or mismatched boundary, another label, an
# empty or non-base64 body), with the named error kind and a position in the
# PEM text, and never an input byte in the message. The encoder writes the
# RFC 7468 section 2 generator form and round-trips through the decoder.

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import (
    PEM_LABEL_CERTIFICATE,
    PEM_LABEL_ENCRYPTED_PRIVATE_KEY,
    PEM_LABEL_PRIVATE_KEY,
    PEM_LABEL_PUBLIC_KEY,
    PEM_LINE_SYMBOLS,
    base64_encode,
    error_kind,
    pem_decode,
    pem_encode,
    pem_label,
)


# base64 of the bytes 30 03 02 01 05: a DER SEQUENCE holding INTEGER 5.
comptime _BODY = "MAMCAQU="


def _der() -> List[UInt8]:
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


def _assert_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _outcome(pem: String, label: String) -> String:
    """`OK`, or the error message of `pem_decode(pem, label)`."""
    try:
        _ = pem_decode(pem, label)
    except e:
        return String(e)
    return String("OK")


def _expect(pem: String, label: String, kind: String, position: Int) raises:
    var msg = _outcome(pem, label)
    assert_true(msg != String("OK"), pem)
    assert_equal(error_kind(Error(msg)), kind, msg)
    assert_true(msg.startswith("komira_encoding." + kind + ": pem_decode: "), msg)
    assert_true(msg.endswith(" at position " + String(position)), msg)


# --- accepted ---------------------------------------------------------------


def test_decodes_a_block() raises:
    _assert_bytes(pem_decode(_block("PRIVATE KEY", _BODY), "PRIVATE KEY"), _der())
    _assert_bytes(
        pem_decode(_block("CERTIFICATE", _BODY), PEM_LABEL_CERTIFICATE), _der()
    )
    assert_equal(String(PEM_LABEL_PRIVATE_KEY), "PRIVATE KEY")
    assert_equal(String(PEM_LABEL_ENCRYPTED_PRIVATE_KEY), "ENCRYPTED PRIVATE KEY")
    assert_equal(String(PEM_LABEL_PUBLIC_KEY), "PUBLIC KEY")
    assert_equal(String(PEM_LABEL_CERTIFICATE), "CERTIFICATE")
    # The Span overload.
    var pem = _block("PUBLIC KEY", _BODY)
    _assert_bytes(pem_decode(pem.as_bytes(), "PUBLIC KEY"), _der())


def test_crlf_indentation_split_body_and_surrounding_text() raises:
    var pem = (
        "a key follows\r\n  -----BEGIN PRIVATE KEY-----\r\n MAMC \r\n\tAQU=\r\n"
        "-----END PRIVATE KEY-----\r\ntrailing text\r\n"
    )
    _assert_bytes(pem_decode(pem, "PRIVATE KEY"), _der())
    # No final newline.
    _assert_bytes(
        pem_decode(
            "-----BEGIN PRIVATE KEY-----\nMAMCAQU=\n-----END PRIVATE KEY-----",
            "PRIVATE KEY",
        ),
        _der(),
    )
    # RFC 7468 `eol = CRLF / CR / LF`: lines that end in a lone CR, with
    # explanatory text before and after, and a body split over two lines.
    var cr = "a key follows\r-----BEGIN X-----\rMAMC\rAQU=\r-----END X-----\rmore\r"
    _assert_bytes(pem_decode(cr, "X"), _der())
    assert_equal(pem_label(cr), "X")
    # Mixed conventions in one file.
    _assert_bytes(
        pem_decode("-----BEGIN X-----\rMAMC\nAQU=\r\n-----END X-----\n", "X"),
        _der(),
    )
    # Positions count every byte of a lone-CR file: the END line is at 27.
    _expect(
        "-----BEGIN X-----\rMAMCAQU=\r-----END Y-----\r", "X", "InvalidBoundary", 27
    )


def test_lax_body_whitespace() raises:
    # RFC 7468 section 3 laxbase64text: W (SP, HT, LF, VT, FF, CR) anywhere
    # in the body, including inside a line and between the padding.
    var vt_ff = chr(0x0B) + chr(0x0C)
    var pem = (
        "-----BEGIN X-----\n\n M A\tM C "
        + vt_ff
        + "\r\n\nAQU =\n\n-----END X-----\n"
    )
    _assert_bytes(pem_decode(pem, "X"), _der())


def test_rfc7468_explanatory_text() raises:
    # RFC 7468 section 5.2: a certificate file may carry explanatory text,
    # for example the subject and issuer, before the block. Section 2:
    # parsers must not malfunction on data before or after the boundaries.
    var pem = (
        "Subject: CN=Example Leaf\n"
        "Issuer: CN=Example Root\n"
        "Validity: from 2026-09-01 to 2027-09-01\n"
        "-----BEGIN CERTIFICATE-----\n"
        + _BODY
        + "\n-----END CERTIFICATE-----\n"
        "and a note after the block, with ----- dashes in it\n"
    )
    _assert_bytes(pem_decode(pem, "CERTIFICATE"), _der())
    assert_equal(pem_label(pem), "CERTIFICATE")


def test_rfc7468_labels() raises:
    # Labels of RFC 7468 sections 5-14: spaces between words, digits, and the
    # grammar's single hyphen between label characters.
    var labels = List[String]()
    labels.append("CERTIFICATE")
    labels.append("X509 CRL")
    labels.append("CERTIFICATE REQUEST")
    labels.append("PKCS7")
    labels.append("CMS")
    labels.append("PRIVATE KEY")
    labels.append("ENCRYPTED PRIVATE KEY")
    labels.append("ATTRIBUTE CERTIFICATE")
    labels.append("PUBLIC KEY")
    labels.append("A-B C")
    labels.append("")  # the grammar's label is optional
    for i in range(len(labels)):
        var pem = _block(labels[i], _BODY)
        assert_equal(pem_label(pem), labels[i])
        _assert_bytes(pem_decode(pem, labels[i]), _der())


def test_pem_label_names_the_first_block() raises:
    assert_equal(pem_label(_block("RSA PRIVATE KEY", _BODY)), "RSA PRIVATE KEY")
    assert_equal(
        pem_label(_block("CERTIFICATE", _BODY) + _block("PRIVATE KEY", _BODY)),
        "CERTIFICATE",
    )
    # The body is not decoded.
    assert_equal(pem_label(_block("X", "not base64!")), "X")
    var raised = False
    try:
        _ = pem_label("no armor here")
    except e:
        raised = True
        assert_equal(error_kind(e), "InvalidBoundary")
        assert_true(String(e).startswith("komira_encoding.InvalidBoundary: pem_label: "))
    assert_true(raised)


# --- refused ----------------------------------------------------------------


def test_no_armor() raises:
    _expect(_BODY, "PRIVATE KEY", "InvalidBoundary", 8)
    _expect("", "PRIVATE KEY", "InvalidBoundary", 0)
    # A line that opens with five dashes before the block is a boundary or
    # an error, never explanatory text, even when a good block follows: a
    # BEGIN without its space, a dash line that is no boundary, a BEGIN
    # with the label glued on.
    _expect("-----BEGIN-----\n" + _block("X", _BODY), "X", "InvalidBoundary", 0)
    _expect("-----FOO-----\n" + _block("X", _BODY), "X", "InvalidBoundary", 0)
    _expect("t\n  -----BEGINX\n" + _block("X", _BODY), "X", "InvalidBoundary", 4)
    _expect("-----\n" + _block("X", _BODY), "X", "InvalidBoundary", 0)
    # An END line before any BEGIN.
    _expect("text\n-----END X-----\n" + _block("X", _BODY), "X", "InvalidBoundary", 5)
    # Fewer than five dashes, or dashes later in the line, are text.
    _assert_bytes(
        pem_decode("----BEGIN X-----\na ----- b\n" + _block("X", _BODY), "X"),
        _der(),
    )


def test_label_mismatch_is_not_skipped() raises:
    # The first block is the one read: a PRIVATE KEY after a CERTIFICATE is
    # not looked for, and the PKCS#1 and encrypted forms are other labels.
    var two = _block("CERTIFICATE", _BODY) + _block("PRIVATE KEY", _BODY)
    _expect(two, "PRIVATE KEY", "LabelMismatch", 11)
    _expect(_block("RSA PRIVATE KEY", _BODY), "PRIVATE KEY", "LabelMismatch", 11)
    _expect(
        _block("ENCRYPTED PRIVATE KEY", _BODY), "PRIVATE KEY", "LabelMismatch", 11
    )
    # Exact match: case and spacing count.
    _expect(_block("private key", _BODY), "PRIVATE KEY", "LabelMismatch", 11)
    _expect(_block("PRIVATE KEY", _BODY), "PRIVATE  KEY", "LabelMismatch", 11)


def test_malformed_boundaries() raises:
    # BEGIN without its closing dashes.
    _expect(
        "-----BEGIN PRIVATE KEY\n" + _BODY + "\n-----END PRIVATE KEY-----\n",
        "PRIVATE KEY",
        "InvalidBoundary",
        0,
    )
    # Labels outside the grammar: a double space, a trailing hyphen, a
    # leading space, a double hyphen, a non-ASCII byte.
    _expect(_block("A  B", _BODY), "A  B", "InvalidBoundary", 0)
    _expect(_block("A-", _BODY), "A-", "InvalidBoundary", 0)
    _expect(_block(" A", _BODY), " A", "InvalidBoundary", 0)
    _expect(_block("A--B", _BODY), "A--B", "InvalidBoundary", 0)
    _expect(_block("Aé", _BODY), "Aé", "InvalidBoundary", 0)
    # A byte outside labelchar between two label characters: the interior
    # loop's own refusal (the end checks pass for each of these).
    _expect(_block("A\tB", _BODY), "A\tB", "InvalidBoundary", 0)
    _expect(_block("AéB", _BODY), "AéB", "InvalidBoundary", 0)
    # Text after the boundary on its line.
    _expect(
        "-----BEGIN X----- trailing\n" + _BODY + "\n-----END X-----\n",
        "X",
        "InvalidBoundary",
        0,
    )


def test_end_line_rules() raises:
    # END with another label (RFC 7468 section 2 lets a parser ignore it;
    # this one refuses). The position is the END line.
    var pem = "-----BEGIN PRIVATE KEY-----\n" + _BODY + "\n-----END PUBLIC KEY-----\n"
    _expect(pem, "PRIVATE KEY", "InvalidBoundary", 37)
    # No END at all.
    var open = "-----BEGIN PRIVATE KEY-----\n" + _BODY + "\n"
    _expect(open, "PRIVATE KEY", "InvalidBoundary", open.byte_length())
    # A second BEGIN before the END, and a dash line that is no boundary:
    # each is named as what it is, not as a missing END.
    var nested = (
        "-----BEGIN PRIVATE KEY-----\n" + _BODY + "\n" + _block("PRIVATE KEY", _BODY)
    )
    _expect(nested, "PRIVATE KEY", "InvalidBoundary", 37)
    assert_true("unexpected boundary inside the block" in _outcome(nested, "PRIVATE KEY"))
    var dashes = "-----BEGIN X-----\n" + _BODY + "\n-----\n-----END X-----\n"
    _expect(dashes, "X", "InvalidBoundary", 27)
    assert_true("unexpected boundary inside the block" in _outcome(dashes, "X"))
    # A malformed END.
    _expect(
        "-----BEGIN X-----\n" + _BODY + "\n-----END X----\n",
        "X",
        "InvalidBoundary",
        27,
    )


def test_body_errors() raises:
    # An empty body, and one of only whitespace.
    _expect(_block("X", ""), "X", "InvalidLength", 19)
    _expect(_block("X", " \t\r"), "X", "InvalidLength", 22)
    # A legacy RFC 1421 header line is not base64: the `-` of `Proc-Type`
    # (body offset 4, PEM offset 18 + 4) is the first byte outside it.
    _expect(
        _block("X", "Proc-Type: 4,ENCRYPTED\n" + _BODY),
        "X",
        "InvalidCharacter",
        22,
    )
    # A bad byte after whitespace: its position is in the PEM text, not in
    # the compacted body, where it is at 4 (`!` is at PEM offset 18 + 5).
    _expect(_block("X", "MA MC!QU="), "X", "InvalidCharacter", 23)
    # Missing padding: reported at the END line.
    _expect(_block("X", "MAMCAQU"), "X", "InvalidPadding", 26)
    # Non-canonical: the unused bits of `V` are not zero.
    _expect(_block("X", "MAMCAQV="), "X", "NonCanonical", 24)


def test_errors_carry_no_input_byte() raises:
    var secret = "c2VjcmV0LWtleS1ib2R5"  # base64 of "secret-key-body"
    var label = "SECRET LABEL"
    var msgs = List[String]()
    msgs.append(_outcome(_block("PRIVATE KEY", secret + "!"), "PRIVATE KEY"))
    msgs.append(_outcome(_block("PRIVATE KEY", secret + "="), "PRIVATE KEY"))
    msgs.append(_outcome("-----BEGIN PRIVATE KEY-----\n" + secret + "\n", "PRIVATE KEY"))
    msgs.append(_outcome(_block(label, secret), "PRIVATE KEY"))
    msgs.append(
        _outcome(
            "-----BEGIN " + label + "-----\n" + secret + "\n-----END X-----\n",
            label,
        )
    )
    msgs.append(_outcome(secret, "PRIVATE KEY"))
    for i in range(len(msgs)):
        assert_true(msgs[i] != String("OK"), msgs[i])
        assert_false("c2VjcmV0" in msgs[i], msgs[i])
        assert_false("secret" in msgs[i], msgs[i])
        assert_false("SECRET" in msgs[i], msgs[i])


# --- encode -----------------------------------------------------------------


def test_encode_known_answer() raises:
    var want = "-----BEGIN PRIVATE KEY-----\nMAMCAQU=\n-----END PRIVATE KEY-----\n"
    assert_equal(pem_encode("PRIVATE KEY", _der()), want)
    # The exported label constants are taken as they are, no conversion.
    assert_equal(pem_encode(PEM_LABEL_PRIVATE_KEY, _der()), want)
    _assert_bytes(pem_decode(want, PEM_LABEL_PRIVATE_KEY), _der())


def test_encode_wraps_at_64_and_round_trips() raises:
    assert_equal(PEM_LINE_SYMBOLS, 64)
    var lengths = List[Int]()
    lengths.append(1)
    lengths.append(47)
    lengths.append(48)  # exactly one full line
    lengths.append(49)
    lengths.append(96)  # exactly two
    lengths.append(100)
    lengths.append(1000)
    for li in range(len(lengths)):
        var n = lengths[li]
        var der = List[UInt8](capacity=n)
        for i in range(n):
            der.append(UInt8((i * 37 + 11) & 0xFF))
        var pem = pem_encode("CERTIFICATE", der)
        _assert_bytes(pem_decode(pem, "CERTIFICATE"), der)
        # Every body line is 64 symbols but the last, which is 1-64; the
        # lines joined are the base64 of the DER.
        var lines = pem.split("\n")
        assert_equal(String(lines[0]), "-----BEGIN CERTIFICATE-----")
        assert_equal(String(lines[len(lines) - 2]), "-----END CERTIFICATE-----")
        assert_equal(String(lines[len(lines) - 1]), "")
        var joined = String()
        for j in range(1, len(lines) - 2):
            var w = String(lines[j]).byte_length()
            if j < len(lines) - 3:
                assert_equal(w, 64)
            else:
                assert_true(w >= 1 and w <= 64)
            joined += String(lines[j])
        assert_equal(joined, base64_encode(der))


def test_encode_refusals() raises:
    var raised = 0
    try:
        _ = pem_encode("A--B", _der())
    except e:
        assert_equal(error_kind(e), "InvalidBoundary")
        raised += 1
    try:
        _ = pem_encode("X", List[UInt8]())
    except e:
        assert_equal(error_kind(e), "InvalidLength")
        raised += 1
    assert_equal(raised, 2)


def main() raises:
    test_decodes_a_block()
    test_crlf_indentation_split_body_and_surrounding_text()
    test_lax_body_whitespace()
    test_rfc7468_explanatory_text()
    test_rfc7468_labels()
    test_pem_label_names_the_first_block()
    test_no_armor()
    test_label_mismatch_is_not_skipped()
    test_malformed_boundaries()
    test_end_line_rules()
    test_body_errors()
    test_errors_carry_no_input_byte()
    test_encode_known_answer()
    test_encode_wraps_at_64_and_round_trips()
    test_encode_refusals()
    print("test_pem: OK")
