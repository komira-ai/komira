# =============================================================================
# test_https_fetcher.mojo: the production JWKS fetcher never dials plain HTTP.
# =============================================================================
#
# The connector factory is replaced by one that raises "DIALED", so no socket
# is ever opened. An http:// (or otherwise non-https) URL must be refused
# with the https message BEFORE the factory runs; the https:// control
# reaches the factory, which proves the refusal is not vacuous (a fetcher
# that refused everything would fail the control).
# =============================================================================

from std.testing import TestSuite, assert_false, assert_true

from komira_http_auth import HttpsJwksFetcher
from komira_http_client.tls_connector import TlsConnector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector


def _no_dial(host: String) raises -> TlsConnector[KernelTcpConnector]:
    raise Error(String("DIALED ") + host)


def _fetch_error(url: String) raises -> String:
    var f = HttpsJwksFetcher(_no_dial, 1_000_000)
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
