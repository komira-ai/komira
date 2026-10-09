# =============================================================================
# src/kci_publish/tests/test_publish_scripted_channel.mojo -- the test
#   double's own contract (what every other test here relies on), the
#   production channel transport over a scripted connection, and the
#   production sleeper.
# =============================================================================
#
# ROWS
#   (1) `ScriptedChannel.put` of a stored name replaces its bytes (setup,
#       not upload), and a later upload of that name answers 409;
#   (2) a request to another host RAISES (a test bug, never an answer);
#   (3) a request whose path, a header, or the form part's headers say
#       `force` answers 400 and is counted; `force` in the part's bytes is
#       not a flag;
#   (4) downloads outside the channel, or with no subdir, are 404; any
#       request that is neither a download nor the channel's upload is 404;
#       a form with no file name, or shorter than its closing boundary, is
#       400; a planned 403 is 403; an upload never made has no index;
#   (5) `HttpChannelTransport` sends through a connector its factory makes
#       for the request's host, and so does the transport it makes for
#       another worker;
#   (6) `UsleepSleeper` waits at least the time asked, in slices.
#
# Hermetic: ScriptedChannel, ScriptedConnector over a ScriptedStream (no
# socket; the host is an IP literal, so nothing is resolved).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST, HTTP_METHOD_PUT
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from kci_pkg_upload import PkgRequest, PkgResponse
from kci_publish import HttpChannelTransport, ScriptedChannel, UsleepSleeper
from kci_publish.scripted_channel import UPLOAD_ANSWER_403, _find


comptime _HOST: String = "conda.example.invalid"
comptime _CHANNEL: String = "example/stable"
comptime _BOUNDARY: String = "kci-test-boundary"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _text(b: List[UInt8]) -> String:
    var s = String("")
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _channel() -> ScriptedChannel:
    return ScriptedChannel(String(_HOST), String(_CHANNEL), String("linux-64"))


def _get(path: String) -> PkgRequest:
    return PkgRequest(HTTP_METHOD_GET, String(_HOST), path.copy())


def _upload(file: String, data: String, part_header: String = String("")) -> PkgRequest:
    """The one-part form `PrefixDevRegistry` sends."""
    var r = PkgRequest(HTTP_METHOD_POST, String(_HOST), String("/api/v1/upload/") + String(_CHANNEL))
    r.with_header(String("Content-Type"), String("multipart/form-data; boundary=") + String(_BOUNDARY))
    r.body = _bytes(
        String("--") + String(_BOUNDARY) + String("\r\nX-File-Name: ") + file + String("\r\n") + part_header
        + String("\r\n") + data + String("\r\n--") + String(_BOUNDARY) + String("--\r\n")
    )
    return r^


def test_put_replaces_and_an_upload_never_overwrites() raises:
    var ch = _channel()
    ch.put(String("linux-64"), String("a-1-h0_1.conda"), _bytes(String("first")))
    ch.put(String("linux-64"), String("a-1-h0_1.conda"), _bytes(String("second")))
    assert_equal(len(ch.stored_paths()), 1)
    var got = ch.exchange(_get(String("/example/stable/linux-64/a-1-h0_1.conda")))
    assert_equal(got.status, 200)
    assert_equal(_text(got.body), String("second"))
    assert_equal(ch.exchange(_upload(String("a-1-h0_1.conda"), String("third"))).status, 409)
    assert_equal(_text(ch.exchange(_get(String("/example/stable/linux-64/a-1-h0_1.conda"))).body), String("second"))


def test_a_request_to_another_host_raises() raises:
    var ch = _channel()
    var text = String("")
    try:
        _ = ch.exchange(PkgRequest(HTTP_METHOD_GET, String("other.example.invalid"), String("/example/stable/linux-64/x")))
    except e:
        text = String(e)
    assert_equal(text, String("ScriptedChannel: a request to an unexpected host 'other.example.invalid'"))


def test_force_anywhere_but_the_bytes_is_refused() raises:
    var ch = _channel()
    assert_equal(ch.exchange(_get(String("/example/stable/linux-64/x.conda?force=true"))).status, 400)
    var h = _get(String("/example/stable/linux-64/x.conda"))
    h.with_header(String("X-Mode"), String("force"))
    assert_equal(ch.exchange(h^).status, 400)
    assert_equal(ch.exchange(_upload(String("b-1-h0_1.conda"), String("b"), String("X-Mode: force\r\n"))).status, 400)
    assert_equal(ch.force_request_count(), 3)
    assert_false(ch.holds(String("linux-64"), String("b-1-h0_1.conda")))
    # the word in the part's BYTES is data, not a flag
    assert_equal(ch.exchange(_upload(String("c-1-h0_1.conda"), String("force of habit"))).status, 201)
    assert_equal(ch.force_request_count(), 3)
    assert_equal(_text(ch.exchange(_get(String("/example/stable/linux-64/c-1-h0_1.conda"))).body), String("force of habit"))


def test_requests_the_channel_does_not_serve() raises:
    var ch = _channel()
    assert_equal(ch.exchange(_get(String("/example/other/linux-64/x.conda"))).status, 404)
    assert_equal(ch.exchange(_get(String("/example/stable/x.conda"))).status, 404)
    assert_equal(ch.exchange(PkgRequest(HTTP_METHOD_PUT, String(_HOST), String("/api/v1/upload/example/stable"))).status, 404)
    var wrong = _upload(String("d-1-h0_1.conda"), String("d"))
    wrong.path = String("/api/v1/upload/example/other")
    assert_equal(ch.exchange(wrong^).status, 404)
    var nameless = PkgRequest(HTTP_METHOD_POST, String(_HOST), String("/api/v1/upload/example/stable"))
    nameless.with_header(String("Content-Type"), String("multipart/form-data; boundary=") + String(_BOUNDARY))
    nameless.body = _bytes(String("--") + String(_BOUNDARY) + String("\r\n\r\nd\r\n--") + String(_BOUNDARY) + String("--\r\n"))
    assert_equal(ch.exchange(nameless^).status, 400)
    var short = PkgRequest(HTTP_METHOD_POST, String(_HOST), String("/api/v1/upload/example/stable"))
    short.with_header(String("Content-Type"), String("multipart/form-data; boundary=") + String(_BOUNDARY))
    short.body = _bytes(String("X-File-Name: e\r\n\r\n"))
    assert_equal(ch.exchange(short^).status, 400)
    ch.plan_upload(String("f-1-h0_1.conda"), UPLOAD_ANSWER_403)
    assert_equal(ch.exchange(_upload(String("f-1-h0_1.conda"), String("f"))).status, 403)
    assert_false(ch.holds(String("linux-64"), String("f-1-h0_1.conda")))
    assert_equal(len(ch.stored_paths()), 0)
    assert_equal(ch.first_upload_call(String("never-1-h0_1.conda")), -1)
    assert_equal(ch.first_upload_call(String("f-1-h0_1.conda")), ch.call_count() - 1)


def test_an_empty_needle_is_found_where_the_search_starts() raises:
    var hay = _bytes(String("abc"))
    assert_equal(_find(hay, String(""), 2), 2)
    assert_equal(_find(hay, String("c"), 0), 2)
    assert_equal(_find(hay, String("d"), 0), -1)


comptime _ANSWER: String = "HTTP/1.1 201 Created\r\ncontent-type: application/json\r\ncontent-length: 2\r\n\r\n{}"


def _connector(host: String) -> ScriptedConnector:
    """A connection that answers `_ANSWER` -- only for the host asked."""
    if host != String("127.0.0.1"):
        return ScriptedConnector()  # no stream: a dial would raise
    return ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_bytes(String(_ANSWER))))


def _check(r: PkgResponse) raises:
    assert_equal(r.status, 201)
    assert_equal(r.header(String("content-type")), String("application/json"))
    assert_equal(_text(r.body), String("{}"))


def test_the_http_transport_and_its_workers_dial_through_the_factory() raises:
    var t = HttpChannelTransport[ScriptedConnector](_connector)
    _check(t.exchange(PkgRequest(HTTP_METHOD_GET, String("127.0.0.1"), String("/example/stable/noarch/repodata.json"))))
    var w = t.for_worker()
    _check(w.exchange(PkgRequest(HTTP_METHOD_GET, String("127.0.0.1"), String("/example/stable/noarch/repodata.json"))))
    # each exchange gets its own connection: the first one is not reused
    _check(t.exchange(PkgRequest(HTTP_METHOD_GET, String("127.0.0.1"), String("/example/stable/linux-64/repodata.json"))))


def test_the_usleep_sleeper_waits_in_slices() raises:
    var s = UsleepSleeper().for_worker()
    var t0 = perf_counter_ns()
    s.sleep_ms(0)
    s.sleep_ms(-5)
    assert_true(perf_counter_ns() - t0 < 400_000_000, String("no wait asked, none taken"))
    var t1 = perf_counter_ns()
    s.sleep_ms(620)
    var waited = perf_counter_ns() - t1
    assert_true(waited >= 620_000_000, String("waited ") + String(waited) + String(" ns"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
