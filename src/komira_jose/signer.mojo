# =============================================================================
# komira_jose/signer.mojo: sign a compact JWS (RFC 7515 section 7.1) with one
#   private key under one algorithm: ES256, EdDSA (Ed25519) or RS256, the
#   three algorithms `JwsVerifier` accepts.
# =============================================================================
#
# A `JwsSigner` owns one private key, moved in as a zeroizing `SecretValue`
# (komira_secret_store), and its public half as a `Jwk` that carries
#
#   * `kid`: the RFC 7638 thumbprint of the public key (thumbprint.mojo), so
#     the `kid` a token names is a function of the key it was signed with;
#   * `alg`: the signer's one algorithm, and `use`: `sig`.
#
# The private key forms:
#
#   * ES256: the 32-byte big-endian P-256 scalar `d` (RFC 7518 section
#     6.2.2.1), from 1 to n - 1: zero, the group order and every larger value
#     (which AWS-LC would reduce modulo n) are refused. Signatures use the deterministic
#     nonce of RFC 6979, so a signer needs no random source;
#   * EdDSA: the 32-byte Ed25519 seed (RFC 8032 section 5.1.5; the JWK `d`
#     of RFC 8037 section 2);
#   * RS256: an RSA PKCS#8 `PrivateKeyInfo` in DER (RFC 5208), as
#     komira_crypto's `rsa_pkcs8_der_from_pem` returns it. Its algorithm must
#     be rsaEncryption, its modulus 2048 to 4096 bits counted in bits
#     (komira_jwks's range is 256 to 512 bytes, which a signer narrows: a
#     2041- to 2047-bit modulus is refused), and AWS-LC must sign with it
#     when the signer is built.
#
# Every constructor (`JwsSigner(alg=, private_key=)` and `es256`, `eddsa`,
# `rs256`, which fix the algorithm) derives the public key from the private
# key, so a signer's `kid` is always its own key's thumbprint and a
# `Keyring` cannot be handed a signer that names another key.
#
# `sign(payload, typ)` writes the protected header `{"alg":..,"kid":..}`, with
# `,"typ":..` when a type is given, in that member order and with no
# whitespace, and signs `base64url(header) . base64url(payload)` with the
# algorithm the signer was built for: the header never chooses it. A `typ`
# must be a non-empty string of printable ASCII; it is written with JSON
# escaping. The payload is any bytes: what it claims is the caller's (the
# Keyring checks the lifetime of what it signs).
#
# Every refusal raises `JoseError: <fixed text>`, a komira_crypto failure
# included; no text carries any byte of a key.
#
# ENCAPSULATION: `SecretValue`, `Span[UInt8, _]` and `String` in; `String`
# and `Jwk` out. No pointer crosses this file's API. The private key is read
# only through `SecretValue.revealed_bytes()`, a span that cannot outlive the
# signer, and is wiped when the signer is destroyed.
# =============================================================================

from komira_crypto import ed25519_pubkey_from_seed, ed25519_sign, rsa_sha256_sign
from komira_crypto.cert.asn1 import der_parse_integer_to_bytes, der_parse_tlv
from komira_crypto.ecdsa_p256 import (
    ecdsa_p256_generate_pubkey,
    ecdsa_p256_sign_deterministic,
)
from komira_encoding import base64_url_encode_nopad
from komira_json import write_json_string
from komira_jwks import Jwk
from komira_secret_store import SecretValue

from komira_jose.header import is_printable_ascii
from komira_jose.thumbprint import jwk_thumbprint
from komira_jose.verifier import JWS_ALG_EDDSA, JWS_ALG_ES256, JWS_ALG_RS256


# The shortest RSA modulus a signer takes, in bits.
comptime _RS256_MIN_MODULUS_BITS: Int = 2048


def _refuse(reason: String) raises:
    raise Error(String("JoseError: ") + reason)


def _published(var bare: Jwk, alg: String) raises -> Jwk:
    """`bare` with its thumbprint as `kid`, `alg` and `use` `sig`."""
    var kid = jwk_thumbprint(bare)
    if alg == JWS_ALG_ES256:
        var x = bare.x()
        var y = bare.y()
        return Jwk.ec_p256(
            Span(x), Span(y), kid=kid, alg=alg, key_use=String("sig")
        )
    if alg == JWS_ALG_EDDSA:
        var x = bare.x()
        return Jwk.ed25519(Span(x), kid=kid, alg=alg, key_use=String("sig"))
    var n = bare.n()
    var e = bare.e()
    return Jwk.rsa(Span(n), Span(e), kid=kid, alg=alg, key_use=String("sig"))


def _p256_order() -> List[UInt8]:
    """The P-256 group order n, big-endian (SEC 2 section 2.4.2)."""
    var out = List[UInt8]()
    for b in [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
        0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]:
        out.append(UInt8(b))
    return out^


def _scalar_in_range(d: Span[UInt8, _]) -> Bool:
    """True when the 32-byte big-endian `d` is from 1 to n - 1. AWS-LC
    reduces a larger value modulo n, which would make two encodings of one
    key; RFC 7518 section 6.2.2.1 allows only the canonical one.

    Constant time: every byte of `d` is read, and no branch or early exit
    depends on it. `d < n` is the borrow out of `d - n`, computed from the
    least significant byte up; `d != 0` is the OR of every byte."""
    var order = _p256_order()
    var any_bit = UInt8(0)
    var borrow = 0
    for k in range(32):
        var i = 31 - k
        any_bit |= d[i]
        # diff is in -256..255; bit 8 of its two's complement is set
        # exactly when it is negative.
        var diff = Int(d[i]) - Int(order[i]) - borrow
        borrow = (diff >> 8) & 1
    return (any_bit != UInt8(0)) & (borrow == 1)


def _rsa_encryption_oid() -> List[UInt8]:
    """1.2.840.113549.1.1.1 (rsaEncryption), the OID's content bytes."""
    var out = List[UInt8]()
    for b in [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]:
        out.append(UInt8(b))
    return out^


def _rsa_public_parts(der: Span[UInt8, _]) raises -> Tuple[List[UInt8], List[UInt8]]:
    """The modulus and public exponent of a PKCS#8 RSA key: PrivateKeyInfo
    SEQUENCE { version, AlgorithmIdentifier { rsaEncryption, .. },
    OCTET STRING { RSAPrivateKey SEQUENCE { version, n, e, .. } } }. Raises
    when the walk leaves the buffer or the algorithm is not rsaEncryption.
    Whether the whole key is well formed is AWS-LC's check (the probe
    signature in `JwsSigner.rs256`)."""
    var outer = der_parse_tlv(der, 0)
    var version = der_parse_tlv(der, outer.value_pos)
    var algorithm = der_parse_tlv(der, version.end_pos)
    var oid = der_parse_tlv(der, algorithm.value_pos)
    var got = List[UInt8]()
    for i in range(oid.value_pos, oid.end_pos):
        got.append(der[i])
    if got != _rsa_encryption_oid():
        raise Error("not rsaEncryption")
    var octets = der_parse_tlv(der, algorithm.end_pos)
    var rsa_key = der_parse_tlv(der, octets.value_pos)
    var rsa_version = der_parse_tlv(der, rsa_key.value_pos)
    var n = der_parse_tlv(der, rsa_version.end_pos)
    var e = der_parse_tlv(der, n.end_pos)
    return (
        der_parse_integer_to_bytes(der[n.value_pos : n.value_pos + n.value_len]),
        der_parse_integer_to_bytes(der[e.value_pos : e.value_pos + e.value_len]),
    )


def _es256_public(private_key: SecretValue) raises -> Jwk:
    """The published key of an ES256 signer, derived from its scalar."""
    if private_key.len() != 32:
        _refuse("an ES256 private key is 32 bytes")
    if not _scalar_in_range(private_key.revealed_bytes()):
        _refuse("the ES256 private key is not a scalar from 1 to n - 1")
    var xy = ecdsa_p256_generate_pubkey(private_key.revealed_bytes())
    var zero = True
    for i in range(64):
        if xy[i] != UInt8(0):
            zero = False
    if zero:
        # AWS-LC returns zeros only when it fails (out of memory): the
        # range check above already refused every scalar it cannot use.
        _refuse("AWS-LC derived no public key for the ES256 private key")
    var x = List[UInt8]()
    var y = List[UInt8]()
    for i in range(32):
        x.append(xy[i])
        y.append(xy[32 + i])
    return _published(Jwk.ec_p256(Span(x), Span(y)), JWS_ALG_ES256)


def _eddsa_public(seed: SecretValue) raises -> Jwk:
    """The published key of an EdDSA signer, derived from its seed."""
    if seed.len() != 32:
        _refuse("an Ed25519 seed is 32 bytes")
    var pk = List[UInt8]()
    try:
        var derived = ed25519_pubkey_from_seed(seed.revealed_bytes())
        for i in range(32):
            pk.append(derived[i])
    except:
        raise Error("JoseError: AWS-LC derived no public key for the Ed25519 seed")
    return _published(Jwk.ed25519(Span(pk)), JWS_ALG_EDDSA)


def _modulus_bits(n: List[UInt8]) -> Int:
    """The bit length of the big-endian `n`, whose first byte is not 0."""
    var top = Int(n[0])
    var bits = 0
    while top > 0:
        bits += 1
        top >>= 1
    return (len(n) - 1) * 8 + bits


def _rs256_public(pkcs8_der: SecretValue) raises -> Jwk:
    """The published key of an RS256 signer, read from its PKCS#8 key, once
    AWS-LC has signed with the key."""
    var parts: Tuple[List[UInt8], List[UInt8]]
    try:
        parts = _rsa_public_parts(pkcs8_der.revealed_bytes())
    except:
        raise Error("JoseError: the key is not a PKCS#8 RSA private key")
    var n = parts[0].copy()
    var e = parts[1].copy()
    var bare: Jwk
    try:
        bare = Jwk.rsa(Span(n), Span(e))
    except:
        raise Error(
            "JoseError: the RSA key's modulus or exponent is outside the"
            " supported range"
        )
    # komira_jwks counts the modulus in bytes (256 to 512), so it takes a
    # 2041- to 2047-bit modulus; a signer counts bits. (`Jwk.rsa` refused
    # a leading zero byte, so n[0] is not 0.)
    if _modulus_bits(n) < _RS256_MIN_MODULUS_BITS:
        _refuse("the RSA modulus is shorter than 2048 bits")
    var probe = String("komira_jose probe")
    try:
        _ = rsa_sha256_sign(pkcs8_der.revealed_bytes(), probe.as_bytes())
    except:
        raise Error("JoseError: AWS-LC does not sign with the RSA key")
    return _published(bare^, JWS_ALG_RS256)


def _signature(
    alg: String, key: Span[UInt8, _], signing_input: Span[UInt8, _]
) raises -> List[UInt8]:
    """The `alg` signature of `signing_input` under the private key bytes
    `key`. A komira_crypto failure is raised as a `JoseError`."""
    var sig = List[UInt8]()
    try:
        if alg == JWS_ALG_ES256:
            var rs = ecdsa_p256_sign_deterministic(key, signing_input)
            for i in range(64):
                sig.append(rs[i])
        elif alg == JWS_ALG_EDDSA:
            var s = ed25519_sign(key, signing_input)
            for i in range(64):
                sig.append(s[i])
        else:
            sig = rsa_sha256_sign(key, signing_input)
    except:
        raise Error("JoseError: komira_crypto could not sign")
    return sig^


struct JwsSigner(Movable):
    """One private key and its algorithm: signs compact JWS tokens whose
    header names the key's RFC 7638 thumbprint as `kid` (see the file
    header). Every constructor derives the public key, and so the `kid`,
    from the private key: no signer names a `kid` its key does not have."""

    var _alg: String
    var _secret: SecretValue
    var _public: Jwk

    def __init__(out self, *, alg: String, var private_key: SecretValue) raises:
        """A signer for `alg` from its private key form (see the file
        header); `es256`, `eddsa` and `rs256` are this with the algorithm
        fixed. Raises `JoseError: ...` for an algorithm other than ES256,
        EdDSA and RS256, and as those three do."""
        var public: Jwk
        if alg == JWS_ALG_ES256:
            public = _es256_public(private_key)
        elif alg == JWS_ALG_EDDSA:
            public = _eddsa_public(private_key)
        elif alg == JWS_ALG_RS256:
            public = _rs256_public(private_key)
        else:
            raise Error(
                "JoseError: a signer's algorithm must be ES256, EdDSA or RS256"
            )
        self._alg = alg.copy()
        self._secret = private_key^
        self._public = public^

    @staticmethod
    def es256(var private_key: SecretValue) raises -> JwsSigner:
        """An ES256 signer from the 32-byte big-endian P-256 scalar. Raises
        `JoseError: ...` for another length or a scalar outside 1 to n - 1."""
        return JwsSigner(alg=JWS_ALG_ES256, private_key=private_key^)

    @staticmethod
    def eddsa(var seed: SecretValue) raises -> JwsSigner:
        """An EdDSA (Ed25519) signer from the 32-byte seed. Raises
        `JoseError: ...` for another length."""
        return JwsSigner(alg=JWS_ALG_EDDSA, private_key=seed^)

    @staticmethod
    def rs256(var pkcs8_der: SecretValue) raises -> JwsSigner:
        """An RS256 signer from an RSA PKCS#8 DER private key. Raises
        `JoseError: ...` when it is not one, when its modulus is outside 2048
        to 4096 bits, or when AWS-LC will not sign with it."""
        return JwsSigner(alg=JWS_ALG_RS256, private_key=pkcs8_der^)

    def alg(self) -> String:
        """The one algorithm this signer signs with."""
        return self._alg.copy()

    def kid(self) -> String:
        """The RFC 7638 thumbprint every token from this signer names."""
        return self._public.kid().value()

    def public_jwk(self) -> Jwk:
        """The public key as published: `kid`, `alg`, `use` `sig`."""
        return self._public.copy()

    def header_json(self, typ: Optional[String]) raises -> String:
        """The protected header `sign` writes for `typ`. Raises for a `typ`
        that is empty or not printable ASCII."""
        var buf = List[UInt8]()
        buf.extend(Span(String('{"alg":').as_bytes()))
        write_json_string(buf, self._alg)
        buf.extend(Span(String(',"kid":').as_bytes()))
        write_json_string(buf, self.kid())
        if typ:
            if not is_printable_ascii(typ.value()):
                _refuse("typ must be a non-empty printable ASCII string")
            buf.extend(Span(String(',"typ":').as_bytes()))
            write_json_string(buf, typ.value())
        buf.append(0x7D)  # '}'
        return String(unsafe_from_utf8=Span(buf))

    def sign(self, payload: Span[UInt8, _], typ: Optional[String]) raises -> String:
        """The compact JWS of `payload` under this signer's key, with the
        header `header_json(typ)`."""
        var h = self.header_json(typ)
        var si = (
            base64_url_encode_nopad(h.as_bytes())
            + "."
            + base64_url_encode_nopad(payload)
        )
        var sig = _signature(
            self._alg, self._secret.revealed_bytes(), si.as_bytes()
        )
        return si + "." + base64_url_encode_nopad(Span(sig))
