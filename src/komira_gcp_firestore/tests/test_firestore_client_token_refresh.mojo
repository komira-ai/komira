# =============================================================================
# tests/test_firestore_client_token_refresh.mojo
#   The FirestoreClient asks its token source for EVERY request, and the
#   Listen watch source for EVERY dial.
# =============================================================================
#
# THE DEFECT THIS GUARDS: a client that captures its bearer once, at
# construction, and stamps it verbatim on every request. A long-lived process
# mints its access token at boot; the token expires after about an hour, and
# every request after that fails UNAUTHENTICATED.
#
# THE CONTRACT: `FirestoreClient[T, S]` calls `S.access_token()` inside `_send`
# for each request. Over a komira_gcp_core `CachingTokenSource`, that serves a
# cached token while it is fresh and refetches it `refresh_before_ms` before it
# expires; over a `FixedBearer` it returns the same token every time.
#
# FALSIFIER (hermetic: no network, no metadata server, no credentials): a fake
# `AccessTokenFetcher` hands out a DISTINCT token per fetch (`tok-1`, `tok-2`,
# ...) that lives one hour, and a komira_retry `ManualClock` decides when a
# cached token is stale. Driving the client over a ScriptedFirestore,
# which RECORDS the bearer stamped on each request, we assert:
#   * two requests inside the token's life carry the SAME bearer (one fetch);
#   * a request after the clock passes the refresh point carries a NEW bearer
#     (the stale token is refetched, not reused);
#   * a `FixedBearer` client stamps its token on every request, and an empty
#     one stamps nothing.
#   * the `Listen` change stream's `FirestoreWatchSource` asks its source on
#     every DIAL the same way: a reconnect past the refresh point gets a NEW
#     token. A source that held one token from construction would reconnect
#     with an expired one once the stream outlived it. (Observed through
#     `dial_bearer`, the call each dial makes; no socket is opened.)
#
# NOT COVERED: a live metadata-server round trip and a real UNAUTHENTICATED
# reply after an hour. This proves the per-request discipline only.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_gcp_core import (
    DEFAULT_REFRESH_BEFORE_MS,
    AccessToken,
    AccessTokenFetcher,
    CachingTokenSource,
)
from komira_retry import ManualClock

from komira_http_core.transport.scripted import ScriptedConnector
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore
from komira_gcp_firestore.firestore_client import FirestoreClient, FixedBearer
from komira_gcp_firestore.firestore_watch_source import FirestoreWatchSource


comptime _PROJECT: String = "example-project"
comptime _DATABASE: String = "(default)"

# One hour, the lifetime Google's token endpoints give an access token.
comptime _TOKEN_LIFE_S: Int64 = 3600


struct _CountingFetcher(AccessTokenFetcher, Movable, Deinitable):
    """Each fetch returns a new token, `tok-<n>`, valid for one hour from the
    fetch time."""

    var _n: Int

    def __init__(out self):
        self._n = 0

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        self._n += 1
        return AccessToken.expiring_in(
            String("tok-") + String(self._n), now_ms, _TOKEN_LIFE_S
        )


comptime _Source = CachingTokenSource[_CountingFetcher, ManualClock]


def _caching_client(
    mut script: ScriptedFirestore,
) raises -> FirestoreClient[ScriptedConnector, _Source]:
    return FirestoreClient[ScriptedConnector, _Source](
        script.take_connector(),
        String(_PROJECT),
        String(_DATABASE),
        _Source(_CountingFetcher(), ManualClock(0)),
    )


def _ok_doc_json() -> String:
    """A minimal BatchGetDocuments answer; the test asserts the BEARER, not
    the payload."""
    return String(
        '[{"found":{"name":"projects/example-project/databases/(default)/documents/jobs/j1"}}]'
    )


def test_fresh_token_is_reused_across_requests() raises:
    """Two requests inside the token's life: one fetch, the same bearer."""
    var transport = ScriptedFirestore()
    transport.queue_response(200, _ok_doc_json())
    transport.queue_response(200, _ok_doc_json())
    var client = _caching_client(transport)
    _ = client.get_document(String("jobs"), String("j1"))
    client.token_source().clock().advance(Int64(60_000))
    _ = client.get_document(String("jobs"), String("j1"))

    assert_equal(transport.call_count(), 2)
    assert_equal(transport.call_method(0), String("POST"))
    assert_equal(transport.call_bearer(0), String("tok-1"))
    assert_equal(transport.call_bearer(1), String("tok-1"))
    assert_equal(client.token_source().fetches(), 1)


def test_stale_token_is_refetched_before_the_next_request() raises:
    """THE FALSIFIER. Past the refresh point, the next request carries a NEW
    token. A client that captured its bearer at construction would stamp
    `tok-1` on both requests."""
    var transport = ScriptedFirestore()
    transport.queue_response(200, _ok_doc_json())
    transport.queue_response(200, _ok_doc_json())
    var client = _caching_client(transport)
    _ = client.get_document(String("jobs"), String("j1"))
    # Move past `expires - refresh_before`: the cached token is no longer fresh.
    client.token_source().clock().advance(
        _TOKEN_LIFE_S * 1000 - DEFAULT_REFRESH_BEFORE_MS
    )
    _ = client.get_document(String("jobs"), String("j1"))

    assert_equal(transport.call_count(), 2)
    assert_equal(transport.call_bearer(0), String("tok-1"))
    assert_equal(transport.call_bearer(1), String("tok-2"))
    assert_true(transport.call_bearer(0) != transport.call_bearer(1))
    assert_equal(client.token_source().fetches(), 2)


def test_fixed_bearer_stamps_the_same_token_on_every_request() raises:
    """A `FixedBearer` client (built from a plain String) stamps its token on
    every request."""
    var transport = ScriptedFirestore()
    transport.queue_response(200, _ok_doc_json())
    transport.queue_response(200, _ok_doc_json())
    var client = FirestoreClient[ScriptedConnector](
        transport.take_connector(),
        String(_PROJECT),
        String(_DATABASE),
        String("tok-fixed"),
    )
    _ = client.get_document(String("jobs"), String("j1"))
    _ = client.get_document(String("jobs"), String("j1"))

    assert_equal(transport.call_count(), 2)
    assert_equal(transport.call_bearer(0), String("tok-fixed"))
    assert_equal(transport.call_bearer(1), String("tok-fixed"))


def test_empty_fixed_bearer_is_accepted() raises:
    """An empty `FixedBearer` (the emulator) builds and sends an empty bearer
    (`Authorization: Bearer ` with nothing after it)."""
    var transport = ScriptedFirestore()
    transport.queue_response(200, _ok_doc_json())
    var client = FirestoreClient[ScriptedConnector](
        transport.take_connector(),
        String(_PROJECT),
        String(_DATABASE),
        FixedBearer(String()),
    )
    _ = client.get_document(String("jobs"), String("j1"))
    assert_equal(transport.call_bearer(0), String())


def _watch_docs() -> List[String]:
    var docs = List[String]()
    docs.append(
        String("projects/example-project/databases/(default)/documents/jobs/j1")
    )
    return docs^


def test_watch_source_asks_its_token_source_on_every_dial() raises:
    """THE LISTEN FALSIFIER. Two dials inside the token's life share one
    fetch; a dial past the refresh point (a reconnect after the stream has run
    for most of an hour) carries a NEW token."""
    var src = FirestoreWatchSource[_Source](
        String("firestore.googleapis.com"),
        String("projects/example-project/databases/(default)"),
        _watch_docs(),
        _Source(_CountingFetcher(), ManualClock(0)),
    )
    assert_equal(src.dial_bearer(), String("tok-1"))
    src.tokens().clock().advance(Int64(60_000))
    assert_equal(src.dial_bearer(), String("tok-1"))
    assert_equal(src.tokens().fetches(), 1)
    src.tokens().clock().advance(
        _TOKEN_LIFE_S * 1000 - DEFAULT_REFRESH_BEFORE_MS
    )
    assert_equal(src.dial_bearer(), String("tok-2"))
    assert_equal(src.tokens().fetches(), 2)


def test_watch_source_over_a_fixed_bearer_reuses_it() raises:
    """Over a `FixedBearer` (the default source type) every dial presents the
    one token it was built with."""
    var src = FirestoreWatchSource(
        String("firestore.googleapis.com"),
        String("projects/example-project/databases/(default)"),
        _watch_docs(),
        FixedBearer(String("fixed-token")),
    )
    assert_equal(src.dial_bearer(), String("fixed-token"))
    assert_equal(src.dial_bearer(), String("fixed-token"))


def main() raises:
    test_fresh_token_is_reused_across_requests()
    test_stale_token_is_refetched_before_the_next_request()
    test_fixed_bearer_stamps_the_same_token_on_every_request()
    test_empty_fixed_bearer_is_accepted()
    test_watch_source_asks_its_token_source_on_every_dial()
    test_watch_source_over_a_fixed_bearer_reuses_it()
    print("PASS tests/test_firestore_client_token_refresh")
