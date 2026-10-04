# =============================================================================
# komira_cloud_metrics/aws_cloudwatch_metrics_query.mojo — the AWS arm, PURE:
#   the `GetMetricData` request body and the FIELD-ALLOW-LISTED response parse.
# =============================================================================
#
# ★ WHY THE PURE AWS HALF EXISTS WITH NO CONFORMER ANYWHERE: the same reason
# `kci_logs.aws_cloudwatch_query` was written before its live twin —
# *"the surface is expressible on AWS"* is a CLAIM, and a claim about a design
# is worth what its falsifier is worth. This file is the falsifier for
# `CloudMetricSource`: the ONE verb, keyed on the provider's own handle, with a
# window alongside, carries the CloudWatch shape without a change to the trait,
# to `MetricPage`, to `MetricSeries` or to `MetricPoint`. ⚠ Read the package
# `__init__` before assuming the GCP half is any more "done" — NEITHER arm has a
# live conformer, and that is a decision, not a gap.
#
# THE WIRE (CloudWatch, JSON 1.1 over the `GraniteServiceVersion20100801` target
# prefix — yes, really; the service's internal name predates "CloudWatch"):
#   POST /   X-Amz-Target: GraniteServiceVersion20100801.GetMetricData
#   {"StartTime":1789120800,"EndTime":1789207200,"ScanBy":"TimestampAscending",
#    "MetricDataQueries":[{"Id":"m1","MetricStat":{"Metric":{
#      "Namespace":"AWS/ECS","MetricName":"CPUUtilization","Dimensions":[
#        {"Name":"ClusterName","Value":"c"},{"Name":"ServiceName","Value":"s"}]},
#      "Period":3600,"Stat":"Sum"}}]}
#   -> {"MetricDataResults":[{"Id":"m1","Label":"…","Timestamps":[1789120800],
#                             "Values":[42.0],"StatusCode":"Complete"}]}
#
# ── ⛔⛔ THE THREE THINGS THAT ARE SILENT WHEN WRONG ON THIS API ────────────
#
#   1. `Timestamps` AND `Values` ARE **PARALLEL ARRAYS**, not a list of pairs.
#      A parser that reads them independently and zips whatever it got pairs
#      value[i] with timestamp[i] across two arrays nothing has checked are the
#      same length — and every resulting point is plausible. `_zip_points` below
#      takes `min(len, len)` and RECORDS a mismatch as a FAULT rather than
#      silently truncating.
#
#   2. `ScanBy` DEFAULTS TO `TimestampDescending` — NEWEST FIRST. `MetricSeries.
#      points` promises OLDEST -> NEWEST (the `startFromHead: true` rule of the
#      log arm, for the identical reason), so the ascending scan is STATED, not
#      omitted. ⚠ Omitting the field is NOT the same as stating it here.
#
#   3. `StatusCode: "PartialData"` IS A TRUNCATED ANSWER INSIDE AN HTTP 200.
#      CloudWatch reports "I could not compute all of this" with a successful
#      call and a plausible short array. It reaches `MetricPage.fault`, because
#      a partial series read as complete is how "the error rate was fine" gets
#      said about a window nobody actually measured.
#
# ── ⛔ THE ALLOW-LIST IS THE SECURITY BOUNDARY (the GCP arm's rule, restated).
# `AWS_METRIC_RESULT_FIELD_ALLOWLIST` is the complete set of keys that can leave
# this parser. And ⛔ a response body is never echoed.
#
# def-based, Mojo 1.0.0b2. No UnsafePointer, no wildcard origin, no FFI.
# =============================================================================

from kci_logs.json_scan import (
    json_scan_string,
    json_skip_space,
    json_skip_value,
)

from komira_cloud_metrics.cloud_metric_source import (
    MetricPage,
    MetricPoint,
    MetricSeries,
    MetricWindow,
)
from komira_cloud_metrics.metric_json import json_scan_scalar_text, parse_f64


comptime CLOUDWATCH_METRICS_TARGET: String = (
    "GraniteServiceVersion20100801.GetMetricData"
)
comptime CLOUDWATCH_METRICS_SERVICE: String = "monitoring"
"""⚠⚠ THE SIGV4 SERVICE NAME FOR CLOUDWATCH **METRICS** IS `monitoring`, AND
THAT IS NOT A TYPO. CloudWatch LOGS signs under `logs`; CloudWatch METRICS signs
under `monitoring` — the service's own pre-rebrand name, which also appears in
its endpoint (`monitoring.<region>.amazonaws.com`). Signing metrics under
`cloudwatch` — the obvious guess, and the name in every console — answers
`SignatureDoesNotMatch`, an error that names the CREDENTIAL and sends every
reader to look at their AWS keys."""

comptime AWS_METRIC_RESULT_FIELD_ALLOWLIST: String = (
    "MetricDataResults,Id,Label,Timestamps,Values,StatusCode,NextToken"
)
"""The complete set of `MetricDataResult` keys this parser lets out.

⚠ `Messages` IS OFF IT. It carries provider-chosen free text about the query
(throttling notes, arithmetic complaints), and this package's rule is that no
bytes the server chose reach a report."""


def cloudwatch_metrics_host(region: String) -> String:
    """`monitoring.<region>.amazonaws.com` — the regional CloudWatch metrics
    endpoint, or EMPTY for an empty region. ⚠ NOT `logs.<region>…`, which is the
    LOGS endpoint; two different hosts, two different SigV4 service names."""
    if region.byte_length() == 0:
        return String("")
    return String("monitoring.") + region + String(".amazonaws.com")


# =============================================================================
# §1 — handle arithmetic on an ECS SERVICE ARN.
# =============================================================================
def ecs_service_cluster(service_arn: String) -> String:
    """The CLUSTER name in `arn:aws:ecs:<r>:<a>:service/<cluster>/<service>`, or
    EMPTY.

    ⚠ THE LEGACY TWO-SEGMENT SHAPE (`…:service/<service>`, no cluster) EXISTS
    AND RETURNS EMPTY HERE, deliberately. `GetMetricData` needs BOTH the
    `ClusterName` and `ServiceName` dimensions; a query carrying only one
    matches every service of that name in every cluster and returns numbers that
    are somebody else's. ⛔ Refuse, do not partially dimension."""
    var marker = String(":service/")
    var at = service_arn.find(marker)
    if at < 0:
        return String("")
    var rest = String(service_arn[byte = at + marker.byte_length() :])
    var slash = rest.find(String("/"))
    if slash <= 0:
        return String("")
    return String(rest[byte=0:slash])


def ecs_service_name(service_arn: String) -> String:
    """The SERVICE name — the segment after the cluster — or EMPTY (including
    for the legacy cluster-less shape; see `ecs_service_cluster`)."""
    var marker = String(":service/")
    var at = service_arn.find(marker)
    if at < 0:
        return String("")
    var rest = String(service_arn[byte = at + marker.byte_length() :])
    var slash = rest.find(String("/"))
    if slash <= 0:
        return String("")
    var leaf = String(rest[byte = slash + 1 :])
    if leaf.byte_length() == 0 or leaf.find(String("/")) >= 0:
        return String("")
    return leaf^


# =============================================================================
# §2 — the REQUEST BODY.
# =============================================================================
def get_metric_data_body(
    namespace: String,
    metric_name: String,
    stat: String,
    period_s: Int,
    service_arn: String,
    window: MetricWindow,
) -> String:
    """The FULLY-FORMED `GetMetricData` body. EMPTY when the handle cannot be
    fully dimensioned, when either window bound is empty, or when the metric is
    unnamed — the refusals.

    ⚠ `StartTime`/`EndTime` ARE EPOCH SECONDS HERE, where the GCP arm's window
    is RFC3339. `MetricWindow` carries the PROVIDER'S OWN spelling and does not
    normalise (see its docstring), so this builder interpolates what it was
    given. ⛔ A caller handing this arm an RFC3339 string produces a body AWS
    rejects — which is a loud failure, and is the correct direction: the silent
    alternative would be this layer inventing a conversion whose timezone
    handling nothing tests.

    ★ `ScanBy: TimestampAscending` — see the module header. Oldest first, stated
    rather than defaulted."""
    var cluster = ecs_service_cluster(service_arn)
    var service = ecs_service_name(service_arn)
    if (
        cluster.byte_length() == 0
        or service.byte_length() == 0
        or metric_name.byte_length() == 0
        or namespace.byte_length() == 0
        or not window.ok()
    ):
        return String("")
    var p = period_s if period_s > 0 else 3600
    return (
        String('{"StartTime":')
        + window.start
        + String(',"EndTime":')
        + window.end
        + String(',"ScanBy":"TimestampAscending","MetricDataQueries":[{"Id":')
        + String('"m1","MetricStat":{"Metric":{"Namespace":"')
        + namespace
        + String('","MetricName":"')
        + metric_name
        + String('","Dimensions":[{"Name":"ClusterName","Value":"')
        + cluster
        + String('"},{"Name":"ServiceName","Value":"')
        + service
        + String('"}]},"Period":')
        + String(p)
        + String(',"Stat":"')
        + stat
        + String('"}}]}')
    )


# =============================================================================
# §3 — the allow-listed PARSE.
# =============================================================================
def _scan_scalar_array(
    b: Span[UInt8, _], start: Int, mut out: List[String]
) -> Int:
    """Read a JSON array of scalars at `start` into `out` as TEXT. Returns the
    index after `]`, or -1."""
    out = List[String]()
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("[")):
        return -1
    j += 1
    var val = String()
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("]")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var nv = json_scan_scalar_text(b, j, val)
        if nv < 0:
            return -1
        out.append(val.copy())
        j = nv


def _zip_points(
    timestamps: List[String], values: List[String], mut s: MetricSeries
) -> Bool:
    """Pair the two PARALLEL arrays into points. Returns False when they DISAGREE
    in length.

    ⛔⛔ THE LENGTH CHECK IS THE WHOLE FUNCTION. `Timestamps` and `Values` are
    two independent arrays that CloudWatch promises are index-aligned; nothing
    in the JSON says so, and a parser that zips `min(n, m)` silently discards
    the tail of the longer one AND — worse — keeps pairing the rest, so every
    surviving point still looks right. A disagreement means the body is not what
    this parser thinks it is, and the honest answer is a FAULT, not a shorter
    series."""
    if len(timestamps) != len(values):
        return False
    for i in range(len(timestamps)):
        var v = Float64(0)
        if not parse_f64(values[i], v):
            return False
        s.points.append(MetricPoint(timestamps[i].copy(), v))
    return True


def _parse_result_object(
    b: Span[UInt8, _], start: Int, mut s: MetricSeries, mut status_code: String
) -> Int:
    """Parse ONE `MetricDataResult` at `start` through the allow-list. Returns
    the index after its closing brace, or -1."""
    s = MetricSeries.empty()
    status_code = String("")
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var val = String()
    var timestamps = List[String]()
    var values = List[String]()
    var saw_ts = False
    var saw_vals = False
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            if saw_ts or saw_vals:
                if not _zip_points(timestamps, values, s):
                    return -1
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
        if key == String("Label"):
            var nv = json_scan_scalar_text(b, j, val)
            if nv < 0:
                return -1
            s.label_summary = val.copy()
            j = nv
        elif key == String("StatusCode"):
            var nc = json_scan_scalar_text(b, j, val)
            if nc < 0:
                return -1
            status_code = val.copy()
            j = nc
        elif key == String("Timestamps"):
            var nt = _scan_scalar_array(b, j, timestamps)
            if nt < 0:
                return -1
            saw_ts = True
            j = nt
        elif key == String("Values"):
            var nva = _scan_scalar_array(b, j, values)
            if nva < 0:
                return -1
            saw_vals = True
            j = nva
        else:
            # ⚠ `Messages` LANDS HERE, and that is the allow-list working.
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns


def _find_key(body: String, b: Span[UInt8, _], key: String) -> Int:
    var needle = String('"') + key + String('"')
    var idx = body.find(needle)
    if idx < 0:
        return -1
    var j = json_skip_space(b, idx + needle.byte_length())
    if j >= len(b) or b[j] != UInt8(ord(":")):
        return -1
    return json_skip_space(b, j + 1)


def parse_get_metric_data_body(body: String) -> MetricPage:
    """Parse a `GetMetricData` response into a `MetricPage`. ⛔ NEVER RAISES and
    ⛔ NEVER ECHOES THE BODY.

    AN EMPTY OR ABSENT `MetricDataResults` ARRAY IS A SUCCESS — the provider
    answered and there is nothing there.

    ⛔ A `PartialData` STATUS CODE IS A **FAULT**, NOT A SHORTER ANSWER. See the
    module header: it is a truncated computation reported inside an HTTP 200,
    and a caller that took the short array at face value would say "the error
    rate was fine" about a window nobody measured."""
    var b = body.as_bytes()
    var page = MetricPage.empty(200)
    if body.byte_length() == 0:
        return page^
    var tok = _find_key(body, b, String("NextToken"))
    if tok >= 0:
        var tval = String()
        if json_scan_string(b, tok, tval) >= 0:
            page.next_token = tval^
    var ri = _find_key(body, b, String("MetricDataResults"))
    if ri < 0:
        return page^
    var j = json_skip_space(b, ri)
    if j >= len(b) or b[j] != UInt8(ord("[")):
        return MetricPage.failed(
            200,
            String("`MetricDataResults` was not an array at byte ")
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
                String("unterminated `MetricDataResults` array in a ")
                + String(body.byte_length())
                + String("-byte body (NOT echoed)"),
            )
        if b[j] == UInt8(ord("]")):
            return page^
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var s = MetricSeries.empty()
        var status_code = String("")
        var nx = _parse_result_object(b, j, s, status_code)
        if nx < 0:
            return MetricPage.failed(
                200,
                String("malformed MetricDataResult at byte ")
                + String(j)
                + String(" of a ")
                + String(body.byte_length())
                + String(
                    "-byte body (NOT echoed) — a Timestamps/Values length"
                    " disagreement lands here, and it is a fault rather than a"
                    " shorter series on purpose"
                ),
            )
        if status_code == String("PartialData"):
            return MetricPage.failed(
                200,
                String(
                    "CloudWatch answered StatusCode=PartialData for series '"
                )
                + s.label_summary
                + String(
                    "' — the computation was TRUNCATED inside an HTTP 200, so"
                    " the points returned do not cover the window that was"
                    " asked for"
                ),
            )
        page.series.append(s^)
        j = nx
