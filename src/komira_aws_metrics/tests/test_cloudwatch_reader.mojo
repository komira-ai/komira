# CloudWatchMetricsReader against the komira_metrics_reader seam.
#
# Conformance: the reader is used through `ErasedMetricsReader`; it refuses,
# before any call, what GetMetricData cannot answer (a raw read, group_by, a
# negated matcher, a matcher on a fixed dimension or one repeated, a step that
# is not a CloudWatch period); it maps a query to one MetricStat (statistic,
# period, window, dimensions); it pages on NextToken, stops at the point limit
# and at its page limit and says `truncated`; `rate` divides by the period; a
# final PartialData is `truncated`; a Forbidden result and a non-2xx answer
# raise with the call's error.
#
# Two transports. A scripted `AwsHttpTransport` replays responses and records
# each signed request, so paging is asserted without sockets. And
# komira_aws_core's `AwsConnectorTransport` over komira_http_core's
# ScriptedConnector with a write capture, so the request as it reached the
# wire is asserted: the request line, Host, the awsJson target, the
# query-mode header, the SigV4 date and scope (a fixed clock) and the body.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import (
    AwsConnectorTransport,
    AwsCredential,
    AwsEndpoint,
    AwsHttpTransport,
    CredentialHttpRequest,
    FixedClock,
    HttpResult,
    StaticCredsSource,
)
from komira_aws_metrics import (
    CloudWatchDimension,
    CloudWatchMetricsReader,
    cloudwatch_endpoint,
    ecs_service_dimensions,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_metrics_reader import (
    ErasedMetricsReader,
    MetricsAggregation,
    MetricsMatcher,
    MetricsQuery,
)

comptime _T0 = Int64(1789120800)
comptime _NS = Int64(1_000_000_000)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


struct _Script(Movable):
    var answers: List[HttpResult]
    var sent: List[CredentialHttpRequest]

    def __init__(out self):
        self.answers = List[HttpResult]()
        self.sent = List[CredentialHttpRequest]()


struct ScriptedTransport(AwsHttpTransport, Movable, Deinitable):
    """Replays `answers` in order and records every signed request. The
    state is shared (`ArcPointer`) so the test reads it after the transport
    has moved into the reader: one thread, a test double."""

    var _p: ArcPointer[_Script]

    def __init__(out self, p: ArcPointer[_Script]):
        self._p = p

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self._p[].sent.append(req.copy())
        if len(self._p[].answers) == 0:
            raise Error("ScriptedTransport: no answer scripted")
        return self._p[].answers.pop(0)


def _ok(body: String) -> HttpResult:
    return HttpResult(200, _bytes(body))


def _result(ts: List[Int64], vs: List[Float64], status: String) -> String:
    var t = String("[")
    var v = String("[")
    for i in range(len(ts)):
        if i > 0:
            t += ","
            v += ","
        t += String(ts[i])
        v += String(vs[i])
    return (
        String('{"Id":"m1","Label":"x","Timestamps":')
        + t
        + "],"
        + '"Values":'
        + v
        + '],"StatusCode":"'
        + status
        + '"}'
    )


def _page(ts: List[Int64], vs: List[Float64], status: String, token: String) -> String:
    var out = String('{"MetricDataResults":[') + _result(ts, vs, status) + "]"
    if token.byte_length() > 0:
        out += String(',"NextToken":"') + token + '"'
    return out + "}"


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _reader(
    p: ArcPointer[_Script],
) raises -> CloudWatchMetricsReader[ScriptedTransport, FixedClock, StaticCredsSource]:
    return CloudWatchMetricsReader[ScriptedTransport, FixedClock, StaticCredsSource](
        ScriptedTransport(p),
        FixedClock(1789207200),
        _creds(),
        String("us-east-1"),
        cloudwatch_endpoint(String("us-east-1")),
        String("AWS/ECS"),
        ecs_service_dimensions(
            String("arn:aws:ecs:us-east-1:111122223333:service/prod/api")
        ),
    )


def _query(
    agg: MetricsAggregation,
    step_ms: Int64 = 60_000,
    point_limit: Int = 1440,
) -> MetricsQuery:
    return MetricsQuery(
        _T0 * _NS,
        (_T0 + 3599) * _NS + 999_999_999,
        String("CPUUtilization"),
        List[MetricsMatcher](),
        agg,
        step_ms,
        List[String](),
        10,
        point_limit,
    )


def test_refusals_before_any_call() raises:
    var p = ArcPointer[_Script](_Script())
    var r = ErasedMetricsReader.erase(_reader(p))
    assert_equal(r.refusal(_query(MetricsAggregation.mean())), String(""))
    assert_true("not stored points" in r.refusal(_query(MetricsAggregation.raw())))
    assert_true("is not a CloudWatch period" in r.refusal(
        _query(MetricsAggregation.sum(), Int64(90_000))
    ))
    assert_true("is not a CloudWatch period" in r.refusal(
        _query(MetricsAggregation.sum(), Int64(60_500))
    ))
    var grouped = _query(MetricsAggregation.sum())
    grouped.group_by.append(String("TaskId"))
    assert_true("SEARCH expression" in r.refusal(grouped))
    var negated = _query(MetricsAggregation.sum())
    negated.matchers.append(MetricsMatcher.neq(String("TaskId"), String("a")))
    assert_true("equality only" in r.refusal(negated))
    var fixed = _query(MetricsAggregation.sum())
    fixed.matchers.append(MetricsMatcher.eq(String("ServiceName"), String("other")))
    assert_true("fixed by this reader" in r.refusal(fixed))
    var twice = _query(MetricsAggregation.sum())
    twice.matchers.append(MetricsMatcher.eq(String("TaskId"), String("a")))
    twice.matchers.append(MetricsMatcher.eq(String("TaskId"), String("b")))
    assert_true("matched twice" in r.refusal(twice))
    var unnamed = _query(MetricsAggregation.sum())
    unnamed.metric = String("")
    assert_true("name a CloudWatch metric" in r.refusal(unnamed))
    with assert_raises(contains="CloudWatch: CloudWatch keeps statistics"):
        _ = r.read(_query(MetricsAggregation.raw()))
    assert_equal(len(p[].sent), 0)


def test_one_page_maps_the_query() raises:
    var p = ArcPointer[_Script](_Script())
    p[].answers.append(
        _ok(_page([_T0, _T0 + 60], [1.5, 2.5], String("Complete"), String("")))
    )
    var r = ErasedMetricsReader.erase(_reader(p))
    var q = _query(MetricsAggregation.mean())
    q.matchers.append(MetricsMatcher.eq(String("TaskId"), String("t-1")))
    var page = r.read(q)
    assert_equal(len(p[].sent), 1)
    var body = p[].sent[0].body_text()
    assert_true(
        body.startswith('{"StartTime":1789120800,"EndTime":1789124400,'), body
    )
    assert_true(
        '"Dimensions":[{"Name":"ClusterName","Value":"prod"},{"Name":"ServiceName",'
        '"Value":"api"},{"Name":"TaskId","Value":"t-1"}]},"Period":60,"Stat":"Average"}'
        in body,
        body,
    )
    assert_true('"MaxDatapoints":1440}' in body, body)
    assert_equal(len(page.series), 1)
    assert_false(page.truncated)
    assert_equal(page.sources_scanned, 1)
    ref s = page.series[0]
    assert_equal(s.metric, String("CPUUtilization"))
    assert_equal(s.label(String("ClusterName")).value(), String("prod"))
    assert_equal(s.label(String("TaskId")).value(), String("t-1"))
    assert_equal(len(s.samples), 2)
    assert_equal(s.samples[0].time_ns, _T0 * _NS)
    assert_equal(s.samples[1].value, 2.5)


def test_pages_on_next_token_and_rate_divides() raises:
    var p = ArcPointer[_Script](_Script())
    p[].answers.append(_ok(_page([_T0], [120.0], String("PartialData"), String("t2"))))
    p[].answers.append(_ok(_page([_T0 + 60], [60.0], String("Complete"), String(""))))
    var r = ErasedMetricsReader.erase(_reader(p))
    var page = r.read(_query(MetricsAggregation.rate()))
    assert_equal(len(p[].sent), 2)
    var second = p[].sent[1].body_text()
    assert_true('"Stat":"Sum"' in second, second)
    assert_true(second.endswith('"MaxDatapoints":1439,"NextToken":"t2"}'), second)
    assert_false(page.truncated)
    assert_equal(page.sources_scanned, 2)
    assert_equal(page.series[0].samples[0].value, 2.0)
    assert_equal(page.series[0].samples[1].value, 1.0)


def test_point_limit_and_page_limit_truncate() raises:
    var p = ArcPointer[_Script](_Script())
    p[].answers.append(_ok(_page([_T0, _T0 + 60], [1.0, 2.0], String("PartialData"), String("t2"))))
    var r = ErasedMetricsReader.erase(_reader(p))
    var page = r.read(_query(MetricsAggregation.sum(), Int64(60_000), 2))
    assert_equal(len(p[].sent), 1)
    assert_true(page.truncated)
    assert_equal(page.sample_count(), 2)

    var p2 = ArcPointer[_Script](_Script())
    p2[].answers.append(_ok(_page([_T0], [1.0], String("PartialData"), String("t2"))))
    var limited = _reader(p2)
    limited.set_max_pages(1)
    var page2 = limited.read(_query(MetricsAggregation.sum()))
    assert_equal(len(p2[].sent), 1)
    assert_true(page2.truncated)

    var p3 = ArcPointer[_Script](_Script())
    p3[].answers.append(_ok(_page([_T0], [1.0], String("PartialData"), String(""))))
    var r3 = _reader(p3)
    var page3 = r3.read(_query(MetricsAggregation.sum()))
    assert_true(page3.truncated)


def test_no_points_is_an_empty_complete_page() raises:
    var p = ArcPointer[_Script](_Script())
    p[].answers.append(_ok(String('{"MetricDataResults":[{"Id":"m1","Timestamps":[],"Values":[],"StatusCode":"Complete"}]}')))
    var r = _reader(p)
    var page = r.read(_query(MetricsAggregation.max()))
    assert_equal(len(page.series), 0)
    assert_false(page.truncated)
    assert_equal(page.sources_scanned, 1)


def test_faults_raise() raises:
    var p = ArcPointer[_Script](_Script())
    p[].answers.append(_ok(_page([_T0], [1.0], String("Forbidden"), String(""))))
    var r = _reader(p)
    with assert_raises(contains="has StatusCode Forbidden"):
        _ = r.read(_query(MetricsAggregation.sum()))
    var p2 = ArcPointer[_Script](_Script())
    var denied = HttpResult(
        403, _bytes('{"__type":"AccessDeniedException","message":"no"}')
    )
    p2[].answers.append(denied^)
    var r2 = _reader(p2)
    with assert_raises(contains="GetMetricData failed: HTTP 403 AccessDeniedException"):
        _ = r2.read(_query(MetricsAggregation.sum()))
    assert_equal(len(p2[].sent), 1)


def _wire_ok() -> List[UInt8]:
    var body = String('{"MetricDataResults":[]}')
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/x-amz-json-1.0\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def test_the_request_on_the_wire() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var conn = ScriptedConnector.with_stream(
        ScriptedStream.from_read_script_with_capture(_wire_ok(), capture)
    )
    var transport = AwsConnectorTransport[ScriptedConnector](
        HttpClientConfig.defaults(), conn^
    )
    var r = CloudWatchMetricsReader[
        AwsConnectorTransport[ScriptedConnector], FixedClock, StaticCredsSource
    ](
        transport^,
        FixedClock(1789207200),
        _creds(),
        String("us-east-1"),
        AwsEndpoint.parse(String("http://127.0.0.1:4566"), String("the test")),
        String("AWS/ECS"),
        List[CloudWatchDimension](),
    )
    var page = r.read(_query(MetricsAggregation.count()))
    assert_equal(len(page.series), 0)
    var wire = String(unsafe_from_utf8=Span(capture[]))
    var lower = wire.lower()
    assert_true(wire.startswith("POST / HTTP/1.1\r\n"), wire)
    for want in [
        "host: 127.0.0.1:4566\r\n",
        "content-type: application/x-amz-json-1.0\r\n",
        "x-amz-target: graniteserviceversion20100801.getmetricdata\r\n",
        "x-amzn-query-mode: true\r\n",
        "x-amz-date: 20260912t100000z\r\n",
        "credential=akidexample/20260912/us-east-1/monitoring/aws4_request",
    ]:
        assert_true(lower.find(want) >= 0, String(want) + " is not in " + wire)
    assert_true(
        wire.endswith(
            '{"StartTime":1789120800,"EndTime":1789124400,"MetricDataQueries":'
            '[{"Id":"m1","MetricStat":{"Metric":{"Namespace":"AWS/ECS",'
            '"MetricName":"CPUUtilization","Dimensions":[]},"Period":60,'
            '"Stat":"SampleCount"},"ReturnData":true}],"ScanBy":'
            '"TimestampAscending","MaxDatapoints":1440}'
        ),
        wire,
    )


def main() raises:
    test_refusals_before_any_call()
    test_one_page_maps_the_query()
    test_pages_on_next_token_and_rate_divides()
    test_point_limit_and_page_limit_truncate()
    test_no_points_is_an_empty_complete_page()
    test_faults_raise()
    test_the_request_on_the_wire()
    print("OK")
