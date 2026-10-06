# The `timeSeries.list` request the adapter builds for the generated
# client, field by field, its refusals, and the filter.
#
# What the generated client does with the request (the query keys, the
# Timestamp and Duration strings, percent-encoding) is pinned byte for byte
# in komira_gcp_monitoring_client's test_list_time_series_query and, for
# the reader's own requests, in test_monitoring_reader. Here: the name is
# `projects/<project>` and a project that is not a project id is refused;
# the interval is the two instants to the nanosecond; an aggregation is
# sent only when aligned, with the aligner and reducer the pinned protos
# declare; the view is FULL; the page size and token pass through. A filter
# value is quoted with `\` and `"` escaped, and a label key that is not a
# plain identifier is refused, so a matcher cannot extend the filter.

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_gcp_monitoring import (
    TimeSeriesListRequest,
    filter_label_selector,
    group_by_field,
    label_key_refusal,
    list_time_series_request,
    monitoring_filter,
    ns_of_timestamp,
    quote_filter_string,
    time_series_list_name,
    timestamp_of_ns,
)
from komira_gcp_monitoring_client.common import Aggregation_Aligner, Aggregation_Reducer
from komira_metrics_reader import MetricsMatcher

comptime _T = Int64(1789207200) * Int64(1_000_000_000)


def _req(
    aligner: String = "",
    period_s: Int = 0,
    reducer: String = "",
    var groups: List[String] = List[String](),
    page_size: Int = 1000,
    token: String = "",
) -> TimeSeriesListRequest:
    return TimeSeriesListRequest(
        String("demo-project"),
        String('metric.type = "run.googleapis.com/request_count"'),
        _T - 1,
        _T + Int64(3600) * Int64(1_000_000_000),
        period_s,
        aligner.copy(),
        reducer.copy(),
        groups^,
        page_size,
        token.copy(),
    )


def test_name() raises:
    assert_equal(
        time_series_list_name(String("demo-project")),
        String("projects/demo-project"),
    )
    assert_equal(
        time_series_list_name(String("123456789012")),
        String("projects/123456789012"),
    )
    with assert_raises(contains="project is empty"):
        _ = time_series_list_name(String(""))
    with assert_raises(contains="a byte a project id never does"):
        _ = time_series_list_name(String("p/../organizations/1"))
    with assert_raises(contains="a byte a project id never does"):
        _ = time_series_list_name(String("Demo"))


def test_raw_request() raises:
    var r = list_time_series_request(_req())
    assert_equal(r.name, String("projects/demo-project"))
    assert_equal(r.filter, String('metric.type = "run.googleapis.com/request_count"'))
    ref iv = r.interval.value()
    assert_equal(ns_of_timestamp(iv.start_time.value()), _T - 1)
    assert_equal(iv.start_time.value().nanos, Int32(999_999_999))
    assert_equal(ns_of_timestamp(iv.end_time.value()), _T + Int64(3600) * Int64(1_000_000_000))
    assert_false(Bool(r.aggregation))
    assert_false(Bool(r.secondary_aggregation))
    assert_equal(r.view.json_name(), String("FULL"))
    assert_equal(r.page_size, Int32(1000))
    assert_equal(r.page_token, String(""))


def test_aggregated_grouped_request_with_token() raises:
    var groups = List[String]()
    groups.append(String("metric.label.response_code"))
    groups.append(String("resource.label.service_name"))
    var r = list_time_series_request(
        _req("ALIGN_RATE", 300, "REDUCE_SUM", groups^, 50, "tok+/=")
    )
    ref a = r.aggregation.value()
    assert_equal(a.alignment_period.value().to_proto3_json(), String("300s"))
    assert_equal(a.per_series_aligner.number(), Aggregation_Aligner.ALIGN_RATE)
    assert_equal(a.cross_series_reducer.number(), Aggregation_Reducer.REDUCE_SUM)
    assert_equal(len(a.group_by_fields), 2)
    assert_equal(a.group_by_fields[1], String("resource.label.service_name"))
    assert_equal(r.page_size, Int32(50))
    assert_equal(r.page_token, String("tok+/="))
    # Aligned, not reduced: the reducer is left at its zero value, unsent.
    var b = list_time_series_request(_req("ALIGN_SUM", 60))
    assert_equal(b.aggregation.value().cross_series_reducer.number(), 0)


def test_request_refusals() raises:
    with assert_raises(contains="at least 60 s"):
        _ = list_time_series_request(_req("ALIGN_SUM", 30))
    with assert_raises(contains="alignment period with no aligner"):
        _ = list_time_series_request(_req("", 60))
    with assert_raises(contains="reducer needs an aligner"):
        _ = list_time_series_request(_req("", 0, "REDUCE_SUM"))
    var groups = List[String]()
    groups.append(String("metric.label.x"))
    with assert_raises(contains="group-by fields need a cross-series reducer"):
        _ = list_time_series_request(_req("ALIGN_SUM", 60, "", groups^))
    with assert_raises(contains="the aligner ALIGN_SUMS is not declared"):
        _ = list_time_series_request(_req("ALIGN_SUMS", 60))
    with assert_raises(contains="the reducer REDUCE_TOTAL is not declared"):
        _ = list_time_series_request(_req("ALIGN_SUM", 60, "REDUCE_TOTAL"))
    with assert_raises(contains="page size of 0"):
        _ = list_time_series_request(_req("", 0, "", List[String](), 0))
    with assert_raises(contains="page size of 100001"):
        _ = list_time_series_request(_req("", 0, "", List[String](), 100001))
    var empty = _req()
    empty.filter = String("")
    with assert_raises(contains="the filter is empty"):
        _ = list_time_series_request(empty)
    var early = _req()
    early.start_ns = Int64(-1)
    with assert_raises(contains="before 1970"):
        _ = list_time_series_request(early)
    var elsewhere = _req()
    elsewhere.project = String("p/../organizations/1")
    with assert_raises(contains="a byte a project id never does"):
        _ = list_time_series_request(elsewhere)


def test_filter() raises:
    var m = List[MetricsMatcher]()
    m.append(MetricsMatcher.eq(String("response_code"), String("200")))
    m.append(MetricsMatcher.neq(String("resource.service_name"), String('a"b\\c')))
    assert_equal(
        monitoring_filter(String("run.googleapis.com/request_count"), m),
        String(
            'metric.type = "run.googleapis.com/request_count"'
            ' AND metric.labels.response_code = "200"'
            ' AND resource.labels.service_name != "a\\"b\\\\c"'
        ),
    )
    with assert_raises(contains="metric type is empty"):
        _ = monitoring_filter(String(""), List[MetricsMatcher]())
    var inject = List[MetricsMatcher]()
    inject.append(MetricsMatcher.eq(String('x" OR metric.type = "y'), String("1")))
    with assert_raises(contains="is not a plain identifier"):
        _ = monitoring_filter(String("m"), inject)


def test_label_spellings() raises:
    assert_equal(filter_label_selector(String("code")), String("metric.labels.code"))
    assert_equal(
        filter_label_selector(String("resource.zone")), String("resource.labels.zone")
    )
    assert_equal(group_by_field(String("code")), String("metric.label.code"))
    assert_equal(group_by_field(String("resource.zone")), String("resource.label.zone"))
    assert_equal(label_key_refusal(String("response_code_class")), String(""))
    assert_true(label_key_refusal(String("resource.")).byte_length() > 0)
    assert_true(label_key_refusal(String("a.b")).byte_length() > 0)
    assert_true(label_key_refusal(String("")).byte_length() > 0)
    assert_equal(quote_filter_string(String("plain")), String('"plain"'))


def test_times() raises:
    var t = timestamp_of_ns(_T - 1)
    assert_equal(t.seconds, Int64(1789207199))
    assert_equal(t.nanos, Int32(999_999_999))
    assert_equal(t.to_proto3_json(), String("2026-09-12T09:59:59.999999999Z"))
    assert_equal(
        timestamp_of_ns(_T + 500_000_000).to_proto3_json(),
        String("2026-09-12T10:00:00.500Z"),
    )
    assert_equal(ns_of_timestamp(timestamp_of_ns(_T - 1)), _T - 1)
    with assert_raises(contains="before 1970"):
        _ = timestamp_of_ns(Int64(-1))


def main() raises:
    test_name()
    test_raw_request()
    test_aggregated_grouped_request_with_token()
    test_request_refusals()
    test_filter()
    test_label_spellings()
    test_times()
    print("OK")
