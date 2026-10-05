# =============================================================================
# komira_localmodel/control_api.mojo
#   ControlApiDispatcher: the loopback CONTROL API. A komira_http_server
#   `RequestDispatcher` that exposes the lifecycle verbs (list / select /
#   stop / status) PLUS the OpenAI `/v1` passthrough: the client hits ONE local
#   endpoint and the state machine loads the named model on demand.
# =============================================================================
#
# THE ROUTES (a client depends on these; tests pin them):
#   GET  /v1/models                  -> the OpenAI model-list shape: every
#                                       registered model as an OpenAI model
#                                       object {id, object:"model", owned_by}.
#   GET  /models                      -> the RICH list: every model with its
#                                       lifecycle state, fit green/yellow/red
#                                       and admission counters.
#   GET  /status?id=<id>              -> one model's full status snapshot.
#   POST /select   {"id": "<id>"}     -> load the model (REGISTERED -> SERVING),
#                                       evicting the LRU if needed;
#                                       200 {state, base_url} or an error that
#                                       names the failure.
#   POST /stop     {"id": "<id>"}     -> unload the model (-> REGISTERED).
#   POST /v1/...   {..., "model": "<id>"}
#                                     -> the PASSTHROUGH: load the named model,
#                                       forward the body to the same path on its
#                                       OpenAI endpoint, return the response.
#   anything else                     -> 404.
#
# THE FORWARDER SEAM `[F: OpenAiForwarder]`: the `/v1` passthrough forwards the
# request body to the loaded backend's OpenAI endpoint through an
# `OpenAiForwarder` trait DEFINED HERE (the same layering as `LocalBackend`:
# this package depends on no HTTP client). A real forwarder wraps an HTTP
# client; the tests bind a STUB forwarder that records the (base_url, path) it
# was handed and returns a canned response, so the passthrough route is
# testable with no live engine.
#
# LOOPBACK ONLY: the server hosting this dispatcher should bind 127.0.0.1
# (HttpServerConfig.default_ephemeral() binds the loopback address). The
# dispatcher does not authenticate: the loopback interface is the trust
# boundary. Exposing it beyond loopback would need authentication in front of
# it.
#
# POINTERS: the dispatcher OWNS the BackendSupervisor[B, C] and the forwarder F
# by value; dispatch takes the request by value (moved) and returns the
# response by value; the reactor is a `mut` borrow passed per call (never
# stored). No pointer in any public signature, no wildcard origin. `[B, C, F]`
# and `RT` are comptime parameters.
# =============================================================================

from std.ffi import external_call

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher

from .backend_state_machine import (
    BackendSupervisor,
    LocalBackend,
    MonotonicClock,
    ModelStatus,
    LM_SERVING,
    LM_FAILED,
    ADMIT_ADMITTED,
    ADMIT_QUEUED,
    ADMIT_REJECTED,
    model_state_name,
    failure_reason_text,
)
from .fit_resolver import (
    FitResult,
    fit_rating_name,
)


# -----------------------------------------------------------------------------
# OpenAiForwarder — the `/v1` passthrough seam. One method: take the loaded
# model's base_url, the request path and the wire-ready request body, return
# the upstream response (status, content type, body). A real forwarder wraps an
# HTTP client; a test binds a stub that records what it was handed.
# -----------------------------------------------------------------------------
struct ForwardedResponse(Movable):
    """The engine's answer to a forwarded `/v1` request, returned to the client
    as it is: the upstream status (a 4xx or 5xx stays a 4xx or 5xx), its
    content type (`text/event-stream` for a streaming request) and its body
    bytes. The body is buffered: a streaming response reaches the client in
    one piece once the engine has finished it."""

    var status: Int
    var content_type: String
    var body: List[UInt8]

    def __init__(out self, status: Int, content_type: String, var body: List[UInt8]):
        self.status = status
        self.content_type = content_type
        self.body = body^

    @staticmethod
    def json(status: Int, body: String) -> ForwardedResponse:
        """A response with an `application/json` body (a convenience for
        forwarders and tests)."""
        var bytes = List[UInt8]()
        var b = body.as_bytes()
        for i in range(len(b)):
            bytes.append(b[i])
        return ForwardedResponse(status, String("application/json"), bytes^)


trait OpenAiForwarder(Movable, Deinitable):
    """Forward an OpenAI request body to a loaded backend's `/v1` endpoint.

    `forward(base_url, path, request_body)` POSTs `request_body` to
    `<base_url><path>` and returns the upstream response. Raises on a
    transport error (the dispatcher maps it to a 502); an HTTP error status
    from the engine is a normal return, passed through to the client."""

    def forward(
        mut self, base_url: String, path: String, request_body: String
    ) raises -> ForwardedResponse:
        ...


# -----------------------------------------------------------------------------
# Control API route paths.
# -----------------------------------------------------------------------------
comptime ROUTE_V1_MODELS: String = "/v1/models"
comptime ROUTE_MODELS: String = "/models"
comptime ROUTE_STATUS: String = "/status"
comptime ROUTE_SELECT: String = "/select"
comptime ROUTE_STOP: String = "/stop"
comptime ROUTE_V1_PREFIX: String = "/v1/"

# The bounded spin budget a QUEUED /v1 request waits for a freed in-flight slot
# before giving up with a 503 (block-and-wait admission). Between turns
# the worker yields the core (`_sched_yield`), so this is a cooperative wait, not
# a hot busy-loop — the engine round-trips run on the OTHER workers in the
# meantime and free slots. The budget bounds a stuck/overloaded engine so a queued
# request cannot pin a worker forever. Sized generously: an engine round-trip is
# ~hundreds of ms to seconds, and each yield is a scheduler quantum (~tens of µs),
# so this tolerates a multi-second queue wait before rejecting.
comptime _ADMIT_WAIT_MAX_SPINS: Int = 5_000_000


@always_inline
def _sched_yield():
    """Yield the worker thread (sched_yield) so a QUEUED-and-spinning worker does
    not burn the core while it waits for an in-flight slot to free on another
    worker. Cooperative-wait primitive for the block-and-wait admission spin."""
    _ = external_call["sched_yield", Int32]()


# =============================================================================
# JSON rendering helpers (small, dependency-free string builders — the control
# API bodies are tiny + flat, so a hand-rolled emitter avoids a json dep).
# =============================================================================


def _string_of_bytes(bytes: List[UInt8]) -> String:
    """A String holding `bytes` unchanged. Every caller passes bytes cut out of
    valid UTF-8 at ASCII delimiters (or validated with `_is_valid_utf8`), so
    the result is valid UTF-8."""
    return String(unsafe_from_utf8=Span(bytes))


def _is_valid_utf8(data: List[UInt8]) -> Bool:
    """Strict UTF-8 validation: overlong encodings, surrogate halves and code
    points above U+10FFFF are rejected."""
    var i = 0
    var n = len(data)
    while i < n:
        var b0 = Int(data[i])
        if b0 < 0x80:
            i += 1
            continue
        var need: Int
        var cp: Int
        if b0 >= 0xC2 and b0 <= 0xDF:
            need = 1
            cp = b0 & 0x1F
        elif b0 >= 0xE0 and b0 <= 0xEF:
            need = 2
            cp = b0 & 0x0F
        elif b0 >= 0xF0 and b0 <= 0xF4:
            need = 3
            cp = b0 & 0x07
        else:
            return False
        if i + need >= n:
            return False
        for k in range(1, need + 1):
            var bk = Int(data[i + k])
            if bk < 0x80 or bk > 0xBF:
                return False
            cp = (cp << 6) | (bk & 0x3F)
        if need == 2 and cp < 0x800:
            return False
        if need == 3 and cp < 0x10000:
            return False
        if cp >= 0xD800 and cp <= 0xDFFF:
            return False
        if cp > 0x10FFFF:
            return False
        i += need + 1
    return True


comptime _HEX_DIGITS: String = "0123456789abcdef"


def _json_escape(s: String) -> String:
    """JSON string escaping: quote, backslash and every control character
    below 0x20 (as `\\u00XX`, or the short form for \\n, \\r, \\t). Other bytes,
    including multi-byte UTF-8, are copied unchanged."""
    var out = List[UInt8]()
    var bytes = s.as_bytes()
    var hex = _HEX_DIGITS.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(ord('"')) or c == UInt8(ord("\\")):
            out.append(UInt8(ord("\\")))
            out.append(c)
        elif c == UInt8(ord("\n")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("n")))
        elif c == UInt8(ord("\r")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("r")))
        elif c == UInt8(ord("\t")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("t")))
        elif c < UInt8(0x20):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("u")))
            out.append(UInt8(ord("0")))
            out.append(UInt8(ord("0")))
            out.append(hex[Int(c) >> 4])
            out.append(hex[Int(c) & 0xF])
        else:
            out.append(c)
    return _string_of_bytes(out)


def _model_status_json(st: ModelStatus, var fit_rating: String) -> String:
    """Render one ModelStatus (including its admission snapshot: the per-model
    concurrency cap and the in-flight / queued counts) and its fit rating as a
    flat JSON object."""
    var o = String("{")
    o += String('"id":"') + _json_escape(st.id) + String('",')
    o += String('"state":"') + model_state_name(st.state) + String('",')
    o += String('"fit":"') + fit_rating + String('",')
    o += String('"resident_bytes":') + String(st.resident_bytes) + String(",")
    o += String('"max_concurrent":') + String(st.max_concurrent) + String(",")
    o += String('"inflight":') + String(st.inflight) + String(",")
    o += String('"queued":') + String(st.queued) + String(",")
    o += String('"base_url":"') + _json_escape(st.base_url) + String('"')
    if st.state == LM_FAILED:
        o += String(',"failure":"')
        o += _json_escape(failure_reason_text(st.failure_reason))
        o += String('"')
        if st.failure_detail.byte_length() > 0:
            o += String(',"failure_detail":"')
            o += _json_escape(st.failure_detail)
            o += String('"')
    o += String("}")
    return o^


def _query_param(query_string: String, key: String) -> String:
    """Extract a single query param value (e.g. `id` from `id=foo&x=1`). Flat
    parse — no URL-decoding (the ids here are plain). Empty if absent. The
    value's bytes are copied unchanged."""
    var prefix = key + String("=")
    var qb = query_string.as_bytes()
    var pb = prefix.as_bytes()
    var n = len(qb)
    var pn = len(pb)
    var i = 0
    while i + pn <= n:
        var matched = True
        var j = 0
        while j < pn:
            if qb[i + j] != pb[j]:
                matched = False
                break
            j += 1
        # Match only at the start or right after a '&'.
        var at_boundary = (i == 0) or (qb[i - 1] == UInt8(ord("&")))
        if matched and at_boundary:
            var out = List[UInt8]()
            var k = i + pn
            while k < n and qb[k] != UInt8(ord("&")):
                out.append(qb[k])
                k += 1
            return _string_of_bytes(out)
        i += 1
    return String("")


def _is_json_ws(c: UInt8) -> Bool:
    return (
        c == UInt8(ord(" "))
        or c == UInt8(ord("\t"))
        or c == UInt8(ord("\n"))
        or c == UInt8(ord("\r"))
    )


def _skip_json_string(bb: Span[UInt8, _], start: Int) -> Int:
    """`start` is the index just past an opening quote; returns the index of
    the matching closing quote (escapes skipped), or len(bb) if there is none."""
    var k = start
    var n = len(bb)
    while k < n:
        if bb[k] == UInt8(ord("\\")):
            k += 2
            continue
        if bb[k] == UInt8(ord('"')):
            return k
        k += 1
    return n


def _top_level_string_field(body: String, field: String) -> String:
    """The value of the string member `field` of the top-level JSON object in
    `body` (e.g. `"model"` in an OpenAI request). Only a key of the outermost
    object counts: the same text inside a nested object, an array or a string
    value is skipped. Empty when the member is absent, is not a string, or its
    value contains an escape sequence (model ids are plain). The value's bytes
    are copied unchanged."""
    var bb = body.as_bytes()
    var fb = field.as_bytes()
    var n = len(bb)
    var depth = 0
    # True when the next string at depth 1 is a key (after '{' or ',').
    var expect_key = False
    var i = 0
    while i < n:
        var c = bb[i]
        if c == UInt8(ord('"')):
            var close = _skip_json_string(bb, i + 1)
            if close >= n:
                return String("")
            if depth == 1 and expect_key:
                expect_key = False
                var is_field = (close - (i + 1)) == len(fb)
                if is_field:
                    for j in range(len(fb)):
                        if bb[i + 1 + j] != fb[j]:
                            is_field = False
                            break
                # Skip to the ':' and the value.
                var k = close + 1
                while k < n and _is_json_ws(bb[k]):
                    k += 1
                if k >= n or bb[k] != UInt8(ord(":")):
                    return String("")
                k += 1
                while k < n and _is_json_ws(bb[k]):
                    k += 1
                if is_field:
                    if k >= n or bb[k] != UInt8(ord('"')):
                        return String("")
                    var vend = _skip_json_string(bb, k + 1)
                    if vend >= n:
                        return String("")
                    var out = List[UInt8]()
                    for m in range(k + 1, vend):
                        if bb[m] == UInt8(ord("\\")):
                            return String("")
                        out.append(bb[m])
                    return _string_of_bytes(out)
                i = k
                continue
            i = close + 1
            continue
        if c == UInt8(ord("{")) or c == UInt8(ord("[")):
            depth += 1
            expect_key = depth == 1 and c == UInt8(ord("{"))
        elif c == UInt8(ord("}")) or c == UInt8(ord("]")):
            depth -= 1
        elif c == UInt8(ord(",")) and depth == 1:
            expect_key = True
        i += 1
    return String("")


# =============================================================================
# Response builders.
# =============================================================================


def _json_200(var body_str: String) -> HttpResponse:
    var r = HttpResponse(status=Int32(200))
    var bytes = body_str.as_bytes()
    var n = len(bytes)
    for i in range(n):
        r.body.append(bytes[i])
    r.headers[String("content-type")] = String("application/json")
    r.headers[String("content-length")] = String(n)
    return r^


def _json_error(status: Int32, var message: String) -> HttpResponse:
    var body = String('{"error":"') + _json_escape(message) + String('"}')
    var r = HttpResponse(status=status)
    var bytes = body.as_bytes()
    var n = len(bytes)
    for i in range(n):
        r.body.append(bytes[i])
    r.headers[String("content-type")] = String("application/json")
    r.headers[String("content-length")] = String(n)
    return r^


def _upstream_response(var upstream: ForwardedResponse) -> HttpResponse:
    """The engine's response, passed through: its status, content type and
    body bytes."""
    var r = HttpResponse(status=Int32(upstream.status))
    var n = len(upstream.body)
    swap(r.body, upstream.body)
    var ct = upstream.content_type
    if ct.byte_length() == 0:
        ct = String("application/json")
    r.headers[String("content-type")] = ct
    r.headers[String("content-length")] = String(n)
    return r^


# =============================================================================
# ControlApiDispatcher[B: LocalBackend, F: OpenAiForwarder] — the control-API.
# =============================================================================
struct ControlApiDispatcher[
    B: LocalBackend, C: MonotonicClock, F: OpenAiForwarder
](Movable, RequestDispatcher):
    """The loopback control API over the BackendSupervisor[B, C] state machine.

    Owns the SM + a per-model FitResult (for the fit rating) + the OpenAI
    forwarder F. Exposes the lifecycle verbs + the `/v1` passthrough.
    Loopback only (the server hosting it binds 127.0.0.1).
    """

    var _sm: BackendSupervisor[Self.B, Self.C]
    var _forwarder: Self.F
    # Per-model fit RESULT (parallel to the SM's registered models by id). The
    # fit was computed at registration (auto_pick); we store the chosen
    # variant's FitResult so the list/status verbs can render green/yellow/red
    # without re-running the resolver. Keyed by id via _fit_ids.
    var _fit_ids: List[String]
    var _fit_results: List[FitResult]

    def __init__(
        out self,
        var sm: BackendSupervisor[Self.B, Self.C],
        var forwarder: Self.F,
    ):
        self._sm = sm^
        self._forwarder = forwarder^
        self._fit_ids = List[String]()
        self._fit_results = List[FitResult]()

    def set_fit(mut self, id: String, fit_result: FitResult):
        """Record the chosen variant's FitResult for `id` (the list/status fit
        rating). Called once per model after register()."""
        for i in range(len(self._fit_ids)):
            if self._fit_ids[i] == id:
                self._fit_results[i] = fit_result
                return
        self._fit_ids.append(id)
        self._fit_results.append(fit_result)

    def _fit_rating_of(self, id: String) -> String:
        """The fit rating string (green/yellow/red) for `id`; empty if unknown."""
        for i in range(len(self._fit_ids)):
            if self._fit_ids[i] == id:
                return fit_rating_name(self._fit_results[i].rating)
        return String("")

    def sm_ref(ref self) -> ref [self._sm] BackendSupervisor[Self.B, Self.C]:
        """Borrow the owned state machine (test inspection)."""
        return self._sm

    def forwarder_ref(ref self) -> ref [self._forwarder] Self.F:
        """Borrow the owned forwarder (test inspection — what it was handed)."""
        return self._forwarder

    def tick_idle_unload(mut self) -> Int:
        """Drive the SM's keep_alive sweep once (the idle-unload TICK). A
        server's serve loop can call this once per serve iteration (the
        simplest correct driver: no extra thread, no shared-SM race). Returns
        the number of models idle-unloaded this tick. Keeps the SM
        encapsulated (the server drives the tick through this dispatcher, not a
        raw mutable SM borrow)."""
        return self._sm.tick_idle_unload()

    def clock_mut(mut self) -> ref [self._sm] BackendSupervisor[Self.B, Self.C]:
        """Borrow the owned SM mutably (test seam — a virtual-clock test advances
        the SM's clock via `clock_mut().clock_mut().advance_ms(...)` to drive the
        idle-unload tick deterministically). Production code does not need
        this."""
        return self._sm

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        """Route a parsed control API request. Domain failures are mapped to
        JSON errors, not raised. The reactor is unused (the backend's launch
        and the forwarder do their own I/O). Loopback is the trust boundary —
        no auth."""
        var method = req.method
        var path = req.path

        # --- GET /v1/models — the OpenAI model-list shape -------------------
        if method == HttpMethod.get() and path == ROUTE_V1_MODELS:
            return self._handle_v1_models()

        # --- GET /models — the RICH list (state + fit) ----------------------
        if method == HttpMethod.get() and path == ROUTE_MODELS:
            return self._handle_models_list()

        # --- GET /status?id=<id> --------------------------------------------
        if method == HttpMethod.get() and path == ROUTE_STATUS:
            var id = _query_param(req.query_string, String("id"))
            return self._handle_status(id)

        # --- POST /select {"id": "<id>"} ------------------------------------
        if method == HttpMethod.post() and path == ROUTE_SELECT:
            return self._handle_select(req^)

        # --- POST /stop {"id": "<id>"} --------------------------------------
        if method == HttpMethod.post() and path == ROUTE_STOP:
            return self._handle_stop(req^)

        # --- POST /v1/... — the OpenAI passthrough --------------------------
        if method == HttpMethod.post() and _path_under_v1(path):
            return self._handle_v1_passthrough(req^)

        return _json_error(Int32(404), String("no such route: ") + path)

    # --- verb handlers -------------------------------------------------------

    def _handle_v1_models(mut self) -> HttpResponse:
        """The OpenAI `/v1/models` list shape (every registered model as an
        OpenAI model object). This is the endpoint an OpenAI client probes.
        `mut self` so the SM-mutex-guarded `all_status` (which is `mut self` for
        the lock) is callable on the request path under N workers."""
        var all = self._sm.all_status()
        var data = String("[")
        for i in range(len(all)):
            if i > 0:
                data += String(",")
            data += String('{"id":"') + _json_escape(all[i].id)
            data += String('","object":"model","owned_by":"komira-localmodel"}')
        data += String("]")
        var body = String('{"object":"list","data":') + data + String("}")
        return _json_200(body^)

    def _handle_models_list(mut self) -> HttpResponse:
        """The RICH list: every model with its lifecycle state + fit rating +
        admission-control snapshot (cap / in-flight / queued), all from one
        locked snapshot of the state machine."""
        var all = self._sm.all_status()
        var data = String("[")
        for i in range(len(all)):
            if i > 0:
                data += String(",")
            data += _model_status_json(all[i], self._fit_rating_of(all[i].id))
        data += String("]")
        var body = String('{"models":') + data + String("}")
        return _json_200(body^)

    def _handle_status(mut self, id: String) -> HttpResponse:
        # `mut self` for the SM-mutex-guarded `status_of`.
        if id.byte_length() == 0:
            return _json_error(Int32(400), String("missing ?id=<model-id>"))
        var st = self._sm.status_of(id)
        if st.state < 0:
            return _json_error(Int32(404), String("no such model: ") + id)
        return _json_200(_model_status_json(st, self._fit_rating_of(id)))

    def _load_failed(mut self, id: String) -> HttpResponse:
        """The 503 for a `request_load` that returned False."""
        var st = self._sm.status_of(id)
        if st.state == LM_FAILED:
            var msg = (
                String("model ") + id + String(" failed to load: ")
                + failure_reason_text(st.failure_reason)
            )
            if st.failure_detail.byte_length() > 0:
                msg += String(" (") + st.failure_detail + String(")")
            return _json_error(Int32(503), msg^)
        return _json_error(
            Int32(503),
            String("model ") + id
            + String(
                " cannot load now: the resident models it would replace are"
                " serving requests; retry shortly"
            ),
        )

    def _handle_select(mut self, var req: HttpRequest) -> HttpResponse:
        var id: String
        try:
            id = _body_id(req^)
        except e:
            return _json_error(Int32(400), String(e))
        if id.byte_length() == 0:
            return _json_error(Int32(400), String('missing {"id": "<model-id>"}'))
        if not self._sm.contains(id):
            return _json_error(Int32(404), String("no such model: ") + id)
        var ok: Bool
        try:
            ok = self._sm.request_load(id)
        except e:
            _ = e
            return _json_error(
                Int32(500), String("load raised for ") + id
            )
        if not ok:
            return self._load_failed(id)
        var st = self._sm.status_of(id)
        var body = String('{"id":"') + _json_escape(id) + String('",')
        body += String('"state":"') + model_state_name(st.state) + String('",')
        body += String('"base_url":"') + _json_escape(st.base_url) + String('"}')
        return _json_200(body^)

    def _handle_stop(mut self, var req: HttpRequest) -> HttpResponse:
        var id: String
        try:
            id = _body_id(req^)
        except e:
            return _json_error(Int32(400), String(e))
        if id.byte_length() == 0:
            return _json_error(Int32(400), String('missing {"id": "<model-id>"}'))
        if not self._sm.contains(id):
            return _json_error(Int32(404), String("no such model: ") + id)
        var stopped = self._sm.stop(id)
        var st = self._sm.status_of(id)
        var body = String('{"id":"') + _json_escape(id) + String('",')
        body += String('"stopped":') + ("true" if stopped else "false") + String(",")
        body += String('"state":"') + model_state_name(st.state) + String('",')
        body += String('"inflight":') + String(st.inflight) + String(",")
        body += String('"queued":') + String(st.queued) + String("}")
        return _json_200(body^)

    def _handle_v1_passthrough(mut self, var req: HttpRequest) -> HttpResponse:
        """The single-endpoint passthrough: read the top-level `model` member of
        the OpenAI body, take an admission slot on that model, load it if needed
        (REGISTERED -> SERVING, evicting idle models if needed), forward the
        body to its `/v1` endpoint and return the engine's response as it is.

        The slot is taken BEFORE the load, so from the moment the model is
        SERVING it has this request outstanding and cannot be idle-unloaded,
        evicted or stopped until the forward returns. The slot is released on
        every return path after it is taken."""
        var path = req.path
        # Move the body bytes out (swap leaves req.body an empty List so req's
        # destructor stays valid — the partial-move-safe primitive).
        var body_bytes = List[UInt8]()
        swap(body_bytes, req.body)
        if not _is_valid_utf8(body_bytes):
            return _json_error(
                Int32(400), String("the /v1 body is not valid UTF-8")
            )
        var body_str = _string_of_bytes(body_bytes)

        var id = _top_level_string_field(body_str, String("model"))
        if id.byte_length() == 0:
            return _json_error(
                Int32(400),
                String('the /v1 body must name a "model" (a registered id)'),
            )
        if not self._sm.contains(id):
            return _json_error(Int32(404), String("no such model: ") + id)

        # ADMISSION CONTROL: bound the in-flight requests against this model at
        # its per-model concurrency cap (the same N the concurrency-aware fit
        # reserved KV for). A burst beyond the cap queues; past cap+queue it is
        # REJECTED (503) rather than admitted into a spill or into KV cross-
        # contamination (ml-explore/mlx-lm#965).
        var decision = self._sm.admit(id)
        if decision == ADMIT_REJECTED:
            var cap = self._sm.max_concurrent_of(id)
            return _json_error(
                Int32(503),
                String("model ") + id
                + String(
                    " is at its concurrency cap + queue (admission rejected to"
                    " avoid memory spill / KV contamination); cap="
                )
                + String(cap)
                + String(", retry shortly"),
            )
        # BLOCK-AND-WAIT for a QUEUED request: this worker holds a queued slot
        # and spins, trying on each turn to PULL it into a freed in-flight slot
        # (try_promote_if_under_cap succeeds only when inflight < cap), so
        # in-flight never exceeds the cap. The spin is bounded by
        # _ADMIT_WAIT_MAX_SPINS yields; on timeout the worker drops its queued
        # slot and returns 503 rather than pin itself on an overloaded engine.
        if decision == ADMIT_QUEUED:
            var claimed = False
            var spins = 0
            while spins < _ADMIT_WAIT_MAX_SPINS:
                if self._sm.try_promote_if_under_cap(id):
                    claimed = True
                    break
                _sched_yield()
                spins += 1
            if not claimed:
                self._sm.release_queued(id)
                var cap = self._sm.max_concurrent_of(id)
                return _json_error(
                    Int32(503),
                    String("model ") + id
                    + String(
                        " is at its concurrency cap and the queue wait timed out"
                        " (admission deferred to avoid memory spill / KV"
                        " contamination); cap="
                    )
                    + String(cap)
                    + String(", retry shortly"),
                )

        # Holding an in-flight slot: load (or re-arm if already serving).
        var ok: Bool
        try:
            ok = self._sm.request_load(id)
        except e:
            _ = e
            self._sm.release(id)
            return _json_error(Int32(500), String("load raised for ") + id)
        if not ok:
            self._sm.release(id)
            return self._load_failed(id)

        var base_url = self._sm.base_url_of(id)
        if base_url.byte_length() == 0:
            self._sm.release(id)
            return _json_error(
                Int32(503), String("model ") + id + String(" has no endpoint")
            )

        var upstream: ForwardedResponse
        try:
            upstream = self._forwarder.forward(base_url, path, body_str)
        except e:
            _ = e
            self._sm.release(id)
            return _json_error(
                Int32(502),
                String("upstream ") + base_url + String(" forward failed"),
            )
        self._sm.release(id)
        return _upstream_response(upstream^)


# -----------------------------------------------------------------------------
# Free helpers (kept out of the struct so they can be called without `self`).
# -----------------------------------------------------------------------------
def _path_under_v1(path: String) -> Bool:
    """True iff `path` starts with `/v1/` (the OpenAI passthrough prefix)."""
    var pb = path.as_bytes()
    var prefix = ROUTE_V1_PREFIX.as_bytes()
    if len(pb) < len(prefix):
        return False
    for i in range(len(prefix)):
        if pb[i] != prefix[i]:
            return False
    return True


def _body_id(var req: HttpRequest) raises -> String:
    """Move the request body out + pull its top-level `"id"` member (the
    select/stop body shape `{"id": "<model-id>"}`). Raises on a body that is
    not valid UTF-8."""
    var body_bytes = List[UInt8]()
    swap(body_bytes, req.body)
    if not _is_valid_utf8(body_bytes):
        raise Error("the request body is not valid UTF-8")
    return _top_level_string_field(_string_of_bytes(body_bytes), String("id"))
