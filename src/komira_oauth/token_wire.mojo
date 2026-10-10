# =============================================================================
# komira_oauth/token_wire.mojo: the token endpoint's wire for the
#   `client_credentials` grant (RFC 6749 section 4.4) with `private_key_jwt`
#   client authentication (RFC 7521 section 4.2, RFC 7523 section 2.2) and a
#   `resource` (RFC 8707): the request, the answer and the error answer.
# =============================================================================
#
# REQUEST. `ClientCredentialsRequest.form()` writes, in this order,
#
#   grant_type=client_credentials
#   &client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
#   &client_assertion=<the compact JWS>&resource=<audience>[&scope=<scope>]
#
# (percent-encoded as form.mojo writes). `parse_client_credentials_request`
# reads one for a token endpoint and never raises: it returns a
# `ParsedTokenRequest` whose `error` is "" or the RFC 6749 section 5.2 code
# to answer with, beside a fixed `reason`. Checked in this order:
#   * the body is not a form (form.mojo)                    invalid_request
#   * a `client_secret` is sent beside the assertion (two
#     client authentication methods, RFC 7521 section 4.2)  invalid_client
#   * `grant_type` is missing                               invalid_request
#   * `grant_type` is not `client_credentials`              unsupported_grant_type
#   * `client_assertion_type` is missing or not the JWT
#     bearer URN                                            invalid_client
#   * `client_assertion` is missing or empty                invalid_client
#   * `client_id` is present and empty                      invalid_client
#   * `resource` is missing or empty                        invalid_target
#   * `scope` is present and not a scope (_text.mojo)       invalid_scope
# A `resource` is compared byte for byte with what the issuer allows; this
# codec does not check that it is an absolute URI (RFC 8707 asks for one; an
# audience that is a client id is not).
#
# ANSWER. `render_token_response` writes
#
#   {"access_token":..,"token_type":"Bearer","expires_in":N[,"scope":..]}
#
# and `parse_token_response` reads it, refusing (fixed `OAuthError: ...`
# texts, no byte of the body): a body longer than `OAUTH_RESPONSE_MAX_BYTES`
# or not a JSON object, a member named twice, an `access_token` that is
# missing, not a string or empty, a `token_type` other than `Bearer` (in any
# case, RFC 6749 section 5.1), an `expires_in` that is missing or not an
# integer from 1 to `OAUTH_MAX_TOKEN_LIFETIME_S` (RFC 6749 makes it
# RECOMMENDED; this profile requires it, so a client knows when to refresh),
# and a `scope` that is present and not a scope.
#
# ERROR. `render_oauth_error(code)` writes `{"error":"<code>"}` with no
# description. `oauth_error_code(body)` reads one for a message and never
# raises: the code when `error` is a string among `oauth_error_codes()`,
# `"not a known code"` for another string, and "" otherwise. No other byte
# of the body is ever returned.
#
# ENCAPSULATION: `String` in and out. No pointer crosses this file's API.
# =============================================================================

from komira_json import (
    JSON_NUMBER,
    JSON_STRING,
    parse_int64_text,
    write_i64_dec,
    write_json_string,
)

from komira_oauth._text import (
    _lit,
    _member,
    _optional_string,
    _parse_object,
    _refuse,
    _required_string,
    _scope_refusal,
)
from komira_oauth.form import FormParams, parse_form


comptime OAUTH_GRANT_CLIENT_CREDENTIALS: String = "client_credentials"
comptime OAUTH_ASSERTION_TYPE_JWT_BEARER: String = (
    "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
)
comptime OAUTH_TOKEN_TYPE_BEARER: String = "Bearer"
# The longest `expires_in` an answer may carry, in seconds (komira_jose's
# longest token lifetime).
comptime OAUTH_MAX_TOKEN_LIFETIME_S: Int64 = 86400
# The longest token endpoint answer `parse_token_response` reads, in bytes.
comptime OAUTH_RESPONSE_MAX_BYTES: Int = 65536

comptime OAUTH_ERROR_INVALID_REQUEST: String = "invalid_request"
comptime OAUTH_ERROR_INVALID_CLIENT: String = "invalid_client"
comptime OAUTH_ERROR_INVALID_GRANT: String = "invalid_grant"
comptime OAUTH_ERROR_UNAUTHORIZED_CLIENT: String = "unauthorized_client"
comptime OAUTH_ERROR_UNSUPPORTED_GRANT_TYPE: String = "unsupported_grant_type"
comptime OAUTH_ERROR_INVALID_SCOPE: String = "invalid_scope"
comptime OAUTH_ERROR_INVALID_TARGET: String = "invalid_target"


def oauth_error_codes() -> List[String]:
    """The error codes of RFC 6749 section 5.2 and `invalid_target` (RFC
    8707 section 2): the only codes this package writes or repeats."""
    var out = List[String]()
    out.append(OAUTH_ERROR_INVALID_REQUEST)
    out.append(OAUTH_ERROR_INVALID_CLIENT)
    out.append(OAUTH_ERROR_INVALID_GRANT)
    out.append(OAUTH_ERROR_UNAUTHORIZED_CLIENT)
    out.append(OAUTH_ERROR_UNSUPPORTED_GRANT_TYPE)
    out.append(OAUTH_ERROR_INVALID_SCOPE)
    out.append(OAUTH_ERROR_INVALID_TARGET)
    return out^


struct ClientCredentialsRequest(Copyable, Movable):
    """A `client_credentials` token request authenticated by a client
    assertion (see the file header). `scope` and `client_id` are "" when not
    sent."""

    var client_assertion: String
    var resource: String
    var scope: String
    var client_id: String

    def __init__(
        out self,
        *,
        client_assertion: String,
        resource: String,
        scope: String,
        client_id: String = "",
    ):
        self.client_assertion = client_assertion.copy()
        self.resource = resource.copy()
        self.scope = scope.copy()
        self.client_id = client_id.copy()

    def form(self) -> String:
        """The request body (see the file header); `client_id` is written
        after `client_assertion` when it is not empty."""
        var p = FormParams()
        p.add("grant_type", OAUTH_GRANT_CLIENT_CREDENTIALS)
        p.add("client_assertion_type", OAUTH_ASSERTION_TYPE_JWT_BEARER)
        p.add("client_assertion", self.client_assertion)
        if self.client_id.byte_length() > 0:
            p.add("client_id", self.client_id)
        p.add("resource", self.resource)
        if self.scope.byte_length() > 0:
            p.add("scope", self.scope)
        return p.encode()


struct ParsedTokenRequest(Copyable, Movable):
    """What `parse_client_credentials_request` read: `error` is "" and
    `request` is the request, or `error` is the code to answer with and
    `reason` a fixed text saying why."""

    var error: String
    var reason: String
    var request: ClientCredentialsRequest

    def __init__(
        out self,
        var error: String,
        var reason: String,
        var request: ClientCredentialsRequest,
    ):
        self.error = error^
        self.reason = reason^
        self.request = request^

    def ok(self) -> Bool:
        return self.error.byte_length() == 0


def _failed(code: String, reason: String) -> ParsedTokenRequest:
    return ParsedTokenRequest(
        code.copy(),
        reason.copy(),
        ClientCredentialsRequest(client_assertion="", resource="", scope=""),
    )


def parse_client_credentials_request(body: String) -> ParsedTokenRequest:
    """Read a token request body for the `client_credentials` grant with a
    client assertion (see the file header). Never raises."""
    var p: FormParams
    try:
        p = parse_form(body)
    except:
        return _failed(OAUTH_ERROR_INVALID_REQUEST, "the body is not a form")
    if p.get("client_secret"):
        return _failed(
            OAUTH_ERROR_INVALID_CLIENT, "two client authentication methods"
        )
    var grant = p.get("grant_type")
    if not grant:
        return _failed(OAUTH_ERROR_INVALID_REQUEST, "grant_type is missing")
    if grant.value() != OAUTH_GRANT_CLIENT_CREDENTIALS:
        return _failed(
            OAUTH_ERROR_UNSUPPORTED_GRANT_TYPE,
            "grant_type is not client_credentials",
        )
    var atype = p.get("client_assertion_type")
    if not atype or atype.value() != OAUTH_ASSERTION_TYPE_JWT_BEARER:
        return _failed(
            OAUTH_ERROR_INVALID_CLIENT,
            "client_assertion_type is not the JWT bearer type",
        )
    var assertion = p.get("client_assertion")
    if not assertion or assertion.value().byte_length() == 0:
        return _failed(
            OAUTH_ERROR_INVALID_CLIENT, "client_assertion is missing or empty"
        )
    var client_id = String("")
    var cid = p.get("client_id")
    if cid:
        if cid.value().byte_length() == 0:
            return _failed(OAUTH_ERROR_INVALID_CLIENT, "client_id is empty")
        client_id = cid.value()
    var resource = p.get("resource")
    if not resource or resource.value().byte_length() == 0:
        return _failed(
            OAUTH_ERROR_INVALID_TARGET, "resource is missing or empty"
        )
    var scope = String("")
    var sc = p.get("scope")
    if sc:
        if _scope_refusal(sc.value()) != "":
            return _failed(OAUTH_ERROR_INVALID_SCOPE, "scope is not a scope")
        scope = sc.value()
    return ParsedTokenRequest(
        String(""),
        String(""),
        ClientCredentialsRequest(
            client_assertion=assertion.value(),
            resource=resource.value(),
            scope=scope,
            client_id=client_id,
        ),
    )


struct TokenResponse(Copyable, Movable):
    """A token endpoint's answer: the access token, its lifetime in seconds
    from the answer, and the scope granted ("" when the answer names
    none)."""

    var access_token: String
    var expires_in: Int64
    var scope: String

    def __init__(
        out self, *, access_token: String, expires_in: Int64, scope: String
    ):
        self.access_token = access_token.copy()
        self.expires_in = expires_in
        self.scope = scope.copy()


def render_token_response(
    access_token: String, expires_in: Int64, scope: String
) -> String:
    """The answer's JSON (see the file header); `scope` is left out when
    empty."""
    var buf = List[UInt8]()
    _lit(buf, '{"access_token":')
    write_json_string(buf, access_token)
    _lit(buf, ',"token_type":"Bearer","expires_in":')
    write_i64_dec(buf, expires_in)
    if scope.byte_length() > 0:
        _lit(buf, ',"scope":')
        write_json_string(buf, scope)
    buf.append(0x7D)  # '}'
    return String(unsafe_from_utf8=Span(buf))


def _is_bearer(t: String) -> Bool:
    return t.lower() == "bearer"


def parse_token_response(body: String) raises -> TokenResponse:
    """Read a token endpoint's 200 answer (see the file header). Raises
    `OAuthError: ...`."""
    var obj = _parse_object(
        body, OAUTH_RESPONSE_MAX_BYTES, "the token response"
    )
    var token = _required_string(obj, "access_token")
    var ttype = _required_string(obj, "token_type")
    if not _is_bearer(ttype):
        _refuse("member token_type is not Bearer")
    var at = _member(obj, "expires_in")
    if at < 0:
        _refuse("member expires_in is missing")
    ref v = obj.children[at]
    var expires_in = Int64(0)
    var ok = v.kind == JSON_NUMBER and v.is_integral_number()
    if ok:
        try:
            expires_in = parse_int64_text(v.text)
        except:
            ok = False
    if not ok or expires_in < 1 or expires_in > OAUTH_MAX_TOKEN_LIFETIME_S:
        _refuse("member expires_in is not an integer from 1 to 86400")
    var scope = String("")
    var sc = _optional_string(obj, "scope")
    if sc:
        if _scope_refusal(sc.value()) != "":
            _refuse("member scope is not a scope")
        scope = sc.value()
    return TokenResponse(access_token=token, expires_in=expires_in, scope=scope)


def render_oauth_error(code: String) -> String:
    """`{"error":"<code>"}` (RFC 6749 section 5.2, no description)."""
    var buf = List[UInt8]()
    _lit(buf, '{"error":')
    write_json_string(buf, code)
    buf.append(0x7D)  # '}'
    return String(unsafe_from_utf8=Span(buf))


def oauth_error_code(body: String) -> String:
    """What an error answer's `error` says, for a message (see the file
    header). Never raises."""
    try:
        var obj = _parse_object(
            body, OAUTH_RESPONSE_MAX_BYTES, "the error response"
        )
        var at = _member(obj, "error")
        if at < 0 or obj.children[at].kind != JSON_STRING:
            return String("")
        var code = obj.children[at].text.copy()
        var known = oauth_error_codes()
        for i in range(len(known)):
            if known[i] == code:
                return code^
        return String("not a known code")
    except:
        return String("")
