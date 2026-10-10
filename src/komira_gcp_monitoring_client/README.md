# komira_gcp_monitoring_client

A Cloud Monitoring v3 client, generated at build time from the googleapis
protos (`google/monitoring/v3`) over REST/JSON. It carries one method,
`MetricServiceClient.list_time_series` (`GET /v3/{name}/timeSeries`), one
page per call, with the request, response and time-series types it reaches
(`ListTimeSeriesRequest`, `ListTimeSeriesResponse`, `TimeSeries`, `Point`,
`TimeInterval`, `Aggregation` and the metric and resource types).

ListTimeSeries is a GET, so the whole request rides the query: a Timestamp
is sent as RFC 3339 UTC, a Duration as `<seconds>[.<frac>]s`, a message
field as dotted lowerCamelCase keys, and a field left at its default is not
sent. The client sends through a komira_http_client `HttpClient` over the
komira_http_core `Connector` it is given, asks a komira_gcp_core
`GcpTokenSource` for one bearer token per request, and raises a non-2xx
answer through komira_gcp_core's `gcp_status_error`, which never quotes the
body. It starts at `monitoring.googleapis.com`; `set_rest_host` and
`set_rest_endpoint` point it elsewhere. It reads no environment.

It does not write metrics or manage descriptors (no other MetricService
method is generated). komira_gcp_monitoring builds on it to read a project's
metrics through the komira_metrics_reader seam.

## Examples

The example sends through komira_http_core's `ScriptedConnector`, which
answers from a canned response and captures the bytes the client wrote; no
socket is opened. The client is pointed at `localhost` so nothing is looked
up in DNS.

A two-minute read aligned to rates and summed by response code: the request
line on the wire, and the answer decoded (an `int64Value` arrives as a JSON
string and is read exactly):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_monitoring_client.common import Aggregation, Aggregation_Aligner, Aggregation_Reducer, TimeInterval
from komira_gcp_monitoring_client.metric_service import ListTimeSeriesRequest, ListTimeSeriesRequest_TimeSeriesView, MetricServiceClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_wkt import Duration, Timestamp

comptime Runtime = BlockingRuntime[NoopSink]

var answer = String(
    '{"timeSeries":[{"metric":{"type":"run.googleapis.com/request_count",'
    + '"labels":{"response_code":"200"}},"valueType":"INT64","points":['
    + '{"interval":{"endTime":"2026-09-12T10:01:00Z"},'
    + '"value":{"int64Value":"9007199254740993"}}]}],"nextPageToken":"p2"}'
)
var reply_text = (
    String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
    + "Content-Length: " + String(answer.byte_length())
    + "\r\nConnection: close\r\n\r\n" + answer
)
var reply = List[UInt8]()
reply.extend(Span(reply_text.as_bytes()))

var sent = ArcPointer[List[UInt8]](List[UInt8]())
var client = MetricServiceClient[ScriptedConnector, StaticTokenSource](
    HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(reply^, sent)
        )
    ),
    StaticTokenSource(String("a-token")),
)
client.set_rest_host(String("localhost"))

var start = Int64(1789207200)  # 2026-09-12T10:00:00Z
var groups = List[String]()
groups.append(String("metric.label.response_code"))
var request = ListTimeSeriesRequest(
    String("projects/demo-project"),
    String('metric.type = "run.googleapis.com/request_count"'),
    TimeInterval(Timestamp(start + 120, Int32(0)), Timestamp(start, Int32(0))),
    Aggregation(
        Duration(Int64(60), Int32(0)),
        Aggregation_Aligner(Aggregation_Aligner.ALIGN_RATE),
        Aggregation_Reducer(Aggregation_Reducer.REDUCE_SUM),
        groups^,
    ),
    None,                                    # no secondary aggregation
    String(""),                              # no ordering
    ListTimeSeriesRequest_TimeSeriesView(0), # FULL, the default: not sent
    Int32(1000),
    String(""),                              # first page: no token sent
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var page = client.list_time_series[Runtime](request, reactor)

var wire = String(unsafe_from_utf8=Span(sent[]))
assert_equal(
    String(wire[byte=0 : wire.find("\r\n")]),
    String(
        "GET /v3/projects/demo-project/timeSeries"
        + "?filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
        + "&interval.endTime=2026-09-12T10%3A02%3A00Z"
        + "&interval.startTime=2026-09-12T10%3A00%3A00Z"
        + "&aggregation.alignmentPeriod=60s"
        + "&aggregation.perSeriesAligner=ALIGN_RATE"
        + "&aggregation.crossSeriesReducer=REDUCE_SUM"
        + "&aggregation.groupByFields=metric.label.response_code"
        + "&pageSize=1000 HTTP/1.1"
    ),
)

assert_equal(page.next_page_token, String("p2"))
assert_equal(len(page.time_series), 1)
ref series = page.time_series[0]
assert_equal(series.metric.value().labels[String("response_code")], String("200"))
assert_equal(series.value_type.json_name(), String("INT64"))
ref point = series.points[0]
assert_equal(point.interval.value().end_time.value().seconds, start + 60)
assert_equal(point.value.value().int64_value.value(), Int64(9007199254740993))
```
