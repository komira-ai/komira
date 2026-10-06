# =============================================================================
# test_search_catalog_lifecycle.mojo
#   The retire / reap end of a split's life: what a reader may rely on while
#   the catalog deletes things.
# =============================================================================
#
#   1. test_store_error_naming_404_is_not_absence: a store error whose message
#      contains "404" only because the object key does (here the index name)
#      is a real failure. Replay must raise it, not skip the chunk as if it had
#      been reaped. A genuine not-found is still skipped.
#   2. test_generation_survives_reaping_the_top_chunk: retiring and reaping the
#      newest chunk of a lineage must not lower the generation a fresh reader
#      computes.
#   3. test_generation_survives_draining_and_reaping_a_shard: through the whole
#      drain of a writer shard (publish, merge into `_base`, retire, reap each
#      chunk, reap the drained shard) the index generation never goes down, and
#      a publish afterwards still moves it.
#   4. test_reap_is_fenced_against_a_publish_after_the_drained_check: a publish
#      that lands in a writer shard after the reaper has decided the shard is
#      drained must survive the reap.
#   5. test_reap_fences_the_writer_slot_without_a_floor: the same late
#      publish on a shard whose generation floor is gone is still fenced,
#      because reaping chunks never makes the lineage look shorter.
#   6. test_publish_into_a_retired_shard_is_refused and
#      test_publish_that_loses_its_slot_to_a_seal_is_refused: once the reaper
#      has sealed a shard, a publish into it (warm writer, cold handle, or one
#      that loses its slot to the seal mid-reap) raises `[SHARD_RETIRED]`
#      instead of landing past the seal, nothing it wrote is visible, and the
#      caller's re-publish into a fresh shard is the only copy.
#      test_a_sweep_never_deletes_an_earlier_seal: a seal left by a reaper
#      that crashed before recording the shard, or written by a concurrent
#      reaper, survives the next sweep, so the writer's warm publish is
#      refused instead of succeeding below the log start of a retired shard.
#      test_a_stale_seal_below_the_log_start_does_not_retire_the_shard: a
#      reaper that stalls after its drained check, while the writer publishes
#      into the fenced slot and that chunk is retired, reaped and deleted
#      below an advanced log start, wins the now-empty slot. It must not
#      retire the shard, and the writer's next publish stays visible.
#   7. test_reaping_a_chunk_below_the_top_keeps_cold_reads_whole and
#      test_cold_read_racing_a_prefix_reap_is_not_torn: reaping chunks in any
#      order, and a cold read racing the reap of a prefix, never make a cold
#      reader report a torn lineage, and the live set and generation stay
#      right.
#
# Every visibility claim is checked through the catalog's read path
# (`list_live_splits_across_shards` or `SearchMetastore.list_live_splits`),
# not by looking at objects in the store.
#
# Everything runs against the in-memory stores, with no network. `_HookStore`
# wraps the shared in-memory store to stage what a single thread cannot
# otherwise reach: a store error on one key, a publish that lands at an exact
# point inside the reaper, and a reap that lands inside a cold reader's head
# recovery.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_objectstore import (
    CasManifestStore,
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    LogStart,
    ManifestHead,
    WritePrecondition,
    chunk_key,
    encode_chunk,
    encode_head,
    head_key,
    encode_log_start,
    decode_chunk_body,
    tombstone_key,
)
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)

from komira_search_catalog.split_summary import (
    SplitSummary,
    decode_split_summary,
    encode_split_summary,
    make_merged_split_summary,
    make_split_summary,
)
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


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 7 + i * 13) & 0xFF)
    return u^


def _uuid_eq(a: Array[UInt8, 16], b: Array[UInt8, 16]) -> Bool:
    for i in range(16):
        if a[i] != b[i]:
            return False
    return True


def _has_uuid(live: List[SplitSummary], u: Array[UInt8, 16]) -> Bool:
    for i in range(len(live)):
        if _uuid_eq(live[i].split_uuid, u):
            return True
    return False


def _summary(seed: Int, doc_count: Int64) -> SplitSummary:
    return make_split_summary(
        _uuid(seed),
        doc_count,
        Int64(seed * 16 + 8),
        Int64(seed * 1000),
        Int64(seed * 1000 + Int(doc_count) - 1),
        String("logs"),
        String("body"),
        String("index/logs/splits/s-" + String(seed) + ".split"),
    )


def _lineage_meta[
    S: CloneableConditionalWriteStore
](store: S, lineage_prefix: String) raises -> SearchMetastore[S]:
    var manifest = CasManifestStore[S](
        store.clone(), lineage_prefix.copy(), RetryPolicy.fast_test()
    )
    return SearchMetastore[S](manifest^, String("logs"))


def _shard_meta[
    S: CloneableConditionalWriteStore
](store: S, shard_id: String) raises -> SearchMetastore[S]:
    return _lineage_meta(store, shard_manifest_prefix(_META, shard_id))


def _count_under(store: SharedInMemoryConditionalStore, prefix: String) raises -> Int:
    return len(store.list_with_delimiter(Path.parse(prefix + "/")).objects)


# -----------------------------------------------------------------------------
# _HookStore: the shared in-memory store plus two staged interleavings.
#
#   * LIST of exactly `list_trigger` first creates `inject_path` with
#     `inject_bytes` (If-None-Match, so it fires at most once), deletes every
#     key in `trigger_deletes` (deleting an absent key succeeds), then lists.
#     It then writes every `trigger_puts[i]` with `trigger_bodies[i]`
#     unconditionally. An empty `inject_path` skips the inject. The reaper's
#     drained check LISTs `<shard>/tombstones/` as its last step, so a
#     trigger there lands writes after the check has looked at the manifest.
#   * GET / ranged GET of exactly `fail_get_path` raises `fail_msg`.
#
# Every field is plain owned data; `clone()` copies them and shares the inner
# map, so the manifest handles the catalog builds over clones see the hooks.
# -----------------------------------------------------------------------------


struct _HookStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _list_trigger: String
    var _inject_path: String
    var _inject_bytes: List[UInt8]
    var _fail_get_path: String
    var _fail_msg: String
    var _trigger_deletes: List[String]
    var _trigger_puts: List[String]
    var _trigger_bodies: List[List[UInt8]]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var list_trigger: String,
        var inject_path: String,
        var inject_bytes: List[UInt8],
        var fail_get_path: String,
        var fail_msg: String,
        var trigger_deletes: List[String] = List[String](),
        var trigger_puts: List[String] = List[String](),
        var trigger_bodies: List[List[UInt8]] = List[List[UInt8]](),
    ):
        self._inner = inner^
        self._list_trigger = list_trigger^
        self._inject_path = inject_path^
        self._inject_bytes = inject_bytes^
        self._fail_get_path = fail_get_path^
        self._fail_msg = fail_msg^
        self._trigger_deletes = trigger_deletes^
        self._trigger_puts = trigger_puts^
        self._trigger_bodies = trigger_bodies^

    def clone(self) -> Self:
        return Self(
            self._inner.clone(),
            self._list_trigger.copy(),
            self._inject_path.copy(),
            self._inject_bytes.copy(),
            self._fail_get_path.copy(),
            self._fail_msg.copy(),
            self._trigger_deletes.copy(),
            self._trigger_puts.copy(),
            self._trigger_bodies.copy(),
        )

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        if (
            self._list_trigger.byte_length() > 0
            and prefix.raw() == self._list_trigger
        ):
            if self._inject_path.byte_length() > 0:
                try:
                    _ = self._inner.conditional_put(
                        Path.parse(self._inject_path),
                        self._inject_bytes,
                        WritePrecondition.if_none_match_star(),
                    )
                except e:
                    if String(e).find("precondition") < 0:
                        raise e^
            for i in range(len(self._trigger_deletes)):
                self._inner.delete(Path.parse(self._trigger_deletes[i]))
            for i in range(len(self._trigger_puts)):
                _ = self._inner.put(
                    Path.parse(self._trigger_puts[i]), self._trigger_bodies[i]
                )
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

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
        if path.raw() == self._fail_get_path:
            raise Error(self._fail_msg)
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if path.raw() == self._fail_get_path:
            raise Error(self._fail_msg)
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _plain_hooks(inner: SharedInMemoryConditionalStore) -> _HookStore:
    return _HookStore(
        inner.clone(),
        String(""),
        String(""),
        List[UInt8](),
        String(""),
        String(""),
    )


# =============================================================================
# 1. A store error that names "404" is not absence.
# =============================================================================


def test_store_error_naming_404_is_not_absence() raises:
    # The index is called "run404", so every key of this lineage contains
    # "404". A permission failure on chunk 1 carries that key in its message,
    # exactly as the cloud conformers format it.
    var lineage = String("index/run404/meta")
    var inner = SharedInMemoryConditionalStore()
    var failing_key = chunk_key(lineage, Int64(1)).raw()
    var hooks = _HookStore(
        inner.clone(),
        String(""),
        String(""),
        List[UInt8](),
        failing_key.copy(),
        String("StoreError[PERMISSION_DENIED] GET mem://bucket/")
        + failing_key
        + " status=403 AccessDenied",
    )
    var meta = _lineage_meta(hooks, lineage)
    for i in range(3):
        _ = meta.publish(_summary(i, Int64(2)))

    # The writer's warm handle knows the head, so replay reads chunk 1 and
    # meets the error. Skipping it would return two splits and hide the third
    # from every query; the error must reach the caller instead.
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = meta.list_live_splits()

    # A genuine not-found (the chunk was reaped after the head was read) is
    # still skipped.
    var ok = _lineage_meta(_plain_hooks(inner), lineage)
    for i in range(3):
        _ = ok.publish(_summary(10 + i, Int64(2)))
    inner.delete(chunk_key(lineage, Int64(4)))
    var live = ok.list_live_splits()
    assert_equal(len(live), 5, "a reaped chunk is skipped, the rest listed")

    _ = inner^


# =============================================================================
# 2. Reaping the newest chunk does not lower the generation.
# =============================================================================


def test_generation_survives_reaping_the_top_chunk() raises:
    var store = SharedInMemoryConditionalStore()
    var w = _shard_meta(store, make_shard_id(String("node"), 0))
    for i in range(3):
        _ = w.publish(_summary(i, Int64(2)))
    var g0 = generation_across_shards(store, _META, String("logs"))

    # Retire and reap the newest chunk (seq 2). A fresh reader recovers the
    # head by LIST, and chunk 2 is no longer listed.
    w.retire_at(Int64(2), Int64(0))
    assert_true(
        w.reap_chunk(Int64(2), _GRACE_MS, _GRACE_MS), "chunk 2 reaped"
    )
    var g1 = generation_across_shards(store, _META, String("logs"))
    assert_true(
        g1 >= g0,
        "reaping the top chunk lowered the generation from "
        + String(g0)
        + " to "
        + String(g1),
    )

    # A publish into the same shard still moves it, and a cold reader sees
    # every split that is still live, with nothing torn.
    _ = w.publish(_summary(3, Int64(2)))
    var g2 = generation_across_shards(store, _META, String("logs"))
    assert_true(g2 > g1, "a publish after the reap moves the generation")
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), 3, "splits 0, 1 and 3 are live")
    assert_true(_has_uuid(live, _uuid(3)), "the new publish is visible")
    assert_false(_has_uuid(live, _uuid(2)), "the reaped split is not")

    _ = store^


# =============================================================================
# 3. Draining and reaping a writer shard never lowers the generation.
# =============================================================================


def test_generation_survives_draining_and_reaping_a_shard() raises:
    var store = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 1)
    var w = _shard_meta(store, shard_id)
    _ = w.publish(_summary(1, Int64(3)))
    _ = w.publish(_summary(2, Int64(4)))

    # The compactor merges both into `_base`.
    var inputs = List[UInt8]()
    var u1 = _uuid(1)
    var u2 = _uuid(2)
    for k in range(16):
        inputs.append(u1[k])
    for k in range(16):
        inputs.append(u2[k])
    var base = _shard_meta(store, String("_base"))
    _ = base.publish(
        make_merged_split_summary(
            _uuid(7),
            Int64(7),
            Int64(999),
            Int64(0),
            Int64(6),
            String("logs"),
            String("body"),
            String("index/logs/splits/merged-7.split"),
            Int64(1),
            inputs^,
        )
    )
    var g0 = generation_across_shards(store, _META, String("logs"))

    w.retire_at(Int64(0), Int64(0))
    w.retire_at(Int64(1), Int64(0))
    var g1 = generation_across_shards(store, _META, String("logs"))
    assert_true(g1 >= g0, "retire lowered the generation")

    assert_true(w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS), "chunk 0 reaped")
    assert_true(w.reap_chunk(Int64(1), _GRACE_MS, _GRACE_MS), "chunk 1 reaped")
    var g2 = generation_across_shards(store, _META, String("logs"))
    assert_true(
        g2 >= g1,
        "reaping the shard's chunks lowered the generation from "
        + String(g1)
        + " to "
        + String(g2),
    )

    var r = reap_drained_shards(store, _META, String("logs"))
    assert_equal(r.shards_reaped, 1, "the drained writer shard is reaped")
    assert_equal(
        _count_under(store, shard_manifest_prefix(_META, shard_id)),
        3,
        "only the terminal seal, the log start that points at it and the"
        " generation counter remain",
    )
    var g3 = generation_across_shards(store, _META, String("logs"))
    assert_true(
        g3 >= g2,
        "reaping the drained shard lowered the generation from "
        + String(g2)
        + " to "
        + String(g3),
    )

    # The merged split is still the whole live set, and a new publish moves
    # the generation past every value seen so far.
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), 1, "only the merged split is live")
    assert_true(_uuid_eq(live[0].split_uuid, _uuid(7)), "it is the merged one")
    _ = base.publish(_summary(8, Int64(1)))
    var g4 = generation_across_shards(store, _META, String("logs"))
    assert_true(g4 > g3, "a publish after the reap moves the generation")

    _ = store^


# =============================================================================
# 4. A publish after the drained check survives the reap.
# =============================================================================


def test_reap_is_fenced_against_a_publish_after_the_drained_check() raises:
    var inner = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 2)
    var lineage = shard_manifest_prefix(_META, shard_id)

    # Drain the writer's shard: two publishes, both retired and reaped.
    var w = _shard_meta(inner, shard_id)
    _ = w.publish(_summary(1, Int64(2)))
    _ = w.publish(_summary(2, Int64(2)))
    w.retire_at(Int64(0), Int64(0))
    w.retire_at(Int64(1), Int64(0))
    assert_true(w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS), "chunk 0 reaped")
    assert_true(w.reap_chunk(Int64(1), _GRACE_MS, _GRACE_MS), "chunk 1 reaped")

    # The writer is still alive and its next publish goes to slot 2: the
    # create-if-absent of chunk 2 is the moment that publish lands (the head
    # pointer advance is deferred). Stage it right after the reaper's drained
    # check has read the manifest.
    var late = _summary(77, Int64(5))
    var late_key = chunk_key(lineage, Int64(2)).raw()
    var hooks = _HookStore(
        inner.clone(),
        lineage + "/tombstones/",
        late_key.copy(),
        encode_chunk(encode_split_summary(late), Int64(5)),
        String(""),
        String(""),
    )
    var r = reap_drained_shards(hooks, _META, String("logs"))
    assert_equal(r.shards_reaped, 0, "a shard that took a publish is not reaped")
    assert_equal(r.shards_fenced, 1, "the seal lost the slot to the publish")

    # The late split is visible to a cold reader of the whole index.
    var live = list_live_splits_across_shards(inner, _META, String("logs"))
    assert_equal(len(live), 1, "only the late split is live")
    assert_true(_has_uuid(live, _uuid(77)), "the late publish is visible")

    # The writer's warm handle lost slot 2 to that publish; its next publish
    # finds the true tail and is visible too.
    _ = w.publish(_summary(78, Int64(1)))
    live = list_live_splits_across_shards(inner, _META, String("logs"))
    assert_equal(len(live), 2, "both late splits are live")
    assert_true(_has_uuid(live, _uuid(78)), "the writer's next publish is visible")

    # Once both are retired and reaped too, the shard is drained for real and
    # the next sweep retires it.
    var w2 = _shard_meta(inner, shard_id)
    w2.retire_at(Int64(2), Int64(0))
    w2.retire_at(Int64(3), Int64(0))
    assert_true(w2.reap_chunk(Int64(2), _GRACE_MS, _GRACE_MS), "chunk 2 reaped")
    assert_true(w2.reap_chunk(Int64(3), _GRACE_MS, _GRACE_MS), "chunk 3 reaped")
    var r2 = reap_drained_shards(_plain_hooks(inner), _META, String("logs"))
    assert_equal(r2.shards_reaped, 1, "the drained shard is reaped")
    assert_equal(
        _count_under(inner, lineage),
        3,
        "only the terminal seal, the log start that points at it and the"
        " generation counter remain",
    )
    assert_equal(
        len(list_live_splits_across_shards(inner, _META, String("logs"))),
        0,
        "nothing is live",
    )

    _ = inner^


def test_reap_fences_the_writer_slot_without_a_floor() raises:
    var inner = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 3)
    var lineage = shard_manifest_prefix(_META, shard_id)
    var w = _shard_meta(inner, shard_id)
    _ = w.publish(_summary(1, Int64(2)))
    _ = w.publish(_summary(2, Int64(2)))
    w.retire_at(Int64(0), Int64(0))
    w.retire_at(Int64(1), Int64(0))
    assert_true(w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS), "chunk 0 reaped")
    assert_true(w.reap_chunk(Int64(1), _GRACE_MS, _GRACE_MS), "chunk 1 reaped")
    # Without the generation floor the reaper still has to find the writer's
    # next slot, 2: reaping a chunk never leaves the lineage looking shorter
    # than it was.
    inner.delete(Path.parse(lineage + "/_GENERATION_FLOOR"))

    var late_key = chunk_key(lineage, Int64(2)).raw()
    var hooks = _HookStore(
        inner.clone(),
        lineage + "/tombstones/",
        late_key.copy(),
        encode_chunk(encode_split_summary(_summary(88, Int64(5))), Int64(5)),
        String(""),
        String(""),
    )
    var r = reap_drained_shards(hooks, _META, String("logs"))
    assert_equal(r.shards_reaped, 0, "the publish at slot 2 fences the reap")
    var live = list_live_splits_across_shards(inner, _META, String("logs"))
    assert_equal(len(live), 1, "only the late split is live")
    assert_true(_has_uuid(live, _uuid(88)), "the late publish is visible")

    _ = inner^


# =============================================================================
# 6. A publish into a retired shard is refused.
# =============================================================================


def _drain(mut w: SearchMetastore[SharedInMemoryConditionalStore], n: Int) raises:
    for i in range(n):
        w.retire_at(Int64(i), Int64(0))
    for i in range(n):
        assert_true(
            w.reap_chunk(Int64(i), _GRACE_MS, _GRACE_MS),
            "chunk " + String(i) + " reaped",
        )


def test_publish_into_a_retired_shard_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 4)
    var w = _shard_meta(store, shard_id)
    _ = w.publish(_summary(1, Int64(2)))
    _ = w.publish(_summary(2, Int64(2)))
    _drain(w, 2)
    var r = reap_drained_shards(store, _META, String("logs"))
    assert_equal(r.shards_reaped, 1, "the drained shard is retired")
    var g0 = generation_across_shards(store, _META, String("logs"))

    # The writer is still alive. Its warm handle's next slot is the seal.
    var refused = False
    try:
        _ = w.publish(_summary(3, Int64(2)))
    except e:
        refused = is_shard_retired(String(e))
    assert_true(refused, "the publish is refused as a retired shard")
    # The refusal is terminal for the handle ...
    with assert_raises(contains="[SHARD_RETIRED]"):
        _ = w.publish(_summary(3, Int64(2)))
    # ... and for a fresh handle on the same shard, which finds the seal on
    # top of the lineage.
    var cold = _shard_meta(store, shard_id)
    with assert_raises(contains="[SHARD_RETIRED]"):
        _ = cold.publish(_summary(3, Int64(2)))

    # Nothing became visible, nothing is torn, and the caller's re-publish
    # into a fresh shard is visible to the index read.
    assert_equal(
        len(list_live_splits_across_shards(store, _META, String("logs"))),
        0,
        "the refused publishes are not visible",
    )
    var fresh = _shard_meta(store, make_shard_id(String("node"), 5))
    _ = fresh.publish(_summary(3, Int64(2)))
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), 1, "exactly one copy of the re-published split")
    assert_true(_has_uuid(live, _uuid(3)), "the re-publish is visible")
    var g1 = generation_across_shards(store, _META, String("logs"))
    assert_true(g1 > g0, "the re-publish moves the generation")

    # A later sweep leaves the retired shard alone.
    var r2 = reap_drained_shards(store, _META, String("logs"))
    assert_equal(r2.shards_reaped, 0, "a retired shard is not reaped twice")
    assert_equal(
        generation_across_shards(store, _META, String("logs")),
        g1,
        "a second sweep does not move the generation",
    )

    _ = store^


def test_publish_that_loses_its_slot_to_a_seal_is_refused() raises:
    # The reaper has sealed the writer's next slot and not yet deleted
    # anything (it crashed there, or is still running). The writer's publish
    # loses slot 2 to the seal; it must not land at slot 3 and report success.
    var store = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 6)
    var lineage = shard_manifest_prefix(_META, shard_id)
    var w = _shard_meta(store, shard_id)
    _ = w.publish(_summary(1, Int64(2)))
    _ = w.publish(_summary(2, Int64(2)))
    _drain(w, 2)
    _ = store.conditional_put(
        chunk_key(lineage, Int64(2)),
        encode_chunk(List[UInt8](), Int64(0)),
        WritePrecondition.if_none_match_star(),
    )

    with assert_raises(contains="[SHARD_RETIRED]"):
        _ = w.publish(_summary(3, Int64(2)))
    assert_equal(
        len(list_live_splits_across_shards(store, _META, String("logs"))),
        0,
        "the refused publish is not visible",
    )

    # The next sweep finishes the shard; the index read stays whole, and the
    # re-publish into a fresh shard is the only copy.
    var r = reap_drained_shards(store, _META, String("logs"))
    assert_equal(r.shards_reaped, 1, "the next sweep retires the shard")
    var fresh = _shard_meta(store, make_shard_id(String("node"), 7))
    _ = fresh.publish(_summary(3, Int64(2)))
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), 1, "exactly one copy of the re-published split")
    assert_true(_has_uuid(live, _uuid(3)), "the re-publish is visible")

    _ = store^


def test_a_sweep_never_deletes_an_earlier_seal() raises:
    # The shard already has a seal at slot 2 that no `_RETIRED_SHARDS` record
    # covers: an earlier reaper wrote it and crashed before recording the
    # shard, or a concurrent reaper wrote it after this sweep read the record.
    # This sweep then sees generation 3 and seals slot 3. Deleting the seal at
    # slot 2 would free the slot the writer's warm handle (last chunk 1)
    # publishes into next, and that publish would report success for a split
    # below the log start of a shard readers skip.
    var store = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 10)
    var lineage = shard_manifest_prefix(_META, shard_id)
    var w = _shard_meta(store, shard_id)
    _ = w.publish(_summary(1, Int64(2)))
    _ = w.publish(_summary(2, Int64(2)))
    _drain(w, 2)
    _ = store.conditional_put(
        chunk_key(lineage, Int64(2)),
        encode_chunk(List[UInt8](), Int64(0)),
        WritePrecondition.if_none_match_star(),
    )
    var r = reap_drained_shards(store, _META, String("logs"))
    assert_equal(r.shards_reaped, 1, "the sweep retires the shard")

    # The warm writer's publish is either refused or visible; never lost.
    var refused = False
    try:
        _ = w.publish(_summary(3, Int64(2)))
    except e:
        assert_true(
            is_shard_retired(String(e)),
            "the publish failed for a reason other than retirement: "
            + String(e),
        )
        refused = True
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_true(refused, "the publish into the retired shard was not refused")
    assert_equal(len(live), 0, "the refused publish is not visible")

    # A cold handle on the same shard is refused too.
    var cold = _shard_meta(store, shard_id)
    with assert_raises(contains="[SHARD_RETIRED]"):
        _ = cold.publish(_summary(3, Int64(2)))

    # The caller's re-publish into a fresh shard is the only copy.
    var fresh = _shard_meta(store, make_shard_id(String("node"), 11))
    _ = fresh.publish(_summary(3, Int64(2)))
    live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), 1, "exactly one copy of the re-published split")
    assert_true(_has_uuid(live, _uuid(3)), "the re-publish is visible")

    _ = store^


def _lineage_objects(
    store: SharedInMemoryConditionalStore, lineage: String
) raises -> Dict[String, List[UInt8]]:
    """Every object under `<lineage>/` (the in-memory store lists flat)."""
    var out = Dict[String, List[UInt8]]()
    var listed = store.list_with_delimiter(Path.parse(lineage + "/"))
    for i in range(len(listed.objects)):
        var key = listed.objects[i].location
        out[key] = store.get(Path.parse(key))
    return out^


def test_a_stale_seal_below_the_log_start_does_not_retire_the_shard() raises:
    # The reaper reads generation 2 and passes the drained check, then
    # stalls. Meanwhile the writer publishes at slot 2, compaction retires
    # that chunk, and reap_chunk stubs it, advances the log start to 3 and
    # deletes it. The reaper wakes; slot 2 is empty again, so its seal wins.
    # Recording the shard as retired then would hide every later publish:
    # the writer's warm handle publishes at slot 3, above that seal and the
    # log start, without a check.
    var inner = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 12)
    var lineage = shard_manifest_prefix(_META, shard_id)
    var w = _shard_meta(inner, shard_id)
    _ = w.publish(_summary(1, Int64(2)))
    _ = w.publish(_summary(2, Int64(2)))
    _drain(w, 2)

    # Run the writer's side for real, record what it changed, and roll the
    # lineage back to the state the reaper's drained check saw. The writer's
    # warm handle keeps its view of slot 2 as its last chunk.
    var before = _lineage_objects(inner, lineage)
    _ = w.publish(_summary(3, Int64(2)))
    # The writer's durable head object catches up with its tail, as its
    # deferred head advance does on a bounded cadence. Until it does, the
    # prefix advance stops below slot 2 and the reaper's seal loses the slot.
    var tail = w._read_head_settled()
    assert_equal(tail.chunk_seq, Int64(2), "the writer's tail is chunk 2")
    _ = inner.put(
        head_key(lineage),
        encode_head(ManifestHead(tail.chunk_seq, tail.next_offset, String(""))),
    )
    w.retire_at(Int64(2), Int64(0))
    assert_true(w.reap_chunk(Int64(2), _GRACE_MS, _GRACE_MS), "chunk 2 reaped")
    var after = _lineage_objects(inner, lineage)
    assert_false(
        chunk_key(lineage, Int64(2)).raw() in after,
        "the writer's chunk 2 was deleted below the advanced log start",
    )
    var puts = List[String]()
    var bodies = List[List[UInt8]]()
    for e in after.items():
        puts.append(e.key)
        bodies.append(e.value.copy())
    var deletes = List[String]()
    for e in before.items():
        if not e.key in after:
            deletes.append(e.key)
    for e in after.items():
        if e.key in before:
            _ = inner.put(Path.parse(e.key), before[e.key])
        else:
            inner.delete(Path.parse(e.key))

    # The writer's side lands inside the reaper, after its drained check.
    var hooks = _HookStore(
        inner.clone(),
        lineage + "/tombstones/",
        String(""),
        List[UInt8](),
        String(""),
        String(""),
        deletes^,
        puts^,
        bodies^,
    )
    var r = reap_drained_shards(hooks, _META, String("logs"))

    # The shard must not have been retired, so the writer's warm publish
    # lands above the log start and is visible to the index read.
    _ = w.publish(_summary(4, Int64(2)))
    var live = list_live_splits_across_shards(inner, _META, String("logs"))
    assert_true(
        _has_uuid(live, _uuid(4)),
        "stale-seal warm publish: publish SUCCEEDED but split is NOT visible"
        + " (reaped " + String(r.shards_reaped)
        + " fenced " + String(r.shards_fenced) + ")",
    )
    assert_equal(len(live), 1, "only the warm publish is live")
    assert_equal(r.shards_reaped, 0, "a stale drained check retired the shard")
    assert_equal(r.shards_fenced, 1, "the stale seal counts as fenced")

    # Once that split is drained too, a fresh sweep retires the shard.
    var w2 = _shard_meta(inner, shard_id)
    w2.retire_at(Int64(3), Int64(0))
    assert_true(w2.reap_chunk(Int64(3), _GRACE_MS, _GRACE_MS), "chunk 3 reaped")
    var r2 = reap_drained_shards(_plain_hooks(inner), _META, String("logs"))
    assert_equal(r2.shards_reaped, 1, "the drained shard is retired")
    assert_equal(
        len(list_live_splits_across_shards(inner, _META, String("logs"))),
        0,
        "nothing is live",
    )
    with assert_raises(contains="[SHARD_RETIRED]"):
        _ = w.publish(_summary(5, Int64(2)))

    _ = inner^


# =============================================================================
# 7. Reaping chunks out of order keeps cold reads whole.
# =============================================================================


def test_reaping_a_chunk_below_the_top_keeps_cold_reads_whole() raises:
    var store = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 8)
    var w = _shard_meta(store, shard_id)
    for i in range(4):
        _ = w.publish(_summary(10 + i, Int64(2)))
    var g0 = generation_across_shards(store, _META, String("logs"))

    # Compaction retired a split in the middle of the lineage.
    w.retire_at(Int64(1), Int64(0))
    assert_true(w.reap_chunk(Int64(1), _GRACE_MS, _GRACE_MS), "chunk 1 reaped")
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), 3, "splits 10, 12 and 13 are live")
    assert_false(_has_uuid(live, _uuid(11)), "the reaped split is gone")
    var g1 = generation_across_shards(store, _META, String("logs"))
    assert_true(g1 >= g0, "reaping chunk 1 lowered the generation")

    # Then the oldest one: chunks 0 and 1 are now a reaped prefix.
    w.retire_at(Int64(0), Int64(0))
    assert_true(w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS), "chunk 0 reaped")
    var cold = _shard_meta(store, shard_id)
    var cold_live = cold.list_live_splits()
    assert_equal(len(cold_live), 2, "a cold shard read lists 12 and 13")
    assert_true(_has_uuid(cold_live, _uuid(12)), "split 12 is live")
    assert_true(_has_uuid(cold_live, _uuid(13)), "split 13 is live")
    assert_equal(cold._next_slot(), Int64(4), "the shard's next slot is 4")
    var g2 = generation_across_shards(store, _META, String("logs"))
    assert_true(g2 >= g1, "reaping chunk 0 lowered the generation")

    # The writer keeps publishing into the same shard.
    _ = w.publish(_summary(14, Int64(2)))
    live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), 3, "splits 12, 13 and 14 are live")
    assert_true(_has_uuid(live, _uuid(14)), "the new publish is visible")
    assert_true(
        generation_across_shards(store, _META, String("logs")) > g2,
        "the new publish moves the generation",
    )

    _ = store^


def test_cold_read_racing_a_prefix_reap_is_not_torn() raises:
    # A reaper advances the log start and deletes chunk 0 after a cold reader
    # has read the log start but before it reads the chunks. The reader must
    # retry against the new log start, not report a torn lineage.
    var inner = SharedInMemoryConditionalStore()
    var shard_id = make_shard_id(String("node"), 9)
    var lineage = shard_manifest_prefix(_META, shard_id)
    var w = _shard_meta(inner, shard_id)
    for i in range(3):
        _ = w.publish(_summary(20 + i, Int64(2)))
    w.retire_at(Int64(0), Int64(0))

    # What reap_chunk(0) and its prefix advance write, staged inside the
    # reader's LIST of the manifest.
    var deletes = List[String]()
    deletes.append(chunk_key(lineage, Int64(0)).raw())
    deletes.append(tombstone_key(lineage, Int64(0)).raw())
    var hooks = _HookStore(
        inner.clone(),
        lineage + "/manifest/",
        lineage + "/_LOG_START",
        encode_log_start(LogStart(Int64(2), Int64(1), String(""))),
        String(""),
        String(""),
        deletes^,
    )
    var reader = _shard_meta(hooks, shard_id)
    var live = reader.list_live_splits()
    assert_equal(len(live), 2, "splits 21 and 22 are live")
    assert_true(_has_uuid(live, _uuid(21)), "split 21 is live")
    assert_true(_has_uuid(live, _uuid(22)), "split 22 is live")

    _ = inner^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
