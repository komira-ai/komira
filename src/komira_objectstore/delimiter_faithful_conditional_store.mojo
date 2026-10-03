# =============================================================================
# komira_objectstore/delimiter_faithful_conditional_store.mojo
#   S-5 — a DELIMITER-FAITHFUL, clone-shared in-process `ConditionalWriteStore`.
# =============================================================================
#
# THE PRODUCTION-BUG CLASS THIS STORE EXPOSES (the recurring LIST-delimiter
# trap, hit 3x in the broker rollout — see the team-lead memory
# "Real-S3 LIST-delimiter trap"):
#
#   Code that enumerates object-store sub-dirs via `list_with_delimiter(prefix,
#   '/')` and folds ONLY `listed.objects` (never `listed.common_prefixes`)
#   returns EMPTY for any keys that live one level DEEPER than the prefix, on a
#   real S3 / GCS backend — but PASSES on the in-memory store, which IGNORES the
#   delimiter and returns EVERY key under the prefix in `objects` (a recursive
#   prefix match, `common_prefixes` always empty). So an objects-only fold
#   silently regresses to EMPTY on real S3/GCS while every offline test is green.
#
# THE REAL S3/GCS SEMANTIC (what this store models, which `InMemoryConditional
# Store.list_with_delimiter` OMITS): given the delimiter '/', a LIST of `prefix`
# returns:
#   * `objects`         — keys whose remainder AFTER `prefix` contains NO further
#                         '/' (i.e. DIRECT children / leaf files under prefix).
#   * `common_prefixes` — for every key whose remainder DOES contain a '/', the
#                         truncated `prefix + <first segment> + '/'`, DEDUPED
#                         (the "sub-directory" rollups). The deeper key itself is
#                         NOT in `objects`.
#
# So a key `p/manifest/000...0.chunk` listed at prefix `p/manifest/` is a leaf
# (no '/' after the prefix) -> it lands in `objects` (correct: an objects-only
# fold of THAT prefix is sound). But a key `p/_meta/dedup/<pid>/<seq>.seq`
# listed at prefix `p/_meta/dedup/` has a '/' after the prefix -> it lands ONLY
# in `common_prefixes` as `p/_meta/dedup/<pid>/`, and an objects-only fold of
# that prefix returns EMPTY. THIS is the trap; this store reproduces it exactly,
# so any commit/recovery enumeration that folds objects-only over a NESTED
# prefix goes RED here while staying green on the plain in-memory twin.
#
# THE SHARED, CLONEABLE SHAPE (mirrors `SharedInMemoryConditionalStore`): the
# map is behind `ArcPointer[_DfSharedMap]` + an atomic spinlock, so `clone()`
# yields a handle SHARING the same backing bytes. This is what lets the
# C-LIST-DELIMITER recovery test commit on handle A and drive a COLD
# `TableStore.open` recovery on a fresh handle B over the SAME committed bucket
# (the same idiom the SI-property + concurrency harnesses use) — a true
# bucket-is-truth recovery whose ONLY input is the faithful-listing store.
#
# This is a TEST-SUPPORT store (sibling of `InMemoryConditionalStore` /
# `SharedInMemoryConditionalStore` / `shared_in_memory_slow_cas_store`).
# Everything EXCEPT `list_with_delimiter` matches the in-memory contract
# (conditional_put / If-None-Match / If-Match / get / get_range / delete / head /
# monotone-integer etags / 404 / 412), so
# `CasManifestStore[DelimiterFaithfulConditionalStore]` + a `TableStore` over it
# exercise the SAME append/recovery protocol, just with REAL delimiter listing.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * Shared state behind `ArcPointer` (the sanctioned shared-ownership pointer;
#     this is genuinely shared state across clones, the
#     canonical ArcPointer use, exactly like `SharedInMemoryConditionalStore`,
#     NOT a fork-join barrier nor a List-element Copyable hack). The lock is an
#     `Atomic`, not a wildcard. Storage is a plain `List[_DfSharedEntry]`
#     (key/bytes/etag as owned String / List[UInt8]) — NOT a byte-slab element,
# so heap-reuse is N/A.
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
struct _DfSharedEntry(Movable, Copyable, Deinitable):
    var key: String
    var bytes: List[UInt8]
    var etag: String


struct _DfSharedMap(Movable, Deinitable):
    """The shared map + an atomic spinlock guarding it. One instance per logical
    store, shared across all clones via ArcPointer. Mirrors
    `shared_in_memory_conditional_store._SharedMap`.

    The lock is `OwnedPointer[Atomic[int32]]` because `Atomic` is non-movable —
    it cannot be a direct field of a Movable struct (the async notify pattern).
    The heap slot is stable for the map's lifetime."""

    var entries: List[_DfSharedEntry]
    var etag_counter: Int64
    var lock: OwnedPointer[AtomicI32]  # 0 = free, 1 = held

    def __init__(out self):
        self.entries = List[_DfSharedEntry]()
        self.etag_counter = Int64(0)
        var raw = alloc[AtomicI32](1)
        raw[] = AtomicI32(Int32(0))
        self.lock = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw
        )


struct DelimiterFaithfulConditionalStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A clone-shared `ConditionalWriteStore` whose `list_with_delimiter`
    faithfully splits results into `objects` (direct children) vs
    `common_prefixes` (sub-directory rollups) — the REAL S3/GCS delimiter
    semantic the plain `InMemoryConditionalStore` OMITS (it dumps every key
    under the prefix into `objects`).

    Use this to PROVE a commit / recovery enumeration folds
    `objects ∪ seq-bearing(common_prefixes)` and not objects-only: a
    nested-prefix enumeration that folds objects-only returns EMPTY here while
    passing on the plain in-memory twin (the LIST-delimiter trap, S-5).

    `clone()` shares the SAME `_map` (Arc) so a writer handle and a fresh
    recovery handle transact over ONE bucket — the bucket-is-truth recovery
    idiom. Every verb acquires the spinlock (LINEARIZABLE, modelling S3's
    server-side conditional-write linearization)."""

    var _map: ArcPointer[_DfSharedMap]

    def __init__(out self):
        self._map = ArcPointer[_DfSharedMap](_DfSharedMap())

    def __init__(out self, var map: ArcPointer[_DfSharedMap]):
        self._map = map^

    def clone(self) -> Self:
        """Return a handle SHARING the same underlying map (Arc copy)."""
        return Self(map=self._map.copy())

    # ---- spinlock helpers (acquire/release around shared-map access) ----

    @always_inline
    def _acquire(self):
        # SAFETY (interior mut via Arc): the lock is an Atomic in the shared
        # _DfSharedMap. Spin on CAS 0->1; the critical sections are O(entries)
        # and tiny, so a spin (no futex) is fine for the offline test.
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
        ref m = self._map[]
        for i in range(len(m.entries)):
            if m.entries[i].key == key:
                return i
        return -1

    def _next_etag(self) -> String:
        ref m = self._map[]
        m.etag_counter += Int64(1)
        return String('"') + String(m.etag_counter) + String('"')

    # ---- ObjectStore base surface ----

    def head(self, path: Path) raises -> ObjectMeta:
        self._acquire()
        var idx = self._find(path.raw())
        if idx < 0:
            self._release()
            raise Error(
                "DelimiterFaithfulConditionalStore.head: not_found (404) key="
                + path.raw()
            )
        ref e = self._map[].entries[idx]
        var out = ObjectMeta(
            e.key, Int64(len(e.bytes)), e.etag, Int64(-1), String("")
        )
        self._release()
        return out^

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        """THE FAITHFUL DELIMITER LIST (the whole point of this store).

        For every entry whose key starts with `prefix`, look at the remainder
        AFTER the prefix:
          * remainder has NO '/'  -> a DIRECT child / leaf -> add to `objects`.
          * remainder HAS a '/'   -> a sub-dir rollup -> add
            `prefix + <first segment> + '/'` to `common_prefixes` (DEDUPED).
            The deeper key itself is NOT added to `objects` (the real S3/GCS
            CommonPrefixes behavior — a nested key is hidden behind its rollup).
        """
        self._acquire()
        var p = prefix.raw()
        var objects = List[ObjectMeta]()
        var common = List[String]()
        ref m = self._map[]
        for i in range(len(m.entries)):
            ref e = m.entries[i]
            if not _df_starts_with(e.key, p):
                continue
            var rest = _df_substr_from(e.key, p.byte_length())
            var slash = _df_find_slash(rest)
            if slash < 0:
                objects.append(
                    ObjectMeta(
                        e.key,
                        Int64(len(e.bytes)),
                        e.etag,
                        Int64(-1),
                        String(""),
                    )
                )
            else:
                var cp = p + _df_substr_range(rest, 0, slash + 1)
                var seen = False
                for j in range(len(common)):
                    if common[j] == cp:
                        seen = True
                        break
                if not seen:
                    common.append(cp^)
        self._release()
        return ListResult(objects^, common^)

    def coalesce_policy(self) -> CoalescePolicy:
        return CoalescePolicy.default()

    # ---- ConditionalWriteStore surface (matches InMemoryConditionalStore) ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._acquire()
        var key = path.raw()
        var idx = self._find(key)
        var exists = idx >= 0
        if precond.is_create():
            if exists:
                self._release()
                raise Error(
                    "DelimiterFaithfulConditionalStore.conditional_put:"
                    " precondition (412) — key already exists (If-None-Match): "
                    + key
                )
        elif precond.is_if_match():
            if not exists:
                self._release()
                raise Error(
                    "DelimiterFaithfulConditionalStore.conditional_put:"
                    " precondition (412) — If-Match on absent key: " + key
                )
            if self._map[].entries[idx].etag != precond.etag:
                self._release()
                raise Error(
                    "DelimiterFaithfulConditionalStore.conditional_put:"
                    " precondition (412) — If-Match etag mismatch: " + key
                )
        var new_etag = self._next_etag()
        if exists:
            self._map[].entries[idx].bytes = bytes.copy()
            self._map[].entries[idx].etag = new_etag
        else:
            self._map[].entries.append(_DfSharedEntry(key, bytes.copy(), new_etag))
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
        var idx = self._find(path.raw())
        if idx < 0:
            self._release()
            raise Error(
                "DelimiterFaithfulConditionalStore.get_range: not_found (404)"
                " key=" + path.raw()
            )
        ref e = self._map[].entries[idx]
        var s = Int(start)
        var ln = Int(length)
        if s < 0 or s + ln > len(e.bytes):
            self._release()
            raise Error(
                "DelimiterFaithfulConditionalStore.get_range: out-of-range"
                " read key=" + path.raw()
            )
        var out = List[UInt8]()
        for i in range(s, s + ln):
            out.append(e.bytes[i])
        self._release()
        return out^

    def get(self, path: Path) raises -> List[UInt8]:
        self._acquire()
        var idx = self._find(path.raw())
        if idx < 0:
            self._release()
            raise Error(
                "DelimiterFaithfulConditionalStore.get: not_found (404) key="
                + path.raw()
            )
        var out = self._map[].entries[idx].bytes.copy()
        self._release()
        return out^

    def delete(self, path: Path) raises -> None:
        self._acquire()
        var key = path.raw()
        ref m = self._map[]
        var keep = List[_DfSharedEntry]()
        for i in range(len(m.entries)):
            if m.entries[i].key != key:
                keep.append(m.entries[i].copy())
        m.entries = keep^
        self._release()


# =============================================================================
# String helpers (dependency-free; mirror in_memory_conditional_store._starts_with).
# =============================================================================


@always_inline
def _df_starts_with(s: String, prefix: String) -> Bool:
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


@always_inline
def _df_find_slash(s: String) -> Int:
    """Index of the first '/' in `s`, or -1 if none."""
    var sb = s.as_bytes()
    var slash = UInt8(ord("/"))
    for i in range(len(sb)):
        if sb[i] == slash:
            return i
    return -1


@always_inline
def _df_substr_from(s: String, start: Int) -> String:
    """The substring of `s` from byte index `start` to the end.

    ★ BYTE-FAITHFUL, and that is the whole point of this helper. Rebuilding
    the result with `out += chr(Int(sb[i]))` is a LATIN-1 RE-ENCODE: `chr` maps
    a byte to the CODEPOINT of that number and appending a codepoint
    UTF-8-encodes it, so every byte >= 0x80 comes back out as the TWO bytes of
    its Latin-1 codepoint (0xE6 -> U+00E6 -> `0xC3 0xA6`).

    That would make `list_with_delimiter`'s common prefix a prefix of NO key in
    this same store — `p/機x/` (7 bytes) comes back as 16, because
    `_df_substr_range` re-encodes the already-re-encoded remainder a SECOND
    time. Every recursive mount walk descends by feeding `common_prefixes`
    back in, so a whole subtree would become invisible to a sweep that erases
    a repo AND to the audit that proves the sweep complete. Pinned by
    `tests/test_delimiter_listing_byte_faithful.mojo`.

    `String(unsafe_from_utf8=Span)` is the same primitive `pb_read_string`
    (`komira_protobuf.reader`) uses for exactly this reason — object keys
    are UTF-8, so the raw byte span IS the String content."""
    var sb = s.as_bytes()
    var n = len(sb)
    var lo = start if start > 0 else 0
    var buf = List[UInt8]()
    for i in range(lo, n):
        buf.append(sb[i])
    return String(unsafe_from_utf8=Span(buf))


@always_inline
def _df_substr_range(s: String, start: Int, end: Int) -> String:
    """The substring of `s` over byte indices `[start, end)`.

    Byte-faithful for the same reason as `_df_substr_from` — see its docstring
    for the defect this shape replaced."""
    var sb = s.as_bytes()
    var n = len(sb)
    var lo = start if start > 0 else 0
    var hi = end if end < n else n
    var buf = List[UInt8]()
    for i in range(lo, hi):
        buf.append(sb[i])
    return String(unsafe_from_utf8=Span(buf))
