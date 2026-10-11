# =============================================================================
# tests/test_cov_sublineage.mojo
#   SubLineageBaseFold and ShardedLineage: the refusals of a corrupt or torn
#   fold, both listing shapes of shard discovery, the canonical sorts, and the
#   serve-assign entry points.
# =============================================================================
#
# `_FaultStore` is a clone-shared wrapper over SharedInMemoryConditionalStore
# (rules shared through an ArcPointer, as the fold clones its store per
# shard) that can fail a verb on a key substring and add stray listing
# entries.
#
# What each case catches:
#   * a `_base` chunk with a wrong version or a corrupt payload accepted on
#     reload (a wrong record served at a dense offset);
#   * a fold whose source holds fewer records than the snapshot promised, or
#     whose `_base` was appended behind its back, publishing anyway (torn
#     offsets) instead of raising;
#   * a lost source `_LOG_START` advance not recovered by the next fold
#     (an already-tombstoned chunk tombstoned twice or the pointer left
#     behind);
#   * an unsorted caller snapshot folded / served in caller order (the dense
#     layout must not depend on it);
#   * a delimiter-honouring backend's common prefixes ignored, or a malformed
#     listing entry turned into a shard id;
#   * a LIST error on the lineage prefix swallowed (only an absent prefix is
#     "no shards");
#   * the prefix test refusing the empty prefix.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    LogStart,
    RetryPolicy,
    encode_log_start,
    log_start_key,
)
from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.sharded_lineage import (
    ShardedLineage,
    shard_id_from_listing_entry,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.sublineage_base_fold import (
    BASE_SHARD_ID,
    ShardFoldedWatermark,
    ShardSnapshot,
    SubLineageBaseFold,
    _encode_base_chunk,
    _str_starts_with,
    decode_record_body,
    encode_record_body,
    sublineage_prefix,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# ---- the clone-shared fault store ----------------------------------------------

comptime V_PUT = 0
comptime V_LIST = 3


@fieldwise_init
struct _Rule(Copyable, Movable):
    var verb: Int
    var key_sub: String
    var msg: String
    var times: Int


struct _Rules(Movable):
    var rules: List[_Rule]
    var stray: List[String]
    var stray_cp: List[String]

    def __init__(out self):
        self.rules = List[_Rule]()
        self.stray = List[String]()
        self.stray_cp = List[String]()


struct _FaultStore(
    CloneableConditionalWriteStore, ConditionalWriteStore, ObjectStore,
    Movable, Deinitable,
):
    var inner: SharedInMemoryConditionalStore
    var rules: ArcPointer[_Rules]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var rules: ArcPointer[_Rules],
    ):
        self.inner = inner^
        self.rules = rules^

    def clone(self) -> Self:
        return Self(self.inner.clone(), self.rules.copy())

    def _raise_if(self, verb: Int, key: String) raises:
        ref r = self.rules[]
        for i in range(len(r.rules)):
            ref rule = r.rules[i]
            if rule.verb == verb and rule.times != 0 and key.find(rule.key_sub) >= 0:
                rule.times -= 1
                raise Error(rule.msg + " key=" + key)

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        self._raise_if(V_LIST, prefix.raw())
        var lr = self.inner.list_with_delimiter(prefix)
        ref r = self.rules[]
        for i in range(len(r.stray)):
            lr.objects.append(
                ObjectMeta(r.stray[i], Int64(1), String("s"), Int64(-1), String(""))
            )
        for i in range(len(r.stray_cp)):
            lr.common_prefixes.append(r.stray_cp[i])
        return lr^

    def coalesce_policy(self) -> CoalescePolicy:
        return CoalescePolicy.default()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._raise_if(V_PUT, path.raw())
        return self.inner.conditional_put(path, bytes, precond)

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
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


comptime TRANSPORT = "StoreError[TRANSPORT] connection reset status=503"

comptime _Fold = SubLineageBaseFold[SharedInMemoryConditionalStore]


def _recs(a: Int64, n: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        out.append(a + Int64(i))
    return out^


def _base_manifest(
    shared: SharedInMemoryConditionalStore, part: String
) -> CasManifestStore[SharedInMemoryConditionalStore]:
    return CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(),
        prefix=sublineage_prefix(part, BASE_SHARD_ID),
        retry=RetryPolicy.fast_test(),
    )


def _err_reload(mut f: _Fold) -> String:
    try:
        f.reload_from_base()
        return String("")
    except e:
        return String(e)


# ---- corrupt `_base` blocks are refused on reload ---------------------------------


def test_reload_refuses_corrupt_base_blocks() raises:
    var shared = SharedInMemoryConditionalStore()
    var f = _Fold(shared.clone(), String("p/ver"))
    _ = f.append_batch(String("w"), _recs(100, 2))
    _ = f.run_once()
    # A block written with an unknown format version.
    var bad = _encode_base_chunk(String("w"), Int64(2), _recs(7, 1))
    bad[0] = UInt8(9)
    var bm = _base_manifest(shared, String("p/ver"))
    _ = bm.append(bad, Int64(1))
    var msg = _err_reload(f)
    assert_equal(msg, String("sublineage_base_fold: unknown _base chunk version 9"))

    var shared2 = SharedInMemoryConditionalStore()
    var g = _Fold(shared2.clone(), String("p/crc"))
    # A block whose payload no longer matches its CRC.
    var corrupt = _encode_base_chunk(String("w"), Int64(0), _recs(5, 2))
    corrupt[len(corrupt) - 1] ^= UInt8(0x01)
    var bm2 = _base_manifest(shared2, String("p/crc"))
    _ = bm2.append(corrupt, Int64(2))
    var cmsg = _err_reload(g)
    assert_true(cmsg.find("_base chunk CRC mismatch (corrupt block): stored=") >= 0, cmsg)
    assert_true(cmsg.find(" computed=") >= 0, cmsg)


def test_reload_clamps_negative_base_log_start() raises:
    var shared = SharedInMemoryConditionalStore()
    var f = _Fold(shared.clone(), String("p/neg"))
    _ = f.append_batch(String("w"), _recs(10, 3))
    _ = f.run_once()
    # `_base`'s `_LOG_START` holding a negative seq reads from slot 0.
    _ = shared.put(
        log_start_key(sublineage_prefix(String("p/neg"), BASE_SHARD_ID)),
        encode_log_start(LogStart(Int64(0), Int64(-5), String(""))),
    )
    f.reload_from_base()
    var r = f.resolve_offset(Int64(2))
    assert_true(r.found)
    assert_equal(r.shard_id, String("w"))
    assert_equal(r.local_offset, Int64(2))
    assert_equal(r.payload, Int64(12))
    # An offset past every folded block is not found (not a wrong record).
    var none = f.resolve_offset(Int64(3))
    assert_false(none.found)
    assert_equal(none.payload, Int64(-1))


# ---- torn folds raise -------------------------------------------------------


def test_fold_refuses_a_torn_source() raises:
    var shared = SharedInMemoryConditionalStore()
    var f = _Fold(shared.clone(), String("p/torn"))
    _ = f.append_batch(String("w"), _recs(1, 2))
    # A caller snapshot that claims 5 records where the shard holds 2.
    var snap = List[ShardSnapshot]()
    snap.append(ShardSnapshot(String("w"), Int64(0), Int64(5)))
    var msg = String("")
    try:
        _ = f.fold(snap)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("sublineage_base_fold: source range [0..5) on shard w yielded 2 records (torn source)"),
    )
    assert_equal(f.live_base_chunk_count(), 0)


def test_fold_refuses_a_foreign_base_append() raises:
    var shared = SharedInMemoryConditionalStore()
    var f = _Fold(shared.clone(), String("p/foreign"))
    _ = f.append_batch(String("w"), _recs(1, 2))
    _ = f.run_once()
    # Another writer appends to `_base` behind this fold's index.
    var bm = _base_manifest(shared, String("p/foreign"))
    _ = bm.append(_encode_base_chunk(String("x"), Int64(0), _recs(3, 3)), Int64(3))
    _ = f.append_batch(String("w"), _recs(9, 1))
    var msg = String("")
    try:
        _ = f.run_once()
    except e:
        msg = String(e)
    assert_equal(msg, String("sublineage_base_fold: _base base_offset 5 != fold high-water 2"))


def test_record_body_truncation() raises:
    var body = encode_record_body(_recs(4, 3))
    assert_equal(len(decode_record_body(body, Int64(3))), 3)
    var msg = String("")
    try:
        _ = decode_record_body(body, Int64(4))
    except e:
        msg = String(e)
    assert_equal(msg, String("sublineage_base_fold: record body truncated"))


# ---- a lost source `_LOG_START` advance is recovered ------------------------------


def test_lost_source_advance_recovered_by_next_fold() raises:
    var shared = SharedInMemoryConditionalStore()
    var rules = ArcPointer[_Rules](_Rules())
    var f = SubLineageBaseFold[_FaultStore](
        _FaultStore(shared.clone(), rules.copy()), String("p/adv")
    )
    _ = f.append_batch(String("w"), _recs(1, 2))
    # The fold's advance of w's `_LOG_START` loses a race (412): swallowed.
    rules[].rules.append(
        _Rule(V_PUT, String("p/adv/_lineage/w/_LOG_START"), String("precondition (412) raced"), 1)
    )
    var s1 = f.run_once()
    assert_equal(s1.records_folded, Int64(2))
    var w = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=sublineage_prefix(String("p/adv"), String("w"))
    )
    assert_equal(w.read_log_start().log_start_seq, Int64(0))
    assert_equal(len(w.tombstone_seqs()), 1)
    var ts0 = w.tombstone_schedule_ts(Int64(0))
    _ = external_call["usleep", Int32](UInt32(5_000))  # the ms clock moves
    # The next fold walks from the stale pointer: chunk 0 is already
    # tombstoned (not re-marked: its schedule ts is unchanged), chunk 1 is
    # tombstoned, the pointer lands.
    _ = f.append_batch(String("w"), _recs(3, 1))
    var s2 = f.run_once()
    assert_equal(s2.records_folded, Int64(1))
    var ts = w.tombstone_seqs()
    assert_equal(len(ts), 2)
    assert_equal(ts[0], Int64(0))
    assert_equal(ts[1], Int64(1))
    assert_equal(w.tombstone_schedule_ts(Int64(0)), ts0)
    var ls = w.read_log_start()
    assert_equal(ls.log_start_seq, Int64(2))
    assert_equal(ls.log_start_offset, Int64(3))


# ---- canonical sorts and the serve-assign entry points ------------------------------


def test_unsorted_snapshot_is_canonicalised() raises:
    var shared = SharedInMemoryConditionalStore()
    var f = _Fold(shared.clone(), String("p/sort"))
    _ = f.append_batch(String("b"), _recs(20, 1))
    _ = f.append_batch(String("a"), _recs(10, 2))
    _ = f.append_batch(String("c"), _recs(30, 1))
    var rev = List[ShardSnapshot]()
    rev.append(ShardSnapshot(String("c"), Int64(0), Int64(1)))
    rev.append(ShardSnapshot(String("b"), Int64(0), Int64(1)))
    rev.append(ShardSnapshot(String("a"), Int64(0), Int64(2)))
    # Serve-assign over the caller's (reversed) snapshot: a, b, c.
    var plan = f.serve_assign_tail_for(rev)
    assert_equal(len(plan), 3)
    assert_equal(plan[0].shard_id, String("a"))
    assert_equal(plan[0].dense_base, Int64(0))
    assert_equal(plan[1].shard_id, String("b"))
    assert_equal(plan[1].dense_base, Int64(2))
    assert_equal(plan[2].shard_id, String("c"))
    assert_equal(plan[2].dense_base, Int64(3))
    # The explicit form with caller-supplied counts: `a` already has 1 folded.
    var wms = List[ShardFoldedWatermark]()
    wms.append(ShardFoldedWatermark(String("a"), Int64(1)))
    var ex = f.serve_assign_tail_explicit(rev, wms, Int64(100))
    assert_equal(ex[0].shard_id, String("a"))
    assert_equal(ex[0].source_local_base, Int64(1))
    assert_equal(ex[0].dense_base, Int64(100))
    assert_equal(ex[1].dense_base, Int64(101))
    # The self-pinned forms agree with the explicit snapshot.
    assert_equal(len(f.snapshot_explicit()), 3)
    var tail = f.serve_assign_tail()
    assert_equal(len(tail), 3)
    assert_equal(tail[2].shard_id, String("c"))
    assert_equal(tail[2].dense_base, Int64(3))
    # Folding the reversed snapshot persists the same layout.
    _ = f.fold(rev)
    assert_equal(f.base_head_next_dense(), Int64(4))
    assert_equal(f.resolve_offset(Int64(0)).payload, Int64(10))
    assert_equal(f.resolve_offset(Int64(2)).payload, Int64(20))
    assert_equal(f.resolve_offset(Int64(3)).payload, Int64(30))
    # A shard with nothing folded counts as a live tail.
    _ = f.append_batch(String("d"), _recs(40, 1))
    var bs = f.bound_stats()
    assert_equal(bs.live_tail_shards, 1)
    assert_equal(bs.distinct_folded_shards, 3)


def test_sharded_lineage_sorts_and_listing() raises:
    var df = DelimiterFaithfulConditionalStore()
    # A delimiter-honouring backend: shards come back as common prefixes.
    var fold = SubLineageBaseFold[DelimiterFaithfulConditionalStore](
        df.clone(), String("p/df")
    )
    _ = fold.append_batch(String("w2"), _recs(1, 1))
    _ = fold.append_batch(String("w1"), _recs(2, 1))
    var ids = fold.enumerate_live_shards()
    assert_equal(len(ids), 2)
    assert_equal(ids[0], String("w1"))
    assert_equal(ids[1], String("w2"))
    var sl = ShardedLineage[DelimiterFaithfulConditionalStore](df.clone(), String("p/df"))
    var sids = sl.enumerate_live_shards()
    assert_equal(len(sids), 2)
    assert_equal(sids[0], String("w1"))
    _ = fold.run_once()
    # `_base` exists now and is excluded from both enumerations.
    assert_equal(len(fold.enumerate_live_shards()), 2)
    assert_equal(len(sl.enumerate_live_shards()), 2)
    # sort_snapshot puts a reversed list in canonical order.
    var rev = List[ShardSnapshot]()
    rev.append(ShardSnapshot(String("z"), Int64(0), Int64(1)))
    rev.append(ShardSnapshot(String("m"), Int64(0), Int64(1)))
    rev.append(ShardSnapshot(String("a"), Int64(0), Int64(1)))
    var srt = sl.sort_snapshot(rev)
    assert_equal(srt[0].shard_id, String("a"))
    assert_equal(srt[1].shard_id, String("m"))
    assert_equal(srt[2].shard_id, String("z"))
    # The listing-entry parser: a foreign entry and an empty segment are "".
    assert_equal(shard_id_from_listing_entry(String("q/_lineage/s/x"), String("p/_lineage/")), String(""))
    assert_equal(shard_id_from_listing_entry(String("p/_lineage//x"), String("p/_lineage/")), String(""))
    assert_equal(shard_id_from_listing_entry(String("p/_lineage/s/x"), String("p/_lineage/")), String("s"))


def test_listing_errors_and_strays() raises:
    var shared = SharedInMemoryConditionalStore()
    var rules = ArcPointer[_Rules](_Rules())
    var store = _FaultStore(shared.clone(), rules.copy())
    var sl = ShardedLineage[_FaultStore](store.clone(), String("p/st"))
    var f = SubLineageBaseFold[_FaultStore](store.clone(), String("p/st"))
    _ = f.append_batch(String("w"), _recs(1, 1))
    # ShardedLineage: an absent prefix is no shards; a 503 is raised.
    rules[].rules.append(_Rule(V_LIST, String("p/st/_lineage/"), String("NoSuchKey"), 1))
    assert_equal(len(sl.enumerate_live_shards()), 0)
    rules[].rules.append(_Rule(V_LIST, String("p/st/_lineage/"), String(TRANSPORT), 1))
    var msg = String("")
    try:
        _ = sl.enumerate_live_shards()
    except e:
        msg = String(e)
    assert_true(msg.find("status=503") >= 0, msg)
    # Stray entries (foreign, shorter than the prefix, empty segment) are
    # never shards, in either arm, for either enumerator.
    rules[].stray.append(String("q/st/_lineage/zz/_HEAD"))
    rules[].stray.append(String("p/st"))
    rules[].stray.append(String("p/st/_lineage//k"))
    rules[].stray_cp.append(String("q/st/_lineage/yy/"))
    rules[].stray_cp.append(String("p/st/_lineage//"))
    rules[].stray_cp.append(String("p/st/_lineage/v/"))
    var a = sl.enumerate_live_shards()
    assert_equal(len(a), 2)
    assert_equal(a[0], String("v"))
    assert_equal(a[1], String("w"))
    var b = f.enumerate_live_shards()
    assert_equal(len(b), 2)
    assert_equal(b[0], String("v"))
    assert_equal(b[1], String("w"))



def test_sharded_should_fold() raises:
    var shared = SharedInMemoryConditionalStore()
    var sl = ShardedLineage[SharedInMemoryConditionalStore](shared.clone(), String("p/sf"))
    # An empty partition never folds, even with the timer elapsed.
    assert_false(sl.should_fold(0, Int64(100), Int64(50)))
    var f = _Fold(shared.clone(), String("p/sf"))
    _ = f.append_batch(String("w"), _recs(1, 1))
    assert_equal(sl.live_shard_count(), 1)
    # Over the threshold: fold.
    assert_true(sl.should_fold(0, Int64(0), Int64(0)))
    # At the threshold, timer not yet elapsed: no fold; elapsed exactly: fold.
    assert_false(sl.should_fold(1, Int64(49), Int64(50)))
    assert_true(sl.should_fold(1, Int64(50), Int64(50)))
    # A disabled timer never fires.
    assert_false(sl.should_fold(1, Int64(1000), Int64(0)))

def test_starts_with_empty_prefix() raises:
    # Every string starts with the empty prefix, the empty string included.
    assert_true(_str_starts_with(String("p/_lineage/x"), String("")))
    assert_true(_str_starts_with(String(""), String("")))
    assert_false(_str_starts_with(String(""), String("p")))


def main() raises:
    test_reload_refuses_corrupt_base_blocks()
    test_reload_clamps_negative_base_log_start()
    test_fold_refuses_a_torn_source()
    test_fold_refuses_a_foreign_base_append()
    test_record_body_truncation()
    test_lost_source_advance_recovered_by_next_fold()
    test_unsorted_snapshot_is_canonicalised()
    test_sharded_lineage_sorts_and_listing()
    test_listing_errors_and_strays()
    test_sharded_should_fold()
    test_starts_with_empty_prefix()
    print("[test_cov_sublineage] PASS")
