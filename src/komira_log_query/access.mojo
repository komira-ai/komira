# =============================================================================
# komira_log_query/access.mojo: WHO MAY READ THE LOG. A hook the embedding
#   service supplies; the route asks it and nothing else.
# =============================================================================
#
# ── WHY A HOOK, AND NOT A POLICY BUILT INTO THE ROUTE ───────────────────────
# Who may read a service's log depends on the service: one checks a shared
# secret, another a signed token its front end already verified, another a role
# in its own user table. This package cannot know which, so it does not choose.
# The route calls `LogReadAccess.allows(req)` before it reads an argument, and
# answers the same 404 to every "no".
#
# ── ⛔ DENY UNLESS A HOOK SAYS YES ──────────────────────────────────────────
# The route takes the hook as a REQUIRED argument, so a route that compiles has
# always been handed a decision. The two conformers shipped here both default to
# NO:
#
#   * `DenyLogReads` answers no to everything. It is what a service passes when
#     it mounts the route before it has a policy.
#   * `HeaderTokenAccess` answers yes only to a request presenting its secret in
#     its header, and NO to everything while either is empty, so a deployment
#     that forgot to configure the secret has no readable log rather than an
#     open one.
#
# No allow-everything conformer ships. A service that wants an open log writes
# that one-line hook itself, which puts the decision in its own code where a
# reviewer sees it.
#
# The reason for denying by default: the route returns the service's whole log,
# and a service's log names data from every one of its callers. A read surface
# that is open whenever nobody configured it is open exactly when nobody is
# looking.
#
# ⚠ A HOOK THAT RAISES IS A NO. The route catches the raise and answers the same
# 404, so a hook whose verifier fails (a key it cannot fetch, a malformed token)
# cannot open the route and cannot tell the caller why it was refused.
#
# ⛔ THE HOOK SEES THE REQUEST, NOT THE QUERY. It runs before any argument is
# parsed (see `route.mojo` on why the order matters), so it cannot make its
# answer depend on the window or the term.
#
# Encapsulation: value types only (`HttpRequest` borrowed in, `Bool` out). ZERO
# UnsafePointer, ZERO wildcard origin.
# =============================================================================

from komira_http_core.codec.types import HttpRequest


trait LogReadAccess:
    """Answers one question for the route: may this request read the log.

    `allows` returns True to let the request through to argument checks and
    the read. False and a raise both become the route's one 404."""

    def allows(self, req: HttpRequest) raises -> Bool:
        ...


struct DenyLogReads(LogReadAccess, Copyable, Movable):
    """Refuses every request. The hook to pass while a service has no
    policy: the route is mounted and answers 404 to everyone, exactly as if it
    were not mounted."""

    def __init__(out self):
        pass

    def allows(self, req: HttpRequest) raises -> Bool:
        return False


struct HeaderTokenAccess(LogReadAccess, Copyable, Movable):
    """Allows a request whose header `header` carries exactly `token`.

    ⛔ DENIES EVERYTHING WHILE `header` OR `token` IS EMPTY. An empty secret
    means the service did not configure one, not that any caller may read.

    The header name is matched lowercased, as HTTP/1.1 header names are
    case-insensitive and the request parser stores them lowercased. The token
    is compared byte for byte (case-sensitive), with no early exit on the
    first differing byte.

    ⚠ THE TOKEN IS SECRET MATERIAL. A service should read it from its secret
    store, not from its command line (`/proc/<pid>/cmdline` is world-readable),
    and pass the value here.

    ⚠ A dedicated header rather than `Authorization` lets this check coexist
    with a front end that authenticates the caller with its own token in
    `Authorization` and forwards it."""

    var _header: String
    var _token: String

    def __init__(out self, header: String, token: String):
        self._header = _ascii_lower(header)
        self._token = token

    def allows(self, req: HttpRequest) raises -> Bool:
        if self._header.byte_length() == 0:
            return False
        if self._token.byte_length() == 0:
            return False
        var presented = req.headers.get(self._header)
        if not presented:
            return False
        return _const_time_eq(presented.value(), self._token)


def _ascii_lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            out.append(c + UInt8(32))
        else:
            out.append(c)
    return String(unsafe_from_utf8=out^)


def _const_time_eq(a: String, b: String) -> Bool:
    """A length-checked, branch-uniform compare (no early exit on the first
    mismatched byte). Not a hardware-constant-time primitive, but it removes
    the obvious early-return timing signal."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    var diff = UInt8(0)
    for i in range(len(ab)):
        diff = diff | (ab[i] ^ bb[i])
    return diff == UInt8(0)
