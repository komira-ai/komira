"""ServiceRegistry[Store] + ServiceResolver[Store] acceptance gate.

Hermetic (no live bucket, no resource files) test for the service-reference
primitive (`komira_svcref.service_registry`) over the in-process
`SharedInMemoryConditionalStore` — which faithfully models the S3
conditional-write contract (create-if-absent, If-Match CAS, 412 on
precondition, 404 on missing).

Gates:

  1. ROUND-TRIP:  register(name, url) then resolve(name) -> url.
  2. ABSENT:      resolve of an unregistered name -> None (not a raise).
  3. OVERWRITE:   re-register (redeploy) the same name -> last-writer-wins;
                  resolve returns the new URL.
  4. CONCURRENT-CAS RETRY (THE concurrency thesis — register is a single-object
                  CAS with a retry-once on 412): a competing write lands BETWEEN
                  the victim's `head` and its `compare_and_swap` (injected
                  deterministically by `_RacingOnceStore`), so the victim's CAS
                  412s, register RE-READS the fresh etag and RETRIES, and the
                  retry commits the victim's URL (last-writer-wins). Final value
                  is the victim's — proof the retry ran and won.
  5. LIST:        list() returns every registered service name.
  6. TTL CACHE:   ServiceResolver serves the cached URL WITHIN the TTL (a
                  redeploy is not observed until the entry expires), and reads
                  THROUGH after expiry (picking up the new URL). The clock is
                  INJECTED as `now_ms`, so the boundary is deterministic; a
                  manual `invalidate` forces a re-read even within the TTL.

No FFI, no vendor-static link — pure Mojo over the in-memory CAS conformer.
"""

from std.memory import ArcPointer

from komira_svcref.service_registry import (
    ServiceRegistry,
    ServiceResolver,
)

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# -----------------------------------------------------------------------------
# Assertion helpers.
# -----------------------------------------------------------------------------


def _eq(got: String, want: String, ctx: String) raises:
    if got != want:
        raise Error(ctx + ": expected '" + want + "' but got '" + got + "'")


def _eq_opt(got: Optional[String], want: String, ctx: String) raises:
    if not got:
        raise Error(ctx + ": expected '" + want + "' but got None")
    if got.value() != want:
        raise Error(
            ctx + ": expected '" + want + "' but got '" + got.value() + "'"
        )


def _expect_none(got: Optional[String], ctx: String) raises:
    if got:
        raise Error(ctx + ": expected None but got '" + got.value() + "'")


def _contains(names: List[String], want: String) -> Bool:
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


# -----------------------------------------------------------------------------
# Gate 1+2+3 — round-trip, absent, overwrite.
# -----------------------------------------------------------------------------


def test_register_resolve_roundtrip() raises:
    print("-- test_register_resolve_roundtrip --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(String("example-api"), String("http://api:8088"))
    _eq_opt(reg.resolve(String("example-api")), String("http://api:8088"), "resolve")
    print("   register -> resolve round-trip OK")


def test_resolve_absent_none() raises:
    print("-- test_resolve_absent_none --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    _expect_none(reg.resolve(String("nonexistent")), "absent resolve")
    print("   resolve of an unregistered name -> None OK")


def test_reregister_overwrites() raises:
    print("-- test_reregister_overwrites --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(String("worker"), String("http://worker-v1:9000"))
    _eq_opt(reg.resolve(String("worker")), String("http://worker-v1:9000"), "v1")
    # Redeploy: the same name is re-registered with a new URL (last-writer-wins).
    reg.register(String("worker"), String("http://worker-v2:9000"))
    _eq_opt(reg.resolve(String("worker")), String("http://worker-v2:9000"), "v2")
    print("   re-register (redeploy) overwrites the URL OK")


# -----------------------------------------------------------------------------
# Gate 4 — concurrent-CAS retry via a deterministic race-once store decorator.
# -----------------------------------------------------------------------------


struct _InjectCell(Movable, Deinitable):
    """The interior-mutable state of the race-once decorator: `fired` (has the
    one competing write been injected yet) + the competitor's URL. Shared via
    `ArcPointer` so the immutable-`self` `head` can flip `fired`."""

    var fired: Bool
    var competitor: String

    def __init__(out self, var competitor: String):
        self.fired = False
        self.competitor = competitor^


struct _RacingOnceStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """A `ConditionalWriteStore` decorator that injects EXACTLY ONE competing
    write on the FIRST `head` call. It reads the inner store's current etag,
    then (once) commits a competitor's URL under that etag — moving the etag —
    and returns the PRE-competition etag to the caller. So the caller's
    subsequent `compare_and_swap(expected=<that stale etag>)` sees a moved etag
    and 412s: exactly the true-concurrency race a live bucket produces, made
    deterministic and single-threaded. Every other verb delegates to the inner
    store unchanged.

    This lets `ServiceRegistry.register`'s 412 -> re-read -> retry-once path be
    exercised WITHOUT threads."""

    var _inner: SharedInMemoryConditionalStore
    var _cell: ArcPointer[_InjectCell]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var competitor: String,
    ):
        self._inner = inner^
        self._cell = ArcPointer[_InjectCell](_InjectCell(competitor^))

    # ---- ObjectStore surface ----

    def head(self, path: Path) raises -> ObjectMeta:
        var meta = self._inner.head(path)  # current etag (propagates a 404)
        if not self._cell[].fired:
            self._cell[].fired = True
            # The competing registrant commits its URL under the etag we just
            # read, moving the object off `meta.etag`.
            var cb = self._cell[].competitor.as_bytes()
            var bytes = List[UInt8](capacity=len(cb))
            for i in range(len(cb)):
                bytes.append(cb[i])
            _ = self._inner.compare_and_swap(path, bytes, meta.etag)
        return meta^  # caller gets the PRE-competition etag -> its CAS 412s

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface (all straight delegation) ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def test_register_concurrent_cas_retry() raises:
    print("-- test_register_concurrent_cas_retry --")
    var store = SharedInMemoryConditionalStore()

    # Seed the object so the victim register takes the UPDATE (If-Match) path.
    var seed = ServiceRegistry(store.clone())
    seed.register(String("svc"), String("http://a"))
    _eq_opt(
        ServiceRegistry(store.clone()).resolve(String("svc")),
        String("http://a"),
        "seed",
    )

    # The victim registers "http://b". On its first head, `_RacingOnceStore`
    # injects a competitor write ("http://c") that moves the etag, so the
    # victim's CAS 412s; register re-reads the fresh etag and retries, and the
    # retry commits "http://b".
    var racing = _RacingOnceStore(store.clone(), String("http://c"))
    var reg = ServiceRegistry(racing^)
    reg.register(String("svc"), String("http://b"))

    # Final value is the victim's URL — NOT the competitor's ("http://c").
    # That the value is "http://b" and register did NOT raise proves the 412
    # was hit, re-read, retried, and won (last-writer-wins after contention).
    _eq_opt(
        ServiceRegistry(store.clone()).resolve(String("svc")),
        String("http://b"),
        "after CAS retry",
    )
    print("   victim 412'd on the injected race, retried, and committed OK")


# -----------------------------------------------------------------------------
# Gate 5 — list every registered service name.
# -----------------------------------------------------------------------------


def test_list_all_names() raises:
    print("-- test_list_all_names --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(String("example-api"), String("http://api"))
    reg.register(String("worker"), String("http://worker"))
    reg.register(String("project-manager"), String("http://scheduler"))

    var names = reg.list()
    if len(names) != 3:
        raise Error("list expected 3 names, got " + String(len(names)))
    if not _contains(names, String("example-api")):
        raise Error("list missing 'example-api'")
    if not _contains(names, String("worker")):
        raise Error("list missing 'worker'")
    if not _contains(names, String("project-manager")):
        raise Error("list missing 'project-manager'")
    print("   list() returned all 3 registered names OK")


# -----------------------------------------------------------------------------
# Gate 6 — TTL cache: cached within TTL, reads through after expiry.
# -----------------------------------------------------------------------------


def test_resolver_ttl_cache() raises:
    print("-- test_resolver_ttl_cache --")
    var store = SharedInMemoryConditionalStore()

    var reg = ServiceRegistry(store.clone())
    reg.register(String("api"), String("http://api-v1"))

    # TTL = 1000 ms. The resolver OWNS `reg`; a redeploy is written via a
    # SEPARATE registry on a shared clone (the same underlying map).
    var resolver = ServiceResolver(reg^, Int64(1000))
    var deploy = ServiceRegistry(store.clone())

    # t=0: cache miss -> read through -> v1; cached with expiry=1000.
    _eq_opt(resolver.resolve(String("api"), Int64(0)), String("http://api-v1"), "t=0 miss")
    if resolver.cache_len() != 1:
        raise Error("expected 1 cached entry after first resolve")

    # Redeploy: the bucket URL becomes v2 (behind the resolver's back).
    deploy.register(String("api"), String("http://api-v2"))

    # t=500 (< TTL): STILL served from cache -> v1 (the redeploy is not yet
    # observed — this is the whole point of the TTL).
    _eq_opt(
        resolver.resolve(String("api"), Int64(500)),
        String("http://api-v1"),
        "t=500 within TTL (cached)",
    )

    # t=1000 (== expiry, treated as stale): reads THROUGH -> v2; re-cached with
    # expiry=2000.
    _eq_opt(
        resolver.resolve(String("api"), Int64(1000)),
        String("http://api-v2"),
        "t=1000 expired (read-through)",
    )

    # t=1200 (< new expiry): served from cache -> v2.
    _eq_opt(
        resolver.resolve(String("api"), Int64(1200)),
        String("http://api-v2"),
        "t=1200 within new TTL (cached)",
    )

    # invalidate forces a re-read even within the TTL — picks up v3 immediately.
    deploy.register(String("api"), String("http://api-v3"))
    resolver.invalidate(String("api"))
    _eq_opt(
        resolver.resolve(String("api"), Int64(1300)),
        String("http://api-v3"),
        "after invalidate (forced read-through)",
    )

    # An unregistered name resolves to None and caches nothing.
    _expect_none(resolver.resolve(String("ghost"), Int64(1400)), "ttl absent")
    print("   TTL cache: within-TTL hit, post-expiry read-through, invalidate OK")


def main() raises:
    print("== ServiceRegistry + ServiceResolver CAS gate ==")
    test_register_resolve_roundtrip()
    test_resolve_absent_none()
    test_reregister_overwrites()
    test_register_concurrent_cas_retry()
    test_list_all_names()
    test_resolver_ttl_cache()
    print("== ALL GATES PASSED ==")
