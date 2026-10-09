# =============================================================================
# komira_jose/claims.mojo: verify a JWT (RFC 7519) under a `ClaimPolicy`:
#   the JWS checks of verifier.mojo with `typ` pinned and `kid` required,
#   then the registered claims.
# =============================================================================
#
# `typ` is checked in the header gate, before any key work, against the ONE
# type of the policy (`at+jwt`, RFC 9068, or `JWT`): a policy never accepts
# a set of types. The claims are read only after the signature verifies,
# from the payload decoded out of its signed segment, and refused (each with
# a fixed `JoseError: ...` text, in this order) when:
#
#   * the payload is not a JSON object, or names a member twice at any depth
#     (RFC 7519 section 4);
#   * `iss` is not a string equal to the policy issuer, byte for byte;
#   * `aud` is neither a string equal to the policy audience nor a non-empty
#     array of strings that contains it;
#   * `sub` is not a non-empty string;
#   * `exp` or `iat` is missing, or `exp`, `iat` or a present `nbf` is not a
#     non-negative integer (no fraction, exponent, sign or string);
#   * with `now` and `leeway_s` from the policy: `exp <= now - leeway_s`
#     (expired; the same as `now >= exp + leeway_s`), `iat > now + leeway_s`,
#     or `nbf > now + leeway_s`;
#   * `exp - iat` is not positive, or is above the policy's `max_ttl_s`.
#
# Other claims are kept and returned untouched; the caller reads what it
# configured. No message carries any byte of the token.
# =============================================================================

from komira_json import (
    JSON_ARRAY,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_int64_text,
    parse_json_bytes,
    refuse_duplicate_keys,
)

from komira_jose.verifier import JwsVerifier


comptime JWT_TYP_AT_JWT: String = "at+jwt"
comptime JWT_TYP_JWT: String = "JWT"
# The largest clock skew a policy may forgive, in seconds.
comptime JOSE_MAX_LEEWAY_S: Int64 = 60
# The largest token lifetime (`exp - iat`) a policy may allow, in seconds.
comptime JOSE_MAX_TTL_S: Int64 = 86400
comptime _JOSE_PAYLOAD_MAX_DEPTH: Int = 16


def _refuse(reason: String) raises:
    raise Error(String("JoseError: ") + reason)


struct ClaimPolicy(Copyable, Movable):
    """What a JWT must claim to pass: one issuer, our audience, one header
    type, the current time in seconds since the epoch, the clock skew
    forgiven, and the longest lifetime accepted."""

    var _issuer: String
    var _audience: String
    var _accept_typ: String
    var _now: Int64
    var _leeway_s: Int64
    var _max_ttl_s: Int64

    def __init__(
        out self,
        *,
        issuer: String,
        audience: String,
        accept_typ: String,
        now: Int64,
        leeway_s: Int64,
        max_ttl_s: Int64,
    ) raises:
        """Raises `JoseError: ...` for an empty issuer or audience, a type
        other than `at+jwt` or `JWT`, a negative time, a leeway outside 0 to
        `JOSE_MAX_LEEWAY_S`, or a max TTL outside 1 to `JOSE_MAX_TTL_S`."""
        if issuer.byte_length() == 0:
            _refuse("the policy issuer is empty")
        if audience.byte_length() == 0:
            _refuse("the policy audience is empty")
        if accept_typ != JWT_TYP_AT_JWT and accept_typ != JWT_TYP_JWT:
            _refuse("the policy typ must be at+jwt or JWT")
        if now < 0:
            _refuse("the policy time is negative")
        if leeway_s < 0 or leeway_s > JOSE_MAX_LEEWAY_S:
            _refuse("the policy leeway must be 0 to 60 seconds")
        if max_ttl_s < 1 or max_ttl_s > JOSE_MAX_TTL_S:
            _refuse("the policy max TTL must be 1 to 86400 seconds")
        self._issuer = issuer.copy()
        self._audience = audience.copy()
        self._accept_typ = accept_typ.copy()
        self._now = now
        self._leeway_s = leeway_s
        self._max_ttl_s = max_ttl_s

    def with_now(self, now: Int64) raises -> ClaimPolicy:
        """This policy at another time (a verifier built once checks each
        token at the time it arrives). Raises for a negative time."""
        return ClaimPolicy(
            issuer=self._issuer,
            audience=self._audience,
            accept_typ=self._accept_typ,
            now=now,
            leeway_s=self._leeway_s,
            max_ttl_s=self._max_ttl_s,
        )

    def issuer(self) -> String:
        return self._issuer.copy()

    def audience(self) -> String:
        return self._audience.copy()

    def accept_typ(self) -> String:
        return self._accept_typ.copy()

    def now(self) -> Int64:
        return self._now

    def leeway_s(self) -> Int64:
        return self._leeway_s

    def max_ttl_s(self) -> Int64:
        return self._max_ttl_s


struct VerifiedJwt(Copyable, Movable):
    """A JWT that passed the verifier and the policy: the checked claims and
    the whole claims object."""

    var issuer: String
    var subject: String
    var audience: String
    var kid: String
    var exp: Int64
    var iat: Int64
    var nbf: Optional[Int64]
    var claims: JsonValue

    def __init__(
        out self,
        *,
        var issuer: String,
        var subject: String,
        var audience: String,
        var kid: String,
        exp: Int64,
        iat: Int64,
        nbf: Optional[Int64],
        var claims: JsonValue,
    ):
        self.issuer = issuer^
        self.subject = subject^
        self.audience = audience^
        self.kid = kid^
        self.exp = exp
        self.iat = iat
        self.nbf = nbf
        self.claims = claims^


def _member(obj: JsonValue, name: String) -> Int:
    for i in range(len(obj.obj_keys)):
        if obj.obj_keys[i] == name:
            return i
    return -1


def _string_claim(obj: JsonValue, name: String) -> Optional[String]:
    var at = _member(obj, name)
    if at < 0 or obj.children[at].kind != JSON_STRING:
        return Optional[String]()
    return Optional[String](obj.children[at].text.copy())


def _int_claim(obj: JsonValue, name: String) raises -> Optional[Int64]:
    """None when absent; raises when present and not a non-negative
    integer."""
    var at = _member(obj, name)
    if at < 0:
        return Optional[Int64]()
    ref v = obj.children[at]
    var ok = v.kind == JSON_NUMBER and v.is_integral_number()
    if ok:
        var b = v.text.as_bytes()
        ok = len(b) > 0 and b[0] != UInt8(0x2D)  # '-'
    if ok:
        try:
            return Optional[Int64](parse_int64_text(v.text))
        except:
            pass
    raise Error(
        String("JoseError: claim ") + name + " is not a non-negative integer"
    )


def _required_int(obj: JsonValue, name: String) raises -> Int64:
    var v = _int_claim(obj, name)
    if not v:
        _refuse(String("claim ") + name + " is missing")
    return v.value()


def _audience_matches(obj: JsonValue, audience: String) raises -> Bool:
    var at = _member(obj, "aud")
    if at < 0:
        _refuse("claim aud is missing")
    ref aud = obj.children[at]
    if aud.kind == JSON_STRING:
        return aud.text == audience
    if aud.kind != JSON_ARRAY or len(aud.children) == 0:
        _refuse("claim aud is not a string or a non-empty array of strings")
    var found = False
    for i in range(len(aud.children)):
        if aud.children[i].kind != JSON_STRING:
            _refuse("claim aud is not a string or a non-empty array of strings")
        if aud.children[i].text == audience:
            found = True
    return found


def verify_jwt(
    token: String, verifier: JwsVerifier, policy: ClaimPolicy
) raises -> VerifiedJwt:
    """Verify `token` with `verifier` (its one algorithm and keys), the
    header `typ` pinned to the policy type and `kid` required, then check
    its claims against `policy` (see the file header)."""
    var jws = verifier.verify_with_typ(
        token, Optional[String](policy._accept_typ.copy()), True
    )
    var claims: JsonValue
    try:
        claims = parse_json_bytes(jws.payload(), _JOSE_PAYLOAD_MAX_DEPTH)
    except:
        raise Error("JoseError: the payload is not JSON")
    if claims.kind != JSON_OBJECT:
        _refuse("the payload is not a JSON object")
    try:
        refuse_duplicate_keys(claims)
    except:
        _refuse("the payload names a member twice")
    var iss = _string_claim(claims, "iss")
    if not iss:
        _refuse("claim iss is missing or not a string")
    if iss.value() != policy._issuer:
        _refuse("claim iss is not the issuer")
    if not _audience_matches(claims, policy._audience):
        _refuse("claim aud does not name the audience")
    var sub = _string_claim(claims, "sub")
    if not sub or sub.value().byte_length() == 0:
        _refuse("claim sub is missing, empty or not a string")
    var exp = _required_int(claims, "exp")
    var iat = _required_int(claims, "iat")
    var nbf = _int_claim(claims, "nbf")
    if exp <= policy._now - policy._leeway_s:
        _refuse("the token has expired")
    if iat > policy._now + policy._leeway_s:
        _refuse("claim iat is in the future")
    if nbf and nbf.value() > policy._now + policy._leeway_s:
        _refuse("the token is not yet valid")
    if exp - iat <= 0:
        _refuse("claim exp is not after iat")
    if exp - iat > policy._max_ttl_s:
        _refuse("the token lives longer than the max TTL")
    return VerifiedJwt(
        issuer=iss.value(),
        subject=sub.value(),
        audience=policy._audience.copy(),
        kid=jws.kid().value(),
        exp=exp,
        iat=iat,
        nbf=nbf,
        claims=claims^,
    )
