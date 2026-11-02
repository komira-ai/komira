# =============================================================================
# komira_crypto/cert/chain.mojo — X.509 Certification Path Validation
# =============================================================================
#
# Implements RFC 5280 §6 path validation for X.509 cert chains over the
# X509Certificate POD, dispatching signatures to ecdsa_p256_verify /
# ecdsa_p384_verify / rsa_pss_verify / ed25519_verify.
#
# # Public surface
#
#   * `chain_verify(chain, trust_anchors, now) raises -> Bool`
#     - chain: List[X509Certificate] (leaf first, terminal cert last)
#     - trust_anchors: List[X509Certificate] (set of trusted roots)
#     - now: (UInt16, UInt8, UInt8, UInt8, UInt8, UInt8) — current UTC
#
#   * Helper enum/error strings carry the rejection reason.
#
# # Algorithm (RFC 5280 §6.1.3)
#
#   For each adjacent (cert[i], cert[i+1]):
#     1. Issuer name match: cert[i].issuer == cert[i+1].subject (byte-equal).
#     2. Signature verify: hash(cert[i].tbs_raw) and verify with
#        cert[i+1].subject_pubkey using algo from cert[i].signature_algo_oid.
#     3. Validity period of cert[i]: not_before <= now <= not_after.
#     4. basicConstraints of cert[i+1] (issuer): cA = TRUE.
#     5. Key Usage of cert[i+1]: keyCertSign if present.
#
#   For chain[0] (leaf):
#     - Key Usage: digitalSignature and/or keyAgreement (if KU present).
#     - Extended Key Usage: serverAuth (if EKU present).
#
#   Terminal:
#     - chain[last] either IS a trust_anchor (subject byte-equal) OR
#       trust_anchors contains a cert whose subject == chain[last].issuer
#       and that signs chain[last] correctly.
# # Algorithm OID dispatch
#
#   ecdsa-with-SHA256       (1.2.840.10045.4.3.2)        → ecdsa_p256_verify
#   ecdsa-with-SHA384       (1.2.840.10045.4.3.3)        → ecdsa_p384_verify
#   rsassaPss               (1.2.840.113549.1.1.10)      → rsa_pss_verify[32, Sha256]
#   sha256WithRSAEncryption (1.2.840.113549.1.1.11)      → not supported (PKCS#1 v1.5)
#   Ed25519                 (1.3.101.112)                → ed25519_verify
#
# Unsupported algos raise with a clear error message.
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in public signatures (Span[UInt8, _] only).
#   * ZERO wildcards / unsafe_from_address / take_pointee.
#   * ZERO new ArcPointer (all POD chains).
# =============================================================================

from komira_crypto.cert.x509 import (
    X509Certificate,
    Extension,
    DnAttribute,
    x509_find_extension,
)
from komira_crypto.cert.asn1 import (
    ASN1_CLASS_UNIVERSAL,
    ASN1_TAG_BOOLEAN,
    ASN1_TAG_INTEGER,
    ASN1_TAG_BIT_STRING,
    ASN1_TAG_OCTET_STRING,
    ASN1_TAG_OID,
    ASN1_TAG_SEQUENCE,
    DerTime,
    DerTlv,
    der_parse_tlv,
    der_parse_boolean,
    der_parse_integer_to_bytes,
    der_parse_bit_string,
    der_parse_oid,
    der_oid_eq,
)
from komira_crypto.ecdsa_p256 import ecdsa_p256_verify
from komira_crypto.ecdsa_p384 import ecdsa_p384_verify
from komira_crypto.ed25519 import ed25519_verify
from komira_crypto.rsa_pss import (
    RsaPublicKey,
    rsa_public_key_from_bytes,
    rsa_pss_verify,
)
from komira_crypto.hash import Sha256


# -----------------------------------------------------------------------------
# OID constants
# -----------------------------------------------------------------------------


def _oid_ecdsa_sha256() -> List[UInt32]:
    # 1.2.840.10045.4.3.2
    var o = List[UInt32]()
    o.append(UInt32(1)); o.append(UInt32(2)); o.append(UInt32(840))
    o.append(UInt32(10045)); o.append(UInt32(4)); o.append(UInt32(3))
    o.append(UInt32(2))
    return o^


def _oid_ecdsa_sha384() -> List[UInt32]:
    # 1.2.840.10045.4.3.3
    var o = List[UInt32]()
    o.append(UInt32(1)); o.append(UInt32(2)); o.append(UInt32(840))
    o.append(UInt32(10045)); o.append(UInt32(4)); o.append(UInt32(3))
    o.append(UInt32(3))
    return o^


def _oid_rsa_pss() -> List[UInt32]:
    # 1.2.840.113549.1.1.10
    var o = List[UInt32]()
    o.append(UInt32(1)); o.append(UInt32(2)); o.append(UInt32(840))
    o.append(UInt32(113549)); o.append(UInt32(1)); o.append(UInt32(1))
    o.append(UInt32(10))
    return o^


def _oid_rsa_sha256_pkcs1v15() -> List[UInt32]:
    # 1.2.840.113549.1.1.11
    var o = List[UInt32]()
    o.append(UInt32(1)); o.append(UInt32(2)); o.append(UInt32(840))
    o.append(UInt32(113549)); o.append(UInt32(1)); o.append(UInt32(1))
    o.append(UInt32(11))
    return o^


def _oid_ed25519() -> List[UInt32]:
    # 1.3.101.112
    var o = List[UInt32]()
    o.append(UInt32(1)); o.append(UInt32(3)); o.append(UInt32(101))
    o.append(UInt32(112))
    return o^


def _oid_ec_public_key() -> List[UInt32]:
    # 1.2.840.10045.2.1
    var o = List[UInt32]()
    o.append(UInt32(1)); o.append(UInt32(2)); o.append(UInt32(840))
    o.append(UInt32(10045)); o.append(UInt32(2)); o.append(UInt32(1))
    return o^


def _oid_rsa_encryption() -> List[UInt32]:
    # 1.2.840.113549.1.1.1
    var o = List[UInt32]()
    o.append(UInt32(1)); o.append(UInt32(2)); o.append(UInt32(840))
    o.append(UInt32(113549)); o.append(UInt32(1)); o.append(UInt32(1))
    o.append(UInt32(1))
    return o^


def _oid_basic_constraints() -> List[UInt32]:
    # 2.5.29.19
    var o = List[UInt32]()
    o.append(UInt32(2)); o.append(UInt32(5)); o.append(UInt32(29))
    o.append(UInt32(19))
    return o^


def _oid_key_usage() -> List[UInt32]:
    # 2.5.29.15
    var o = List[UInt32]()
    o.append(UInt32(2)); o.append(UInt32(5)); o.append(UInt32(29))
    o.append(UInt32(15))
    return o^


def _oid_ext_key_usage() -> List[UInt32]:
    # 2.5.29.37
    var o = List[UInt32]()
    o.append(UInt32(2)); o.append(UInt32(5)); o.append(UInt32(29))
    o.append(UInt32(37))
    return o^


def _oid_server_auth() -> List[UInt32]:
    # 1.3.6.1.5.5.7.3.1
    var o = List[UInt32]()
    o.append(UInt32(1)); o.append(UInt32(3)); o.append(UInt32(6))
    o.append(UInt32(1)); o.append(UInt32(5)); o.append(UInt32(5))
    o.append(UInt32(7)); o.append(UInt32(3)); o.append(UInt32(1))
    return o^


# Set of extension OIDs that we recognize. Any critical extension NOT in
# this set causes a reject per RFC 5280 §4.2.
def _is_recognized_critical_oid(oid: List[UInt32]) -> Bool:
    # Recognized extensions:
    #   basicConstraints, keyUsage, extKeyUsage, subjectAltName,
    #   subjectKeyIdentifier, authorityKeyIdentifier.
    if der_oid_eq(oid, _oid_basic_constraints()): return True
    if der_oid_eq(oid, _oid_key_usage()): return True
    if der_oid_eq(oid, _oid_ext_key_usage()): return True
    # subjectAltName (2.5.29.17)
    var san = List[UInt32]()
    san.append(UInt32(2)); san.append(UInt32(5)); san.append(UInt32(29)); san.append(UInt32(17))
    if der_oid_eq(oid, san): return True
    # subjectKeyIdentifier (2.5.29.14)
    var ski = List[UInt32]()
    ski.append(UInt32(2)); ski.append(UInt32(5)); ski.append(UInt32(29)); ski.append(UInt32(14))
    if der_oid_eq(oid, ski): return True
    # authorityKeyIdentifier (2.5.29.35)
    var aki = List[UInt32]()
    aki.append(UInt32(2)); aki.append(UInt32(5)); aki.append(UInt32(29)); aki.append(UInt32(35))
    if der_oid_eq(oid, aki): return True
    return False


# -----------------------------------------------------------------------------
# DN comparison (byte-equal; RFC 5280 §7.1 canonical comparison not implemented)
# -----------------------------------------------------------------------------


def _dn_equal(a: List[DnAttribute], b: List[DnAttribute]) -> Bool:
    """Byte-equal DN comparison: same length, same OIDs in order, same
    comparison; this uses byte-equal comparison, which works for anchor
    lineages that encode their DNs byte-stably (e.g. Let's Encrypt R3 +
    ISRG). Canonical DN comparison is not implemented.
    """
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if not der_oid_eq(a[i].oid, b[i].oid):
            return False
        if a[i].value != b[i].value:
            return False
    return True


# -----------------------------------------------------------------------------
# DerTime comparison
# -----------------------------------------------------------------------------


def _time_cmp(a: DerTime, b: DerTime) -> Int:
    """Compare two DerTimes lex order. Returns -1 / 0 / 1."""
    if Int(a.year) < Int(b.year): return -1
    if Int(a.year) > Int(b.year): return 1
    if Int(a.month) < Int(b.month): return -1
    if Int(a.month) > Int(b.month): return 1
    if Int(a.day) < Int(b.day): return -1
    if Int(a.day) > Int(b.day): return 1
    if Int(a.hour) < Int(b.hour): return -1
    if Int(a.hour) > Int(b.hour): return 1
    if Int(a.minute) < Int(b.minute): return -1
    if Int(a.minute) > Int(b.minute): return 1
    if Int(a.second) < Int(b.second): return -1
    if Int(a.second) > Int(b.second): return 1
    return 0


def _now_to_dertime(
    now: Tuple[UInt16, UInt8, UInt8, UInt8, UInt8, UInt8]
) -> DerTime:
    return DerTime(now[0], now[1], now[2], now[3], now[4], now[5])


# -----------------------------------------------------------------------------
# basicConstraints + keyUsage + extKeyUsage extension parsers
# -----------------------------------------------------------------------------


struct _BasicConstraints(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Parsed basicConstraints extension (RFC 5280 §4.2.1.9).

    BasicConstraints ::= SEQUENCE {
        cA                 BOOLEAN DEFAULT FALSE,
        pathLenConstraint  INTEGER (0..MAX) OPTIONAL
    }
    """
    var ca: Bool
    var has_path_len: Bool
    var path_len: Int  # -1 if has_path_len = False

    def __init__(out self, ca: Bool, has_path_len: Bool, path_len: Int):
        self.ca = ca
        self.has_path_len = has_path_len
        self.path_len = path_len


def _parse_basic_constraints(value: Span[UInt8, _]) raises -> _BasicConstraints:
    """Parse extnValue of basicConstraints."""
    var seq = der_parse_tlv(value, 0)
    if not (seq.tag.class_ == ASN1_CLASS_UNIVERSAL and seq.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("basicConstraints: not a SEQUENCE")
    var ca = False
    var has_path = False
    var path_len = -1
    var pos = seq.value_pos
    while pos < seq.end_pos:
        var child = der_parse_tlv(value, pos)
        if child.tag.class_ == ASN1_CLASS_UNIVERSAL and child.tag.tag_number == ASN1_TAG_BOOLEAN:
            ca = der_parse_boolean(value[child.value_pos : child.value_pos + child.value_len])
        elif child.tag.class_ == ASN1_CLASS_UNIVERSAL and child.tag.tag_number == ASN1_TAG_INTEGER:
            # pathLenConstraint INTEGER >= 0.
            var bs = der_parse_integer_to_bytes(value[child.value_pos : child.value_pos + child.value_len])
            # Compress to Int. bytes is unsigned BE (since pathLen >= 0).
            var n = 0
            for k in range(len(bs)):
                n = n * 256 + Int(bs[k])
            path_len = n
            has_path = True
        # else: unknown child — silently skip
        pos = child.end_pos
    return _BasicConstraints(ca, has_path, path_len)


# Bit positions for keyUsage per RFC 5280 §4.2.1.3
# KeyUsage ::= BIT STRING {
#     digitalSignature   (0),
#     contentCommitment  (1),   -- formerly nonRepudiation
#     keyEncipherment    (2),
#     dataEncipherment   (3),
#     keyAgreement       (4),
#     keyCertSign        (5),
#     cRLSign            (6),
#     encipherOnly       (7),
#     decipherOnly       (8) }
comptime KU_DIGITAL_SIGNATURE = 0
comptime KU_KEY_ENCIPHERMENT = 2
comptime KU_KEY_AGREEMENT = 4
comptime KU_KEY_CERT_SIGN = 5


def _parse_key_usage(value: Span[UInt8, _]) raises -> UInt16:
    """Parse keyUsage extension's extnValue into a 16-bit bitmask
    (bit i = position i).

    The extnValue bytes ARE the BIT STRING TLV (tag 0x03 + len +
    unused_bits + data). We unwrap the TLV first then call
    `der_parse_bit_string` on the inner value bytes.

    Per X.690 §8.6: bit 0 of the first data byte is the MSB. KeyUsage
    uses big-endian bit numbering with bit 0 = digitalSignature.
    """
    var bs_tlv = der_parse_tlv(value, 0)
    if not (bs_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and bs_tlv.tag.tag_number == ASN1_TAG_BIT_STRING):
        raise Error("keyUsage: extnValue is not a BIT STRING")
    var bs_res = der_parse_bit_string(value[bs_tlv.value_pos : bs_tlv.value_pos + bs_tlv.value_len])
    var mask = UInt16(0)
    var nbytes = len(bs_res.bytes)
    var total_bits = nbytes * 8 - Int(bs_res.unused_bits)
    for i in range(total_bits):
        var byte_idx = i // 8
        var bit_pos_in_byte = 7 - (i % 8)
        var bit = (bs_res.bytes[byte_idx] >> UInt8(bit_pos_in_byte)) & UInt8(1)
        if bit == UInt8(1):
            mask = mask | (UInt16(1) << UInt16(i))
    return mask


def _has_ku_bit(mask: UInt16, bit_pos: Int) -> Bool:
    """Check if bit at `bit_pos` in keyUsage mask is set."""
    return (mask & (UInt16(1) << UInt16(bit_pos))) != UInt16(0)


def _parse_ext_key_usage_has_server_auth(value: Span[UInt8, _]) raises -> Bool:
    """Parse extKeyUsage extension and return True if serverAuth OID present.

    ExtKeyUsageSyntax ::= SEQUENCE SIZE (1..MAX) OF KeyPurposeId
    KeyPurposeId ::= OBJECT IDENTIFIER
    """
    var seq = der_parse_tlv(value, 0)
    if not (seq.tag.class_ == ASN1_CLASS_UNIVERSAL and seq.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("extKeyUsage: not a SEQUENCE")
    var server_auth = _oid_server_auth()
    var pos = seq.value_pos
    while pos < seq.end_pos:
        var child = der_parse_tlv(value, pos)
        if child.tag.class_ != ASN1_CLASS_UNIVERSAL or child.tag.tag_number != ASN1_TAG_OID:
            raise Error("extKeyUsage: child not OID")
        var oid = der_parse_oid(value[child.value_pos : child.value_pos + child.value_len])
        if der_oid_eq(oid, server_auth):
            return True
        pos = child.end_pos
    return False


# -----------------------------------------------------------------------------
# Critical-extension scan (RFC 5280 §4.2)
# -----------------------------------------------------------------------------


def _has_unknown_critical(cert: X509Certificate) -> Bool:
    """Return True if any critical extension is not in the recognized
    set (basicConstraints, keyUsage, extKeyUsage, SAN, SKI, AKI)."""
    for i in range(len(cert.extensions)):
        if cert.extensions[i].critical:
            if not _is_recognized_critical_oid(cert.extensions[i].oid):
                return True
    return False


# -----------------------------------------------------------------------------
# Public-key extraction
# -----------------------------------------------------------------------------


def _extract_ec_pubkey(cert: X509Certificate) raises -> List[UInt8]:
    """Extract a 64-byte uncompressed EC pubkey (x || y) from
    cert.subject_pubkey. The cert's SPKI BIT STRING wraps a leading
    0x04 byte (uncompressed point indicator) followed by x || y (32 + 32
    bytes for P-256).
    """
    if not der_oid_eq(cert.subject_pubkey_algo_oid, _oid_ec_public_key()):
        raise Error("EC pubkey extract: SPKI algo OID is not ecPublicKey")
    # NOTE: cert.subject_pubkey is List[UInt8] (heap-owning, NOT
    # ImplicitlyCopyable on Mojo 1.0.0b1 since it owns a heap buffer).
    # Index directly to avoid implicit-copy reject.
    if len(cert.subject_pubkey) != 65:
        raise Error("EC pubkey extract: expected 65 bytes (0x04 || x || y), got different size")
    if cert.subject_pubkey[0] != UInt8(0x04):
        raise Error("EC pubkey extract: not uncompressed form (leading byte != 0x04)")
    var out = List[UInt8]()
    for i in range(1, 65):
        out.append(cert.subject_pubkey[i])
    return out^


def _extract_ec384_pubkey(cert: X509Certificate) raises -> List[UInt8]:
    """Extract a 96-byte uncompressed EC-P-384 pubkey (x || y) from
    cert.subject_pubkey. The cert's SPKI BIT STRING wraps a leading
    0x04 byte (uncompressed point indicator) followed by x || y
    (48 + 48 bytes for P-384).

    Parallel helper to `_extract_ec_pubkey` (P-256, 64 bytes) — the
    65/97 split is determined by the issuer's pubkey curve which the
    dispatch site already knows via the leaf's signatureAlgorithm OID.
    """
    if not der_oid_eq(cert.subject_pubkey_algo_oid, _oid_ec_public_key()):
        raise Error("EC-P-384 pubkey extract: SPKI algo OID is not ecPublicKey")
    if len(cert.subject_pubkey) != 97:
        raise Error("EC-P-384 pubkey extract: expected 97 bytes (0x04 || x || y), got different size")
    if cert.subject_pubkey[0] != UInt8(0x04):
        raise Error("EC-P-384 pubkey extract: not uncompressed form (leading byte != 0x04)")
    var out = List[UInt8]()
    for i in range(1, 97):
        out.append(cert.subject_pubkey[i])
    return out^


def _extract_ed25519_pubkey(cert: X509Certificate) raises -> List[UInt8]:
    """Extract a 32-byte Ed25519 pubkey from cert.subject_pubkey.

    Per RFC 8410 §4, the Ed25519 SubjectPublicKeyInfo uses the SAME OID
    (1.3.101.112) for BOTH the AlgorithmIdentifier AND the inner pubkey
    encoding. The BIT STRING wraps the raw 32-byte public key value
    directly — NO 0x04 uncompressed-point prefix (no curve group), NO
    DER wrapper (no SEQUENCE), just 32 bytes.

    Note: our X.509 parser stores the BIT STRING value (post the leading
    "unused-bits" byte) in `cert.subject_pubkey`, so this is just a
    length check + copy.

    Parallel helper to `_extract_ec_pubkey` (P-256) and
    `_extract_ec384_pubkey` (P-384). Simpler than both — no curve, no
    encoding wrapper.
    """
    if not der_oid_eq(cert.subject_pubkey_algo_oid, _oid_ed25519()):
        raise Error("Ed25519 pubkey extract: SPKI algo OID is not Ed25519 (1.3.101.112)")
    if len(cert.subject_pubkey) != 32:
        raise Error("Ed25519 pubkey extract: expected 32 bytes (raw pubkey), got different size")
    var out = List[UInt8]()
    for i in range(32):
        out.append(cert.subject_pubkey[i])
    return out^


struct _RsaPubkeyBytes(Movable, Deinitable):
    var modulus: List[UInt8]
    var exponent: List[UInt8]

    def __init__(out self, var modulus: List[UInt8], var exponent: List[UInt8]):
        self.modulus = modulus^
        self.exponent = exponent^


def _extract_rsa_pubkey(cert: X509Certificate) raises -> _RsaPubkeyBytes:
    """Extract RSA modulus + exponent bytes from cert.subject_pubkey.

    The SPKI for rsaEncryption wraps a SEQUENCE { modulus INTEGER,
    publicExponent INTEGER } inside the BIT STRING.
    """
    if not der_oid_eq(cert.subject_pubkey_algo_oid, _oid_rsa_encryption()):
        raise Error("RSA pubkey extract: SPKI algo OID is not rsaEncryption")
    var pk = Span(cert.subject_pubkey)
    var seq = der_parse_tlv(pk, 0)
    if not (seq.tag.class_ == ASN1_CLASS_UNIVERSAL and seq.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("RSA pubkey: SPKI inner not SEQUENCE")
    var mod_tlv = der_parse_tlv(pk, seq.value_pos)
    if not (mod_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and mod_tlv.tag.tag_number == ASN1_TAG_INTEGER):
        raise Error("RSA pubkey: modulus not INTEGER")
    var modulus = der_parse_integer_to_bytes(pk[mod_tlv.value_pos : mod_tlv.value_pos + mod_tlv.value_len])
    var exp_tlv = der_parse_tlv(pk, mod_tlv.end_pos)
    if not (exp_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and exp_tlv.tag.tag_number == ASN1_TAG_INTEGER):
        raise Error("RSA pubkey: exponent not INTEGER")
    var exponent = der_parse_integer_to_bytes(pk[exp_tlv.value_pos : exp_tlv.value_pos + exp_tlv.value_len])
    return _RsaPubkeyBytes(modulus^, exponent^)


# -----------------------------------------------------------------------------
# ECDSA signature DER -> raw r||s conversion
# -----------------------------------------------------------------------------


def _ecdsa_der_to_raw(sig_der: Span[UInt8, _]) raises -> List[UInt8]:
    """Convert ECDSA DER-encoded signature `SEQUENCE { r INTEGER, s INTEGER }`
    into 64-byte r||s form (32B each, big-endian, zero-padded).
    """
    var seq = der_parse_tlv(sig_der, 0)
    if not (seq.tag.class_ == ASN1_CLASS_UNIVERSAL and seq.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("ECDSA sig: not SEQUENCE")
    var r_tlv = der_parse_tlv(sig_der, seq.value_pos)
    if not (r_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and r_tlv.tag.tag_number == ASN1_TAG_INTEGER):
        raise Error("ECDSA sig: r not INTEGER")
    var r_bytes = der_parse_integer_to_bytes(sig_der[r_tlv.value_pos : r_tlv.value_pos + r_tlv.value_len])
    var s_tlv = der_parse_tlv(sig_der, r_tlv.end_pos)
    if not (s_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and s_tlv.tag.tag_number == ASN1_TAG_INTEGER):
        raise Error("ECDSA sig: s not INTEGER")
    var s_bytes = der_parse_integer_to_bytes(sig_der[s_tlv.value_pos : s_tlv.value_pos + s_tlv.value_len])
    if len(r_bytes) > 32 or len(s_bytes) > 32:
        raise Error("ECDSA sig: r or s > 32 bytes")
    var out = List[UInt8]()
    # Left-pad r with zeros to 32 bytes
    for _ in range(32 - len(r_bytes)):
        out.append(UInt8(0))
    for i in range(len(r_bytes)):
        out.append(r_bytes[i])
    # Left-pad s with zeros to 32 bytes
    for _ in range(32 - len(s_bytes)):
        out.append(UInt8(0))
    for i in range(len(s_bytes)):
        out.append(s_bytes[i])
    return out^


def _ecdsa_der_to_raw_p384(sig_der: Span[UInt8, _]) raises -> List[UInt8]:
    """Convert ECDSA-P384 DER-encoded signature `SEQUENCE { r INTEGER,
    s INTEGER }` into 96-byte r||s form (48B each, big-endian, zero-padded).

    Parallel helper to `_ecdsa_der_to_raw` (P-256, 32B components).
    """
    var seq = der_parse_tlv(sig_der, 0)
    if not (seq.tag.class_ == ASN1_CLASS_UNIVERSAL and seq.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("ECDSA-P384 sig: not SEQUENCE")
    var r_tlv = der_parse_tlv(sig_der, seq.value_pos)
    if not (r_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and r_tlv.tag.tag_number == ASN1_TAG_INTEGER):
        raise Error("ECDSA-P384 sig: r not INTEGER")
    var r_bytes = der_parse_integer_to_bytes(sig_der[r_tlv.value_pos : r_tlv.value_pos + r_tlv.value_len])
    var s_tlv = der_parse_tlv(sig_der, r_tlv.end_pos)
    if not (s_tlv.tag.class_ == ASN1_CLASS_UNIVERSAL and s_tlv.tag.tag_number == ASN1_TAG_INTEGER):
        raise Error("ECDSA-P384 sig: s not INTEGER")
    var s_bytes = der_parse_integer_to_bytes(sig_der[s_tlv.value_pos : s_tlv.value_pos + s_tlv.value_len])
    if len(r_bytes) > 48 or len(s_bytes) > 48:
        raise Error("ECDSA-P384 sig: r or s > 48 bytes")
    var out = List[UInt8]()
    # Left-pad r with zeros to 48 bytes
    for _ in range(48 - len(r_bytes)):
        out.append(UInt8(0))
    for i in range(len(r_bytes)):
        out.append(r_bytes[i])
    # Left-pad s with zeros to 48 bytes
    for _ in range(48 - len(s_bytes)):
        out.append(UInt8(0))
    for i in range(len(s_bytes)):
        out.append(s_bytes[i])
    return out^


# -----------------------------------------------------------------------------
# Signature verification dispatch
# -----------------------------------------------------------------------------


def _verify_signature(
    issuer: X509Certificate,
    subject_cert: X509Certificate,
) raises -> Bool:
    """Verify subject_cert was signed by issuer.

    Dispatches on subject_cert.signature_algo_oid:
      - ecdsa-with-SHA256 -> ecdsa_p256_verify(issuer-pubkey, tbs_raw, sig)
      - ecdsa-with-SHA384 -> ecdsa_p384_verify(issuer-pubkey-p384, tbs_raw, sig)
      - rsassaPss (2048-bit only) -> rsa_pss_verify[32, Sha256](...)
      - all others raise.

    The signature is in subject_cert.signature_value; the message is
    subject_cert.tbs_raw; the verifying pubkey is issuer.subject_pubkey
    (interpretation depends on issuer.subject_pubkey_algo_oid).
    """
    # NOTE: signature_algo_oid is List[UInt32] (heap-owning, NOT
    # ImplicitlyCopyable). Pass cert.signature_algo_oid directly to
    # der_oid_eq which takes refs.

    # ECDSA-with-SHA256
    if der_oid_eq(subject_cert.signature_algo_oid, _oid_ecdsa_sha256()):
        # Issuer must have an EC pubkey
        var ec_pk = _extract_ec_pubkey(issuer)
        var sig_raw = _ecdsa_der_to_raw(Span(subject_cert.signature_value))
        return ecdsa_p256_verify(
            Span(ec_pk),
            Span(subject_cert.tbs_raw),
            Span(sig_raw),
        )

    # RSA-PSS (2048-bit + SHA-256 + salt 32)
    if der_oid_eq(subject_cert.signature_algo_oid,_oid_rsa_pss()):
        var rsa_bytes = _extract_rsa_pubkey(issuer)
        # Only a 2048-bit modulus (256 bytes) is accepted; 3072 / 4096-bit
        # RSA-PSS issuers are not supported.
        if len(rsa_bytes.modulus) != 256:
            raise Error("RSA-PSS chain link: only 2048-bit RSA is supported; modulus len=" + String(len(rsa_bytes.modulus)))
        # Convert exponent bytes (BE) to UInt64.
        if len(rsa_bytes.exponent) > 8:
            raise Error("RSA-PSS chain link: exponent > 8 bytes not supported")
        var e64 = UInt64(0)
        for i in range(len(rsa_bytes.exponent)):
            e64 = (e64 << UInt64(8)) | UInt64(Int(rsa_bytes.exponent[i]))
        var pubkey = rsa_public_key_from_bytes[32](Span(rsa_bytes.modulus), e64)
        # Salt length = hash output (TLS 1.3 cert profile)
        return rsa_pss_verify[32, Sha256](
            pubkey,
            Span(subject_cert.tbs_raw),
            Span(subject_cert.signature_value),
            32,  # s_len = 32 (SHA-256 output length)
        )

    # ECDSA-with-SHA384.
    if der_oid_eq(subject_cert.signature_algo_oid, _oid_ecdsa_sha384()):
        var ec_pk384 = _extract_ec384_pubkey(issuer)
        var sig_raw384 = _ecdsa_der_to_raw_p384(Span(subject_cert.signature_value))
        return ecdsa_p384_verify(
            Span(ec_pk384),
            Span(subject_cert.tbs_raw),
            Span(sig_raw384),
        )

    # Ed25519. Per RFC 8410 §6
    # the Ed25519 signature in the cert is the raw 64-byte R || S value
    # stored directly as the BIT STRING (no DER wrapper, no SEQUENCE) —
    # `cert.signature_value` already holds those 64 bytes post-bit-string
    # parsing. The pubkey is also raw 32 bytes via `_extract_ed25519_pubkey`.)
    if der_oid_eq(subject_cert.signature_algo_oid, _oid_ed25519()):
        var ed_pk = _extract_ed25519_pubkey(issuer)
        return ed25519_verify(
            Span(ed_pk),
            Span(subject_cert.tbs_raw),
            Span(subject_cert.signature_value),
        )

    # Algorithms that are recognized but not supported
    if der_oid_eq(subject_cert.signature_algo_oid,_oid_rsa_sha256_pkcs1v15()):
        raise Error("Cert chain: PKCS#1 v1.5 RSA signatures are not supported")

    raise Error("Cert chain: unsupported signature algorithm OID")


# -----------------------------------------------------------------------------
# Per-cert validation steps
# -----------------------------------------------------------------------------


def _validate_validity_period(
    cert: X509Certificate, now: DerTime
) raises -> Bool:
    """RFC 5280 §6.1.3 (a)(2): cert is currently valid."""
    if _time_cmp(now, cert.not_before) < 0:
        return False
    if _time_cmp(now, cert.not_after) > 0:
        return False
    return True


def _validate_issuer_ca(issuer: X509Certificate) raises:
    """RFC 5280 §6.1.4: issuer must have basicConstraints cA=TRUE.
    Also KU keyCertSign if KU extension present + critical.
    Raises on failure."""
    var bc_idx = x509_find_extension(issuer, _oid_basic_constraints())
    if bc_idx < 0:
        raise Error("Issuer cert lacks basicConstraints extension (cannot be CA)")
    var bc = _parse_basic_constraints(Span(issuer.extensions[bc_idx].value))
    if not bc.ca:
        raise Error("Issuer cert basicConstraints cA=false (cannot sign other certs)")
    # KeyUsage: if present, must include keyCertSign
    var ku_idx = x509_find_extension(issuer, _oid_key_usage())
    if ku_idx >= 0:
        var mask = _parse_key_usage(Span(issuer.extensions[ku_idx].value))
        if not _has_ku_bit(mask, KU_KEY_CERT_SIGN):
            raise Error("Issuer cert keyUsage lacks keyCertSign bit")


def _validate_leaf(leaf: X509Certificate) raises:
    """Leaf-specific checks: digitalSignature/keyAgreement in KU if present,
    serverAuth in EKU if present."""
    var ku_idx = x509_find_extension(leaf, _oid_key_usage())
    if ku_idx >= 0:
        var mask = _parse_key_usage(Span(leaf.extensions[ku_idx].value))
        var has_sig = _has_ku_bit(mask, KU_DIGITAL_SIGNATURE)
        var has_ka = _has_ku_bit(mask, KU_KEY_AGREEMENT)
        var has_ke = _has_ku_bit(mask, KU_KEY_ENCIPHERMENT)
        if not (has_sig or has_ka or has_ke):
            raise Error("Leaf keyUsage has neither digitalSignature, keyAgreement, nor keyEncipherment")
    var eku_idx = x509_find_extension(leaf, _oid_ext_key_usage())
    if eku_idx >= 0:
        var has_sa = _parse_ext_key_usage_has_server_auth(Span(leaf.extensions[eku_idx].value))
        if not has_sa:
            raise Error("Leaf extKeyUsage lacks serverAuth")


# -----------------------------------------------------------------------------
# Public chain_verify
# -----------------------------------------------------------------------------


def chain_verify(
    chain: List[X509Certificate],
    trust_anchors: List[X509Certificate],
    now: Tuple[UInt16, UInt8, UInt8, UInt8, UInt8, UInt8],
) raises -> Bool:
    """Walk an X.509 cert chain from leaf to terminal, verifying each link
    + terminating at a trust anchor. Returns True iff verification
    succeeds end-to-end.

    Raises with a descriptive error on rejection. (Choice: raise rather
    than return False so the caller learns WHICH check failed, which is
    useful for both tests and for TLS handshake-level diagnostics.)
    """
    if len(chain) == 0:
        raise Error("Cert chain: empty chain")

    var now_dt = _now_to_dertime(now)

    # Phase 1: per-cert validity + unknown-critical scan + leaf-specific checks
    for i in range(len(chain)):
        if not _validate_validity_period(chain[i], now_dt):
            raise Error("Cert chain: cert " + String(i) + " not currently valid (validity period violated)")
        if _has_unknown_critical(chain[i]):
            raise Error("Cert chain: cert " + String(i) + " has unknown CRITICAL extension")
    _validate_leaf(chain[0])

    # Phase 2: per-link signature + issuer-CA + name match
    for i in range(len(chain) - 1):
        # Issuer name match
        if not _dn_equal(chain[i].issuer, chain[i + 1].subject):
            raise Error("Cert chain: cert " + String(i) + " issuer DN != cert " + String(i + 1) + " subject DN")
        # Issuer (cert[i+1]) must be a CA with keyCertSign
        _validate_issuer_ca(chain[i + 1])
        # Signature verify
        var ok = _verify_signature(chain[i + 1], chain[i])
        if not ok:
            raise Error("Cert chain: signature verification failed at link " + String(i) + " -> " + String(i + 1))

    # Phase 3: terminate at trust anchor
    # The terminal cert chain[last] must EITHER be itself a trust_anchor
    # (subject byte-equal) OR be signed by a trust_anchor whose subject
    # matches chain[last].issuer.
    # NOTE: X509Certificate owns List/String heap fields and is NOT
    # ImplicitlyCopyable. Index into chain[last_idx] directly.
    var last_idx = len(chain) - 1
    # Case A: last cert IS a trust anchor
    for k in range(len(trust_anchors)):
        if _dn_equal(chain[last_idx].subject, trust_anchors[k].subject):
            # We trust this directly. Skip signature re-verification.
            return True
    # Case B: last cert is signed by a trust anchor
    for k in range(len(trust_anchors)):
        if _dn_equal(chain[last_idx].issuer, trust_anchors[k].subject):
            _validate_issuer_ca(trust_anchors[k])
            var ok = _verify_signature(trust_anchors[k], chain[last_idx])
            if ok:
                return True
    raise Error("Cert chain: terminal cert does not chain to any trust anchor")
