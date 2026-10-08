# =============================================================================
# test_https_fetcher.mojo: the production JWKS fetcher never dials plain
# HTTP, and its fetch timeout bounds both the TLS handshake and the request.
# =============================================================================
#
# The connector factory is replaced by one that raises "DIALED", so no socket
# is ever opened. An http:// (or otherwise non-https) URL must be refused
# with the https message BEFORE the factory runs; the https:// control
# reaches the factory, which proves the refusal is not vacuous (a fetcher
# that refused everything would fail the control).
#
# The bounds are read without a network: `connector_for` is the connector
# `fetch` dials with (a real public-CA connector here, built and never
# dialed), and `client_config` the client settings `fetch` uses. A fetcher
# that left the handshake at the TLS connector's own 30 s default, or that
# ignored the timeout it was given, fails these.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto.rs256_jwks import RS256_MAX_JWKS_BYTES
from komira_http_auth import HttpsJwksFetcher
from komira_http_auth.config import DEFAULT_JWKS_FETCH_TIMEOUT_US
from komira_http_client.tls_connector import (
    TlsConnector,
    build_public_ca_tls_connector,
)
from komira_http_core.transport.kernel_tcp import KernelTcpConnector


def _no_dial(host: String) raises -> TlsConnector[KernelTcpConnector]:
    raise Error(String("DIALED ") + host)


def _public_ca(host: String) raises -> TlsConnector[KernelTcpConnector]:
    return build_public_ca_tls_connector(host)


def _fetch_error(url: String) raises -> String:
    var f = HttpsJwksFetcher(_no_dial)
    try:
        _ = f.fetch(url)
    except e:
        return String(e)
    raise Error("fetch returned without dialing")


def test_http_url_is_refused_before_dialing() raises:
    var msgs = List[String]()
    msgs.append(_fetch_error(String("http://www.googleapis.com/oauth2/v3/certs")))
    msgs.append(_fetch_error(String("HTTP://www.googleapis.com/oauth2/v3/certs")))
    msgs.append(_fetch_error(String("ftp://www.googleapis.com/certs")))
    msgs.append(_fetch_error(String("//www.googleapis.com/certs")))
    msgs.append(_fetch_error(String("https://user@keys.example.com/certs")))
    for i in range(len(msgs)):
        assert_false(String("DIALED") in msgs[i], msgs[i])
        assert_true(String("JWKS URL") in msgs[i], msgs[i])


def test_https_url_reaches_the_connector() raises:
    var msg = _fetch_error(String("https://www.googleapis.com/oauth2/v3/certs"))
    assert_true(String("DIALED www.googleapis.com") in msg, msg)


def test_the_tls_handshake_is_bounded_by_the_fetch_timeout() raises:
    var f = HttpsJwksFetcher(_public_ca)
    var c0 = f.connector_for(String("keys.example.com"))
    # The default fetch timeout, not the TLS connector's own 30 s.
    assert_equal(c0.handshake_deadline_us(), Int64(DEFAULT_JWKS_FETCH_TIMEOUT_US))
    f.set_timeout_us(1_234_000)
    var c1 = f.connector_for(String("keys.example.com"))
    assert_equal(c1.handshake_deadline_us(), Int64(1_234_000))


def test_the_request_is_bounded_by_the_fetch_timeout() raises:
    var f = HttpsJwksFetcher(_no_dial)
    assert_equal(f.client_config().request_timeout_us, DEFAULT_JWKS_FETCH_TIMEOUT_US)
    f.set_timeout_us(2_500_000)
    assert_equal(f.timeout_us(), 2_500_000)
    var cfg = f.client_config()
    assert_equal(cfg.request_timeout_us, 2_500_000)
    assert_equal(cfg.max_response_body_bytes, RS256_MAX_JWKS_BYTES)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
