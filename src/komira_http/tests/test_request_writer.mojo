# =============================================================================
# src/komira_http/tests/test_request_writer.mojo
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http.client.body import BytesBody, EmptyBody
from komira_http.client.header_map import HeaderMap
from komira_http.client.request_writer import (
    drain_body_into,
    method_get,
    method_head,
    method_post,
    method_put,
    serialize_request_head,
)
from komira_http.client.url import Url


def _bytes_to_str(buf: List[UInt8]) -> String:
    var out = String()
    var i = 0
    while i < buf.__len__():
        out = out + chr(Int(buf[i]))
        i = i + 1
    return out^


def test_get_minimal() raises:
    var url = Url.parse(String("http://example.com/health"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    var wire = _bytes_to_str(out)
    var expected = String(
        "GET /health HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "User-Agent: komira-http/1.0\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
    )
    assert_equal(wire, expected)


def test_get_with_query() raises:
    var url = Url.parse(String("http://example.com/search?q=test&n=5"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    var wire = _bytes_to_str(out)
    # First line must include the query.
    assert_true(wire.startswith(String("GET /search?q=test&n=5 HTTP/1.1\r\n")))


def test_authority_with_explicit_port() raises:
    var url = Url.parse(String("http://localhost:8080/x"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    var wire = _bytes_to_str(out)
    assert_true(wire.find(String("Host: localhost:8080\r\n")) >= 0)


def test_authority_omits_default_port_for_https() raises:
    var url = Url.parse(String("https://api.example.com:443/data"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    var wire = _bytes_to_str(out)
    # 443 is default for https — must be omitted.
    assert_true(wire.find(String("Host: api.example.com\r\n")) >= 0)


def test_caller_set_host_overrides() raises:
    var url = Url.parse(String("http://10.0.0.1/x"))
    var hdrs = HeaderMap()
    hdrs.insert(String("Host"), String("real-host.example.com"))
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    var wire = _bytes_to_str(out)
    # Default Host should NOT be injected when the caller set one.
    # HeaderMap lowercases names on insert; emission is the lowercase
    # canonical form (HTTP is case-insensitive on the wire).
    assert_true(wire.find(String("host: real-host.example.com\r\n")) >= 0)
    # And we must NOT have a separate Host line with the URL's host.
    assert_true(wire.find(String("10.0.0.1")) < 0)


def test_caller_set_user_agent_overrides() raises:
    var url = Url.parse(String("http://example.com/x"))
    var hdrs = HeaderMap()
    hdrs.insert(String("User-Agent"), String("custom-agent/2.0"))
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    var wire = _bytes_to_str(out)
    # Lowercase emission per HeaderMap canonicalization.
    assert_true(wire.find(String("user-agent: custom-agent/2.0\r\n")) >= 0)
    # Default UA must NOT appear.
    assert_true(wire.find(String("komira-http/1.0")) < 0)


def test_post_with_body() raises:
    var url = Url.parse(String("http://api.example.com/items"))
    var hdrs = HeaderMap()
    hdrs.insert(String("Content-Type"), String("application/json"))
    var out = List[UInt8]()
    serialize_request_head(method_post(), url, hdrs, 13, out)
    var wire = _bytes_to_str(out)
    assert_true(wire.startswith(String("POST /items HTTP/1.1\r\n")))
    assert_true(wire.find(String("Content-Length: 13\r\n")) >= 0)
    assert_true(wire.find(String("content-type: application/json\r\n")) >= 0)


def test_put_with_chunked_te() raises:
    """content_length=-1 triggers Transfer-Encoding: chunked."""
    var url = Url.parse(String("http://api.example.com/large"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_put(), url, hdrs, -1, out)
    var wire = _bytes_to_str(out)
    assert_true(wire.find(String("Transfer-Encoding: chunked\r\n")) >= 0)
    # No Content-Length should appear.
    assert_true(wire.find(String("Content-Length")) < 0)


def test_caller_cl_overrides_injected() raises:
    var url = Url.parse(String("http://x.io/y"))
    var hdrs = HeaderMap()
    hdrs.insert(String("Content-Length"), String("42"))
    var out = List[UInt8]()
    # Caller says content_length=10, but their header says 42 — caller wins.
    serialize_request_head(method_post(), url, hdrs, 10, out)
    var wire = _bytes_to_str(out)
    assert_true(wire.find(String("content-length: 42\r\n")) >= 0)
    # No second Content-Length line with 10.
    assert_true(wire.find(String("Content-Length: 10\r\n")) < 0)


def test_head_method() raises:
    var url = Url.parse(String("http://example.com/"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_head(), url, hdrs, 0, out)
    var wire = _bytes_to_str(out)
    assert_true(wire.startswith(String("HEAD / HTTP/1.1\r\n")))


def test_terminator_present() raises:
    var url = Url.parse(String("http://example.com/"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    # The buffer must end with CRLFCRLF.
    var n = out.__len__()
    assert_true(n >= 4)
    assert_equal(Int(out[n - 4]), 0x0D)
    assert_equal(Int(out[n - 3]), 0x0A)
    assert_equal(Int(out[n - 2]), 0x0D)
    assert_equal(Int(out[n - 1]), 0x0A)


def test_drain_empty_body() raises:
    var b = EmptyBody.new()
    var out = List[UInt8]()
    var n = drain_body_into(b, out)
    assert_equal(n, 0)
    assert_equal(out.__len__(), 0)


def test_drain_bytes_body() raises:
    var b = BytesBody.from_str(String("hello world"))
    var out = List[UInt8]()
    var n = drain_body_into(b, out)
    assert_equal(n, 11)
    assert_equal(out.__len__(), 11)
    assert_equal(_bytes_to_str(out), String("hello world"))


def main() raises:
    test_get_minimal()
    test_get_with_query()
    test_authority_with_explicit_port()
    test_authority_omits_default_port_for_https()
    test_caller_set_host_overrides()
    test_caller_set_user_agent_overrides()
    test_post_with_body()
    test_put_with_chunked_te()
    test_caller_cl_overrides_injected()
    test_head_method()
    test_terminator_present()
    test_drain_empty_body()
    test_drain_bytes_body()
    print("OK: test_request_writer")
