# =============================================================================
# komira_jwks/jwk.mojo: one public JSON Web Key (RFC 7517) of a signature key
#   type this package supports, and its canonical JSON rendering.
# =============================================================================
#
# Supported keys (RFC 7518 section 6, RFC 8037 section 2):
#
#   kty   crv       key members (raw bytes after base64url decoding)
#   OKP   Ed25519   x: the 32-byte public key
#   EC    P-256     x, y: the two 32-byte affine coordinates (full length,
#                   RFC 7518 section 6.2.1.2)
#   RSA   (none)    n: the modulus, 2048 to 4096 bits; e: the public exponent,
#                   odd and at least 3, at most 8 bytes. Both are
#                   Base64urlUInt (RFC 7518 section 2): no leading zero byte.
#
# A `Jwk` holds PUBLIC members only. There is no field for `d`, `p`, `q`,
# `dp`, `dq`, `qi`, `oth` or `k`, so nothing built from a `Jwk` can carry
# private material; the parser (jwk_set.mojo) refuses a document that has
# any of them.
#
# `kid`, `alg` and `use` are optional and kept verbatim (`alg` and `use` are
# not interpreted here: a verifier matches them against its own pinned
# algorithm and purpose). A present `kid` is non-empty.
#
# The three constructors and the parser run the same checks (`_check_*`
# below); `render_jwks_json` builds its keys through `Jwk.ed25519`. The fields
# sit in `_JwkParts`, read through accessors that return copies. The leading
# underscore is a naming convention the compiler does not enforce: code that
# imports `_JwkParts` can build a `Jwk` without the checks, so a verifier must
# not treat these checks as a security property.
#
# Rendering is canonical: members in the order kty, crv, alg, use, kid, then
# x, y (OKP, EC) or n, e (RSA); optional members only when present; string
# values escaped per RFC 8259; key members as base64url without padding.
#
# ENCAPSULATION: `Span[UInt8, _]` and `String` in, owned `String` and
# `List[UInt8]` out. No pointer crosses this file's API.
# =============================================================================

from komira_encoding import base64_url_encode_nopad
from komira_json import write_json_string


comptime JWK_KTY_OKP: String = "OKP"
comptime JWK_KTY_EC: String = "EC"
comptime JWK_KTY_RSA: String = "RSA"
comptime JWK_CRV_ED25519: String = "Ed25519"
comptime JWK_CRV_P256: String = "P-256"

# The supported RSA modulus range, in bytes (2048 to 4096 bits).
comptime JWK_RSA_MIN_MODULUS_BYTES: Int = 256
comptime JWK_RSA_MAX_MODULUS_BYTES: Int = 512


def _q(s: String) -> String:
    return String('"') + s + '"'


def _check_len(member: String, b: List[UInt8], want: Int, curve: String) raises:
    if len(b) != want:
        raise Error(
            String("member ")
            + _q(member)
            + " is "
            + String(len(b))
            + " bytes; "
            + curve
            + " needs "
            + String(want)
        )


def _check_okp_crv(crv: String) raises:
    if crv != JWK_CRV_ED25519:
        raise Error(
            String("OKP curve ") + _q(crv) + " is not supported (Ed25519 is)"
        )


def _check_ec_crv(crv: String) raises:
    if crv != JWK_CRV_P256:
        raise Error(String("EC curve ") + _q(crv) + " is not supported (P-256 is)")


def _check_okp(crv: String, x: List[UInt8]) raises:
    _check_okp_crv(crv)
    _check_len("x", x, 32, JWK_CRV_ED25519)


def _check_ec(crv: String, x: List[UInt8], y: List[UInt8]) raises:
    _check_ec_crv(crv)
    _check_len("x", x, 32, JWK_CRV_P256)
    _check_len("y", y, 32, JWK_CRV_P256)


def _check_rsa(n: List[UInt8], e: List[UInt8]) raises:
    if len(n) == 0 or n[0] == 0:
        raise Error(
            "member \"n\" is not a minimal Base64urlUInt (empty or a leading"
            " zero byte)"
        )
    if len(e) == 0 or e[0] == 0:
        raise Error(
            "member \"e\" is not a minimal Base64urlUInt (empty or a leading"
            " zero byte)"
        )
    if len(n) < JWK_RSA_MIN_MODULUS_BYTES or len(n) > JWK_RSA_MAX_MODULUS_BYTES:
        raise Error(
            String("RSA modulus is ")
            + String(len(n) * 8)
            + " bits; supported are 2048 to 4096"
        )
    if len(e) > 8:
        raise Error(
            String("RSA exponent is ") + String(len(e)) + " bytes; at most 8"
        )
    var last = e[len(e) - 1]
    if (last & 1) == 0 or (len(e) == 1 and last < 3):
        raise Error("RSA exponent must be odd and at least 3")


def _check_kid(kid: Optional[String]) raises:
    if kid:
        if kid.value().byte_length() == 0:
            raise Error("member \"kid\" is empty")


def _bytes(s: Span[UInt8, _]) -> List[UInt8]:
    var out = List[UInt8](capacity=len(s))
    out.extend(s)
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _opt_eq(a: Optional[String], b: Optional[String]) -> Bool:
    if a:
        if b:
            return a.value() == b.value()
        return False
    if b:
        return False
    return True


@fieldwise_init
struct _JwkParts(Copyable, Movable):
    """The members of a `Jwk`, before or after checking (private)."""

    var kty: String
    var crv: String
    var x: List[UInt8]
    var y: List[UInt8]
    var n: List[UInt8]
    var e: List[UInt8]
    var kid: Optional[String]
    var alg: Optional[String]
    var key_use: Optional[String]


struct Jwk(Copyable, Movable):
    """One public JWK of a supported signature key type (see the file
    header). Build one with `Jwk.ed25519`, `Jwk.ec_p256`, `Jwk.rsa` or the
    parser; each runs the same checks."""

    var _p: _JwkParts

    def __init__(out self, *, var _parts: _JwkParts):
        """Takes parts as given and runs no check. The parts type is private
        by naming convention only: callers use `ed25519`, `ec_p256`, `rsa` or
        the parser, which check first."""
        self._p = _parts^

    @staticmethod
    def ed25519(
        x: Span[UInt8, _],
        kid: Optional[String] = None,
        alg: Optional[String] = None,
        key_use: Optional[String] = None,
    ) raises -> Jwk:
        """An OKP Ed25519 key (RFC 8037 section 2) from its 32-byte public key.
        Raises `JwksError: ...` if `x` is not 32 bytes or `kid` is empty."""
        var xb = _bytes(x)
        try:
            _check_okp(JWK_CRV_ED25519, xb)
            _check_kid(kid)
        except err:
            raise Error(String("JwksError: ") + String(err))
        return Jwk(
            _parts=_JwkParts(
                kty=JWK_KTY_OKP,
                crv=JWK_CRV_ED25519,
                x=xb^,
                y=List[UInt8](),
                n=List[UInt8](),
                e=List[UInt8](),
                kid=kid.copy(),
                alg=alg.copy(),
                key_use=key_use.copy(),
            )
        )

    @staticmethod
    def ec_p256(
        x: Span[UInt8, _],
        y: Span[UInt8, _],
        kid: Optional[String] = None,
        alg: Optional[String] = None,
        key_use: Optional[String] = None,
    ) raises -> Jwk:
        """An EC P-256 key (RFC 7518 section 6.2) from its two 32-byte affine
        coordinates. Raises `JwksError: ...` if either is not 32 bytes or
        `kid` is empty. Whether the point is on the curve is the verifier's
        check, not this one."""
        var xb = _bytes(x)
        var yb = _bytes(y)
        try:
            _check_ec(JWK_CRV_P256, xb, yb)
            _check_kid(kid)
        except err:
            raise Error(String("JwksError: ") + String(err))
        return Jwk(
            _parts=_JwkParts(
                kty=JWK_KTY_EC,
                crv=JWK_CRV_P256,
                x=xb^,
                y=yb^,
                n=List[UInt8](),
                e=List[UInt8](),
                kid=kid.copy(),
                alg=alg.copy(),
                key_use=key_use.copy(),
            )
        )

    @staticmethod
    def rsa(
        n: Span[UInt8, _],
        e: Span[UInt8, _],
        kid: Optional[String] = None,
        alg: Optional[String] = None,
        key_use: Optional[String] = None,
    ) raises -> Jwk:
        """An RSA public key (RFC 7518 section 6.3) from its big-endian
        modulus and exponent, each without a leading zero byte. Raises
        `JwksError: ...` outside the supported range (see the file header)
        or if `kid` is empty."""
        var nb = _bytes(n)
        var eb = _bytes(e)
        try:
            _check_rsa(nb, eb)
            _check_kid(kid)
        except err:
            raise Error(String("JwksError: ") + String(err))
        return Jwk(
            _parts=_JwkParts(
                kty=JWK_KTY_RSA,
                crv=String(""),
                x=List[UInt8](),
                y=List[UInt8](),
                n=nb^,
                e=eb^,
                kid=kid.copy(),
                alg=alg.copy(),
                key_use=key_use.copy(),
            )
        )

    def kty(self) -> String:
        """`OKP`, `EC` or `RSA`."""
        return self._p.kty.copy()

    def crv(self) -> String:
        """`Ed25519` or `P-256`; empty for an RSA key."""
        return self._p.crv.copy()

    def x(self) -> List[UInt8]:
        """The Ed25519 public key, or the P-256 x coordinate; empty for RSA."""
        return self._p.x.copy()

    def y(self) -> List[UInt8]:
        """The P-256 y coordinate; empty for any other key."""
        return self._p.y.copy()

    def n(self) -> List[UInt8]:
        """The RSA modulus, big-endian; empty for any other key."""
        return self._p.n.copy()

    def e(self) -> List[UInt8]:
        """The RSA public exponent, big-endian; empty for any other key."""
        return self._p.e.copy()

    def kid(self) -> Optional[String]:
        """The `kid` member, if present (never empty)."""
        return self._p.kid.copy()

    def alg(self) -> Optional[String]:
        """The `alg` member, if present, verbatim."""
        return self._p.alg.copy()

    def key_use(self) -> Optional[String]:
        """The `use` member, if present, verbatim."""
        return self._p.key_use.copy()

    def __eq__(self, other: Self) -> Bool:
        """True iff every member is equal."""
        return (
            self._p.kty == other._p.kty
            and self._p.crv == other._p.crv
            and _bytes_eq(self._p.x, other._p.x)
            and _bytes_eq(self._p.y, other._p.y)
            and _bytes_eq(self._p.n, other._p.n)
            and _bytes_eq(self._p.e, other._p.e)
            and _opt_eq(self._p.kid, other._p.kid)
            and _opt_eq(self._p.alg, other._p.alg)
            and _opt_eq(self._p.key_use, other._p.key_use)
        )

    def __ne__(self, other: Self) -> Bool:
        return not self == other

    def write_json(self, mut buf: List[UInt8]):
        """Append the canonical JSON object of this key to `buf` (see the
        file header for the member order)."""
        _lit(buf, '{"kty":')
        write_json_string(buf, self._p.kty)
        if self._p.kty != JWK_KTY_RSA:
            _lit(buf, ',"crv":')
            write_json_string(buf, self._p.crv)
        if self._p.alg:
            _lit(buf, ',"alg":')
            write_json_string(buf, self._p.alg.value())
        if self._p.key_use:
            _lit(buf, ',"use":')
            write_json_string(buf, self._p.key_use.value())
        if self._p.kid:
            _lit(buf, ',"kid":')
            write_json_string(buf, self._p.kid.value())
        if self._p.kty == JWK_KTY_RSA:
            _b64_member(buf, "n", self._p.n)
            _b64_member(buf, "e", self._p.e)
        else:
            _b64_member(buf, "x", self._p.x)
            if self._p.kty == JWK_KTY_EC:
                _b64_member(buf, "y", self._p.y)
        buf.append(0x7D)  # '}'


def _lit(mut buf: List[UInt8], s: String):
    buf.extend(Span(s.as_bytes()))


def _b64_member(mut buf: List[UInt8], name: String, b: List[UInt8]):
    _lit(buf, ',"')
    _lit(buf, name)
    _lit(buf, '":"')
    _lit(buf, base64_url_encode_nopad(Span(b)))
    buf.append(0x22)  # '"'


def render_jwk(key: Jwk) -> String:
    """The canonical JSON object of one key (public members only)."""
    var buf = List[UInt8]()
    key.write_json(buf)
    return String(unsafe_from_utf8=Span(buf))


def render_jwk_set(keys: List[Jwk]) -> String:
    """The RFC 7517 JWK Set `{"keys":[...]}` of `keys`, in list order, each
    rendered as `render_jwk` does. An empty list renders `{"keys":[]}`."""
    var buf = List[UInt8]()
    _lit(buf, '{"keys":[')
    for i in range(len(keys)):
        if i > 0:
            buf.append(0x2C)  # ','
        keys[i].write_json(buf)
    _lit(buf, "]}")
    return String(unsafe_from_utf8=Span(buf))
