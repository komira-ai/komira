# =============================================================================
# src/komira_http/middleware/error_mapper.mojo — uncaught-error → 500
# =============================================================================
#
# Uncaught-error mapping for the middleware chain.
#
# ErrorMappingMiddleware catches uncaught Mojo `Error` from any inner
# middleware / handler and converts it to a 500 Internal Server Error
# response with a SANITIZED body. Never echo client
# input in the response. The default body is a static string from a
# fixed table; users may override via constructor.
#
# Position in the chain: OUTERMOST (registered first; runs last in the
# after phase). Conventionally always present; the chain's run driver
# falls back to `HttpResponse.internal_error()` if no error mapper is
# configured.
#
# Public surface:
#   - ErrorMappingMiddleware struct
#   - ErrorMappingConfig — body / content-type knobs
#   - map_error(e: Error) -> HttpResponse — the conversion fn
#
# Does NOT conform to the Middleware trait directly because its
# semantics are special-cased by the chain driver (the `try / except`
# wraps the whole chain, not the layer-by-layer before/after pair).
# The before/after pair are stub no-ops for chain composability.
# =============================================================================

from komira_http.codec.types import HttpRequest, HttpResponse, status_text
from komira_http.middleware.fault_report import (
    FAULT_CODE_UNATTRIBUTED,
    report_fault,
)
from komira_http.middleware.middleware import RequestContext


# =============================================================================
# §1 — ErrorMappingConfig.
# =============================================================================


@fieldwise_init
struct ErrorMappingConfig(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Configurable knobs for ErrorMappingMiddleware.

    Defaults:
      status        = 500
      content_type  = "text/plain"
      body          = "Internal Server Error" (static — no client echo)
      include_log_marker = True — write a single log line to a server-
                                  local buffer so the operator can
                                  correlate the 500 with the underlying
                                  Error. NEVER includes client input.
    """

    var status: Int32
    var include_log_marker: Bool

    @staticmethod
    def default() -> ErrorMappingConfig:
        return ErrorMappingConfig(
            status=Int32(500),
            include_log_marker=True,
        )


# =============================================================================
# §2 — ErrorMappingMiddleware.
# =============================================================================


struct ErrorMappingMiddleware(Movable, Deinitable):
    """Converts uncaught raises into an ATTRIBUTED 500 — a sanitized JSON
    envelope carrying a stable cause code + an incident id, plus one stdout
    line carrying the raw cause under that same id.

    The response NEVER echoes the raise text: that is the LOAD-BEARING half of
    the disclosure split. The raise text goes SOMEWHERE instead — one stdout
    line, not a field nothing reads, so a 500 is diagnosable. See
    `fault_report.mojo` for the split
    and for why a refusal is not this struct's subject.

    Construction:
        var em = ErrorMappingMiddleware.default()
        var em = ErrorMappingMiddleware.with_body(msg)   # replace message text
        var em = em^.with_wiring_report(n_unwired)       # boot wiring count

    The chain driver invokes `map_error_at(e, method, path)` when it catches a
    raise; `before` / `after` are stub no-ops (the special-case semantics live
    in the driver's try/except, not in the trait surface).
    """

    var config: ErrorMappingConfig
    # The STATIC human-readable text placed in the envelope's `message` field.
    # Never derived from the raise. (Named `body` for source compatibility with
    # every existing construction site; it is one FIELD of the body now, not
    # the whole body.)
    var body: String
    # There is no `content_type` knob: the attributed envelope is always
    # `application/json` — that is the whole point of it parsing identically to
    # a deliberate refusal. Keeping a content-type knob that the emitter no
    # no longer honours would be an accept-and-ignore-a-parameter defect, so
    # there is none.
    # Server-local diagnostic ring. Each map_error invocation appends one entry.
    #
    # ⚠ THIS FIELD IS NOT OBSERVABILITY. It has zero readers outside this
    # struct's two accessors, so as the ONLY sink for a caught 500's cause it
    # would retain the cause in process memory and never emit it anywhere an
    # operator could read. It is
    # kept because unit tests assert against it in-process, but the AUTHORITATIVE
    # sink is the stdout line `report_fault` prints. Do not "simplify" by
    # routing back to this field alone.
    var diagnostic_log: List[String]
    # The number of capabilities this deployment booted WITHOUT (the binary's
    # boot-time unwired-capability report, handed in via `with_wiring_report`).
    # Emitted on every fault line. 0 == "wiring complete", which is also the
    # default, so a server that never calls `with_wiring_report` reports 0 and
    # behaves exactly as before on this axis.
    var wiring_unwired: Int

    def __init__(
        out self,
        config: ErrorMappingConfig,
        var body: String,
    ):
        self.config = config
        self.body = body^
        self.diagnostic_log = List[String]()
        self.wiring_unwired = 0

    def with_wiring_report(var self, unwired_count: Int) -> ErrorMappingMiddleware:
        """Tell the mapper how many capabilities this deployment booted WITHOUT,
        so every fault line carries it.

        WHY THIS EXISTS: a binary can compute its unwired capabilities at
        boot and print them — and nothing reads that. A
        deployment that boots incomplete and then 500s was reporting those two
        facts to two audiences that never met. This is the join: the count rides
        every fault line, so an operator holding a 500 learns in the same line
        whether to suspect configuration before code.

        Only the COUNT, never the names — the names stay in the boot log, which
        is not reachable from the wire."""
        self.wiring_unwired = unwired_count
        return self^

    @staticmethod
    def default() -> ErrorMappingMiddleware:
        return ErrorMappingMiddleware(
            ErrorMappingConfig.default(),
            String("Internal Server Error"),
        )

    @staticmethod
    def with_body(var message: String) -> ErrorMappingMiddleware:
        """Override the STATIC human text carried in the envelope's `message`
        field. Still static — never formatted against the Error message.

        (The envelope is always `application/json`, so there is no
        `content_type` parameter to accept and ignore.)"""
        return ErrorMappingMiddleware(
            ErrorMappingConfig.default(),
            message^,
        )

    def map_error(mut self, e: Error) -> HttpResponse:
        """Convert an uncaught Mojo Error into an ATTRIBUTED 500 response, with
        no route context available.

        Prefer `map_error_at`, which carries the method + path onto the log
        line. This overload exists so every pre-existing call site keeps
        compiling; it reports the route as `-`."""
        return self.map_error_at(
            e, String("-"), String("-"), String(""), String("")
        )

    def map_error_at(
        mut self,
        e: Error,
        method: String,
        path: String,
        trace: String,
        trace_project: String,
    ) -> HttpResponse:
        """Convert an uncaught Mojo Error into an ATTRIBUTED response.

        Steps:
          1. EMIT the fault line to stdout — incident id, cause code, status,
             method, path, unwired-capability count, and the RAW message.
             This is the step whose absence made a 500 a dead end: the cause
             was always in hand and was written only to `diagnostic_log`, which
             nothing reads.
          2. Return the `{"error":{code,message,incidentId}}` envelope carrying
             the SAME incident id — the correlation an operator follows from a
             user's screenshot to the log line.
          3. Keep appending to `diagnostic_log` for the in-process unit tests.

        ⚠ `path` MUST be the path only. `HttpRequest.query_string` is a separate
        field precisely so a credential in the query never reaches this line.
        `trace_project` qualifies the line's trace; empty omits the canonical
        trace field.

        The cause code is `internal.unattributed`: this boundary catches raises
        from everywhere and cannot name the cause without guessing from the
        error text, which would be wrong in both directions. Naming the
        anonymity is the honest report, and the detail is one grep away."""
        var resp = report_fault(
            e,
            self.config.status,
            FAULT_CODE_UNATTRIBUTED,
            method,
            path,
            self.body,
            self.wiring_unwired,
            trace,
            trace_project,
        )
        # Preserved from the pre-attribution behaviour: a mapped fault closes
        # the connection rather than keeping it alive for pipelining.
        resp.headers[String("connection")] = String("close")

        if self.config.include_log_marker:
            var marker = String("error_mapped status=") + String(
                Int(self.config.status)
            ) + String(" message=") + String(e)
            self.diagnostic_log.append(marker^)

        return resp^

    # --- Middleware trait stubs (chain driver special-cases this mw) ---

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        """No-op. The chain driver's try/except handles error mapping."""
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        """No-op."""
        pass

    def diagnostic_log_len(self) -> Int:
        return len(self.diagnostic_log)

    def diagnostic_log_entry(self, idx: Int) -> String:
        if idx < 0 or idx >= len(self.diagnostic_log):
            return String("")
        return String(self.diagnostic_log[idx])
