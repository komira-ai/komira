# CloudMonitoringMetricsReader at its edges, over komira_http_core's
# ScriptedConnector (no socket) with a shared write capture. Each series is
# compared whole (metric, every label in order, every sample).
#
# What is pinned, and what each part would catch:
#   * The aligner and reducer of every aggregation code (raw, the six the
#     seam names, and codes outside them) with 0, 1 and 2 group-by keys: a
#     wrong name, a reducer sent for an ungrouped query, or one sent for
#     raw or an unknown code fails here; and the request line of each of the
#     six aggregations, whole, grouped by a metric and a resource label.
#   * A raw read sends no aggregation, whatever its step.
#   * The interval start one nanosecond before the query's start, and the
#     epoch itself for start 0 and 1 (start 2: one nanosecond after it);
#     the page size as series x points clamped to [1, 100000] (0, 1, 2,
#     100000 exactly, above it).
#   * Paging: max pages 0 and -5 read as 1, 2 of 3 pages truncated, 3 of 3
#     not, and the default of 10.
#   * The merge of one series continued on later pages: interleaved times,
#     a later page holding the older points, equal times (the earlier
#     page's point first), three pages.
#   * The identity: series apart only in their resource type, in the key
#     of a resource label or in their metric type stay two;
#     three labels in three wire orders are one series; label text that
#     would read as another label set without the length prefixes stays
#     apart.
#   * The series limit (cut and truncated above it, not truncated at it, a
#     cut series not resurrected by a later page, a kept series still merged
#     after the limit is reached, limit 0), the point limit (not truncated
#     at it, newest kept above it, applied after a merge), executionErrors
#     on a later page.
#   * Resource labels kept only when a matcher or group-by names
#     `resource.<k>` (a matcher alone, a group-by alone, both: once), in
#     wire order, after the metric labels.
#   * The refusals: each step boundary (59000, 60000, 60001, 61000, 0 ms),
#     a raw read's step ignored, a bad key at index 1, and the order of the
#     checks (metric, matchers, group-by, raw grouping, step); `read`
#     raises the refusal with nothing sent.
#   * `set_host` moves `host()`.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import StaticTokenSource
from komira_gcp_monitoring import (
    CloudMonitoringMetricsReader,
    monitoring_aligner,
    monitoring_reducer,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_metrics_reader import (
    MetricsAggregation,
    MetricsLabel,
    MetricsMatcher,
    MetricsPage,
    MetricsQuery,
    MetricsSample,
    MetricsSeriesData,
)

comptime _NS = Int64(1_000_000_000)
comptime _T = Int64(1789207200) * _NS  # 2026-09-12T10:00:00Z
comptime _MIN = Int64(60) * _NS
comptime _Reader = CloudMonitoringMetricsReader[ScriptedConnector, StaticTokenSource]
comptime _METRIC = "run.googleapis.com/request_count"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> String:
    return (
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ")
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _reader(capture: ArcPointer[List[UInt8]], var bodies: List[String]) raises -> _Reader:
    """A reader at a plaintext test endpoint answering each dial with a 200
    carrying the next of `bodies`."""
    var conn = ScriptedConnector()
    for i in range(len(bodies)):
        var stream = ScriptedStream.from_read_script_with_capture(
            _bytes(_ok(bodies[i])), capture
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
    r.set_host(String("192.0.2.1"), 8085, plaintext=True)
    return r^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _request_lines(capture: ArcPointer[List[UInt8]]) -> List[String]:
    var out = List[String]()
    var wire = _wire(capture)
    var at = wire.find("GET ")
    while at >= 0:
        var end = wire.find("\r\n", at)
        out.append(String(wire[byte=at:end]))
        at = wire.find("GET ", end)
    return out^


def _query(agg: MetricsAggregation, step_ms: Int64 = 60_000) -> MetricsQuery:
    return MetricsQuery(
        _T,
        _T + 2 * _MIN,
        String(_METRIC),
        List[MetricsMatcher](),
        agg,
        step_ms,
        List[String](),
        10,
        100,
    )


def _point(minute: Int, v: Int) -> String:
    """A point ending `minute` minutes after 10:00 (0..59), value `v`."""
    var mm = String(minute) if minute >= 10 else String("0") + String(minute)
    return (
        String('{"interval":{"endTime":"2026-09-12T10:')
        + mm
        + ':00Z"},"value":{"int64Value":"'
        + String(v)
        + '"}}'
    )


def _join(var parts: List[String]) -> String:
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += ","
        out += parts[i]
    return out^


def _series(
    code: String,
    var points: List[String],
    resource_type: String = "cloud_run_revision",
    resource_labels: String = '"zone":"z"',
) -> String:
    return (
        String('{"metric":{"type":"')
        + _METRIC
        + '","labels":{"response_code":"'
        + code
        + '"}},"resource":{"type":"'
        + resource_type
        + '","labels":{'
        + resource_labels
        + '}},"valueType":"INT64","points":['
        + _join(points^)
        + "]}"
    )


def _page(var series: List[String], token: String = "") -> String:
    var out = String('{"timeSeries":[') + _join(series^) + "]"
    if token.byte_length() > 0:
        out += String(',"nextPageToken":"') + token + '"'
    return out + "}"


def _want(var labels: List[String], var minutes: List[Int], var values: List[Int]) -> MetricsSeriesData:
    var s = MetricsSeriesData.named(String(_METRIC))
    for i in range(0, len(labels), 2):
        s.labels.append(MetricsLabel(labels[i].copy(), labels[i + 1].copy()))
    for i in range(len(minutes)):
        s.samples.append(MetricsSample(_T + Int64(minutes[i]) * _MIN, Float64(values[i])))
    return s^


def _check_series(got: MetricsSeriesData, want: MetricsSeriesData) raises:
    assert_equal(got.metric, want.metric)
    assert_equal(len(got.labels), len(want.labels), "labels")
    for i in range(len(want.labels)):
        assert_equal(got.labels[i].key, want.labels[i].key)
        assert_equal(got.labels[i].value, want.labels[i].value)
    assert_equal(len(got.samples), len(want.samples), "samples")
    for i in range(len(want.samples)):
        assert_equal(got.samples[i].time_ns, want.samples[i].time_ns)
        assert_equal(got.samples[i].value, want.samples[i].value)


def _check_page(got: MetricsPage, var want: List[MetricsSeriesData], truncated: Bool, calls: Int) raises:
    assert_equal(len(got.series), len(want), "series")
    for i in range(len(want)):
        _check_series(got.series[i], want[i])
    assert_equal(got.truncated, truncated, "truncated")
    assert_equal(got.sources_scanned, calls, "sources_scanned")


# ── the query mapping ───────────────────────────────────────────────────────


def test_aligner_and_reducer_of_every_code() raises:
    var codes: List[Int] = [-1, 0, 1, 2, 3, 4, 5, 6, 7]
    var aligners: List[String] = [
        String(""), String(""), String("ALIGN_SUM"), String("ALIGN_RATE"),
        String("ALIGN_MEAN"), String("ALIGN_MIN"), String("ALIGN_MAX"),
        String("ALIGN_COUNT"), String(""),
    ]
    var reducers: List[String] = [
        String(""), String(""), String("REDUCE_SUM"), String("REDUCE_SUM"),
        String("REDUCE_MEAN"), String("REDUCE_MIN"), String("REDUCE_MAX"),
        String("REDUCE_SUM"), String(""),
    ]
    for i in range(len(codes)):
        for groups in range(3):
            var q = _query(MetricsAggregation(codes[i]))
            for g in range(groups):
                q.group_by.append(String("k") + String(g))
            var what = String("code ") + String(codes[i]) + " groups " + String(groups)
            assert_equal(monitoring_aligner(q), aligners[i], what)
            assert_equal(
                monitoring_reducer(q), reducers[i] if groups > 0 else String(""), what
            )


def test_request_line_of_each_aggregation() raises:
    var aggs: List[MetricsAggregation] = [
        MetricsAggregation.sum(), MetricsAggregation.rate(), MetricsAggregation.mean(),
        MetricsAggregation.min(), MetricsAggregation.max(), MetricsAggregation.count(),
    ]
    var pairs: List[String] = [
        String("ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM"),
        String("ALIGN_RATE&aggregation.crossSeriesReducer=REDUCE_SUM"),
        String("ALIGN_MEAN&aggregation.crossSeriesReducer=REDUCE_MEAN"),
        String("ALIGN_MIN&aggregation.crossSeriesReducer=REDUCE_MIN"),
        String("ALIGN_MAX&aggregation.crossSeriesReducer=REDUCE_MAX"),
        String("ALIGN_COUNT&aggregation.crossSeriesReducer=REDUCE_SUM"),
    ]
    for i in range(len(aggs)):
        var capture = ArcPointer[List[UInt8]](List[UInt8]())
        var r = _reader(capture, [String("{}")])
        var q = _query(aggs[i], Int64(300_000))
        q.group_by.append(String("response_code"))
        q.group_by.append(String("resource.zone"))
        _check_page(r.read(q), List[MetricsSeriesData](), False, 1)
        var lines = _request_lines(capture)
        assert_equal(len(lines), 1)
        assert_equal(
            lines[0],
            String(
                "GET /v3/projects/demo-project/timeSeries"
                "?filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
                "&interval.endTime=2026-09-12T10%3A02%3A00Z"
                "&interval.startTime=2026-09-12T09%3A59%3A59.999999999Z"
                "&aggregation.alignmentPeriod=300s"
                "&aggregation.perSeriesAligner="
            )
            + pairs[i]
            + "&aggregation.groupByFields=metric.label.response_code"
            + "&aggregation.groupByFields=resource.label.zone"
            + "&pageSize=1000 HTTP/1.1",
        )


def test_raw_sends_no_aggregation_whatever_its_step() raises:
    var steps: List[Int64] = [Int64(0), Int64(1), Int64(60_000), Int64(61_500)]
    for i in range(len(steps)):
        var capture = ArcPointer[List[UInt8]](List[UInt8]())
        var r = _reader(capture, [String("{}")])
        _ = r.read(_query(MetricsAggregation.raw(), steps[i]))
        assert_equal(
            _request_lines(capture)[0],
            String(
                "GET /v3/projects/demo-project/timeSeries"
                "?filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
                "&interval.endTime=2026-09-12T10%3A02%3A00Z"
                "&interval.startTime=2026-09-12T09%3A59%3A59.999999999Z"
                "&pageSize=1000 HTTP/1.1"
            ),
        )


def _sent(q: MetricsQuery) raises -> String:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var r = _reader(capture, [String("{}")])
    _ = r.read(q)
    return _request_lines(capture)[0]


def _start_time(line: String) -> String:
    """The `interval.startTime` value of a request line, as sent."""
    var key = String("&interval.startTime=")
    var at = line.find(key) + key.byte_length()
    return String(line[byte=at : line.find("&", at)])


def test_interval_start_at_the_epoch() raises:
    # Start 0 is sent as the epoch itself (never one nanosecond before it,
    # which would be refused), start 1 as the epoch too, start 2 as the
    # epoch plus one nanosecond: the same instant spelled with a fraction.
    var q0 = _query(MetricsAggregation.raw())
    q0.start_ns = Int64(0)
    var q1 = _query(MetricsAggregation.raw())
    q1.start_ns = Int64(1)
    var q2 = _query(MetricsAggregation.raw())
    q2.start_ns = Int64(2)
    var at0 = _start_time(_sent(q0))
    var at1 = _start_time(_sent(q1))
    var at2 = _start_time(_sent(q2))
    assert_true(at0.endswith("T00%3A00%3A00Z"), at0)
    assert_equal(at1, at0)
    assert_equal(at2, String(at0[byte = 0 : at0.byte_length() - 1]) + ".000000001Z")


def test_page_size_clamped() raises:
    var series: List[Int] = [0, 5, 1, 1, 100, 1000, 100001, 1]
    var points: List[Int] = [5, 0, 1, 2, 1000, 1000, 1, 100000]
    var want: List[Int] = [1, 1, 1, 2, 100000, 100000, 100000, 100000]
    for i in range(len(series)):
        var q = _query(MetricsAggregation.raw())
        q.series_limit = series[i]
        q.point_limit = points[i]
        var line = _sent(q)
        assert_true(
            line.endswith(String("&pageSize=") + String(want[i]) + " HTTP/1.1"), line
        )


# ── paging ──────────────────────────────────────────────────────────────────


def _token_pages(n: Int, last_has_token: Bool) -> List[String]:
    var out = List[String]()
    for i in range(n):
        if i == n - 1 and not last_has_token:
            out.append(String("{}"))
        else:
            out.append(String('{"nextPageToken":"p') + String(i + 2) + '"}')
    return out^


def test_max_pages() raises:
    var settings: List[Int] = [0, -5, 1, 2, 3]
    var pages: List[Int] = [3, 3, 3, 3, 3]
    var last_token: List[Bool] = [True, True, True, True, False]
    var calls: List[Int] = [1, 1, 1, 2, 3]
    var truncated: List[Bool] = [True, True, True, True, False]
    for i in range(len(settings)):
        var capture = ArcPointer[List[UInt8]](List[UInt8]())
        var r = _reader(capture, _token_pages(pages[i], last_token[i]))
        r.set_max_pages(settings[i])
        var page = r.read(_query(MetricsAggregation.raw()))
        _check_page(page, List[MetricsSeriesData](), truncated[i], calls[i])
        var lines = _request_lines(capture)
        assert_equal(len(lines), calls[i])
        for k in range(1, len(lines)):
            assert_true(lines[k].endswith(String("&pageToken=p") + String(k + 1) + " HTTP/1.1"), lines[k])
    # The default: ten calls, then truncated with a token left.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var r = _reader(capture, _token_pages(11, True))
    _check_page(r.read(_query(MetricsAggregation.raw())), List[MetricsSeriesData](), True, 10)
    assert_equal(len(_request_lines(capture)), 10)


def _read_pages(var bodies: List[String], q: MetricsQuery) raises -> MetricsPage:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var r = _reader(capture, bodies^)
    return r.read(q)


def test_merge_across_pages() raises:
    var raw = _query(MetricsAggregation.raw())
    var code: List[String] = [String("response_code"), String("200")]
    # Interleaved: the first page holds 1 and 3, the second 2 and 4.
    _check_page(
        _read_pages(
            [
                _page([_series(String("200"), [_point(3, 30), _point(1, 10)])], String("p2")),
                _page([_series(String("200"), [_point(4, 40), _point(2, 20)])]),
            ],
            raw,
        ),
        [_want(code.copy(), [1, 2, 3, 4], [10, 20, 30, 40])],
        False,
        2,
    )
    # The later page holds the older points.
    _check_page(
        _read_pages(
            [
                _page([_series(String("200"), [_point(5, 50)])], String("p2")),
                _page([_series(String("200"), [_point(2, 20), _point(1, 10)])]),
            ],
            raw,
        ),
        [_want(code.copy(), [1, 2, 5], [10, 20, 50])],
        False,
        2,
    )
    # Equal times: the earlier page's point first; then three pages.
    _check_page(
        _read_pages(
            [
                _page([_series(String("200"), [_point(1, 11)])], String("p2")),
                _page([_series(String("200"), [_point(1, 22)])], String("p3")),
                _page([_series(String("200"), [_point(1, 33), _point(0, 5)])]),
            ],
            raw,
        ),
        [_want(code.copy(), [0, 1, 1, 1], [5, 11, 22, 33])],
        False,
        3,
    )


def test_identity() raises:
    var raw = _query(MetricsAggregation.raw())
    var code: List[String] = [String("response_code"), String("200")]
    # Apart only in the resource type: two series.
    _check_page(
        _read_pages(
            [_page([
                _series(String("200"), [_point(1, 1)], String("cloud_run_revision")),
                _series(String("200"), [_point(1, 2)], String("cloud_run_job")),
            ])],
            raw,
        ),
        [_want(code.copy(), [1], [1]), _want(code.copy(), [1], [2])],
        False,
        1,
    )
    # Apart only in the key of a resource label, its value the same: two.
    _check_page(
        _read_pages(
            [_page([
                _series(String("200"), [_point(1, 1)], resource_labels='"zone":"z"'),
                _series(String("200"), [_point(1, 2)], resource_labels='"region":"z"'),
            ])],
            raw,
        ),
        [_want(code.copy(), [1], [1]), _want(code.copy(), [1], [2])],
        False,
        1,
    )
    # Apart only in the metric type: two, each named by its own.
    var other = _series(String("200"), [_point(1, 2)]).replace(
        String(_METRIC), String("run.googleapis.com/request_count_other")
    )
    var two_types = _read_pages(
        [_page([_series(String("200"), [_point(1, 1)]), other])], raw
    )
    assert_equal(len(two_types.series), 2)
    _check_series(two_types.series[0], _want(code.copy(), [1], [1]))
    var renamed = _want(code.copy(), [1], [2])
    renamed.metric = String("run.googleapis.com/request_count_other")
    _check_series(two_types.series[1], renamed)
    # Three labels in three wire orders: one series.
    _check_page(
        _read_pages(
            [
                _page([_series(String("200"), [_point(3, 3)], resource_labels='"a":"1","b":"2","c":"3"')], String("p2")),
                _page([_series(String("200"), [_point(2, 2)], resource_labels='"c":"3","a":"1","b":"2"')], String("p3")),
                _page([_series(String("200"), [_point(1, 1)], resource_labels='"b":"2","c":"3","a":"1"')]),
            ],
            raw,
        ),
        [_want(code.copy(), [1, 2, 3], [1, 2, 3])],
        False,
        3,
    )
    # Two label sets that would spell one key without the length prefixes.
    var forged = (
        String('{"metric":{"type":"')
        + _METRIC
        + '","labels":{"a":"x|b=y","c":"z"}},"points":['
        + _point(1, 1)
        + ']},{"metric":{"type":"'
        + _METRIC
        + '","labels":{"a":"x","b=y|c":"z"}},"points":['
        + _point(1, 2)
        + "]}"
    )
    _check_page(
        _read_pages([String('{"timeSeries":[') + forged + "]}"], raw),
        [
            _want([String("a"), String("x|b=y"), String("c"), String("z")], [1], [1]),
            _want([String("a"), String("x"), String("b=y|c"), String("z")], [1], [2]),
        ],
        False,
        1,
    )


def test_limits() raises:
    var three = _page([
        _series(String("200"), [_point(1, 1)]),
        _series(String("404"), [_point(1, 2)]),
        _series(String("500"), [_point(1, 3)]),
    ])
    var c200: List[String] = [String("response_code"), String("200")]
    var c404: List[String] = [String("response_code"), String("404")]
    var limited = _query(MetricsAggregation.raw())
    limited.series_limit = 2
    _check_page(
        _read_pages([three.copy()], limited),
        [_want(c200.copy(), [1], [1]), _want(c404.copy(), [1], [2])],
        True,
        1,
    )
    var at_limit = _query(MetricsAggregation.raw())
    at_limit.series_limit = 3
    var page = _read_pages([three.copy()], at_limit)
    assert_equal(len(page.series), 3)
    assert_false(page.truncated)
    var none = _query(MetricsAggregation.raw())
    none.series_limit = 0
    _check_page(_read_pages([three.copy()], none), List[MetricsSeriesData](), True, 1)
    _check_page(_read_pages([String("{}")], none), List[MetricsSeriesData](), False, 1)
    # Limit 1: the cut series stays cut on the next page; the kept one merges.
    var one = _query(MetricsAggregation.raw())
    one.series_limit = 1
    _check_page(
        _read_pages(
            [
                _page([_series(String("200"), [_point(2, 2)]), _series(String("404"), [_point(2, 9)])], String("p2")),
                _page([_series(String("404"), [_point(1, 8)]), _series(String("200"), [_point(1, 1)])]),
            ],
            one,
        ),
        [_want(c200.copy(), [1, 2], [1, 2])],
        True,
        2,
    )
    # Point limit: none cut at it; the newest kept above it, after a merge.
    var two_points = _query(MetricsAggregation.raw())
    two_points.point_limit = 2
    _check_page(
        _read_pages([_page([_series(String("200"), [_point(2, 2), _point(1, 1)])])], two_points),
        [_want(c200.copy(), [1, 2], [1, 2])],
        False,
        1,
    )
    _check_page(
        _read_pages(
            [
                _page([_series(String("200"), [_point(3, 3), _point(1, 1)])], String("p2")),
                _page([_series(String("200"), [_point(2, 2)])]),
            ],
            two_points,
        ),
        [_want(c200.copy(), [2, 3], [2, 3])],
        True,
        2,
    )
    # executionErrors on the second page only.
    _check_page(
        _read_pages(
            [String('{"nextPageToken":"p2"}'), String('{"executionErrors":[{"code":4}]}')],
            _query(MetricsAggregation.raw()),
        ),
        List[MetricsSeriesData](),
        True,
        2,
    )


def test_resource_labels_named_by_the_query() raises:
    var q = _query(MetricsAggregation.sum())
    q.matchers.append(MetricsMatcher.eq(String("resource.zone"), String("z")))
    q.matchers.append(MetricsMatcher.eq(String("response_code"), String("200")))
    # Named by a matcher only.
    q.matchers.append(MetricsMatcher.neq(String("resource.region"), String("h")))
    q.group_by.append(String("resource.revision_name"))
    q.group_by.append(String("project_id"))
    # Named twice (a matcher and a group-by key): kept once.
    q.group_by.append(String("resource.zone"))
    var labels = String('"project_id":"p","revision_name":"r","region":"g","zone":"z"')
    _check_page(
        _read_pages([_page([_series(String("200"), [_point(1, 1)], resource_labels=labels)])], q),
        [_want(
            [
                String("response_code"), String("200"),
                String("resource.revision_name"), String("r"),
                String("resource.region"), String("g"),
                String("resource.zone"), String("z"),
            ],
            [1],
            [1],
        )],
        False,
        1,
    )


# ── refusals ────────────────────────────────────────────────────────────────


def _step_refusal(ms: Int64) -> String:
    return (
        String("a step of ")
        + String(ms)
        + " ms is not a Cloud Monitoring alignment period: use whole seconds,"
        + " at least 60000 ms"
    )


def _key_refusal(key: String) -> String:
    return (
        String("the label key '")
        + key
        + "' is not a plain identifier (letters, digits, '_'), optionally after 'resource.'"
    )


def test_refusals() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var r = _reader(capture, List[String]())
    var steps: List[Int64] = [Int64(0), Int64(59_000), Int64(59_999), Int64(60_000), Int64(60_001), Int64(61_000)]
    var step_ok: List[Bool] = [False, False, False, True, False, True]
    for i in range(len(steps)):
        var want = String("") if step_ok[i] else _step_refusal(steps[i])
        assert_equal(r.refusal(_query(MetricsAggregation.mean(), steps[i])), want)
        assert_equal(r.refusal(_query(MetricsAggregation.raw(), steps[i])), String(""))
    var second_matcher = _query(MetricsAggregation.sum())
    second_matcher.matchers.append(MetricsMatcher.eq(String("ok"), String("1")))
    second_matcher.matchers.append(MetricsMatcher.eq(String("b-d"), String("1")))
    assert_equal(r.refusal(second_matcher), _key_refusal(String("b-d")))
    var second_group = _query(MetricsAggregation.sum())
    second_group.group_by.append(String("ok"))
    second_group.group_by.append(String("g h"))
    assert_equal(r.refusal(second_group), _key_refusal(String("g h")))
    # The order: metric, matchers, group-by keys, raw grouping, step.
    var all_bad = _query(MetricsAggregation.raw(), Int64(1))
    all_bad.matchers.append(MetricsMatcher.eq(String("m-1"), String("1")))
    all_bad.group_by.append(String("g-1"))
    all_bad.metric = String("")
    assert_equal(r.refusal(all_bad), String("name a Cloud Monitoring metric type"))
    all_bad.metric = String("m")
    assert_equal(r.refusal(all_bad), _key_refusal(String("m-1")))
    all_bad.matchers = List[MetricsMatcher]()
    assert_equal(r.refusal(all_bad), _key_refusal(String("g-1")))
    all_bad.group_by = [String("g")]
    assert_true("groups only aligned series" in r.refusal(all_bad))
    var short = _query(MetricsAggregation.max(), Int64(1))
    short.metric = String("m")
    assert_equal(r.refusal(short), _step_refusal(Int64(1)))
    try:
        _ = r.read(second_group)
        raise Error("read a refused query")
    except e:
        assert_equal(String(e), String("Cloud Monitoring: ") + _key_refusal(String("g h")))
    assert_equal(len(capture[]), 0)


def test_set_host() raises:
    var r = _Reader(
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector()),
        StaticTokenSource(String("t")),
        String("demo-project"),
    )
    r.set_host(String("monitoring.example.test"), 443)
    assert_equal(r.host(), String("monitoring.example.test"))


def main() raises:
    test_aligner_and_reducer_of_every_code()
    test_request_line_of_each_aggregation()
    test_raw_sends_no_aggregation_whatever_its_step()
    test_interval_start_at_the_epoch()
    test_page_size_clamped()
    test_max_pages()
    test_merge_across_pages()
    test_identity()
    test_limits()
    test_resource_labels_named_by_the_query()
    test_refusals()
    test_set_host()
    print("OK")
