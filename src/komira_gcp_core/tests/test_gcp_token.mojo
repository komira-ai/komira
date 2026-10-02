# =============================================================================
# test_gcp_token.mojo — token caching and refresh-before-expiry, komira_retry ManualClock.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_core import (
    DEFAULT_REFRESH_BEFORE_MS,
    AccessToken,
    AccessTokenFetcher,
    CachingTokenSource,
    GcpTokenSource,
    StaticTokenSource,
)
from komira_retry import ManualClock


struct CountingFetcher(AccessTokenFetcher, Movable, Deinitable):
    """Issues "tok-<n>" valid for `lifetime_s` seconds, or fails on demand."""

    var lifetime_s: Int64
    var calls: Int
    var fail: Bool

    def __init__(out self, lifetime_s: Int64):
        self.lifetime_s = lifetime_s
        self.calls = 0
        self.fail = False

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        self.calls += 1
        if self.fail:
            raise Error("token endpoint unavailable")
        return AccessToken.expiring_in(
            String("tok-") + String(self.calls), now_ms, self.lifetime_s
        )


def _bearer[T: GcpTokenSource](mut src: T) raises -> String:
    """What a generated client does with a source: one call per request."""
    return String("Bearer ") + src.access_token()


def test_token_is_cached_until_the_refresh_margin() raises:
    var src = CachingTokenSource(CountingFetcher(3600), ManualClock(0))
    assert_equal(src.access_token(), "tok-1")
    assert_equal(src.access_token(), "tok-1")
    # 3600 s lifetime, 225 s margin: still fresh 1 ms before the margin.
    src.clock().now = 3600_000 - DEFAULT_REFRESH_BEFORE_MS - 1
    assert_equal(src.access_token(), "tok-1")
    assert_equal(src.fetches(), 1)
    # At the margin it refreshes BEFORE expiry.
    src.clock().now = 3600_000 - DEFAULT_REFRESH_BEFORE_MS
    assert_equal(src.access_token(), "tok-2")
    assert_equal(src.fetches(), 2)
    assert_equal(_bearer(src), "Bearer tok-2")


def test_expired_token_is_refetched() raises:
    var src = CachingTokenSource(CountingFetcher(60), ManualClock(5_000), refresh_before_ms=0)
    assert_equal(src.access_token(), "tok-1")
    src.clock().now = 5_000 + 60_000
    assert_equal(src.access_token(), "tok-2")


def test_short_lived_token_is_refused_not_looped() raises:
    # 100 s lifetime is inside the 225 s margin: unusable.
    var src = CachingTokenSource(CountingFetcher(100), ManualClock(0))
    var raised = False
    try:
        _ = src.access_token()
    except e:
        raised = True
        var text = String(e)
        assert_true(text.find("unusable access token (5 bytes") >= 0, text)
        assert_false(text.find("tok-1") >= 0, text)
    assert_true(raised)
    assert_equal(src.fetches(), 1)


def test_fetch_failure_propagates_and_recovers() raises:
    var src = CachingTokenSource(CountingFetcher(3600), ManualClock(0))
    src.fetcher().fail = True
    var raised = False
    try:
        _ = src.access_token()
    except:
        raised = True
    assert_true(raised)
    src.fetcher().fail = False
    assert_equal(src.access_token(), "tok-2")


def test_invalidate_forces_a_refetch() raises:
    var src = CachingTokenSource(CountingFetcher(3600), ManualClock(0))
    assert_equal(src.access_token(), "tok-1")
    src.invalidate()
    assert_equal(src.access_token(), "tok-2")


def test_access_token_freshness_and_describe() raises:
    var t = AccessToken.expiring_in("ya29.secret", 1000, 10)
    assert_equal(t.expires_at_ms, 11_000)
    assert_true(t.is_fresh(1000, 0))
    assert_false(t.is_fresh(11_000, 0))
    assert_false(t.is_fresh(6_000, 5_000))
    assert_false(AccessToken(String(), 99_999).is_fresh(0, 0))
    var d = t.describe(1000)
    assert_equal(d, "access token (11 bytes, expires in 10000 ms)")
    assert_false(d.find("ya29") >= 0)


def test_static_source_and_bad_margin() raises:
    var s = StaticTokenSource("emulator-token")
    assert_equal(_bearer(s), "Bearer emulator-token")
    var refused = 0
    try:
        _ = StaticTokenSource(String())
    except:
        refused += 1
    try:
        _ = CachingTokenSource(CountingFetcher(1), ManualClock(0), refresh_before_ms=-1)
    except:
        refused += 1
    assert_equal(refused, 2)


def main() raises:
    test_token_is_cached_until_the_refresh_margin()
    test_expired_token_is_refetched()
    test_short_lived_token_is_refused_not_looped()
    test_fetch_failure_propagates_and_recovers()
    test_invalidate_forces_a_refetch()
    test_access_token_freshness_and_describe()
    test_static_source_and_bad_margin()
    print("all gcp token tests passed")
