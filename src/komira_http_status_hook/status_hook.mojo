# =============================================================================
# src/komira_http_status_hook/status_hook.mojo — THE STATUS HOOK: the
#   one built-in `MetricsSink` that POSTs a request's two endpoints to a job
#   manager URL.
# =============================================================================
#
# A status hook in the middleware: given a job-manager URL, it sends each
# request's endpoints there.
#
# ⛔ THE HOOK COMPUTES NOTHING. It posts an instance identifier and the two
# timestamps `MetricsMiddleware` observed. No accumulation, no union, no
# duration, no allocation, no rate, no money. Every one of those is the job
# manager's, for a reason that is architectural and not stylistic: THIS CODE
# RUNS INSIDE EVERY DEPLOYED APPLICATION AND CANNOT BE CHANGED WITHOUT EACH OF
# THEM REDEPLOYING, while the job manager is one deploy. Accounting logic
# placed here could not be corrected after the fact.
#
# THE WIRE, WHICH IS A CONTRACT WITH THE JOB MANAGER
# --------------------------------------------------
#   POST {jm_url}/internal/usage
#   content-type: application/json
#   {"instance_id":"...","start_mono_ns":<u64>,"end_mono_ns":<u64>,
#    "method":"GET","path":"/x","status":200,"short_circuit":false}
#
# Hand-rolled JSON, deliberately: the point of an open-source middleware is that
# a stranger can reimplement it in Go or Python in an afternoon, and a
# hand-written object of seven scalar fields is a spec you can read.
#
# ⚠ `latency_ns` IS ABSENT FROM THAT BODY AND MUST STAY ABSENT. A scalar
# duration cannot be unioned; shipping one would force the server to SUM, which
# is correct for sequential traffic and over-counts by the concurrency factor
# for everything else. A test greps the captured wire bytes for it.
#
# ⚠ THE ENDPOINTS ARE MONOTONIC, SO `instance_id` MUST BE PER-PROCESS. See the
# `metrics.mojo` banner and `StatusHookConfig.build`.
#
# AUTH: `HookCredential`, NOT A SECOND MINTER
# -------------------------------------------
# The application that embeds this middleware typically already has a
# minter for an audience-scoped identity token (one that knows the audience
# must OMIT the default port, and RAISES rather than sending a request
# unauthenticated). It is NOT
# reachable from here when that package depends on `komira_http`, so
# importing it back would be a dependency cycle. Writing a second minter would
# be worse than the cycle — two implementations of a fail-closed auth rule
# disagree eventually, and the one in a customer binary is the one you cannot
# fix. So this file declares the SHAPE of that seam (`HookCredential.headers`,
# byte-for-byte the signature such a minter exposes) and the ~10-line adapter
# over the real minter is written at the APP layer, where both packages are
# visible and no cycle exists.
#
# POINTER DISCIPLINE: value semantics throughout. No UnsafePointer, no wildcard
# origins.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderEntry, HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_POST, HttpMethod
from komira_http_server.middleware.metrics import MetricsSink, RequestMetric
from komira_http_core.transport.io_stream import Connector


# =============================================================================
# §1 — The route, named once.
# =============================================================================

comptime USAGE_PATH: String = "/internal/usage"
"""The job-manager route this hook posts to, when the configured job-manager URL carries
no path of its own. Named as a constant so the server side can grep for it and
so a rename is one edit rather than a string scattered through a library nobody
can redeploy."""


# =============================================================================
# §2 — StatusHookConfig: REFUSES rather than defaults.
# =============================================================================


struct StatusHookConfig(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Where to post, as whom, and with what deadline.

    Built ONLY through `build()`, which parses and REFUSES. Every field is
    required; none has a read-site default. That is the library form of the
    standing rule that configuration is stated: a missing value must be REFUSED
    AT CONSTRUCTION, naming what is missing, rather than resolving to a
    plausible zero far from its cause.
    """

    var scheme: String
    var host: String
    var port: UInt16
    var path: String
    var instance_id: String
    var timeout_us: Int

    def __init__(
        out self,
        var scheme: String,
        var host: String,
        port: UInt16,
        var path: String,
        var instance_id: String,
        timeout_us: Int,
    ):
        self.scheme = scheme^
        self.host = host^
        self.port = port
        self.path = path^
        self.instance_id = instance_id^
        self.timeout_us = timeout_us

    @staticmethod
    def build(
        jm_url: String, instance_id: String, timeout_us: Int
    ) raises -> StatusHookConfig:
        """Parse `jm_url` and validate everything, or RAISE naming the problem.

        REFUSALS, each with its reason:

          * EMPTY `jm_url` — "not configured" and "configured to the empty
            string" are the same bytes to a reader that tolerates it. A hook
            pointed nowhere would post nowhere and report nothing, and the
            first anyone knew of it would be a zero on an invoice.
          * UNPARSEABLE `jm_url`, or one with no host — same, one step later.
          * EMPTY `instance_id` — the server unions intervals PER INSTANCE. An
            empty id collapses every instance in the fleet into one, which
            under-bills by exactly the instance count, silently.
          * `timeout_us <= 0` — ⛔ THE IMPORTANT ONE. This POST is synchronous
            on the serve thread (it must be; see `StatusHookSink.record`), so
            an unbounded deadline turns a wedged job manager into a wedged
            CUSTOMER REQUEST. Zero is exactly the value an author reaches for
            to mean "no opinion", and it is the one value that cannot be
            allowed to mean that here.

        `instance_id` MUST BE UNIQUE PER PROCESS, not merely per container or
        revision: the timestamps posted alongside it are MONOTONIC readings,
        which are comparable only within one process. Two processes sharing an
        id would have their incomparable clocks unioned together. A restart is
        a new process and must carry a new id.

        The path: if `jm_url` carries a path of its own (anything other than
        `/`), it is used VERBATIM — so an operator can front the job manager
        with a prefix-routing proxy. Otherwise `USAGE_PATH` is appended.
        """
        if jm_url.byte_length() == 0:
            raise Error(
                "status hook: jm_url is empty. The hook must be given the job"
                " manager's URL explicitly; there is no default and an unset"
                " URL is not a silent disable (construct no hook for that)."
            )
        if instance_id.byte_length() == 0:
            raise Error(
                "status hook: instance_id is empty. The server unions request"
                " intervals PER INSTANCE and the posted timestamps are"
                " monotonic, so the id must be unique per PROCESS."
            )
        if timeout_us <= 0:
            raise Error(
                String(
                    "status hook: timeout_us must be > 0 (got "
                )
                + String(timeout_us)
                + String(
                    "). The POST is synchronous on the serve thread, so an"
                    " unbounded deadline makes a wedged job manager wedge the"
                    " customer's request."
                )
            )
        var url = Url.parse(jm_url)
        if url.host.byte_length() == 0:
            raise Error(
                String("status hook: jm_url has no host: ") + jm_url
            )
        var scheme = String(url.scheme)
        if scheme.byte_length() == 0:
            scheme = String("http")
        var port = url.port
        if port == UInt16(0):
            if scheme == String("https"):
                port = UInt16(443)
            else:
                port = UInt16(80)
        var path = String(url.path)
        if path.byte_length() == 0 or path == String("/"):
            path = String(USAGE_PATH)
        return StatusHookConfig(
            scheme=scheme^,
            host=String(url.host),
            port=port,
            path=path^,
            instance_id=String(instance_id),
            timeout_us=timeout_us,
        )


# =============================================================================
# §3 — HookCredential: the auth seam, shaped like the one that already exists.
# =============================================================================


trait HookCredential(Movable, Deinitable):
    """Produces the auth headers for one usage POST, or RAISES.

    ⚠ THE SIGNATURE IS DELIBERATELY `jm_auth.jm_auth_headers`' SIGNATURE. The
    GCP conformer is then a ~10-line adapter over the EXISTING
    `jm_audience()` + `GcpMetadataMinter`, written at the app layer (which sees
    both `komira_agent` and `komira_http`; this package cannot, because
    `komira_agent` depends on it). Nothing here re-implements a token minter.

    `scheme`/`host`/`port` are passed so a conformer can derive the audience
    itself — including the rule that the audience must OMIT the default port,
    which a token minted for `https://host:443` violates and the Google Frontend
    rejects. `method`/`path`/`body` are passed because AWS SigV4 signs exactly
    those; taking them now is what lets an AWS arm land without reshaping the
    caller.

    ⛔ A MINT FAILURE MUST RAISE, NOT RETURN AN EMPTY LIST. Degrading to a
    bearer-less POST is the fail-open path: the request would then be rejected
    at the ingress edge and reported as an ordinary transport failure, making
    "this image cannot authenticate" indistinguishable from "the network
    blipped". `StatusHookSink.record` catches the raise BEFORE any bytes are
    written, so a mint failure sends nothing at all.
    """

    def headers(
        mut self,
        scheme: String,
        host: String,
        port: UInt16,
        method: String,
        path: String,
        body: List[UInt8],
    ) raises -> List[HeaderEntry]:
        ...


struct NoCredential(HookCredential, Movable, Deinitable):
    """No auth headers — for an in-cluster plaintext job manager that
    authenticates by network position. Byte-identical on the wire to a POST
    with no credential, because that is what it is."""

    def __init__(out self):
        pass

    def headers(
        mut self,
        scheme: String,
        host: String,
        port: UInt16,
        method: String,
        path: String,
        body: List[UInt8],
    ) raises -> List[HeaderEntry]:
        _ = scheme
        _ = host
        _ = port
        _ = method
        _ = path
        _ = len(body)
        return List[HeaderEntry]()


# =============================================================================
# §4 — The body renderer. Seven scalar fields, hand-rolled.
# =============================================================================


def _json_escape(s: String) -> String:
    """Escape a String for a JSON double-quoted scalar. Handles the two
    structural characters and the C0 range; everything else is passed through as
    UTF-8 bytes, which is legal JSON."""
    var out = String()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var b = bs[i]
        if b == UInt8(ord('"')):
            out += String('\\"')
        elif b == UInt8(ord("\\")):
            out += String("\\\\")
        elif b == UInt8(ord("\n")):
            out += String("\\n")
        elif b == UInt8(ord("\r")):
            out += String("\\r")
        elif b == UInt8(ord("\t")):
            out += String("\\t")
        elif b < UInt8(0x20):
            # Remaining C0 controls: \u00XX.
            var hi = Int(b) // 16
            var lo = Int(b) % 16
            out += String("\\u00")
            out += String("0123456789abcdef"[byte=hi])
            out += String("0123456789abcdef"[byte=lo])
        else:
            out += String(chr(Int(b)))
    return out^


def render_usage_body(
    instance_id: String, ref m: RequestMetric
) -> List[UInt8]:
    """The usage POST body for one request.

    ⛔ SEVEN FIELDS, AND NOT ONE OF THEM IS DERIVED. `start_mono_ns` and
    `end_mono_ns` are the two endpoints verbatim; there is no duration, no
    total, no count and no allocation here, and there must never be. The server
    unions the intervals; this function's whole job is to not lose the
    information that makes a union possible.

    `method`/`path`/`status`/`short_circuit` ride along as DIMENSIONS — they let
    the server attribute usage without changing what is billed. `span_id` and
    `latency_ns` are deliberately omitted: the first is a tracing concern and
    the second is the un-unionable scalar this whole design exists to avoid
    putting on the wire.
    """
    var s = String("{")
    s += String('"instance_id":"') + _json_escape(instance_id) + String('",')
    s += String('"start_mono_ns":') + String(m.start_mono_ns) + String(",")
    s += String('"end_mono_ns":') + String(m.end_mono_ns) + String(",")
    s += String('"method":"') + _json_escape(m.entry.method.name()) + String(
        '",'
    )
    s += String('"path":"') + _json_escape(m.entry.path) + String('",')
    s += String('"status":') + String(Int(m.entry.status)) + String(",")
    if m.entry.short_circuit:
        s += String('"short_circuit":true')
    else:
        s += String('"short_circuit":false')
    s += String("}")
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


# =============================================================================
# §5 — StatusHookSink.
# =============================================================================


struct StatusHookSink[C: Connector, K: HookCredential](
    MetricsSink, Movable, Deinitable
):
    """POSTs each request's two endpoints to the job manager, synchronously.

        var cfg = StatusHookConfig.build(jm_url, instance_id, 250_000)
        var sink = StatusHookSink[KernelTcpConnector, MyGcpCredential].new(
            cfg, KernelTcpConnector.new(), MyGcpCredential(...)
        )
        var mw = MetricsMiddleware[
            StatusHookSink[KernelTcpConnector, MyGcpCredential]
        ].new(sink^)

    ⛔ SYNCHRONOUS, AND THAT IS THE REQUIREMENT, NOT A SHORTCUT. The POST
    completes before `MetricsMiddleware.after` returns, and the transport
    serializes and writes the response only after the whole after-phase returns
    — so the hook has landed before the customer's response leaves the process.
    On a serverless platform this is the only ordering that works: the CPU is
    withdrawn when the response completes, there is no guaranteed next request
    to carry a buffered observation, and a background timer does not tick.

    THE COST, STATED SO NOBODY REDISCOVERS IT IN A LATENCY GRAPH: one round trip
    is added to every request, on the serve thread. It is bounded by the
    REQUIRED `timeout_us` (which is why zero is refused) and clamped further by
    the client's own containing-deadline budget. Configure it deliberately —
    a couple of hundred milliseconds — and measure before putting it on a hot
    path.

    FAILURE POLICY — a failed POST costs ONE LOST INTERVAL and nothing else.
    Every failure mode (mint raise, connect refused, connect never resolves,
    timeout, non-2xx) is caught here; `record` never raises out, and
    `MetricsMiddleware.after` catches anything that somehow did. A lost interval
    UNDER-reports usage, i.e. it errs in the customer's favour and never in
    ours. `last_record_failed()` / `last_error()` expose the most recent
    outcome for a customer's own health endpoint — one bit and one string, NOT
    counters: this file keeps no running totals of anything.
    """

    var _cfg: StatusHookConfig
    var _client: HttpClient[Self.C]
    var _cred: Self.K
    var _last_record_failed: Bool
    var _last_error: String

    def __init__(
        out self,
        var cfg: StatusHookConfig,
        var connector: Self.C,
        var cred: Self.K,
    ):
        self._client = HttpClient[Self.C].with_request_timeout_us(
            connector^, cfg.timeout_us
        )
        self._cfg = cfg^
        self._cred = cred^
        self._last_record_failed = False
        self._last_error = String()

    @staticmethod
    def new(
        var cfg: StatusHookConfig, var connector: Self.C, var cred: Self.K
    ) -> StatusHookSink[Self.C, Self.K]:
        return StatusHookSink[Self.C, Self.K](cfg^, connector^, cred^)

    def record(mut self, ref m: RequestMetric) raises:
        """POST this request's endpoints. NEVER raises out — see the failure
        policy on the struct."""
        try:
            self._post(m)
            self._last_record_failed = False
            self._last_error = String()
        except e:
            self._last_record_failed = True
            self._last_error = String(e)

    def _post(mut self, ref m: RequestMetric) raises:
        """The POST itself. Raises on every failure mode; `record` is the only
        caller and it catches."""
        var body = render_usage_body(self._cfg.instance_id, m)
        # ⛔ CREDENTIAL FIRST, BYTES SECOND. A mint failure must raise HERE,
        # before a single byte is written, so that "cannot authenticate" never
        # degrades into an unauthenticated POST.
        var extra = self._cred.headers(
            self._cfg.scheme,
            self._cfg.host,
            self._cfg.port,
            String("POST"),
            self._cfg.path,
            body,
        )
        var headers = HeaderMap()
        headers.append(String("content-type"), String("application/json"))
        for i in range(len(extra)):
            headers.append(String(extra[i].name), String(extra[i].value))
        var url = Url(
            scheme=String(self._cfg.scheme),
            host=String(self._cfg.host),
            port=self._cfg.port,
            path=String(self._cfg.path),
        )
        var req = build_request_with_body[BytesBody](
            HttpMethod(code=HTTP_METHOD_POST),
            url^,
            headers^,
            BytesBody.from_bytes(body^),
        )
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = self._client.send_buffered[
            BlockingRuntime[NoopSink], BytesBody
        ](req^, reactor)
        var status = Int(cr.status)
        if status < 200 or status >= 300:
            raise Error(
                String("status hook: usage POST failed: HTTP ")
                + String(status)
            )

    def last_record_failed(self) -> Bool:
        """True iff the most recent `record` did not land. One bit, not a
        counter."""
        return self._last_record_failed

    def last_error(self) -> String:
        """The most recent failure's detail, or empty. Never carries a
        credential: the credential seam returns headers this file forwards
        without inspecting, and no header value is ever put in an error."""
        return self._last_error

    def config(self) -> StatusHookConfig:
        return self._cfg
