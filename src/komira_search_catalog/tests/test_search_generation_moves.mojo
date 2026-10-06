# =============================================================================
# test_search_generation_moves.mojo
#   Every catalog change moves the generation, and a scan that straddles one
#   sees the generation differ.
# =============================================================================
#
# A scan reads the generation, then the catalog, then the generation again,
# and trusts its view of the splits only when the two values agree. So the
# generation has to move on every change to the catalog, not only on a
# publish.
#
#   1. test_publish_moves_generation (control): each publish raises the
#      lineage generation and the index generation.
#   2. test_retire_moves_generation: `retire_at` and `retire` each raise
#      both. Before the fix they only wrote a tombstone, so the value stayed.
#   3. test_reap_moves_generation: a `reap_chunk` that reaps raises both.
#      Before the fix it only raised the floor to a value the head already
#      covered.
#   4. test_scan_straddling_a_retire_detects_it: a scan reads the
#      generation and the live set, a split in its view is retired, and the
#      scan's re-check sees a different generation.
#   5. test_scan_straddling_a_reap_detects_it: the same for a reap.
#   6. test_retire_bumps_before_and_after_its_tombstone and
#      test_reap_bumps_before_and_after_dropping_its_tombstone: the order.
#      `_SpyStore` reads the generation counter at the moment the change is
#      written (the tombstone PUT of a retire, the tombstone DELETE of a
#      reap). It must be above the value before the call (the bump before
#      the change, so a reader that sees the change sees a new generation),
#      and the value after the call must be above it (the bump after the
#      change, which retires the value a reader between the two may have
#      paired with the old view).
#   7. test_refusal_carries_the_marker_when_the_bump_fails: a publish
#      refused past a seal bumps the counter after rewriting its chunk into a
#      seal. That bump is best effort: with an unreadable counter the publish
#      must still raise `[SHARD_RETIRED]` (so the caller moves to a fresh
#      shard id instead of retrying into the retired one) and the seal must
#      still be written. Mutant: let the bump error propagate.
#
# Mutants that turn these red: dropping both bumps from `retire_at` (2, 4,
# 6), from `reap_chunk` (3, 5, 6); dropping only the first or only the
# second bump of either (6); letting the bump error propagate on a refused
# publish (7).
#
# In-memory stores only, no network.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_objectstore import (
    CasManifestStore,
    chunk_key,
    decode_chunk_body,
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    WritePrecondition,
)
from komira_objectstore.cas_manifest import is_not_found
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)

from komira_search_catalog.split_summary import SplitSummary, make_split_summary
from komira_search_catalog.metastore import (
    SearchMetastore,
    generation_across_shards,
    is_shard_retired,
    list_live_splits_across_shards,
    make_shard_id,
    shard_manifest_prefix,
)
from komira_search_catalog.shard_reaper import reap_drained_shards


comptime _META: String = "index/logs/meta"
comptime _GRACE_MS = Int64(1000)
comptime _SPY_KEY: String = "spy/counter_at_change"


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 11 + i * 5) & 0xFF)
    return u^


def _has_uuid(live: List[SplitSummary], u: Array[UInt8, 16]) -> Bool:
    for i in range(len(live)):
        var same = True
        for k in range(16):
            if live[i].split_uuid[k] != u[k]:
                same = False
                break
        if same:
            return True
    return False


def _summary(seed: Int) -> SplitSummary:
    return make_split_summary(
        _uuid(seed),
        Int64(2),
        Int64(seed * 16 + 8),
        Int64(seed * 1000),
        Int64(seed * 1000 + 1),
        String("logs"),
        String("body"),
        String("index/logs/splits/s-" + String(seed) + ".split"),
    )


def _shard_meta[
    S: CloneableConditionalWriteStore
](store: S, shard_id: String) raises -> SearchMetastore[S]:
    var manifest = CasManifestStore[S](
        store.clone(),
        shard_manifest_prefix(_META, shard_id),
        RetryPolicy.fast_test(),
    )
    return SearchMetastore[S](manifest^, String("logs"))


def _index_generation[S: CloneableConditionalWriteStore](store: S) raises -> Int64:
    return generation_across_shards(store, _META, String("logs"))


# -----------------------------------------------------------------------------
# _SpyStore: the shared in-memory store, plus one observation. The first PUT
# (when `on_put`) or DELETE (when not) of a key containing `watch` first
# copies the lineage's generation counter, read straight from the store, to
# `_SPY_KEY` (8 bytes, little endian; 0 when the counter does not exist), then
# performs the write. The copy is a create-if-absent, so only the first
# matching write is observed. The counter is read raw because the write runs
# inside the manifest store's write lock, where a catalog read would wait on
# that lock.
# -----------------------------------------------------------------------------


def _i64_le(b: List[UInt8], off: Int) -> Int64:
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(b[off + k]) << UInt64(8 * k)
    return Int64(v)


def _raw_counter(
    store: SharedInMemoryConditionalStore, lineage: String
) raises -> Int64:
    """The lineage's `_GENERATION_BUMPS` count ([version u8][i64 LE]), 0 when
    the object does not exist."""
    var body: List[UInt8]
    try:
        body = store.get(Path.parse(lineage + "/_GENERATION_BUMPS"))
    except e:
        if is_not_found(String(e)):
            return Int64(0)
        raise e^
    return _i64_le(body, 1)


def _counter_at_change(store: SharedInMemoryConditionalStore) raises -> Int64:
    return _i64_le(store.get(Path.parse(_SPY_KEY)), 0)


struct _SpyStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _watch: String
    var _lineage: String
    var _on_put: Bool

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var watch: String,
        var lineage: String,
        on_put: Bool,
    ):
        self._inner = inner^
        self._watch = watch^
        self._lineage = lineage^
        self._on_put = on_put

    def clone(self) -> Self:
        return Self(
            self._inner.clone(),
            self._watch.copy(),
            self._lineage.copy(),
            self._on_put,
        )

    def _observe(self, path: Path, is_put: Bool) raises:
        if is_put != self._on_put or path.raw().find(self._watch) < 0:
            return
        var c = _raw_counter(self._inner, self._lineage)
        var b = List[UInt8]()
        for k in range(8):
            b.append(UInt8((UInt64(c) >> UInt64(8 * k)) & UInt64(0xFF)))
        try:
            _ = self._inner.conditional_put(
                Path.parse(_SPY_KEY), b, WritePrecondition.if_none_match_star()
            )
        except e:
            if String(e).find("precondition") < 0:
                raise e^

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._observe(path, True)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._observe(path, True)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._observe(path, True)
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._observe(path, False)
        self._inner.delete(path)


# =============================================================================
# 1-3. Every mutation moves the generation.
# =============================================================================


def test_publish_moves_generation() raises:
    var store = SharedInMemoryConditionalStore()
    var w = _shard_meta(store, make_shard_id(String("node"), 0))
    var g = w.generation()
    var gi = _index_generation(store)
    for i in range(3):
        _ = w.publish(_summary(i))
        var g2 = w.generation()
        var gi2 = _index_generation(store)
        assert_true(g2 > g, "a publish did not raise the lineage generation")
        assert_true(gi2 > gi, "a publish did not raise the index generation")
        g = g2
        gi = gi2
    _ = store^


def test_retire_moves_generation() raises:
    var store = SharedInMemoryConditionalStore()
    var w = _shard_meta(store, make_shard_id(String("node"), 1))
    for i in range(3):
        _ = w.publish(_summary(10 + i))
    var g0 = w.generation()
    var gi0 = _index_generation(store)

    w.retire_at(Int64(1), Int64(0))
    var g1 = w.generation()
    var gi1 = _index_generation(store)
    assert_true(
        g1 > g0,
        "retire_at left the lineage generation at " + String(g0)
        + " (now " + String(g1) + ")",
    )
    assert_true(gi1 > gi0, "retire_at did not raise the index generation")

    # A cold handle (every reader but the writer) sees the move too.
    var cold = _shard_meta(store, make_shard_id(String("node"), 1))
    assert_equal(cold.generation(), g1, "a cold reader reads the same value")

    w.retire(Int64(2))
    assert_true(w.generation() > g1, "retire did not raise the generation")
    assert_true(
        _index_generation(store) > gi1,
        "retire did not raise the index generation",
    )
    _ = store^


def test_reap_moves_generation() raises:
    var store = SharedInMemoryConditionalStore()
    var w = _shard_meta(store, make_shard_id(String("node"), 2))
    for i in range(3):
        _ = w.publish(_summary(20 + i))
    w.retire_at(Int64(0), Int64(0))
    w.retire_at(Int64(2), Int64(0))
    var g0 = w.generation()
    var gi0 = _index_generation(store)

    # Still in grace: nothing reaped, nothing to report.
    assert_true(
        not w.reap_chunk(Int64(0), Int64(1), _GRACE_MS), "chunk 0 in grace"
    )

    # The top chunk (its reap moves no head) and the bottom one (its reap
    # also advances the log start and deletes the chunk).
    assert_true(w.reap_chunk(Int64(2), _GRACE_MS, _GRACE_MS), "chunk 2 reaped")
    var g1 = w.generation()
    var gi1 = _index_generation(store)
    assert_true(
        g1 > g0,
        "reaping the top chunk left the lineage generation at " + String(g0)
        + " (now " + String(g1) + ")",
    )
    assert_true(gi1 > gi0, "reaping the top chunk did not raise the index one")
    assert_true(w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS), "chunk 0 reaped")
    assert_true(w.generation() > g1, "reaping chunk 0 did not raise it")
    assert_true(
        _index_generation(store) > gi1,
        "reaping chunk 0 did not raise the index generation",
    )
    _ = store^


# =============================================================================
# 4-5. A scan that straddles a retire or a reap sees the generation differ.
# =============================================================================


def test_scan_straddling_a_retire_detects_it() raises:
    var store = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 3)
    var w = _shard_meta(store, shard_id)
    for i in range(3):
        _ = w.publish(_summary(30 + i))

    # The scan: generation, then the catalog ...
    var before = _index_generation(store)
    var view = list_live_splits_across_shards(store, _META, String("logs"))
    assert_true(_has_uuid(view, _uuid(31)), "split 31 is in the scan's view")

    # ... a compactor retires split 31 ...
    w.retire_at(Int64(1), Int64(0))
    var now = list_live_splits_across_shards(store, _META, String("logs"))
    assert_true(not _has_uuid(now, _uuid(31)), "split 31 left the live set")

    # ... and the scan's re-check must see the catalog moved.
    var after = _index_generation(store)
    assert_true(
        after != before,
        "a scan straddling a retire read generation " + String(before)
        + " twice and kept a view the catalog no longer has",
    )
    _ = store^


def test_scan_straddling_a_reap_detects_it() raises:
    var store = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 4)
    var w = _shard_meta(store, shard_id)
    for i in range(3):
        _ = w.publish(_summary(40 + i))
    w.retire_at(Int64(0), Int64(0))

    var before = _index_generation(store)
    var tombs_before = len(w.tombstoned_seqs())
    _ = list_live_splits_across_shards(store, _META, String("logs"))

    assert_true(w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS), "chunk 0 reaped")
    assert_equal(
        len(w.tombstoned_seqs()), tombs_before - 1, "the reap took a tombstone"
    )

    var after = _index_generation(store)
    assert_true(
        after != before,
        "a scan straddling a reap read generation " + String(before) + " twice",
    )
    _ = store^


# =============================================================================
# 6. The counter moves before the change is written, and again after it.
# =============================================================================


def test_retire_bumps_before_and_after_its_tombstone() raises:
    var inner = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 5)
    var lineage = shard_manifest_prefix(_META, shard_id)
    var w = _shard_meta(inner, shard_id)
    for i in range(2):
        _ = w.publish(_summary(50 + i))
    var c0 = _raw_counter(inner, lineage)

    var spy = _SpyStore(inner.clone(), String("/tombstones/"), lineage.copy(), True)
    var ws = _shard_meta(spy, shard_id)
    ws.retire_at(Int64(0), Int64(0))
    var at_change = _counter_at_change(inner)
    var c1 = _raw_counter(inner, lineage)
    assert_true(
        at_change > c0,
        "the tombstone was written before the generation moved (counter "
        + String(c0) + " before the retire, " + String(at_change)
        + " at the tombstone)",
    )
    assert_true(
        c1 > at_change,
        "the generation did not move again after the tombstone (counter "
        + String(at_change) + " at the tombstone, " + String(c1) + " after)",
    )
    _ = inner^


def test_reap_bumps_before_and_after_dropping_its_tombstone() raises:
    var inner = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 6)
    var lineage = shard_manifest_prefix(_META, shard_id)
    var w = _shard_meta(inner, shard_id)
    for i in range(2):
        _ = w.publish(_summary(60 + i))
    w.retire_at(Int64(1), Int64(0))
    var c0 = _raw_counter(inner, lineage)

    var spy = _SpyStore(
        inner.clone(), String("/tombstones/"), lineage.copy(), False
    )
    var ws = _shard_meta(spy, shard_id)
    assert_true(ws.reap_chunk(Int64(1), _GRACE_MS, _GRACE_MS), "chunk 1 reaped")
    var at_change = _counter_at_change(inner)
    var c1 = _raw_counter(inner, lineage)
    assert_true(
        at_change > c0,
        "the reap dropped the tombstone before the generation moved (counter "
        + String(c0) + " before, " + String(at_change) + " at the drop)",
    )
    assert_true(
        c1 > at_change,
        "the generation did not move again after the reap (counter "
        + String(at_change) + " at the drop, " + String(c1) + " after)",
    )
    _ = inner^


# =============================================================================
# 7. A refused publish always says so, even when its bump fails.
# =============================================================================


def _refusal_error(
    mut w: SearchMetastore[SharedInMemoryConditionalStore], seed: Int
) raises -> String:
    try:
        _ = w.publish(_summary(seed))
    except e:
        return String(e)
    return String("")


def test_refusal_carries_the_marker_when_the_bump_fails() raises:
    var store = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 7)
    var lineage = shard_manifest_prefix(_META, shard_id)
    var w = _shard_meta(store, shard_id)
    for i in range(2):
        _ = w.publish(_summary(70 + i))
    for i in range(2):
        w.retire_at(Int64(i), Int64(0))
    for i in range(2):
        assert_true(
            w.reap_chunk(Int64(i), _GRACE_MS, _GRACE_MS), "chunk reaped"
        )
    var r = reap_drained_shards(store, _META, String("logs"))
    assert_equal(r.shards_reaped, 1, "the drained shard is retired (seal at 2)")

    # An unreadable counter: every bump on this lineage now raises.
    var corrupt = List[UInt8]()
    corrupt.append(UInt8(0xEE))
    _ = store.put(Path.parse(lineage + "/_GENERATION_BUMPS"), corrupt)

    # The writer's warm handle loses slot 2 to the seal, wins slot 3, finds
    # the seal below it and is refused.
    var msg = _refusal_error(w, 72)
    assert_true(
        is_shard_retired(msg),
        "a refused publish whose bump failed raised without the marker: '"
        + msg + "'",
    )
    var body = decode_chunk_body(store.get(chunk_key(lineage, Int64(3))))
    assert_equal(len(body), 0, "the refused publish's chunk is a seal")

    # A fresh handle is refused the same way.
    var cold = _shard_meta(store, shard_id)
    var cold_msg = _refusal_error(cold, 73)
    assert_true(
        is_shard_retired(cold_msg),
        "a cold refused publish whose bump failed raised without the"
        " marker: '" + cold_msg + "'",
    )
    assert_equal(
        len(list_live_splits_across_shards(store, _META, String("logs"))),
        0,
        "nothing the refused publishes wrote is visible",
    )
    _ = store^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
