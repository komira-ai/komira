# =============================================================================
# src/komira_http_server/middleware/middleware.mojo — Middleware trait + Context
# =============================================================================
#
# The Middleware trait is the extension shape. Mojo 1.0 cannot express a
# `next: Next` callable type cleanly (no impl Trait / HKT), so the shape used
# by Express, fastify and hono is adopted: `before(req, ctx)` may
# short-circuit by returning `Some(response)`; otherwise the chain proceeds to
# the next middleware and ultimately the handler. After the handler returns,
# `after(req, resp, ctx)` runs in REVERSE order for response post-processing.
#
# Errors propagate via `raises`. The chain's `error_mapper` (an instance of
# ErrorMappingMiddleware) catches any uncaught Mojo Error and maps it to a 500
# with a sanitized body.
#
# `RequestContext` carries per-request state threaded through the chain:
#   - start_ns:   monotonic clock at request start (latency calculation)
#   - span_id:    opaque span identifier from TracingMiddleware (0 if no tracer)
#   - principal:  who the request was authenticated as, if an embedder's
#                 middleware decided so: the scheme that authenticated it
#                 (`jwt` or `session`), an opaque subject string, a string
#                 claims map, and optionally the credential the request
#                 presented (redacted, not printable). The library gives the
#                 subject and the claims no meaning.
#   - attributes: a string map any middleware may write and any later
#                 middleware or the dispatcher may read (a request id,
#                 an account label, a feature flag, ...).
#
# This library ships NO notion of who the caller is or what they may do. An
# embedder that needs identity or authorization writes a `Middleware` that
# fills `ctx.principal` / `ctx.attributes`, and a dispatcher that reads them.
#
# No UnsafePointer in public signatures. No wildcard origin. Value semantics.
# =============================================================================

from komira_http_core.codec.types import HttpRequest, HttpResponse


# =============================================================================
# §0 — Claims: an ordered string-to-string map.
# =============================================================================


struct Claims(Copyable, Movable, Deinitable):
    """A small ordered string map: the opaque key/value payload of a
    `Principal` and of `RequestContext.attributes`.

    Two parallel lists, linear lookup: it holds a handful of entries per
    request, an empty one allocates nothing, and it needs no hashing. `set`
    replaces an existing key in place, so insertion order is the order keys
    were FIRST set.
    """

    var _keys: List[String]
    var _values: List[String]

    def __init__(out self):
        self._keys = List[String]()
        self._values = List[String]()

    def set(mut self, key: String, value: String):
        """Set `key` to `value`, replacing any earlier value for `key`."""
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                self._values[i] = value
                return
        self._keys.append(key)
        self._values.append(value)

    def get(self, key: String) -> Optional[String]:
        """The value for `key`, or `None` when it was never set."""
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return Optional[String](self._values[i])
        return Optional[String]()

    def has(self, key: String) -> Bool:
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return True
        return False

    def len(self) -> Int:
        return len(self._keys)

    def key_at(self, idx: Int) -> String:
        """The `idx`-th key in insertion order. Caller keeps `idx` in range."""
        return self._keys[idx]

    def value_at(self, idx: Int) -> String:
        """The `idx`-th value in insertion order. Caller keeps `idx` in range."""
        return self._values[idx]


# =============================================================================
# §1 — Principal: the authenticated identity.
# =============================================================================

# The schemes a `Principal` may carry. `jwt`: a verified bearer JWT.
# `session`: an embedder's own session credential. The constructor refuses any
# other value, so a new scheme is a change to this list.
comptime PRINCIPAL_SCHEME_JWT = "jwt"
comptime PRINCIPAL_SCHEME_SESSION = "session"


struct PresentedCredential(Copyable, Movable, Deinitable):
    """The credential a request presented (for a bearer JWT, the token), kept
    so a later step can forward it (for example to a remote authorization
    service).

    It is deliberately not `Writable`, the trait every formatting path goes
    through, so nothing prints it. `redacted()` is the text to log in its place; `expose()` is the
    only public way to read the value. `_value` is private by convention
    only: Mojo does not enforce the leading underscore.
    """

    var _value: String

    def __init__(out self, var value: String):
        self._value = value^

    def expose(self) -> String:
        """The credential itself. Call only to forward it to the party it was
        issued for; never log or store the result."""
        return self._value.copy()

    def redacted(self) -> String:
        """A fixed text naming the type, with nothing of the value in it (not
        even its length)."""
        return String("PresentedCredential(<redacted>)")


struct Principal(Copyable, Movable, Deinitable):
    """Who a request was authenticated as: the `scheme` that authenticated it,
    a `subject` string, a `claims` map, and optionally the credential the
    request `presented`.

    `scheme` is `PRINCIPAL_SCHEME_JWT` or `PRINCIPAL_SCHEME_SESSION`; the
    constructor refuses anything else, and a reader that expects one scheme
    refuses the other. What a subject names (a user, a service, a device) and
    what the claims mean (scopes, roles, an expiry) is the embedder's
    vocabulary, attached by the embedder's middleware and read back by the
    embedder's dispatcher. This library never inspects either.
    """

    var scheme: String
    var subject: String
    var claims: Claims
    var presented: Optional[PresentedCredential]

    def __init__(out self, *, var scheme: String, var subject: String) raises:
        _check_scheme(scheme)
        self.scheme = scheme^
        self.subject = subject^
        self.claims = Claims()
        self.presented = Optional[PresentedCredential]()

    def __init__(
        out self, *, var scheme: String, var subject: String, var claims: Claims
    ) raises:
        _check_scheme(scheme)
        self.scheme = scheme^
        self.subject = subject^
        self.claims = claims^
        self.presented = Optional[PresentedCredential]()

    def with_claim(var self, key: String, value: String) -> Principal:
        """Return this principal with `key` set to `value` in its claims."""
        self.claims.set(key, value)
        return self^

    def with_presented(var self, var credential: PresentedCredential) -> Principal:
        """Return this principal carrying `credential` as the one it presented,
        replacing any earlier one."""
        self.presented = Optional[PresentedCredential](credential^)
        return self^


def _check_scheme(scheme: String) raises:
    """Raises unless `scheme` is one of the `PRINCIPAL_SCHEME_*` values."""
    if scheme == PRINCIPAL_SCHEME_JWT or scheme == PRINCIPAL_SCHEME_SESSION:
        return
    raise Error(
        'Principal: unknown scheme "'
        + scheme
        + '"; the schemes are "jwt" and "session"'
    )


# =============================================================================
# §2 — RequestContext: per-request threaded state.
# =============================================================================


@fieldwise_init
struct RequestContext(Copyable, Movable, Deinitable):
    """Per-request state threaded through the middleware chain.

    Fields:
      start_ns      — request start (monotonic ns); set by
                      LoggingMiddleware.before. Used in after() for latency.
      span_id       — opaque span identifier from the tracer; 0 if no tracer
                      is configured OR if TracingMiddleware was not enabled.
      worker_id     — worker / pthread id; threaded through for
                      komira_trace.Tracer.start_span which is per-worker.
                      single-threaded baseline: 0.
      short_circuit — set by the chain driver when a `before` returns
                      Some(response) so `after` knows the response did NOT
                      come from a handler — affects which post-processors run
                      (e.g. CORS still adds headers).
      principal     — the authenticated identity, set by an embedder's
                      authentication middleware; `None` until then (and on
                      every unauthenticated route).
      attributes    — free-form per-request string attributes. Middleware
                      write them in `before`; later middleware, `after` and
                      the dispatcher read them.
    """

    var start_ns: UInt64
    var span_id: UInt64
    var worker_id: Int
    var short_circuit: Bool
    var principal: Optional[Principal]
    var attributes: Claims

    @staticmethod
    def new() -> RequestContext:
        return RequestContext(
            start_ns=UInt64(0),
            span_id=UInt64(0),
            worker_id=0,
            short_circuit=False,
            principal=Optional[Principal](),
            attributes=Claims(),
        )

    @staticmethod
    def for_worker(worker_id: Int) -> RequestContext:
        return RequestContext(
            start_ns=UInt64(0),
            span_id=UInt64(0),
            worker_id=worker_id,
            short_circuit=False,
            principal=Optional[Principal](),
            attributes=Claims(),
        )


# =============================================================================
# §3 — Middleware trait (the extension shape).
# =============================================================================
# The `before` / `after` pair is the Mojo 1.0.0b1
# workaround for the absent `Service<Request> = Layer<Request, Response>`
# higher-kinded type. Express / fastify / hono all use this shape.
#
# Trait surface:
#   * before — invoked BEFORE the next middleware / handler. Returns
#              Some(response) to short-circuit; None to continue. May
#              `raises` — exception propagates UP through the chain.
#   * after  — invoked AFTER the inner chain returns. Receives the
#              borrowed request + the mut response so it can rewrite
#              headers / body (e.g. compression, CORS). May `raises`.
#
# Ships the trait declaration + 4 concrete builtins composed in
# `MiddlewareChain`. User-extension via the trait is forward-compatible;
# the chain's parametric extension hook is filled in separately.


trait Middleware(Movable, Deinitable):
    """Ordered request/response interceptor.

    Conform to this trait to plug a custom interceptor into a
    MiddlewareChain. The 4 builtins (Cors / Tracing / Logging /
    ErrorMapping) are concrete-typed for performance + Mojo 1.0.0b1
    compatibility (no `List[OwnedPointer[Middleware]]` dispatch); user
    extensions plug through a single parametric chain slot.

    Lifecycle:
      1. before(req, ctx) — may short-circuit by returning Some(response).
      2. (next middleware / handler) — runs only if before returned None.
      3. after(req, resp, ctx) — runs UNCONDITIONALLY in reverse order.

    Short-circuit semantics: returning Some(response) from before()
    skips ALL subsequent middlewares AND the handler. The after()
    chain then runs in reverse on that short-circuit response. This
    lets e.g. an authentication middleware return 401 while still allowing
    LoggingMiddleware to log the rejection.

    Error semantics: a `raises` exception from any layer propagates up
    until ErrorMappingMiddleware (which conventionally sits at the
    outermost / first-registered position) catches it and converts to
    a 500.
    """

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        ...

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        ...
