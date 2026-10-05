# =============================================================================
# komira_gcp_monitoring/time_series_list.mojo: Cloud Monitoring v3
#   `projects.timeSeries.list`, PURE. The request target, the filter, and the
#   response parse, with no transport.
# =============================================================================
#
# THE WIRE (REST, `google.monitoring.v3.MetricService.ListTimeSeries`):
#
#   GET /v3/projects/<project>/timeSeries
#       ?filter=metric.type%3D%22run.googleapis.com%2Frequest_count%22...
#       &interval.startTime=<RFC 3339>&interval.endTime=<RFC 3339>
#       &aggregation.alignmentPeriod=60s
#       &aggregation.perSeriesAligner=ALIGN_SUM
#       &aggregation.crossSeriesReducer=REDUCE_SUM
#       &aggregation.groupByFields=metric.label.response_code
#       &view=FULL&pageSize=1000[&pageToken=...]
#   -> {"timeSeries":[{"metric":{"type":"...","labels":{"response_code":"200"}},
#        "resource":{"type":"cloud_run_revision","labels":{...}},
#        "metricKind":"DELTA","valueType":"INT64",
#        "points":[{"interval":{"startTime":"...","endTime":"..."},
#                   "value":{"int64Value":"42"}}]}],
#       "nextPageToken":"...","executionErrors":[...]}
#
# ── WHY THIS IS HAND-WRITTEN AND NOT GENERATED ──────────────────────────────
# The REST generator (`tools/build/proto-codegen/src/emit_rest.rs`,
# `query_items`) sends a message-typed query field as its scalar fields, and
# refuses one whose fields are messages. ListTimeSeries is a GET whose
# `interval` holds two `google.protobuf.Timestamp`s and whose `aggregation`
# holds a `google.protobuf.Duration`; their query form is the well-known
# type's JSON string, which the generator implements only for FieldMask. Once
# it renders Timestamp and Duration query parameters as their JSON strings,
# `komira_gcp_monitoring` can be a `mojo_gcp_client` over
# `MetricService.ListTimeSeries` and this file shrinks to the reader's
# adapter.
#
# ── WHAT IS SILENT WHEN WRONG ON THIS API ───────────────────────────────────
#   1. `int64Value` is a JSON STRING (the proto3 JSON mapping of int64). A
#      parser that read only bare numbers returns no points for every INT64
#      metric, which looks like a workload with no traffic.
#   2. Points come NEWEST FIRST. The reader returns them oldest first.
#   3. The filter is a language. A label value is quoted and escaped here,
#      and a label key is refused unless it is a plain identifier, so a
#      matcher cannot widen the filter it is part of.
#   4. `interval` covers (startTime, endTime]: the reader sends one
#      nanosecond before the query's inclusive start.
#   5. `executionErrors` in a 200 means the returned data may be incomplete;
#      it is counted on the parsed page.
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

from komira_datetime import Timestamp, format_rfc3339, parse_rfc3339
from komira_json import JsonValue, parse_json_value
from komira_metrics_reader import MetricsLabel, MetricsMatcher, MetricsSample


comptime MONITORING_DEFAULT_HOST: String = "monitoring.googleapis.com"
"""The `google.api.default_host` of `MetricService` in the pinned protos
(//tools/vendor/googleapis:monitoring_v3)."""

comptime LIST_TIME_SERIES_RPC: String = "ListTimeSeries"

comptime LIST_TIME_SERIES_MAX_PAGE_SIZE: Int = 100_000
"""The largest effective `pageSize`, per the request's documentation; with
`view=FULL` it counts points."""

comptime MONITORING_MIN_ALIGNMENT_S: Int = 60
"""`Aggregation.alignment_period` "must be at least 60 seconds"."""

comptime _NS = Int64(1_000_000_000)


@fieldwise_init
struct TimeSeriesListRequest(Copyable, Movable):
    """One `timeSeries.list` call.

      * `project`             a project id or number.
      * `filter`              a monitoring filter (`monitoring_filter`).
      * `start_time`, `end_time`  the interval, RFC 3339.
      * `alignment_period_s`, `per_series_aligner`  the alignment; 0 and ""
                              for none (raw points).
      * `cross_series_reducer`, `group_by_fields`  the reduction; "" and
                              empty for none.
      * `page_size`           at most this many points; `page_token` the
                              previous page's `nextPageToken`, or ""."""

    var project: String
    var filter: String
    var start_time: String
    var end_time: String
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


def time_series_list_path(project: String) raises -> String:
    """`/v3/projects/<project>/timeSeries`. Raises for an empty project and
    for one holding a byte a project id or number never does (a `/` would
    address another resource)."""
    if project.byte_length() == 0:
        raise Error("ListTimeSeries: the project is empty")
    var b = project.as_bytes()
    for i in range(len(b)):
        if not _is_project_byte(b[i]):
            raise Error(
                "ListTimeSeries: the project holds a byte a project id never"
                " does"
            )
    return String("/v3/projects/") + project + String("/timeSeries")


def percent_encode(s: String) -> String:
    """RFC 3986 percent-encoding of a query component: every byte but the
    unreserved `A-Z a-z 0-9 - . _ ~`."""
    var out = String("")
    var hex = "0123456789ABCDEF".as_bytes()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var c = bs[i]
        var keep = (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x2D)
            or c == UInt8(0x2E)
            or c == UInt8(0x5F)
            or c == UInt8(0x7E)
        )
        if keep:
            out += chr(Int(c))
        else:
            out += "%"
            out += chr(Int(hex[Int(c >> 4)]))
            out += chr(Int(hex[Int(c & 0x0F)]))
    return out^


def time_series_list_query(req: TimeSeriesListRequest) raises -> String:
    """The query string (no `?`), percent-encoded, in the field order of the
    request message. Raises, rather than sends, a request the service would
    refuse or would answer with something else: an empty filter or end time,
    an aligner with a period under `MONITORING_MIN_ALIGNMENT_S` or with none,
    a reducer with no aligner, group-by fields with no reducer, and a page
    size outside [1, LIST_TIME_SERIES_MAX_PAGE_SIZE]."""
    if req.filter.byte_length() == 0:
        raise Error(
            "ListTimeSeries: the filter is empty; it must name one metric type"
        )
    if req.end_time.byte_length() == 0:
        raise Error("ListTimeSeries: the interval has no end time")
    var aligned = req.per_series_aligner.byte_length() > 0
    if aligned and req.alignment_period_s < MONITORING_MIN_ALIGNMENT_S:
        raise Error(
            String("ListTimeSeries: an alignment period of ")
            + String(req.alignment_period_s)
            + String(" s; it must be at least 60 s")
        )
    if not aligned and req.alignment_period_s != 0:
        raise Error("ListTimeSeries: an alignment period with no aligner")
    if req.cross_series_reducer.byte_length() > 0 and not aligned:
        raise Error("ListTimeSeries: a cross-series reducer needs an aligner")
    if len(req.group_by_fields) > 0 and req.cross_series_reducer.byte_length() == 0:
        raise Error("ListTimeSeries: group-by fields need a cross-series reducer")
    if req.page_size < 1 or req.page_size > LIST_TIME_SERIES_MAX_PAGE_SIZE:
        raise Error(
            String("ListTimeSeries: a page size of ")
            + String(req.page_size)
            + String(" is outside [1, 100000]")
        )
    var q = String("filter=") + percent_encode(req.filter)
    if req.start_time.byte_length() > 0:
        q += String("&interval.startTime=") + percent_encode(req.start_time)
    q += String("&interval.endTime=") + percent_encode(req.end_time)
    if aligned:
        q += String("&aggregation.alignmentPeriod=") + String(
            req.alignment_period_s
        ) + String("s")
        q += String("&aggregation.perSeriesAligner=") + percent_encode(
            req.per_series_aligner
        )
    if req.cross_series_reducer.byte_length() > 0:
        q += String("&aggregation.crossSeriesReducer=") + percent_encode(
            req.cross_series_reducer
        )
        for i in range(len(req.group_by_fields)):
            q += String("&aggregation.groupByFields=") + percent_encode(
                req.group_by_fields[i]
            )
    q += String("&view=FULL&pageSize=") + String(req.page_size)
    if req.page_token.byte_length() > 0:
        q += String("&pageToken=") + percent_encode(req.page_token)
    return q^


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


def rfc3339_of_ns(ns: Int64) raises -> String:
    """`ns` (UNIX epoch nanoseconds, not negative) as RFC 3339 UTC, the
    fraction cut to the shortest exact multiple of three digits."""
    if ns < Int64(0):
        raise Error("a time before 1970 is not sent")
    return format_rfc3339(
        Timestamp(Int(ns // _NS), Int(ns % _NS)), 9, 3
    )


def ns_of_rfc3339(text: String) raises -> Int64:
    """An RFC 3339 time as UNIX epoch nanoseconds."""
    var ts = parse_rfc3339(text)
    return Int64(ts.seconds) * _NS + Int64(ts.nanos)


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


def parse_time_series_list_response(body: String) raises -> TimeSeriesListPage:
    """Parse a `timeSeries.list` response. An absent `timeSeries` is an
    answer with no series.

    Raises for a body that is not a JSON object, a series or point not in
    the documented shape, a point time that is not RFC 3339, and a value this
    package does not carry as a number (a distribution or a string: ask for
    an aggregation that reduces it). A raise names the byte count and what
    was wrong, never the body."""
    var doc: JsonValue
    try:
        doc = parse_json_value(body)
    except e:
        raise Error(
            String("ListTimeSeries: the ")
            + String(body.byte_length())
            + String("-byte response is not JSON: ")
            + String(e)
        )
    if not doc.is_object():
        raise Error("ListTimeSeries: the response is not a JSON object")
    var token = String("")
    if doc.has(String("nextPageToken")):
        var t = doc.get(String("nextPageToken"))
        if t.is_string():
            token = t.as_string()
    var errors = 0
    if doc.has(String("executionErrors")):
        var ee = doc.get(String("executionErrors"))
        if ee.is_array():
            errors = ee.array_len()
    var out = List[MonitoringSeries]()
    if doc.has(String("timeSeries")):
        var arr = doc.get(String("timeSeries"))
        if not arr.is_array():
            raise Error("ListTimeSeries: timeSeries is not an array")
        for i in range(arr.array_len()):
            out.append(_parse_series(arr.element_at(i), i))
    return TimeSeriesListPage(out^, token^, errors)


def _labels_of(holder: JsonValue, what: String) raises -> List[MetricsLabel]:
    var out = List[MetricsLabel]()
    if not holder.has(String("labels")):
        return out^
    var m = holder.get(String("labels"))
    if not m.is_object():
        raise Error(String("ListTimeSeries: ") + what + String(".labels is not an object"))
    for i in range(m.num_members()):
        var v = m.value_at(i)
        if not v.is_string():
            raise Error(String("ListTimeSeries: a ") + what + String(" label is not a string"))
        out.append(MetricsLabel(m.key_at(i), v.as_string()))
    return out^


def _parse_series(s: JsonValue, index: Int) raises -> MonitoringSeries:
    if not s.is_object():
        raise Error(
            String("ListTimeSeries: series ") + String(index) + String(" is not an object")
        )
    var metric_type = String("")
    var metric_labels = List[MetricsLabel]()
    if s.has(String("metric")):
        var m = s.get(String("metric"))
        if not m.is_object():
            raise Error("ListTimeSeries: metric is not an object")
        if m.has(String("type")):
            metric_type = m.get(String("type")).as_string()
        metric_labels = _labels_of(m, String("metric"))
    var resource_labels = List[MetricsLabel]()
    var resource_type = String("")
    if s.has(String("resource")):
        var r = s.get(String("resource"))
        if not r.is_object():
            raise Error("ListTimeSeries: resource is not an object")
        if r.has(String("type")):
            resource_type = r.get(String("type")).as_string()
        resource_labels = _labels_of(r, String("resource"))
    var value_type = String("")
    if s.has(String("valueType")):
        value_type = s.get(String("valueType")).as_string()
    var points = List[MetricsSample]()
    if s.has(String("points")):
        var ps = s.get(String("points"))
        if not ps.is_array():
            raise Error("ListTimeSeries: points is not an array")
        # Newest first on the wire; read back to front.
        var n = ps.array_len()
        for k in range(n):
            points.append(_parse_point(ps.element_at(n - 1 - k), metric_type))
    return MonitoringSeries(
        metric_type^,
        metric_labels^,
        resource_labels^,
        resource_type^,
        value_type^,
        points^,
    )


def _parse_point(p: JsonValue, metric_type: String) raises -> MetricsSample:
    if not p.is_object() or not p.has(String("interval")) or not p.has(String("value")):
        raise Error("ListTimeSeries: a point has no interval or no value")
    var interval = p.get(String("interval"))
    if not interval.is_object() or not interval.has(String("endTime")):
        raise Error("ListTimeSeries: a point's interval has no endTime")
    var end_text = interval.get(String("endTime"))
    if not end_text.is_string():
        raise Error("ListTimeSeries: a point's endTime is not a string")
    var t: Int64
    try:
        t = ns_of_rfc3339(end_text.as_string())
    except:
        raise Error("ListTimeSeries: a point's endTime is not RFC 3339")
    return MetricsSample(t, _typed_value(p.get(String("value")), metric_type))


def _typed_value(v: JsonValue, metric_type: String) raises -> Float64:
    """A `TypedValue` as a Float64: `int64Value` (a JSON string), `doubleValue`
    (a number, or the strings "NaN", "Infinity", "-Infinity"), `boolValue`
    as 1 or 0."""
    if not v.is_object():
        raise Error("ListTimeSeries: a point's value is not an object")
    if v.has(String("int64Value")):
        var i = v.get(String("int64Value"))
        if not i.is_string() and not i.is_number():
            raise Error("ListTimeSeries: an int64Value is not a number")
        return Float64(i.as_int64())
    if v.has(String("doubleValue")):
        var d = v.get(String("doubleValue"))
        if d.is_string():
            var s = d.as_string()
            if s == "NaN":
                return Float64(0) / Float64(0)
            if s == "Infinity":
                return Float64(1) / Float64(0)
            if s == "-Infinity":
                return Float64(-1) / Float64(0)
            raise Error("ListTimeSeries: a doubleValue string is not NaN or Infinity")
        if not d.is_number():
            raise Error("ListTimeSeries: a doubleValue is not a number")
        return d.as_float64()
    if v.has(String("boolValue")):
        return Float64(1) if v.get(String("boolValue")).as_bool() else Float64(0)
    raise Error(
        String("ListTimeSeries: ")
        + metric_type
        + String(
            " has a distribution or string value, which is not read as a"
            " number; ask for an aggregation that reduces it (mean, sum,"
            " count)"
        )
    )
