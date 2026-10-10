# komira_gcp_core

The hand-written core beneath komira's generated Google Cloud clients
(`komira_gcp_<service>`). It defines no request type and no send loop for a
service; it holds what every client shares:

- **Tokens.** `GcpTokenSource` (the contract each generated client takes),
  `StaticTokenSource`, and `CachingTokenSource`, which serves a fetcher's
  token until `refresh_before_ms` before it expires, on a komira_retry
  `MonotonicClock`. `AccessToken` has no string conversion: a token is never
  printed.
- **Application Default Credentials.** `resolve_adc` searches Google's order
  (`GOOGLE_APPLICATION_CREDENTIALS`, gcloud's well-known file, the metadata
  server) over injected environment, file and transport seams;
  `application_default_token_source` returns a `CachingTokenSource` over the
  fetcher it chose (metadata server, service-account key, self-signed JWT,
  authorized_user). Workload identity federation's `external_account` files
  are refused by name.
- **Errors.** `parse_gcp_status` and `gcp_status_error` turn a non-2xx answer
  into an error naming the verb, the method, the HTTP status and the
  canonical `google.rpc.Code`, counting bytes and never quoting the body;
  `gcp_status_error_code` reads the code back. gRPC statuses have the same
  pair (`gcp_grpc_status_error`, `gcp_grpc_error_code`).
- **Paging and retry.** `next_page_token`, `with_page_token` and `PageCursor`
  (AIP-158); `GcpRetryClassifier` (AIP-194's retryable codes, with
  `google.rpc.RetryInfo` as the server's delay) and `gcp_retry_policy`
  (AIP-4221 backoff) for a komira_retry loop.
- **Cloud Storage V4 signed URLs** (`gcs_v4_signed_url` and its canonical
  request and string to sign), with the signing time a parameter.

Only `sources.mojo` (`ProcessEnv`) reads the process environment, and only
the variables Google's auth libraries read. The only connections the package
opens are the token fetches, over the connectors its caller gives.

## Examples

An error answer becomes an error that names the code and counts bytes. Here
the server asks for a retry after 1.5 s, which the classifier honours; a
NOT_FOUND is not retried:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_gcp_core import CODE_NOT_FOUND, CODE_UNAVAILABLE, GcpRetryClassifier, gcp_status_error_code, parse_gcp_status

def body_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^

var busy = parse_gcp_status(
    "POST",
    "Commit",
    503,
    body_bytes(
        '{"error":{"code":503,"message":"try later","status":"UNAVAILABLE","details":['
        + '{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"1.5s"}]}}'
    ),
)
assert_equal(busy.code(), CODE_UNAVAILABLE)
assert_equal(busy.retry_delay_ms, 1500)
var text = busy.message()
assert_true(text.startswith("POST Commit: HTTP 503, UNAVAILABLE (code 14)"))
assert_false("try later" in text)
assert_equal(gcp_status_error_code("POST", "Commit", text), CODE_UNAVAILABLE)

var classifier = GcpRetryClassifier()
var verdict = classifier.classify(busy)
assert_true(verdict.retryable)
assert_equal(verdict.server_delay_ms, 1500)

var missing = parse_gcp_status(
    "GET", "GetDocument", 404, body_bytes('{"error":{"code":404,"status":"NOT_FOUND"}}')
)
assert_equal(missing.code(), CODE_NOT_FOUND)
assert_false(classifier.classify(missing).retryable)
```

Paging a List method: `with_page_token` adds the token to the next URL,
`next_page_token` reads it off a page, and `PageCursor` stops at the last
page (and refuses a server that hands back the token it was sent):

<!-- mojo-hidden
from std.testing import assert_equal, assert_true

def body_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^
-->
```mojo
from komira_gcp_core import PageCursor, next_page_token, with_page_token

var pages = List[String]()
pages.append('{"items":[1,2],"nextPageToken":"p/2"}')
pages.append('{"items":[3]}')
var cursor = PageCursor()
var urls = List[String]()
while not cursor.done():
    urls.append(with_page_token("/v1/things?pageSize=2", cursor.page_token()))
    cursor.advance(next_page_token(body_bytes(pages[cursor.pages()])))
assert_equal(cursor.pages(), 2)
assert_equal(urls[0], "/v1/things?pageSize=2")
assert_equal(urls[1], "/v1/things?pageSize=2&pageToken=p%2F2")

var stuck = PageCursor()
stuck.advance("t1")
var refused = False
try:
    stuck.advance("t1")
except:
    refused = True
assert_true(refused)
```

A `CachingTokenSource` fetches once, serves the cached token while it is
fresh, and fetches again once the clock is inside the refresh margin.
`ManualClock` is komira_retry's test clock; a real program passes its
`SystemClock` and one of this package's fetchers:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo module
from komira_gcp_core import AccessToken, AccessTokenFetcher, CachingTokenSource, GcpTokenSource
from komira_retry import ManualClock


struct NumberedFetcher(AccessTokenFetcher, Movable, Deinitable):
    """Issues token-1, token-2, ..., each valid for one hour."""
    var issued: Int

    def __init__(out self):
        self.issued = 0

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        self.issued += 1
        return AccessToken.expiring_in(String("token-") + String(self.issued), now_ms, 3600)


def main() raises:
    var source = CachingTokenSource[NumberedFetcher, ManualClock](
        NumberedFetcher(), ManualClock(0), refresh_before_ms=60_000
    )
    assert_equal(source.access_token(), "token-1")
    source.clock().advance(3_000_000)  # 50 minutes: still fresh
    assert_equal(source.access_token(), "token-1")
    source.clock().advance(540_000)  # 59 minutes: inside the one-minute margin
    assert_equal(source.access_token(), "token-2")
    assert_equal(source.fetches(), 2)
```

Application Default Credentials over in-memory seams: `MapEnv` records every
variable read, `MapFiles` holds the files, and the probe transport would
only be asked if no file were found. Here gcloud's well-known file under
`HOME` holds an `authorized_user` credential; with neither file nor metadata
server, the search fails with Google's own text:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo module
from komira_gcp_core import ADC_KIND_AUTHORIZED_USER, ADC_NOT_FOUND, ADC_SOURCE_GCLOUD_FILE, AdcOptions, GcpHttpTransport, MapEnv, MapFiles, TokenHttpRequest, TokenHttpResponse, resolve_adc


struct NoMetadataServer(GcpHttpTransport, Movable, Deinitable):
    var asked: Int

    def __init__(out self):
        self.asked = 0

    def send(mut self, req: TokenHttpRequest) raises -> TokenHttpResponse:
        self.asked += 1
        raise Error("HttpError[CONNECT_FAILED]: no route")


def main() raises:
    var env = MapEnv()
    env.set("HOME", "/var/lib/app")
    var files = MapFiles()
    files.put(
        "/var/lib/app/.config/gcloud/application_default_credentials.json",
        '{"type":"authorized_user","client_id":"cid","client_secret":"s","refresh_token":"r"}',
    )
    var probe = NoMetadataServer()
    var found = resolve_adc(env, files, probe, AdcOptions())
    assert_equal(found.source, ADC_SOURCE_GCLOUD_FILE)
    assert_equal(found.kind, ADC_KIND_AUTHORIZED_USER)
    assert_equal(found.origin, "/var/lib/app/.config/gcloud/application_default_credentials.json")
    assert_equal(found.user.value().client_id, "cid")
    assert_equal(probe.asked, 0)
    assert_equal(env.reads[0], "GOOGLE_APPLICATION_CREDENTIALS")

    var empty_env = MapEnv()
    var no_files = MapFiles()
    var raised = String()
    try:
        _ = resolve_adc(empty_env, no_files, probe, AdcOptions())
    except e:
        raised = String(e)
    assert_equal(raised, String(ADC_NOT_FOUND))
```
