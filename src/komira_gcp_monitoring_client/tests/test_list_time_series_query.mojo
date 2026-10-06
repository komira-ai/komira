# The request line the generated `MetricServiceClient.list_time_series`
# puts on the wire, byte for byte. ListTimeSeries is a GET, so everything but
# the project rides the query: `interval` holds two Timestamps and
# `aggregation` a Duration, an aligner, a reducer and the group-by fields.
#
# What is pinned, and what each assertion would catch:
#   * A Timestamp is its proto3 JSON string: RFC 3339 in UTC, `Z`, the
#     fraction cut to 0, 3, 6 or 9 digits (`.999999999Z`, `.500Z`, none).
#     A generator that sent `interval.startTime.seconds=...&...nanos=...`,
#     or a formatter that dropped the `Z` or kept nine digits for `.5`,
#     fails here.
#   * A Duration is `<seconds>[.<frac>]s` (`120s`, `1.500s`). A formatter
#     without the trailing `s` fails here.
#   * A message field is flattened to dotted lowerCamelCase keys, in the
#     message's declaration order (`interval.endTime` before
#     `interval.startTime`: TimeInterval declares end_time first), and an
#     unset message sends none of its keys.
#   * Implicit-presence defaults are not sent: `view=FULL` (FULL is 0) and
#     an empty `pageToken` are absent, as the proto3 JSON mapping omits them;
#     `view=HEADERS` is sent.
#   * Query values are percent-encoded outside the RFC 3986 unreserved set.
#
# The expected strings are written from the Cloud Monitoring v3 REST
# reference for `projects.timeSeries.list` and the proto3 JSON mapping of
# google.protobuf.Timestamp and Duration, not read back from the generator.
# The connector is komira_http_core's ScriptedConnector with a write capture;
# no socket is opened and nothing talks to the service.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_monitoring_client.common import (
    Aggregation,
    Aggregation_Aligner,
    Aggregation_Reducer,
    TimeInterval,
)
from komira_gcp_monitoring_client.metric_service import (
    ListTimeSeriesRequest,
    ListTimeSeriesRequest_TimeSeriesView,
    MetricServiceClient,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_wkt import Duration, Timestamp


comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = MetricServiceClient[ScriptedConnector, StaticTokenSource]
comptime _T = Int64(1789207200)  # 2026-09-12T10:00:00Z


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(capture: ArcPointer[List[UInt8]], body: String) raises -> _Client:
    var conn = ScriptedConnector()
    conn.arm(ScriptedStream.from_read_script_with_capture(_ok(body), capture))
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(conn^),
        StaticTokenSource(String("test-token")),
    )
    c.set_rest_endpoint(String("127.0.0.1"), UInt16(8085), True)
    return c^


def _request_line(capture: ArcPointer[List[UInt8]]) raises -> String:
    var wire = String(unsafe_from_utf8=Span(capture[]))
    var end = wire.find("\r\n")
    return String(wire[byte=0:end]) if end >= 0 else wire


def _req(
    var interval: Optional[TimeInterval],
    var aggregation: Optional[Aggregation],
    view: Int = 0,
    page_token: String = "",
) -> ListTimeSeriesRequest:
    return ListTimeSeriesRequest(
        String("projects/demo-project"),
        String('metric.type = "run.googleapis.com/request_count"'),
        interval^,
        aggregation^,
        None,
        String(""),
        ListTimeSeriesRequest_TimeSeriesView(view),
        Int32(1000),
        page_token.copy(),
    )


def _send(var req: ListTimeSeriesRequest) raises -> String:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String("{}"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.list_time_series[_RT](req, reactor)
    return _request_line(capture)


def test_interval_and_aggregation_on_the_wire() raises:
    var groups = List[String]()
    groups.append(String("metric.label.response_code"))
    groups.append(String("resource.label.service_name"))
    var line = _send(
        _req(
            TimeInterval(
                Timestamp(_T + 120, Int32(0)),
                Timestamp(_T - 1, Int32(999_999_999)),
            ),
            Aggregation(
                Duration(Int64(120), Int32(0)),
                Aggregation_Aligner(Aggregation_Aligner.ALIGN_RATE),
                Aggregation_Reducer(Aggregation_Reducer.REDUCE_SUM),
                groups^,
            ),
            page_token=String("tok+/="),
        )
    )
    assert_equal(
        line,
        String(
            "GET /v3/projects/demo-project/timeSeries"
            "?filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
            "&interval.endTime=2026-09-12T10%3A02%3A00Z"
            "&interval.startTime=2026-09-12T09%3A59%3A59.999999999Z"
            "&aggregation.alignmentPeriod=120s"
            "&aggregation.perSeriesAligner=ALIGN_RATE"
            "&aggregation.crossSeriesReducer=REDUCE_SUM"
            "&aggregation.groupByFields=metric.label.response_code"
            "&aggregation.groupByFields=resource.label.service_name"
            "&pageSize=1000&pageToken=tok%2B%2F%3D HTTP/1.1"
        ),
    )


def test_fractions_and_view() raises:
    # A half second is `.500` on a Timestamp and `1.500s` on a Duration; an
    # unset end time and an unset aligner send no key; HEADERS is sent.
    var line = _send(
        _req(
            TimeInterval(None, Timestamp(_T, Int32(500_000_000))),
            Aggregation(
                Duration(Int64(1), Int32(500_000_000)),
                Aggregation_Aligner(0),
                Aggregation_Reducer(0),
                List[String](),
            ),
            view=ListTimeSeriesRequest_TimeSeriesView.HEADERS,
        )
    )
    assert_equal(
        line,
        String(
            "GET /v3/projects/demo-project/timeSeries"
            "?filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
            "&interval.startTime=2026-09-12T10%3A00%3A00.500Z"
            "&aggregation.alignmentPeriod=1.500s"
            "&view=HEADERS&pageSize=1000 HTTP/1.1"
        ),
    )


def test_unset_messages_send_nothing() raises:
    var line = _send(_req(None, None))
    assert_equal(
        line,
        String(
            "GET /v3/projects/demo-project/timeSeries"
            "?filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
            "&pageSize=1000 HTTP/1.1"
        ),
    )


def test_the_response_is_decoded() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        String(
            '{"timeSeries":[{"metric":{"type":"m","labels":{"code":"200"}},'
            '"valueType":"INT64","points":[{"interval":{"endTime":'
            '"2026-09-12T10:01:00Z"},"value":{"int64Value":"9007199254740993"}}]}],'
            '"nextPageToken":"p2"}'
        ),
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var resp = c.list_time_series[_RT](_req(None, None), reactor)
    assert_equal(resp.next_page_token, String("p2"))
    assert_equal(len(resp.time_series), 1)
    ref ts = resp.time_series[0]
    assert_equal(ts.metric.value().type, String("m"))
    assert_equal(ts.metric.value().labels[String("code")], String("200"))
    assert_equal(ts.value_type.json_name(), String("INT64"))
    ref p = ts.points[0]
    assert_equal(p.interval.value().end_time.value().seconds, _T + 60)
    assert_equal(p.value.value().int64_value.value(), Int64(9007199254740993))
    assert_true(len(capture[]) > 0)


def main() raises:
    test_interval_and_aggregation_on_the_wire()
    test_fractions_and_view()
    test_unset_messages_send_nothing()
    test_the_response_is_decoded()
    print("OK")
