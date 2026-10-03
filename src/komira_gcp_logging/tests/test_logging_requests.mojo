# The request the generated `LoggingServiceV2Client.list_log_entries` puts
# on the wire, byte for byte: the request line, the Host, the headers and
# the JSON body. The connector is komira_http_core's ScriptedConnector with
# a shared write capture, so the bytes the client wrote outlive the stream
# it dialled; no socket, no network.
#
# The expected forms are written here from the Cloud Logging v2 REST
# reference for `entries.list` (POST https://logging.googleapis.com/v2/
# entries:list, a JSON `ListLogEntriesRequest` body whose keys are the
# fields' JSON names): `resourceNames` is an array even for one project,
# `pageToken` is the previous page's `nextPageToken` sent back verbatim.
#
# The body carries every field, `"pageToken":""` included on a first page:
# komira_proto_codec's JsonEncoder writes default values, and the API reads
# an empty `pageToken` as no token (proto3: the empty string is the unset
# value), so a first page is a first page either way.
from std.memory import ArcPointer
from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_logging.logging import (
    ListLogEntriesRequest,
    ListLogEntriesResponse,
    LoggingServiceV2Client,
)
from komira_http_client.client import HttpClient
from komira_http_client.header_map import HeaderMap
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _HOST = "logging.googleapis.com"
comptime _TOKEN = "test-access-token"
comptime _RT = BlockingRuntime[NoopSink]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    """A 200 with a JSON body, closing the connection after it."""
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(
    capture: ArcPointer[List[UInt8]], var default_headers: HeaderMap
) raises -> LoggingServiceV2Client[ScriptedConnector, StaticTokenSource]:
    var stream = ScriptedStream.from_read_script_with_capture(
        _ok('{"entries":[]}'), capture
    )
    var http = HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(stream^)
    )
    var c = LoggingServiceV2Client[ScriptedConnector, StaticTokenSource](
        http^, StaticTokenSource(String(_TOKEN)), default_headers^
    )
    c.set_rest_host(String(_HOST))
    return c^


def _wire(req: ListLogEntriesRequest, var default_headers: HeaderMap) raises -> String:
    """What `list_log_entries(req)` wrote."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, default_headers^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.list_log_entries[_RT](req, reactor)
    return String(unsafe_from_utf8=Span(capture[]))


def _wire(req: ListLogEntriesRequest) raises -> String:
    return _wire(req, HeaderMap())


def _expected(body: String, extra_headers: String = "") -> String:
    """The request as written: komira_http's Host, User-Agent and
    Content-Length first, then the client's headers in the order it adds
    them (lowercased on the wire), then the body."""
    return (
        String("POST /v2/entries:list HTTP/1.1\r\n")
        + "Host: logging.googleapis.com\r\n"
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\n"
        + extra_headers
        + "authorization: Bearer test-access-token\r\n"
        + "content-type: application/json\r\n"
        + "\r\n"
        + body
    )


def _request(
    var names: List[String], filter: String, page_size: Int32, page_token: String
) -> ListLogEntriesRequest:
    return ListLogEntriesRequest(
        names^,
        filter.copy(),
        String("timestamp asc"),
        page_size,
        page_token.copy(),
    )


def test_first_page() raises:
    # The read a log reader makes first: one project, a filter with quotes
    # (escaped in the body), oldest first, a page size, no token.
    var names = List[String]()
    names.append(String("projects/demo-project"))
    var req = _request(
        names^,
        String('resource.type="cloud_run_job" AND severity>=DEFAULT'),
        Int32(200),
        String(""),
    )
    var body = String(
        '{"resourceNames":["projects/demo-project"],'
        + '"filter":"resource.type=\\"cloud_run_job\\" AND severity>=DEFAULT",'
        + '"orderBy":"timestamp asc","pageSize":200,"pageToken":""}'
    )
    assert_equal(_wire(req), _expected(body))


def test_next_page_sends_the_token_back_verbatim() raises:
    # A token is opaque: `+`, `/` and `=` go into the JSON string as they are.
    var names = List[String]()
    names.append(String("projects/demo-project"))
    var req = _request(
        names^, String("severity>=ERROR"), Int32(50), String("EAA4+/=xQ")
    )
    var body = String(
        '{"resourceNames":["projects/demo-project"],"filter":"severity>=ERROR",'
        + '"orderBy":"timestamp asc","pageSize":50,"pageToken":"EAA4+/=xQ"}'
    )
    assert_equal(_wire(req), _expected(body))


def test_several_resource_names() raises:
    # `resourceNames` takes projects, folders, billing accounts and log
    # views alike; each is one array element, in order.
    var names = List[String]()
    names.append(String("projects/demo-project"))
    names.append(String("folders/123456"))
    names.append(
        String("projects/demo-project/locations/global/buckets/b1/views/v1")
    )
    var req = _request(names^, String(""), Int32(0), String(""))
    var body = String(
        '{"resourceNames":["projects/demo-project","folders/123456",'
        + '"projects/demo-project/locations/global/buckets/b1/views/v1"],'
        + '"filter":"","orderBy":"timestamp asc","pageSize":0,"pageToken":""}'
    )
    assert_equal(_wire(req), _expected(body))


def test_default_headers_come_before_the_bearer() raises:
    # A caller's per-client header (here the quota project a caller bills a
    # read to) is sent on the request, ahead of the client's own headers.
    var names = List[String]()
    names.append(String("projects/demo-project"))
    var req = _request(names^, String(""), Int32(10), String(""))
    var headers = HeaderMap()
    headers.append(String("x-goog-user-project"), String("demo-billing"))
    var body = String(
        '{"resourceNames":["projects/demo-project"],"filter":"",'
        + '"orderBy":"timestamp asc","pageSize":10,"pageToken":""}'
    )
    assert_equal(
        _wire(req, headers^),
        _expected(body, String("x-goog-user-project: demo-billing\r\n")),
    )


def main() raises:
    test_first_page()
    test_next_page_sends_the_token_back_verbatim()
    test_several_resource_names()
    test_default_headers_come_before_the_bearer()
    print("OK")
