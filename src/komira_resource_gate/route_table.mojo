# =============================================================================
# route_table.mojo — a declarative (method, path) -> RouteDecision table.
# =============================================================================
#
# `ResourceRouteTable.route` is pure: no store, no clock, no I/O. So "is every
# route gated?" is a unit test over the table.
#
# Rows match in declaration order and the first match wins. Nothing matching
# yields DENY. A row is one of:
#   * `governed(method, pattern, kind, id_capture, action)`: `action` on the
#     resource of `kind` whose id is the path segment captured as
#     `{id_capture}`. The id is the segment's bytes as sent (not
#     percent-decoded);
#   * `on_kind(method, pattern, kind, action)`: `action` on `kind` as a whole
#     (empty id), for a create or a listing. Only this factory makes a
#     kind-wide row: it sets `kind_wide`;
#   * `public_route(method, pattern)`: served without a credential;
#   * `deny_route(method, pattern, reason)`: a recorded refusal. It answers
#     exactly what an undeclared route answers; placed before a broader row it
#     carves one path out of it. `reason` is for the reader and is never sent.
#
# PATTERN GRAMMAR:
#   * a literal segment matches itself;
#   * `{name}` matches one segment and captures it;
#   * `{name}<suffix>` matches one segment that ends in `<suffix>` and is longer
#     than it, and captures the part before the suffix (`{repo}.git` captures
#     `acme` from `acme.git` and does not match `.git`);
#   * a final `*` matches one or more further segments, uncaptured.
# Without `*` the segment counts must be equal, so `/repos/{repo}` does not
# match `/repos/x/settings`. `method` matches the request's method name
# exactly (`GET`).
#
# RAW BYTES, CANONICAL PATHS ONLY. The table matches the path's bytes as
# sent; it percent-decodes nothing. Before any row is tried a path is refused
# unless it starts with `/` and has no empty segment (`//`, a trailing `/`) and
# no dot segment (`.`, `..`, or either spelled with `%2e`). The root `/` has no
# segments. A pattern that is not canonical matches nothing. Any other
# percent-escape is routed as its raw bytes: `/repos/acme/adm%69n` does not
# match the literal `admin`, and `%2F` does not split a segment. So a
# `deny_route` carve-out holds only for an inner dispatcher that routes on the
# same raw bytes; one that percent-decodes before routing can read such a path
# as the carved-out route.
#
# A non-kind-wide governed row whose kind is empty, or whose `id_capture` is
# not captured exactly once by its pattern (an empty `id_capture` never is),
# is malformed: a match on it yields DENY. A kind-wide row with an empty kind
# or a non-empty `id_capture` (only a hand-built row can have one) is
# malformed too.
#
# Encapsulation: value types only; no pointer, no wildcard origin.
# =============================================================================

from komira_authz_api import AuthzAction, AuthzResource

from .route_decision import RouteDecision


struct RouteRule(Copyable, Movable, Deinitable):
    """One row of a `ResourceRouteTable` (module header). Build it with a
    factory: `governed`, `on_kind`, `public_route` or `deny_route`."""

    var method: String
    var pattern: String
    var kind: String
    var id_capture: String
    var action: AuthzAction
    var kind_wide: Bool
    var public: Bool
    var denied: Bool
    var deny_reason: String

    def __init__(
        out self,
        *,
        var method: String,
        var pattern: String,
        var kind: String,
        var id_capture: String,
        var action: AuthzAction,
        kind_wide: Bool,
        public: Bool,
        denied: Bool,
        var deny_reason: String,
    ):
        self.method = method^
        self.pattern = pattern^
        self.kind = kind^
        self.id_capture = id_capture^
        self.action = action^
        self.kind_wide = kind_wide
        self.public = public
        self.denied = denied
        self.deny_reason = deny_reason^

    @staticmethod
    def governed(
        method: String,
        pattern: String,
        kind: String,
        id_capture: String,
        var action: AuthzAction,
    ) -> RouteRule:
        """`action` on the `kind` resource whose id is `{id_capture}`."""
        return RouteRule(
            method=method,
            pattern=pattern,
            kind=kind,
            id_capture=id_capture,
            action=action^,
            kind_wide=False,
            public=False,
            denied=False,
            deny_reason=String(""),
        )

    @staticmethod
    def on_kind(
        method: String, pattern: String, kind: String, var action: AuthzAction
    ) -> RouteRule:
        """`action` on `kind` as a whole: the resource id is empty."""
        return RouteRule(
            method=method,
            pattern=pattern,
            kind=kind,
            id_capture=String(""),
            action=action^,
            kind_wide=True,
            public=False,
            denied=False,
            deny_reason=String(""),
        )

    @staticmethod
    def public_route(method: String, pattern: String) -> RouteRule:
        """A route served without a credential. The only way a route becomes
        public."""
        return RouteRule(
            method=method,
            pattern=pattern,
            kind=String(""),
            id_capture=String(""),
            action=AuthzAction.read(),
            kind_wide=False,
            public=True,
            denied=False,
            deny_reason=String(""),
        )

    @staticmethod
    def deny_route(method: String, pattern: String, reason: String) -> RouteRule:
        """A recorded refusal; `reason` is never sent to a client."""
        return RouteRule(
            method=method,
            pattern=pattern,
            kind=String(""),
            id_capture=String(""),
            action=AuthzAction.admin(),
            kind_wide=False,
            public=False,
            denied=True,
            deny_reason=reason,
        )


comptime _SLASH: UInt8 = 0x2F
comptime _DOT: UInt8 = 0x2E
comptime _PERCENT: UInt8 = 0x25
comptime _OPEN_BRACE: UInt8 = 0x7B
comptime _CLOSE_BRACE: UInt8 = 0x7D


def _dot_count(seg: String) -> Int:
    """The number of dots `seg` spells if it consists only of `.` and `%2e`
    (either case), else -1."""
    var b = seg.as_bytes()
    var n = len(b)
    var dots = 0
    var i = 0
    while i < n:
        if b[i] == _DOT:
            dots += 1
            i += 1
        elif (
            b[i] == _PERCENT
            and i + 2 < n
            and b[i + 1] == UInt8(ord("2"))
            and (b[i + 2] == UInt8(ord("e")) or b[i + 2] == UInt8(ord("E")))
        ):
            dots += 1
            i += 3
        else:
            return -1
    return dots


def _is_dot_segment(seg: String) -> Bool:
    """True iff `seg` is `.` or `..`, spelled with `.` or `%2e`."""
    var dots = _dot_count(seg)
    return dots == 1 or dots == 2


def canonical_segments(path: String) -> Optional[List[String]]:
    """The segments of a canonical path, or `None` (module header): the path
    starts with `/`, and no segment is empty or a dot segment. `/` has
    none."""
    var b = path.as_bytes()
    var n = len(b)
    if n == 0 or b[0] != _SLASH:
        return Optional[List[String]]()
    var segs = List[String]()
    if n == 1:
        return Optional[List[String]](segs^)
    var start = 1
    for i in range(1, n + 1):
        if i == n or b[i] == _SLASH:
            if i == start:
                return Optional[List[String]]()
            var seg = String(path[byte=start:i])
            if _is_dot_segment(seg):
                return Optional[List[String]]()
            segs.append(seg^)
            start = i + 1
    return Optional[List[String]](segs^)


def _capture_close(seg: String) -> Int:
    """The byte index of the `}` closing a capture segment `{name}...` with a
    non-empty name, or -1 when `seg` is not a capture."""
    var b = seg.as_bytes()
    if len(b) == 0 or b[0] != _OPEN_BRACE:
        return -1
    for i in range(1, len(b)):
        if b[i] == _CLOSE_BRACE:
            return i if i > 1 else -1
    return -1


def _match_capture(
    pattern_seg: String, close: Int, actual: String
) -> Optional[String]:
    """The value `{name}<suffix>` captures from `actual`, or `None` when
    `actual` does not end in the suffix or is not longer than it."""
    var suffix = String(pattern_seg[byte = close + 1 :])
    var s = suffix.as_bytes()
    var a = actual.as_bytes()
    if len(s) == 0:
        return Optional[String](actual)
    if len(a) <= len(s):
        return Optional[String]()
    var base = len(a) - len(s)
    for i in range(len(s)):
        if a[base + i] != s[i]:
            return Optional[String]()
    return Optional[String](String(actual[byte=0:base]))


def _decide(rule: RouteRule, names: List[String], values: List[String]) -> RouteDecision:
    """The decision of a row that matched, given its captures."""
    if rule.denied:
        return RouteDecision.deny()
    if rule.public:
        return RouteDecision.public()
    if rule.kind.byte_length() == 0:
        return RouteDecision.deny()
    if rule.kind_wide:
        if rule.id_capture.byte_length() != 0:
            return RouteDecision.deny()
        return RouteDecision.governed(
            rule.action.copy(), AuthzResource(kind=rule.kind, id=String(""))
        )
    # Not kind-wide: an empty `id_capture` matches no capture name (a name is
    # never empty), so `found` stays 0 and the row denies.
    var found = 0
    var id = String("")
    for i in range(len(names)):
        if names[i] == rule.id_capture:
            found += 1
            id = values[i]
    if found != 1:
        return RouteDecision.deny()
    return RouteDecision.governed(
        rule.action.copy(), AuthzResource(kind=rule.kind, id=id^)
    )


struct ResourceRouteTable(Copyable, Movable, Deinitable):
    """An ordered list of `RouteRule`s (module header). `route` is the body a
    `ResourceCatalog` usually returns."""

    var rules: List[RouteRule]

    def __init__(out self, var rules: List[RouteRule]):
        self.rules = rules^

    def route(self, method: String, path: String) -> RouteDecision:
        """The decision of the first row matching (`method`, `path`); DENY
        when none does or when `path` is not canonical."""
        var maybe_segs = canonical_segments(path)
        if not maybe_segs:
            return RouteDecision.deny()
        ref segs = maybe_segs.value()
        for r in range(len(self.rules)):
            ref rule = self.rules[r]
            if rule.method != method:
                continue
            var maybe_pat = canonical_segments(rule.pattern)
            if not maybe_pat:
                continue
            ref pat = maybe_pat.value()
            var wildcard = len(pat) > 0 and pat[len(pat) - 1] == String("*")
            var fixed = len(pat) - 1 if wildcard else len(pat)
            if wildcard:
                if len(segs) <= fixed:
                    continue
            elif len(segs) != fixed:
                continue
            var ok = True
            var names = List[String]()
            var values = List[String]()
            for i in range(fixed):
                var close = _capture_close(pat[i])
                if close < 0:
                    if pat[i] != segs[i]:
                        ok = False
                        break
                    continue
                var got = _match_capture(pat[i], close, segs[i])
                if not got:
                    ok = False
                    break
                names.append(String(pat[i][byte=1:close]))
                values.append(got.take())
            if not ok:
                continue
            return _decide(rule, names, values)
        return RouteDecision.deny()
