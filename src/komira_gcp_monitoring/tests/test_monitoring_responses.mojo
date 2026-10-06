# `timeSeries.list` responses.
#
# The bodies are hand-written in the form the Cloud Monitoring v3 reference
# documents for ListTimeSeriesResponse and TimeSeries: `int64Value` is a JSON
# string, `doubleValue` a number (or "NaN"/"Infinity"), points newest first
# with an RFC 3339 `endTime`. The parse returns points oldest first, keeps
# metric and resource labels apart, carries `nextPageToken` and counts
# `executionErrors`. An empty or absent `timeSeries` is an answer with no
# series. A distribution value is refused with a sentence naming the metric;
# a malformed body raises naming its size, never its bytes.

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_gcp_monitoring import parse_time_series_list_response

comptime _T = Int64(1789207200) * Int64(1_000_000_000)
comptime _MIN = Int64(60) * Int64(1_000_000_000)


def test_int64_and_double_series() raises:
    var page = parse_time_series_list_response(
        String(
            '{"timeSeries":[{"metric":{"type":"run.googleapis.com/request_count",'
            '"labels":{"response_code":"200","response_code_class":"2xx"}},'
            '"resource":{"type":"cloud_run_revision","labels":{"project_id":'
            '"demo-project","service_name":"api"}},"metricKind":"DELTA",'
            '"valueType":"INT64","points":['
            '{"interval":{"startTime":"2026-09-12T10:01:00Z","endTime":"2026-09-12T10:02:00Z"},'
            '"value":{"int64Value":"9007199254740993"}},'
            '{"interval":{"startTime":"2026-09-12T10:00:00Z","endTime":"2026-09-12T10:01:00Z"},'
            '"value":{"int64Value":"42"}}]},'
            '{"metric":{"type":"m2"},"valueType":"DOUBLE","points":['
            '{"interval":{"endTime":"2026-09-12T10:00:00.5Z"},"value":{"doubleValue":"NaN"}},'
            '{"interval":{"endTime":"2026-09-12T10:00:00Z"},"value":{"doubleValue":0.25}}]}],'
            '"nextPageToken":"page-2","executionErrors":[{"code":4}],"unit":"1"}'
        )
    )
    assert_equal(page.next_page_token, String("page-2"))
    assert_equal(page.execution_errors, 1)
    assert_equal(len(page.series), 2)
    ref a = page.series[0]
    assert_equal(a.metric_type, String("run.googleapis.com/request_count"))
    assert_equal(a.value_type, String("INT64"))
    assert_equal(len(a.metric_labels), 2)
    assert_equal(a.metric_labels[0].key, String("response_code"))
    assert_equal(a.resource_labels[1].value, String("api"))
    assert_equal(len(a.points), 2)
    # Oldest first.
    assert_equal(a.points[0].time_ns, _T + _MIN)
    assert_equal(a.points[0].value, 42.0)
    assert_equal(a.points[1].time_ns, _T + 2 * _MIN)
    assert_equal(a.points[1].value, 9007199254740992.0)
    ref b = page.series[1]
    assert_equal(b.points[0].value, 0.25)
    assert_equal(b.points[1].time_ns, _T + 500_000_000)
    assert_true(b.points[1].value != b.points[1].value)


def test_empty_answers() raises:
    var a = parse_time_series_list_response(String("{}"))
    assert_equal(len(a.series), 0)
    assert_equal(a.next_page_token, String(""))
    assert_equal(a.execution_errors, 0)
    var b = parse_time_series_list_response(String('{"timeSeries":[]}'))
    assert_equal(len(b.series), 0)
    var c = parse_time_series_list_response(
        String('{"timeSeries":[{"metric":{"type":"m"},"points":[]}]}')
    )
    assert_equal(len(c.series[0].points), 0)


def test_bool_value() raises:
    var p = parse_time_series_list_response(
        String(
            '{"timeSeries":[{"metric":{"type":"up"},"points":['
            '{"interval":{"endTime":"2026-09-12T10:00:00Z"},"value":{"boolValue":true}}]}]}'
        )
    )
    assert_equal(p.series[0].points[0].value, 1.0)


def test_distribution_is_refused_naming_the_metric() raises:
    with assert_raises(contains="run.googleapis.com/request_latencies has a distribution"):
        _ = parse_time_series_list_response(
            String(
                '{"timeSeries":[{"metric":{"type":"run.googleapis.com/request_latencies"},'
                '"points":[{"interval":{"endTime":"2026-09-12T10:00:00Z"},'
                '"value":{"distributionValue":{"count":"3"}}}]}]}'
            )
        )


def test_malformed_bodies_raise_without_echo() raises:
    var secret = String("<html>project demo-secret-project</html>")
    try:
        _ = parse_time_series_list_response(secret)
        raise Error("parsed a non-JSON body")
    except e:
        var msg = String(e)
        assert_true(msg.startswith("ListTimeSeries: the 40-byte response is not JSON"), msg)
        assert_false("demo-secret-project" in msg, msg)
    with assert_raises(contains="timeSeries is not an array"):
        _ = parse_time_series_list_response(String('{"timeSeries":{}}'))
    with assert_raises(contains="series 0 is not an object"):
        _ = parse_time_series_list_response(String('{"timeSeries":[1]}'))
    with assert_raises(contains="no interval or no value"):
        _ = parse_time_series_list_response(
            String('{"timeSeries":[{"points":[{"value":{"int64Value":"1"}}]}]}')
        )
    with assert_raises(contains="endTime is not RFC 3339"):
        _ = parse_time_series_list_response(
            String(
                '{"timeSeries":[{"points":[{"interval":{"endTime":"yesterday"},'
                '"value":{"int64Value":"1"}}]}]}'
            )
        )
    with assert_raises(contains="an int64Value is not a number"):
        _ = parse_time_series_list_response(
            String(
                '{"timeSeries":[{"points":[{"interval":{"endTime":"2026-09-12T10:00:00Z"},'
                '"value":{"int64Value":true}}]}]}'
            )
        )
    with assert_raises(contains="a metric label is not a string"):
        _ = parse_time_series_list_response(
            String('{"timeSeries":[{"metric":{"type":"m","labels":{"k":1}}}]}')
        )


def main() raises:
    test_int64_and_double_series()
    test_empty_answers()
    test_bool_value()
    test_distribution_is_refused_naming_the_metric()
    test_malformed_bodies_raise_without_echo()
    print("OK")
