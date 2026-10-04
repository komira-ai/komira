# =============================================================================
# komira_cloud_metrics/gcp_monitoring_query.mojo — the GCP arm, PURE: the
#   `timeSeries.list` path + query string, and the FIELD-ALLOW-LISTED response
#   parse.
# =============================================================================
#
# THE WIRE (Cloud Monitoring v3):
#   GET monitoring.googleapis.com/v3/projects/<p>/timeSeries
#       ?filter=<f>&interval.startTime=<s>&interval.endTime=<e>
#       &aggregation.alignmentPeriod=3600s&aggregation.perSeriesAligner=ALIGN_SUM
#   -> {"timeSeries":[{"metric":{"type":"...","labels":{"response_code":"200"}},
#                      "resource":{"type":"cloud_run_revision","labels":{...}},
#                      "points":[{"interval":{"startTime":"...",
#                                             "endTime":"2026-09-12T10:00:00Z"},
#                                 "value":{"int64Value":"42"}}]}]}
#
# ⚠⚠ `int64Value` IS A JSON **STRING**, NOT A NUMBER, and that is not a quirk of
# one metric — it is the proto3-JSON mapping for int64 (precision above 2^53 is
# not representable in a JSON number, so the mapping quotes it). A parser that
# read only `doubleValue`, or that scanned for a bare number, comes back with
# ZERO POINTS for every INT64 metric — including `run.googleapis.com/
# request_count`, which is the only metric anything in this repo has ever read.
# ⛔ A "no points" answer is ALSO the legitimate answer for a fresh deploy, so
# that failure would look exactly like the thing it is supposed to measure.
#
# ── ⛔ THE ALLOW-LIST IS THE SECURITY BOUNDARY ──────────────────────────────
# A `TimeSeries` carries `metric.labels` and `resource.labels` — free-form maps
# the EMITTING SERVICE controls. `GCP_TIMESERIES_FIELD_ALLOWLIST` is the complete
# set of keys that can leave this parser; anything else is SKIPPED, and the
# labels that DO survive are rendered into ONE summary clause rather than stored
# as a map. And ⛔ a response body is never echoed — faults report a byte count
# and a position.
#
# def-based, Mojo 1.0.0b2. No UnsafePointer, no wildcard origin, no FFI.
# =============================================================================

from kci_logs.json_scan import (
    json_scan_string,
    json_skip_space,
    json_skip_value,
)

from komira_cloud_metrics.cloud_metric_source import (
    DEFAULT_METRIC_ALIGNER,
    DEFAULT_METRIC_ALIGNMENT_PERIOD,
    MetricPage,
    MetricPoint,
    MetricSeries,
    MetricWindow,
)
from komira_cloud_metrics.metric_json import (
    json_scan_scalar_text,
    parse_f64,
    urlencode_query_component,
)


comptime MONITORING_HOST: String = "monitoring.googleapis.com"

comptime GCP_TIMESERIES_FIELD_ALLOWLIST: String = (
    "timeSeries,metric,type,labels,points,interval,endTime,value,int64Value,"
    "doubleValue"
)
"""The complete set of keys this parser lets out.

⚠ `resource` IS OFF IT, DELIBERATELY, AND SO IS `startTime`. `resource.labels`
carries the project id, the revision name, the location and the configuration
name — none of which a caller learns anything from that the HANDLE did not
already say, and all of which would then be renderable into a report.
`interval.startTime` is dropped because `MetricPoint` carries ONE timestamp and
a bucket is identified by its END: two times per point in one rendered stream is
how a reader concludes a bucket covers a window it does not."""


# =============================================================================
# §1 — handle arithmetic on a Cloud Run SERVICE resource name.
# =============================================================================
def service_project(service_resource_name: String) -> String:
    """The PROJECT id a Cloud Run service resource name carries
    (`projects/<p>/locations/<r>/services/<s>`), or EMPTY.

    ⭐ THE SAME PROPERTY `execution_project` gives the log arm, and for the same
    reason: a conformer that DERIVES the project from the handle cannot be
    configured with one that disagrees with it, and the failure mode of that
    disagreement is reading ANOTHER PROJECT'S numbers and presenting them as
    this workload's. On a metric that is worse than on a log line — a wrong log
    line usually looks wrong, and a wrong number never does."""
    if not service_resource_name.startswith(String("projects/")):
        return String("")
    var rest = String(service_resource_name[byte=9:])
    var slash = rest.find(String("/"))
    if slash <= 0:
        return rest^ if rest.byte_length() > 0 else String("")
    return String(rest[byte=0:slash])


def service_leaf(service_resource_name: String) -> String:
    """The SERVICE id — the segment after the last `/services/` — or EMPTY."""
    var marker = String("/services/")
    var at = service_resource_name.find(marker)
    if at < 0:
        return String("")
    var leaf = String(
        service_resource_name[byte = at + marker.byte_length() :]
    )
    if leaf.find(String("/")) >= 0:
        return String("")
    return leaf^


def run_service_metric_filter(
    metric_type: String, service_resource_name: String
) -> String:
    """The Cloud Monitoring filter for ONE Cloud Run service's `metric_type`, or
    EMPTY when either part is missing.

    ⛔ EMPTY IS A REFUSAL, the `cloud_run_execution_log_filter` rule. An
    unscoped filter (`metric.type="..."` with no service) is SYNTACTICALLY FINE
    and returns EVERY service in the project — which a caller renders under this
    workload's name."""
    var leaf = service_leaf(service_resource_name)
    if metric_type.byte_length() == 0 or leaf.byte_length() == 0:
        return String("")
    return (
        String('metric.type="')
        + metric_type
        + String('" AND resource.labels.service_name="')
        + leaf
        + String('"')
    )


def timeseries_path(service_resource_name: String) -> String:
    """`/v3/projects/<p>/timeSeries`, or EMPTY when the handle carries no
    project. ⛔ A project-less path is a 404 that reads as "this service has no
    metrics"."""
    var project = service_project(service_resource_name)
    if project.byte_length() == 0:
        return String("")
    return String("/v3/projects/") + project + String("/timeSeries")


# =============================================================================
# §2 — the QUERY STRING.
# =============================================================================
def timeseries_query(
    filter_expr: String,
    window: MetricWindow,
    alignment_period: String = DEFAULT_METRIC_ALIGNMENT_PERIOD,
    aligner: String = DEFAULT_METRIC_ALIGNER,
) -> String:
    """The `timeSeries.list` QUERY STRING (no leading `?`), percent-encoded.
    EMPTY when the filter or either window bound is empty — the refusal.

    ⛔⛔ THE AGGREGATION PARAMETERS ARE NOT OPTIONAL AND THEY ARE NOT COSMETIC.
    Omitting them returns every RAW point in the interval, and that is a
    MEASURED failure, not a size preference: 2,546,731 bytes over 24h, which
    stalled and then died on a fixed ~279s budget inside the Cloud Run Job
    environment (measured on Cloud Run). Hourly ALIGN_SUM
    over the same window: the SAME 16 series, 53,772 bytes.

    ⚠ THE STALL IS ENVIRONMENT-SPECIFIC — the same read from a workstation
    passed in 12 seconds — so the aggregation is a MITIGATION for a client
    defect, not a fix for it. Do not read this default as "the transport is
    fine now"."""
    if not window.ok() or filter_expr.byte_length() == 0:
        return String("")
    return (
        String("filter=")
        + urlencode_query_component(filter_expr)
        + String("&interval.startTime=")
        + urlencode_query_component(window.start)
        + String("&interval.endTime=")
        + urlencode_query_component(window.end)
        + String("&aggregation.alignmentPeriod=")
        + urlencode_query_component(alignment_period)
        + String("&aggregation.perSeriesAligner=")
        + urlencode_query_component(aligner)
    )


# =============================================================================
# §3 — the allow-listed PARSE.
# =============================================================================
def _parse_label_map(
    b: Span[UInt8, _], start: Int, mut summary: String
) -> Int:
    """Render a `labels` object at `start` into ONE `k=v,k=v` clause. Returns the
    index after its closing brace, or -1.

    ⛔ RENDERED, NOT STORED. These keys are chosen by the emitting service; a
    map on the POD would let any of them reach any future consumer. A clause is
    something a report can print and nothing can key on."""
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var val = String()
    var first = True
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var nk = json_scan_string(b, j, key)
        if nk < 0:
            return -1
        j = json_skip_space(b, nk)
        if j >= len(b) or b[j] != UInt8(ord(":")):
            return -1
        j = json_skip_space(b, j + 1)
        var nv = json_scan_scalar_text(b, j, val)
        if nv < 0:
            # A nested / non-scalar label value is SKIPPED, not failed — the
            # allow-list's own discipline: an unknown shape must not stop the
            # parse of the shapes that ARE known.
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns
            continue
        if not first:
            summary += String(",")
        summary += key + String("=") + val
        first = False
        j = nv


def _parse_point(b: Span[UInt8, _], start: Int, mut pt: MetricPoint) -> Int:
    """Parse ONE `Point` at `start` through the allow-list. Returns the index
    after its closing brace, or -1.

    THE TWO THINGS IT LOOKS FOR: `interval.endTime` and
    `value.{int64Value,doubleValue}`. Everything else — including
    `interval.startTime` — is skipped."""
    pt = MetricPoint.empty()
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var inner = String()
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var nk = json_scan_string(b, j, key)
        if nk < 0:
            return -1
        j = json_skip_space(b, nk)
        if j >= len(b) or b[j] != UInt8(ord(":")):
            return -1
        j = json_skip_space(b, j + 1)
        if key == String("interval"):
            var ne = _parse_interval(b, j, pt)
            if ne < 0:
                return -1
            j = ne
        elif key == String("value"):
            var nv = _parse_value(b, j, pt)
            if nv < 0:
                return -1
            j = nv
        else:
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns
        _ = inner


def _parse_interval(b: Span[UInt8, _], start: Int, mut pt: MetricPoint) -> Int:
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var val = String()
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var nk = json_scan_string(b, j, key)
        if nk < 0:
            return -1
        j = json_skip_space(b, nk)
        if j >= len(b) or b[j] != UInt8(ord(":")):
            return -1
        j = json_skip_space(b, j + 1)
        if key == String("endTime"):
            var nv = json_scan_scalar_text(b, j, val)
            if nv < 0:
                return -1
            pt.end_time = val.copy()
            j = nv
        else:
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns


def _parse_value(b: Span[UInt8, _], start: Int, mut pt: MetricPoint) -> Int:
    """Read `value.{int64Value | doubleValue}` into `pt.value`.

    ⚠ BOTH KEYS, AND `int64Value` IS QUOTED — see the module header. A parser
    that read only one of them answers "no points" for every metric of the other
    kind, which is indistinguishable from a workload with no traffic."""
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var val = String()
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var nk = json_scan_string(b, j, key)
        if nk < 0:
            return -1
        j = json_skip_space(b, nk)
        if j >= len(b) or b[j] != UInt8(ord(":")):
            return -1
        j = json_skip_space(b, j + 1)
        if key == String("int64Value") or key == String("doubleValue"):
            var nv = json_scan_scalar_text(b, j, val)
            if nv < 0:
                return -1
            var parsed = Float64(0)
            if parse_f64(val, parsed):
                pt.value = parsed
            j = nv
        else:
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns


def _parse_series(b: Span[UInt8, _], start: Int, mut s: MetricSeries) -> Int:
    """Parse ONE `TimeSeries` at `start`. Returns the index after its closing
    brace, or -1."""
    s = MetricSeries.empty()
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var nk = json_scan_string(b, j, key)
        if nk < 0:
            return -1
        j = json_skip_space(b, nk)
        if j >= len(b) or b[j] != UInt8(ord(":")):
            return -1
        j = json_skip_space(b, j + 1)
        if key == String("metric"):
            var nm = _parse_metric_descriptor(b, j, s)
            if nm < 0:
                return -1
            j = nm
        elif key == String("points"):
            var np = _parse_points_array(b, j, s)
            if np < 0:
                return -1
            j = np
        else:
            # ⚠ `resource` LANDS HERE, and that is the allow-list working.
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns


def _parse_metric_descriptor(
    b: Span[UInt8, _], start: Int, mut s: MetricSeries
) -> Int:
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var val = String()
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var nk = json_scan_string(b, j, key)
        if nk < 0:
            return -1
        j = json_skip_space(b, nk)
        if j >= len(b) or b[j] != UInt8(ord(":")):
            return -1
        j = json_skip_space(b, j + 1)
        if key == String("labels"):
            var summary = String("")
            var nl = _parse_label_map(b, j, summary)
            if nl < 0:
                return -1
            if summary.byte_length() > 0:
                if s.label_summary.byte_length() > 0:
                    s.label_summary += String(" ")
                s.label_summary += summary
            j = nl
        elif key == String("type"):
            var nv = json_scan_scalar_text(b, j, val)
            if nv < 0:
                return -1
            if s.label_summary.byte_length() > 0:
                s.label_summary = val + String(" ") + s.label_summary
            else:
                s.label_summary = val.copy()
            j = nv
        else:
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns


def _parse_points_array(
    b: Span[UInt8, _], start: Int, mut s: MetricSeries
) -> Int:
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("[")):
        return -1
    j += 1
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("]")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var pt = MetricPoint.empty()
        var nx = _parse_point(b, j, pt)
        if nx < 0:
            return -1
        s.points.append(pt^)
        j = nx


def _find_key(body: String, b: Span[UInt8, _], key: String) -> Int:
    var needle = String('"') + key + String('"')
    var idx = body.find(needle)
    if idx < 0:
        return -1
    var j = json_skip_space(b, idx + needle.byte_length())
    if j >= len(b) or b[j] != UInt8(ord(":")):
        return -1
    return json_skip_space(b, j + 1)


def parse_timeseries_body(body: String) -> MetricPage:
    """Parse a `timeSeries.list` response into a `MetricPage`. ⛔ NEVER RAISES
    and ⛔ NEVER ECHOES THE BODY.

    AN EMPTY OR ABSENT `timeSeries` ARRAY IS A SUCCESS — the provider answered
    and there is nothing there. ⚠ ON THIS API THAT IS ALSO THE NORMAL STATE OF A
    FRESHLY DEPLOYED WORKLOAD: a ~26 min gap between the newest point and now was
    measured on Cloud Run. A caller that reads it as
    unhealthy has built a clock.

    ⚠ `nextPageToken` is carried when present. GCP omits it at the end of a
    result set — unlike CloudWatch Logs' always-present forward token — so
    `next_token` here really does mean "there is more"."""
    var b = body.as_bytes()
    var page = MetricPage.empty(200)
    if body.byte_length() == 0:
        return page^
    var tok = _find_key(body, b, String("nextPageToken"))
    if tok >= 0:
        var tval = String()
        if json_scan_string(b, tok, tval) >= 0:
            page.next_token = tval^
    var si = _find_key(body, b, String("timeSeries"))
    if si < 0:
        return page^
    var j = json_skip_space(b, si)
    if j >= len(b) or b[j] != UInt8(ord("[")):
        return MetricPage.failed(
            200,
            String("`timeSeries` was not an array at byte ")
            + String(j)
            + String(" of a ")
            + String(body.byte_length())
            + String("-byte body (NOT echoed)"),
        )
    j += 1
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return MetricPage.failed(
                200,
                String("unterminated `timeSeries` array in a ")
                + String(body.byte_length())
                + String("-byte body (NOT echoed)"),
            )
        if b[j] == UInt8(ord("]")):
            return page^
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var s = MetricSeries.empty()
        var nx = _parse_series(b, j, s)
        if nx < 0:
            return MetricPage.failed(
                200,
                String("malformed time series at byte ")
                + String(j)
                + String(" of a ")
                + String(body.byte_length())
                + String("-byte body (NOT echoed)"),
            )
        page.series.append(s^)
        j = nx
