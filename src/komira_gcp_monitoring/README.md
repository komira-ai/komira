# komira_gcp_monitoring

Reads a project's Cloud Monitoring metrics through the komira_metrics_reader
seam. `CloudMonitoringMetricsReader` is a `MetricsReader` for one project: it
maps a `MetricsQuery` to Cloud Monitoring `timeSeries.list` calls (a filter,
an interval, an optional alignment and reduction, a page size), sends each
through the generated komira_gcp_monitoring_client
`MetricServiceClient.list_time_series` with a bearer token from a
komira_gcp_core token source, follows `nextPageToken` up to a page limit, and
merges a series continued on a later page into one. A non-2xx answer raises
through komira_gcp_core's `gcp_status_error`, which never quotes the body.

The adapter under it is pure and public: `monitoring_filter` writes the
filter (values quoted, a label key that is not a plain identifier refused),
`list_time_series_request` builds the generated request and refuses what the
service would refuse (an empty filter, a bad project, a time before 1970, an
alignment period under 60 s, a reducer with no aligner, an aligner or reducer
the pinned protos do not declare, a page size outside 1 to 100000), and
`parse_time_series_list_response` reads a response body into series whose
points are oldest first.

It reads no environment: the project, the host, the connector and the token
source are the caller's. It does not write metrics, and it reads only
numeric values (a distribution or string value is refused: ask for an
aggregation that reduces it).

## Examples

The filter for a metric and two label conditions. A label named
`resource.<k>` selects the monitored resource's label; a value is quoted
with its `"` and `\` escaped, and a key that could extend the filter is
refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_gcp_monitoring import monitoring_filter
from komira_metrics_reader import MetricsMatcher

var matchers = List[MetricsMatcher]()
matchers.append(MetricsMatcher.eq(String("response_code"), String("200")))
matchers.append(MetricsMatcher.neq(String("resource.service_name"), String('a"b')))
assert_equal(
    monitoring_filter(String("run.googleapis.com/request_count"), matchers),
    String(
        'metric.type = "run.googleapis.com/request_count"'
        + ' AND metric.labels.response_code = "200"'
        + ' AND resource.labels.service_name != "a\\"b"'
    ),
)

var injected = List[MetricsMatcher]()
injected.append(MetricsMatcher.eq(String('x" OR metric.type = "y'), String("1")))
with assert_raises(contains="is not a plain identifier"):
    _ = monitoring_filter(String("m"), injected)
```

The request for one hour of a metric, summed per series over 5-minute
windows, and one the service would refuse:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_gcp_monitoring import TimeSeriesListRequest, list_time_series_request

comptime HOUR_NS = Int64(3600) * Int64(1_000_000_000)
var start = Int64(1789207200) * Int64(1_000_000_000)  # 2026-09-12T10:00:00Z

var request = list_time_series_request(
    TimeSeriesListRequest(
        String("demo-project"),
        String('metric.type = "run.googleapis.com/request_count"'),
        start,
        start + HOUR_NS,
        300,                  # alignment period, seconds
        String("ALIGN_SUM"),  # per-series aligner
        String(""),           # no cross-series reducer
        List[String](),       # so no group-by fields
        1000,                 # page size
        String(""),           # first page
    )
)
assert_equal(request.name, String("projects/demo-project"))
assert_equal(request.interval.value().start_time.value().to_proto3_json(), String("2026-09-12T10:00:00Z"))
assert_equal(request.aggregation.value().alignment_period.value().to_proto3_json(), String("300s"))
assert_equal(request.view.json_name(), String("FULL"))
assert_equal(request.page_size, Int32(1000))

with assert_raises(contains="at least 60 s"):
    _ = list_time_series_request(
        TimeSeriesListRequest(
            String("demo-project"), String('metric.type = "m"'), start, start + HOUR_NS,
            30, String("ALIGN_SUM"), String(""), List[String](), 1000, String(""),
        )
    )
```

A response body, read. Points arrive newest first on the wire and come back
oldest first, with their times in UNIX epoch nanoseconds; an `int64Value` is
a JSON string and is read as a number:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_gcp_monitoring import parse_time_series_list_response

var page = parse_time_series_list_response(
    String(
        '{"timeSeries":[{"metric":{"type":"run.googleapis.com/request_count",'
        + '"labels":{"response_code":"200"}},'
        + '"resource":{"type":"cloud_run_revision","labels":{"service_name":"api"}},'
        + '"valueType":"INT64","points":['
        + '{"interval":{"endTime":"2026-09-12T10:02:00Z"},"value":{"int64Value":"7"}},'
        + '{"interval":{"endTime":"2026-09-12T10:01:00Z"},"value":{"int64Value":"42"}}]}],'
        + '"nextPageToken":"page-2"}'
    )
)
assert_equal(page.next_page_token, String("page-2"))
assert_equal(len(page.series), 1)
ref series = page.series[0]
assert_equal(series.metric_type, String("run.googleapis.com/request_count"))
assert_equal(series.metric_labels[0].key, String("response_code"))
assert_equal(series.resource_labels[0].value, String("api"))
assert_equal(len(series.points), 2)
assert_equal(series.points[0].value, 42.0)  # oldest first
assert_equal(series.points[1].value, 7.0)
assert_equal(series.points[1].time_ns - series.points[0].time_ns, Int64(60) * Int64(1_000_000_000))
```
