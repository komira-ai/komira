# =============================================================================
# komira_test_issuer/user_token.mojo: the claims of a user access token in
#   the shape the HTTP auth design describes (RFC 9068 access tokens).
# =============================================================================
#
# `user_token_claims` writes exactly
#
#   {"iss":..,"sub":..,"aud":..,"iat":now,"exp":now+ttl_s,"jti":..,
#    "client_id":..,"scope":..}
#
# in that order, with `"scope"` left out when `scope` is empty. `aud` is one
# string (the audience the token is for); `client_id` is the client the token
# was issued to; `scope` is space-delimited, written as given.
#
# Refused, each with a fixed `TestIssuerError: ...` text: an empty issuer,
# subject, audience, `client_id` or `jti`; a negative time; a lifetime
# outside 1 to `JOSE_MAX_TTL_S` (86400) seconds; and a time so late that
# `now + ttl_s` would not fit an Int64.
#
# ENCAPSULATION: `String` and `Int64` in, `String` out. No pointer crosses
# this file's API.
# =============================================================================

from komira_jose import JOSE_MAX_TTL_S
from komira_json import write_i64_dec, write_json_string


def _refuse(reason: String) raises:
    raise Error(String("TestIssuerError: ") + reason)


def _lit(mut buf: List[UInt8], s: String):
    buf.extend(Span(s.as_bytes()))


def user_token_claims(
    *,
    issuer: String,
    subject: String,
    audience: String,
    client_id: String,
    scope: String,
    now: Int64,
    ttl_s: Int64,
    jti: String,
) raises -> String:
    """The claims object of a user access token (see the file header).
    Raises `TestIssuerError: ...` for any input the header lists."""
    if issuer.byte_length() == 0:
        _refuse("the token issuer is empty")
    if subject.byte_length() == 0:
        _refuse("the token subject is empty")
    if audience.byte_length() == 0:
        _refuse("the token audience is empty")
    if client_id.byte_length() == 0:
        _refuse("the token client_id is empty")
    if jti.byte_length() == 0:
        _refuse("the token jti is empty")
    if now < 0:
        _refuse("the token time is negative")
    if ttl_s < 1 or ttl_s > JOSE_MAX_TTL_S:
        _refuse("the token lifetime must be 1 to 86400 seconds")
    if now > Int64.MAX - ttl_s:
        _refuse("the token expiry does not fit a 64-bit integer")
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
    _lit(buf, ',"client_id":')
    write_json_string(buf, client_id)
    if scope.byte_length() > 0:
        _lit(buf, ',"scope":')
        write_json_string(buf, scope)
    buf.append(0x7D)  # '}'
    return String(unsafe_from_utf8=Span(buf))
