# CloudMonitoringMetricsReader against the komira_metrics_reader seam, over
# komira_http_core's ScriptedConnector (no socket) with a shared write
# capture, so each request is asserted as it reached the wire.
#
# Conformance: the reader is used through `ErasedMetricsReader`; it refuses,
# before any call, what it cannot send (an empty metric, a label key that is
# not a plain identifier, grouping a raw read, a step under 60 s or not whole
# seconds); it maps a query to one GET (filter, interval one nanosecond
# before the inclusive start, aligner, reducer, group-by fields, page size)
# with a bearer token; it follows nextPageToken and merges a series
# continued on the next page, oldest first, keyed on the series' whole wire
# identity, so two series apart only in a label the query did not name stay
# two; it keeps resource labels only when the query names them; the series limit, the point limit (keeping the
# newest), the page limit and executionErrors set `truncated`; and a non-2xx
# answer raises through komira_gcp_core's `gcp_status_error`, the body never
# quoted.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_gcp_core import StaticTokenSource
from komira_gcp_monitoring import (
    MONITORING_DEFAULT_HOST,
    CloudMonitoringMetricsReader,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_metrics_reader import (
    ErasedMetricsReader,
    MetricsAggregation,
    MetricsMatcher,
    MetricsQuery,
)

comptime _T = Int64(1789207200) * Int64(1_000_000_000)
comptime _MIN = Int64(60) * Int64(1_000_000_000)
comptime _Reader = CloudMonitoringMetricsReader[ScriptedConnector, StaticTokenSource]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status_line: String, body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _reader(capture: ArcPointer[List[UInt8]], var answers: List[String]) raises -> _Reader:
    """A reader at a plaintext test endpoint whose connector answers each
    dial with the next of `answers` (each a whole HTTP response)."""
    var conn = ScriptedConnector()
    for i in range(len(answers)):
        var stream = ScriptedStream.from_read_script_with_capture(
            _bytes(answers[i]), capture
        )
        if i == 0:
            conn.arm(stream^)
        else:
            conn.arm_next(stream^)
    var r = _Reader(
        HttpClient[ScriptedConnector].with_defaults(conn^),
        StaticTokenSource(String("test-token")),
        String("demo-project"),
    )
    r.set_host(String("127.0.0.1"), 8085, plaintext=True)
    return r^


def _ok(body: String) -> String:
    return String(unsafe_from_utf8=Span(_answer("200 OK", body)))


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _query(agg: MetricsAggregation, step_ms: Int64 = 60_000) -> MetricsQuery:
    return MetricsQuery(
        _T,
        _T + 2 * _MIN,
        String("run.googleapis.com/request_count"),
        List[MetricsMatcher](),
        agg,
        step_ms,
        List[String](),
        10,
        100,
    )


def _point(end: String, v: String) -> String:
    return (
        String('{"interval":{"endTime":"') + end + '"},"value":{"int64Value":"' + v + '"}}'
    )


def _series(code: String, zone: String, var points: List[String]) -> String:
    var ps = String("")
    for i in range(len(points)):
        if i > 0:
            ps += ","
        ps += points[i]
    return (
        String('{"metric":{"type":"run.googleapis.com/request_count","labels":'
        '{"response_code":"')
        + code
        + '"}},"resource":{"type":"cloud_run_revision","labels":{"project_id":'
        '"demo-project","zone":"'
        + zone
        + '"}},"valueType":"INT64","points":['
        + ps
        + "]}"
    )


def test_default_host() raises:
    var r = _Reader(
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector()),
        StaticTokenSource(String("t")),
        String("demo-project"),
    )
    assert_equal(r.host(), String(MONITORING_DEFAULT_HOST))
    with assert_raises(contains="a byte a project id never does"):
        _ = _Reader(
            HttpClient[ScriptedConnector].with_defaults(ScriptedConnector()),
            StaticTokenSource(String("t")),
            String("projects/x"),
        )


def test_refusals_before_any_call() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var r = ErasedMetricsReader.erase(_reader(capture, List[String]()))
    assert_equal(r.refusal(_query(MetricsAggregation.raw())), String(""))
    assert_equal(r.refusal(_query(MetricsAggregation.sum())), String(""))
    assert_true(
        "at least 60000 ms" in r.refusal(_query(MetricsAggregation.sum(), Int64(30_000)))
    )
    assert_true(
        "at least 60000 ms" in r.refusal(_query(MetricsAggregation.sum(), Int64(60_500)))
    )
    var raw_grouped = _query(MetricsAggregation.raw())
    raw_grouped.group_by.append(String("response_code"))
    assert_true("groups only aligned series" in r.refusal(raw_grouped))
    var bad_key = _query(MetricsAggregation.sum())
    bad_key.matchers.append(MetricsMatcher.eq(String('a" OR x="'), String("1")))
    assert_true("not a plain identifier" in r.refusal(bad_key))
    var bad_group = _query(MetricsAggregation.sum())
    bad_group.group_by.append(String("metric.labels.x"))
    assert_true("not a plain identifier" in r.refusal(bad_group))
    var unnamed = _query(MetricsAggregation.sum())
    unnamed.metric = String("")
    assert_true("name a Cloud Monitoring metric type" in r.refusal(unnamed))
    with assert_raises(contains="Cloud Monitoring: a step of 30000 ms"):
        _ = r.read(_query(MetricsAggregation.sum(), Int64(30_000)))
    assert_equal(len(capture[]), 0)


def test_the_request_on_the_wire() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var answers = List[String]()
    answers.append(_ok(String("{}")))
    var r = ErasedMetricsReader.erase(_reader(capture, answers^))
    var q = _query(MetricsAggregation.rate(), Int64(120_000))
    q.matchers.append(MetricsMatcher.eq(String("resource.service_name"), String("api")))
    q.group_by.append(String("response_code"))
    var page = r.read(q)
    assert_equal(len(page.series), 0)
    assert_false(page.truncated)
    assert_equal(page.sources_scanned, 1)
    var wire = _wire(capture)
    assert_true(
        wire.startswith(
            "GET /v3/projects/demo-project/timeSeries"
            "?filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
            "%20AND%20resource.labels.service_name%20%3D%20%22api%22"
            "&interval.startTime=2026-09-12T09%3A59%3A59.999999999Z"
            "&interval.endTime=2026-09-12T10%3A02%3A00Z"
            "&aggregation.alignmentPeriod=120s"
            "&aggregation.perSeriesAligner=ALIGN_RATE"
            "&aggregation.crossSeriesReducer=REDUCE_SUM"
            "&aggregation.groupByFields=metric.label.response_code"
            "&view=FULL&pageSize=1000 HTTP/1.1\r\n"
        ),
        wire,
    )
    assert_true(wire.lower().find("authorization: bearer test-token\r\n") >= 0, wire)


def test_pages_merge_and_resource_labels() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var first = (
        String('{"timeSeries":[')
        + _series(
            String("200"),
            String("us-central1-a"),
            [_point(String("2026-09-12T10:02:00Z"), String("5")),
             _point(String("2026-09-12T10:01:00Z"), String("4"))],
        )
        + '],"nextPageToken":"p2"}'
    )
    var second = (
        String('{"timeSeries":[')
        + _series(
            String("200"),
            String("us-central1-a"),
            [_point(String("2026-09-12T10:00:00Z"), String("3"))],
        )
        + ","
        + _series(
            String("500"),
            String("us-central1-a"),
            [_point(String("2026-09-12T10:01:00Z"), String("1"))],
        )
        + "]}"
    )
    var answers = List[String]()
    answers.append(_ok(first))
    answers.append(_ok(second))
    var r = ErasedMetricsReader.erase(_reader(capture, answers^))
    var q = _query(MetricsAggregation.sum())
    q.group_by.append(String("resource.zone"))
    var page = r.read(q)
    assert_equal(page.sources_scanned, 2)
    assert_false(page.truncated)
    assert_equal(len(page.series), 2)
    ref a = page.series[0]
    assert_equal(a.label(String("response_code")).value(), String("200"))
    assert_equal(a.label(String("resource.zone")).value(), String("us-central1-a"))
    assert_false(Bool(a.label(String("resource.project_id"))))
    assert_false(Bool(a.label(String("project_id"))))
    assert_equal(len(a.samples), 3)
    assert_equal(a.samples[0].time_ns, _T)
    assert_equal(a.samples[0].value, 3.0)
    assert_equal(a.samples[2].time_ns, _T + 2 * _MIN)
    assert_equal(a.samples[2].value, 5.0)
    assert_equal(page.series[1].label(String("response_code")).value(), String("500"))
    var wire = _wire(capture)
    assert_true("&aggregation.groupByFields=resource.label.zone&" in wire, wire)
    assert_true("&pageToken=p2 HTTP/1.1\r\n" in wire, wire)


def _revision(rev: String, labels_first: Bool, var points: List[String]) -> String:
    """A request_count series of revision `rev`, its resource labels in one
    wire order or the other."""
    var ps = String("")
    for i in range(len(points)):
        if i > 0:
            ps += ","
        ps += points[i]
    var labels = String('"zone":"z","revision_name":"') + rev + '"'
    if not labels_first:
        labels = String('"revision_name":"') + rev + '","zone":"z"'
    return (
        String('{"metric":{"type":"run.googleapis.com/request_count","labels":'
        '{"response_code":"200"}},"resource":{"type":"cloud_run_revision",'
        '"labels":{')
        + labels
        + '}},"valueType":"INT64","points":['
        + ps
        + "]}"
    )


def test_series_apart_in_an_unnamed_label_are_not_merged() raises:
    # Two revisions of one service, the query naming no resource label: two
    # series, each with its own points, and a revision continued on the next
    # page (its labels in another order) is merged into its own series only.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var first = (
        String('{"timeSeries":[')
        + _revision(String("api-001"), True, [_point(String("2026-09-12T10:02:00Z"), String("5"))])
        + ","
        + _revision(String("api-002"), True, [_point(String("2026-09-12T10:02:00Z"), String("7"))])
        + '],"nextPageToken":"p2"}'
    )
    var second = (
        String('{"timeSeries":[')
        + _revision(String("api-001"), False, [_point(String("2026-09-12T10:01:00Z"), String("4"))])
        + "]}"
    )
    var answers = List[String]()
    answers.append(_ok(first))
    answers.append(_ok(second))
    var r = ErasedMetricsReader.erase(_reader(capture, answers^))
    var page = r.read(_query(MetricsAggregation.raw()))
    assert_equal(len(page.series), 2)
    ref a = page.series[0]
    ref b = page.series[1]
    assert_false(Bool(a.label(String("resource.revision_name"))))
    assert_equal(len(a.samples), 2)
    assert_equal(a.samples[0].time_ns, _T + _MIN)
    assert_equal(a.samples[0].value, 4.0)
    assert_equal(a.samples[1].time_ns, _T + 2 * _MIN)
    assert_equal(a.samples[1].value, 5.0)
    assert_equal(len(b.samples), 1)
    assert_equal(b.samples[0].value, 7.0)


def test_limits_truncate() raises:
    # Series limit: the second series is cut.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var body = (
        String('{"timeSeries":[')
        + _series(String("200"), String("z"), [_point(String("2026-09-12T10:01:00Z"), String("1"))])
        + ","
        + _series(String("500"), String("z"), [_point(String("2026-09-12T10:01:00Z"), String("2"))])
        + "]}"
    )
    var answers = List[String]()
    answers.append(_ok(body))
    var r = _reader(capture, answers^)
    var q = _query(MetricsAggregation.sum())
    q.series_limit = 1
    q.point_limit = 7
    var page = r.read(q)
    assert_true(page.truncated)
    assert_equal(len(page.series), 1)
    assert_true("&pageSize=7 HTTP/1.1" in _wire(capture), _wire(capture))

    # Point limit: the newest points are kept.
    var capture2 = ArcPointer[List[UInt8]](List[UInt8]())
    var body2 = (
        String('{"timeSeries":[')
        + _series(
            String("200"),
            String("z"),
            [_point(String("2026-09-12T10:02:00Z"), String("3")),
             _point(String("2026-09-12T10:01:00Z"), String("2")),
             _point(String("2026-09-12T10:00:00Z"), String("1"))],
        )
        + "]}"
    )
    var answers2 = List[String]()
    answers2.append(_ok(body2))
    var r2 = _reader(capture2, answers2^)
    var q2 = _query(MetricsAggregation.sum())
    q2.point_limit = 2
    var page2 = r2.read(q2)
    assert_true(page2.truncated)
    assert_equal(len(page2.series[0].samples), 2)
    assert_equal(page2.series[0].samples[0].value, 2.0)
    assert_equal(page2.series[0].samples[1].value, 3.0)

    # Page limit, and executionErrors.
    var capture3 = ArcPointer[List[UInt8]](List[UInt8]())
    var answers3 = List[String]()
    answers3.append(_ok(String('{"nextPageToken":"more"}')))
    var r3 = _reader(capture3, answers3^)
    r3.set_max_pages(1)
    assert_true(r3.read(_query(MetricsAggregation.sum())).truncated)
    var capture4 = ArcPointer[List[UInt8]](List[UInt8]())
    var answers4 = List[String]()
    answers4.append(_ok(String('{"executionErrors":[{"code":4,"message":"x"}]}')))
    var r4 = _reader(capture4, answers4^)
    assert_true(r4.read(_query(MetricsAggregation.raw())).truncated)


def test_an_error_answer_raises_without_the_body() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var body = String(
        '{"error":{"code":403,"message":"Permission monitoring.timeSeries.list'
        ' denied on resource projects/demo-secret","status":"PERMISSION_DENIED"}}'
    )
    var answers = List[String]()
    answers.append(String(unsafe_from_utf8=Span(_answer("403 Forbidden", body))))
    var r = _reader(capture, answers^)
    try:
        _ = r.read(_query(MetricsAggregation.sum()))
        raise Error("read returned on a 403")
    except e:
        var msg = String(e)
        assert_true(
            msg.startswith("GET ListTimeSeries: HTTP 403, PERMISSION_DENIED (code 7)"),
            msg,
        )
        assert_false("demo-secret" in msg, msg)


def main() raises:
    test_default_host()
    test_refusals_before_any_call()
    test_the_request_on_the_wire()
    test_pages_merge_and_resource_labels()
    test_series_apart_in_an_unnamed_label_are_not_merged()
    test_limits_truncate()
    test_an_error_answer_raises_without_the_body()
    print("OK")
