# =============================================================================
# komira_objectstore/in_memory_conditional_store.mojo
#   An in-process `ConditionalWriteStore` for offline CAS tests
# =============================================================================
#
# A `ConditionalWriteStore` conformer backed by an in-process map. It lets the
# shared `CasManifestStore[Store]` protocol run OFFLINE (CI without a live
# MinIO) over the IDENTICAL append CAS loop — only the backend differs. The
# offline no-gap property test instantiates
# `CasManifestStore[InMemoryConditionalStore]` and asserts the linearizable-
# append invariant without any network.
#
# CONDITIONAL-WRITE SEMANTICS (the part that matters): the in-memory store
# faithfully models the S3 conditional-write contract the protocol relies on:
#   * `If-None-Match: *` (create-if-absent): succeeds iff the key is ABSENT;
#     otherwise raises a precondition error (the 412 the loser sees).
#   * `If-Match: <etag>`: succeeds iff the current etag matches; else
#     precondition error.
#   * etag is a monotone integer rendered as a String (one per successful
#     write) — opaque at the trait boundary, exactly like S3.
#   * a missing key on `get` / `get_range` raises a not-found error (404).
#
# INTERIOR MUTABILITY: the `ConditionalWriteStore` trait surface takes an
# IMMUTABLE `self` (e.g. `def conditional_put(self, ...)`) — the same reason
# `S3ConditionalStore` reaches its per-pthread transport through
# `Slab.get_mut_interior`. The in-memory store holds its mutable map in a
# length-1 `Slab[_InnerState]` and reaches it MUTABLY from an immutable `self`
# via `Slab.get_mut_interior(0)` — the blessed interior-mutability primitive
# (Mojo's `UnsafeCell` / C++ `mutable` analog), exactly mirroring the S3
# conformer. The wildcard origin is laundered INSIDE the Slab primitive; it
# never escapes a method signature, and no UnsafePointer appears in any public
# signature.
#
# THREADING: this store is SINGLE-THREADED. It models conditional-write
# CORRECTNESS for the offline property test (a deterministic interleaving of
# K logical writers on one thread — the no-gap invariant does not require
# OS-level concurrency to falsify a broken CAS loop). The LIVE C-4
# contention/latency characterization runs against real MinIO with K real OS
# threads (test_s3_minio_e2e_cas_manifest_stress); that is where genuine
# concurrency is exercised. Keeping the in-memory store single-threaded avoids
# pulling a mutex primitive into komira_objectstore.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins / `unsafe_from_address`.
#   * Storage is a plain `List[_Entry]` (key/bytes/etag as owned String /
#     List[UInt8]) inside `_InnerState`, held in a length-1 `Slab` — NOT a
#     byte-slab-with-wildcard element (the wildcard is laundered inside the
# Slab primitive, never on a field type), so heap-reuse N/A.
# =============================================================================

from komira_core.collections.slab import Slab

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


@fieldwise_init
struct _Entry(Movable, Copyable, Deinitable):
    var key: String
    var bytes: List[UInt8]
    var etag: String


struct _InnerState(Movable, Deinitable):
    """The mutable map state, held in a length-1 Slab for interior
    mutability (the trait verbs take immutable `self`)."""

    var entries: List[_Entry]
    var etag_counter: Int64

    def __init__(out self):
        self.entries = List[_Entry]()
        self.etag_counter = Int64(0)

    def find(self, key: String) -> Int:
        for i in range(len(self.entries)):
            if self.entries[i].key == key:
                return i
        return -1

    def next_etag(mut self) -> String:
        self.etag_counter += Int64(1)
        return String('"') + String(self.etag_counter) + String('"')


struct InMemoryConditionalStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """In-process `ConditionalWriteStore` conformer (offline test backend).

    Models the S3 conditional-write contract: create-if-absent, If-Match
    CAS, monotone-integer etags, 404 on missing, 412 on precondition fail.
    Single-threaded (see module header). Mutable state lives in a length-1
    `Slab[_InnerState]`, reached via `get_mut_interior(0)` for
    trait-immutable-self interior mutability (mirrors `S3ConditionalStore`).
    """

    var _state: Slab[_InnerState]

    def __init__(out self):
        var slab = Slab[_InnerState]()
        slab.append(_InnerState())
        self._state = slab^

    # ---- ObjectStore base surface ----

    def head(self, path: Path) raises -> ObjectMeta:
        # SAFETY (get_mut_interior): single-threaded store, only slot 0,
        # `self` outlives the ref; no realloc (slab sized 1, never grown).
        ref st = self._state.get_mut_interior(0)
        var idx = st.find(path.raw())
        if idx < 0:
            raise Error(
                "InMemoryConditionalStore.head: not_found (404) key="
                + path.raw()
            )
        ref e = st.entries[idx]
        return ObjectMeta(
            e.key, Int64(len(e.bytes)), e.etag, Int64(-1), String("")
        )

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        ref st = self._state.get_mut_interior(0)
        var p = prefix.raw()
        var objects = List[ObjectMeta]()
        for i in range(len(st.entries)):
            ref e = st.entries[i]
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
        return ListResult(objects^, List[String]())

    def coalesce_policy(self) -> CoalescePolicy:
        return CoalescePolicy.default()

    # ---- ConditionalWriteStore surface ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        ref st = self._state.get_mut_interior(0)
        var key = path.raw()
        var idx = st.find(key)
        var exists = idx >= 0
        if precond.is_create():
            if exists:
                raise Error(
                    "InMemoryConditionalStore.conditional_put: precondition"
                    " (412) — key already exists (If-None-Match): " + key
                )
        elif precond.is_if_match():
            if not exists:
                raise Error(
                    "InMemoryConditionalStore.conditional_put: precondition"
                    " (412) — If-Match on absent key: " + key
                )
            if st.entries[idx].etag != precond.etag:
                raise Error(
                    "InMemoryConditionalStore.conditional_put: precondition"
                    " (412) — If-Match etag mismatch: " + key
                )
        # NONE or satisfied precondition: write.
        var new_etag = st.next_etag()
        if exists:
            st.entries[idx].bytes = bytes.copy()
            st.entries[idx].etag = new_etag
        else:
            st.entries.append(_Entry(key, bytes.copy(), new_etag))
        return ObjectMeta(
            key, Int64(len(bytes)), new_etag^, Int64(-1), String("")
        )

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
        ref st = self._state.get_mut_interior(0)
        var idx = st.find(path.raw())
        if idx < 0:
            raise Error(
                "InMemoryConditionalStore.get_range: not_found (404) key="
                + path.raw()
            )
        ref e = st.entries[idx]
        var s = Int(start)
        var ln = Int(length)
        if s < 0 or s + ln > len(e.bytes):
            raise Error(
                "InMemoryConditionalStore.get_range: out-of-range read key="
                + path.raw()
            )
        var out = List[UInt8]()
        for i in range(s, s + ln):
            out.append(e.bytes[i])
        return out^

    def get(self, path: Path) raises -> List[UInt8]:
        ref st = self._state.get_mut_interior(0)
        var idx = st.find(path.raw())
        if idx < 0:
            raise Error(
                "InMemoryConditionalStore.get: not_found (404) key="
                + path.raw()
            )
        return st.entries[idx].bytes.copy()

    def delete(self, path: Path) raises -> None:
        ref st = self._state.get_mut_interior(0)
        var key = path.raw()
        var keep = List[_Entry]()
        for i in range(len(st.entries)):
            if st.entries[i].key != key:
                keep.append(st.entries[i].copy())
        st.entries = keep^


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
