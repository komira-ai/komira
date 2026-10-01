# =============================================================================
# src/komira_http/middleware/cors.mojo — CORS preflight + response headers
# =============================================================================
#
# L3.-
# MIDDLEWARE-ROUTING.
#
# Behavior:
#   - Preflight (OPTIONS with Access-Control-Request-Method): short-
#     circuits via `before` returning a 204 No Content + ACAO/ACAM/ACAH
#     headers. The handler is NOT invoked.
#   - Simple request (GET / POST / ...): `before` is no-op; `after`
#     adds Access-Control-Allow-Origin (and friends) to the response.
#
# Sane defaults:
#   Access-Control-Allow-Origin: *
#   Access-Control-Allow-Methods: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS
#   Access-Control-Allow-Headers: Content-Type, Authorization, X-Request-Id
#   Access-Control-Max-Age: 86400  (1 day)
#
# Constructors:
#   CorsMiddleware.permissive()  — sane defaults (wildcard origin, common methods)
#   CorsMiddleware.strict(...)   — user-locked-down (specific origin / methods)
#
# Pointer discipline: pure value semantics. No UnsafePointer.
# =============================================================================

from komira_http.codec.types import (
    HTTP_METHOD_OPTIONS,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http.middleware.middleware import RequestContext


# =============================================================================
# §1 — CorsConfig.
# =============================================================================


@fieldwise_init
struct CorsConfig(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """CORS configuration knobs.

    Fields:
      allow_origin   — Access-Control-Allow-Origin value (e.g. "*" or
                       "https://example.com"). Empty = don't emit header.
      allow_methods  — Access-Control-Allow-Methods value (comma-joined
                       method list).
      allow_headers  — Access-Control-Allow-Headers value (comma-joined
                       header list).
      max_age_seconds — Access-Control-Max-Age value (seconds the
                        preflight response is cacheable).
      preflight_status — Status to return on preflight short-circuit
                        (204 No Content by default).
    """

    var allow_origin: String
    var allow_methods: String
    var allow_headers: String
    var max_age_seconds: Int
    var preflight_status: Int32

    @staticmethod
    def permissive() -> CorsConfig:
        return CorsConfig(
            allow_origin=String("*"),
            allow_methods=String("GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS"),
            allow_headers=String("Content-Type, Authorization, X-Request-Id"),
            max_age_seconds=86400,
            preflight_status=Int32(204),
        )


# =============================================================================
# §2 — CorsMiddleware.
# =============================================================================


struct CorsMiddleware(Movable, Deinitable):
    """Origin / Methods / Headers handling.

    On preflight (OPTIONS + Access-Control-Request-Method): short-
    circuits with the configured preflight_status (default 204).
    On simple request: `after` adds the Access-Control-Allow-* headers
    to the response.
    """

    var config: CorsConfig

    def __init__(out self, var config: CorsConfig):
        self.config = config^

    @staticmethod
    def permissive() -> CorsMiddleware:
        return CorsMiddleware(CorsConfig.permissive())

    @staticmethod
    def with_config(var config: CorsConfig) -> CorsMiddleware:
        return CorsMiddleware(config^)

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        """Detect preflight; short-circuit with 204 + ACAO/ACAM/ACAH.

        Preflight per RFC: OPTIONS request with both Origin AND
        Access-Control-Request-Method headers. We check the method
        first (cheap) then the request-method header.
        """
        if req.method.code != HTTP_METHOD_OPTIONS:
            return Optional[HttpResponse]()
        # Is this a CORS preflight? Look for the request-method header.
        var has_acrm = req.headers.__contains__(
            String("access-control-request-method")
        )
        if not has_acrm:
            # Plain OPTIONS, not a preflight; pass through.
            return Optional[HttpResponse]()

        # Preflight: build the 204 response with CORS headers.
        var resp = HttpResponse(status=self.config.preflight_status)
        if self.config.allow_origin.byte_length() > 0:
            resp.headers[String("access-control-allow-origin")] = String(
                self.config.allow_origin
            )
        if self.config.allow_methods.byte_length() > 0:
            resp.headers[String("access-control-allow-methods")] = String(
                self.config.allow_methods
            )
        if self.config.allow_headers.byte_length() > 0:
            resp.headers[String("access-control-allow-headers")] = String(
                self.config.allow_headers
            )
        resp.headers[String("access-control-max-age")] = String(
            self.config.max_age_seconds
        )
        resp.headers[String("content-length")] = String("0")
        return Optional[HttpResponse](resp^)

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        """Add Access-Control-Allow-Origin (and friends) to a simple
        request response.

        Skipped if the response already carries an ACAO header
        (which happens on the preflight short-circuit path: `before`
        already populated it).

        The `after` leg's response-side decoration ignores `req` / `ctx`
        entirely (a simple-request CORS response is a fixed-origin header,
        not request-derived), so the actual header logic lives in the
        request-free `decorate_response` — the ONE source of truth reused
        by both the chained serve path AND the suspendable delivered-
        response seam (`KomiraSuspendableHandler.step`)."""
        self.decorate_response(resp)

    def decorate_response(self, mut resp: HttpResponse):
        """Apply the simple-request CORS response headers to `resp` — the
        request-free response-side decoration the `after` leg performs.

        Idempotent: a response that already carries an ACAO header (e.g.
        the chained sync path already ran `after`, or a preflight short-
        circuit populated it) is left untouched. This idempotency is what
        lets the suspendable seam decorate EVERY delivered response without
        double-writing the header on the sync (already-chained) path.

        Adds ONLY Access-Control-Allow-Origin on a simple request: ACAM /
        ACAH are preflight-only per the CORS spec (the browser cache serves
        both from the preflight-cached response)."""
        if resp.headers.__contains__(
            String("access-control-allow-origin")
        ):
            return
        if self.config.allow_origin.byte_length() > 0:
            resp.headers[String("access-control-allow-origin")] = String(
                self.config.allow_origin
            )
