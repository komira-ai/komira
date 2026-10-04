# =============================================================================
# komira_service_registry_client/resolution.mojo — WHAT A PEER LOOKUP RETURNS.
#   Eight dispositions, one predicate, one log line.
# =============================================================================
#
# ★★ WHY THIS TYPE EXISTS AND WHY THE LOOKUP DOES NOT SIMPLY RETURN
#   `ResolveResult`.
#
# `ResolveResult` is the CONTRACT type and it is exactly right for what it
# models: a lookup that REACHED a store. Its own header says so —
# `found=0 source=store` means "the bucket was reached and the key is genuinely
# unregistered". It has no way to say "I never reached anything", because for
# an in-process store over a bucket that state is a raised error.
#
# Over HTTP, across clouds, through an API Gateway, it is the ORDINARY state.
# So returning a bare `ResolveResult` from this client would force the caller
# into exactly the collapse the whole subsystem exists to prevent: an
# unreachable registry rendered as `found=false`, i.e. "that peer is not
# registered", i.e. a deploy bug reported for a network fault.
#
# `PeerResolution` therefore WRAPS `ResolveResult` — the contract type survives
# intact, with the right provenance, for every case where a lookup DID produce
# an answer — and adds the facts only a remote client has: which of eight
# dispositions this was, whether the response carried the registry's marker, the
# URL dialled, and why a failure was a failure.
#
# ⛔ THE TAXONOMY IS A VALUE, NEVER A MESSAGE. Not one of these states is
# reported by raising. `directory.mojo` in the contract package has to recover
# `412` and `404` by SUBSTRING-MATCHING a store error, and documents exactly
# what that costs ("a message reformat that dropped `status=412` would silently
# turn a concurrent-deploy 412 into a fatal write"). A client whose caller had
# to `String(e).find("unreachable")` would be that, one layer up, in code every
# service runs on its request path.
#
# ★ `usable()` IS THE ONE PREDICATE A CALLER BRANCHES ON. Three dispositions
# carry an endpoint you may dial and five do not. Every caller writing its own
# version of that test is how one of them ends up dialling `""`, or treating a
# stale-but-good URL as a hard failure. There is one implementation.
#
# ENCAPSULATION: flat value types. ZERO UnsafePointer, ZERO wildcard origins.
# =============================================================================

from komira_service_registry.resolve_result import (
    RESOLVE_SOURCE_UNSET,
    ResolveResult,
)


# -----------------------------------------------------------------------------
# §1 — the eight dispositions. Each one has a DIFFERENT correction, which is the
# test for whether it deserves to be its own ordinal.
# -----------------------------------------------------------------------------

comptime PEER_FRESH: Int = 1
"""Dialled the registry; it answered; the binding exists. No action."""

comptime PEER_CACHED: Int = 2
"""Served from a cache entry younger than the TTL. No dial happened. No
action."""

comptime PEER_STALE: Int = 3
"""⭐ Served from an EXPIRED cache entry BECAUSE THE FETCH FAILED. The endpoint
is usable and the result says how old it is. ACTION: fix the registry path — but
NOT urgently on this call's behalf, because this call succeeded."""

comptime PEER_ABSENT: Int = 4
"""The registry ANSWERED and the name is unregistered (`200 {"found":false}`).
ACTION: publish the endpoint. This is a DEPLOY bug and never a network one."""

comptime PEER_UNREACHABLE: Int = 5
"""No response, or a response with no marker, and nothing usable cached. ACTION:
the edge, the base URL, or the network. NOT a deploy bug."""

comptime PEER_REGISTRY_ERROR: Int = 6
"""The registry answered 5xx: it is THERE and cannot read its store. ACTION:
the registry's store. Distinct from UNREACHABLE because it proves the base URL
and the whole network path are correct — which is most of what an operator
would otherwise spend the incident establishing."""

comptime PEER_PROTOCOL_ERROR: Int = 7
"""The registry answered something this client cannot read — a body that is not
the contract, or a status the route does not define (INCLUDING a MARKED 404,
which is a route that does not exist). ACTION: ship a client and a server that
agree. Never an absence."""

comptime PEER_REFUSED: Int = 8
"""This client refused to dial, or the registry refused the request (400). The
NAME is wrong — empty, or carrying a byte that is not safe in one path segment.
ACTION: fix the caller. Nothing intermittent; a retry fails identically."""


# -----------------------------------------------------------------------------
# §2 — marker state. THREE values, because "we did not dial" is not "the
# response was unmarked" and reporting the second for the first would invent an
# observation.
# -----------------------------------------------------------------------------

comptime MARKER_NOT_DIALLED: Int = 0
comptime MARKER_PRESENT: Int = 1
comptime MARKER_ABSENT: Int = 2


@fieldwise_init
struct PeerResolution(Copyable, Movable, Deinitable):
    """The answer to one peer lookup: the contract result plus the facts only a
    REMOTE client has."""

    var disposition: Int
    """One of the eight `PEER_*` ordinals above."""

    var result: ResolveResult
    """The contract type. For FRESH/ABSENT it is `from_store` (this call went to
    the registry — the registry IS the store from here); for CACHED/STALE it is
    `from_cache` with the REAL elapsed age; for every failure it is
    `RESOLVE_SOURCE_UNSET` with an EMPTY key.

    ⛔ A FAILURE'S RESULT IS `UNSET`, NEVER `absent()`. `ResolveResult.absent`
    asserts `found=0 source=store` — "the store WAS consulted and the key is
    genuinely unregistered". Using it for an unreachable registry would write a
    false statement into the one log line this subsystem traded deploy-time
    validation for. `RESOLVE_SOURCE_UNSET`'s own docstring reserves it for
    exactly this: "a zero value is legible rather than pretending to be a store
    read"."""

    var name: String
    """What was asked for — the service name."""

    var url: String
    """The URL dialled, or `""` when no dial happened (a cache hit, or a
    client-side refusal). A CLIENT fact: the server never states it."""

    var marker_state: Int
    """`MARKER_NOT_DIALLED` / `MARKER_PRESENT` / `MARKER_ABSENT`."""

    var detail: String
    """Why a non-happy disposition happened, in constant-shaped text. NEVER an
    echo of a response body: bytes from an unidentified intermediary are
    attacker-influenced and this string is written to logs."""

    @staticmethod
    def refused(var name: String, var detail: String) -> Self:
        """A refusal decided HERE, before any dial."""
        return Self(
            PEER_REFUSED,
            ResolveResult(
                False, String(""), String(""), Int64(0), RESOLVE_SOURCE_UNSET
            ),
            name^,
            String(""),
            MARKER_NOT_DIALLED,
            detail^,
        )

    def disposition_name(self) -> StaticString:
        """⚠ `StaticString`, NOT `String`: every arm returns a literal."""
        if self.disposition == PEER_FRESH:
            return "fresh"
        if self.disposition == PEER_CACHED:
            return "cached"
        if self.disposition == PEER_STALE:
            return "stale"
        if self.disposition == PEER_ABSENT:
            return "absent"
        if self.disposition == PEER_UNREACHABLE:
            return "unreachable"
        if self.disposition == PEER_REGISTRY_ERROR:
            return "registry-error"
        if self.disposition == PEER_PROTOCOL_ERROR:
            return "protocol-error"
        if self.disposition == PEER_REFUSED:
            return "refused"
        return "unset"

    def marker_name(self) -> StaticString:
        """⚠ `StaticString`, NOT `String`: every arm returns a literal."""
        if self.marker_state == MARKER_PRESENT:
            return "present"
        if self.marker_state == MARKER_ABSENT:
            return "absent"
        return "not-dialled"

    @always_inline
    def usable(self) -> Bool:
        """Whether this resolution carries an endpoint the caller may dial.

        TRUE for FRESH, CACHED and STALE. FALSE for everything else — INCLUDING
        `PEER_ABSENT`, which is a definite answer and still gives the caller
        nothing to dial.

        ★ STALE IS USABLE, AND THAT IS THE CENTRAL TRADE OF THIS PACKAGE. See
        `directory.mojo`'s header."""
        return (
            self.disposition == PEER_FRESH
            or self.disposition == PEER_CACHED
            or self.disposition == PEER_STALE
        )

    @always_inline
    def is_stale(self) -> Bool:
        """Whether the endpoint came from an EXPIRED entry served because the
        fetch failed. A caller that must not act on stale topology (a
        destructive administrative operation, say) tests THIS; ordinary request
        traffic should not."""
        return self.disposition == PEER_STALE

    @always_inline
    def endpoint(self) -> String:
        """The resolved endpoint, or `""` when `usable()` is False.

        ⚠ NEVER branch on `endpoint() != ""` — that is `usable()` spelled
        badly, and it silently reads ABSENT and UNREACHABLE the same way."""
        if self.usable():
            return String(self.result.value)
        return String("")

    def describe(self) -> String:
        """The ONE log line a service emits when it resolves a peer.

        It carries the contract's own `describe()` verbatim — key / found /
        source / age_ms / value — and prefixes the client-side facts. This line
        is the artifact that replaces validation at deploy time; keep every
        field on it and keep it parseable."""
        var out = String("peer resolve name=")
        out += self.name
        out += String(" disposition=")
        out += self.disposition_name()
        out += String(" usable=")
        out += String("1") if self.usable() else String("0")
        out += String(" marker=")
        out += self.marker_name()
        out += String(" url=")
        out += self.url if self.url.byte_length() > 0 else String("-")
        out += String(" ")
        out += self.result.describe()
        if self.detail.byte_length() > 0:
            out += String(" detail=")
            out += self.detail
        return out^
