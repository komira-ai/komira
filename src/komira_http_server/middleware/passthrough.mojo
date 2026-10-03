# =============================================================================
# src/komira_http_server/middleware/passthrough.mojo — the INERT innermost chain
#   slot, for an app whose authorization lives INSIDE its dispatcher.
# =============================================================================
#
# WHY THIS EXISTS. `serve_one_iteration_dispatch_chained[D, M, RT]` takes ONE
# user-`Middleware` `M` at the innermost position — the slot an app usually
# fills with a grant-verifying middleware, whose `before` resolves the
# grant or short-circuits 401. Some apps do NOT authorize there: they
# authorize inside their DISPATCHER (a fail-closed gate per route, or per
# arm of a composite dispatcher). Without this type such an app is
# stuck on the UNCHAINED `serve_one_iteration_dispatch`, which runs no
# middleware at all — so it neither stamps `Access-Control-Allow-Origin` nor
# answers a browser preflight, and no browser can dial it.
#
# `PassthroughMiddleware` is what lets such an app onto the chained seam WITHOUT
# moving its authorization: the chain's CORS leg answers the preflight, the
# innermost slot does nothing, and every non-preflight request reaches the
# dispatcher with its own gate completely unchanged.
#
# ⛔ IT AUTHORIZES NOTHING AND REFUSES NOTHING, AND THAT IS THE WHOLE POINT —
# WHICH MAKES IT THE ONE MIDDLEWARE THAT IS DANGEROUS TO REACH FOR BY DEFAULT.
# It is CORRECT only where the dispatcher it fronts is itself the gate. Putting
# it in front of a dispatcher that expects `ctx.authed_user` to have been
# resolved upstream produces a server that serves every request unauthenticated,
# and it produces it SILENTLY: the chain still runs, the responses still carry
# CORS headers, and nothing anywhere returns 401. If you are reaching for this
# because a real middleware would not compile, the answer is the real middleware.
#
# ⚠ IT IS NOT `Optional[M]` ON THE CHAIN, DELIBERATELY. Making the innermost slot
# optional would mean the chained serve path could be spelled with NO auth leg at
# all, and the difference between "this app gates below" and "somebody forgot the
# auth middleware" would stop being visible in the source. A named type that says
# what it is in its name, declared at the app's own serve site, keeps that visible
# — `grep PassthroughMiddleware` lists every app that gates below.
#
# ENCAPSULATION: zero-field value type. NO UnsafePointer, no wildcard origins,
# nothing heap-allocated.
# =============================================================================

from komira_http_core.codec.types import HttpRequest, HttpResponse
from komira_http_server.middleware.middleware import Middleware, RequestContext


struct PassthroughMiddleware(Movable, Deinitable, Middleware):
    """The INERT innermost `Middleware` — `before` never short-circuits and
    `after` never touches the response.

    For an app whose authorization is performed by its DISPATCHER (a per-route
    gate; a composite's per-arm gates), so the
    chained serve path's auth slot has nothing to do. It exists so those apps
    can run the chain — and therefore CORS — without relocating a single
    authorization decision.

    ⛔ Correct ONLY in front of a self-gating dispatcher. See the module banner.
    """

    def __init__(out self):
        pass

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        """Never short-circuits: `None` always, so the request proceeds to the
        dispatcher — which is where this app's authorization lives.

        `ctx.authed_user` is left UNSET on purpose. A dispatcher fronted by this
        middleware resolves its own principal; an identity synthesized here
        would be an identity nothing verified."""
        _ = req
        _ = ctx
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        """No-op. The CORS / tracing / logging `after` legs still run around it
        (they are OUTER to this slot), so a dispatcher-produced 401 is still
        decorated with `Access-Control-Allow-Origin` on its way out."""
        _ = req
        _ = resp
        _ = ctx
