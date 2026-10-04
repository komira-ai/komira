# =============================================================================
# komira_search_catalog/generation.mojo
#   The durable records that keep an index's generation from going down when
#   the catalog deletes chunks and drained shards.
# =============================================================================
#
# A query planner folds the catalog generation into its plan-cache key, and
# komira_search_scan pins a snapshot by it, so it must never go down: a value
# that comes back can be answered from a plan cached for a different split
# set.
#
# The generation of one lineage counts the chunks it has ever committed: its
# highest chunk_seq + 1. A fresh reader finds that by LISTing the manifest,
# so it only sees chunks that still exist, and reaping deletes chunks. Two
# durable records keep what a deletion would otherwise erase:
#
#   * `<lineage>/_GENERATION_FLOOR`. Before `SearchMetastore.reap_chunk`
#     reaps chunk `s` (which lets a later prefix advance delete it), it
#     raises the floor to at least `s + 1`. The lineage's generation is
#     max(listed head + 1, floor).
#   * `<index>/meta/_RETIRED_SHARDS`. Before `reap_drained_shards` deletes a
#     writer shard's objects, it records that shard's final generation here.
#     Readers of the live split set skip a shard recorded here. The index
#     generation counts each shard id once, as max(live, recorded), plus the
#     recorded value of every shard that is gone.
#
# Why that is monotone: every deletion is preceded by a durable write of at
# least the value the deleted object contributed, and both records only grow.
# A reader reads the live objects first and the records second. If a later
# reader no longer sees an object an earlier reader counted, the deletion
# happened before the later reader's LIST, the record before the deletion,
# and the later reader's record read after both, so it sees the record.
#
# Both records are written by compare-and-swap on the object's etag: read
# the etag (HEAD) first and the body (GET) second, so a write keyed on that
# etag can only fail when the object moved on, never overwrite a newer body
# with one computed from an older one.
#
# Cost: one GET per lineage on each generation read, and one GET of the
# retired-shards record per index. That record gains one entry (the shard id
# and an i64) per reaped writer shard and is never shrunk. Folding entries
# into one number would break the max(live, recorded) rule for a reader that
# is still counting the same shard live.
# =============================================================================

from komira_objectstore import (
    ConditionalWriteStore,
    LogStart,
    WritePrecondition,
    decode_log_start,
    encode_log_start,
    log_start_key,
)
from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path

from komira_search_catalog.split_summary import (
    _get_i64_le,
    _get_lp_bytes,
    _put_i64_le,
    _put_lp_bytes,
)


comptime GENERATION_FLOOR_VERSION = UInt8(1)
"""Leading byte of a `_GENERATION_FLOOR` body: [version u8][floor i64 LE]."""

comptime RETIRED_SHARDS_VERSION = UInt8(1)
"""Leading byte of a `_RETIRED_SHARDS` body: [version u8][count i64 LE], then
per entry [shard id: length-prefixed bytes][generation i64 LE]."""

comptime _CAS_ATTEMPTS = 64
"""Compare-and-swap attempts before a record write gives up and raises. A
lost attempt means another reaper moved the record; each retry re-reads it."""


def generation_floor_key(lineage_prefix: String) raises -> Path:
    return Path.parse(lineage_prefix + "/_GENERATION_FLOOR")


def retired_shards_key(index_meta_prefix: String) raises -> Path:
    return Path.parse(index_meta_prefix + "/_RETIRED_SHARDS")


# -----------------------------------------------------------------------------
# Codecs
# -----------------------------------------------------------------------------


def encode_generation_floor(generation: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(GENERATION_FLOOR_VERSION)
    _put_i64_le(out, generation)
    return out^


def decode_generation_floor(bytes: List[UInt8]) raises -> Int64:
    if len(bytes) < 1 or bytes[0] != GENERATION_FLOOR_VERSION:
        raise Error(
            "komira_search_catalog: unknown _GENERATION_FLOOR version (corrupt)"
        )
    return _get_i64_le(bytes, 1)


def _same_bytes(a: List[UInt8], s: String) -> Bool:
    var b = s.as_bytes()
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


struct RetiredShards(Copyable, Movable, Sized, Deinitable):
    """The final generation of every writer shard that has been reaped, keyed
    by shard id (kept as its raw bytes so the comparison with a live shard id
    is exact)."""

    var shard_ids: List[List[UInt8]]
    var generations: List[Int64]

    def __init__(out self):
        self.shard_ids = List[List[UInt8]]()
        self.generations = List[Int64]()

    def __len__(self) -> Int:
        return len(self.generations)

    def find(self, shard_id: String) -> Int:
        """The entry index of `shard_id`, or -1."""
        for i in range(len(self.shard_ids)):
            if _same_bytes(self.shard_ids[i], shard_id):
                return i
        return -1

    def generation_of(self, shard_id: String) -> Int64:
        """The recorded generation of `shard_id`, or 0 if it was never
        reaped."""
        var i = self.find(shard_id)
        if i < 0:
            return Int64(0)
        return self.generations[i]

    def raise_to(mut self, shard_id: String, generation: Int64) -> Bool:
        """Record at least `generation` for `shard_id`. Returns False when the
        record already held that much (nothing to write)."""
        var i = self.find(shard_id)
        if i < 0:
            var b = List[UInt8]()
            var sb = shard_id.as_bytes()
            for k in range(len(sb)):
                b.append(sb[k])
            self.shard_ids.append(b^)
            self.generations.append(generation)
            return True
        if self.generations[i] >= generation:
            return False
        self.generations[i] = generation
        return True


def encode_retired_shards(r: RetiredShards) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(RETIRED_SHARDS_VERSION)
    _put_i64_le(out, Int64(len(r.generations)))
    for i in range(len(r.generations)):
        _put_lp_bytes(out, r.shard_ids[i])
        _put_i64_le(out, r.generations[i])
    return out^


def decode_retired_shards(bytes: List[UInt8]) raises -> RetiredShards:
    if len(bytes) < 1 or bytes[0] != RETIRED_SHARDS_VERSION:
        raise Error(
            "komira_search_catalog: unknown _RETIRED_SHARDS version (corrupt)"
        )
    var off = 1
    var n = Int(_get_i64_le(bytes, off))
    off += 8
    if n < 0:
        raise Error(
            "komira_search_catalog: negative _RETIRED_SHARDS count (corrupt)"
        )
    var out = RetiredShards()
    for _ in range(n):
        var id = _get_lp_bytes(bytes, off)
        var g = _get_i64_le(bytes, off)
        off += 8
        out.shard_ids.append(id^)
        out.generations.append(g)
    return out^


# -----------------------------------------------------------------------------
# Reads and compare-and-swap writes
# -----------------------------------------------------------------------------


struct _Versioned(Movable, Deinitable):
    var present: Bool
    var body: List[UInt8]
    var etag: String

    def __init__(out self, present: Bool, var body: List[UInt8], var etag: String):
        self.present = present
        self.body = body^
        self.etag = etag^


def _read_versioned[
    S: ConditionalWriteStore
](store: S, key: Path) raises -> _Versioned:
    """HEAD then GET. An object deleted in between reads as absent; the
    create-if-absent that follows then fails if it was recreated."""
    var etag: String
    try:
        etag = store.head(key).etag
    except e:
        if is_not_found(String(e)):
            return _Versioned(False, List[UInt8](), String(""))
        raise e^
    try:
        var body = store.get(key)
        return _Versioned(True, body^, etag^)
    except e:
        if is_not_found(String(e)):
            return _Versioned(False, List[UInt8](), String(""))
        raise e^


def _precondition_for(v: _Versioned) -> WritePrecondition:
    if v.present:
        return WritePrecondition.if_match(v.etag)
    return WritePrecondition.if_none_match_star()


def read_generation_floor[
    S: ConditionalWriteStore
](store: S, lineage_prefix: String) raises -> Int64:
    """The lineage's generation floor, 0 when none was ever written."""
    try:
        return decode_generation_floor(
            store.get(generation_floor_key(lineage_prefix))
        )
    except e:
        if is_not_found(String(e)):
            return Int64(0)
        raise e^


def raise_generation_floor[
    S: ConditionalWriteStore
](store: S, lineage_prefix: String, at_least: Int64) raises -> None:
    """Make the lineage's generation floor at least `at_least`."""
    var key = generation_floor_key(lineage_prefix)
    for _ in range(_CAS_ATTEMPTS):
        var cur = _read_versioned(store, key)
        if cur.present and decode_generation_floor(cur.body) >= at_least:
            return
        try:
            _ = store.conditional_put(
                key, encode_generation_floor(at_least), _precondition_for(cur)
            )
            return
        except e:
            if not is_precondition(String(e)):
                raise e^
    raise Error(
        "komira_search_catalog: lost the compare-and-swap on "
        + key.raw()
        + " "
        + String(_CAS_ATTEMPTS)
        + " times"
    )


def read_retired_shards[
    S: ConditionalWriteStore
](store: S, index_meta_prefix: String) raises -> RetiredShards:
    """Every reaped writer shard's final generation; empty when none."""
    try:
        return decode_retired_shards(
            store.get(retired_shards_key(index_meta_prefix))
        )
    except e:
        if is_not_found(String(e)):
            return RetiredShards()
        raise e^


def record_retired_shard[
    S: ConditionalWriteStore
](
    store: S, index_meta_prefix: String, shard_id: String, generation: Int64
) raises -> None:
    """Record at least `generation` for `shard_id`. Called before any of the
    shard's objects are deleted."""
    var key = retired_shards_key(index_meta_prefix)
    for _ in range(_CAS_ATTEMPTS):
        var cur = _read_versioned(store, key)
        var r = RetiredShards()
        if cur.present:
            r = decode_retired_shards(cur.body)
        if not r.raise_to(shard_id, generation):
            return
        try:
            _ = store.conditional_put(
                key, encode_retired_shards(r), _precondition_for(cur)
            )
            return
        except e:
            if not is_precondition(String(e)):
                raise e^
    raise Error(
        "komira_search_catalog: lost the compare-and-swap on "
        + key.raw()
        + " "
        + String(_CAS_ATTEMPTS)
        + " times"
    )


# -----------------------------------------------------------------------------
# The lineage's log start
# -----------------------------------------------------------------------------
#
# `<lineage>/_LOG_START` is komira_objectstore's retention pointer: chunks
# below its sequence number may be gone, and a reader that recovers the head
# by LIST starts there. A chunk at or above it must exist, so the catalog
# advances it before deleting anything at or above the old value. It is
# written here, not through `CasManifestStore.advance_log_start`, because
# that verb's caller reads the pointer GET-then-HEAD, and a compare-and-swap
# keyed on an etag read after the body can move the pointer backwards over
# chunks another reaper has already deleted.


def read_log_start_seq[
    S: ConditionalWriteStore
](store: S, lineage_prefix: String) raises -> Int64:
    """The lineage's log start sequence number; 0 when it has none."""
    var cur = _read_versioned(store, log_start_key(lineage_prefix))
    if not cur.present:
        return Int64(0)
    return decode_log_start(cur.body, cur.etag).log_start_seq


def advance_log_start_to[
    S: ConditionalWriteStore
](
    store: S, lineage_prefix: String, seq: Int64, offset: Int64
) raises -> None:
    """Make the lineage's log start at least `seq` (with `offset` as the
    absolute offset of chunk `seq`). Never moves it backwards."""
    var key = log_start_key(lineage_prefix)
    for _ in range(_CAS_ATTEMPTS):
        var cur = _read_versioned(store, key)
        if cur.present and decode_log_start(cur.body, cur.etag).log_start_seq >= seq:
            return
        try:
            _ = store.conditional_put(
                key,
                encode_log_start(LogStart(offset, seq, String(""))),
                _precondition_for(cur),
            )
            return
        except e:
            if not is_precondition(String(e)):
                raise e^
    raise Error(
        "komira_search_catalog: lost the compare-and-swap on "
        + key.raw()
        + " "
        + String(_CAS_ATTEMPTS)
        + " times"
    )
