# =============================================================================
# komira_gcp_monitoring/time_series_list.mojo: the reader's adapter over the
#   generated Cloud Monitoring v3 client's `projects.timeSeries.list`, PURE.
#   The request it builds, the filter, and the page it reads, with no
#   transport.
# =============================================================================
#
# THE WIRE is komira_gcp_monitoring_client's: `MetricServiceClient.
# list_time_series` (generated from the pinned google/monitoring/v3 protos)
# builds the path and the query from a `ListTimeSeriesRequest` and decodes
# the `ListTimeSeriesResponse`. For the reader's requests it sends
#
#   GET /v3/projects/<project>/timeSeries
#       ?filter=metric.type%20%3D%20%22run.googleapis.com%2Frequest_count%22...
#       &interval.endTime=<RFC 3339>&interval.startTime=<RFC 3339>
#       &aggregation.alignmentPeriod=60s
#       &aggregation.perSeriesAligner=ALIGN_SUM
#       &aggregation.crossSeriesReducer=REDUCE_SUM
#       &aggregation.groupByFields=metric.label.response_code
#       &pageSize=1000[&pageToken=...]
#
# keys in the request message's declaration order (TimeInterval declares
# end_time first). `view` is FULL, the enum's zero value, so the proto3
# JSON mapping leaves it out of the query; the service reads an absent view
# as FULL.
#
# What this file adds to the generated call:
#   * `list_time_series_request`: the refusals of a request the service
#     would refuse or would answer with something else, then the generated
#     request. A project is checked byte by byte (`time_series_list_name`),
#     an aligner or reducer must be one the pinned protos declare.
#   * `time_series_list_page`: the generated response as the reader reads
#     it, series by series, points OLDEST first.
#   * `monitoring_filter`: the filter, values quoted, label keys refused
#     unless plain identifiers.
#
# ── WHAT IS SILENT WHEN WRONG ON THIS API ───────────────────────────────────
#   1. `int64Value` is a JSON STRING (the proto3 JSON mapping of int64). The
#      generated decode reads it as one; a parser that read only bare
#      numbers would return no points for every INT64 metric.
#   2. Points come NEWEST FIRST. The reader returns them oldest first.
#   3. The filter is a language. A label value is quoted and escaped here,
#      and a label key is refused unless it is a plain identifier, so a
#      matcher cannot widen the filter it is part of.
#   4. `interval` covers (startTime, endTime]: the reader sends one
#      nanosecond before the query's inclusive start.
#   5. `executionErrors` in a 200 means the returned data may be incomplete;
#      it is counted on the page.
#   6. A series is told apart by its metric type, ALL its metric and
#      resource labels and its resource type, not by the labels a reader
#      returns. Merging pages on fewer folds different workloads into one
#      series of duplicate timestamps.
#
# The host, the path, the page-size ceiling, the minimum alignment period,
# the point order, the interval and the aligner and reducer names are
# checked against the pinned protos by the welded test_monitoring_protos.
# ⚠ Not yet checked against the live API: the `groupByFields` spelling
# (`group_by_field`).
#
# Encapsulation: value types only. No pointer. Reads no environment.
# =============================================================================

from komira_gcp_monitoring_client.common import (
    Aggregation,
    Aggregation_Aligner,
    Aggregation_Reducer,
    TimeInterval,
    TypedValue,
)
from komira_gcp_monitoring_client.metric import Point, TimeSeries
from komira_gcp_monitoring_client.metric_service import (
    ListTimeSeriesRequest,
    ListTimeSeriesRequest_TimeSeriesView,
    ListTimeSeriesResponse,
)
from komira_metrics_reader import MetricsLabel, MetricsMatcher, MetricsSample
from komira_proto_codec.codec import decode_json_lenient
from komira_wkt import Duration, Timestamp


comptime MONITORING_DEFAULT_HOST: String = "monitoring.googleapis.com"
"""The `google.api.default_host` of `MetricService` in the pinned protos
(//tools/vendor/googleapis:monitoring_v3)."""

comptime LIST_TIME_SERIES_MAX_PAGE_SIZE: Int = 100_000
"""The largest effective `pageSize`, per the request's documentation; with
`view=FULL` it counts points."""

comptime MONITORING_MIN_ALIGNMENT_S: Int = 60
"""`Aggregation.alignment_period` "must be at least 60 seconds"."""

comptime _NS = Int64(1_000_000_000)


@fieldwise_init
struct TimeSeriesListRequest(Copyable, Movable):
    """One `timeSeries.list` call, as the reader describes it.

      * `project`             a project id or number.
      * `filter`              a monitoring filter (`monitoring_filter`).
      * `start_ns`, `end_ns`  the interval, UNIX epoch nanoseconds.
      * `alignment_period_s`, `per_series_aligner`  the alignment; 0 and ""
                              for none (raw points).
      * `cross_series_reducer`, `group_by_fields`  the reduction; "" and
                              empty for none.
      * `page_size`           at most this many points; `page_token` the
                              previous page's `nextPageToken`, or ""."""

    var project: String
    var filter: String
    var start_ns: Int64
    var end_ns: Int64
    var alignment_period_s: Int
    var per_series_aligner: String
    var cross_series_reducer: String
    var group_by_fields: List[String]
    var page_size: Int
    var page_token: String


def _is_project_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("-"))
        or c == UInt8(ord("."))
        or c == UInt8(ord(":"))
    )


def time_series_list_name(project: String) raises -> String:
    """`projects/<project>`, the request's `name`. Raises for an empty
    project and for one holding a byte a project id or number never does
    (a `/` would address another resource; the generated path would refuse
    it too, but an upper-case letter or a space it would percent-encode and
    send)."""
    if project.byte_length() == 0:
        raise Error("ListTimeSeries: the project is empty")
    var b = project.as_bytes()
    for i in range(len(b)):
        if not _is_project_byte(b[i]):
            raise Error(
                "ListTimeSeries: the project holds a byte a project id never"
                " does"
            )
    return String("projects/") + project


def timestamp_of_ns(ns: Int64) raises -> Timestamp:
    """`ns` (UNIX epoch nanoseconds, not negative) as a Timestamp, whose
    query form is RFC 3339 UTC with the fraction cut to the shortest exact
    multiple of three digits (komira_wkt)."""
    if ns < Int64(0):
        raise Error("a time before 1970 is not sent")
    return Timestamp(ns // _NS, Int32(ns % _NS))


def ns_of_timestamp(ts: Timestamp) -> Int64:
    """A Timestamp as UNIX epoch nanoseconds."""
    return ts.seconds * _NS + Int64(ts.nanos)


def list_time_series_request(req: TimeSeriesListRequest) raises -> ListTimeSeriesRequest:
    """The generated request for `req`. Raises, rather than sends, a
    request the service would refuse or would answer with something else: an
    empty filter, a bad project, a time before 1970, an aligner with a
    period under `MONITORING_MIN_ALIGNMENT_S` or a period with no aligner, a
    reducer with no aligner, group-by fields with no reducer, an aligner or
    reducer the pinned protos do not declare, and a page size outside
    [1, LIST_TIME_SERIES_MAX_PAGE_SIZE]."""
    if req.filter.byte_length() == 0:
        raise Error(
            "ListTimeSeries: the filter is empty; it must name one metric type"
        )
    var name = time_series_list_name(req.project)
    var aligned = req.per_series_aligner.byte_length() > 0
    var reduced = req.cross_series_reducer.byte_length() > 0
    if aligned and req.alignment_period_s < MONITORING_MIN_ALIGNMENT_S:
        raise Error(
            String("ListTimeSeries: an alignment period of ")
            + String(req.alignment_period_s)
            + String(" s; it must be at least 60 s")
        )
    if not aligned and req.alignment_period_s != 0:
        raise Error("ListTimeSeries: an alignment period with no aligner")
    if reduced and not aligned:
        raise Error("ListTimeSeries: a cross-series reducer needs an aligner")
    if len(req.group_by_fields) > 0 and not reduced:
        raise Error("ListTimeSeries: group-by fields need a cross-series reducer")
    if aligned and not Aggregation_Aligner.is_known_json_name(req.per_series_aligner):
        raise Error(
            String("ListTimeSeries: the aligner ")
            + req.per_series_aligner
            + String(" is not declared in the pinned protos")
        )
    if reduced and not Aggregation_Reducer.is_known_json_name(req.cross_series_reducer):
        raise Error(
            String("ListTimeSeries: the reducer ")
            + req.cross_series_reducer
            + String(" is not declared in the pinned protos")
        )
    if req.page_size < 1 or req.page_size > LIST_TIME_SERIES_MAX_PAGE_SIZE:
        raise Error(
            String("ListTimeSeries: a page size of ")
            + String(req.page_size)
            + String(" is outside [1, 100000]")
        )
    var interval = TimeInterval(
        timestamp_of_ns(req.end_ns), timestamp_of_ns(req.start_ns)
    )
    var aggregation: Optional[Aggregation] = None
    if aligned:
        aggregation = Aggregation(
            Duration(Int64(req.alignment_period_s), Int32(0)),
            Aggregation_Aligner.from_json_name(req.per_series_aligner),
            Aggregation_Reducer.from_json_name(req.cross_series_reducer),
            req.group_by_fields.copy(),
        )
    return ListTimeSeriesRequest(
        name^,
        req.filter.copy(),
        interval^,
        aggregation^,
        None,
        String(""),
        ListTimeSeriesRequest_TimeSeriesView(ListTimeSeriesRequest_TimeSeriesView.FULL),
        Int32(req.page_size),
        req.page_token.copy(),
    )


# =============================================================================
# §2 — the filter.
# =============================================================================

comptime RESOURCE_LABEL_PREFIX: String = "resource."
"""A label key spelled `resource.<k>` names the monitored resource's label
`k`; any other key names a metric label."""


def _is_label_key(k: String) -> Bool:
    var b = k.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("_"))
        )
        if not ok:
            return False
    return True


def label_key_refusal(key: String) -> String:
    """"" when `key` is a label key this package can put in a filter or a
    group-by field (`k` or `resource.k`, `k` a plain identifier), else why
    not."""
    var k = key
    if key.startswith(RESOURCE_LABEL_PREFIX):
        k = String(key[byte = RESOURCE_LABEL_PREFIX.byte_length() :])
    if not _is_label_key(k):
        return (
            String("the label key '")
            + key
            + String(
                "' is not a plain identifier (letters, digits, '_'), optionally"
                " after 'resource.'"
            )
        )
    return String("")


def filter_label_selector(key: String) raises -> String:
    """The filter's spelling of a label: `metric.labels.<k>`, or
    `resource.labels.<k>` for `resource.<k>`."""
    var why = label_key_refusal(key)
    if why.byte_length() > 0:
        raise Error(why)
    if key.startswith(RESOURCE_LABEL_PREFIX):
        return String("resource.labels.") + String(
            key[byte = RESOURCE_LABEL_PREFIX.byte_length() :]
        )
    return String("metric.labels.") + key


def group_by_field(key: String) raises -> String:
    """The `aggregation.groupByFields` spelling of a label:
    `metric.label.<k>`, or `resource.label.<k>` for `resource.<k>`.

    Singular `label.`, unlike the filter's `labels.`: the pinned protos
    (`Aggregation.group_by_fields`) give no syntax, and this is the form
    Cloud Monitoring's alerting-policy JSON samples use
    (`"groupByFields": ["project", "resource.label.module_id",
    "resource.label.version_id"]`). Not yet checked against the live API."""
    var why = label_key_refusal(key)
    if why.byte_length() > 0:
        raise Error(why)
    if key.startswith(RESOURCE_LABEL_PREFIX):
        return String("resource.label.") + String(
            key[byte = RESOURCE_LABEL_PREFIX.byte_length() :]
        )
    return String("metric.label.") + key


def quote_filter_string(v: String) -> String:
    """`v` as a filter string literal: double-quoted, with `\\` and `"`
    escaped by a backslash."""
    var out = String('"')
    var b = v.as_bytes()
    var run = List[UInt8]()
    for i in range(len(b)):
        if b[i] == UInt8(ord('"')) or b[i] == UInt8(ord("\\")):
            run.append(UInt8(ord("\\")))
        run.append(b[i])
    out += String(unsafe_from_utf8=run^)
    out += '"'
    return out^


def monitoring_filter(
    metric_type: String, matchers: List[MetricsMatcher]
) raises -> String:
    """`metric.type = "<metric_type>"`, then ` AND <selector> = "<v>"` (or
    `!=` for a negated matcher) per matcher. Raises for an empty metric type
    and a label key `label_key_refusal` refuses."""
    if metric_type.byte_length() == 0:
        raise Error("ListTimeSeries: the metric type is empty")
    var f = String("metric.type = ") + quote_filter_string(metric_type)
    for i in range(len(matchers)):
        ref m = matchers[i]
        f += String(" AND ") + filter_label_selector(m.key)
        f += String(" != ") if m.negated else String(" = ")
        f += quote_filter_string(m.value)
    return f^


# =============================================================================
# §3 — the response.
# =============================================================================


@fieldwise_init
struct MonitoringSeries(Copyable, Movable):
    """One `TimeSeries`: its metric type, its metric and resource labels,
    its resource type, its value type, and its points OLDEST FIRST (reversed
    from the wire). The metric type, every label and the resource type
    together are the series' identity."""

    var metric_type: String
    var metric_labels: List[MetricsLabel]
    var resource_labels: List[MetricsLabel]
    var resource_type: String
    var value_type: String
    var points: List[MetricsSample]


@fieldwise_init
struct TimeSeriesListPage(Copyable, Movable):
    """One `timeSeries.list` response: its series, its `nextPageToken` (""
    at the end) and how many `executionErrors` it reported."""

    var series: List[MonitoringSeries]
    var next_page_token: String
    var execution_errors: Int


def time_series_list_page(resp: ListTimeSeriesResponse) raises -> TimeSeriesListPage:
    """The generated response as the reader reads it. Raises for a point
    with no interval, end time or value, and for a value this package does
    not carry as a number (a distribution or a string: ask for an
    aggregation that reduces it)."""
    var out = List[MonitoringSeries]()
    for i in range(len(resp.time_series)):
        out.append(_series_of(resp.time_series[i]))
    return TimeSeriesListPage(
        out^, resp.next_page_token.copy(), len(resp.execution_errors)
    )


def parse_time_series_list_response(body: String) raises -> TimeSeriesListPage:
    """A `timeSeries.list` response body, decoded as the generated client
    decodes it (proto3 JSON, unknown keys skipped), then read by
    `time_series_list_page`. An absent `timeSeries` is an answer with no
    series. A body that does not decode raises naming its byte count and the
    decoder's reason: a position or a field path, and for a malformed
    well-known type its offending value (a point time that is not RFC
    3339); never the rest of the body."""
    var resp: ListTimeSeriesResponse
    try:
        resp = decode_json_lenient[ListTimeSeriesResponse](body)
    except e:
        raise Error(
            String("ListTimeSeries: the ")
            + String(body.byte_length())
            + String("-byte response is not a ListTimeSeriesResponse: ")
            + String(e)
        )
    return time_series_list_page(resp)


def _labels_of(labels: Dict[String, String]) -> List[MetricsLabel]:
    var out = List[MetricsLabel]()
    for e in labels.items():
        out.append(MetricsLabel(e.key.copy(), e.value.copy()))
    return out^


def _series_of(ts: TimeSeries) raises -> MonitoringSeries:
    var metric_type = String("")
    var metric_labels = List[MetricsLabel]()
    if ts.metric:
        ref m = ts.metric.value()
        metric_type = m.type.copy()
        metric_labels = _labels_of(m.labels)
    var resource_type = String("")
    var resource_labels = List[MetricsLabel]()
    if ts.resource:
        ref r = ts.resource.value()
        resource_type = r.type.copy()
        resource_labels = _labels_of(r.labels)
    var points = List[MetricsSample]()
    # Newest first on the wire; read back to front.
    var n = len(ts.points)
    for k in range(n):
        points.append(_sample_of(ts.points[n - 1 - k], metric_type))
    return MonitoringSeries(
        metric_type^,
        metric_labels^,
        resource_labels^,
        resource_type^,
        ts.value_type.json_name(),
        points^,
    )


def _sample_of(p: Point, metric_type: String) raises -> MetricsSample:
    if not p.interval or not p.value:
        raise Error("ListTimeSeries: a point has no interval or no value")
    ref interval = p.interval.value()
    if not interval.end_time:
        raise Error("ListTimeSeries: a point's interval has no endTime")
    return MetricsSample(
        ns_of_timestamp(interval.end_time.value()),
        _typed_value(p.value.value(), metric_type),
    )


def _typed_value(v: TypedValue, metric_type: String) raises -> Float64:
    """A `TypedValue` as a Float64: `int64Value`, `doubleValue` (NaN and the
    infinities included), `boolValue` as 1 or 0."""
    if v.int64_value:
        return Float64(v.int64_value.value())
    if v.double_value:
        return v.double_value.value()
    if v.bool_value:
        return Float64(1) if v.bool_value.value() else Float64(0)
    raise Error(
        String("ListTimeSeries: ")
        + metric_type
        + String(
            " has a distribution or string value, which is not read as a"
            " number; ask for an aggregation that reduces it (mean, sum,"
            " count)"
        )
    )
