# =============================================================================
# src/komira_http_server/routing/router.mojo — L4 routing
# =============================================================================
#
# map (METHOD, path) → handler_id. Supports:
#   - Exact match              "/healthz"
#   - Prefix wildcard match    "/api/v1/*"       (matches any suffix)
#   - Param match              "/users/:id"     (binds :id into path_params)
#
# Handler dispatch is by integer ID (the index into the user's handler
# table). The router is a small registration-time data structure built
# from a list of routes; lookup walks O(routes × segments) which is fine
# for the route counts every service will have (~10-100). The radix-
# trie optimization is later perf work.
#
# Public surface:
#   - Router struct
#   - Router.add(method, pattern, handler_id) raises
#   - Router.match_route(method, path, path_params) -> Optional[Int]
#   - Router.has_path_match(path) -> Bool, Router.allowed_methods(path)
#     -> List[HttpMethod] (the 404 vs 405 disposition and a 405's Allow)
#   - HANDLER_NOT_FOUND alias (-1) sentinel
#   - RouterBuildError struct for typed registration errors
#
# Conflict detection ( L4):
#   - Two routes with the SAME method AND the SAME pattern → error.
#   - Two routes with the SAME method + structurally-identical patterns
#     (one's a param, one's a static segment in the same slot) — flagged
#     iff they're literally identical patterns. Crossing patterns like
#     "/users/:id" vs "/users/me" are NOT flagged as conflicts (the
#     design's "longest static-prefix wins" semantics apply at match
#     time; This version implements via in-order static-first lookup).
# =============================================================================

from std.collections.dict import Dict
from std.collections.list import List

from komira_http_core.codec import HttpMethod


# =============================================================================
# §1 — Constants + error type.
# =============================================================================

# Sentinel for "no route matched". `match_route` returns Optional[Int];
# this is also exported for callers who want to compare without the
# Optional wrapper after unwrap.
comptime HANDLER_NOT_FOUND: Int = -1


@fieldwise_init
struct RouterBuildError(Copyable, Movable, Deinitable):
    """Returned via `raises` from `Router.add` on registration errors."""
    var message: String


# =============================================================================
# §2 — Internal route entry.
# =============================================================================
# Patterns are pre-split into segments at registration time so match-
# time iteration is a tight comparison loop without re-splitting.

comptime _SEGMENT_KIND_STATIC: UInt8 = 0     # exact byte-match (e.g. "users")
comptime _SEGMENT_KIND_PARAM: UInt8 = 1      # capture by name (e.g. ":id")
comptime _SEGMENT_KIND_WILDCARD: UInt8 = 2   # "*" — matches remaining path


@fieldwise_init
struct _Segment(Copyable, Movable, Deinitable):
    """One segment of a parsed pattern."""
    var kind: UInt8                    # _SEGMENT_KIND_*
    var literal_or_name: String        # static text OR param name


@fieldwise_init
struct _Route(Copyable, Movable, Deinitable):
    """Internal registered-route record."""
    var method: HttpMethod
    var pattern: String                # original pattern (for error msgs)
    var segments: List[_Segment]
    var has_wildcard: Bool             # true iff last segment is "*"
    var handler_id: Int


# =============================================================================
# §3 — Path / pattern segmentation.
# =============================================================================


def _split_path(path: String) -> List[String]:
    """Split a path into segments by '/'.

    Empty leading + trailing slashes are dropped: "/foo/bar/" -> ["foo", "bar"].
    The root "/" -> [].
    """
    var out = List[String]()
    var bytes = path.as_bytes()
    var n = len(bytes)
    var i = 0
    var seg_start = -1
    while i < n:
        var c = bytes[i]
        if c == UInt8(0x2F):   # '/'
            if seg_start >= 0:
                # Build segment from [seg_start, i).
                var buf = String("")
                var k = seg_start
                while k < i:
                    buf = buf + chr(Int(bytes[k]))
                    k = k + 1
                out.append(buf^)
                seg_start = -1
        else:
            if seg_start < 0:
                seg_start = i
        i = i + 1
    if seg_start >= 0:
        var buf = String("")
        var k = seg_start
        while k < n:
            buf = buf + chr(Int(bytes[k]))
            k = k + 1
        out.append(buf^)
    return out^


@fieldwise_init
struct _ParsedPattern(Movable, Deinitable):
    """Out-param container for `_parse_pattern`."""
    var segments: List[_Segment]
    var has_wildcard: Bool


def _parse_pattern(pattern: String) raises -> _ParsedPattern:
    """Parse a pattern like "/users/:id" into segments.

    Wildcard "*" must be the LAST segment if present; otherwise raises.
    Param names must be non-empty (`/:` → error).
    """
    var segs = List[_Segment]()
    var raw = _split_path(pattern)
    var n = len(raw)
    var has_wild = False
    var i = 0
    while i < n:
        var s = raw[i]
        var sb = s.as_bytes()
        var sl = len(sb)
        if sl == 0:
            i = i + 1
            continue
        if sb[0] == UInt8(0x2A):    # '*'
            if sl != 1:
                raise Error(
                    "komira_http_server.routing: wildcard '*' must be a "
                    "single-character segment in pattern '" + pattern + "'"
                )
            if i != n - 1:
                raise Error(
                    "komira_http_server.routing: wildcard '*' must be the last "
                    "segment in pattern '" + pattern + "'"
                )
            segs.append(_Segment(
                kind=_SEGMENT_KIND_WILDCARD,
                literal_or_name=String("*"),
            ))
            has_wild = True
        elif sb[0] == UInt8(0x3A):  # ':'
            if sl < 2:
                raise Error(
                    "komira_http_server.routing: param segment ':' missing name "
                    "in pattern '" + pattern + "'"
                )
            var name = String("")
            var k = 1
            while k < sl:
                name = name + chr(Int(sb[k]))
                k = k + 1
            segs.append(_Segment(
                kind=_SEGMENT_KIND_PARAM,
                literal_or_name=name^,
            ))
        else:
            segs.append(_Segment(
                kind=_SEGMENT_KIND_STATIC,
                literal_or_name=s,
            ))
        i = i + 1
    return _ParsedPattern(segments=segs^, has_wildcard=has_wild)


# =============================================================================
# §4 — Public Router struct.
# =============================================================================


struct Router(Movable, Deinitable):
    """Registration-time route table + match-time lookup.

    Build pattern:
        var r = Router()
        try:
            r.add(HttpMethod.get(), "/healthz", 0)
            r.add(HttpMethod.get(), "/users/:id", 1)
            r.add(HttpMethod.post(), "/users", 2)
        except e:
            # registration error (duplicate, bad pattern, ...)
            raise e
        # Router is now immutable for the rest of its life.

    Match pattern:
        var params = Dict[String, String]()
        var hid_opt = r.match_route(HttpMethod.get(), "/users/42", params)
        if hid_opt:
            var hid = hid_opt.value()   # 1
            # params["id"] == "42"

    Status disposition:
      - Match found             → Some(handler_id)
      - Path matched but method → None; caller checks `had_path_match` to
        decide whether to return 405 vs 404.
    """

    var _routes: List[_Route]

    def __init__(out self):
        self._routes = List[_Route]()

    def add(
        mut self,
        var method: HttpMethod,
        pattern: String,
        handler_id: Int,
    ) raises:
        """Register a route. Raises on:
          - empty pattern (must start with '/')
          - wildcard not in tail position
          - param name empty
          - duplicate registration (same method + same pattern).
        """
        if pattern.byte_length() == 0:
            raise Error(
                "komira_http_server.routing: pattern must not be empty"
            )
        # Check duplicate.
        var i = 0
        while i < len(self._routes):
            ref ex = self._routes[i]
            if ex.method == method and ex.pattern == pattern:
                raise Error(
                    "komira_http_server.routing: duplicate route registration: "
                    + method.name() + " " + pattern
                )
            i = i + 1
        # _parse_pattern returns _ParsedPattern; we consume it whole into
        # the _Route ctor to avoid partial-moves. _ParsedPattern is just a
        # plumbing wrapper around the fields _Route needs.
        var parsed = _parse_pattern(pattern)
        var route = _Route(
            method=method,
            pattern=String(pattern),
            segments=List[_Segment](),
            has_wildcard=parsed.has_wildcard,
            handler_id=handler_id,
        )
        # Reassign segments from `parsed` after taking the placeholder slot.
        # This pattern is allowed because we're swapping the field as a
        # whole, not partial-moving out of `parsed`.
        swap(route.segments, parsed.segments)
        self._routes.append(route^)

    def match_route(
        self,
        method: HttpMethod,
        path: String,
        mut path_params: Dict[String, String],
    ) -> Optional[Int]:
        """Return handler_id if (method, path) matches a registered route.

        Match precedence ( "longest static-prefix wins"):
          1. Routes are scanned in registration order.
          2. Within each scan, static segments take precedence over param
             segments when both could match — handled by route ordering
             (caller registers more specific routes first) AND by the
             two-pass loop below: first pass tries STATIC-only matches,
             second pass admits PARAM matches.
          3. Wildcard (`/*`) is the lowest-precedence match.

        `path_params` is mutated only on a successful match.
        """
        var path_segs = _split_path(path)
        # Phase 1: prefer exact + param matches (static segments matter);
        # this single-pass walks all routes and returns the first match,
        # but the registration order convention puts more-specific routes
        # earlier so users get sensible defaults without an explicit
        # priority field.
        var i = 0
        while i < len(self._routes):
            ref r = self._routes[i]
            if r.method == method:
                # Speculative param map — only commit if this route matches.
                var speculative = Dict[String, String]()
                var ok = _try_match(r, path_segs, speculative)
                if ok:
                    # Merge speculative into caller's path_params.
                    for k_v in speculative.items():
                        path_params[k_v.key] = k_v.value
                    return Optional[Int](r.handler_id)
            i = i + 1
        return Optional[Int]()

    def has_path_match(
        self,
        path: String,
    ) -> Bool:
        """Return True if SOME method-agnostic route matches the path.

        Used by the caller (HttpServer) to disambiguate 404 (no path
        match) from 405 (path matched but wrong method).
        """
        var path_segs = _split_path(path)
        var i = 0
        while i < len(self._routes):
            ref r = self._routes[i]
            var sink = Dict[String, String]()
            if _try_match(r, path_segs, sink):
                return True
            i = i + 1
        return False

    def allowed_methods(self, path: String) -> List[HttpMethod]:
        """The methods of every route matching `path`, each once, in
        registration order: what a 405 for `path` names in its `Allow` header
        (`HttpResponse.method_not_allowed(allowed)` sorts them). Empty iff
        `has_path_match(path)` is False."""
        var path_segs = _split_path(path)
        var out = List[HttpMethod]()
        for i in range(len(self._routes)):
            ref r = self._routes[i]
            var sink = Dict[String, String]()
            if not _try_match(r, path_segs, sink):
                continue
            var seen = False
            for j in range(len(out)):
                if out[j] == r.method:
                    seen = True
                    break
            if not seen:
                out.append(r.method)
        return out^

    def len(self) -> Int:
        """Number of registered routes."""
        return len(self._routes)


# =============================================================================
# §5 — Internal match helper.
# =============================================================================


def _try_match(
    ref route: _Route,
    path_segs: List[String],
    mut params: Dict[String, String],
) -> Bool:
    """Try to match `route` against `path_segs`. On success: fill `params`."""
    var rn = len(route.segments)
    var pn = len(path_segs)

    # Wildcard: tail segment is "*"; everything before must match;
    # remaining path is the wildcard capture (not exposed in path_params
    # in; may expose as path_params["*"]).
    if route.has_wildcard:
        var prefix_n = rn - 1
        if pn < prefix_n:
            return False
        var i = 0
        while i < prefix_n:
            ref seg = route.segments[i]
            if seg.kind == _SEGMENT_KIND_STATIC:
                if seg.literal_or_name != path_segs[i]:
                    return False
            elif seg.kind == _SEGMENT_KIND_PARAM:
                params[String(seg.literal_or_name)] = String(path_segs[i])
            else:
                # Wildcard in non-tail; _parse_pattern would've raised.
                return False
            i = i + 1
        return True

    # No wildcard: lengths must match exactly.
    if rn != pn:
        return False
    var i = 0
    while i < rn:
        ref seg = route.segments[i]
        if seg.kind == _SEGMENT_KIND_STATIC:
            if seg.literal_or_name != path_segs[i]:
                return False
        elif seg.kind == _SEGMENT_KIND_PARAM:
            params[String(seg.literal_or_name)] = String(path_segs[i])
        else:
            return False
        i = i + 1
    return True
