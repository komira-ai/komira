# =============================================================================
# src/komira_http_server/middleware/chain.mojo — ordered middleware driver
# =============================================================================
#
# `MiddlewareChain` holds the 4 builtin middlewares as Optional-wrapped
# fields. The user constructs a chain via builder methods (with_cors,
# with_tracing, with_logging, with_error_mapper); the chain's `run`
# driver invokes them in the canonical outer→inner order, runs the
# handler/canned-response at the bottom, and walks back inner→outer
# in the `after` phase.
#
# Canonical order (outer → inner):
#   1. ErrorMappingMiddleware  (always present; outermost catch-all)
#   2. CorsMiddleware          (browser preflight handling)
#   3. TracingMiddleware       (span emit)
#   4. LoggingMiddleware       (start time, log emit)
#   5. (handler / canned response)
#
# Rationale for ordering:
#   - ErrorMapper outermost so it catches everything (including raises
#     from other middlewares).
#   - CORS BEFORE Tracing/Logging so preflight short-circuits don't
#     emit spans for non-real requests.
#   - Tracing BEFORE Logging so the LoggingMiddleware can include the
#     span_id in its log entries.
#
# Mojo 1.0.0b1 compatibility: the chain is concrete-typed (NOT a
# `List[OwnedPointer[Middleware]]`). Each builtin is held as an
# `Optional` so users can opt-in to which middlewares to enable. User-
# defined `Middleware` conformers plug via the parametric
# `run_with_user_mw[M: Middleware]` entry point (Mojo 1.0.0b1 traits
# don't support struct-level parameters, so the parametric extension
# is at the call site — see `chain.run_with_user_mw[MyMiddleware](...)`).
# =============================================================================

from komira_http_core.codec.types import HttpRequest, HttpResponse, status_text
from komira_http_server.middleware.cors import CorsMiddleware
from komira_http_server.middleware.error_mapper import ErrorMappingMiddleware
from komira_http_server.middleware.fault_report import (
    FAULT_CODE_TRANSPORT,
    WIRING_UNWIRED_UNKNOWN,
    report_fault,
    trace_header_of,
)
from komira_http_server.middleware.logging import LoggingMiddleware
from komira_http_server.middleware.middleware import Middleware, RequestContext
from komira_http_server.middleware.tracing import TracingMiddleware


# =============================================================================
# §1 — ChainOutcome.
# =============================================================================


@fieldwise_init
struct ChainOutcome(Movable, Deinitable):
    """Result of running a middleware chain.

    The chain ALWAYS produces a response (even on error: the
    ErrorMappingMiddleware converts raises → 500). `short_circuited`
    indicates the response did NOT come from the handler — useful for
    metrics distinguishing handler vs. middleware-rejected requests.
    """

    var response: HttpResponse
    var short_circuited: Bool


# =============================================================================
# §2 — MiddlewareChain.
# =============================================================================


struct MiddlewareChain(Movable, Deinitable):
    """Composes the 4 builtin middlewares + a handler at the bottom.

    Build-time:
        var chain = MiddlewareChain()
        chain = chain.with_error_mapper(ErrorMappingMiddleware.default())
        chain = chain.with_cors(CorsMiddleware.permissive())
        chain = chain.with_tracing(TracingMiddleware.disabled())
        chain = chain.with_logging(LoggingMiddleware.new())

    Run-time:
        # baseline — canned response at the bottom:
        var outcome = chain.run_with_canned(req^, canned_response_bytes)

        # User extension — parametric Middleware conformer:
        var outcome = chain.run_with_user_mw[MyMW](req^, my_mw)

    The 4 builtins are Optional-wrapped so the chain works with any
    subset enabled. ErrorMappingMiddleware is conventionally always
    present (the outermost catch-all); the other 3 are user-opt-in.
    """

    var _error_mapper: Optional[ErrorMappingMiddleware]
    var _cors: Optional[CorsMiddleware]
    var _tracing: Optional[TracingMiddleware]
    var _logging: Optional[LoggingMiddleware]
    # The cloud project id fault and error-response log lines qualify their
    # trace with. Empty (the default) omits the canonical trace field; the
    # plain `trace_id` is still written. Set from the process configuration
    # with `with_trace_project`.
    var _trace_project: String

    def __init__(out self):
        self._error_mapper = Optional[ErrorMappingMiddleware]()
        self._cors = Optional[CorsMiddleware]()
        self._tracing = Optional[TracingMiddleware]()
        self._logging = Optional[LoggingMiddleware]()
        self._trace_project = String("")

    @staticmethod
    def default() -> MiddlewareChain:
        """Build a chain with the 4 builtins enabled and sane defaults.

        Equivalent to:
            chain = MiddlewareChain()
            chain = chain.with_error_mapper(ErrorMappingMiddleware.default())
            chain = chain.with_cors(CorsMiddleware.permissive())
            chain = chain.with_tracing(TracingMiddleware.disabled())
            chain = chain.with_logging(LoggingMiddleware.new())
        """
        var c = MiddlewareChain()
        c._error_mapper = Optional[ErrorMappingMiddleware](
            ErrorMappingMiddleware.default()
        )
        c._cors = Optional[CorsMiddleware](CorsMiddleware.permissive())
        c._tracing = Optional[TracingMiddleware](TracingMiddleware.disabled())
        c._logging = Optional[LoggingMiddleware](LoggingMiddleware.new())
        return c^

    def with_error_mapper(
        var self, var mw: ErrorMappingMiddleware
    ) -> MiddlewareChain:
        self._error_mapper = Optional[ErrorMappingMiddleware](mw^)
        return self^

    def with_trace_project(var self, project: String) -> MiddlewareChain:
        """Qualify the trace on this chain's fault and error-response log lines
        with `project` (`projects/<project>/traces/<trace>`)."""
        self._trace_project = project
        return self^

    def trace_project(self) -> String:
        """The project id set by `with_trace_project`, or empty."""
        return self._trace_project

    def with_cors(var self, var mw: CorsMiddleware) -> MiddlewareChain:
        self._cors = Optional[CorsMiddleware](mw^)
        return self^

    def with_tracing(var self, var mw: TracingMiddleware) -> MiddlewareChain:
        self._tracing = Optional[TracingMiddleware](mw^)
        return self^

    def with_logging(var self, var mw: LoggingMiddleware) -> MiddlewareChain:
        self._logging = Optional[LoggingMiddleware](mw^)
        return self^

    def has_error_mapper(self) -> Bool:
        return Bool(self._error_mapper)

    def has_cors(self) -> Bool:
        return Bool(self._cors)

    def has_tracing(self) -> Bool:
        return Bool(self._tracing)

    def has_logging(self) -> Bool:
        return Bool(self._logging)

    # --------------------------------------------------------------------------
    # Borrowed accessors (for test inspection).
    # --------------------------------------------------------------------------

    def logging_ref(ref self) -> ref [self._logging] Optional[LoggingMiddleware]:
        return self._logging

    def tracing_ref(ref self) -> ref [self._tracing] Optional[TracingMiddleware]:
        return self._tracing

    def cors_ref(ref self) -> ref [self._cors] Optional[CorsMiddleware]:
        return self._cors

    def error_mapper_ref(
        ref self
    ) -> ref [self._error_mapper] Optional[ErrorMappingMiddleware]:
        return self._error_mapper

    # --------------------------------------------------------------------------
    # Chain run — canned-response handler.
    # --------------------------------------------------------------------------

    def run_with_canned(
        mut self,
        var req: HttpRequest,
        var canned: HttpResponse,
    ) -> ChainOutcome:
        """Drive the chain to completion with a CANNED response at the
        bottom (i.e., no user handler invocation).

        This is the baseline; the dispatched variants swap `canned` for a
        Router-dispatched handler invocation.

        Always returns a ChainOutcome (the error mapper catches any
        uncaught Mojo Error and converts to 500).
        """
        return _drive_chain_canned(self, req^, canned^)

    # --------------------------------------------------------------------------
    # Chain run — parametric user-Middleware handler.
    # --------------------------------------------------------------------------

    def run_with_user_mw[
        M: Middleware
    ](
        mut self,
        var req: HttpRequest,
        var fallback: HttpResponse,
        mut user_mw: M,
    ) -> ChainOutcome:
        """Drive the chain with ONE additional user-Middleware conformer
        at the innermost layer (closest to the handler).

        The user middleware's `before` is the last `before` invoked
        before the canned response (which acts as the "handler" stand-in);
        its `after` is the first `after` invoked after the handler.

        Errors from the user middleware are caught by the chain's
        ErrorMappingMiddleware.
        """
        return _drive_chain_user_mw[M](self, req^, fallback^, user_mw)

    # --------------------------------------------------------------------------
    # legs — the building blocks for driving the chain
    # AROUND a real `RequestDispatcher` (see transport/dispatch.mojo's
    # `serve_read_round_dispatch_chained`). The chain CANNOT call the dispatcher
    # itself (that would force `komira_http_server.middleware` to depend on the
    # transport's `RequestDispatcher` trait — and the transport already imports
    # the chain, so it would be a cycle). Instead the chain exposes its `before`
    # leg (run the builtins + the user/auth middleware's `before`) and its
    # `after` leg (reverse) as two methods; the transport-side driver runs the
    # dispatcher BETWEEN them, wrapping the whole thing in the ErrorMapper try.
    # --------------------------------------------------------------------------

    def run_before_legs[
        M: Middleware
    ](
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
        mut user_mw: M,
        mut user_before_ran: Bool,
    ) raises -> Optional[HttpResponse]:
        """Run the `before` legs in outer→inner order:
            CORS.before → Tracing.before → Logging.before → user_mw.before.

        `user_mw` is the innermost interceptor — for an authenticated API it is the
        `AuthMiddleware`, whose `before` either resolves `ctx.authed_user`
        (returns None → continue to the dispatcher) OR short-circuits with a
        `Some(401)`.

        Returns `Some(response)` if ANY leg short-circuited (the dispatcher
        must NOT run; the caller goes straight to `run_after_legs` on that
        response with `ctx.short_circuit == True`); `None` to continue to the
        dispatcher. Mutates `ctx` (auth attaches the identity; tracing/logging
        stamp their fields) and sets `user_before_ran = True` IFF the innermost
        user/auth `before` actually executed (i.e. no OUTER leg short-circuited
        first) — the caller gates `run_after_legs`' user `after` on it for a
        precise symmetric before/after pairing. May `raises` — the caller's
        ErrorMapper try catches it.

        The ErrorMapper is NOT run here (it is the outermost try in the
        caller); CORS/Tracing/Logging `before` are the inner legs.
        """
        user_before_ran = False
        if self._cors:
            ref cors_mw = self._cors.value()
            var r = cors_mw.before(req, ctx)
            if r:
                ctx.short_circuit = True
                return r^
        if self._tracing:
            ref tr_mw = self._tracing.value()
            var r = tr_mw.before(req, ctx)
            if r:
                ctx.short_circuit = True
                return r^
        if self._logging:
            ref lg_mw = self._logging.value()
            var r = lg_mw.before(req, ctx)
            if r:
                ctx.short_circuit = True
                return r^
        # Innermost: the user / auth middleware. Its `before` sets
        # `ctx.authed_user` (continue) OR short-circuits 401.
        user_before_ran = True
        var ur = user_mw.before(req, ctx)
        if ur:
            ctx.short_circuit = True
            return ur^
        return Optional[HttpResponse]()

    def run_after_legs[
        M: Middleware
    ](
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
        mut user_mw: M,
        user_before_ran: Bool,
    ) raises:
        """Run the `after` legs in reverse (inner→outer) order:
            user_mw.after → Logging.after → Tracing.after → CORS.after.

        Runs UNCONDITIONALLY after the dispatcher (or short-circuit response),
        so e.g. CORS still decorates a 401. `user_before_ran` gates the user
        middleware's `after` to the symmetric case where its `before` ran (a
        CORS/Tracing/Logging short-circuit skips the inner user `before`, so
        its `after` must be skipped too). May `raises` — caught by the caller's
        ErrorMapper try."""
        if user_before_ran:
            user_mw.after(req, resp, ctx)
        if self._logging:
            ref lg_mw_a = self._logging.value()
            lg_mw_a.after(req, resp, ctx)
        if self._tracing:
            ref tr_mw_a = self._tracing.value()
            tr_mw_a.after(req, resp, ctx)
        if self._cors:
            ref cors_mw_a = self._cors.value()
            cors_mw_a.after(req, resp, ctx)

    def map_chain_error(
        mut self, e: Error, method: String, path: String, trace: String
    ) -> HttpResponse:
        """Map an uncaught Mojo `Error` (raised by any leg or the dispatcher)
        to an ATTRIBUTED `HttpResponse` via the chain's
        `ErrorMappingMiddleware`. The transport-side chained driver calls this
        from the outermost `except`, passing the request's method + path (path
        ONLY — never the query string, which can carry a credential).

        ⚠ THE NO-MAPPER FALLBACK IS NO LONGER `internal_error()`. That returned
        a 500 with `content-length: 0` and dropped `e` entirely — a response an
        operator cannot act on, from the branch that fires precisely when the
        server was assembled without its error plumbing. It now reports through
        the same `report_fault` path with the transport cause code, so a
        mapper-less chain is diagnosable too."""
        if self._error_mapper:
            ref em_mw = self._error_mapper.value()
            return em_mw.map_error_at(
                e, method, path, trace, self._trace_project
            )
        return report_fault(
            e,
            Int32(500),
            FAULT_CODE_TRANSPORT,
            method,
            path,
            String("Internal Server Error"),
            WIRING_UNWIRED_UNKNOWN,
            trace,
            self._trace_project,
        )


# =============================================================================
# §3 — Chain driver (free fn so the parametric form composes cleanly).
# =============================================================================


def _drive_chain_canned(
    mut chain: MiddlewareChain,
    var req: HttpRequest,
    var canned: HttpResponse,
) -> ChainOutcome:
    """Drive the 4-builtin chain with a canned response at the bottom.

    Order:  ErrorMapper.before → CORS.before → Tracing.before
            → Logging.before → (handler/canned) → Logging.after
            → Tracing.after  → CORS.after     → ErrorMapper.after
    """
    var ctx = RequestContext.new()
    var response = canned^
    var short_circuited = False

    # ErrorMapper outermost: wraps everything in a try-block.
    # The chain's `try` block calls the inner chain; if any layer
    # raises, ErrorMapper produces the 500.
    var em_caught = False
    try:
        # --- CORS.before ---
        if chain._cors:
            ref cors_mw = chain._cors.value()
            var cors_resp = cors_mw.before(req, ctx)
            if cors_resp:
                response = cors_resp.take()
                ctx.short_circuit = True
                short_circuited = True
        if not ctx.short_circuit:
            # --- Tracing.before ---
            if chain._tracing:
                ref tr_mw = chain._tracing.value()
                var tr_resp = tr_mw.before(req, ctx)
                if tr_resp:
                    response = tr_resp.take()
                    ctx.short_circuit = True
                    short_circuited = True
        if not ctx.short_circuit:
            # --- Logging.before ---
            if chain._logging:
                ref lg_mw = chain._logging.value()
                var lg_resp = lg_mw.before(req, ctx)
                if lg_resp:
                    response = lg_resp.take()
                    ctx.short_circuit = True
                    short_circuited = True
        # Inner-most: nothing — the canned response is used as-is.

        # --- After phase (reverse order) ---
        if chain._logging:
            ref lg_mw_a = chain._logging.value()
            lg_mw_a.after(req, response, ctx)
        if chain._tracing:
            ref tr_mw_a = chain._tracing.value()
            tr_mw_a.after(req, response, ctx)
        if chain._cors:
            ref cors_mw_a = chain._cors.value()
            cors_mw_a.after(req, response, ctx)
    except e:
        em_caught = True
        # ErrorMapper handles the raised error → an ATTRIBUTED 500. The
        # mapper-less arm reports through the SAME path rather than answering a
        # bodiless `internal_error()` — an unconfigured chain is exactly when an
        # operator most needs the cause named.
        response = chain.map_chain_error(
            e, req.method.name(), String(req.path), trace_header_of(req)
        )
        short_circuited = True
        ctx.short_circuit = True
        # Best-effort: still run the after-chain on the error response
        # for metrics consistency (LoggingMiddleware records status etc.).
        # Wrap in another try to swallow any after-chain raises (we
        # already lost the original).
        try:
            if chain._logging:
                ref lg2 = chain._logging.value()
                lg2.after(req, response, ctx)
        except e2:
            _ = e2
        try:
            if chain._tracing:
                ref tr2 = chain._tracing.value()
                tr2.after(req, response, ctx)
        except e2:
            _ = e2
        try:
            if chain._cors:
                ref cors2 = chain._cors.value()
                cors2.after(req, response, ctx)
        except e2:
            _ = e2

    _ = em_caught
    return ChainOutcome(response=response^, short_circuited=short_circuited)


def _drive_chain_user_mw[
    M: Middleware
](
    mut chain: MiddlewareChain,
    var req: HttpRequest,
    var fallback: HttpResponse,
    mut user_mw: M,
) -> ChainOutcome:
    """Drive the chain with a user Middleware at the innermost position.

    Order:  ErrorMapper.before → CORS.before → Tracing.before
            → Logging.before  → user.before  → (fallback)
            → user.after      → Logging.after → Tracing.after
            → CORS.after      → ErrorMapper.after
    """
    var ctx = RequestContext.new()
    var response = fallback^
    var short_circuited = False
    var user_before_ran = False

    try:
        if chain._cors:
            ref cors_mw = chain._cors.value()
            var r1 = cors_mw.before(req, ctx)
            if r1:
                response = r1.take()
                ctx.short_circuit = True
                short_circuited = True
        if not ctx.short_circuit and chain._tracing:
            ref tr_mw = chain._tracing.value()
            var r2 = tr_mw.before(req, ctx)
            if r2:
                response = r2.take()
                ctx.short_circuit = True
                short_circuited = True
        if not ctx.short_circuit and chain._logging:
            ref lg_mw = chain._logging.value()
            var r3 = lg_mw.before(req, ctx)
            if r3:
                response = r3.take()
                ctx.short_circuit = True
                short_circuited = True
        if not ctx.short_circuit:
            # User middleware - innermost layer.
            user_before_ran = True
            var ur = user_mw.before(req, ctx)
            if ur:
                response = ur.take()
                ctx.short_circuit = True
                short_circuited = True

        # After phase (reverse order).
        if user_before_ran:
            user_mw.after(req, response, ctx)
        if chain._logging:
            ref lg_mw_a = chain._logging.value()
            lg_mw_a.after(req, response, ctx)
        if chain._tracing:
            ref tr_mw_a = chain._tracing.value()
            tr_mw_a.after(req, response, ctx)
        if chain._cors:
            ref cors_mw_a = chain._cors.value()
            cors_mw_a.after(req, response, ctx)
    except e:
        # ATTRIBUTED via the one chain-level path (mapper or mapper-less).
        response = chain.map_chain_error(
            e, req.method.name(), String(req.path), trace_header_of(req)
        )
        short_circuited = True
        ctx.short_circuit = True
        # Best-effort after-chain.
        try:
            if user_before_ran:
                user_mw.after(req, response, ctx)
        except e2:
            _ = e2
        try:
            if chain._logging:
                ref lg2 = chain._logging.value()
                lg2.after(req, response, ctx)
        except e2:
            _ = e2
        try:
            if chain._tracing:
                ref tr2 = chain._tracing.value()
                tr2.after(req, response, ctx)
        except e2:
            _ = e2
        try:
            if chain._cors:
                ref cors2 = chain._cors.value()
                cors2.after(req, response, ctx)
        except e2:
            _ = e2

    return ChainOutcome(response=response^, short_circuited=short_circuited)


# =============================================================================
# §4 — Convenience: run_chain (legacy alias for run_with_canned).
# =============================================================================


def run_chain(
    mut chain: MiddlewareChain,
    var req: HttpRequest,
    var canned: HttpResponse,
) -> ChainOutcome:
    """Free-fn alias for `chain.run_with_canned(req, canned)`.

    Useful for sites that have a `MiddlewareChain` by `mut ref` but
    can't easily call the method form (e.g., in a chain of free fns).
    """
    return _drive_chain_canned(chain, req^, canned^)
