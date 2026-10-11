# =============================================================================
# komira_crypto/tests/test_x509_malformed.mojo
#
# x509_parse_certificate over certificates assembled here field by field, so
# each test changes exactly one field of a well-formed certificate:
#   * accepted shapes the fixture certificates never carry: GeneralizedTime
#     in notBefore / notAfter, an IA5String attribute value, an
#     issuerUniqueID [1] before the extensions;
#   * every structural refusal, matched on its message (Validity, Time
#     CHOICE, DirectoryString, Name / RDN / ATV, AlgorithmIdentifier,
#     Extensions / Extension / extnValue, version, serialNumber, SPKI,
#     inner-vs-outer signature algorithm, signatureValue).
# The parser checks no signature, so the signature bytes are filler.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.x509 import x509_parse_certificate


# -----------------------------------------------------------------------------
# DER builder
# -----------------------------------------------------------------------------


def _b(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _cat(*parts: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(parts)):
        for j in range(len(parts[i])):
            out.append(parts[i][j])
    return out^


def _tlv(tag: Int, content: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(tag))
    var n = len(content)
    if n < 0x80:
        out.append(UInt8(n))
    elif n < 0x100:
        out.append(0x81)
        out.append(UInt8(n))
    else:
        out.append(0x82)
        out.append(UInt8(n >> 8))
        out.append(UInt8(n & 0xFF))
    for j in range(n):
        out.append(content[j])
    return out^


def _str(tag: Int, text: String) -> List[UInt8]:
    var v = List[UInt8]()
    for c in text.as_bytes():
        v.append(c)
    return _tlv(tag, v)


def _seq(content: List[UInt8]) -> List[UInt8]:
    return _tlv(0x30, content)


def _oid_cn() -> List[UInt8]:
    return _b(0x06, 0x03, 0x55, 0x04, 0x03)  # 2.5.4.3


def _alg_ecdsa_sha256() -> List[UInt8]:
    return _seq(_b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02))


def _alg_ecdsa_sha384() -> List[UInt8]:
    return _seq(_b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03))


def _name_with(value_tlv: List[UInt8]) -> List[UInt8]:
    return _seq(_tlv(0x31, _seq(_cat(_oid_cn(), value_tlv))))


def _name(cn: String) -> List[UInt8]:
    return _name_with(_str(0x0C, cn))


def _validity_of(nb: List[UInt8], na: List[UInt8]) -> List[UInt8]:
    return _seq(_cat(nb, na))


def _utc(text: String) -> List[UInt8]:
    return _str(0x17, text)


def _gen(text: String) -> List[UInt8]:
    return _str(0x18, text)


def _validity() -> List[UInt8]:
    return _validity_of(_utc("300101000000Z"), _utc("360101000000Z"))


def _spki() -> List[UInt8]:
    var point = List[UInt8]()
    point.append(0x00)  # unused bits
    point.append(0x04)
    for i in range(64):
        point.append(UInt8(i + 1))
    var alg = _seq(
        _cat(
            _b(0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01),
            _b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07),
        )
    )
    return _seq(_cat(alg, _tlv(0x03, point)))


def _version() -> List[UInt8]:
    return _tlv(0xA0, _b(0x02, 0x01, 0x02))


def _serial() -> List[UInt8]:
    return _b(0x02, 0x01, 0x07)


def _ext(oid: List[UInt8], value: List[UInt8]) -> List[UInt8]:
    return _seq(_cat(oid, _tlv(0x04, value)))


def _exts_of(content: List[UInt8]) -> List[UInt8]:
    return _tlv(0xA3, _seq(content))


def _exts() -> List[UInt8]:
    # basicConstraints (2.5.29.19), non-critical, cA absent.
    return _exts_of(_ext(_b(0x06, 0x03, 0x55, 0x1D, 0x13), _seq(List[UInt8]())))


def _sig() -> List[UInt8]:
    return _tlv(0x03, _b(0x00, 0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01))


def _tbs(
    version: List[UInt8],
    serial: List[UInt8],
    alg: List[UInt8],
    issuer: List[UInt8],
    validity: List[UInt8],
    subject: List[UInt8],
    spki: List[UInt8],
    tail: List[UInt8],
) -> List[UInt8]:
    return _seq(_cat(version, serial, alg, issuer, validity, subject, spki, tail))


def _cert(tbs: List[UInt8], outer_alg: List[UInt8], sig: List[UInt8]) -> List[UInt8]:
    return _seq(_cat(tbs, outer_alg, sig))


def _default_tbs_with_validity(validity: List[UInt8]) -> List[UInt8]:
    return _tbs(
        _version(), _serial(), _alg_ecdsa_sha256(), _name("issuer"),
        validity, _name("subject"), _spki(), _exts(),
    )


def _default_tbs_with_subject(subject: List[UInt8]) -> List[UInt8]:
    return _tbs(
        _version(), _serial(), _alg_ecdsa_sha256(), _name("issuer"),
        _validity(), subject, _spki(), _exts(),
    )


def _default_tbs_with_tail(tail: List[UInt8]) -> List[UInt8]:
    return _tbs(
        _version(), _serial(), _alg_ecdsa_sha256(), _name("issuer"),
        _validity(), _name("subject"), _spki(), tail,
    )


def _wrap(tbs: List[UInt8]) -> List[UInt8]:
    return _cert(tbs, _alg_ecdsa_sha256(), _sig())


def _err(der: List[UInt8]) -> String:
    try:
        _ = x509_parse_certificate(Span(der))
    except e:
        return String(e)
    return String("no error")


def _refused(der: List[UInt8], needle: String, what: String) raises:
    var e = _err(der)
    assert_true(e.find(needle) >= 0, what + ": got '" + e + "'")


# -----------------------------------------------------------------------------
# Accepted shapes
# -----------------------------------------------------------------------------


def test_the_builder_makes_a_parseable_certificate() raises:
    var der = _wrap(_default_tbs_with_validity(_validity()))
    var c = x509_parse_certificate(Span(der))
    assert_equal(Int(c.version), 2, "v3")
    assert_equal(len(c.extensions), 1, "one extension")
    assert_equal(c.subject[0].value, String("subject"), "subject CN")
    assert_equal(Int(c.not_before.year), 2030, "UTCTime notBefore")


def test_generalized_time_validity() raises:
    var der = _wrap(
        _default_tbs_with_validity(
            _validity_of(_gen("20500102030405Z"), _gen("20600708091011Z"))
        )
    )
    var c = x509_parse_certificate(Span(der))
    assert_equal(Int(c.not_before.year), 2050, "notBefore year")
    assert_equal(Int(c.not_before.month), 1, "notBefore month")
    assert_equal(Int(c.not_before.second), 5, "notBefore second")
    assert_equal(Int(c.not_after.year), 2060, "notAfter year")
    assert_equal(Int(c.not_after.day), 8, "notAfter day")
    assert_equal(Int(c.not_after.second), 11, "notAfter second")


def test_ia5_string_attribute_value() raises:
    var der = _wrap(_default_tbs_with_subject(_name_with(_str(0x16, "ia5.example"))))
    var c = x509_parse_certificate(Span(der))
    assert_equal(c.subject[0].value, String("ia5.example"), "IA5 value")


def test_unique_ids_are_skipped_before_extensions() raises:
    # issuerUniqueID [1] and subjectUniqueID [2], then the [3] extensions.
    var tail = _cat(
        _b(0x81, 0x02, 0x00, 0xAA), _b(0x82, 0x02, 0x00, 0xBB), _exts()
    )
    var der = _wrap(_default_tbs_with_tail(tail))
    var c = x509_parse_certificate(Span(der))
    assert_equal(len(c.extensions), 1, "extensions after the unique ids")


# -----------------------------------------------------------------------------
# Refusals
# -----------------------------------------------------------------------------


def test_validity_refusals() raises:
    _refused(
        _wrap(_default_tbs_with_validity(_tlv(0x31, _cat(_utc("300101000000Z"), _utc("360101000000Z"))))),
        "X.509 validity: not a SEQUENCE", "validity SET",
    )
    _refused(
        _wrap(_default_tbs_with_validity(_validity_of(_str(0x04, "300101000000Z"), _utc("360101000000Z")))),
        "notBefore not a Time CHOICE", "notBefore OCTET STRING",
    )
    _refused(
        _wrap(_default_tbs_with_validity(_validity_of(_utc("300101000000Z"), _str(0x13, "360101000000Z")))),
        "notAfter not a Time CHOICE", "notAfter PrintableString",
    )


def test_directory_string_refusals() raises:
    _refused(
        _wrap(_default_tbs_with_subject(_name_with(_str(0x80, "x")))),
        "DirectoryString: non-universal class", "context-class value",
    )
    _refused(
        _wrap(_default_tbs_with_subject(_name_with(_str(0x04, "x")))),
        "DirectoryString: unsupported string type", "OCTET STRING value (not a DirectoryString type)",
    )


def test_name_refusals() raises:
    _refused(
        _wrap(_default_tbs_with_subject(_tlv(0x31, _tlv(0x31, _seq(_cat(_oid_cn(), _str(0x0C, "x"))))))),
        "Name: not a SEQUENCE", "Name as SET",
    )
    _refused(
        _wrap(_default_tbs_with_subject(_seq(_seq(_seq(_cat(_oid_cn(), _str(0x0C, "x"))))))),
        "Name: child not a SET", "RDN as SEQUENCE",
    )
    _refused(
        _wrap(_default_tbs_with_subject(_seq(_tlv(0x31, _tlv(0x31, _cat(_oid_cn(), _str(0x0C, "x"))))))),
        "Name: ATV not a SEQUENCE", "ATV as SET",
    )
    _refused(
        _wrap(_default_tbs_with_subject(_seq(_tlv(0x31, _seq(_cat(_str(0x0C, "x"), _str(0x0C, "x"))))))),
        "Name: ATV first member not an OID", "ATV without OID",
    )


def test_algorithm_identifier_refusals() raises:
    var not_seq = _tlv(0x31, _b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02))
    _refused(
        _wrap(_tbs(_version(), _serial(), not_seq, _name("i"), _validity(), _name("s"), _spki(), _exts())),
        "AlgorithmIdentifier: not a SEQUENCE", "algorithm as SET",
    )
    var no_oid = _seq(_b(0x05, 0x00))
    _refused(
        _wrap(_tbs(_version(), _serial(), no_oid, _name("i"), _validity(), _name("s"), _spki(), _exts())),
        "AlgorithmIdentifier: first member not an OID", "algorithm NULL first",
    )


def test_extension_refusals() raises:
    var bc_oid = _b(0x06, 0x03, 0x55, 0x1D, 0x13)
    _refused(
        _wrap(_default_tbs_with_tail(_tlv(0xA3, _tlv(0x31, _ext(bc_oid, _seq(List[UInt8]())))))),
        "Extensions: not a SEQUENCE", "extensions as SET",
    )
    _refused(
        _wrap(_default_tbs_with_tail(_exts_of(_tlv(0x31, _cat(bc_oid, _tlv(0x04, _seq(List[UInt8]()))))))),
        "Extension: not a SEQUENCE", "extension as SET",
    )
    _refused(
        _wrap(_default_tbs_with_tail(_exts_of(_seq(_cat(_b(0x05, 0x00), _tlv(0x04, _seq(List[UInt8]()))))))),
        "Extension: first member not an OID", "extension without OID",
    )
    _refused(
        _wrap(_default_tbs_with_tail(_exts_of(_seq(_cat(bc_oid, _b(0x01, 0x01, 0xFF), _tlv(0x03, _b(0x00))))))),
        "Extension: extnValue not an OCTET STRING", "critical, then BIT STRING value",
    )


def test_version_and_serial_refusals() raises:
    _refused(
        _wrap(_tbs(_tlv(0xA0, _b(0x04, 0x01, 0x02)), _serial(), _alg_ecdsa_sha256(), _name("i"), _validity(), _name("s"), _spki(), _exts())),
        "Certificate: version inner not INTEGER", "version OCTET STRING",
    )
    _refused(
        _wrap(_tbs(_version(), _b(0x04, 0x01, 0x07), _alg_ecdsa_sha256(), _name("i"), _validity(), _name("s"), _spki(), _exts())),
        "Certificate: serialNumber not INTEGER", "serial OCTET STRING",
    )


def test_spki_refusals() raises:
    var alg = _seq(
        _cat(
            _b(0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01),
            _b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07),
        )
    )
    var key = _tlv(0x03, _b(0x00, 0x04, 0x01))
    _refused(
        _wrap(_tbs(_version(), _serial(), _alg_ecdsa_sha256(), _name("i"), _validity(), _name("s"), _tlv(0x31, _cat(alg, key)), _exts())),
        "Certificate: SPKI not a SEQUENCE", "SPKI as SET",
    )
    _refused(
        _wrap(_tbs(_version(), _serial(), _alg_ecdsa_sha256(), _name("i"), _validity(), _name("s"), _seq(_cat(alg, _tlv(0x04, _b(0x04, 0x01)))), _exts())),
        "Certificate: SPKI subjectPublicKey not BIT STRING", "key OCTET STRING",
    )


def test_outer_signature_refusals() raises:
    var tbs = _default_tbs_with_validity(_validity())
    _refused(
        _cert(tbs, _alg_ecdsa_sha384(), _sig()),
        "inner signature algorithm OID != outer", "outer ecdsa-with-SHA384",
    )
    _refused(
        _cert(tbs, _alg_ecdsa_sha256(), _tlv(0x04, _b(0x30, 0x00))),
        "Certificate: signatureValue not BIT STRING", "signature OCTET STRING",
    )


def main() raises:
    test_the_builder_makes_a_parseable_certificate()
    test_generalized_time_validity()
    test_ia5_string_attribute_value()
    test_unique_ids_are_skipped_before_extensions()
    test_validity_refusals()
    test_directory_string_refusals()
    test_name_refusals()
    test_algorithm_identifier_refusals()
    test_extension_refusals()
    test_version_and_serial_refusals()
    test_spki_refusals()
    test_outer_signature_refusals()
    print("test_x509_malformed: 12 tests PASS")
