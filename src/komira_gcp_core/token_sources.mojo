# =============================================================================
# komira_gcp_core/token_sources.mojo -- the production token fetchers
# =============================================================================
#
# Each is an `AccessTokenFetcher` (token.mojo): ONE fetch of a new token, which
# `CachingTokenSource` calls when its cached token is about to expire. Each
# builds its request with token_wire.mojo, sends it through a
# `GcpHttpTransport` (token_http.mojo) and reads the answer with
# `parse_token_response`:
#
#   MetadataServerFetcher[X]       the metadata server's token for the
#                                  default service account (GCE, Cloud Run,
#                                  GKE): plain HTTP.
#   ServiceAccountKeyFetcher[X, W] a service-account key: the RS256 JWT
#                                  bearer grant to the key's token URI,
#                                  signed at `W`'s wall-clock time.
#   SelfSignedJwtFetcher[W]        a service-account key's self-signed JWT,
#                                  the bearer token itself: no exchange.
#   AuthorizedUserFetcher[X]       an authorized_user file's refresh-token
#                                  grant.
#
# None retries: a failed fetch raises, and the next request through the
# caching source fetches again. Every error names the endpoint (its URL) and
# never a credential.
# =============================================================================

from .token import AccessToken, AccessTokenFetcher
from .token_http import GcpHttpTransport, TokenHttpRequest, TokenHttpResponse
from .token_wire import (
    JWT_LIFETIME_SECONDS,
    AuthorizedUser,
    ServiceAccountKey,
    TokenEndpoint,
    authorized_user_refresh_request,
    jwt_grant_assertion,
    metadata_token_request,
    parse_token_response,
    self_signed_jwt,
    service_account_grant_request,
)
from .sources import WallClock


def _exchange[X: GcpHttpTransport](
    mut transport: X, req: TokenHttpRequest, what: String
) raises -> TokenHttpResponse:
    try:
        return transport.send(req)
    except e:
        raise Error(what + " could not be reached: " + String(e))


struct MetadataServerFetcher[X: GcpHttpTransport](
    AccessTokenFetcher, Movable, Deinitable
):
    """The default service account's token from the metadata server at
    `endpoint` (token_wire's `metadata_endpoint`), with `scopes` when any
    are given."""

    var _transport: Self.X
    var _endpoint: TokenEndpoint
    var _scopes: List[String]

    def __init__(
        out self,
        var transport: Self.X,
        var endpoint: TokenEndpoint,
        var scopes: List[String],
    ):
        self._transport = transport^
        self._endpoint = endpoint^
        self._scopes = scopes^

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        var what = String("the metadata server at ") + self._endpoint.url()
        var req = metadata_token_request(self._endpoint, self._scopes)
        var res = _exchange(self._transport, req, what)
        return parse_token_response(res, what, now_ms)

    def transport(mut self) -> ref [self._transport] Self.X:
        """The transport (a test reads its record through this)."""
        return self._transport


struct ServiceAccountKeyFetcher[X: GcpHttpTransport, W: WallClock](
    AccessTokenFetcher, Movable, Deinitable
):
    """A token for a service-account key: each fetch signs a new JWT bearer
    assertion at the wall clock's time and exchanges it at the key's token
    URI. `subject` names a user to act as (domain-wide delegation), or is
    empty."""

    var _transport: Self.X
    var _clock: Self.W
    var _key: ServiceAccountKey
    var _scopes: List[String]
    var _subject: String

    def __init__(
        out self,
        var transport: Self.X,
        var clock: Self.W,
        var key: ServiceAccountKey,
        var scopes: List[String],
        var subject: String = String(""),
    ) raises:
        if len(scopes) == 0:
            raise Error(
                "ServiceAccountKeyFetcher: the JWT bearer grant needs at least"
                " one scope"
            )
        self._transport = transport^
        self._clock = clock^
        self._key = key^
        self._scopes = scopes^
        self._subject = subject^

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        var what = String("the token endpoint ") + self._key.token_endpoint.url()
        var assertion = jwt_grant_assertion(
            self._key, self._scopes, self._subject, self._clock.now_unix_seconds()
        )
        var req = service_account_grant_request(self._key, assertion)
        var res = _exchange(self._transport, req, what)
        return parse_token_response(res, what, now_ms)

    def transport(mut self) -> ref [self._transport] Self.X:
        return self._transport


struct SelfSignedJwtFetcher[W: WallClock](AccessTokenFetcher, Movable, Deinitable):
    """A service-account key's self-signed JWT, used as the bearer token: no
    request is sent. It lives `JWT_LIFETIME_SECONDS` from the fetch."""

    var _clock: Self.W
    var _key: ServiceAccountKey
    var _audience: String
    var _scopes: List[String]

    def __init__(
        out self,
        var clock: Self.W,
        var key: ServiceAccountKey,
        var audience: String,
        var scopes: List[String],
    ) raises:
        if audience.byte_length() == 0 and len(scopes) == 0:
            raise Error("SelfSignedJwtFetcher: needs an audience or scopes")
        self._clock = clock^
        self._key = key^
        self._audience = audience^
        self._scopes = scopes^

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        var jwt = self_signed_jwt(
            self._key, self._audience, self._scopes, self._clock.now_unix_seconds()
        )
        return AccessToken.expiring_in(jwt^, now_ms, JWT_LIFETIME_SECONDS)


struct AuthorizedUserFetcher[X: GcpHttpTransport](
    AccessTokenFetcher, Movable, Deinitable
):
    """A token for an authorized_user file: the refresh-token grant at the
    file's token URI, with `scopes` when any are given."""

    var _transport: Self.X
    var _user: AuthorizedUser
    var _scopes: List[String]

    def __init__(
        out self,
        var transport: Self.X,
        var user: AuthorizedUser,
        var scopes: List[String],
    ):
        self._transport = transport^
        self._user = user^
        self._scopes = scopes^

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        var what = String("the token endpoint ") + self._user.token_endpoint.url()
        var req = authorized_user_refresh_request(self._user, self._scopes)
        var res = _exchange(self._transport, req, what)
        return parse_token_response(res, what, now_ms)

    def transport(mut self) -> ref [self._transport] Self.X:
        return self._transport
