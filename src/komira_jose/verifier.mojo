# =============================================================================
# komira_jose/verifier.mojo: verify a compact JWS with exactly one algorithm
#   (ES256, EdDSA or RS256) against the keys it was configured with.
# =============================================================================
#
# One `JwsVerifier` is one (algorithm, keys) pair. It never accepts a second
# algorithm: an issuer that signs RS256 tokens for anyone (a cloud's
# service-account ID tokens) must never reach a verifier that trusts another
# issuer's ES256 keys, so a deployment that trusts both builds two verifiers.
#
# Steps, in order (each refusal raises a fixed `JoseError: ...` text):
#
#   1. the header gate (header.mojo), before any key work;
#   2. key selection. A verifier built from a JWK Set (`JwsVerifier(alg,
#      set)`) requires `kid` and takes the key whose `kid` equals it; a `kid`
#      that names no key, or two keys, is refused, never a reason to try the
#      others. A verifier built from one key (`JwsVerifier.single_key(alg,
#      key)`) accepts a token without `kid`, and refuses one whose `kid`
#      differs from the key's;
#   3. the key must suit the pinned algorithm: ES256 an EC P-256 key, EdDSA
#      an OKP Ed25519 key, RS256 an RSA key of 2048 to 4096 bits; its `alg`,
#      when present, the pinned algorithm; its `use`, when present, `sig`;
#      its `key_ops`, when present, must include `verify` (RFC 7517 section
#      4). The key lengths are checked again here: a `Jwk` built around the
#      komira_jwks constructors carries no guarantee;
#   4. the signature: base64url without padding, then exactly 64 bytes for
#      ES256 (R || S, RFC 7518 section 3.4; a DER signature is refused) and
#      EdDSA (RFC 8037 section 3.1), or the modulus length for RS256 (RFC
#      8017 section 8.2.2);
#   5. the pinned algorithm over the signing input, the original token bytes
#      before the second dot;
#   6. only then the payload is decoded.
#
# ENCAPSULATION: `String`, `Jwk`, `JwkSet` in; owned values out. No pointer
# crosses this file's API. Every key here is public; nothing needs zeroizing.
# =============================================================================

from komira_crypto import ed25519_verify, rsa_pkcs1_sha256_verify
from komira_crypto.ecdsa_p256 import ecdsa_p256_verify
from komira_encoding import base64_url_decode_nopad
from komira_jwks import (
    JWK_CRV_ED25519,
    JWK_CRV_P256,
    JWK_KTY_EC,
    JWK_KTY_OKP,
    JWK_KTY_RSA,
    JWK_RSA_MAX_MODULUS_BYTES,
    JWK_RSA_MIN_MODULUS_BYTES,
    Jwk,
    JwkSet,
)

from komira_jose.header import (
    JwsCompact,
    check_header,
    header_string,
    split_compact,
)


comptime JWS_ALG_ES256: String = "ES256"
comptime JWS_ALG_EDDSA: String = "EdDSA"
comptime JWS_ALG_RS256: String = "RS256"


def _refuse(reason: String) raises:
    raise Error(String("JoseError: ") + reason)


def _check_supported(alg: String) raises:
    if alg != JWS_ALG_ES256 and alg != JWS_ALG_EDDSA and alg != JWS_ALG_RS256:
        raise Error(
            String("JoseError: algorithm \"")
            + alg
            + "\" is not supported (ES256, EdDSA and RS256 are)"
        )


def _type_fits(key: Jwk, alg: String) -> Bool:
    var kty = key.kty()
    if alg == JWS_ALG_ES256:
        return (
            kty == JWK_KTY_EC
            and key.crv() == JWK_CRV_P256
            and len(key.x()) == 32
            and len(key.y()) == 32
        )
    if alg == JWS_ALG_EDDSA:
        return (
            kty == JWK_KTY_OKP
            and key.crv() == JWK_CRV_ED25519
            and len(key.x()) == 32
        )
    if alg == JWS_ALG_RS256:
        var n = len(key.n())
        var e = key.e()
        return (
            kty == JWK_KTY_RSA
            and n >= JWK_RSA_MIN_MODULUS_BYTES
            and n <= JWK_RSA_MAX_MODULUS_BYTES
            and len(e) >= 1
            and len(e) <= 8
        )
    return False


def key_refusal(key: Jwk, alg: String) -> String:
    """Why `key` may not verify an `alg` signature, or "" when it may."""
    if not _type_fits(key, alg):
        return "the key does not suit the pinned algorithm"
    var key_alg = key.alg()
    if key_alg and key_alg.value() != alg:
        return "the key's alg is not the pinned algorithm"
    var use = key.key_use()
    if use and use.value() != "sig":
        return "the key's use is not sig"
    var ops = key.key_ops()
    if ops:
        var allows = False
        for i in range(len(ops.value())):
            if ops.value()[i] == "verify":
                allows = True
        if not allows:
            return "the key's key_ops does not include verify"
    return ""


def _exponent(e: List[UInt8]) -> UInt64:
    var v: UInt64 = 0
    for i in range(len(e)):
        v = (v << 8) | UInt64(e[i])
    return v


def _signature_verifies(
    alg: String, key: Jwk, signing_input: List[UInt8], sig: List[UInt8]
) -> Bool:
    if alg == JWS_ALG_ES256:
        var xy = key.x()
        var y = key.y()
        xy.extend(Span(y))
        return ecdsa_p256_verify(Span(xy), Span(signing_input), Span(sig))
    if alg == JWS_ALG_EDDSA:
        var x = key.x()
        return ed25519_verify(Span(x), Span(signing_input), Span(sig))
    if alg == JWS_ALG_RS256:
        var n = key.n()
        return rsa_pkcs1_sha256_verify(
            Span(n), _exponent(key.e()), Span(signing_input), Span(sig)
        )
    return False


def _signature_length(alg: String, key: Jwk) -> Int:
    if alg == JWS_ALG_RS256:
        return len(key.n())
    return 64


struct VerifiedJws(Copyable, Movable):
    """A JWS whose signature verified: its algorithm, the header's `kid` and
    `typ` when present as strings, and the payload bytes. The payload is
    authentic, not trusted: what it claims is the caller's to check."""

    var _alg: String
    var _kid: Optional[String]
    var _typ: Optional[String]
    var _payload: List[UInt8]

    def __init__(
        out self,
        var alg: String,
        var kid: Optional[String],
        var typ: Optional[String],
        var payload: List[UInt8],
    ):
        self._alg = alg^
        self._kid = kid^
        self._typ = typ^
        self._payload = payload^

    def alg(self) -> String:
        """The pinned algorithm the signature verified under."""
        return self._alg.copy()

    def kid(self) -> Optional[String]:
        """The header's `kid`, if present."""
        return self._kid.copy()

    def typ(self) -> Optional[String]:
        """The header's `typ`, if present and a string."""
        return self._typ.copy()

    def payload(self) -> List[UInt8]:
        """The decoded payload bytes."""
        return self._payload.copy()


struct JwsVerifier(Copyable, Movable):
    """Verifies compact JWS tokens under one pinned algorithm with the keys
    it was built from (see the file header)."""

    var _alg: String
    var _keys: List[Jwk]
    var _by_kid: Bool

    def __init__(out self, alg: String, keys: JwkSet) raises:
        """A verifier that selects a key from `keys` by the token's `kid`.
        Raises if `alg` is not ES256, EdDSA or RS256, or if no key in the
        set suits it."""
        _check_supported(alg)
        var usable = False
        for i in range(len(keys.keys)):
            if key_refusal(keys.keys[i], alg) == "":
                usable = True
        if not usable:
            raise Error(
                String("JoseError: the key set holds no key for ") + alg
            )
        self._alg = alg.copy()
        self._keys = keys.keys.copy()
        self._by_kid = True

    def __init__(out self, *, var _alg: String, var _key: Jwk):
        """One configured key; use `single_key`, which checks it."""
        self._alg = _alg^
        self._keys = List[Jwk]()
        self._keys.append(_key^)
        self._by_kid = False

    @staticmethod
    def single_key(alg: String, key: Jwk) raises -> JwsVerifier:
        """A verifier with one configured key: a token need not carry `kid`,
        and one that does must name this key's `kid` when the key has one.
        Raises if `alg` is unsupported or the key does not suit it."""
        _check_supported(alg)
        var why = key_refusal(key, alg)
        if why != "":
            _refuse(why)
        return JwsVerifier(_alg=alg.copy(), _key=key.copy())

    def alg(self) -> String:
        """The one algorithm this verifier accepts."""
        return self._alg.copy()

    def verify(self, token: String) raises -> VerifiedJws:
        """Verify `token` (see the file header). The header `typ` is not
        checked here; `verify_jwt` pins it."""
        return self.verify_with_typ(token, Optional[String](), False)

    def verify_with_typ(
        self, token: String, typ: Optional[String], require_kid: Bool
    ) raises -> VerifiedJws:
        """`verify`, with the header `typ` pinned to `typ` when present and a
        `kid` required when `require_kid` (a set-built verifier always
        requires one)."""
        var c = split_compact(token)
        check_header(c.header, self._alg, typ, require_kid or self._by_kid)
        var kid = header_string(c.header, "kid")
        var chosen = 0
        if self._by_kid:
            chosen = -1
            for i in range(len(self._keys)):
                var k = self._keys[i].kid()
                if k and k.value() == kid.value():
                    if chosen >= 0:
                        _refuse("kid names two keys in the set")
                    chosen = i
            if chosen < 0:
                _refuse("kid names no key in the set")
        else:
            var k = self._keys[0].kid()
            if Bool(kid) and Bool(k) and k.value() != kid.value():
                _refuse("kid does not name the configured key")
        ref key = self._keys[chosen]
        var why = key_refusal(key, self._alg)
        if why != "":
            _refuse(why)
        var sig: List[UInt8]
        try:
            sig = base64_url_decode_nopad(c.signature_b64)
        except:
            raise Error(
                "JoseError: the signature segment is not base64url without padding"
            )
        if len(sig) != _signature_length(self._alg, key):
            _refuse("the signature has the wrong length")
        if not _signature_verifies(self._alg, key, c.signing_input, sig):
            _refuse("the signature does not verify")
        var payload: List[UInt8]
        try:
            payload = base64_url_decode_nopad(c.payload_b64)
        except:
            raise Error(
                "JoseError: the payload segment is not base64url without padding"
            )
        return VerifiedJws(
            self._alg.copy(), kid^, header_string(c.header, "typ"), payload^
        )
