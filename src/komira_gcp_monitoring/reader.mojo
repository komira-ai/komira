# =============================================================================
# komira_gcp_monitoring/reader.mojo: CloudMonitoringMetricsReader, a
#   MetricsReader over Cloud Monitoring `timeSeries.list`.
# =============================================================================
#
# ONE READER READS ONE PROJECT. The project is the reader's, not the query's,
# so a reader wired for one project cannot be asked about another one's
# numbers.
#
# WHAT A QUERY MAPS TO:
#
#   | MetricsQuery          | timeSeries.list                                   |
#   |-----------------------|---------------------------------------------------|
#   | metric                | filter `metric.type = "<metric>"`                 |
#   | matchers              | ` AND metric.labels.<k> = "<v>"` (`!=` negated);  |
#   |                       | `resource.<k>` names `resource.labels.<k>`        |
#   | raw                   | no aggregation: the stored points                 |
#   | sum, rate, mean, min, max, count | perSeriesAligner ALIGN_SUM, ALIGN_RATE, |
#   |                       | ALIGN_MEAN, ALIGN_MIN, ALIGN_MAX, ALIGN_COUNT     |
#   | step_ms               | alignmentPeriod, whole seconds, at least 60       |
#   | group_by              | crossSeriesReducer REDUCE_SUM (sum, rate, count), |
#   |                       | REDUCE_MEAN, REDUCE_MIN, REDUCE_MAX; groupByFields|
#   | [start_ns, end_ns]    | interval (start_ns - 1 ns, end_ns]                |
#   | limits                | pageSize, then the series and point cuts          |
#
# AND WHAT IT REFUSES, before any call (`refusal`): an empty metric, a label
# key that is not a plain identifier (it would be spliced into the filter
# language), grouping a raw read (Cloud Monitoring reduces only aligned
# series), and a step that is not whole seconds or is under 60 s.
#
# A SERIES' LABELS: its metric labels, and the resource labels the query
# named (in a matcher or `group_by`), as `resource.<k>`. The other resource
# labels (project id, location, revision) describe where the series was
# recorded; they stay out unless asked for. They still tell series apart:
# pages are merged on the whole wire identity (metric type, every label,
# resource type), so two revisions of one service are two series even when
# their returned labels are equal. Name the label to see which is which.
#
# Paging follows `nextPageToken` up to `max_pages` calls. A series continued
# on a later page is merged into one. Stopping with a token left, cutting at
# a limit, or a page with `executionErrors` sets `truncated`. Points arrive
# newest first, so at the point limit a series keeps its NEWEST points.
#
# The connector and the token source are type parameters: production binds a
# TLS connector and a komira_gcp_core token source; the tests bind
# komira_http_core's ScriptedConnector and a static token. A non-2xx answer
# raises through komira_gcp_core's `gcp_status_error`, which never quotes the
# body.
#
# Encapsulation: value types and owned type parameters. No pointer. Reads no
# environment.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import GcpTokenSource, gcp_status_error
from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.transport.io_stream import Connector
from komira_metrics_reader import (
    MetricsLabel,
    MetricsPage,
    MetricsQuery,
    MetricsReader,
    MetricsSample,
    MetricsSeriesData,
)

from komira_gcp_monitoring.time_series_list import (
    LIST_TIME_SERIES_MAX_PAGE_SIZE,
    LIST_TIME_SERIES_RPC,
    MONITORING_DEFAULT_HOST,
    MONITORING_MIN_ALIGNMENT_S,
    RESOURCE_LABEL_PREFIX,
    MonitoringSeries,
    TimeSeriesListRequest,
    group_by_field,
    label_key_refusal,
    monitoring_filter,
    parse_time_series_list_response,
    rfc3339_of_ns,
    time_series_list_path,
    time_series_list_query,
)


comptime MONITORING_DEFAULT_MAX_PAGES: Int = 10
"""The most `timeSeries.list` calls one read makes."""


def monitoring_aligner(q: MetricsQuery) -> String:
    """The per-series aligner of a query's aggregation, "" for `raw`."""
    var name = q.aggregation.name()
    if name == "sum":
        return String("ALIGN_SUM")
    if name == "rate":
        return String("ALIGN_RATE")
    if name == "mean":
        return String("ALIGN_MEAN")
    if name == "min":
        return String("ALIGN_MIN")
    if name == "max":
        return String("ALIGN_MAX")
    if name == "count":
        return String("ALIGN_COUNT")
    return String("")


def monitoring_reducer(q: MetricsQuery) -> String:
    """The cross-series reducer that combines a group, "" when the query
    does not group. Sums of sums, rates and counts are sums; mean, min and
    max reduce with themselves."""
    if len(q.group_by) == 0:
        return String("")
    var name = q.aggregation.name()
    if name == "sum" or name == "rate" or name == "count":
        return String("REDUCE_SUM")
    if name == "mean":
        return String("REDUCE_MEAN")
    if name == "min":
        return String("REDUCE_MIN")
    if name == "max":
        return String("REDUCE_MAX")
    return String("")


struct CloudMonitoringMetricsReader[C: Connector, T: GcpTokenSource](
    MetricsReader, Movable, Deinitable
):
    """A `MetricsReader` over Cloud Monitoring for one project (module
    header). It starts at `monitoring.googleapis.com` over TLS;
    `set_host` points it elsewhere."""

    var _client: HttpClient[Self.C]
    var _tokens: Self.T
    var _project: String
    var _host: String
    var _port: UInt16
    var _plaintext: Bool
    var _max_pages: Int
    var _rt: BlockingRuntime[NoopSink]

    def __init__(
        out self, var client: HttpClient[Self.C], var tokens: Self.T, project: String
    ) raises:
        """`client` carries the connector and the time budget (build it with
        the serving ceiling in a process that has one); `tokens` supplies
        each request's bearer token; `project` is the project id or number
        every read addresses."""
        _ = time_series_list_path(project)
        self._client = client^
        self._tokens = tokens^
        self._project = project.copy()
        self._host = String(MONITORING_DEFAULT_HOST)
        self._port = UInt16(443)
        self._plaintext = False
        self._max_pages = MONITORING_DEFAULT_MAX_PAGES
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))

    def set_host(mut self, host: String, port: Int, plaintext: Bool = False):
        """Send to `host:port` instead (an emulator, a private endpoint).
        `plaintext` is for a local test endpoint only; the bearer token is
        sent either way."""
        self._host = host.copy()
        self._port = UInt16(port)
        self._plaintext = plaintext

    def host(self) -> String:
        """The host each read is sent to."""
        return self._host.copy()

    def set_max_pages(mut self, n: Int):
        """The most calls one read makes (at least 1)."""
        self._max_pages = n if n >= 1 else 1

    def refusal(self, q: MetricsQuery) -> String:
        if q.metric.byte_length() == 0:
            return String("name a Cloud Monitoring metric type")
        for i in range(len(q.matchers)):
            var why = label_key_refusal(q.matchers[i].key)
            if why.byte_length() > 0:
                return why
        for i in range(len(q.group_by)):
            var why = label_key_refusal(q.group_by[i])
            if why.byte_length() > 0:
                return why
        if q.aggregation.is_raw():
            if len(q.group_by) > 0:
                return String(
                    "Cloud Monitoring groups only aligned series: ask for sum,"
                    " rate, mean, min, max or count with group_by"
                )
            return String("")
        if (
            q.step_ms % Int64(1000) != Int64(0)
            or q.step_ms < Int64(MONITORING_MIN_ALIGNMENT_S * 1000)
        ):
            return (
                String("a step of ")
                + String(q.step_ms)
                + String(
                    " ms is not a Cloud Monitoring alignment period: use whole"
                    " seconds, at least 60000 ms"
                )
            )
        return String("")

    def read(mut self, q: MetricsQuery) raises -> MetricsPage:
        var why = self.refusal(q)
        if why.byte_length() > 0:
            raise Error(String("Cloud Monitoring: ") + why)
        var aligner = monitoring_aligner(q)
        var group_fields = List[String]()
        for i in range(len(q.group_by)):
            group_fields.append(group_by_field(q.group_by[i]))
        var start = q.start_ns - Int64(1) if q.start_ns > Int64(0) else Int64(0)
        var page_size = q.series_limit * q.point_limit
        if page_size < 1:
            page_size = 1
        if page_size > LIST_TIME_SERIES_MAX_PAGE_SIZE:
            page_size = LIST_TIME_SERIES_MAX_PAGE_SIZE
        var req = TimeSeriesListRequest(
            self._project.copy(),
            monitoring_filter(q.metric, q.matchers),
            rfc3339_of_ns(start),
            rfc3339_of_ns(q.end_ns),
            Int(q.step_ms // Int64(1000)) if aligner.byte_length() > 0 else 0,
            aligner,
            monitoring_reducer(q),
            group_fields^,
            page_size,
            String(""),
        )
        var keep_resource = _resource_keys_named(q)
        var keys = List[String]()
        var out = List[MetricsSeriesData]()
        var truncated = False
        var calls = 0
        while True:
            var body = self._list(req)
            calls += 1
            var page = parse_time_series_list_response(body)
            if page.execution_errors > 0:
                truncated = True
            for i in range(len(page.series)):
                # The merge key is the series' whole wire identity; the
                # labels returned are fewer (`_series_of`).
                var key = _wire_identity(page.series[i])
                var s = _series_of(page.series[i], keep_resource)
                var at = -1
                for k in range(len(keys)):
                    if keys[k] == key:
                        at = k
                        break
                if at < 0:
                    if len(out) >= q.series_limit:
                        truncated = True
                        continue
                    keys.append(key^)
                    out.append(s^)
                else:
                    out[at].samples = _merge(out[at].samples, s.samples)
            req.page_token = page.next_page_token.copy()
            if req.page_token.byte_length() == 0:
                break
            if calls >= self._max_pages:
                truncated = True
                break
        for i in range(len(out)):
            var n = len(out[i].samples)
            if n > q.point_limit:
                truncated = True
                var kept = List[MetricsSample]()
                for k in range(n - q.point_limit, n):
                    kept.append(out[i].samples[k])
                out[i].samples = kept^
        return MetricsPage(out^, truncated, calls)

    def _list(mut self, req: TimeSeriesListRequest) raises -> String:
        """One GET; the body of a 2xx answer, else the raised status."""
        var path = time_series_list_path(req.project)
        var url: Url
        if self._plaintext:
            url = Url.http(self._host.copy(), self._port, path^)
        else:
            url = Url.https(self._host.copy(), self._port, path^)
        url.query = time_series_list_query(req)
        var headers = HeaderMap()
        headers.append(
            String("Authorization"),
            String("Bearer ") + self._tokens.access_token(),
        )
        var http_req = build_get_request(url^, headers^)
        ref reactor = self._rt.reactor()
        var resp = self._client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            http_req^, reactor
        )
        var status = Int(resp.status)
        var bytes = resp.body.take_bytes()
        if status < 200 or status >= 300:
            raise gcp_status_error(
                String("GET"), String(LIST_TIME_SERIES_RPC), status, bytes
            )
        return String(unsafe_from_utf8=Span(bytes))


def _resource_keys_named(q: MetricsQuery) -> List[String]:
    """The resource label names (without `resource.`) the query names."""
    var out = List[String]()
    var n = RESOURCE_LABEL_PREFIX.byte_length()
    for i in range(len(q.matchers)):
        if q.matchers[i].key.startswith(RESOURCE_LABEL_PREFIX):
            out.append(String(q.matchers[i].key[byte=n:]))
    for i in range(len(q.group_by)):
        if q.group_by[i].startswith(RESOURCE_LABEL_PREFIX):
            out.append(String(q.group_by[i][byte=n:]))
    return out^


def _series_of(s: MonitoringSeries, keep_resource: List[String]) -> MetricsSeriesData:
    var out = MetricsSeriesData.named(s.metric_type)
    for i in range(len(s.metric_labels)):
        out.labels.append(s.metric_labels[i].copy())
    for i in range(len(s.resource_labels)):
        for k in range(len(keep_resource)):
            if s.resource_labels[i].key == keep_resource[k]:
                out.labels.append(
                    MetricsLabel(
                        String(RESOURCE_LABEL_PREFIX) + s.resource_labels[i].key,
                        s.resource_labels[i].value.copy(),
                    )
                )
                break
    out.samples = s.points.copy()
    return out^


def _field(s: String) -> String:
    """`s` length-prefixed, so no label text can forge another's."""
    return String(s.byte_length()) + String(":") + s


def _labels_key(labels: List[MetricsLabel]) -> String:
    """`labels` sorted by key and length-prefixed, so the same labels in
    another wire order give the same key."""
    var order = List[Int]()
    for i in range(len(labels)):
        var at = len(order)
        while at > 0 and labels[order[at - 1]].key > labels[i].key:
            at -= 1
        order.insert(at, i)
    var k = String(len(labels))
    for i in range(len(order)):
        k += String("|") + _field(labels[order[i]].key)
        k += String("=") + _field(labels[order[i]].value)
    return k^


def _wire_identity(s: MonitoringSeries) -> String:
    """A key equal for two parts of ONE series: its metric type, every
    metric label, its resource type and every resource label. Two series
    that differ only in a label the query did not name (a revision, an
    instance) are different series and get different keys."""
    return (
        _field(s.metric_type)
        + String("#")
        + _labels_key(s.metric_labels)
        + String("#")
        + _field(s.resource_type)
        + String("#")
        + _labels_key(s.resource_labels)
    )


def _merge(a: List[MetricsSample], b: List[MetricsSample]) -> List[MetricsSample]:
    """Two oldest-first runs as one oldest-first run."""
    var out = List[MetricsSample]()
    var i = 0
    var j = 0
    while i < len(a) and j < len(b):
        if a[i].time_ns <= b[j].time_ns:
            out.append(a[i])
            i += 1
        else:
            out.append(b[j])
            j += 1
    while i < len(a):
        out.append(a[i])
        i += 1
    while j < len(b):
        out.append(b[j])
        j += 1
    return out^
