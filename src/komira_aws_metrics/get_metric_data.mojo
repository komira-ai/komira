# =============================================================================
# komira_aws_metrics/get_metric_data.mojo: CloudWatch GetMetricData, PURE. The
#   request body, the response parse and the error, with no transport.
# =============================================================================
#
# THE WIRE (awsJson 1.0, which CloudWatch serves beside its query and CBOR
# protocols):
#
#   POST /    X-Amz-Target: GraniteServiceVersion20100801.GetMetricData
#             Content-Type: application/x-amz-json-1.0
#   {"StartTime":1789120800,"EndTime":1789207200,
#    "MetricDataQueries":[{"Id":"m1","MetricStat":{
#      "Metric":{"Namespace":"AWS/ECS","MetricName":"CPUUtilization",
#                "Dimensions":[{"Name":"ClusterName","Value":"c"}, ...]},
#      "Period":60,"Stat":"Average"},"ReturnData":true}],
#    "ScanBy":"TimestampDescending","MaxDatapoints":1440}
#   -> {"MetricDataResults":[{"Id":"m1","Label":"CPUUtilization",
#        "Timestamps":[1789120800,...],"Values":[42.0,...],
#        "StatusCode":"Complete"}],"NextToken":"..."}
#
# ── WHY THIS IS HAND-WRITTEN AND NOT GENERATED ──────────────────────────────
# The CloudWatch model in the pinned botocore archive
# (//third_party/botocore:cloudwatch, api 2010-08-01) declares `protocol: smithy-rpc-v2-cbor`
# and lists `smithy-rpc-v2-cbor`, `json` and `query` in `protocols`. The AWS
# generator chooses the first protocol of that list it supports, `json`
# (`tools/build/proto-codegen/src/aws_in.rs`, `lower_metadata`;
# `emit_aws/proto.rs`, `select_protocol`, refuses the choice if unsupported).
# Generating the CloudWatch client into this package is a follow-up; when it
# lands, this file becomes the reader's adapter over it.
#
# ── WHAT IS SILENT WHEN WRONG ON THIS API ───────────────────────────────────
#   1. The signing name is `monitoring`, the service's endpoint prefix, not
#      `cloudwatch`. A request signed as `cloudwatch` is answered
#      SignatureDoesNotMatch, an error that points at the credential.
#   2. `Timestamps` and `Values` are PARALLEL arrays. A length mismatch is a
#      malformed response, refused here rather than zipped short.
#   3. A timestamp is the START of its period: a 5-second period queried at
#      15:07:17 for the last five minutes answers points "timestamped
#      between 15:02:15 and 15:07:15" (the model's StartTime documentation).
#      The reader turns it into the period's end, the seam's sample time.
#   4. `ScanBy` is stated newest first (also the service's default), so a
#      read cut at its point limit keeps the newest points, as the seam
#      requires; the reader reverses them into oldest first.
#   5. `StatusCode: PartialData` inside an HTTP 200 means more data is
#      available (with a `NextToken`) or the answer was cut. It is reported
#      on the parsed result, never dropped.
#
# The constants below are checked against the pinned model by the welded
# test_cloudwatch_model, so a botocore bump that changes one fails the build.
#
# The body is written with komira_json, so a dimension value holding a quote
# or a control byte is escaped rather than breaking the document.
#
# Encapsulation: value types only. No pointer. Reads no environment.
# =============================================================================

from komira_aws_core import AwsErrorInfo, HttpResult, aws_json_error_info
from komira_json import JsonValue, parse_json_value


comptime CLOUDWATCH_SIGNING_NAME: String = "monitoring"
"""The SigV4 service name and endpoint prefix of CloudWatch metrics (the
model's `endpointPrefix`; it declares no separate `signingName`)."""

comptime GET_METRIC_DATA_TARGET: String = (
    "GraniteServiceVersion20100801.GetMetricData"
)
"""The `X-Amz-Target` of GetMetricData: the model's `targetPrefix` and the
operation name."""

comptime CLOUDWATCH_JSON_CONTENT_TYPE: String = "application/x-amz-json-1.0"

comptime GET_METRIC_DATA_MAX_DATAPOINTS: Int = 100_800
"""The most datapoints one GetMetricData call returns, and its default
(the model's `MaxDatapoints` documentation)."""

comptime CLOUDWATCH_MAX_DIMENSIONS: Int = 30
"""The most dimensions a metric carries (the model's `Dimensions` max)."""

comptime _QUERY_ID: String = "m1"


@fieldwise_init
struct CloudWatchDimension(Copyable, Movable):
    """One `Name`/`Value` dimension of a metric."""

    var name: String
    var value: String


@fieldwise_init
struct CloudWatchMetricStat(Copyable, Movable):
    """One metric and the statistic to read of it: the `MetricStat` of the
    single query this package sends.

    `stat` is a CloudWatch statistic (`Sum`, `Average`, `Minimum`,
    `Maximum`, `SampleCount`) and `period_s` the period in seconds."""

    var namespace: String
    var metric_name: String
    var dimensions: List[CloudWatchDimension]
    var period_s: Int
    var stat: String


def cloudwatch_period_ok(period_s: Int) -> Bool:
    """True for a period GetMetricData accepts: 1, 5, 10, 20 or 30 seconds
    (for high-resolution metrics) or a positive multiple of 60 (the model's
    `MetricStat.Period` documentation)."""
    if (
        period_s == 1
        or period_s == 5
        or period_s == 10
        or period_s == 20
        or period_s == 30
    ):
        return True
    return period_s >= 60 and period_s % 60 == 0


def ecs_service_dimensions(service_arn: String) raises -> List[CloudWatchDimension]:
    """The `ClusterName` and `ServiceName` dimensions of an ECS service ARN,
    `arn:<partition>:ecs:<region>:<account>:service/<cluster>/<service>`.

    Raises for the old ARN form with no cluster
    (`...:service/<service>`), and for anything else: a query dimensioned on
    the service name alone matches that name in every cluster of the account,
    and returns numbers that are another service's."""
    var marker = String(":service/")
    var at = service_arn.find(marker)
    if not service_arn.startswith(String("arn:")) or at < 0:
        raise Error("not an ECS service ARN (want arn:...:service/<cluster>/<service>)")
    var rest = String(service_arn[byte = at + marker.byte_length() :])
    var slash = rest.find(String("/"))
    if slash <= 0:
        raise Error(
            "an ECS service ARN without a cluster cannot be dimensioned: the"
            " service name alone matches every cluster"
        )
    var cluster = String(rest[byte=0:slash])
    var service = String(rest[byte = slash + 1 :])
    if service.byte_length() == 0 or service.find(String("/")) >= 0:
        raise Error("an ECS service ARN names no service after its cluster")
    var out = List[CloudWatchDimension]()
    out.append(CloudWatchDimension(String("ClusterName"), cluster^))
    out.append(CloudWatchDimension(String("ServiceName"), service^))
    return out^


def build_get_metric_data_body(
    stat: CloudWatchMetricStat,
    start_s: Int64,
    end_s: Int64,
    max_datapoints: Int,
    next_token: String,
) raises -> String:
    """The GetMetricData JSON body for one `MetricStat` over
    `[start_s, end_s)` (epoch seconds, matched against each period's start
    timestamp), newest first, at most `max_datapoints` points per page, continuing from `next_token` when it is not "".

    Refuses, rather than sends, a request the service would answer with a
    validation error or, worse, with the wrong numbers: an empty namespace,
    metric or statistic, a dimension with an empty name or value, more than
    `CLOUDWATCH_MAX_DIMENSIONS`, a period GetMetricData does not accept, an
    empty or inverted window, and `max_datapoints` outside
    [1, GET_METRIC_DATA_MAX_DATAPOINTS]."""
    if stat.namespace.byte_length() == 0:
        raise Error("GetMetricData: the namespace is empty")
    if stat.metric_name.byte_length() == 0:
        raise Error("GetMetricData: the metric name is empty")
    if stat.stat.byte_length() == 0:
        raise Error("GetMetricData: the statistic is empty")
    if len(stat.dimensions) > CLOUDWATCH_MAX_DIMENSIONS:
        raise Error(
            String("GetMetricData: ")
            + String(len(stat.dimensions))
            + String(" dimensions; a metric has at most ")
            + String(CLOUDWATCH_MAX_DIMENSIONS)
        )
    if not cloudwatch_period_ok(stat.period_s):
        raise Error(
            String("GetMetricData: a period of ")
            + String(stat.period_s)
            + String(" s; the period is 1, 5, 10, 20, 30 or a multiple of 60")
        )
    if start_s >= end_s:
        raise Error(
            String("GetMetricData: the window [")
            + String(start_s)
            + String(", ")
            + String(end_s)
            + String(") is empty")
        )
    if max_datapoints < 1 or max_datapoints > GET_METRIC_DATA_MAX_DATAPOINTS:
        raise Error(
            String("GetMetricData: MaxDatapoints ")
            + String(max_datapoints)
            + String(" is outside [1, ")
            + String(GET_METRIC_DATA_MAX_DATAPOINTS)
            + String("]")
        )
    var dims = JsonValue.empty_array()
    for i in range(len(stat.dimensions)):
        ref d = stat.dimensions[i]
        if d.name.byte_length() == 0 or d.value.byte_length() == 0:
            raise Error("GetMetricData: a dimension has an empty name or value")
        var o = JsonValue.empty_object()
        o.set_member(String("Name"), JsonValue.from_string(d.name.copy()))
        o.set_member(String("Value"), JsonValue.from_string(d.value.copy()))
        dims.push(o^)
    var metric = JsonValue.empty_object()
    metric.set_member(String("Namespace"), JsonValue.from_string(stat.namespace.copy()))
    metric.set_member(String("MetricName"), JsonValue.from_string(stat.metric_name.copy()))
    metric.set_member(String("Dimensions"), dims^)
    var metric_stat = JsonValue.empty_object()
    metric_stat.set_member(String("Metric"), metric^)
    metric_stat.set_member(String("Period"), JsonValue.from_i64(Int64(stat.period_s)))
    metric_stat.set_member(String("Stat"), JsonValue.from_string(stat.stat.copy()))
    var query = JsonValue.empty_object()
    query.set_member(String("Id"), JsonValue.from_string(String(_QUERY_ID)))
    query.set_member(String("MetricStat"), metric_stat^)
    query.set_member(String("ReturnData"), JsonValue.from_bool(True))
    var queries = JsonValue.empty_array()
    queries.push(query^)
    var body = JsonValue.empty_object()
    body.set_member(String("StartTime"), JsonValue.from_i64(start_s))
    body.set_member(String("EndTime"), JsonValue.from_i64(end_s))
    body.set_member(String("MetricDataQueries"), queries^)
    body.set_member(String("ScanBy"), JsonValue.from_string(String("TimestampDescending")))
    body.set_member(String("MaxDatapoints"), JsonValue.from_i64(Int64(max_datapoints)))
    if next_token.byte_length() > 0:
        body.set_member(String("NextToken"), JsonValue.from_string(next_token.copy()))
    return body.serialize()


@fieldwise_init
struct CloudWatchResult(Copyable, Movable):
    """One `MetricDataResult`: its id and label, its points as parallel
    epoch-second times and values (lengths checked equal), and its status
    (`Complete`, `PartialData`, `Forbidden` or `InternalError`).

    `Messages` is not read: it is free text the service chose."""

    var id: String
    var label: String
    var timestamps: List[Int64]
    var values: List[Float64]
    var status_code: String


@fieldwise_init
struct CloudWatchPage(Copyable, Movable):
    """One GetMetricData response: its results and its `NextToken` ("" when
    the response has none)."""

    var results: List[CloudWatchResult]
    var next_token: String


def parse_get_metric_data_response(body: String) raises -> CloudWatchPage:
    """Parse a GetMetricData response.

    An absent or empty `MetricDataResults` is an answer with no results.
    Raises for a body that is not a JSON object, a result that is not an
    object, a `Timestamps` or `Values` entry that is not a number, and
    `Timestamps` and `Values` of different lengths. A raise names the byte
    count and what was wrong, never the body."""
    var doc: JsonValue
    try:
        doc = parse_json_value(body)
    except e:
        raise Error(
            String("GetMetricData: the ")
            + String(body.byte_length())
            + String("-byte response is not JSON: ")
            + String(e)
        )
    if not doc.is_object():
        raise Error("GetMetricData: the response is not a JSON object")
    var token = String("")
    if doc.has(String("NextToken")):
        var t = doc.get(String("NextToken"))
        if t.is_string():
            token = t.as_string()
    var results = List[CloudWatchResult]()
    if doc.has(String("MetricDataResults")):
        var arr = doc.get(String("MetricDataResults"))
        if not arr.is_array():
            raise Error("GetMetricData: MetricDataResults is not an array")
        for i in range(arr.array_len()):
            results.append(_parse_result(arr.element_at(i), i))
    return CloudWatchPage(results^, token^)


def _string_member(o: JsonValue, key: String) raises -> String:
    if not o.has(key):
        return String("")
    var v = o.get(key)
    if not v.is_string():
        raise Error(String("GetMetricData: ") + key + String(" is not a string"))
    return v.as_string()


def _parse_result(r: JsonValue, index: Int) raises -> CloudWatchResult:
    if not r.is_object():
        raise Error(
            String("GetMetricData: result ") + String(index) + String(" is not an object")
        )
    var times = List[Int64]()
    var values = List[Float64]()
    if r.has(String("Timestamps")):
        var ts = r.get(String("Timestamps"))
        if not ts.is_array():
            raise Error("GetMetricData: Timestamps is not an array")
        for j in range(ts.array_len()):
            var t = ts.element_at(j)
            if not t.is_number():
                raise Error("GetMetricData: a timestamp is not a number")
            # Epoch seconds; awsJson allows a fraction, which a period of
            # whole seconds never carries.
            times.append(Int64(Int(t.as_float64())))
    if r.has(String("Values")):
        var vs = r.get(String("Values"))
        if not vs.is_array():
            raise Error("GetMetricData: Values is not an array")
        for j in range(vs.array_len()):
            var v = vs.element_at(j)
            if not v.is_number():
                raise Error("GetMetricData: a value is not a number")
            values.append(v.as_float64())
    if len(times) != len(values):
        raise Error(
            String("GetMetricData: result ")
            + String(index)
            + String(" has ")
            + String(len(times))
            + String(" timestamps and ")
            + String(len(values))
            + String(" values; the two arrays are parallel")
        )
    return CloudWatchResult(
        _string_member(r, String("Id")),
        _string_member(r, String("Label")),
        times^,
        values^,
        _string_member(r, String("StatusCode")),
    )


def get_metric_data_error(res: HttpResult) -> Error:
    """The error of a failed GetMetricData call: status, code, message and
    request id, as komira_aws_core reads an awsJson error (the code from
    `x-amzn-query-error`, `X-Amzn-Errortype` or the body's `__type`)."""
    var info: AwsErrorInfo = aws_json_error_info(res.to_response())
    return info.to_error(String("GetMetricData"))
