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
#     be rsaEncryption, its modulus 2048 to 4096 bits (komira_jwks's range),
#     and AWS-LC must sign with it when the signer is built.
#
# `sign(payload, typ)` writes the protected header `{"alg":..,"kid":..}`, with
# `,"typ":..` when a type is given, in that member order and with no
# whitespace, and signs `base64url(header) . base64url(payload)` with the
# algorithm the signer was built for: the header never chooses it. A `typ`
# must be a non-empty string of printable ASCII; it is written with JSON
# escaping. The payload is any bytes: what it claims is the caller's (the
# Keyring checks the lifetime of what it signs).
#
# Every refusal raises `JoseError: <fixed text>`; no text carries any byte
# of a key.
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
    key; RFC 7518 section 6.2.2.1 allows only the canonical one."""
    var nonzero = False
    for i in range(32):
        if d[i] != UInt8(0):
            nonzero = True
    if not nonzero:
        return False
    var order = _p256_order()
    for i in range(32):
        if d[i] != order[i]:
            return d[i] < order[i]
    return False


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


struct JwsSigner(Movable):
    """One private key and its algorithm: signs compact JWS tokens whose
    header names the key's RFC 7638 thumbprint as `kid` (see the file
    header). Build one with `es256`, `eddsa` or `rs256`."""

    var _alg: String
    var _secret: SecretValue
    var _public: Jwk

    def __init__(
        out self, *, var _alg: String, var _secret: SecretValue, var _public: Jwk
    ):
        """Takes the parts as given; use `es256`, `eddsa` or `rs256`, which
        check them (private by naming convention only)."""
        self._alg = _alg^
        self._secret = _secret^
        self._public = _public^

    @staticmethod
    def es256(var private_key: SecretValue) raises -> JwsSigner:
        """An ES256 signer from the 32-byte big-endian P-256 scalar. Raises
        `JoseError: ...` for another length or a scalar outside 1 to n - 1."""
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
        var public = _published(Jwk.ec_p256(Span(x), Span(y)), JWS_ALG_ES256)
        return JwsSigner(
            _alg=JWS_ALG_ES256, _secret=private_key^, _public=public^
        )

    @staticmethod
    def eddsa(var seed: SecretValue) raises -> JwsSigner:
        """An EdDSA (Ed25519) signer from the 32-byte seed. Raises
        `JoseError: ...` for another length."""
        if seed.len() != 32:
            _refuse("an Ed25519 seed is 32 bytes")
        var pk = ed25519_pubkey_from_seed(seed.revealed_bytes())
        var public = _published(
            Jwk.ed25519(Span[UInt8, origin_of(pk)](pk)), JWS_ALG_EDDSA
        )
        return JwsSigner(_alg=JWS_ALG_EDDSA, _secret=seed^, _public=public^)

    @staticmethod
    def rs256(var pkcs8_der: SecretValue) raises -> JwsSigner:
        """An RS256 signer from an RSA PKCS#8 DER private key. Raises
        `JoseError: ...` when it is not one, when its modulus is outside 2048
        to 4096 bits, or when AWS-LC will not sign with it."""
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
        var probe = String("komira_jose probe")
        try:
            _ = rsa_sha256_sign(pkcs8_der.revealed_bytes(), probe.as_bytes())
        except:
            raise Error("JoseError: AWS-LC does not sign with the RSA key")
        var public = _published(bare^, JWS_ALG_RS256)
        return JwsSigner(_alg=JWS_ALG_RS256, _secret=pkcs8_der^, _public=public^)

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
        var sig: List[UInt8]
        if self._alg == JWS_ALG_ES256:
            var rs = ecdsa_p256_sign_deterministic(
                self._secret.revealed_bytes(), si.as_bytes()
            )
            sig = List[UInt8]()
            for i in range(64):
                sig.append(rs[i])
        elif self._alg == JWS_ALG_EDDSA:
            var s = ed25519_sign(self._secret.revealed_bytes(), si.as_bytes())
            sig = List[UInt8]()
            for i in range(64):
                sig.append(s[i])
        else:
            sig = rsa_sha256_sign(self._secret.revealed_bytes(), si.as_bytes())
        return si + "." + base64_url_encode_nopad(Span(sig))
