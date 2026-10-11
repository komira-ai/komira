# =============================================================================
# src/komira_http_client/tests/test_shared_scripted_transport_recorders.mojo
#   The per-call recorders of the SharedScriptedTransport test double, read
#   through a second handle from share() after the first handle is moved away.
# =============================================================================
#
# Three requests carry three different header names, each with a value that
# differs from its name. The test asserts the exact name and value recorded for
# every call index, so a header_name_at that returns the header value, or that
# reads calls[0] whatever the index, fails here.

from std.testing import assert_equal

from komira_http_client.http_transport import (
    PM_METHOD_GET,
    PM_METHOD_POST,
    PM_METHOD_PUT,
    SharedScriptedTransport,
)


def _drive(var t: SharedScriptedTransport) raises:
    """Send three requests through a moved-in handle, each with its own header
    name and value."""
    _ = t.request(
        PM_METHOD_GET, "https://a.example/one", "Authorization", "Bearer t1", ""
    )
    _ = t.request(
        PM_METHOD_POST,
        "https://a.example/two",
        "X-Api-Key",
        "key-2",
        "{}",
    )
    _ = t.request(
        PM_METHOD_PUT,
        "https://a.example/three",
        "Metadata-Flavor",
        "Google",
        "",
    )


def test_header_name_at_reads_each_call() raises:
    var t = SharedScriptedTransport()
    t.add("", 200, "ok")
    var spy = t.share()
    _drive(t^)

    assert_equal(spy.call_count(), 3)

    assert_equal(spy.header_name_at(0), String("Authorization"))
    assert_equal(spy.header_name_at(1), String("X-Api-Key"))
    assert_equal(spy.header_name_at(2), String("Metadata-Flavor"))

    # The value recorder reads the other field of the same call.
    assert_equal(spy.header_value_at(0), String("Bearer t1"))
    assert_equal(spy.header_value_at(1), String("key-2"))
    assert_equal(spy.header_value_at(2), String("Google"))

    assert_equal(spy.url_at(1), String("https://a.example/two"))
    assert_equal(spy.method_at(2), PM_METHOD_PUT)


def main() raises:
    test_header_name_at_reads_each_call()
    print("OK: test_shared_scripted_transport_recorders")
