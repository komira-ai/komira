# =============================================================================
# komira_gcp_core/token.mojo — access tokens and the token-source seam.
# =============================================================================
#
# `GcpTokenSource` is the contract the GENERATED REST clients are written
# against (proto-codegen `emit_rest.rs`, `GCP_TOKEN_SOURCE`): one call per
# request, returning the bare OAuth2 access token with no `Bearer ` prefix.
# Everything about where the token comes from is this package's business.
#
# The layering:
#   * `AccessTokenFetcher` — ONE round trip to a token endpoint (the metadata
#     server, a service-account JWT exchange, a workload-identity exchange).
#     Their pure request/response codecs are part P18a-2 and the fetchers
#     over komira_http's `Connector` are P18b; nothing here reads the
#     environment or opens a socket.
#   * `CachingTokenSource` — a `GcpTokenSource` over any fetcher and any
#     komira_retry `MonotonicClock` (`SystemClock` in production,
#     `ManualClock` in a test): it serves the cached token while it is
#     fresh and refetches `refresh_before_ms` BEFORE it expires, so a request
#     never carries a token that expires in flight. The clock is MONOTONIC on
#     purpose: every expiry here is relative (`expires_in` seconds from the
#     token endpoint), so a wall-clock step must not make a token look
#     fresher or older than it is.
#   * `StaticTokenSource` — a fixed token, for an emulator or a test.
#
# ⛔ A TOKEN IS A CREDENTIAL. Nothing in this file renders one: `AccessToken`
# has no `Writable`/`Stringable` conformance, and every error names the
# token's LENGTH and expiry, never its bytes.
# =============================================================================

from komira_retry import MonotonicClock


comptime DEFAULT_REFRESH_BEFORE_MS: Int64 = 225_000
"""Refetch a cached token this long before it expires: 3 minutes 45 seconds,
the `REFRESH_THRESHOLD` of Google's own auth library for Python
(`google/auth/_helpers.py`). A token used for one request after the check must
still be valid when the server reads it, and a slow request or a skewed server
clock eats into that margin."""


trait GcpTokenSource(Movable, Deinitable):
    """Where each request's bearer token comes from.

    `access_token` returns the BARE token (no `Bearer ` prefix). It may raise
    when no token can be obtained; the generated client lets that propagate.
    `Deinitable` is required because a generated client holds the source as a
    field of a `Deinitable` struct."""

    def access_token(mut self) raises -> String:
        """A currently valid access token, without a `Bearer ` prefix."""
        ...


@fieldwise_init
struct AccessToken(Copyable, Movable, Deinitable):
    """An OAuth2 access token and the instant, on the fetching `MonotonicClock`'s
    timeline, at which it stops being valid.

    It deliberately has no string conversion: a token is a credential, and a
    `print(token)` or an f-string must not compile."""

    var token: String
    var expires_at_ms: Int64

    @staticmethod
    def expiring_in(var token: String, now_ms: Int64, expires_in_s: Int64) -> AccessToken:
        """A token that a token endpoint issued at `now_ms` with
        `expires_in = expires_in_s` seconds (RFC 6749 §5.1)."""
        return AccessToken(token^, now_ms + expires_in_s * 1000)

    def is_fresh(self, now_ms: Int64, refresh_before_ms: Int64) -> Bool:
        """Whether the token can still be handed out at `now_ms`: it has bytes,
        and at least `refresh_before_ms` remain before it expires."""
        return (
            self.token.byte_length() > 0
            and now_ms + refresh_before_ms < self.expires_at_ms
        )

    def describe(self, now_ms: Int64) -> String:
        """A diagnostic that names the token's length and remaining life,
        never its bytes."""
        return (
            String("access token (")
            + String(self.token.byte_length())
            + " bytes, expires in "
            + String(self.expires_at_ms - now_ms)
            + " ms)"
        )


trait AccessTokenFetcher(Movable, Deinitable):
    """ONE fetch of a new access token from a token endpoint.

    `now_ms` is the caller's clock reading taken just before the request, so a
    relative `expires_in` from the endpoint lands on the same timeline the
    cache compares against."""

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        """Fetch a fresh token. May raise on any endpoint or transport fault."""
        ...


struct CachingTokenSource[F: AccessTokenFetcher, K: MonotonicClock](
    GcpTokenSource, Movable, Deinitable
):
    """A `GcpTokenSource` that caches the fetcher's token and refetches it
    `refresh_before_ms` before it expires.

    A fetch that returns a token which is ALREADY not fresh is refused rather
    than served or refetched in a loop: an endpoint answering with a token
    shorter-lived than the refresh margin is a misconfiguration to report."""

    var _fetcher: Self.F
    var _clock: Self.K
    var _refresh_before_ms: Int64
    var _cached: AccessToken
    var _has_cached: Bool
    var _fetches: Int

    def __init__(
        out self,
        var fetcher: Self.F,
        var clock: Self.K,
        refresh_before_ms: Int64 = DEFAULT_REFRESH_BEFORE_MS,
    ) raises:
        if refresh_before_ms < 0:
            raise Error(
                String("CachingTokenSource: refresh_before_ms must be >= 0, got ")
                + String(refresh_before_ms)
            )
        self._fetcher = fetcher^
        self._clock = clock^
        self._refresh_before_ms = refresh_before_ms
        self._cached = AccessToken(String(), Int64(0))
        self._has_cached = False
        self._fetches = 0

    def access_token(mut self) raises -> String:
        var now = self._clock.now_ms()
        if self._has_cached and self._cached.is_fresh(now, self._refresh_before_ms):
            return self._cached.token.copy()
        var fresh = self._fetcher.fetch(now)
        self._fetches += 1
        if not fresh.is_fresh(now, self._refresh_before_ms):
            # Drop any older token too: it was the reason we fetched.
            self._has_cached = False
            raise Error(
                String("CachingTokenSource: the token endpoint returned an unusable ")
                + fresh.describe(now)
                + "; it must outlive the "
                + String(self._refresh_before_ms)
                + " ms refresh margin"
            )
        self._cached = fresh^
        self._has_cached = True
        return self._cached.token.copy()

    def invalidate(mut self):
        """Forget the cached token, so the next request refetches (for a
        server that answered UNAUTHENTICATED to a token we thought fresh)."""
        self._has_cached = False

    def fetches(self) -> Int:
        """How many times the fetcher has been called."""
        return self._fetches

    def clock(mut self) -> ref [self._clock] Self.K:
        """The clock this source reads (a test advances its fake through this)."""
        return self._clock

    def fetcher(mut self) -> ref [self._fetcher] Self.F:
        """The fetcher this source calls."""
        return self._fetcher


struct StaticTokenSource(GcpTokenSource, Movable, Deinitable):
    """A fixed token, for an emulator or a test. An empty token is refused."""

    var _token: String

    def __init__(out self, var token: String) raises:
        if token.byte_length() == 0:
            raise Error("StaticTokenSource: the token is empty")
        self._token = token^

    def access_token(mut self) raises -> String:
        return self._token.copy()
