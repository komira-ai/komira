# =============================================================================
# komira_service_registry/directory.mojo -- ServiceDirectory[Store] +
#   CachedServiceDirectory[Store]. The STORE CONTRACT for the cross-cloud
#   service registry's discovery job.
# =============================================================================
#
# ONE generic job over ONE `ConditionalWriteStore`: DISCOVERY.
#
#   key              value            write policy
#   ---------------  ---------------  ----------------------------------------
#   service/<name>   the URL bytes    LAST-WRITER-WINS: head + CAS,
#                                     RETRY ONCE on 412.
#
# Enrollment (binding a platform identity to a service name) is NOT part of this
# package. It is authentication-adjacent and is not provided here.
#
# ⛔ THE DISCOVERY KEY COMPOSITION IS `<prefix>/<name>` AND IT DOES NOT CHANGE.
# `service/<name>` holding the BARE URL BYTES is byte-for-byte what
# `komira_svcref.ServiceRegistry` writes, so this contract is a DROP-IN for it:
# switching a caller is a code change with no data migration behind it. The
# byte-level composition is pinned by this package's own
# `test_the_endpoint_object_is_wire_identical_to_the_shipped_writer`.
#
# ⛔ AND THE PREFIX IS A COMPTIME CONSTANT, NOT A CONSTRUCTOR PARAMETER.
# `komira_svcref.ServiceRegistry` takes an optional prefix; this deliberately
# does not. A configurable prefix IS a second key composition, and a second key
# composition fails quietly: a key that is no service's name, decoded back by a
# mapper, can grant access on a service that does not exist, with a GREEN
# deploy and a permanent 403. ONE registry per stage needs one composition.
#
# ⛔ NO KOMIRA PRODUCT CONCEPTS. No org_id, no app_id, no bundle, no env, no
# region, no cloud enum. A service is a NAME. Every axis beyond that is the
# caller's, and a service that must be
# region-scoped carries the region IN ITS NAME (composed once, by its deployer),
# which is why there is no region parameter anywhere in this file.
#
# ⛔ THE REGISTRY DOES NOT MINT TOKENS AND DOES NOT VERIFY ATTESTATIONS. It
# records a binding and answers lookups. Deciding whether a writer may publish
# is the serving app's job.
#
# # Encapsulation discipline
#   * ZERO UnsafePointer anywhere; in/out are `String` / `ResolveResult` /
#     `List[...]`.
#   * ZERO wildcard origins, ZERO `unsafe_from_address`, ZERO FFI.
#   * The `Store` is a moved-in generic value; the cache is a plain `List` of
#     flat-`String` rows (a typed List, not a byte-slab).
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from .resolve_result import (
    RESOLVE_SOURCE_CACHE,
    RESOLVE_SOURCE_STORE,
    ResolveResult,
)


comptime ENDPOINT_PREFIX: StaticString = "service"
"""The discovery keyspace. `service/<name>` -> the served URL bytes. UNCHANGED
from the shipped writer — see the module header."""


# -----------------------------------------------------------------------------
# Bytes <-> String. The stored value is bare and unframed: the key carries the
# identity of the thing and the value carries the one fact bound to it. One
# source of truth per fact, so nothing inside an object can drift out of
# agreement with the key that names it.
# -----------------------------------------------------------------------------


def _encode(s: String) -> List[UInt8]:
    """The stored object bytes for `s` — bare, no trailing newline."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _decode(bytes: List[UInt8]) -> String:
    """Parse stored object bytes back to a String, stripping trailing
    whitespace a tool may have appended (defensive — `_encode` adds none)."""
    var end = len(bytes)
    while end > 0:
        var c = bytes[end - 1]
        if c == UInt8(10) or c == UInt8(13) or c == UInt8(32) or c == UInt8(9):
            end -= 1
        else:
            break
    var out = String("")
    for i in range(end):
        out += chr(Int(bytes[i]))
    return out^


# -----------------------------------------------------------------------------
# Error taxonomy probes.
#
# ⚠ THE CANONICAL UPPERCASE TOKEN COMES FIRST, AND THAT ORDER IS LOAD-BEARING.
# `komira_gcp_storage`'s `GcsGrpcConditionalStore` /
# `map_grpc_error_to_store_error` emit
# `StoreError[PRECONDITION]` / `StoreError[NOT_FOUND]`. A classifier that keys
# only on the lowercase word plus the numeric status is DEAD against those
# tokens and survives only while the numeric happens to be co-present — a
# message reformat that dropped `status=412` would silently turn a
# concurrent-deploy 412 into a fatal write. `komira_svcref` carries the same
# classifier for the same reason. These are copied rather than imported because
# that package depends on a database layer and the HTTP stack; importing it to
# share twelve lines would cost this package its one-dependency closure.
# -----------------------------------------------------------------------------


def _is_precondition_failed(e: Error) -> Bool:
    """True iff `e` is a conditional-write precondition failure (412)."""
    var msg = String(e)
    return (
        msg.find("StoreError[PRECONDITION]") >= 0
        or msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("PreconditionFailed") >= 0
        or msg.find("412") >= 0
    )


def _is_not_found(e: Error) -> Bool:
    """True iff `e` is a store not-found (404) — an absent object."""
    var msg = String(e)
    return (
        msg.find("StoreError[NOT_FOUND]") >= 0
        or msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("NoSuchKey") >= 0
        or msg.find("404") >= 0
    )


# =============================================================================
# ServiceDirectory[Store]
# =============================================================================
struct ServiceDirectory[Store: ConditionalWriteStore](Movable):
    """The cross-cloud service registry's store contract: discovery over ONE
    `ConditionalWriteStore`.

    Portable by inheritance from the `Store` type-param — the SAME code runs on
    the in-memory conformer (tests) and on a cloud store (the live registry).
    This leaf codes to the object-store CAS seam and is agnostic to which
    backing store the serving app binds."""

    var _store: Self.Store

    def __init__(out self, var store: Self.Store):
        """Construct over a moved-in `store`. There is deliberately no prefix
        parameter — see the module header."""
        self._store = store^

    def into_store(deinit self) -> Self.Store:
        """Recover the underlying store (e.g. to share the backing handle)."""
        return self._store^

    # -------------------------------------------------------------------------
    # Key composition -- the ONLY one, stated here.
    # -------------------------------------------------------------------------

    @always_inline
    def endpoint_key(self, name: String) -> String:
        """`service/<name>`. The key IS the service name."""
        return String(ENDPOINT_PREFIX) + String("/") + name

    def _strip(self, key: String, prefix: StaticString) raises -> String:
        """Recover the variable part of a key under `prefix`."""
        var head = String(prefix) + String("/")
        var hb = head.as_bytes()
        var kb = key.as_bytes()
        if len(kb) < len(hb):
            raise Error(
                "service registry: key '" + key + "' is not under '" + head + "'"
            )
        var out = String("")
        for i in range(len(hb), len(kb)):
            out += chr(Int(kb[i]))
        return out^

    # =========================================================================
    # DISCOVERY — name -> endpoint. LAST-WRITER-WINS.
    # =========================================================================

    def publish_endpoint(mut self, name: String, url: String) raises:
        """Publish (or re-publish on redeploy) service `name` at `url`.

        LAST-WRITER-WINS, and that is the CORRECT policy here: a URL changes on
        every redeploy and the newest deploy's URL is the one peers should
        reach. Reads the current etag and CASes on it — or creates if absent —
        RETRYING ONCE on a 412 (a concurrent registrant moved the object between
        our read and our write). One retry suffices: publishing is a deploy-time
        event, two publishers racing one name is already unlikely, and a double
        collision on the retry is vanishingly so. If even the retry 412s we
        raise, surfacing genuine pathological contention rather than looping."""
        var path = Path.parse(self.endpoint_key(name))
        var bytes = _encode(url)
        if self._try_last_writer_wins(path, bytes):
            return
        if self._try_last_writer_wins(path, bytes):
            return
        raise Error(
            "service registry: persistent CAS contention publishing the"
            " endpoint for '"
            + name
            + "' (412 twice) — retry the deploy"
        )

    def publish_endpoint_if_changed(
        mut self, name: String, url: String
    ) raises -> Bool:
        """Publish ONLY when the stored URL differs from `url`. Returns True iff
        a write was issued.

        A LEVEL-TRIGGERED caller (a reconcile loop firing on every health-gate
        advance) would otherwise emit a steady write stream AND can exhaust
        `publish_endpoint`'s retry-once budget racing a concurrent publisher on
        the same key. A steady-state redeploy to the SAME url becomes a PURE
        READ here — no head, no CAS."""
        var cur = self.resolve_endpoint(name)
        if cur.found and cur.value == url:
            return False
        self.publish_endpoint(name, url)
        return True

    def resolve_endpoint(self, name: String) raises -> ResolveResult:
        """Resolve `name` -> its published URL, WITH PROVENANCE. An absent key
        is a `found=False` result sourced from the STORE, not a raise and not a
        third source — see `resolve_result.mojo`."""
        var key = self.endpoint_key(name)
        return self._read(key)

    def withdraw_endpoint(mut self, name: String) raises -> Bool:
        """DELETE the discovery binding for `name`. Returns True iff an object
        was there to remove, False if it was already absent (idempotent — a
        second reap pass is not an error).

        ⚠ IT HEADS BEFORE IT DELETES, and that is not a wasted round trip: S3
        answers 204 to a DELETE of a missing key while GCS answers 404, so
        deciding present-vs-absent from the delete's own outcome would make this
        verb's return value depend on which cloud the registry is on. The head
        makes the answer a property of the registry rather than of the backend.

        ⚠ A concurrent delete between the head and the delete is treated as
        already-absent (False), not as an error: two reapers agreeing is not a
        conflict."""
        var path = Path.parse(self.endpoint_key(name))
        return self._delete_if_present(path)

    def list_endpoints(self) raises -> List[String]:
        """Every service name with a published endpoint. Store listing order;
        sort if you need a stable one."""
        var res = self._store.list_with_delimiter(
            Path.parse(String(ENDPOINT_PREFIX) + String("/"))
        )
        var out = List[String]()
        for i in range(len(res.objects)):
            out.append(self._strip(res.objects[i].location, ENDPOINT_PREFIX))
        return out^

    # =========================================================================
    # Store mechanics.
    # =========================================================================

    def _read(self, key: String) raises -> ResolveResult:
        """One GET, rendered as a provenance-carrying result. A 404 is an
        `absent` result sourced from the STORE; every other error raises."""
        var path = Path.parse(key)
        try:
            var bytes = self._store.get(path)
            return ResolveResult.from_store(True, _decode(bytes), String(key))
        except e:
            if _is_not_found(e):
                return ResolveResult.absent(String(key))
            raise e^

    def _try_last_writer_wins(
        self, path: Path, bytes: List[UInt8]
    ) raises -> Bool:
        """One read-etag + conditional-write cycle for the DISCOVERY keyspace.
        True on commit, False on a 412 (the caller retries)."""
        var cur_etag = Optional[String]()
        try:
            var meta = self._store.head(path)
            cur_etag = Optional[String](meta.etag)
        except e:
            if not _is_not_found(e):
                raise e^  # a real error (auth / transport) is not our 404

        if not cur_etag:
            try:
                _ = self._store.conditional_put(
                    path, bytes, WritePrecondition.if_none_match_star()
                )
                return True
            except e:
                if _is_precondition_failed(e):
                    return False
                raise e^

        try:
            _ = self._store.compare_and_swap(path, bytes, cur_etag.value())
            return True
        except e:
            if _is_precondition_failed(e):
                return False
            raise e^

    def _delete_if_present(self, path: Path) raises -> Bool:
        """head-then-delete. See `withdraw_endpoint` for why the head is not a
        wasted round trip."""
        try:
            _ = self._store.head(path)
        except e:
            if _is_not_found(e):
                return False
            raise e^
        try:
            self._store.delete(path)
        except e:
            if _is_not_found(e):
                return False  # a concurrent reaper won; not a conflict
            raise e^
        return True


# =============================================================================
# CachedServiceDirectory[Store] — the TTL-cached read-through lookup client.
# =============================================================================


@fieldwise_init
struct _CacheEntry(Copyable, Movable, Deinitable):
    """One cached `key -> (value, read_at_ms)` row. Keyed by the OBJECT KEY, not
    by the name."""

    var key: String
    var value: String
    var read_at_ms: Int64


struct CachedServiceDirectory[Store: ConditionalWriteStore](Movable):
    """A TTL-cached read-through client over a `ServiceDirectory[Store]`.

    Lookup happens at runtime and is cached client-side, and the price of
    dropping deploy-time validation is LOGGING. Those two together are
    why the cache returns a `ResolveResult` rather than a value: a cache hit
    reports `source=cache` and its REAL age, so a service reading a stale peer
    URL says so in its own log line instead of looking identical to a fresh
    read.

    THE CLOCK IS INJECTED: every op takes `now_ms` (a caller-supplied monotonic
    reading), so the cache is fully deterministic under test — there is no
    hidden `Date.now()`.

    ⚠ NEGATIVES ARE NOT CACHED. An unregistered name is re-read every time. A
    peer that has not yet published is the ordinary state during a rollout, and
    caching its absence would make the registry's convergence slower than the
    deploy's — the one behaviour a DNS replacement may not have."""

    var _directory: ServiceDirectory[Self.Store]
    var _ttl_ms: Int64
    var _cache: List[_CacheEntry]

    def __init__(
        out self, var directory: ServiceDirectory[Self.Store], ttl_ms: Int64
    ):
        """Construct over a moved-in `directory` with a `ttl_ms` entry lifetime.
        A larger TTL trades staleness-on-redeploy for fewer bucket reads."""
        self._directory = directory^
        self._ttl_ms = ttl_ms
        self._cache = List[_CacheEntry]()

    def into_directory(deinit self) -> ServiceDirectory[Self.Store]:
        """Recover the wrapped directory."""
        return self._directory^

    def directory(
        ref self,
    ) -> ref [self._directory] ServiceDirectory[Self.Store]:
        """Borrow the wrapped directory (e.g. to publish this service's own
        endpoint at boot, before entering the resolve loop)."""
        return self._directory

    @always_inline
    def ttl_ms(self) -> Int64:
        """The cache TTL in milliseconds."""
        return self._ttl_ms

    @always_inline
    def cache_len(self) -> Int:
        """Cached entry count (test / introspection helper)."""
        return len(self._cache)

    def _find(self, key: String) -> Int:
        """Index of `key` in the cache, or -1. Linear — the cache holds one row
        per peer, a handful of entries."""
        for i in range(len(self._cache)):
            if self._cache[i].key == key:
                return i
        return -1

    def _cached(self, key: String, now_ms: Int64) -> Optional[ResolveResult]:
        """A fresh cache hit for `key`, or None. `age < ttl` is a hit; an entry
        exactly at the TTL boundary is stale (so a 0-length TTL never serves
        from cache)."""
        var idx = self._find(key)
        if idx < 0:
            return Optional[ResolveResult]()
        var age = now_ms - self._cache[idx].read_at_ms
        if age >= self._ttl_ms:
            return Optional[ResolveResult]()
        return Optional[ResolveResult](
            ResolveResult.from_cache(
                String(self._cache[idx].value), String(key), age
            )
        )

    def _store_entry(mut self, key: String, value: String, now_ms: Int64):
        var idx = self._find(key)
        if idx >= 0:
            self._cache[idx].value = String(value)
            self._cache[idx].read_at_ms = now_ms
        else:
            self._cache.append(
                _CacheEntry(String(key), String(value), now_ms)
            )

    def resolve_endpoint(
        mut self, name: String, now_ms: Int64
    ) raises -> ResolveResult:
        """Resolve `name` -> URL, serving a fresh cache entry when there is one.
        The returned result says which happened and how stale it is."""
        var key = self._directory.endpoint_key(name)
        var hit = self._cached(key, now_ms)
        if hit:
            return hit.value().copy()
        var got = self._directory.resolve_endpoint(name)
        if got.found:
            self._store_entry(key, got.value, now_ms)
        return got^

    def invalidate(mut self, key: String):
        """Drop one OBJECT KEY from the cache so the next resolve reads through.
        Compose the key with `directory().endpoint_key(...)`."""
        var keep = List[_CacheEntry]()
        for i in range(len(self._cache)):
            if self._cache[i].key != key:
                keep.append(self._cache[i].copy())
        self._cache = keep^

    def clear(mut self):
        """Drop every cached entry."""
        self._cache = List[_CacheEntry]()
