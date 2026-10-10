# komira_metrics_reader

Read a service's metrics back, wherever they are kept. The package holds the
seam and the HTTP route, not a store:

- `MetricsQuery` (a window in nanoseconds, a metric, label matchers, an
  aggregation over steps, group-by keys, a series limit and a point limit)
  and the answer, `MetricsPage` of `MetricsSeriesData` (labels and
  `MetricsSample`s, oldest first, with a `truncated` flag and a count of the
  sources read).
- `MetricsReader`, the trait a reader conforms to: `refusal(query)` names a
  question the store cannot answer (an empty string means it can), and
  `read(query)` answers it. `ErasedMetricsReader` is the non-generic facade a
  service holds as one field; `ScriptedMetricsReader` is the scripted double.
- `metrics_response`, the `GET <path>` route: an access hook
  (`MetricsReadAccess`; `DenyMetricsReads`, or `MetricsHeaderTokenAccess`
  for a shared token in a header), then the argument checks, the reader's
  refusal, the read, and a JSON body. A refused caller, a raising hook and an
  unwired reader all get the same 404; a bad argument is a 400 naming it,
  never a silent default; a read that raises is a 500.

No reader ships here (the CloudWatch and Cloud Monitoring readers are packages
of their own) and nothing here opens a socket: the service supplies the mount
path, the access hook, the reader and the current time.

## Examples

Answer a request over the scripted reader, and see what the reader was asked:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_http_core.codec.types import HttpMethod, HttpRequest
from komira_metrics_reader import ErasedMetricsReader, MetricsHeaderTokenAccess
from komira_metrics_reader import MetricsLabel, MetricsPage, MetricsSample
from komira_metrics_reader import MetricsSeriesData, ScriptedMetricsReader
from komira_metrics_reader import is_metrics_request, metrics_response

var reader = ScriptedMetricsReader()
var series = MetricsSeriesData.named("requests")
series.labels.append(MetricsLabel("code", "200"))
series.samples.append(MetricsSample(Int64(60_000_000_000), 1.5))
var answer = List[MetricsSeriesData]()
answer.append(series^)
reader.answer(MetricsPage(answer^, False, 1))

var req = HttpRequest(HttpMethod.get(), "/metrics/read")
req.query_string = "metric=requests&since_ms=0&until_ms=60000&step_ms=60000&agg=sum&label.code=200"
req.headers["x-read-token"] = "s3cret-token"
assert_true(is_metrics_request(req, "/metrics/read"))

var access = MetricsHeaderTokenAccess("x-read-token", "s3cret-token")
var wired = Optional(ErasedMetricsReader.erase(reader.share()))
var now_ns = Int64(4_000_000_000_000_000_000)
var resp = metrics_response(wired, req, access, now_ns)
assert_equal(resp.status, 200)
assert_equal(
    String(unsafe_from_utf8=Span(resp.body)),
    '{"metric":"requests","agg":"sum","since_ms":0,"until_ms":60000,'
    + '"step_ms":60000,"series_limit":100,"point_limit":1440,'
    + '"returned":1,"truncated":false,"scanned":1,"series":['
    + '{"metric":"requests","labels":{"code":"200"},"samples":[[60000000000,1.5]]}]}',
)

var asked = reader.last_query()
assert_equal(asked.aggregation.name(), "sum")
assert_equal(asked.matchers[0].key, "code")
assert_equal(asked.matchers[0].value, "200")
```

A wrong token is the same 404 as no route at all, and the reader is never
asked; a reader's refusal is a 400 carrying its sentence:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_http_core.codec.types import HttpMethod, HttpRequest
from komira_metrics_reader import ErasedMetricsReader, MetricsHeaderTokenAccess
from komira_metrics_reader import ScriptedMetricsReader, metrics_response

var reader = ScriptedMetricsReader()
var access = MetricsHeaderTokenAccess("x-read-token", "s3cret-token")
var now_ns = Int64(4_000_000_000_000_000_000)

var wrong = HttpRequest(HttpMethod.get(), "/metrics/read")
wrong.query_string = "metric=requests"
wrong.headers["x-read-token"] = "guess"
var wired = Optional(ErasedMetricsReader.erase(reader.share()))
var denied = metrics_response(wired, wrong, access, now_ns)
assert_equal(denied.status, 404)
assert_equal(String(unsafe_from_utf8=Span(denied.body)), '{"error":"not found"}')
assert_equal(reader.read_count(), 0)

reader.refuse("this store cannot group by a label")
var req = HttpRequest(HttpMethod.get(), "/metrics/read")
req.query_string = "metric=requests&group_by=code"
req.headers["x-read-token"] = "s3cret-token"
var wired2 = Optional(ErasedMetricsReader.erase(reader.share()))
var refused = metrics_response(wired2, req, access, now_ns)
assert_equal(refused.status, 400)
assert_equal(
    String(unsafe_from_utf8=Span(refused.body)),
    '{"error":"this metrics reader cannot answer: this store cannot group by a label"}',
)
assert_equal(reader.read_count(), 0)
```
