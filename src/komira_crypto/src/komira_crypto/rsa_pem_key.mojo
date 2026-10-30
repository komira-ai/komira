# =============================================================================
# komira_crypto/rsa_pem_key.mojo -- an RSA PEM private key -> the DER
# rsa_sha256_sign takes.
# =============================================================================
#
# `rsa_sha256_sign` takes a PKCS#8 PrivateKeyInfo (RFC 5208 section 5) as DER.
# Keys are usually handed around as PEM text (a service-account JSON file's
# `private_key`, a `.pem` file). `rsa_pkcs8_der_from_pem` turns the one into
# the other, for RSA keys only (the `rsa_` prefix says so; a loader for
# another algorithm is a function of its own):
#
#   1. The armor comes off through `komira_encoding.pem` (RFC 7468). Only the
#      first block is read, and it must be labelled `PRIVATE KEY`.
#   2. Two other private-key labels are refused BY NAME, because each has a
#      fix the caller can act on:
#        `RSA PRIVATE KEY`        PKCS#1 RSAPrivateKey, not PKCS#8. Convert it
#                                 (`openssl pkcs8 -topk8 -nocrypt`).
#        `ENCRYPTED PRIVATE KEY`  PKCS#8 EncryptedPrivateKeyInfo. Nothing here
#                                 decrypts a key; decrypt it first.
#      Any other label is komira_encoding's `LabelMismatch`.
#   3. The DER gets a STRUCTURAL check of the PrivateKeyInfo envelope, and no
#      more:
#
#        PrivateKeyInfo ::= SEQUENCE {          -- the whole input, no trailer
#          version              INTEGER,        -- must be 0 (v1)
#          privateKeyAlgorithm  SEQUENCE {
#            algorithm  OBJECT IDENTIFIER,      -- must be rsaEncryption
#            ... },                             --   (1.2.840.113549.1.1.1)
#          privateKey           OCTET STRING,   -- present; NOT opened
#          ... }
#
#      The OCTET STRING holds the RSAPrivateKey. It is not parsed here: AWS-LC
#      parses it inside `rsa_sha256_sign`, and a second RSA parser would be a
#      second place for the two to disagree. So a block that passes this check
#      can still be refused by the signer; what the check buys is that a
#      certificate, a public key, an EC key or an RFC 5958 v2 key is refused
#      HERE, by name, instead of as an opaque AWS-LC parse failure.
#
# ERRORS carry no byte of the input: the input is a private key. The armor
# errors are komira_encoding's (kind + position); the ones raised here start
# with `rsa_pkcs8_der_from_pem: ` and name the field that failed.
#
# RESIDUE. A DER the check refuses is wiped (`zeroize_list`) before the
# raise. The DER returned is the caller's key: wipe it with `zeroize_list`
# once it is no longer needed.
# =============================================================================

from komira_encoding import (
    PEM_LABEL_ENCRYPTED_PRIVATE_KEY,
    PEM_LABEL_PRIVATE_KEY,
    pem_decode,
    pem_label,
)

from komira_crypto.cert.asn1 import (
    ASN1_CLASS_UNIVERSAL,
    ASN1_TAG_INTEGER,
    ASN1_TAG_OCTET_STRING,
    ASN1_TAG_OID,
    ASN1_TAG_SEQUENCE,
    DerTlv,
    der_parse_tlv,
)
from komira_crypto.zeroize import zeroize_list


comptime _PEM_LABEL_RSA_PRIVATE_KEY: StaticString = "RSA PRIVATE KEY"
"""The OpenSSL-traditional label of a PKCS#1 RSAPrivateKey. It is not an
RFC 7468 label, so it lives here, where it is refused, and not with the
RFC 7468 labels of komira_encoding."""

comptime _FN: StaticString = "rsa_pkcs8_der_from_pem: "

comptime _RSA_ENCRYPTION_OID_LEN = 9
comptime _RSA_ENCRYPTION_OID: InlineArray[UInt8, _RSA_ENCRYPTION_OID_LEN] = [
    0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01
]
"""The content octets of the rsaEncryption OID, 1.2.840.113549.1.1.1
(RFC 8017 appendix C). Compared byte for byte: DER has one encoding of it."""


def _refuse(detail: StaticString) -> Error:
    return Error(String(_FN) + String(detail))


def _expect(
    der: Span[UInt8, _],
    pos: Int,
    tag: UInt32,
    constructed: Bool,
    what: StaticString,
) raises -> DerTlv:
    """The universal-class TLV at `pos`, refused as `what` unless it is
    well-formed, inside `der`, and carries tag `tag` with the given form."""
    var tlv: DerTlv
    try:
        tlv = der_parse_tlv(der, pos)
    except:
        raise _refuse(what)
    if (
        tlv.tag.class_ != ASN1_CLASS_UNIVERSAL
        or tlv.tag.tag_number != tag
        or tlv.tag.constructed != constructed
    ):
        raise _refuse(what)
    return tlv


def _check_private_key_info(der: Span[UInt8, _]) raises:
    """Refuse `der` unless it has the PrivateKeyInfo envelope in the header."""
    if len(der) == 0:
        raise _refuse("not a PKCS#8 PrivateKeyInfo: no DER")
    var outer = _expect(
        der,
        0,
        ASN1_TAG_SEQUENCE,
        True,
        "not a PKCS#8 PrivateKeyInfo: no outer SEQUENCE",
    )
    if outer.end_pos != len(der):
        raise _refuse(
            "not a PKCS#8 PrivateKeyInfo: bytes after the outer SEQUENCE"
        )

    var version = _expect(
        der,
        outer.value_pos,
        ASN1_TAG_INTEGER,
        False,
        "not a PKCS#8 PrivateKeyInfo: no version INTEGER",
    )
    if version.end_pos > outer.end_pos:
        raise _refuse("not a PKCS#8 PrivateKeyInfo: no version INTEGER")  # cov: unreachable outer.end_pos is len(der), checked above, and the TLV parse refuses anything past len(der)
    if version.value_len != 1 or der[version.value_pos] != UInt8(0):
        raise _refuse(
            "PrivateKeyInfo version is not 0 (v1); RFC 5958 v2 keys are not"
            " supported"
        )

    var algorithm = _expect(
        der,
        version.end_pos,
        ASN1_TAG_SEQUENCE,
        True,
        "not a PKCS#8 PrivateKeyInfo: no privateKeyAlgorithm SEQUENCE",
    )
    if algorithm.end_pos > outer.end_pos:
        raise _refuse(  # cov: unreachable algorithm.end_pos cannot pass outer.end_pos, for the reason at the version check
            "not a PKCS#8 PrivateKeyInfo: no privateKeyAlgorithm SEQUENCE"  # cov: unreachable see the line above
        )
    var oid = _expect(
        der,
        algorithm.value_pos,
        ASN1_TAG_OID,
        False,
        "not a PKCS#8 PrivateKeyInfo: no algorithm OBJECT IDENTIFIER",
    )
    if oid.end_pos > algorithm.end_pos:
        raise _refuse(
            "not a PKCS#8 PrivateKeyInfo: no algorithm OBJECT IDENTIFIER"
        )
    var same = oid.value_len == _RSA_ENCRYPTION_OID_LEN
    if same:
        comptime for i in range(_RSA_ENCRYPTION_OID_LEN):
            comptime want = _RSA_ENCRYPTION_OID[i]
            if der[oid.value_pos + i] != want:
                same = False
    if not same:
        raise _refuse(
            "the private key algorithm is not rsaEncryption"
            " (1.2.840.113549.1.1.1)"
        )

    var key = _expect(
        der,
        algorithm.end_pos,
        ASN1_TAG_OCTET_STRING,
        False,
        "not a PKCS#8 PrivateKeyInfo: no privateKey OCTET STRING",
    )
    if key.end_pos > outer.end_pos or key.value_len == 0:
        raise _refuse("not a PKCS#8 PrivateKeyInfo: no privateKey OCTET STRING")


def rsa_pkcs8_der_from_pem(pem: Span[UInt8, _]) raises -> List[UInt8]:
    """The PKCS#8 DER of the RSA private key in `pem`, in the form
    `rsa_sha256_sign` takes. The caller owns the key it returns and wipes it
    with `zeroize_list` when done.

    `pem` must open (after any explanatory text) with a `PRIVATE KEY` block
    holding an RSA PrivateKeyInfo; see the module header for what is checked
    and what is left to AWS-LC.

    Raises:
        `RSA PRIVATE KEY` (PKCS#1) and `ENCRYPTED PRIVATE KEY` blocks, by name;
        any other label or malformed armor (a komira_encoding error); and DER
        that is not an RSA PrivateKeyInfo v1, which is wiped first. No message
        contains input bytes.
    """
    var label = pem_label(pem)
    if label == String(_PEM_LABEL_RSA_PRIVATE_KEY):
        raise _refuse(
            "the PEM block is a PKCS#1 'RSA PRIVATE KEY'; convert it to an"
            " unencrypted PKCS#8 'PRIVATE KEY' (openssl pkcs8 -topk8 -nocrypt)"
        )
    if label == String(PEM_LABEL_ENCRYPTED_PRIVATE_KEY):
        raise _refuse(
            "the PEM block is an 'ENCRYPTED PRIVATE KEY'; encrypted keys are"
            " not supported, decrypt it to an unencrypted PKCS#8 'PRIVATE KEY'"
            " first"
        )
    var der = pem_decode(pem, PEM_LABEL_PRIVATE_KEY)
    try:
        _check_private_key_info(Span[UInt8, origin_of(der)](der))
    except e:
        zeroize_list(der)
        raise e^
    return der^


def rsa_pkcs8_der_from_pem(pem: String) raises -> List[UInt8]:
    """`rsa_pkcs8_der_from_pem` over the bytes of `pem`."""
    return rsa_pkcs8_der_from_pem(pem.as_bytes())
