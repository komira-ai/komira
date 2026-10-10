# =============================================================================
# komira_oauth/client.mojo: the `client_credentials` client with
#   `private_key_jwt` (RFC 6749 section 4.4, RFC 7523 section 2.2), and
#   `ClientCredentialSource`, which holds the access token it got and
#   refreshes it before it expires.
# =============================================================================
#
# The token endpoint is reached through `TokenEndpointTransport`, one method:
# `post_form(url, form)` POSTs the form body with `Content-Type:
# application/x-www-form-urlencoded` and returns the status and body. The
# package holds no HTTP stack; a test passes a scripted one, and a service
# passes one over its HTTP client.
#
# `fetch_client_credentials_token(transport, signer, ...)` mints a client
# assertion with komira_jose's `mint_client_assertion` (`iss = sub =
# client_id`, `aud` = `assertion_audience`, the issuer identifier or the token
# endpoint URL, a lifetime of `OAUTH_ASSERTION_TTL_S`, a random 128-bit `jti`),
# POSTs `ClientCredentialsRequest.form()` (token_wire.mojo) to the token
# endpoint, and reads a 200 answer with `parse_token_response`. Every
# failure raises a fixed `OAuthError: ...` text:
#   * the transport raises: `the token request failed` (the transport's own
#     text is dropped: it may hold the request, and the request holds the
#     assertion);
#   * any status but 200: `the token endpoint answered <status>`, followed by
#     the error code when `oauth_error_code` reads one;
#   * a 200 whose body `parse_token_response` refuses: its text.
# No text carries the assertion, the access token or a byte of a body.
#
# `ClientCredentialSource[T]` is one client asking for one resource:
#   * `access_token(now)` fetches on first use, and serves the token it holds
#     while `now < expires_at - OAUTH_REFRESH_SKEW_S` (60 s), where
#     `expires_at` is the time of the request plus the answer's `expires_in`;
#     from `expires_at - 60` on it fetches again;
#   * the source stops holding its token before every fetch, so when a fetch
#     fails the call raises and the source holds nothing: a failed refresh never serves
#     the former token, though it may not have expired yet, and a token past
#     its `exp` is never served. The next call fetches again;
#   * `access_token` takes `mut self`, so one source has at most one fetch in
#     flight; a service holds one source per (client, resource).
# A token with `expires_in` of 60 s or less is fetched for every call.
#
# ENCAPSULATION: values in and out; the signer is moved in and never leaves.
# `transport()` is a `ref` to the transport the source owns, for tests that
# inspect what it sent. No pointer crosses this file's API.
# =============================================================================

from komira_jose import (
    JWS_ALG_EDDSA,
    JWS_ALG_ES256,
    JwsSigner,
    mint_client_assertion,
)

from komira_oauth._text import _https_url_refusal, _refuse, _scope_refusal
from komira_oauth.token_wire import (
    OAUTH_MAX_TOKEN_LIFETIME_S,
    ClientCredentialsRequest,
    TokenResponse,
    oauth_error_code,
    parse_token_response,
)


# The lifetime of a client assertion this client mints, in seconds.
comptime OAUTH_ASSERTION_TTL_S: Int64 = 60
# How long before `expires_at` a held token is fetched again, in seconds.
comptime OAUTH_REFRESH_SKEW_S: Int64 = 60


@fieldwise_init
struct TokenEndpointReply(Copyable, Movable):
    """A token endpoint's answer: the HTTP status and the body."""

    var status: Int
    var body: String


trait TokenEndpointTransport(Movable, Deinitable):
    """How a client reaches a token endpoint (see the file header)."""

    def post_form(mut self, url: String, form: String) raises -> TokenEndpointReply:
        """POST `form` as `application/x-www-form-urlencoded` to `url`.
        Raises only when no answer came."""
        ...


def _check_client(
    signer: JwsSigner,
    client_id: String,
    token_endpoint: String,
    assertion_audience: String,
    resource: String,
    scope: String,
) raises:
    if client_id.byte_length() == 0:
        _refuse("the client_id is empty")
    var why = _https_url_refusal(token_endpoint, True)
    if why != "":
        _refuse("the token endpoint " + why)
    if assertion_audience.byte_length() == 0:
        _refuse("the assertion audience is empty")
    if resource.byte_length() == 0:
        _refuse("the resource is empty")
    if scope.byte_length() > 0 and _scope_refusal(scope) != "":
        _refuse("the scope is not a scope")
    var alg = signer.alg()
    if alg != JWS_ALG_ES256 and alg != JWS_ALG_EDDSA:
        _refuse("the client key must sign ES256 or EdDSA")


def fetch_client_credentials_token[
    T: TokenEndpointTransport
](
    mut transport: T,
    signer: JwsSigner,
    *,
    client_id: String,
    token_endpoint: String,
    assertion_audience: String,
    resource: String,
    scope: String,
    now: Int64,
) raises -> TokenResponse:
    """One token request (see the file header). `scope` is "" to ask for
    the client's default. Raises `OAuthError: ...` for an empty
    `client_id`, `assertion_audience` or `resource`, a token endpoint that
    is not an https URL, a scope that is not one, a signer that is not
    ES256 or EdDSA, and every failure the header lists; and `JoseError:
    ...` for a time the assertion mint refuses."""
    _check_client(
        signer, client_id, token_endpoint, assertion_audience, resource, scope
    )
    var assertion = mint_client_assertion(
        signer,
        client_id=client_id,
        audience=assertion_audience,
        now=now,
        ttl_s=OAUTH_ASSERTION_TTL_S,
    )
    var form = ClientCredentialsRequest(
        client_assertion=assertion, resource=resource, scope=scope
    ).form()
    var reply: TokenEndpointReply
    try:
        reply = transport.post_form(token_endpoint, form)
    except:
        raise Error("OAuthError: the token request failed")
    if reply.status != 200:
        var msg = String("OAuthError: the token endpoint answered ") + String(
            reply.status
        )
        var code = oauth_error_code(reply.body)
        if code != "":
            msg += String(" ") + code
        raise Error(msg)
    return parse_token_response(reply.body)


struct ClientCredentialSource[T: TokenEndpointTransport](Movable):
    """The access token of one client for one resource, refreshed before it
    expires (see the file header)."""

    var _transport: Self.T
    var _signer: JwsSigner
    var _client_id: String
    var _token_endpoint: String
    var _assertion_audience: String
    var _resource: String
    var _scope: String
    var _token: String
    var _expires_at: Int64
    var _held: Bool

    def __init__(
        out self,
        var transport: Self.T,
        var signer: JwsSigner,
        *,
        client_id: String,
        token_endpoint: String,
        assertion_audience: String,
        resource: String,
        scope: String,
    ) raises:
        """A source that asks `token_endpoint` for tokens for `resource`,
        authenticating with `signer`'s key. Raises as
        `fetch_client_credentials_token` does for its arguments."""
        _check_client(
            signer,
            client_id,
            token_endpoint,
            assertion_audience,
            resource,
            scope,
        )
        self._transport = transport^
        self._signer = signer^
        self._client_id = client_id.copy()
        self._token_endpoint = token_endpoint.copy()
        self._assertion_audience = assertion_audience.copy()
        self._resource = resource.copy()
        self._scope = scope.copy()
        self._token = String("")
        self._expires_at = 0
        self._held = False

    def transport(ref self) -> ref [self._transport] Self.T:
        """The transport this source owns."""
        return self._transport

    def access_token(mut self, now: Int64) raises -> String:
        """A token for the resource at time `now` (seconds since the epoch;
        see the file header). Raises `OAuthError: ...` when a fetch is due
        and fails, and for a negative `now` or one so late that the expiry
        would not fit an Int64."""
        if now < 0:
            _refuse("the time is negative")
        if now > Int64.MAX - OAUTH_MAX_TOKEN_LIFETIME_S:
            _refuse("the time is too late for a token expiry")
        if self._held and now < self._expires_at - OAUTH_REFRESH_SKEW_S:
            return self._token.copy()
        self._held = False
        var r = fetch_client_credentials_token(
            self._transport,
            self._signer,
            client_id=self._client_id,
            token_endpoint=self._token_endpoint,
            assertion_audience=self._assertion_audience,
            resource=self._resource,
            scope=self._scope,
            now=now,
        )
        self._token = r.access_token.copy()
        self._expires_at = now + r.expires_in
        self._held = True
        return self._token.copy()
