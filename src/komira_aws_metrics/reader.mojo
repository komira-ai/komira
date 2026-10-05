# =============================================================================
# komira_aws_metrics/reader.mojo: CloudWatchMetricsReader, a MetricsReader over
#   GetMetricData.
# =============================================================================
#
# ONE READER READS ONE NAMESPACE, WITH FIXED DIMENSIONS. The reader is built
# with a namespace (`AWS/ECS`, a custom one) and the dimensions that address
# the workload it reads about (an ECS service's `ClusterName` and
# `ServiceName`, from `ecs_service_dimensions`). A query names the metric;
# its equality matchers add dimensions. So a reader wired for one service
# cannot be asked about another one's numbers.
#
# WHAT A QUERY MAPS TO:
#
#   | MetricsQuery            | GetMetricData                                  |
#   |-------------------------|------------------------------------------------|
#   | metric                  | MetricStat.Metric.MetricName                   |
#   | matchers (equality)     | further Dimensions                             |
#   | sum, mean, min, max, count | Stat Sum, Average, Minimum, Maximum, SampleCount |
#   | rate                    | Stat Sum, each value divided by the period     |
#   | step_ms                 | Period, in whole seconds                       |
#   | [start_ns, end_ns]      | StartTime = start seconds, EndTime = end seconds + 1 |
#   | point_limit             | MaxDatapoints, and the paging stops there      |
#
# AND WHAT IT REFUSES, before any call (`refusal`): `raw` (CloudWatch keeps
# statistics per period, not points), `group_by` (one MetricStat is one
# series; grouping needs a metric-math SEARCH expression, which this reader
# does not send), a negated matcher (dimensions match by equality), a matcher
# on a dimension the reader fixes, and a step that is not a period
# GetMetricData accepts.
#
# Paging follows `NextToken` up to `max_pages` calls; stopping with a token
# left, or at the point limit, or on a final `PartialData`, sets `truncated`.
# The scan is ascending, so at the point limit the series keeps its OLDEST
# points.
# A result whose `StatusCode` is `Forbidden` or `InternalError` raises.
#
# The transport, the signing clock and the credential source are type
# parameters: production binds komira_aws_core's `AwsConnectorTransport` over
# a TLS connector, `SystemAwsClock` and a credential chain; the tests bind a
# scripted connector, a fixed clock and a static credential. Each call is
# signed and retried by komira_aws_core (`send_sigv4_signed_request_with`).
#
# Encapsulation: value types and owned type parameters. No pointer. Reads no
# environment: the region and endpoint are the caller's.
# =============================================================================

from komira_aws_core import (
    AwsClock,
    AwsCredsSource,
    AwsEndpoint,
    AwsHttpTransport,
    AwsRetryQuota,
    Header,
    HttpResult,
    aws_service_endpoint,
    aws_standard_retry_policy,
    aws_system_retry_loop,
    send_sigv4_signed_request_with,
)
from komira_metrics_reader import (
    MetricsLabel,
    MetricsPage,
    MetricsQuery,
    MetricsReader,
    MetricsSample,
    MetricsSeriesData,
)

from komira_aws_metrics.get_metric_data import (
    CLOUDWATCH_JSON_CONTENT_TYPE,
    CLOUDWATCH_MAX_DIMENSIONS,
    CLOUDWATCH_SIGNING_NAME,
    GET_METRIC_DATA_MAX_DATAPOINTS,
    GET_METRIC_DATA_TARGET,
    CloudWatchDimension,
    CloudWatchMetricStat,
    build_get_metric_data_body,
    cloudwatch_period_ok,
    get_metric_data_error,
    parse_get_metric_data_response,
)


comptime CLOUDWATCH_DEFAULT_MAX_PAGES: Int = 10
"""The most GetMetricData calls one read makes. Each call returns up to
`MaxDatapoints` points, so this bounds a read's cost before the point limit
does."""


def cloudwatch_endpoint(region: String) raises -> AwsEndpoint:
    """`https://monitoring.<region>.<partition dns suffix>`, the regional
    CloudWatch endpoint. Raises for an empty or malformed region."""
    return aws_service_endpoint(
        String(CLOUDWATCH_SIGNING_NAME), region, False, False
    )


def cloudwatch_stat(q: MetricsQuery) -> String:
    """The CloudWatch statistic a query's aggregation reads, or "" for one
    it cannot (`raw`). `rate` reads `Sum`."""
    var name = q.aggregation.name()
    if name == "sum" or name == "rate":
        return String("Sum")
    if name == "mean":
        return String("Average")
    if name == "min":
        return String("Minimum")
    if name == "max":
        return String("Maximum")
    if name == "count":
        return String("SampleCount")
    return String("")


struct CloudWatchMetricsReader[
    X: AwsHttpTransport,
    K: AwsClock & Movable & Deinitable,
    P: AwsCredsSource,
](MetricsReader, Movable, Deinitable):
    """A `MetricsReader` over CloudWatch GetMetricData for one namespace and
    a fixed set of dimensions (module header)."""

    var _transport: Self.X
    var _clock: Self.K
    var _creds: Self.P
    var _region: String
    var _endpoint: AwsEndpoint
    var _namespace: String
    var _dimensions: List[CloudWatchDimension]
    var _quota: AwsRetryQuota
    var _max_pages: Int

    def __init__(
        out self,
        var transport: Self.X,
        var clock: Self.K,
        var creds: Self.P,
        region: String,
        endpoint: AwsEndpoint,
        namespace: String,
        var dimensions: List[CloudWatchDimension],
    ):
        """`region` signs each call; `endpoint` is where it goes
        (`cloudwatch_endpoint(region)` for the service itself)."""
        self._transport = transport^
        self._clock = clock^
        self._creds = creds^
        self._region = region.copy()
        self._endpoint = endpoint.copy()
        self._namespace = namespace.copy()
        self._dimensions = dimensions^
        self._quota = AwsRetryQuota()
        self._max_pages = CLOUDWATCH_DEFAULT_MAX_PAGES

    def set_max_pages(mut self, n: Int):
        """The most calls one read makes (at least 1)."""
        self._max_pages = n if n >= 1 else 1

    def refusal(self, q: MetricsQuery) -> String:
        if q.metric.byte_length() == 0:
            return String("name a CloudWatch metric")
        if q.aggregation.is_raw():
            return String(
                "CloudWatch keeps statistics per period, not stored points:"
                " ask for sum, rate, mean, min, max or count"
            )
        if len(q.group_by) > 0:
            return String(
                "this reader reads one CloudWatch metric with one set of"
                " dimensions; group_by needs a metric-math SEARCH expression,"
                " which it does not send"
            )
        if q.step_ms % Int64(1000) != Int64(0) or not cloudwatch_period_ok(
            Int(q.step_ms // Int64(1000))
        ):
            return (
                String("a step of ")
                + String(q.step_ms)
                + String(
                    " ms is not a CloudWatch period: use 1000, 5000, 10000,"
                    " 30000 or a multiple of 60000"
                )
            )
        for i in range(len(q.matchers)):
            ref m = q.matchers[i]
            if m.negated:
                return String(
                    "CloudWatch dimensions match by equality only; '"
                ) + m.key + String("' is negated")
            if m.value.byte_length() == 0:
                return String("the dimension '") + m.key + String(
                    "' has an empty value"
                )
            for j in range(len(self._dimensions)):
                if self._dimensions[j].name == m.key:
                    return String("the dimension '") + m.key + String(
                        "' is fixed by this reader"
                    )
            for j in range(i):
                if q.matchers[j].key == m.key:
                    return String("the dimension '") + m.key + String(
                        "' is matched twice"
                    )
        if len(self._dimensions) + len(q.matchers) > CLOUDWATCH_MAX_DIMENSIONS:
            return String("more dimensions than a CloudWatch metric has")
        return String("")

    def read(mut self, q: MetricsQuery) raises -> MetricsPage:
        var why = self.refusal(q)
        if why.byte_length() > 0:
            raise Error(String("CloudWatch: ") + why)
        var period_s = Int(q.step_ms // Int64(1000))
        var dims = self._dimensions.copy()
        for i in range(len(q.matchers)):
            dims.append(
                CloudWatchDimension(
                    q.matchers[i].key.copy(), q.matchers[i].value.copy()
                )
            )
        var stat = CloudWatchMetricStat(
            self._namespace.copy(),
            q.metric.copy(),
            dims.copy(),
            period_s,
            cloudwatch_stat(q),
        )
        var start_s = q.start_ns // Int64(1_000_000_000)
        var end_s = q.end_ns // Int64(1_000_000_000) + Int64(1)
        var limit = q.point_limit
        if limit < 1:
            limit = 1
        var series = MetricsSeriesData.named(q.metric)
        for i in range(len(dims)):
            series.labels.append(
                MetricsLabel(dims[i].name.copy(), dims[i].value.copy())
            )
        var rate = q.aggregation.name() == "rate"
        var token = String("")
        var calls = 0
        var truncated = False
        var last_status = String("")
        while True:
            var want = limit - len(series.samples)
            if want > GET_METRIC_DATA_MAX_DATAPOINTS:
                want = GET_METRIC_DATA_MAX_DATAPOINTS
            var body = build_get_metric_data_body(
                stat, start_s, end_s, want, token
            )
            var res = self._send(body)
            calls += 1
            if res.status < 200 or res.status >= 300:
                raise get_metric_data_error(res)
            var page = parse_get_metric_data_response(res.body_text())
            for r in range(len(page.results)):
                ref result = page.results[r]
                if (
                    result.status_code == "Forbidden"
                    or result.status_code == "InternalError"
                ):
                    raise Error(
                        String("GetMetricData: the result for ")
                        + q.metric
                        + String(" has StatusCode ")
                        + result.status_code
                    )
                last_status = result.status_code.copy()
                for k in range(len(result.timestamps)):
                    if len(series.samples) >= limit:
                        truncated = True
                        break
                    var v = result.values[k]
                    if rate:
                        v = v / Float64(period_s)
                    series.samples.append(
                        MetricsSample(
                            result.timestamps[k] * Int64(1_000_000_000), v
                        )
                    )
            token = page.next_token.copy()
            if token.byte_length() == 0:
                break
            if len(series.samples) >= limit or calls >= self._max_pages:
                truncated = True
                break
        if last_status == "PartialData" and token.byte_length() == 0:
            truncated = True
        var out = List[MetricsSeriesData]()
        if len(series.samples) > 0:
            out.append(series^)
        return MetricsPage(out^, truncated, calls)

    def _send(mut self, body: String) raises -> HttpResult:
        var extra = List[Header]()
        extra.append(Header(String("X-Amz-Target"), String(GET_METRIC_DATA_TARGET)))
        # CloudWatch is awsQueryCompatible: in query mode its errors name
        # the legacy query code in `x-amzn-query-error`, as botocore reports
        # them.
        extra.append(Header(String("x-amzn-query-mode"), String("true")))
        var bytes = List[UInt8]()
        bytes.extend(Span(body.as_bytes()))
        var cred = self._creds.credentials()
        var loop = aws_system_retry_loop(aws_standard_retry_policy())
        return send_sigv4_signed_request_with(
            self._transport,
            self._clock,
            loop,
            self._quota,
            String("POST"),
            cred,
            self._region,
            String(CLOUDWATCH_SIGNING_NAME),
            self._endpoint,
            String("/"),
            String(CLOUDWATCH_JSON_CONTENT_TYPE),
            bytes,
            extra,
        )
