# =============================================================================
# komira_azure_core/azure_token.mojo — AzureBearerToken + the token-response
#   reader
# =============================================================================
#
# The Azure OAuth2 access token, and the one reader of a token endpoint's
# answer shared by AzureImdsProvider (managed identity) and
# ServicePrincipalProvider (the Entra client-credentials grant).
#
# The answer is parsed as JSON (komira_json), so only the top-level members
# count: an `access_token` inside a nested object is not the token, and a
# string value is decoded the way JSON decodes it (`\"`, `\\`, `\uXXXX`).
# `expires_in` is read as a NUMBER or as a STRING of decimal digits, because
# the two endpoints disagree on its type: Azure IMDS sends "3599", the Entra
# token endpoint (login.microsoftonline.com) 3599.
#
# A refusal names the member and never repeats a body byte: the body of a
# token endpoint's answer holds the credential.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================

from komira_json import JsonValue, parse_json_bytes


# Deeper than any token response nests; a body that nests more is refused.
comptime _MAX_TOKEN_RESPONSE_DEPTH: Int = 8
# More decimal digits than any lifetime in seconds needs (Int64 holds 18).
comptime _MAX_EXPIRES_IN_DIGITS: Int = 12
# The largest expires_in accepted, in either form: the most 12 digits hold.
# The providers add `expires_in * 1000` to the clock in ms, which this keeps
# far inside Int64.
comptime _MAX_EXPIRES_IN_SECONDS: Int64 = 999_999_999_999


# -----------------------------------------------------------------------------
# AzureBearerToken — OAuth2 access token (managed identity / service principal)
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureBearerToken(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """An OAuth2 bearer token for Azure Storage (the audience is
    https://storage.azure.com/). Returned by managed-identity / service-
    principal providers.

    Field layout:
      var token: String              — the access_token string
      var expiry_ms: Int64           — ms on the issuing provider's
                                       MonotonicClock; -1 if unknown
    """

    var token: String
    var expiry_ms: Int64

    @always_inline
    def is_empty(self) -> Bool:
        """True iff this is the empty / anonymous sentinel (token == "")."""
        return self.token.byte_length() == 0


# -----------------------------------------------------------------------------
# OAuthTokenResponse — a 2xx token endpoint answer, read
# -----------------------------------------------------------------------------


@fieldwise_init
struct OAuthTokenResponse(Copyable, Movable, Deinitable):
    """The members of a token endpoint's answer the providers use.

    Field layout:
      var access_token: String  — non-empty
      var expires_in: Int64     — seconds, positive
      var token_type: String    — as sent; "Bearer" when absent
    """

    var access_token: String
    var expires_in: Int64
    var token_type: String


def _is_decimal_digits(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > _MAX_EXPIRES_IN_DIGITS:
        return False
    for i in range(len(b)):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return False
    return True


def _is_bearer(s: String) -> Bool:
    """`Bearer`, compared case-insensitively (RFC 6749 section 5.1)."""
    var b = s.as_bytes()
    var want = String("bearer").as_bytes()
    if len(b) != len(want):
        return False
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            c += UInt8(32)
        if c != want[i]:
            return False
    return True


def _refuse_repeated(doc: JsonValue, member: String) raises:
    """Refuse a body naming `member` more than once: JSON leaves a repeated
    name undefined, and parsers disagree on which one wins."""
    var seen = 0
    for i in range(doc.num_members()):
        if doc.key_at(i) == member:
            seen += 1
    if seen > 1:
        raise Error("the token response repeats " + member)


def parse_oauth_token_response(body: List[UInt8]) raises -> OAuthTokenResponse:
    """Read a 2xx token endpoint answer
    (`{"access_token", "expires_in", "token_type", ...}`); other members are
    ignored.

    Refused, naming the member and never its value: a body that is not JSON
    or not a JSON object; an `access_token` that is absent, not a string or
    empty; an `expires_in` that is absent, or is neither a whole JSON number
    nor a string of decimal digits, or is not positive; a `token_type` that
    is present and is not the string `Bearer` (in any case); any of those
    three members appearing more than once.

    `expires_in` is at most 999999999999 seconds in either form, so a
    caller can add it, in ms, to the clock without overflow."""
    var doc: JsonValue
    try:
        doc = parse_json_bytes(body, _MAX_TOKEN_RESPONSE_DEPTH)
    except:
        # The parser's message names a position only, but the body is a
        # credential: say no more than that it is not JSON.
        raise Error("the token response is not JSON")
    if not doc.is_object():
        raise Error("the token response is not a JSON object")
    _refuse_repeated(doc, String("access_token"))
    _refuse_repeated(doc, String("expires_in"))
    _refuse_repeated(doc, String("token_type"))
    if not doc.has(String("access_token")) or not doc.get(
        String("access_token")
    ).is_string():
        raise Error("the token response has no access_token string")
    var token = doc.get(String("access_token")).as_string()
    if token.byte_length() == 0:
        raise Error("the token response's access_token is empty")
    if not doc.has(String("expires_in")):
        raise Error("the token response has no expires_in")
    var exp = doc.get(String("expires_in"))
    var whole = exp.is_integral_number() or (
        exp.is_string() and _is_decimal_digits(exp.as_string())
    )
    var expires_in = Int64(0)
    if whole:
        try:
            expires_in = exp.as_int64()
        except:
            expires_in = Int64(0)  # outside Int64: refused below
    if expires_in <= 0 or expires_in > _MAX_EXPIRES_IN_SECONDS:
        raise Error(
            "the token response's expires_in is not a positive whole number"
            " of seconds"
        )
    var token_type = String("Bearer")
    if doc.has(String("token_type")):
        var tt = doc.get(String("token_type"))
        if not tt.is_string() or not _is_bearer(tt.as_string()):
            raise Error("the token response's token_type is not Bearer")
        token_type = tt.as_string()
    return OAuthTokenResponse(token^, expires_in, token_type^)
