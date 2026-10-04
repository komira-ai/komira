# =============================================================================
# komira_service_registry_client/directory.mojo — RemotePeerDirectory[T]. The
#   thing a deployed service actually holds.
# =============================================================================
#
# ★★★ THE CACHE IS THE ANSWER TO "WHAT IF THERE IS AN OUTAGE", AND IT IS THE
#   CENTRAL DESIGN DECISION OF THIS PACKAGE.
#
# A peer endpoint is a URL that changes ONLY on the peer's redeploy. So during a
# registry outage the last value this client read is, overwhelmingly, still
# correct. Two policies were available:
#
#   HARD FAIL     the registry is unreachable -> the lookup fails -> the peer
#                 call does not happen. This makes the registry a HARD RUNTIME
#                 DEPENDENCY of every service-to-service call in the mesh: a
#                 registry blip becomes a fleet-wide outage, and the blast
#                 radius of the discovery layer becomes larger than the blast
#                 radius of anything it discovers.
#
#   SERVE STALE   the registry is unreachable -> serve the last known endpoint,
#                 SAY SO, and say HOW OLD IT IS. The peer call happens. The
#                 registry is a CONVERGENCE mechanism, not a gate on traffic.
#
# ⇒ SERVE STALE. Under three conditions that are what make it honest rather
#   than a guess:
#
#   1. ONLY FROM A VALUE THIS CLIENT ITSELF READ from the registry. Never a
#      default, never a fallback URL, never anything a config supplied. If we
#      never resolved this name, an outage means we do not know — and saying so
#      is `PEER_UNREACHABLE`.
#   2. ONLY WHEN THE FETCH FAILED. A registry that ANSWERS wins, always, even
#      when the answer is `found:false` — see the eviction rule below.
#   3. ONLY WITHIN `max_stale_ms`, and the result carries the REAL age, so the
#      staleness is in the log line rather than in someone's head. Beyond it,
#      `PEER_UNREACHABLE` — an endpoint from a week ago is a guess wearing a
#      cache's clothes.
#
# ⛔ A REACHED REGISTRY SAYING `found:false` EVICTS THE CACHED ENTRY. It does
# NOT fall back to it. `found:false` means the binding was withdrawn or never
# published; serving the stale URL would RESURRECT a binding an operator or the
# reaper deliberately removed, and would do it silently and forever, because
# every subsequent absent answer would re-serve it. Absence from a REACHED
# registry is authoritative. This is the one place where "prefer availability"
# is the wrong instinct and the rule is written down so nobody re-relaxes it.
#
# ⛔ NEGATIVES ARE NEVER CACHED. A peer that has not published yet is the
# ORDINARY state during a rollout; caching its absence would make the client's
# convergence slower than the deploy's, which is the one behaviour a DNS
# replacement may not have. (`CachedServiceDirectory` states the same rule for
# the in-cloud path.)
#
# ═══════════════════════════════════════════════════════════════════════════
#  WHAT SERVES STALE, AND WHAT DOES NOT
# ═══════════════════════════════════════════════════════════════════════════
#   NOT_REACHED      -> STALE if we have one, else PEER_UNREACHABLE
#   REGISTRY_ERROR   -> STALE if we have one, else PEER_REGISTRY_ERROR
#   PROTOCOL_ERROR   -> STALE if we have one, else PEER_PROTOCOL_ERROR
#        (a version-skewed or half-deployed registry is exactly the outage a
#         cache should ride out; the endpoint is not less likely to be right
#         because the response was unparseable)
#   OK found:false   -> EVICT, PEER_ABSENT. NEVER stale. See the ⛔ above.
#   REFUSED          -> PEER_REFUSED. NEVER stale: the name is wrong, retrying
#                       is identical, and serving a cached value for a name we
#                       just refused would mask a caller's bug.
#
# ★ THERE IS ONE TYPE, NOT AN UNCACHED ONE AND A CACHED WRAPPER.
# `ServiceDirectory` + `CachedServiceDirectory` split that way because the bare
# one is genuinely useful in-process (the deploy writes through it). Here a bare
# one has exactly one effect: it lets a caller bind the variant that turns a
# registry blip into a peer outage. `ttl_ms = 0, max_stale_ms = 0` expresses
# "always re-read, never serve stale" in the SAME type, and `ttl_ms = 0,
# max_stale_ms > 0` expresses "always re-read, but survive an outage", which the
# two-type shape cannot express at all.
#
# ★ THE CLOCK IS INJECTED. Every op takes `now_ms`. No hidden `Date.now()`, so
# the whole staleness ladder is deterministic under test — and a caller that
# already runs an event loop reads its own clock, as callers of the in-cloud
# resolver do.
#
# ⛔ NOTHING ON THE LOOKUP PATH RAISES. Every failure is a `PeerResolution`
# value. See `resolution.mojo`'s ⛔ block: a taxonomy recovered by
# substring-matching an exception is the fragility the contract package already
# documents about store errors, and this is code on a request path.
#
# ENCAPSULATION: the transport is a moved-in generic value; the cache is a plain
# `List` of flat-`String` rows. ZERO UnsafePointer, ZERO wildcard origins, no
# FFI. gap6 N/A — a typed List, not a byte slab.
# =============================================================================

from komira_service_registry.http_contract import resolve_service_path
from komira_service_registry.resolve_result import (
    RESOLVE_SOURCE_UNSET,
    ResolveResult,
)

from .answer import (
    ANSWER_NOT_REACHED,
    ANSWER_OK,
    ANSWER_PROTOCOL_ERROR,
    ANSWER_REFUSED,
    ANSWER_REGISTRY_ERROR,
    RegistryAnswer,
    classify_registry_response,
)
from .endpoint import RegistryEndpoint, refuse_unsafe_segment
from .resolution import (
    MARKER_ABSENT,
    MARKER_NOT_DIALLED,
    MARKER_PRESENT,
    PEER_ABSENT,
    PEER_CACHED,
    PEER_FRESH,
    PEER_PROTOCOL_ERROR,
    PEER_REFUSED,
    PEER_REGISTRY_ERROR,
    PEER_STALE,
    PEER_UNREACHABLE,
    PeerResolution,
)
from .transport import RegistryTransport


@fieldwise_init
struct _PeerEntry(Copyable, Movable, Deinitable):
    """One cached row, keyed by the REQUEST PATH.

    Keyed by the path rather than the name so the cache key is exactly the
    question that was asked of the registry. (`_CacheEntry` in the contract
    package keys by the OBJECT key for the same reason.)"""

    var path: String
    var value: String
    var key: String
    """The key the SERVER said it consulted, stored so a CACHE hit still reports
    the server's key and not the client's belief about it."""
    var read_at_ms: Int64


struct RemotePeerDirectory[T: RegistryTransport](Movable):
    """The peer-side registry client: name -> endpoint, over HTTP, with a TTL
    cache and a stated staleness policy.

    ⛔ IT IS NOT A `ConditionalWriteStore` CONFORMER, AND MUST NEVER BECOME ONE.
    That trait's `conditional_put` / `compare_and_swap` / `delete` are WRITES
    the serving app does not serve — it has no write verb and holds no write
    credential, by design. A conformer would have to raise on three of its own
    verbs: a type claiming capabilities the wire refuses, in the seam whose
    entire job is that the store ENFORCES an invariant rather than the caller
    remembering it. Reusing `ServiceDirectory`/`CachedServiceDirectory`
    unchanged is the payoff that makes it tempting; it is not worth a lying
    type.

    ⛔ IT CARRIES NO AUTH. Discovery only. The caller applies its own
    authentication to the PEER call, after resolution — a different call, to a
    different host, with a different audience."""

    var _endpoint: RegistryEndpoint
    var _transport: Self.T
    var _ttl_ms: Int64
    var _max_stale_ms: Int64
    var _cache: List[_PeerEntry]

    def __init__(
        out self,
        var endpoint: RegistryEndpoint,
        var transport: Self.T,
        ttl_ms: Int64,
        max_stale_ms: Int64,
    ):
        """Construct over a VALIDATED endpoint and a moved-in transport.

        `ttl_ms` — how long a read stays fresh. A larger value trades
        staleness-on-redeploy for fewer registry reads.

        `max_stale_ms` — how far past its read time an entry may still be served
        WHEN A FETCH FAILS. `0` disables stale serving entirely. It is measured
        from the read, not from expiry, so it is the ONE number that bounds how
        wrong this client is willing to be, and `describe()` prints the age it
        is bounding.

        ⚠ BOTH ARE REQUIRED ARGUMENTS WITH NO DEFAULTS. How long a service may
        run on a stale peer URL is a deployment's decision, and a library that
        picked one would be making it for every consumer silently."""
        self._endpoint = endpoint^
        self._transport = transport^
        self._ttl_ms = ttl_ms
        self._max_stale_ms = max_stale_ms
        self._cache = List[_PeerEntry]()

    def into_transport(deinit self) -> Self.T:
        """Recover the transport (e.g. to share one connection pool)."""
        return self._transport^

    def transport(ref self) -> ref [self._transport] Self.T:
        """Borrow the transport — e.g. to inspect a test double's call log
        BETWEEN steps of a sequence, which `into_transport` cannot do because it
        consumes the directory. (`CachedServiceDirectory.directory` is the same
        accessor for the same reason.)"""
        return self._transport

    @always_inline
    def ttl_ms(self) -> Int64:
        return self._ttl_ms

    @always_inline
    def max_stale_ms(self) -> Int64:
        return self._max_stale_ms

    @always_inline
    def cache_len(self) -> Int:
        return len(self._cache)

    def endpoint_base(self) -> String:
        """The validated registry base URL this client dials."""
        return String(self._endpoint.base)

    # =========================================================================
    # The lookup.
    # =========================================================================

    def resolve_endpoint(
        mut self, name: String, now_ms: Int64
    ) -> PeerResolution:
        """DISCOVERY: service `name` -> the URL a peer dials.

        Never raises. The disposition is the answer; see `resolution.mojo`."""
        var why = refuse_unsafe_segment(name)
        if why.byte_length() > 0:
            return PeerResolution.refused(String(name), why^)
        return self._lookup(resolve_service_path(name), String(name), now_ms)

    # =========================================================================
    # Cache mechanics.
    # =========================================================================

    def _find(self, path: String) -> Int:
        """Index of `path` in the cache, or -1. Linear — the cache holds one row
        per peer, a handful of entries."""
        for i in range(len(self._cache)):
            if self._cache[i].path == path:
                return i
        return -1

    def _store(mut self, path: String, value: String, key: String, now_ms: Int64):
        var idx = self._find(path)
        if idx >= 0:
            self._cache[idx].value = String(value)
            self._cache[idx].key = String(key)
            self._cache[idx].read_at_ms = now_ms
        else:
            self._cache.append(
                _PeerEntry(String(path), String(value), String(key), now_ms)
            )

    def invalidate(mut self, path: String):
        """Drop one request PATH from the cache so the next lookup reads
        through. Compose it with the contract's `resolve_service_path`."""
        var keep = List[_PeerEntry]()
        for i in range(len(self._cache)):
            if self._cache[i].path != path:
                keep.append(self._cache[i].copy())
        self._cache = keep^

    def clear(mut self):
        """Drop every cached entry."""
        self._cache = List[_PeerEntry]()

    # =========================================================================
    # The one lookup path. Both verbs funnel through it, so the staleness ladder
    # and the failure taxonomy are stated ONCE and cannot drift between the two
    # keyspaces.
    # =========================================================================

    def _lookup(
        mut self, var path: String, var name: String, now_ms: Int64
    ) -> PeerResolution:
        # 1 — a FRESH cache entry answers without a dial.
        var idx = self._find(path)
        if idx >= 0:
            var age = now_ms - self._cache[idx].read_at_ms
            if age >= Int64(0) and age < self._ttl_ms:
                return PeerResolution(
                    PEER_CACHED,
                    ResolveResult.from_cache(
                        String(self._cache[idx].value),
                        String(self._cache[idx].key),
                        age,
                    ),
                    name^,
                    String(""),
                    MARKER_NOT_DIALLED,
                    String(""),
                )

        # 2 — dial.
        var url = self._endpoint.url_for(path)
        var marker_state = MARKER_NOT_DIALLED
        var answer = RegistryAnswer.failed(ANSWER_NOT_REACHED, String(""))
        try:
            var resp = self._transport.get(url)
            marker_state = (
                MARKER_PRESENT if resp.marker.byte_length()
                > 0 else MARKER_ABSENT
            )
            answer = classify_registry_response(
                resp.status, resp.marker, resp.body
            )
        except e:
            # A GENUINE transport fault: DNS, TCP, TLS, timeout, a bad URL.
            # `detail` carries the transport's own text because it is OUR
            # client's error, not bytes from an unidentified intermediary.
            marker_state = MARKER_NOT_DIALLED
            answer = RegistryAnswer.failed(
                ANSWER_NOT_REACHED,
                String("the registry could not be dialled: ") + String(e),
            )

        # 3 — an ANSWER from the registry wins, in both directions.
        if answer.kind == ANSWER_OK:
            if answer.found:
                self._store(path, answer.value, answer.key, now_ms)
                return PeerResolution(
                    PEER_FRESH,
                    ResolveResult.from_store(
                        True, String(answer.value), String(answer.key)
                    ),
                    name^,
                    url^,
                    marker_state,
                    String(""),
                )
            # ⛔ EVICT. A reached registry saying "unregistered" is
            # authoritative; falling back to the cache here would resurrect a
            # withdrawn binding, silently and permanently.
            self.invalidate(path)
            return PeerResolution(
                PEER_ABSENT,
                ResolveResult.absent(String(answer.key)),
                name^,
                url^,
                marker_state,
                String(""),
            )

        # 4 — the fetch did not produce an answer. A refusal is OURS and is
        # never covered by a cache; everything else may be ridden out.
        if answer.kind == ANSWER_REFUSED:
            # ⚠ `PEER_REFUSED`, NOT `answer.kind`. The two vocabularies are
            # DIFFERENT and their ordinals do not line up (ANSWER_REFUSED is 5,
            # PEER_REFUSED is 8); passing one through as the other is a bug that
            # compiles, and `refused_disposition_is_translated_not_passed_through`
            # is its falsifier.
            return PeerResolution(
                PEER_REFUSED,
                ResolveResult(
                    False, String(""), String(""), Int64(0), RESOLVE_SOURCE_UNSET
                ),
                name^,
                url^,
                marker_state,
                String(answer.detail),
            )

        var stale_idx = self._find(path)
        if stale_idx >= 0 and self._max_stale_ms > Int64(0):
            var stale_age = now_ms - self._cache[stale_idx].read_at_ms
            if stale_age >= Int64(0) and stale_age <= self._max_stale_ms:
                return PeerResolution(
                    PEER_STALE,
                    ResolveResult.from_cache(
                        String(self._cache[stale_idx].value),
                        String(self._cache[stale_idx].key),
                        stale_age,
                    ),
                    name^,
                    url^,
                    marker_state,
                    String("serving a STALE endpoint because the lookup failed:")
                    + String(" ")
                    + String(answer.detail),
                )

        var disposition = PEER_UNREACHABLE
        if answer.kind == ANSWER_REGISTRY_ERROR:
            disposition = PEER_REGISTRY_ERROR
        elif answer.kind == ANSWER_PROTOCOL_ERROR:
            disposition = PEER_PROTOCOL_ERROR
        return PeerResolution(
            disposition,
            ResolveResult(
                False, String(""), String(""), Int64(0), RESOLVE_SOURCE_UNSET
            ),
            name^,
            url^,
            marker_state,
            String(answer.detail),
        )
