# =============================================================================
# komira_objectstore/shared_in_memory_conditional_store.mojo
#   A THREAD-SAFE, SHARED in-process `ConditionalWriteStore`
# =============================================================================
#
# A `ConditionalWriteStore` conformer whose state is SHARED across `clone()`s
# (one logical store, many handles) and protected by an atomic spinlock, so
# K real OS-thread writers can race the SAME manifest-append CAS lineage
# OFFLINE — characterizing the pure-CAS-loop contention distribution (412
# rate, p50/p99/p999, terminal-fail, livelock bound) WITHOUT a live object
# store. This is the offline twin of the live-MinIO C-4 gate: it exercises the
# IDENTICAL `CasManifestStore` append loop under genuine concurrency, isolating
# the CAS-manifest contention behavior from any backend transport.
#
# DIFFERENCE FROM `InMemoryConditionalStore`: that one is single-threaded and
# each value is independent (each test gets a fresh map). THIS one SHARES its
# map across clones via `ArcPointer[_SharedMap]`, so `store.clone()` handed to
# each writer thread reaches the SAME entries — that is what makes K threads
# actually contend on one manifest. The shared map is guarded by an
# `Atomic[int32]` spinlock (acquire/release around every map mutation/read).
#
# CONDITIONAL-WRITE SEMANTICS: identical to the single-threaded store —
# If-None-Match create-if-absent (412 on a lost slot), If-Match CAS,
# monotone-integer etags, 404 on missing. The spinlock makes each verb
# LINEARIZABLE, which is exactly the S3 conditional-write contract (S3
# linearizes conditional PUTs server-side; the spinlock models that).
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins / `unsafe_from_address`.
#   * Shared state behind `ArcPointer` (the sanctioned shared-ownership
#     pointer — this is genuinely shared cross-thread
#     state, the canonical ArcPointer use, not a fork-join barrier nor a
#     List-element Copyable hack). The lock is an `Atomic`, not a wildcard.
# =============================================================================

from komira_atomic_alias import AtomicI32
from std.memory import alloc, ArcPointer, OwnedPointer, UnsafePointer

from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


@fieldwise_init
struct _SharedEntry(Movable, Copyable, Deinitable):
    var key: String
    var bytes: List[UInt8]
    var etag: String


struct _SharedMap(Movable, Deinitable):
    """The shared map + an atomic spinlock guarding it. One instance per
    logical store, shared across all clones via ArcPointer.

    The lock is `OwnedPointer[Atomic[int32]]` because `Atomic` is
    non-movable — it cannot be a direct field of a Movable struct (the
    async notify pattern). The heap slot is stable for the map's lifetime.

    OP COUNTERS (`n_get` / `n_head` / `n_put` / `n_get_range`): per-verb call
    tallies, shared across every clone (they live in this Arc-shared map). They
    let an OFFLINE test assert the EXACT object-store op count of a broker
    operation (the win of an op-elision is invisible on a single-MinIO rig —
    same latency, one fewer round-trip — but is exact + deterministic on this
    in-memory conformer). Mutated under the spinlock, alongside the verb's map
    access, so the count is linearizable with the verb itself."""

    var entries: List[_SharedEntry]
    # key -> its position in `entries`, kept in step with every insert and
    # delete. Every verb looks its key up; a linear scan cost a key compare
    # per stored object on each lookup, which dominated tests that replay a
    # long manifest lineage.
    var index: Dict[String, Int]
    var etag_counter: Int64
    var lock: OwnedPointer[AtomicI32]  # 0 = free, 1 = held
    var n_get: Int64
    var n_head: Int64
    var n_put: Int64
    var n_get_range: Int64
    var n_list: Int64
    # BYTE COUNTERS (`b_get` / `b_put`) — the payload volume that crossed the
    # store boundary, tallied under the SAME spinlock as the verb that moved it.
    #
    # Why bytes and not just ops: an op count alone cannot tell "we read 3 small
    # objects" from "we read the whole repository". A git host's closure walk
    # over the current refs issues one GET per object already in the repo, so its op count
    # AND its byte volume are both O(repo) — and only the byte figure is
    # comparable against the size of the push that triggered it. A GET-count
    # assertion catches the round-trip cost; a byte assertion catches the
    # bandwidth + resident-memory cost. The O(N)-vs-O(new) question needs both.
    #
    # `b_get` counts `get` + `get_range` response bytes; `b_put` counts
    # `conditional_put` (hence `put` / `compare_and_swap`) request bytes,
    # INCLUDING writes that then fail their precondition — a 412 still spent the
    # upload. Test-substrate-only, additive; zero production behavior.
    var b_get: Int64
    var b_put: Int64
    # ADAPTIVE INDEX SHARDING: a SECOND LIST tally that counts
    # ONLY LISTs whose prefix contains the `/_lineage/` shard-discovery segment.
    # The total `n_list` mixes the WAL-head + catalog-enumeration LISTs the
    # dual-tier LEAF issues with the ONE shard-DISCOVERY LIST; this counter
    # isolates the discovery LIST so a falsifier can assert the
    # ZERO-LIST steady state precisely (the 2nd+ read serves discovery from the
    # per-index cache). Test-substrate-only, additive; zero production behavior.
    var n_list_lineage: Int64

    def __init__(out self):
        self.entries = List[_SharedEntry]()
        self.index = Dict[String, Int]()
        self.etag_counter = Int64(0)
        var raw = alloc[AtomicI32](1)
        raw[] = AtomicI32(Int32(0))
        self.lock = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw
        )
        self.n_get = Int64(0)
        self.n_head = Int64(0)
        self.n_put = Int64(0)
        self.n_get_range = Int64(0)
        self.n_list = Int64(0)
        self.b_get = Int64(0)
        self.b_put = Int64(0)
        self.n_list_lineage = Int64(0)


struct SharedInMemoryConditionalStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """THREAD-SAFE, clone-shared `ConditionalWriteStore` (offline C-4 twin).

    `clone()` shares the SAME `_map` (Arc) so K writer threads contend on one
    manifest. Every verb acquires the spinlock, mutates/reads the shared map,
    and releases — modelling S3's server-side linearization of conditional
    writes. Use for the offline K-thread CAS contention characterization.
    """

    var _map: ArcPointer[_SharedMap]

    def __init__(out self):
        self._map = ArcPointer[_SharedMap](_SharedMap())

    def __init__(out self, var map: ArcPointer[_SharedMap]):
        self._map = map^

    def clone(self) -> Self:
        """Return a handle SHARING the same underlying map (Arc copy). This
        is what makes K writer threads contend on ONE manifest."""
        return Self(map=self._map.copy())

    # ---- spinlock helpers (acquire/release around shared-map access) ----

    @always_inline
    def _acquire(self):
        # SAFETY (interior mut via Arc): the lock is an Atomic in the shared
        # _SharedMap; concurrent acquire from K threads is the whole point.
        # Spin on CAS 0→1. The critical sections are short: a keyed verb is
        # one index lookup plus a copy of the object's bytes; only `list`
        # and `delete` walk every entry. So a spin (no futex) is fine for the
        # offline characterization.
        ref m = self._map[]
        while True:
            var expected = Int32(0)
            if m.lock[].compare_exchange(expected, Int32(1)):
                return

    @always_inline
    def _release(self):
        ref m = self._map[]
        AtomicI32.store(
            UnsafePointer(to=m.lock[]).unsafe_bitcast[Scalar[DType.int32]](), Int32(0)
        )

    def _find(self, key: String) -> Int:
        var hit = self._map[].index.get(key)
        if hit:
            return hit.value()
        return -1

    def _next_etag(self) -> String:
        ref m = self._map[]
        m.etag_counter += Int64(1)
        return String('"') + String(m.etag_counter) + String('"')

    # ---- op-count accessors (offline op-elision assertions) ----
    # Read the per-verb call tallies (shared across every clone of this store).
    # Used by OFFLINE tests to assert the EXACT object-store op count of a
    # broker op — the only place the op-elision win is observable (a single
    # round-trip is identical wall-time on a single-MinIO rig; the op count is
    # exact + deterministic here). Each acquires the spinlock for a consistent
    # read (the verbs mutate these under the same lock).

    def n_get(self) -> Int64:
        self._acquire()
        var v = self._map[].n_get
        self._release()
        return v

    def n_head(self) -> Int64:
        self._acquire()
        var v = self._map[].n_head
        self._release()
        return v

    def n_put(self) -> Int64:
        self._acquire()
        var v = self._map[].n_put
        self._release()
        return v

    def n_get_range(self) -> Int64:
        self._acquire()
        var v = self._map[].n_get_range
        self._release()
        return v

    def n_list(self) -> Int64:
        """The LIST (`list_with_delimiter`) call tally — the round-trip the
        sub-lineage serve path's authoritative head reads + shard enumeration
        issue. Used by the SERVE-PERF op-elision proof: the cache removes the
        crash-fix's redundant `_base` + per-shard authoritative LISTs."""
        self._acquire()
        var v = self._map[].n_list
        self._release()
        return v

    def n_list_lineage(self) -> Int64:
        """The shard-DISCOVERY LIST tally — LISTs whose prefix contains the
        `/_lineage/` segment (adaptive-index-sharding read discovery). The
        discovery falsifier asserts this is EXACTLY 1 on the first read of a
        fresh 1-shard index and 0 on every subsequent unchanged read (served from
        the per-index discovery cache — the zero-overhead proof).
        Isolated from `n_list` (which also counts the LEAF's WAL-head + catalog
        LISTs). Shared across every clone."""
        self._acquire()
        var v = self._map[].n_list_lineage
        self._release()
        return v

    def b_get(self) -> Int64:
        """Total response BYTES returned by `get` + `get_range`. The read volume
        that crossed the store boundary — the figure that makes an O(repo) read
        distinguishable from an O(new-objects) one at a single repo size."""
        self._acquire()
        var v = self._map[].b_get
        self._release()
        return v

    def b_put(self) -> Int64:
        """Total request BYTES handed to `conditional_put` (hence `put` /
        `compare_and_swap`), INCLUDING writes whose precondition then failed — a
        412 still spent the upload."""
        self._acquire()
        var v = self._map[].b_put
        self._release()
        return v

    def reset_op_counts(self):
        """Zero all op AND byte counters (so a test can isolate the ops of ONE
        subsequent operation from any setup/warm-up traffic)."""
        self._acquire()
        ref m = self._map[]
        m.n_get = Int64(0)
        m.n_head = Int64(0)
        m.n_put = Int64(0)
        m.n_get_range = Int64(0)
        m.n_list = Int64(0)
        m.b_get = Int64(0)
        m.b_put = Int64(0)
        m.n_list_lineage = Int64(0)
        self._release()

    # ---- ObjectStore base surface ----

    def head(self, path: Path) raises -> ObjectMeta:
        self._acquire()
        self._map[].n_head += Int64(1)
        var idx = self._find(path.raw())
        if idx < 0:
            self._release()
            raise Error(
                "SharedInMemoryConditionalStore.head: not_found (404) key="
                + path.raw()
            )
        ref e = self._map[].entries[idx]
        var out = ObjectMeta(
            e.key, Int64(len(e.bytes)), e.etag, Int64(-1), String("")
        )
        self._release()
        return out^

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        self._acquire()
        self._map[].n_list += Int64(1)
        var p = prefix.raw()
        # Isolate the shard-DISCOVERY LIST (the `/_lineage/` keyspace) from the
        # LEAF's WAL-head + catalog LISTs (adaptive index sharding).
        if p.find("/_lineage/") >= 0:
            self._map[].n_list_lineage += Int64(1)
        var objects = List[ObjectMeta]()
        ref m = self._map[]
        for i in range(len(m.entries)):
            ref e = m.entries[i]
            if _starts_with(e.key, p):
                objects.append(
                    ObjectMeta(
                        e.key,
                        Int64(len(e.bytes)),
                        e.etag,
                        Int64(-1),
                        String(""),
                    )
                )
        self._release()
        return ListResult(objects^, List[String]())

    def coalesce_policy(self) -> CoalescePolicy:
        return CoalescePolicy.default()

    # ---- ConditionalWriteStore surface ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._acquire()
        self._map[].n_put += Int64(1)
        # Tallied BEFORE the precondition check on purpose: a 412 still spent the
        # upload bytes on the wire against a real backend.
        self._map[].b_put += Int64(len(bytes))
        var key = path.raw()
        var idx = self._find(key)
        var exists = idx >= 0
        if precond.is_create():
            if exists:
                self._release()
                raise Error(
                    "SharedInMemoryConditionalStore.conditional_put:"
                    " precondition (412) — key exists (If-None-Match): " + key
                )
        elif precond.is_if_match():
            if not exists:
                self._release()
                raise Error(
                    "SharedInMemoryConditionalStore.conditional_put:"
                    " precondition (412) — If-Match on absent key: " + key
                )
            if self._map[].entries[idx].etag != precond.etag:
                self._release()
                raise Error(
                    "SharedInMemoryConditionalStore.conditional_put:"
                    " precondition (412) — If-Match etag mismatch: " + key
                )
        var new_etag = self._next_etag()
        ref m = self._map[]
        if exists:
            m.entries[idx].bytes = bytes.copy()
            m.entries[idx].etag = new_etag
        else:
            m.index[key] = len(m.entries)
            m.entries.append(_SharedEntry(key, bytes.copy(), new_etag))
        var out = ObjectMeta(
            key, Int64(len(bytes)), new_etag^, Int64(-1), String("")
        )
        self._release()
        return out^

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.conditional_put(path, bytes, WritePrecondition.none())

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        if length <= Int64(0):
            return List[UInt8]()
        self._acquire()
        self._map[].n_get_range += Int64(1)
        var idx = self._find(path.raw())
        if idx < 0:
            self._release()
            raise Error(
                "SharedInMemoryConditionalStore.get_range: not_found (404)"
                " key=" + path.raw()
            )
        ref e = self._map[].entries[idx]
        var s = Int(start)
        var ln = Int(length)
        if s < 0 or s + ln > len(e.bytes):
            self._release()
            raise Error(
                "SharedInMemoryConditionalStore.get_range: out-of-range key="
                + path.raw()
            )
        var out = List[UInt8]()
        for i in range(s, s + ln):
            out.append(e.bytes[i])
        self._map[].b_get += Int64(len(out))
        self._release()
        return out^

    def get(self, path: Path) raises -> List[UInt8]:
        self._acquire()
        self._map[].n_get += Int64(1)
        var idx = self._find(path.raw())
        if idx < 0:
            self._release()
            raise Error(
                "SharedInMemoryConditionalStore.get: not_found (404) key="
                + path.raw()
            )
        var out = self._map[].entries[idx].bytes.copy()
        self._map[].b_get += Int64(len(out))
        self._release()
        return out^

    def delete(self, path: Path) raises -> None:
        self._acquire()
        var key = path.raw()
        var keep = List[_SharedEntry]()
        ref m = self._map[]
        for i in range(len(m.entries)):
            if m.entries[i].key != key:
                keep.append(m.entries[i].copy())
        m.entries = keep^
        m.index = Dict[String, Int]()
        for i in range(len(m.entries)):
            m.index[m.entries[i].key] = i
        self._release()


@always_inline
def _starts_with(s: String, prefix: String) -> Bool:
    if prefix.byte_length() == 0:
        return True
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(sb) < len(pb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True
