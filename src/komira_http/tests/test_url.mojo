# =============================================================================
# src/komira_http/tests/test_url.mojo — Url parser unit tests
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_http.client.url import Url


def test_simple_http() raises:
    var u = Url.parse(String("http://example.com/"))
    assert_equal(u.scheme, String("http"))
    assert_equal(u.host, String("example.com"))
    assert_equal(Int(u.port), 0)
    assert_equal(Int(u.effective_port()), 80)
    assert_equal(u.path, String("/"))
    assert_equal(u.query, String(""))


def test_simple_https() raises:
    var u = Url.parse(String("https://example.com/api"))
    assert_equal(u.scheme, String("https"))
    assert_equal(u.host, String("example.com"))
    assert_equal(Int(u.effective_port()), 443)
    assert_equal(u.path, String("/api"))


def test_explicit_port() raises:
    var u = Url.parse(String("http://localhost:8080/health"))
    assert_equal(u.host, String("localhost"))
    assert_equal(Int(u.port), 8080)
    assert_equal(Int(u.effective_port()), 8080)
    assert_equal(u.path, String("/health"))


def test_path_with_query() raises:
    var u = Url.parse(String("http://example.com/search?q=hello&n=10"))
    assert_equal(u.path, String("/search"))
    assert_equal(u.query, String("q=hello&n=10"))


def test_path_query_fragment() raises:
    var u = Url.parse(String("https://x.io/a/b?k=v#section-1"))
    assert_equal(u.path, String("/a/b"))
    assert_equal(u.query, String("k=v"))
    assert_equal(u.fragment, String("section-1"))


def test_empty_path_canonicalizes() raises:
    """Per RFC 3986 §3.3 / §6.2.3, empty path with explicit authority
    is equivalent to /."""
    var u = Url.parse(String("http://example.com"))
    assert_equal(u.path, String("/"))


def test_authority_only_with_query() raises:
    """No path, with query — path canonicalizes to /."""
    var u = Url.parse(String("http://example.com?k=v"))
    # Behavior: we expect path = "/" (default) and query = "k=v".
    assert_equal(u.path, String("/"))
    assert_equal(u.query, String("k=v"))


def test_userinfo() raises:
    var u = Url.parse(String("http://user:pass@host.com/p"))
    assert_equal(u.userinfo, String("user:pass"))
    assert_equal(u.host, String("host.com"))


def test_ipv6_literal() raises:
    var u = Url.parse(String("http://[::1]:8080/"))
    assert_equal(u.host, String("::1"))
    assert_equal(Int(u.port), 8080)
    # authority() must bracket on emission.
    assert_equal(u.authority(), String("[::1]:8080"))


def test_ipv4_literal() raises:
    var u = Url.parse(String("http://127.0.0.1:9000/health"))
    assert_equal(u.host, String("127.0.0.1"))
    assert_equal(Int(u.port), 9000)
    assert_equal(u.path, String("/health"))


def test_request_target_no_query() raises:
    var u = Url.parse(String("http://example.com/api/v1"))
    assert_equal(u.request_target(), String("/api/v1"))


def test_request_target_with_query() raises:
    var u = Url.parse(String("http://example.com/api/v1?x=1"))
    assert_equal(u.request_target(), String("/api/v1?x=1"))


def test_authority_omits_default_port() raises:
    var u = Url.parse(String("http://example.com:80/"))
    # 80 is the default for http; effective_port should be 80; explicit
    # port is set in the field.
    assert_equal(Int(u.port), 80)
    assert_equal(u.authority(), String("example.com"))


def test_authority_includes_non_default_port() raises:
    var u = Url.parse(String("https://example.com:8443/"))
    assert_equal(u.authority(), String("example.com:8443"))


def test_scheme_lowercased() raises:
    var u = Url.parse(String("HTTP://example.com/"))
    assert_equal(u.scheme, String("http"))


def test_reject_empty() raises:
    with assert_raises():
        var _u = Url.parse(String(""))


def test_reject_missing_scheme() raises:
    with assert_raises():
        var _u = Url.parse(String("example.com/path"))


def test_reject_bad_scheme() raises:
    with assert_raises():
        var _u = Url.parse(String("ftp://example.com/"))


def test_reject_missing_authority_slashes() raises:
    with assert_raises():
        var _u = Url.parse(String("http:example.com/"))


def test_reject_empty_host() raises:
    with assert_raises():
        var _u = Url.parse(String("http:///path"))


def test_reject_port_out_of_range() raises:
    with assert_raises():
        var _u = Url.parse(String("http://example.com:99999/"))


def test_reject_non_digit_in_port() raises:
    with assert_raises():
        var _u = Url.parse(String("http://example.com:abc/"))


def test_reject_unclosed_ipv6_bracket() raises:
    with assert_raises():
        var _u = Url.parse(String("http://[::1/"))


def test_http_factory() raises:
    var u = Url.http(String("example.com"), UInt16(8080), String("/api"))
    assert_equal(u.scheme, String("http"))
    assert_equal(u.host, String("example.com"))
    assert_equal(Int(u.port), 8080)
    assert_equal(u.path, String("/api"))


def test_https_factory() raises:
    var u = Url.https(String("example.com"), UInt16(443), String("/"))
    assert_equal(u.scheme, String("https"))
    assert_equal(Int(u.effective_port()), 443)


def main() raises:
    test_simple_http()
    test_simple_https()
    test_explicit_port()
    test_path_with_query()
    test_path_query_fragment()
    test_empty_path_canonicalizes()
    test_authority_only_with_query()
    test_userinfo()
    test_ipv6_literal()
    test_ipv4_literal()
    test_request_target_no_query()
    test_request_target_with_query()
    test_authority_omits_default_port()
    test_authority_includes_non_default_port()
    test_scheme_lowercased()
    test_reject_empty()
    test_reject_missing_scheme()
    test_reject_bad_scheme()
    test_reject_missing_authority_slashes()
    test_reject_empty_host()
    test_reject_port_out_of_range()
    test_reject_non_digit_in_port()
    test_reject_unclosed_ipv6_bracket()
    test_http_factory()
    test_https_factory()
    print("OK: test_url")
