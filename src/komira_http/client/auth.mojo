# =============================================================================
# src/komira_http/client/auth.mojo — pluggable request-auth seam (AuthProvider)
# =============================================================================
#
# Request-auth seam. A small, reactor-free abstraction for
# injecting per-request authentication into an outbound request, decoupled
# from the client's I/O model. Rather than baking a single auth scheme (e.g.
# bearer) into HttpClient.send, auth is a PLUGGABLE provider that decorates a
# request's `HeaderMap`:
#
#   trait AuthProvider:  fn apply(self, mut headers: HeaderMap) raises
#
# The shape is an interface like `AuthProvider.apply(request)` with a
# `BearerTokenProvider` impl. It keeps the
# client generic for future SigV4 / mTLS / Basic providers — each conforms to
# AuthProvider and is composed at the request-build site (or, later, wrapped in
# a tower-style SigningLayer).
#
# WHY HeaderMap, not the whole request: the only thing every request-auth
# scheme needs to do at the wire seam is add/replace headers (Authorization,
# X-Amz-*, Proxy-Authorization, ...). Operating on the HeaderMap keeps this
# module free of any dependency on the reactor / Runtime / Connector — it is a
# pure header decorator, usable both by the async HttpClient AND by synchronous
# callers (e.g. komira_k8s) that frame their own requests but want the same
# auth seam + the same rotation semantics.
#
# TOKEN ROTATION (the k8s-critical property): BearerTokenProvider is parametric
# on a `BearerTokenSource` trait whose `fetch_token()` is invoked on EVERY
# `apply`. A source that re-reads a file (the projected-SA-token path) therefore
# picks up a rotated token on every request with no caching. A static source
# (StaticTokenSource) returns the same value each call for fixed-token callers.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO take_pointee / ArcPointer / additive-parallel-API.
#   * Token Strings are OWNED (returned by value); no borrowed/dangling slice
#     crosses the seam (use-after-free discipline).
# =============================================================================

from komira_http.client.header_map import HeaderMap


# =============================================================================
# §1 — BearerTokenSource trait — where a bearer token comes from, per request.
# =============================================================================
trait BearerTokenSource(Movable, Deinitable):
    """A source of bearer-token strings. `fetch_token()` is invoked ONCE per
    request (per `BearerTokenProvider.apply`), so a rotating source (file
    re-read, STS refresh) returns the live value each call without any caching
    in the provider.

    The return is an OWNED String — no borrowed slice escapes the source (UAF
    discipline). `raises` so a source that does file IO / network refresh can
    surface a failure to the request path.
    """

    def fetch_token(self) raises -> String:
        ...


# =============================================================================
# §2 — StaticTokenSource — a fixed bearer token (no rotation).
# =============================================================================
@fieldwise_init
struct StaticTokenSource(BearerTokenSource, Movable, Deinitable):
    """A `BearerTokenSource` that returns the same token every call. For
    fixed-token callers (a long-lived API key, a test). Rotating callers (the
    projected-SA-token path) supply their own re-reading source instead.
    """

    var _token: String

    def fetch_token(self) raises -> String:
        return self._token


# =============================================================================
# §3 — AuthProvider trait — decorate an outbound request's headers.
# =============================================================================
trait AuthProvider(Movable, Deinitable):
    """The pluggable request-auth seam. `apply` mutates the request's
    `HeaderMap` to add (or replace) whatever auth headers the scheme needs,
    immediately before the request is serialized to the wire.

    Conformers: `BearerTokenProvider[S]` (this module). Future: `SigV4Provider`,
    `BasicAuthProvider`, `MTlsProvider` (mTLS is connector-level, but a provider
    can still set a routing header). Each is composed at the request-build site;
    a no-auth path simply skips the provider.
    """

    def apply(self, mut headers: HeaderMap) raises:
        ...


# =============================================================================
# §4 — BearerTokenProvider — `Authorization: Bearer <token>` per request.
# =============================================================================
struct BearerTokenProvider[S: BearerTokenSource](
    AuthProvider, Movable, Deinitable
):
    """`AuthProvider` that sets `Authorization: Bearer <token>` where the token
    is pulled FRESH from the parametric `S: BearerTokenSource` on every `apply`.

    The token is fetched per request (no provider-side cache), so a rotating
    source picks up a new token automatically — the projected-SA-token rotation
    property the K8s in-cluster client needs.

    Header semantics: `insert` (REPLACE) not `append` — a request must carry at
    most one Authorization header; re-applying the provider (e.g. on a retry
    with a rotated token) overwrites the stale one rather than duplicating it.
    """

    var _source: Self.S

    def __init__(out self, var source: Self.S):
        self._source = source^

    @staticmethod
    def over(var source: Self.S) -> Self:
        """Convenience ctor — `BearerTokenProvider.over(source)`."""
        return Self(source^)

    def apply(self, mut headers: HeaderMap) raises:
        """Set `Authorization: Bearer <token>`, replacing any existing
        Authorization header. The token is re-fetched from the source on every
        call (rotation)."""
        var token = self._source.fetch_token()
        headers.insert(String("Authorization"), String("Bearer ") + token^)
