# =============================================================================
# src/komira_http_server/routing/route.mojo — the Mojo-native route pack.
# =============================================================================
#
# The idiomatic route-registration surface for `komira_http`. Every app today
# conforms to `RequestDispatcher` and HAND-ROLLS an `if req.method == … and
# req.path == …` chain inside `dispatch[RT]` — even though a real match table
# (`Router`, `routing/router.mojo`) already exists but is never called on the
# plaintext serve path. This file WIRES that table into a comptime variadic
# route pack so a dispatcher is DECLARED as a list of route structs instead of
# a hand-rolled if-chain.
#
# THE SHAPE (the comptime variadic pack, NOT a fn-ptr
# table). A route is a concrete, zero/small `Route` struct:
#     comptime METHOD: HttpMethod          — the verb it answers
#     comptime PATTERN: StaticString       — its route pattern ("/users/:id")
#     handle[RT](mut self, mut reactor, var req) raises -> HttpResponse
# and a dispatcher is `AppRouter[R0, R1, R2, …]` — a variadic `*Routes: Route`
# pack that CONFORMS to the EXISTING `RequestDispatcher` trait, so it drops into
# `server.serve_one_iteration_dispatch[D, RT]` with ZERO edits to server.mojo or
# any trait. The routes are stored as `Tuple[*Routes]` (the blessed
# variadic idiom — same as `HashAggTable[KB, *Aggs]` /
# `JoinBuildTable[KB, *Payload]`), and a `RouteTable` (the existing `Router`
# match table, imported under an alias to dodge the name collision) is built
# ONCE at ctor off the TYPE pack.
#
# WHY THE PACK (over a stored fn-ptr table): only the pack (a) PRESERVES the
# `[RT]` generic — the trait method stays `[RT]`-parametric, which a stored
# `def(...) thin` fn-ptr CANNOT carry (dispatch.mojo:189/244); (b) has ZERO
# stale-pointer / wildcard / UnsafePointer / fn-ptr risk (Tuple[*Pack] of concrete
# Movable structs — no byte-slab, no wildcard origin, no raw pointer crosses any
# boundary); (c) turns an unregistered / duplicate route into a COMPILE error,
# not a runtime 500.
#
# ENCAPSULATION: no UnsafePointer crosses any boundary; no wildcard origin; no
# `unsafe_from_address`. The route structs are value types (HttpRequest moved
# in, HttpResponse moved out). pointer-free: nothing here is stored in a
# byte-slab; the pack is a plain `Tuple[*Routes]` of concrete structs.
#
# def-based, Mojo 1.0.0b2. `def` carries implicit `raises`.
# =============================================================================

from std.collections.dict import Dict

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher

# Import the existing match table under an alias — the new dispatcher struct is
# `AppRouter` (NOT `Router`), but it FIELDS a `Router` match table, and two
# `Router` types in one scope collide. The alias keeps the match table's name
# distinct at every use site (`self._table: RouteTable`).
from komira_http_server.routing.router import Router as RouteTable


# =============================================================================
# §1 — trait Route — one concrete route (verb + pattern + handler).
# =============================================================================


trait Route(Movable, Deinitable):
    """One route in a `AppRouter[*Routes]` pack.

    A conformer is a concrete zero/small struct that declares the (METHOD,
    PATTERN) it answers as comptime members, plus a `[RT]`-generic `handle`
    that produces the `HttpResponse`. Per-route state (a store handle, a
    config value) lives as ORDINARY struct fields — the pack stores the routes
    by value in a `Tuple[*Routes]`, so each route's fields are real typed
    storage, not erased.

      comptime METHOD:  the verb this route answers (`HttpMethod.get()` …).
      comptime PATTERN: the route pattern — an exact path ("/healthz"), a
                        `:param` capture ("/users/:id"), or a trailing `*`
                        wildcard ("/api/*"). Same grammar as `Router.add`.
      handle[RT]:       the per-request leaf. Receives the SERVER'S reactor
                        (threaded per-call — never stored) so an async handler
                        can PARK on it, and the parsed `HttpRequest` (moved in;
                        `req.path_params` already filled by the match). Returns
                        the `HttpResponse`; a raise becomes a 500 at the serve
                        round (the dispatcher maps its own domain errors).

    `PATTERN` is a `StaticString` (the comptime string type — matches
    `db_storable.mojo`'s `comptime TABLE: StaticString`). `AppRouter`'s ctor
    converts it once via `String(Self.Routes[i].PATTERN)` when it registers the
    route into the match table.
    """

    comptime METHOD: HttpMethod
    comptime PATTERN: StaticString

    def handle[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        ...


# =============================================================================
# §2 — RouteBlock[*Routes] — the single-pack ctor wrapper.
# =============================================================================
#
# A function parameter list (incl. a ctor's) may carry only ONE `*` marker on
# Mojo 1.0.0b2. `AppRouter`'s ctor needs to accept the variadic route pack,
# so the routes are pre-wrapped in this one-pack block. `Optional`-wraps the
# inner `Tuple[*Routes]` so it lifts out via `.take()` — NEVER via
# `UnsafePointer.take_pointee`, which is a banned partial move. This is the
# one-pack payload-block pattern for variadic constructors.


struct RouteBlock[*Routes: Route](Movable):
    """Single-pack ctor wrapper carrying the variadic route pack through
    `AppRouter`'s ctor (the one-`*`-per-param-list rule). Build it from the
    concrete route structs: `RouteBlock[A, B, C](A(), B(), C())`."""

    var _routes: Optional[Tuple[*Self.Routes]]

    def __init__(out self, var *routes: *Self.Routes):
        self._routes = Tuple(*routes^)

    @always_inline
    def take(mut self) -> Tuple[*Self.Routes]:
        """Lift the route Tuple out (one-shot consume — Optional.take, NOT
        UnsafePointer.take_pointee)."""
        return self._routes.take()


# =============================================================================
# §3 — AppRouter[*Routes] — the variadic pack dispatcher.
# =============================================================================


struct AppRouter[*Routes: Route](Movable, RequestDispatcher):
    """A `RequestDispatcher` declared as a comptime pack of `Route` structs.

    Drops into `server.serve_one_iteration_dispatch[D, RT]` unchanged (it
    conforms to the existing `RequestDispatcher` trait). Registration is by
    TYPE — `AppRouter[HealthzRoute, EchoGetRoute, EchoPostRoute]` — so an
    unregistered or duplicate route is a compile error, not a runtime 500.

    Storage:
      _routes: `Tuple[*Routes]` — the route structs by value (per-route state
               is real typed storage). The blessed variadic idiom.
      _table:  `RouteTable` (the existing `Router` match table) — built ONCE at
               ctor off the TYPE pack; owns the (method, pattern) → pack-index
               lookup + the 404-vs-405 disposition.

    Construct via the two-arg form (routes + a `RouteBlock`) OR the
    `AppRouter[…].build(RouteBlock[…](…))` factory below — both go through
    the same ctor. The two-arg ctor exists so the routes' comptime members are
    read off `Self.Routes[i]` (the TYPE pack) while the runtime values ride in
    via the block.
    """

    var _routes: Tuple[*Self.Routes]
    var _table: RouteTable

    def __init__(out self, var block: RouteBlock[*Self.Routes]) raises:
        """Build the pack + the match table. The table is registered off the
        TYPE pack: for each pack index `i`, read `Self.Routes[i].METHOD` /
        `Self.Routes[i].PATTERN` (comptime members are per-TYPE — reading them
        off a runtime tuple VALUE gives `can't access 'PATTERN' in
        non-parameter`, so they MUST be read off the type-pack element) and
        register `(METHOD, PATTERN) -> i`. A duplicate (method, pattern) raises
        out of `RouteTable.add` — a genuine registration error surfaced at
        construction, not silently at request time."""
        self._routes = block.take()
        self._table = RouteTable()
        comptime for i in range(Self.Routes.__len__()):
            self._table.add(
                Self.Routes[i].METHOD,
                String(Self.Routes[i].PATTERN),
                i,
            )

    @staticmethod
    def build(var block: RouteBlock[*Self.Routes]) raises -> Self:
        """Factory: `AppRouter[A, B, C].build(RouteBlock[A, B, C](A(), B(),
        C()))`. Same as the ctor; provided so a caller can spell the build in
        one expression at a `comptime`/`var` site."""
        return Self(block^)

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        """PASS-1 match (borrow) → PASS-2 run the matched route's `handle[RT]`.

        The match fills `req.path_params` (a `:param` route's captures land
        there before `handle` runs). On no match, `has_path_match` disposes
        404 (no path matched) vs 405 (path matched, wrong verb) — the pack gets
        405 for a wrong verb on a known path FOR FREE (e.g. PUT /healthz).

        MOVE-ONCE across the comptime-for unroll: `comptime for` UNROLLS, so a
        bare `req^` inside it would emit `req^` textually on every arm →
        `use of uninitialized value 'req'`. Instead `req` is stashed in an
        `Optional` up front; the matched arm does `slot.take()` (leaving the
        Optional in `None` state for every other arm) so the borrow checker
        sees exactly one move. (`Optional.take()`, NOT
        `UnsafePointer.take_pointee`, a banned partial move.)"""
        # PASS 1 — resolve the pack index (borrow; fills req.path_params).
        var hid = self._table.match_route(req.method, req.path, req.path_params)
        if not hid:
            # No (method, path) match. Path matched but verb didn't -> 405
            # with the path's methods in `Allow`; otherwise no such path -> 404.
            var allowed = self._table.allowed_methods(req.path)
            if len(allowed) != 0:
                return HttpResponse.method_not_allowed(allowed)
            return HttpResponse.not_found()

        # PASS 2 — run exactly the matched route's handle[RT]. Stash req in an
        # Optional so the single move survives the comptime-for unroll.
        var slot = Optional[HttpRequest](req^)
        var resp = HttpResponse.internal_error()
        comptime for i in range(Self.Routes.__len__()):
            if i == hid.value() and slot:
                resp = self._routes[i].handle[RT](reactor, slot.take())
        return resp^

    @staticmethod
    @always_inline
    def route_count() -> Int:
        """Comptime count of routes in the pack."""
        return Self.Routes.__len__()
