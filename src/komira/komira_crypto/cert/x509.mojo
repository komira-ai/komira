# =============================================================================
# komira_crypto/cert/x509.mojo — X.509 v3 Certificate parser (RFC 5280)
# =============================================================================
#
# Implements parsing of an X.509 v3 cert DER-encoded per RFC 5280 §4.1 +
# RFC 6818 errata. Consumes the ASN.1 DER substrate at `asn1.mojo`.
#
# # ASN.1 type (RFC 5280 §4.1)
#
#     Certificate ::= SEQUENCE {
#         tbsCertificate       TBSCertificate,
#         signatureAlgorithm   AlgorithmIdentifier,
#         signatureValue       BIT STRING
#     }
#
#     TBSCertificate ::= SEQUENCE {
#         version         [0]  EXPLICIT Version DEFAULT v1,
#         serialNumber         CertificateSerialNumber,
#         signature            AlgorithmIdentifier,
#         issuer               Name,
#         validity             Validity,
#         subject              Name,
#         subjectPublicKeyInfo SubjectPublicKeyInfo,
#         issuerUniqueID  [1]  IMPLICIT UniqueIdentifier OPTIONAL,
#         subjectUniqueID [2]  IMPLICIT UniqueIdentifier OPTIONAL,
#         extensions      [3]  EXPLICIT Extensions OPTIONAL
#     }
#
# # Public surface (no UnsafePointer, no wildcards)
#
#   * `X509Certificate` — POD struct holding all parsed fields.
#   * `Extension` — single parsed extension (oid, critical, value bytes).
#   * `DnAttribute` — single parsed Distinguished Name component
#     (OID + string value).
#   * `x509_parse_certificate(der: Span[UInt8, _]) raises -> X509Certificate`
#   * `x509_find_extension(cert, oid) -> Optional[Extension]` (helper).
#
# # Out of scope
#
# Signature verification + chain walking live in `chain.mojo`. This module
# just extracts the typed fields (incl. the TBSCertificate raw bytes needed
# for the signature check) + the common extensions.
# =============================================================================

from komira_crypto.cert.asn1 import (
    ASN1_CLASS_UNIVERSAL,
    ASN1_CLASS_CONTEXT,
    ASN1_TAG_BOOLEAN,
    ASN1_TAG_INTEGER,
    ASN1_TAG_BIT_STRING,
    ASN1_TAG_OCTET_STRING,
    ASN1_TAG_NULL,
    ASN1_TAG_OID,
    ASN1_TAG_UTF8_STRING,
    ASN1_TAG_SEQUENCE,
    ASN1_TAG_SET,
    ASN1_TAG_PRINTABLE_STRING,
    ASN1_TAG_IA5_STRING,
    ASN1_TAG_UTC_TIME,
    ASN1_TAG_GENERALIZED_TIME,
    DerTag,
    DerTlv,
    DerTime,
    der_parse_tlv,
    der_parse_boolean,
    der_parse_integer_to_int64,
    der_parse_integer_to_bytes,
    der_parse_octet_string,
    der_parse_bit_string,
    der_parse_utf8_string,
    der_parse_printable_string,
    der_parse_ia5_string,
    der_parse_oid,
    der_parse_utc_time,
    der_parse_generalized_time,
    der_oid_eq,
    der_expect_tag,
)


# -----------------------------------------------------------------------------
# POD types
# -----------------------------------------------------------------------------


struct Extension(Copyable, Movable, Deinitable):
    """A single X.509 extension (RFC 5280 §4.2).

    Extension ::= SEQUENCE {
        extnID    OBJECT IDENTIFIER,
        critical  BOOLEAN DEFAULT FALSE,
        extnValue OCTET STRING
    }

    `value` holds the raw extnValue bytes (the inner content; for parsed
    interpretation see the per-extension helpers below).
    """
    var oid: List[UInt32]
    var critical: Bool
    var value: List[UInt8]

    def __init__(out self, var oid: List[UInt32], critical: Bool, var value: List[UInt8]):
        self.oid = oid^
        self.critical = critical
        self.value = value^


struct DnAttribute(Copyable, Movable, Deinitable):
    """A single Distinguished Name relative-distinguished-name attribute.

    AttributeTypeAndValue ::= SEQUENCE {
        type   AttributeType,    -- OID
        value  AttributeValue    -- ANY (UTF8String / PrintableString / etc.)
    }

    For X.509 DNs (subject / issuer), the typical OIDs are:
      2.5.4.3   commonName       (CN)
      2.5.4.6   countryName      (C)
      2.5.4.7   localityName     (L)
      2.5.4.8   stateOrProvince  (ST)
      2.5.4.10  organizationName (O)
      2.5.4.11  organizationalUnitName (OU)
    """
    var oid: List[UInt32]
    var value: String

    def __init__(out self, var oid: List[UInt32], var value: String):
        self.oid = oid^
        self.value = value^


struct X509Certificate(Copyable, Movable, Deinitable):
    """Parsed X.509 v3 Certificate.

    Field-by-field mapping to RFC 5280 §4.1:
      version              -> tbsCertificate.version (default 0=v1, 2=v3)
      serial_number        -> tbsCertificate.serialNumber (raw bytes,
                              big-endian, sign-pad stripped if positive)
      signature_algo_oid   -> tbsCertificate.signature.algorithm OID
                              (the inner one; the outer Certificate.
                              signatureAlgorithm MUST match per §4.1.1.2)
      issuer / subject     -> Sequences of DnAttribute
      not_before/not_after -> Validity period as DerTime
      subject_pubkey_algo_oid -> SubjectPublicKeyInfo.algorithm OID
      subject_pubkey       -> Raw bit-string bytes (caller decodes based
                              on algo OID — e.g. for RSA: another SEQUENCE
                              of (modulus, exponent))
      extensions           -> List of parsed Extensions (v3 only)
      signature_value      -> The outer signatureValue BIT STRING bytes
      tbs_raw              -> Raw TBSCertificate bytes (for signature
                              verification in chain.mojo)
    """
    var version: UInt8
    var serial_number: List[UInt8]
    var signature_algo_oid: List[UInt32]
    var issuer: List[DnAttribute]
    var not_before: DerTime
    var not_after: DerTime
    var subject: List[DnAttribute]
    var subject_pubkey_algo_oid: List[UInt32]
    var subject_pubkey: List[UInt8]
    var extensions: List[Extension]
    var signature_value: List[UInt8]
    var tbs_raw: List[UInt8]

    def __init__(
        out self,
        version: UInt8,
        var serial_number: List[UInt8],
        var signature_algo_oid: List[UInt32],
        var issuer: List[DnAttribute],
        not_before: DerTime,
        not_after: DerTime,
        var subject: List[DnAttribute],
        var subject_pubkey_algo_oid: List[UInt32],
        var subject_pubkey: List[UInt8],
        var extensions: List[Extension],
        var signature_value: List[UInt8],
        var tbs_raw: List[UInt8],
    ):
        self.version = version
        self.serial_number = serial_number^
        self.signature_algo_oid = signature_algo_oid^
        self.issuer = issuer^
        self.not_before = not_before
        self.not_after = not_after
        self.subject = subject^
        self.subject_pubkey_algo_oid = subject_pubkey_algo_oid^
        self.subject_pubkey = subject_pubkey^
        self.extensions = extensions^
        self.signature_value = signature_value^
        self.tbs_raw = tbs_raw^


# -----------------------------------------------------------------------------
# Internal parsers
# -----------------------------------------------------------------------------


def _parse_validity(buf: Span[UInt8, _], tlv: DerTlv) raises -> Tuple[DerTime, DerTime]:
    """Parse Validity ::= SEQUENCE { notBefore Time, notAfter Time }.

    Time ::= CHOICE { utcTime UTCTime, generalTime GeneralizedTime }.
    Per RFC 5280 §4.1.2.5, dates before 2050 use UTCTime; 2050+ use
    GeneralizedTime.
    """
    if not (tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and tlv.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("X.509 validity: not a SEQUENCE")
    var pos = tlv.value_pos
    var nb_tlv = der_parse_tlv(buf, pos)
    var nb: DerTime
    if nb_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and nb_tlv.tag.tag_number == ASN1_TAG_UTC_TIME:
        nb = der_parse_utc_time(buf[nb_tlv.value_pos : nb_tlv.value_pos + nb_tlv.value_len])
    elif nb_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and nb_tlv.tag.tag_number == ASN1_TAG_GENERALIZED_TIME:
        nb = der_parse_generalized_time(buf[nb_tlv.value_pos : nb_tlv.value_pos + nb_tlv.value_len])
    else:
        raise Error("X.509 validity: notBefore not a Time CHOICE")
    pos = nb_tlv.end_pos
    var na_tlv = der_parse_tlv(buf, pos)
    var na: DerTime
    if na_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and na_tlv.tag.tag_number == ASN1_TAG_UTC_TIME:
        na = der_parse_utc_time(buf[na_tlv.value_pos : na_tlv.value_pos + na_tlv.value_len])
    elif na_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and na_tlv.tag.tag_number == ASN1_TAG_GENERALIZED_TIME:
        na = der_parse_generalized_time(buf[na_tlv.value_pos : na_tlv.value_pos + na_tlv.value_len])
    else:
        raise Error("X.509 validity: notAfter not a Time CHOICE")
    return (nb, na)


def _parse_directory_string(buf: Span[UInt8, _], tlv: DerTlv) raises -> String:
    """Parse a DirectoryString CHOICE — accept UTF8String, PrintableString,
    or IA5String."""
    var v = buf[tlv.value_pos : tlv.value_pos + tlv.value_len]
    if tlv.tag.class_ != ASN1_CLASS_UNIVERSAL:
        raise Error("DirectoryString: non-universal class")
    if tlv.tag.tag_number == ASN1_TAG_UTF8_STRING:
        return der_parse_utf8_string(v)
    if tlv.tag.tag_number == ASN1_TAG_PRINTABLE_STRING:
        return der_parse_printable_string(v)
    if tlv.tag.tag_number == ASN1_TAG_IA5_STRING:
        return der_parse_ia5_string(v)
    raise Error("DirectoryString: unsupported string type")


def _parse_name(buf: Span[UInt8, _], tlv: DerTlv) raises -> List[DnAttribute]:
    """Parse Name ::= CHOICE { rdnSequence RDNSequence }
       RDNSequence ::= SEQUENCE OF RelativeDistinguishedName
       RelativeDistinguishedName ::= SET SIZE (1..MAX) OF AttributeTypeAndValue
       AttributeTypeAndValue ::= SEQUENCE { type AttributeType, value ANY }
    """
    if not (tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and tlv.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("Name: not a SEQUENCE")
    var out = List[DnAttribute]()
    var pos = tlv.value_pos
    while pos < tlv.end_pos:
        # Each child is a SET (RelativeDistinguishedName).
        var rdn = der_parse_tlv(buf, pos)
        if not (rdn.tag.class_ == ASN1_CLASS_UNIVERSAL and rdn.tag.tag_number == ASN1_TAG_SET):
            raise Error("Name: child not a SET")
        # The SET contains one (or more, but we just take all) ATV SEQUENCEs.
        var rpos = rdn.value_pos
        while rpos < rdn.end_pos:
            var atv = der_parse_tlv(buf, rpos)
            if not (atv.tag.class_ == ASN1_CLASS_UNIVERSAL and atv.tag.tag_number == ASN1_TAG_SEQUENCE):
                raise Error("Name: ATV not a SEQUENCE")
            # Inside: OID + value.
            var inner_pos = atv.value_pos
            var oid_tlv = der_parse_tlv(buf, inner_pos)
            if not (oid_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and oid_tlv.tag.tag_number == ASN1_TAG_OID):
                raise Error("Name: ATV first member not an OID")
            var oid = der_parse_oid(buf[oid_tlv.value_pos : oid_tlv.value_pos + oid_tlv.value_len])
            var val_tlv = der_parse_tlv(buf, oid_tlv.end_pos)
            var val_str = _parse_directory_string(buf, val_tlv)
            out.append(DnAttribute(oid^, val_str^))
            rpos = atv.end_pos
        pos = rdn.end_pos
    return out^


def _parse_algorithm_identifier(buf: Span[UInt8, _], tlv: DerTlv) raises -> List[UInt32]:
    """Parse AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters ANY OPTIONAL }.

    We return just the OID. The parameters (e.g. RSA-PSS PSS parameters,
    ECDSA curve OID) are ignored at this layer; `chain.mojo` parses
    them for cert-chain verification.
    """
    if not (tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and tlv.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("AlgorithmIdentifier: not a SEQUENCE")
    var oid_tlv = der_parse_tlv(buf, tlv.value_pos)
    if not (oid_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and oid_tlv.tag.tag_number == ASN1_TAG_OID):
        raise Error("AlgorithmIdentifier: first member not an OID")
    return der_parse_oid(buf[oid_tlv.value_pos : oid_tlv.value_pos + oid_tlv.value_len])


def _parse_extensions(buf: Span[UInt8, _], tlv: DerTlv) raises -> List[Extension]:
    """Parse `extensions [3] EXPLICIT Extensions` per RFC 5280 §4.2.

    `tlv` is the inner SEQUENCE OF Extension (caller has already unwrapped
    the [3] EXPLICIT context-class wrapper).
    """
    if not (tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and tlv.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("Extensions: not a SEQUENCE")
    var out = List[Extension]()
    var pos = tlv.value_pos
    while pos < tlv.end_pos:
        var ext_tlv = der_parse_tlv(buf, pos)
        if not (ext_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and ext_tlv.tag.tag_number == ASN1_TAG_SEQUENCE):
            raise Error("Extension: not a SEQUENCE")
        var inner_pos = ext_tlv.value_pos
        # extnID OID
        var oid_tlv = der_parse_tlv(buf, inner_pos)
        if not (oid_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and oid_tlv.tag.tag_number == ASN1_TAG_OID):
            raise Error("Extension: first member not an OID")
        var oid = der_parse_oid(buf[oid_tlv.value_pos : oid_tlv.value_pos + oid_tlv.value_len])
        var next_pos = oid_tlv.end_pos
        # critical BOOLEAN DEFAULT FALSE (optional)
        var critical = False
        var next_tlv = der_parse_tlv(buf, next_pos)
        if next_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and next_tlv.tag.tag_number == ASN1_TAG_BOOLEAN:
            critical = der_parse_boolean(buf[next_tlv.value_pos : next_tlv.value_pos + next_tlv.value_len])
            next_pos = next_tlv.end_pos
            next_tlv = der_parse_tlv(buf, next_pos)
        # extnValue OCTET STRING (wraps the actual extension content)
        if not (next_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and next_tlv.tag.tag_number == ASN1_TAG_OCTET_STRING):
            raise Error("Extension: extnValue not an OCTET STRING")
        var ext_value = der_parse_octet_string(buf[next_tlv.value_pos : next_tlv.value_pos + next_tlv.value_len])
        out.append(Extension(oid^, critical, ext_value^))
        pos = ext_tlv.end_pos
    return out^


# -----------------------------------------------------------------------------
# Public parser
# -----------------------------------------------------------------------------


def x509_parse_certificate(der: Span[UInt8, _]) raises -> X509Certificate:
    """Parse an X.509 v3 Certificate DER-encoded per RFC 5280 §4.1.

    Returns an X509Certificate with all fields populated. Raises on any
    structural malformation; the inner `tbs_raw` field holds the bytes
    that `chain.mojo` feeds to the signature-verify primitive.
    """
    # Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    var top = der_parse_tlv(der, 0)
    if not (top.tag.class_ == ASN1_CLASS_UNIVERSAL and top.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("Certificate: top is not a SEQUENCE")

    # tbsCertificate
    var tbs_start = top.value_pos
    var tbs_tlv = der_parse_tlv(der, tbs_start)
    if not (tbs_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and tbs_tlv.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("TBSCertificate: not a SEQUENCE")
    # Capture the full TBSCertificate raw bytes (tag + length + value), used
    # by `chain.mojo` for the signature verification — the signature is computed
    # over the DER-encoded TBSCertificate INCLUDING its outer tag+length.
    var tbs_raw = List[UInt8]()
    for i in range(tbs_start, tbs_tlv.end_pos):
        tbs_raw.append(der[i])

    var pos = tbs_tlv.value_pos

    # version [0] EXPLICIT Version DEFAULT v1
    var version = UInt8(0)  # v1 default
    var maybe_ver = der_parse_tlv(der, pos)
    if maybe_ver.tag.class_ == ASN1_CLASS_CONTEXT and maybe_ver.tag.tag_number == UInt32(0):
        # Unwrap EXPLICIT: inner INTEGER.
        var ver_inner = der_parse_tlv(der, maybe_ver.value_pos)
        if not (ver_inner.tag.class_ == ASN1_CLASS_UNIVERSAL and ver_inner.tag.tag_number == ASN1_TAG_INTEGER):
            raise Error("Certificate: version inner not INTEGER")
        var ver_int = der_parse_integer_to_int64(der[ver_inner.value_pos : ver_inner.value_pos + ver_inner.value_len])
        if ver_int < Int64(0) or ver_int > Int64(2):
            raise Error("Certificate: version out of range [0,2]")
        version = UInt8(Int(ver_int))
        pos = maybe_ver.end_pos

    # serialNumber INTEGER
    var serial_tlv = der_parse_tlv(der, pos)
    if not (serial_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and serial_tlv.tag.tag_number == ASN1_TAG_INTEGER):
        raise Error("Certificate: serialNumber not INTEGER")
    var serial_number = der_parse_integer_to_bytes(der[serial_tlv.value_pos : serial_tlv.value_pos + serial_tlv.value_len])
    pos = serial_tlv.end_pos

    # signature AlgorithmIdentifier (inner)
    var sig_algo_tlv = der_parse_tlv(der, pos)
    var sig_algo_oid = _parse_algorithm_identifier(der, sig_algo_tlv)
    pos = sig_algo_tlv.end_pos

    # issuer Name
    var issuer_tlv = der_parse_tlv(der, pos)
    var issuer = _parse_name(der, issuer_tlv)
    pos = issuer_tlv.end_pos

    # validity Validity
    var validity_tlv = der_parse_tlv(der, pos)
    var validity_pair = _parse_validity(der, validity_tlv)
    var not_before = validity_pair[0]
    var not_after = validity_pair[1]
    pos = validity_tlv.end_pos

    # subject Name
    var subject_tlv = der_parse_tlv(der, pos)
    var subject = _parse_name(der, subject_tlv)
    pos = subject_tlv.end_pos

    # subjectPublicKeyInfo SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
    var spki_tlv = der_parse_tlv(der, pos)
    if not (spki_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and spki_tlv.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("Certificate: SPKI not a SEQUENCE")
    var spki_inner_pos = spki_tlv.value_pos
    var spki_algo_tlv = der_parse_tlv(der, spki_inner_pos)
    var spki_algo_oid = _parse_algorithm_identifier(der, spki_algo_tlv)
    var spki_key_tlv = der_parse_tlv(der, spki_algo_tlv.end_pos)
    if not (spki_key_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and spki_key_tlv.tag.tag_number == ASN1_TAG_BIT_STRING):
        raise Error("Certificate: SPKI subjectPublicKey not BIT STRING")
    var spki_key_res = der_parse_bit_string(der[spki_key_tlv.value_pos : spki_key_tlv.value_pos + spki_key_tlv.value_len])
    # NOTE: `spki_key_res.bytes^` partial-move is REJECTED by Mojo 1.0.0b1
    # ("field destroyed out of the middle of a value, preventing the
    # overall value from being destroyed"). Use `.copy()` to extract.
    var subject_pubkey = spki_key_res.bytes.copy()
    pos = spki_tlv.end_pos

    # Skip [1] issuerUniqueID / [2] subjectUniqueID if present (v2/v3).
    while pos < tbs_tlv.end_pos:
        var next_tlv = der_parse_tlv(der, pos)
        if next_tlv.tag.class_ == ASN1_CLASS_CONTEXT and (next_tlv.tag.tag_number == UInt32(1) or next_tlv.tag.tag_number == UInt32(2)):
            pos = next_tlv.end_pos
        else:
            break

    # extensions [3] EXPLICIT Extensions OPTIONAL (v3 only)
    var extensions = List[Extension]()
    if pos < tbs_tlv.end_pos:
        var ext_wrapper = der_parse_tlv(der, pos)
        if ext_wrapper.tag.class_ == ASN1_CLASS_CONTEXT and ext_wrapper.tag.tag_number == UInt32(3):
            # Inner SEQUENCE
            var ext_inner = der_parse_tlv(der, ext_wrapper.value_pos)
            extensions = _parse_extensions(der, ext_inner)

    # Back at top-level: signatureAlgorithm (outer; should match sig_algo_oid)
    var outer_sig_algo_tlv = der_parse_tlv(der, tbs_tlv.end_pos)
    var outer_sig_algo_oid = _parse_algorithm_identifier(der, outer_sig_algo_tlv)
    if not der_oid_eq(sig_algo_oid, outer_sig_algo_oid):
        raise Error("Certificate: inner signature algorithm OID != outer (RFC 5280 §4.1.1.2)")

    # signatureValue BIT STRING
    var sig_val_tlv = der_parse_tlv(der, outer_sig_algo_tlv.end_pos)
    if not (sig_val_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and sig_val_tlv.tag.tag_number == ASN1_TAG_BIT_STRING):
        raise Error("Certificate: signatureValue not BIT STRING")
    var sig_val_res = der_parse_bit_string(der[sig_val_tlv.value_pos : sig_val_tlv.value_pos + sig_val_tlv.value_len])
    var signature_value = sig_val_res.bytes.copy()

    return X509Certificate(
        version,
        serial_number^,
        sig_algo_oid^,
        issuer^,
        not_before,
        not_after,
        subject^,
        spki_algo_oid^,
        subject_pubkey^,
        extensions^,
        signature_value^,
        tbs_raw^,
    )


# -----------------------------------------------------------------------------
# Extension lookup helper
# -----------------------------------------------------------------------------


def x509_find_extension(
    cert: X509Certificate, oid: List[UInt32]
) -> Int:
    """Return the index into `cert.extensions` of the first extension whose
    OID matches `oid`, or -1 if not found.

    The caller indexes back into `cert.extensions[i]` to inspect the
    `critical` flag + raw `value` bytes. Per-extension value decoders
    live in `chain.mojo` (e.g. parse SAN dNSNames, parse Basic Constraints
    CA bit + pathLen).
    """
    for i in range(len(cert.extensions)):
        if der_oid_eq(cert.extensions[i].oid, oid):
            return i
    return -1
