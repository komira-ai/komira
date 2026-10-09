# =============================================================================
# src/komira_http_server/routing/compose.mojo — several route sets, one server.
# =============================================================================
#
# A server takes one `RequestDispatcher`. A dispatcher that answers a fixed set
# of routes (a generated `<Service>Routes`, say) answers 404 for every path
# outside its set, so two of them cannot share a server by trying one and then
# the other on its status: a 404 or 405 may be the handler's own answer.
#
# `RoutedDispatcher` adds the two questions a composite needs answered without
# dispatching: does a route match (method, path), and which methods have a
# route matching path. `ComposedRoutes[*Services]` asks its services in order,
# dispatches to the first with a route for (method, path), and otherwise
# answers 405 with `Allow` naming the methods every service has for the path,
# or 404 when none has the path. It is itself a `RoutedDispatcher`, so a
# composite nests.
#
# Pointer-free: the services are stored by value in a `Tuple[*Services]` (the
# same variadic-pack idiom as `AppRouter`); the request moves into exactly one
# service through `Optional.take()`.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher


trait RoutedDispatcher(RequestDispatcher):
    """A `RequestDispatcher` over a fixed route set that can say, without
    dispatching, whether it has a route for a request."""

    def has_route(self, method: HttpMethod, path: String) -> Bool:
        """True iff a route matches `method` and `path`: `dispatch` would run
        a route rather than answer 404 or 405."""
        ...

    def allowed_methods(self, path: String, mut methods: List[HttpMethod]):
        """Append the method of every route matching `path` (any order;
        a repeat is harmless)."""
        ...


struct ComposedRoutes[*Services: RoutedDispatcher](Movable, RoutedDispatcher):
    """Several `RoutedDispatcher`s served as one: the first service (in
    parameter order) with a route for the request's method and path
    dispatches it; otherwise 405 with `Allow` when some service has the path
    under another method, else 404.

        var app = ComposedRoutes[BookServiceRoutes[B], ShelfServiceRoutes[S]](
            BookServiceRoutes[B](books^), ShelfServiceRoutes[S](shelves^)
        )

    A service's own 404 or 405 (a handler's answer) is returned as is; it
    never moves the request on to the next service."""

    var services: Tuple[*Self.Services]

    def __init__(out self, var *services: *Self.Services):
        self.services = Tuple(*services^)

    def has_route(self, method: HttpMethod, path: String) -> Bool:
        var found = False
        comptime for i in range(Self.Services.__len__()):
            if not found and self.services[i].has_route(method, path):
                found = True
        return found

    def allowed_methods(self, path: String, mut methods: List[HttpMethod]):
        comptime for i in range(Self.Services.__len__()):
            self.services[i].allowed_methods(path, methods)

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        """Each service's route set is matched once to choose it and again by
        its own `dispatch`: two walks of the chosen service's routes."""
        var chosen = -1
        comptime for i in range(Self.Services.__len__()):
            if chosen < 0 and self.services[i].has_route(req.method, req.path):
                chosen = i
        if chosen < 0:
            var allowed = List[HttpMethod]()
            self.allowed_methods(req.path, allowed)
            if len(allowed) != 0:
                return HttpResponse.method_not_allowed(allowed)
            return HttpResponse.not_found()
        # `comptime for` unrolls: the request moves out of the Optional in the
        # one arm that matches (the AppRouter idiom).
        var slot = Optional[HttpRequest](req^)
        var resp = HttpResponse.internal_error()
        comptime for i in range(Self.Services.__len__()):
            if i == chosen and slot:
                resp = self.services[i].dispatch[RT](reactor, slot.take())
        return resp^
