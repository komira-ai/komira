# =============================================================================
# komira_service_registry/resolve_result.mojo — the PROVENANCE-carrying answer
#   to a registry lookup.
# =============================================================================
#
# ★ WHY A LOOKUP RETURNS A RECORD AND NOT AN `Optional[String]`.
#
# The registry trades deploy-time validation for runtime lookup, and the price
# of that trade is LOGGING: logging is load-bearing, not a nicety. A registry
# that returns a bare `Optional[String]` gives the caller no way to tell a
# FRESH read of the store from a 60-second-stale cache entry, and no way to
# tell "we looked and it is not there" from "we never looked". Those are the
# two questions every runtime-lookup incident opens with, and neither is
# answerable from a `None`.
#
# So every lookup returns four facts, and `describe()` renders them as the one
# log line a service emits at the moment it resolves a peer:
#
#     resolve key=service/orders-api found=1 source=cache age_ms=1500 value=…
#
#   * `key`     — the object key that was consulted. Not the NAME: the key. An
#                 operator with this line can `gsutil cat` exactly that object,
#                 which is what closes the loop between a bad resolution and the
#                 bytes that caused it.
#   * `found`   — whether a binding exists at all.
#   * `source`  — STORE (this call went to the bucket) vs CACHE (it did not).
#   * `age_ms`  — how stale the answer is. 0 for a store read, the real elapsed
#                 milliseconds for a cache hit.
#
# ⚠ AN ABSENT ANSWER IS SOURCED FROM THE **STORE**, NOT FROM A THIRD "ABSENT"
# SOURCE. `source` records WHERE THE ANSWER CAME FROM; `found` records WHAT the
# answer was. Fusing them would destroy the one distinction the field exists for
# — a `found=0 source=store` line proves the bucket was reached and the key is
# genuinely unregistered, which is a deploy bug; there is no way to say that if
# absence is its own source. (Negatives are deliberately NOT cached, so
# `found=0 source=cache` is unreachable today; the field is still honest about
# it rather than assuming it.)
# =============================================================================


comptime RESOLVE_SOURCE_UNSET: Int = 0
"""A default-constructed result that no lookup produced. Never returned by the
registry; present so a zero value is legible rather than pretending to be a
store read."""

comptime RESOLVE_SOURCE_STORE: Int = 1
"""This call read the object store. `age_ms` is 0."""

comptime RESOLVE_SOURCE_CACHE: Int = 2
"""This call was served from an in-process cache WITHOUT touching the store.
`age_ms` is the real elapsed time since the entry was read."""


@fieldwise_init
struct ResolveResult(Copyable, Movable, Deinitable):
    """The answer to one registry lookup, with its provenance.

    Flat `String`s + scalars — ZERO UnsafePointer, ZERO wildcard origins."""

    var found: Bool
    """Whether a binding exists at `key`."""

    var value: String
    """The bound value — a URL for a discovery lookup, a service NAME for an
    enrollment lookup. Empty when `found` is False."""

    var key: String
    """The object key that was consulted, e.g. `service/orders-api` or
    `identity/gcp.jm_40proj.iam.gserviceaccount.com`."""

    var age_ms: Int64
    """Milliseconds since the value was read from the store. 0 for a store
    read; the real elapsed time for a cache hit."""

    var source: Int
    """`RESOLVE_SOURCE_STORE` / `RESOLVE_SOURCE_CACHE` — see the ordinals."""

    @staticmethod
    def from_store(found: Bool, var value: String, var key: String) -> Self:
        """A result this call read out of the object store (age 0)."""
        return Self(found, value^, key^, Int64(0), RESOLVE_SOURCE_STORE)

    @staticmethod
    def absent(var key: String) -> Self:
        """A store read that found no binding at `key`. Sourced from the STORE
        — the bucket WAS consulted; see the module header."""
        return Self(
            False, String(""), key^, Int64(0), RESOLVE_SOURCE_STORE
        )

    @staticmethod
    def from_cache(var value: String, var key: String, age_ms: Int64) -> Self:
        """A result served from an in-process cache without touching the store.
        `age_ms` is how stale it is — the whole reason this constructor is
        distinct from `from_store`."""
        return Self(True, value^, key^, age_ms, RESOLVE_SOURCE_CACHE)

    def source_name(self) -> StaticString:
        """The lowercase source token used in `describe()` and in logs.

        ⚠ `StaticString`, NOT `String`: every arm returns a literal, so
        nothing is allocated."""
        if self.source == RESOLVE_SOURCE_STORE:
            return "store"
        if self.source == RESOLVE_SOURCE_CACHE:
            return "cache"
        return "unset"

    def describe(self) -> String:
        """The one-line log record of this lookup. This is the artifact the
        deploy-time validation was traded FOR — keep it parseable and keep all
        four facts on it."""
        var found_s = String("0")
        if self.found:
            found_s = String("1")
        var out = String("resolve key=")
        out += self.key
        out += String(" found=")
        out += found_s
        out += String(" source=")
        out += self.source_name()
        out += String(" age_ms=")
        out += String(self.age_ms)
        out += String(" value=")
        if self.found:
            out += self.value
        else:
            out += String("-")
        return out^
