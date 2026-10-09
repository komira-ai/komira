# =============================================================================
# komira_jose/assertion.mojo: JWT bearer assertions (RFC 7523): mint one
#   with a `JwsSigner`, and verify one with a `JwsVerifier` and a
#   `ClaimPolicy`. Every assertion carries a `jti`.
# =============================================================================
#
# Mint (`mint_assertion`, and `mint_client_assertion` for client
# authentication, RFC 7523 section 2.2, where `iss` and `sub` are both the
# client id): the header is the signer's with `typ` `JWT`, and the claims
# are exactly
#
#   {"iss":..,"sub":..,"aud":..,"iat":now,"exp":now+ttl_s,"jti":..}
#
# in that order. `jti` is 16 bytes (128 bits) from AWS-LC's random source,
# base64url without padding: a caller cannot choose or omit it. `iss`, `sub`
# and `aud` must be non-empty, `now` non-negative, and `ttl_s` 1 to
# `JOSE_ASSERTION_MAX_TTL_S` (300) seconds.
#
# Verify (`verify_assertion`): `verify_jwt` with the policy (its one issuer,
# audience, `typ`, time, leeway and max TTL; RFC 7523 section 3 items 1 to
# 5), then `jti` must be a non-empty string (RFC 7523 makes `jti` optional;
# this package requires it, so a replay check always has a key).
# `verify_client_assertion` also requires `sub` to equal `iss`, byte for
# byte. Remembering a `jti` until its `exp` to refuse a replay is the
# caller's: it is the one that sees every assertion.
#
# Every refusal raises `JoseError: <fixed text>`; no text carries any byte
# of the token.
#
# ENCAPSULATION: `String` and the package's own types in and out. No
# pointer crosses this file's API.
# =============================================================================

from komira_crypto import system_entropy
from komira_encoding import base64_url_encode_nopad
from komira_json import write_i64_dec, write_json_string

from komira_jose.claims import (
    JWT_TYP_JWT,
    ClaimPolicy,
    VerifiedJwt,
    _string_claim,
    verify_jwt,
)
from komira_jose.signer import JwsSigner
from komira_jose.verifier import JwsVerifier


# The longest assertion lifetime `mint_assertion` accepts, in seconds.
comptime JOSE_ASSERTION_MAX_TTL_S: Int64 = 300
# The random bytes in a minted `jti`.
comptime JOSE_JTI_BYTES: Int = 16


def _refuse(reason: String) raises:
    raise Error(String("JoseError: ") + reason)


def _lit(mut buf: List[UInt8], s: String):
    buf.extend(Span(s.as_bytes()))


def new_jti() raises -> String:
    """A fresh `jti`: `JOSE_JTI_BYTES` random bytes, base64url without
    padding."""
    var b = List[UInt8](length=JOSE_JTI_BYTES, fill=UInt8(0))
    system_entropy(Span(b))
    return base64_url_encode_nopad(Span(b))


def assertion_claims(
    *,
    issuer: String,
    subject: String,
    audience: String,
    now: Int64,
    ttl_s: Int64,
    jti: String,
) raises -> String:
    """The claims object `mint_assertion` signs, with the given `jti`.
    Raises as `mint_assertion` does, and for an empty `jti`."""
    if issuer.byte_length() == 0:
        _refuse("the assertion issuer is empty")
    if subject.byte_length() == 0:
        _refuse("the assertion subject is empty")
    if audience.byte_length() == 0:
        _refuse("the assertion audience is empty")
    if now < 0:
        _refuse("the assertion time is negative")
    if ttl_s < 1 or ttl_s > JOSE_ASSERTION_MAX_TTL_S:
        _refuse("the assertion lifetime must be 1 to 300 seconds")
    if jti.byte_length() == 0:
        _refuse("the assertion jti is empty")
    var buf = List[UInt8]()
    _lit(buf, '{"iss":')
    write_json_string(buf, issuer)
    _lit(buf, ',"sub":')
    write_json_string(buf, subject)
    _lit(buf, ',"aud":')
    write_json_string(buf, audience)
    _lit(buf, ',"iat":')
    write_i64_dec(buf, now)
    _lit(buf, ',"exp":')
    write_i64_dec(buf, now + ttl_s)
    _lit(buf, ',"jti":')
    write_json_string(buf, jti)
    buf.append(0x7D)  # '}'
    return String(unsafe_from_utf8=Span(buf))


def mint_assertion(
    signer: JwsSigner,
    *,
    issuer: String,
    subject: String,
    audience: String,
    now: Int64,
    ttl_s: Int64,
) raises -> String:
    """An RFC 7523 assertion signed by `signer`, with a fresh random `jti`
    (see the file header). Raises `JoseError: ...` for an empty issuer,
    subject or audience, a negative time, or a lifetime outside 1 to 300
    seconds."""
    var claims = assertion_claims(
        issuer=issuer,
        subject=subject,
        audience=audience,
        now=now,
        ttl_s=ttl_s,
        jti=new_jti(),
    )
    return signer.sign(claims.as_bytes(), Optional[String](JWT_TYP_JWT))


def mint_client_assertion(
    signer: JwsSigner,
    *,
    client_id: String,
    audience: String,
    now: Int64,
    ttl_s: Int64,
) raises -> String:
    """A client authentication assertion (RFC 7523 section 2.2): `iss` and
    `sub` are `client_id`. Raises as `mint_assertion` does."""
    return mint_assertion(
        signer,
        issuer=client_id,
        subject=client_id,
        audience=audience,
        now=now,
        ttl_s=ttl_s,
    )


struct VerifiedAssertion(Copyable, Movable):
    """An assertion that passed: the verified JWT and its `jti`."""

    var jwt: VerifiedJwt
    var jti: String

    def __init__(out self, var jwt: VerifiedJwt, var jti: String):
        self.jwt = jwt^
        self.jti = jti^


def verify_assertion(
    token: String, verifier: JwsVerifier, policy: ClaimPolicy
) raises -> VerifiedAssertion:
    """`verify_jwt(token, verifier, policy)`, then a non-empty string `jti`
    is required."""
    var jwt = verify_jwt(token, verifier, policy)
    var jti = _string_claim(jwt.claims, "jti")
    if not jti or jti.value().byte_length() == 0:
        _refuse("claim jti is missing, empty or not a string")
    return VerifiedAssertion(jwt^, jti.value())


def verify_client_assertion(
    token: String, verifier: JwsVerifier, policy: ClaimPolicy
) raises -> VerifiedAssertion:
    """`verify_assertion`, then `sub` must equal `iss` (RFC 7523 section
    2.2: both are the client id; the policy pins `iss`)."""
    var a = verify_assertion(token, verifier, policy)
    if a.jwt.subject != a.jwt.issuer:
        _refuse("claim sub is not the client (iss)")
    return a^
