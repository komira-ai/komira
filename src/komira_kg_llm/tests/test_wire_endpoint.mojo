# =============================================================================
# test_wire_endpoint.mojo -- the address of a model service and the bounds on an
# exchange with it.
# =============================================================================
#
# An endpoint keeps what it was given; there is no default for any field. Each
# rule has a case that fails by itself and, where the rule is a limit, a case on
# each side of it:
#   host      not empty, at most 253 bytes, letters digits '.', '-', '_' only
#             (a space, '/', '@', ':' and a line break are refused);
#   port      not zero;
#   path      begins with '/', at most 2048 bytes, printable ASCII without a
#             space and without '#';
#   timeout   more than zero, and small enough to be taken in microseconds;
#   size      more than zero.
# `timeout_us` is the time bound times a thousand.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_kg_llm import (
    ENDPOINT_MAX_HOST_BYTES,
    ENDPOINT_MAX_PATH_BYTES,
    WireEndpoint,
)


def _refusal(
    host: String,
    port: Int,
    path: String,
    timeout_ms: Int = 1000,
    max_bytes: Int = 1000,
) -> String:
    try:
        _ = WireEndpoint(
            host,
            UInt16(port),
            path,
            timeout_ms=timeout_ms,
            max_response_bytes=max_bytes,
        )
    except e:
        return String(e)
    return String()


def test_an_endpoint_keeps_what_it_was_given() raises:
    var e = WireEndpoint(
        "model-host_1.example.test",
        UInt16(8443),
        "/v9/x?y=1",
        timeout_ms=2500,
        max_response_bytes=65536,
    )
    assert_equal(e.host, "model-host_1.example.test")
    assert_equal(Int(e.port), 8443)
    assert_equal(e.path, "/v9/x?y=1")
    assert_equal(e.timeout_ms, 2500)
    assert_equal(e.max_response_bytes, 65536)
    assert_equal(e.timeout_us(), 2_500_000)
    var c = e.copy()
    assert_equal(c.path, "/v9/x?y=1")


def test_the_host_rules() raises:
    assert_equal(_refusal("127.0.0.1", 80, "/"), "")
    assert_true("host is empty" in _refusal("", 80, "/"))
    var bad = List[String]()
    bad.append("a b")
    bad.append("a/b")
    bad.append("user@host")
    bad.append("host:80")
    bad.append("a\nb")
    bad.append("hôst")
    for i in range(len(bad)):
        assert_true(
            "a host name cannot" in _refusal(bad[i], 80, "/"), bad[i]
        )
    var at = String()
    for _ in range(ENDPOINT_MAX_HOST_BYTES):
        at += "h"
    assert_equal(_refusal(at, 80, "/"), "")
    assert_true("longer than 253" in _refusal(at + "h", 80, "/"))


def test_the_port_rule() raises:
    assert_true("port is zero" in _refusal("h", 0, "/"))
    assert_equal(_refusal("h", 1, "/"), "")
    assert_equal(_refusal("h", 65535, "/"), "")


def test_the_path_rules() raises:
    assert_true("must begin with '/'" in _refusal("h", 80, ""))
    assert_true("must begin with '/'" in _refusal("h", 80, "v1/x"))
    var bad = List[String]()
    bad.append("/a b")
    bad.append("/a\nb")
    bad.append("/a\tb")
    bad.append("/a#frag")
    bad.append("/café")
    bad.append("/a" + chr(127) + "b")
    for i in range(len(bad)):
        assert_true(
            "holds a space, a control" in _refusal("h", 80, bad[i]), bad[i]
        )
    var at = String("/")
    for _ in range(ENDPOINT_MAX_PATH_BYTES - 1):
        at += "p"
    assert_equal(_refusal("h", 80, at), "")
    assert_true("longer than 2048" in _refusal("h", 80, at + "p"))


def test_the_bounds() raises:
    assert_true("timeout_ms must be more than zero" in _refusal("h", 80, "/", 0))
    assert_true("timeout_ms must be more than zero" in _refusal("h", 80, "/", -5))
    assert_equal(_refusal("h", 80, "/", 1), "")
    # The largest time bound that still fits in microseconds.
    assert_equal(_refusal("h", 80, "/", Int.MAX // 1000), "")
    assert_true("too large" in _refusal("h", 80, "/", Int.MAX // 1000 + 1))
    assert_true(
        "max_response_bytes must be more than zero"
        in _refusal("h", 80, "/", 1000, 0)
    )
    assert_true(
        "max_response_bytes must be more than zero"
        in _refusal("h", 80, "/", 1000, -1)
    )
    assert_equal(_refusal("h", 80, "/", 1000, 1), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
