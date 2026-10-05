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

from komira_http import (
    HttpMethod,
    HttpRequest,
    HttpResponse,
    RequestDispatcher,
)

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
# the OpenAI response body. A real forwarder wraps an HTTP client; a test binds
# a stub that records what it was handed.
# -----------------------------------------------------------------------------
trait OpenAiForwarder(Movable, Deinitable):
    """Forward an OpenAI request body to a loaded backend's `/v1` endpoint.

    `forward(base_url, path, request_body)` POSTs `request_body` to
    `<base_url><path>` and returns the response body. Raises on a transport
    error (the dispatcher maps it to a 502)."""

    def forward(
        mut self, base_url: String, path: String, request_body: String
    ) raises -> String:
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


def _json_escape(s: String) -> String:
    """Minimal JSON string escaping (quote + backslash). The ids / urls here
    are ASCII paths + model ids; this covers the characters that would break
    the flat envelope."""
    var out = String("")
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(ord('"')):
            out += String('\\"')
        elif c == UInt8(ord("\\")):
            out += String("\\\\")
        else:
            out += chr(Int(c))
    return out^


def _model_status_json(
    st: ModelStatus,
    var fit_rating: String,
    max_concurrent: Int,
    inflight: Int,
    queued: Int,
) -> String:
    """Render one ModelStatus + its fit rating + its admission-control snapshot
    (the per-model concurrency cap + the current in-flight / queued counts) as a
    flat JSON object."""
    var o = String("{")
    o += String('"id":"') + _json_escape(st.id) + String('",')
    o += String('"state":"') + model_state_name(st.state) + String('",')
    o += String('"fit":"') + fit_rating + String('",')
    o += String('"resident_bytes":') + String(st.resident_bytes) + String(",")
    o += String('"max_concurrent":') + String(max_concurrent) + String(",")
    o += String('"inflight":') + String(inflight) + String(",")
    o += String('"queued":') + String(queued) + String(",")
    o += String('"base_url":"') + _json_escape(st.base_url) + String('"')
    if st.state == LM_FAILED:
        o += String(',"failure":"')
        o += _json_escape(failure_reason_text(st.failure_reason))
        o += String('"')
    o += String("}")
    return o^


def _query_param(query_string: String, key: String) -> String:
    """Extract a single query param value (e.g. `id` from `id=foo&x=1`). Flat
    parse — no URL-decoding (the ids here are plain). Empty if absent."""
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
            var out = String("")
            var k = i + pn
            while k < n and qb[k] != UInt8(ord("&")):
                out += chr(Int(qb[k]))
                k += 1
            return out^
        i += 1
    return String("")


def _extract_json_string_field(body: String, field: String) -> String:
    """Pull a flat top-level string field's value out of a small JSON body
    (e.g. `"id"` from `{"id":"foo"}`). Naive scan adequate for the flat control
    bodies: find `"<field>"`, skip to the next `"`, read to the closing `"`.
    Empty if not found. Does NOT handle escaped quotes inside the value (the
    ids here are plain)."""
    var needle = String('"') + field + String('"')
    var nb = needle.as_bytes()
    var bb = body.as_bytes()
    var n = len(bb)
    var nn = len(nb)
    var i = 0
    while i + nn <= n:
        var matched = True
        var j = 0
        while j < nn:
            if bb[i + j] != nb[j]:
                matched = False
                break
            j += 1
        if matched:
            # Skip past the field name, the ':' and whitespace, to the opening
            # quote of the value.
            var k = i + nn
            while k < n and bb[k] != UInt8(ord('"')):
                # Stop if we hit a comma/brace before a quote (field had a
                # non-string value).
                if bb[k] == UInt8(ord(",")) or bb[k] == UInt8(ord("}")):
                    return String("")
                k += 1
            if k >= n:
                return String("")
            k += 1  # past the opening quote
            var out = String("")
            while k < n and bb[k] != UInt8(ord('"')):
                out += chr(Int(bb[k]))
                k += 1
            return out^
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
        admission-control snapshot (cap / in-flight / queued). `mut self` for the
        SM-mutex-guarded `all_status`."""
        var all = self._sm.all_status()
        var data = String("[")
        for i in range(len(all)):
            if i > 0:
                data += String(",")
            var mid = all[i].id
            data += _model_status_json(
                all[i],
                self._fit_rating_of(mid),
                self._sm.max_concurrent_of(mid),
                self._sm.inflight_of(mid),
                self._sm.queued_of(mid),
            )
        data += String("]")
        var body = String('{"models":') + data + String("}")
        return _json_200(body^)

    def _handle_status(mut self, id: String) -> HttpResponse:
        # `mut self` for the SM-mutex-guarded `status_of`.
        if id.byte_length() == 0:
            return _json_error(Int32(400), String("missing ?id=<model-id>"))
        if not self._sm.contains(id):
            return _json_error(Int32(404), String("no such model: ") + id)
        var st = self._sm.status_of(id)
        return _json_200(
            _model_status_json(
                st,
                self._fit_rating_of(id),
                self._sm.max_concurrent_of(id),
                self._sm.inflight_of(id),
                self._sm.queued_of(id),
            )
        )

    def _handle_select(mut self, var req: HttpRequest) -> HttpResponse:
        var id = _body_id(req^)
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
            # A loud FAILED load — surface the actionable reason.
            var st = self._sm.status_of(id)
            if st.state == LM_FAILED:
                return _json_error(
                    Int32(503),
                    String("model ") + id + String(" failed to load: ")
                    + failure_reason_text(st.failure_reason),
                )
            return _json_error(
                Int32(503), String("model ") + id + String(" did not load")
            )
        var st = self._sm.status_of(id)
        var body = String('{"id":"') + _json_escape(id) + String('",')
        body += String('"state":"') + model_state_name(st.state) + String('",')
        body += String('"base_url":"') + _json_escape(st.base_url) + String('"}')
        return _json_200(body^)

    def _handle_stop(mut self, var req: HttpRequest) -> HttpResponse:
        var id = _body_id(req^)
        if id.byte_length() == 0:
            return _json_error(Int32(400), String('missing {"id": "<model-id>"}'))
        if not self._sm.contains(id):
            return _json_error(Int32(404), String("no such model: ") + id)
        var stopped = self._sm.stop(id)
        var st = self._sm.status_of(id)
        var body = String('{"id":"') + _json_escape(id) + String('",')
        body += String('"stopped":') + ("true" if stopped else "false") + String(",")
        body += String('"state":"') + model_state_name(st.state) + String('"}')
        return _json_200(body^)

    def _handle_v1_passthrough(mut self, var req: HttpRequest) -> HttpResponse:
        """The single-endpoint passthrough: read the `model` field from the
        OpenAI body, JIT-load it (REGISTERED -> SERVING, LRU-evicting if
        needed), forward the body to its `/v1` endpoint, return the response."""
        var path = req.path
        # Move the body bytes out (swap leaves req.body an empty List so req's
        # destructor stays valid — the partial-move-safe primitive).
        var body_bytes = List[UInt8]()
        swap(body_bytes, req.body)
        var body_str = String(unsafe_from_utf8=Span(body_bytes))

        var id = _extract_json_string_field(body_str, String("model"))
        if id.byte_length() == 0:
            return _json_error(
                Int32(400),
                String('the /v1 body must name a "model" (a registered id)'),
            )
        if not self._sm.contains(id):
            return _json_error(Int32(404), String("no such model: ") + id)

        # JIT-load (or re-arm if already serving).
        var ok: Bool
        try:
            ok = self._sm.request_load(id)
        except e:
            _ = e
            return _json_error(Int32(500), String("load raised for ") + id)
        if not ok:
            var st = self._sm.status_of(id)
            if st.state == LM_FAILED:
                return _json_error(
                    Int32(503),
                    String("model ") + id + String(" failed to load: ")
                    + failure_reason_text(st.failure_reason),
                )
            return _json_error(
                Int32(503), String("model ") + id + String(" did not load")
            )

        # Forward to the loaded backend's OpenAI endpoint.
        var base_url = self._sm.base_url_of(id)
        if base_url.byte_length() == 0:
            return _json_error(
                Int32(503), String("model ") + id + String(" has no endpoint")
            )

        # ADMISSION CONTROL: bound the in-flight requests against this model at
        # its per-model concurrency cap (the same N the concurrency-aware fit
        # reserved KV for). A burst beyond the cap queues; past cap+queue it is
        # REJECTED (503) rather than admitted into a spill or into KV cross-
        # contamination (ml-explore/mlx-lm#965). The slot is RELEASED on
        # EVERY return path below (the forward succeeded, raised, or the upstream
        # errored) so the in-flight count never leaks.
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
        # CONCURRENT WORKERS: a server may run this passthrough on N pthread
        # workers, so N ADMITTED requests reach the forward() below
        # SIMULTANEOUSLY and the engine's OWN continuous batching serves them
        # in parallel.
        #
        # BLOCK-AND-WAIT for a QUEUED request (a queued request WAITS for a real
        # in-flight slot, turning OOM under load into bounded latency under
        # load). A QUEUED decision means the cap is momentarily full; this
        # worker holds a QUEUED slot and SPINS — on each turn it tries to PULL its
        # queued slot into a freed in-flight slot (try_promote_if_under_cap, which
        # only succeeds when inflight < cap). This makes in-flight a TRUE hard cap
        # (== max_concurrent) — a queued slot becomes in-flight ONLY when a real
        # slot frees, never unconditionally. The spin is bounded by _ADMIT_WAIT_MAX_SPINS * the yield; on timeout the
        # worker drops its queued slot + returns 503 (a stuck/overloaded engine
        # must not pin the worker forever). The thread yields between turns so a
        # waiting worker does not burn the core (the engine round-trips run on the
        # OTHER workers in the meantime + free slots).
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
                # Timed out waiting for a slot — drop the queued reservation and
                # reject LOUD rather than pin this worker on an overloaded engine.
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

        var resp_body: String
        try:
            resp_body = self._forwarder.forward(base_url, path, body_str)
        except e:
            _ = e
            self._sm.release(id)
            return _json_error(
                Int32(502),
                String("upstream ") + base_url + String(" forward failed"),
            )
        self._sm.release(id)
        return _json_200(resp_body^)


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


def _body_id(var req: HttpRequest) -> String:
    """Move the request body out + pull its `"id"` field (the select/stop
    body shape `{"id": "<model-id>"}`)."""
    var body_bytes = List[UInt8]()
    swap(body_bytes, req.body)
    var body_str = String(unsafe_from_utf8=Span(body_bytes))
    return _extract_json_string_field(body_str, String("id"))
