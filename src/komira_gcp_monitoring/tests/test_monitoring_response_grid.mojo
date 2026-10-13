# `timeSeries.list` responses over a grid, each series compared whole.
#
# A helper compares every field of a MonitoringSeries (metric type, metric
# labels in order, resource labels in order, resource type, value type,
# every point's time and value) and of the page (series, nextPageToken,
# executionErrors count). The grid: metric and resource absent or present,
# 0..2 labels each, 0..2 points, every value kind the reader carries
# (int64Value as a string, negative too; doubleValue, -0.0 and the
# infinities; boolValue true and false), and 0..2 series and 0..2
# executionErrors. Points arrive newest first and are returned oldest
# first, to the nanosecond. A point with no value, no interval or no end
# time, and a string or distribution value, is refused with the exact
# sentence, at the first point and at the second, in the first series and
# in the second.
#
# The bodies are hand-written in the form the Cloud Monitoring v3 reference
# documents for ListTimeSeriesResponse (proto3 JSON: int64 as a string,
# enum values by name, RFC 3339 times).

from std.testing import assert_equal, assert_true

from komira_gcp_monitoring import MonitoringSeries, parse_time_series_list_response
from komira_metrics_reader import MetricsLabel, MetricsSample

comptime _NS = Int64(1_000_000_000)
comptime _T = Int64(1789207200) * _NS  # 2026-09-12T10:00:00Z


def _labels(var pairs: List[String]) -> List[MetricsLabel]:
    var out = List[MetricsLabel]()
    for i in range(0, len(pairs), 2):
        out.append(MetricsLabel(pairs[i].copy(), pairs[i + 1].copy()))
    return out^


def _samples(var times: List[Int64], var values: List[Float64]) -> List[MetricsSample]:
    var out = List[MetricsSample]()
    for i in range(len(times)):
        out.append(MetricsSample(times[i], values[i]))
    return out^


def _check_labels(got: List[MetricsLabel], want: List[MetricsLabel], what: String) raises:
    assert_equal(len(got), len(want), what)
    for i in range(len(want)):
        assert_equal(got[i].key, want[i].key, what)
        assert_equal(got[i].value, want[i].value, what)


def _same_float(a: Float64, b: Float64) -> Bool:
    """Equal, NaN to NaN, and the sign of zero kept."""
    if a != a or b != b:
        return a != a and b != b
    if a == 0.0 and b == 0.0:
        return (1.0 / a) == (1.0 / b)
    return a == b


def _check_series(got: MonitoringSeries, want: MonitoringSeries) raises:
    assert_equal(got.metric_type, want.metric_type)
    _check_labels(got.metric_labels, want.metric_labels, String("metric labels"))
    _check_labels(got.resource_labels, want.resource_labels, String("resource labels"))
    assert_equal(got.resource_type, want.resource_type)
    assert_equal(got.value_type, want.value_type)
    assert_equal(len(got.points), len(want.points))
    for i in range(len(want.points)):
        assert_equal(got.points[i].time_ns, want.points[i].time_ns)
        assert_true(
            _same_float(got.points[i].value, want.points[i].value),
            String(got.points[i].value) + " != " + String(want.points[i].value),
        )


def _point(end: String, value: String) -> String:
    return String('{"interval":{"endTime":"') + end + '"},"value":' + value + "}"


def _join(var parts: List[String]) -> String:
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += ","
        out += parts[i]
    return out^


def _parse_one(series_json: String) raises -> MonitoringSeries:
    var page = parse_time_series_list_response(
        String('{"timeSeries":[') + series_json + "]}"
    )
    assert_equal(len(page.series), 1)
    return page.series[0].copy()


def test_metric_and_resource_presence_and_label_counts() raises:
    # Metric with two labels, resource with one, two points.
    _check_series(
        _parse_one(
            String('{"metric":{"type":"m1","labels":{"b":"2","a":"1"}},')
            + '"resource":{"type":"gce_instance","labels":{"zone":"z1"}},'
            + '"valueType":"DOUBLE","points":['
            + _point(String("2026-09-12T10:00:02Z"), String('{"doubleValue":2.5}'))
            + ","
            + _point(String("2026-09-12T10:00:01.000000001Z"), String('{"doubleValue":-1}'))
            + "]}"
        ),
        MonitoringSeries(
            String("m1"),
            _labels([String("b"), String("2"), String("a"), String("1")]),
            _labels([String("zone"), String("z1")]),
            String("gce_instance"),
            String("DOUBLE"),
            _samples([_T + _NS + 1, _T + 2 * _NS], [-1.0, 2.5]),
        ),
    )
    # No metric, no resource, no value type: one point.
    _check_series(
        _parse_one(
            String('{"points":[')
            + _point(String("2026-09-12T10:00:00Z"), String('{"boolValue":false}'))
            + "]}"
        ),
        MonitoringSeries(
            String(""),
            List[MetricsLabel](),
            List[MetricsLabel](),
            String(""),
            String("VALUE_TYPE_UNSPECIFIED"),
            _samples([_T], [0.0]),
        ),
    )
    # Metric with no labels, resource with two, no points.
    _check_series(
        _parse_one(
            String('{"metric":{"type":"m3"},"resource":{"type":"r3","labels":')
            + '{"project_id":"p","zone":"z"}},"valueType":"BOOL","points":[]}'
        ),
        MonitoringSeries(
            String("m3"),
            List[MetricsLabel](),
            _labels([String("project_id"), String("p"), String("zone"), String("z")]),
            String("r3"),
            String("BOOL"),
            List[MetricsSample](),
        ),
    )
    # A resource with no metric, its labels absent; a metric with one label.
    _check_series(
        _parse_one(
            String('{"metric":{"type":"m4","labels":{"k":"v"}},')
            + '"resource":{"type":"r4"},"valueType":"INT64"}'
        ),
        MonitoringSeries(
            String("m4"),
            _labels([String("k"), String("v")]),
            List[MetricsLabel](),
            String("r4"),
            String("INT64"),
            List[MetricsSample](),
        ),
    )


def test_every_value_kind() raises:
    var values: List[String] = [
        String('{"int64Value":"-5"}'),
        String('{"int64Value":"0"}'),
        String('{"doubleValue":-0.0}'),
        String('{"doubleValue":"Infinity"}'),
        String('{"doubleValue":"-Infinity"}'),
        String('{"boolValue":true}'),
        String('{"boolValue":false}'),
    ]
    var inf = Float64.MAX_FINITE * 2.0
    var want: List[Float64] = [-5.0, 0.0, -0.0, inf, -inf, 1.0, 0.0]
    for i in range(len(values)):
        var s = _parse_one(
            String('{"metric":{"type":"m"},"points":[')
            + _point(String("2026-09-12T10:00:00Z"), values[i])
            + "]}"
        )
        _check_series(
            s,
            MonitoringSeries(
                String("m"),
                List[MetricsLabel](),
                List[MetricsLabel](),
                String(""),
                String("VALUE_TYPE_UNSPECIFIED"),
                _samples([_T], [want[i]]),
            ),
        )


def test_page_counts() raises:
    var series: List[String] = [
        String('{"metric":{"type":"s0"}}'),
        String('{"metric":{"type":"s1"}}'),
    ]
    var errors: List[String] = [String('{"code":4}'), String('{"code":13,"message":"x"}')]
    for n in range(3):
        for e in range(3):
            var s_parts = List[String]()
            for i in range(n):
                s_parts.append(series[i])
            var e_parts = List[String]()
            for i in range(e):
                e_parts.append(errors[i])
            var page = parse_time_series_list_response(
                String('{"timeSeries":[')
                + _join(s_parts^)
                + '],"nextPageToken":"t'
                + String(n)
                + '","executionErrors":['
                + _join(e_parts^)
                + "]}"
            )
            assert_equal(len(page.series), n)
            for i in range(n):
                assert_equal(page.series[i].metric_type, String("s") + String(i))
            assert_equal(page.next_page_token, String("t") + String(n))
            assert_equal(page.execution_errors, e)


def _refusal(body: String) -> String:
    try:
        _ = parse_time_series_list_response(body)
        return String("")
    except e:
        return String(e)


def test_bad_points_at_each_position() raises:
    var good = _point(String("2026-09-12T10:00:00Z"), String('{"int64Value":"1"}'))
    var bad: List[String] = [
        String('{"value":{"int64Value":"1"}}'),
        String('{"interval":{"endTime":"2026-09-12T10:00:00Z"}}'),
        String('{"interval":{"startTime":"2026-09-12T10:00:00Z"},"value":{"int64Value":"1"}}'),
        _point(String("2026-09-12T10:00:00Z"), String('{"stringValue":"up"}')),
        _point(String("2026-09-12T10:00:00Z"), String('{"distributionValue":{"count":"1"}}')),
    ]
    var number = String(
        " has a distribution or string value, which is not read as a number;"
        " ask for an aggregation that reduces it (mean, sum, count)"
    )
    var want: List[String] = [
        String("ListTimeSeries: a point has no interval or no value"),
        String("ListTimeSeries: a point has no interval or no value"),
        String("ListTimeSeries: a point's interval has no endTime"),
        String("ListTimeSeries: m") + number,
        String("ListTimeSeries: m") + number,
    ]
    var ok_series = String('{"metric":{"type":"m"},"points":[') + good + "]}"
    for i in range(len(bad)):
        var points: List[List[String]] = [
            [bad[i].copy()],
            [bad[i].copy(), good.copy()],
            [good.copy(), bad[i].copy()],
        ]
        for p in range(len(points)):
            var one = String('{"metric":{"type":"m"},"points":[') + _join(points[p].copy()) + "]}"
            assert_equal(_refusal(String('{"timeSeries":[') + one + "]}"), want[i])
            assert_equal(
                _refusal(String('{"timeSeries":[') + ok_series + "," + one + "]}"),
                want[i],
            )
    assert_equal(_refusal(String('{"timeSeries":[') + ok_series + "]}"), String(""))


def main() raises:
    test_metric_and_resource_presence_and_label_counts()
    test_every_value_kind()
    test_page_counts()
    test_bad_points_at_each_position()
    print("OK")
