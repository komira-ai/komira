# The `timeSeries.list` request: the path, the filter and the query string,
# byte for byte, and the refusals.
#
# The expected forms are written here from the Cloud Monitoring v3 REST
# reference for `projects.timeSeries.list` (GET /v3/{name=projects/*}/
# timeSeries) and the `Aggregation` message of the pinned
# google/monitoring/v3/common.proto: query keys are the fields' JSON names,
# nested as `interval.startTime` and `aggregation.alignmentPeriod`, a
# Duration is written `60s`, a Timestamp in RFC 3339, `groupByFields`
# repeats. A filter value is quoted with `\` and `"` escaped, and a label key
# that is not a plain identifier is refused, so a matcher cannot extend the
# filter. Times convert to RFC 3339 and back to the nanosecond.

from std.testing import assert_equal, assert_raises, assert_true

from komira_gcp_monitoring import (
    TimeSeriesListRequest,
    filter_label_selector,
    group_by_field,
    label_key_refusal,
    monitoring_filter,
    ns_of_rfc3339,
    percent_encode,
    quote_filter_string,
    rfc3339_of_ns,
    time_series_list_path,
    time_series_list_query,
)
from komira_metrics_reader import MetricsMatcher


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
        String("2026-09-12T10:00:00Z"),
        String("2026-09-12T11:00:00Z"),
        period_s,
        aligner.copy(),
        reducer.copy(),
        groups^,
        page_size,
        token.copy(),
    )


def test_path() raises:
    assert_equal(
        time_series_list_path(String("demo-project")),
        String("/v3/projects/demo-project/timeSeries"),
    )
    assert_equal(
        time_series_list_path(String("123456789012")),
        String("/v3/projects/123456789012/timeSeries"),
    )
    with assert_raises(contains="project is empty"):
        _ = time_series_list_path(String(""))
    with assert_raises(contains="a byte a project id never does"):
        _ = time_series_list_path(String("p/../organizations/1"))
    with assert_raises(contains="a byte a project id never does"):
        _ = time_series_list_path(String("Demo"))


def test_raw_query() raises:
    assert_equal(
        time_series_list_query(_req()),
        String(
            "filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
            "&interval.startTime=2026-09-12T10%3A00%3A00Z"
            "&interval.endTime=2026-09-12T11%3A00%3A00Z"
            "&view=FULL&pageSize=1000"
        ),
    )


def test_aggregated_grouped_query_with_token() raises:
    var groups = List[String]()
    groups.append(String("metric.label.response_code"))
    groups.append(String("resource.label.service_name"))
    assert_equal(
        time_series_list_query(
            _req("ALIGN_RATE", 300, "REDUCE_SUM", groups^, 50, "tok+/=")
        ),
        String(
            "filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22"
            "&interval.startTime=2026-09-12T10%3A00%3A00Z"
            "&interval.endTime=2026-09-12T11%3A00%3A00Z"
            "&aggregation.alignmentPeriod=300s"
            "&aggregation.perSeriesAligner=ALIGN_RATE"
            "&aggregation.crossSeriesReducer=REDUCE_SUM"
            "&aggregation.groupByFields=metric.label.response_code"
            "&aggregation.groupByFields=resource.label.service_name"
            "&view=FULL&pageSize=50&pageToken=tok%2B%2F%3D"
        ),
    )


def test_query_refusals() raises:
    with assert_raises(contains="at least 60 s"):
        _ = time_series_list_query(_req("ALIGN_SUM", 30))
    with assert_raises(contains="alignment period with no aligner"):
        _ = time_series_list_query(_req("", 60))
    with assert_raises(contains="reducer needs an aligner"):
        _ = time_series_list_query(_req("", 0, "REDUCE_SUM"))
    var groups = List[String]()
    groups.append(String("metric.label.x"))
    with assert_raises(contains="group-by fields need a cross-series reducer"):
        _ = time_series_list_query(_req("ALIGN_SUM", 60, "", groups^))
    with assert_raises(contains="page size of 0"):
        _ = time_series_list_query(_req("", 0, "", List[String](), 0))
    with assert_raises(contains="page size of 100001"):
        _ = time_series_list_query(_req("", 0, "", List[String](), 100001))
    var empty = _req()
    empty.filter = String("")
    with assert_raises(contains="the filter is empty"):
        _ = time_series_list_query(empty)


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
    var t = Int64(1789207200) * Int64(1_000_000_000)
    assert_equal(rfc3339_of_ns(t), String("2026-09-12T10:00:00Z"))
    assert_equal(rfc3339_of_ns(t - 1), String("2026-09-12T09:59:59.999999999Z"))
    assert_equal(rfc3339_of_ns(t + 500_000_000), String("2026-09-12T10:00:00.500Z"))
    assert_equal(ns_of_rfc3339(String("2026-09-12T09:59:59.999999999Z")), t - 1)
    assert_equal(ns_of_rfc3339(String("2026-09-12T10:00:00Z")), t)
    with assert_raises(contains="before 1970"):
        _ = rfc3339_of_ns(Int64(-1))


def test_percent_encode() raises:
    assert_equal(percent_encode(String("aZ09-._~")), String("aZ09-._~"))
    assert_equal(percent_encode(String(" /\"=&+")), String("%20%2F%22%3D%26%2B"))
    assert_equal(percent_encode(String("é")), String("%C3%A9"))


def main() raises:
    test_path()
    test_raw_query()
    test_aggregated_grouped_query_with_token()
    test_query_refusals()
    test_filter()
    test_label_spellings()
    test_times()
    test_percent_encode()
    print("OK")
