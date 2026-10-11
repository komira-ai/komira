# =============================================================================
# test_search_catalog_record_faults.mojo
#   The compare-and-swap records of generation.mojo and the drained-shard
#   reaper under store failures, lost races and a delimiter-honoring LIST.
# =============================================================================
#
#   1. test_a_lost_compare_and_swap_is_retried: each of the four record
#      writers (generation floor, bumps counter, retired-shards record, log
#      start) retries a lost conditional write and lands its value.
#   2. test_a_compare_and_swap_lost_every_time_gives_up_after_64: each raises
#      "lost the compare-and-swap ... 64 times" after exactly 64 attempts.
#   3. test_a_store_failure_in_a_record_write_is_not_retried: a failure that
#      is not a lost race raises after one attempt.
#   4. test_record_reads_fail_closed: a failed HEAD or GET of a record
#      raises; a record deleted between its HEAD and GET reads as absent.
#   5. test_record_retired_shard_writes_only_a_raise.
#   6. test_reads_of_a_failing_retired_shards_record_raise.
#   7. test_a_shard_with_a_pending_tombstone_is_not_reaped.
#   8. test_a_shard_holding_only_a_stray_object_is_retired: a shard with no
#      chunk and no log start is sealed at slot 0.
#   9. test_the_sweep_descends_a_delimiter_honoring_listing: on a store
#      whose LIST folds sub-directories into common prefixes, the sweep still
#      deletes every object down to three levels below the shard. A key four
#      levels down is missed (komira-ai/komira#1373) and is not tested.
#  10. test_a_chunk_deleted_under_the_seal_scan_is_skipped and
#      test_a_failed_read_in_the_seal_scan_raises.
#  11. test_a_failed_seal_write_raises.
#
# `_FaultStore` is the same wrapper as in test_search_metastore_faults.mojo
# (rules under `__fault__/<op>/<key>` in the shared map).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_objectstore import (
    CasManifestStore,
    CoalescePolicy,
    DelimiterFaithfulConditionalStore,
    ListResult,
    ObjectMeta,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    WritePrecondition,
    chunk_key,
    decode_chunk_body,
    encode_chunk,
    log_start_key,
    tombstone_key,
)
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
    list_live_splits_across_shards,
    make_shard_id,
    shard_manifest_prefix,
)
from komira_search_catalog.generation import (
    advance_log_start_to,
    bump_generation,
    decode_generation_bumps,
    generation_bumps_key,
    generation_floor_key,
    raise_generation_floor,
    read_generation_floor,
    read_log_start_seq,
    read_retired_shards,
    record_retired_shard,
    retired_shards_key,
)
from komira_search_catalog.shard_reaper import reap_drained_shards


comptime _Inner = SharedInMemoryConditionalStore
comptime _RULES = "__fault__/"
comptime _L: String = "index/logs/meta"
comptime _DENIED = "StoreError[PERMISSION_DENIED] status=403 AccessDenied"
comptime _UNAVAILABLE = "StoreError[UNAVAILABLE] status=503 SlowDown"
comptime _PRECOND = "StoreError[PRECONDITION_FAILED] status=412"
comptime _GRACE_MS = Int64(1000)



def _le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


def _le_at(b: List[UInt8], off: Int) -> Int64:
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(b[off + i])) << UInt64(8 * i)
    return Int64(u)


def _rule(op: String, key: String) raises -> Path:
    return Path.parse(_RULES + op + "/" + key)


def _arm(
    store: _Inner,
    op: String,
    key: String,
    msg: String,
    skip: Int = 0,
    count: Int = 1 << 20,
) raises:
    var b = List[UInt8]()
    _le(b, Int64(skip))
    _le(b, Int64(count))
    _le(b, Int64(0))
    var mb = msg.as_bytes()
    for i in range(len(mb)):
        b.append(mb[i])
    _ = store.put(_rule(op, key), b)


def _fired(store: _Inner, op: String, key: String) raises -> Int:
    return Int(_le_at(store.get(_rule(op, key)), 16))


def _fire(store: _Inner, op: String, key: String) raises -> Optional[String]:
    """Consume one call against the rule; the message when it fires."""
    var p = _rule(op, key)
    var b: List[UInt8]
    try:
        b = store.get(p)
    except:
        return None
    var skip = _le_at(b, 0)
    var count = _le_at(b, 8)
    var fired = _le_at(b, 16)
    var hit = False
    if skip > 0:
        skip -= 1
    elif count > 0:
        count -= 1
        fired += 1
        hit = True
    else:
        return None
    var nb = List[UInt8]()
    _le(nb, skip)
    _le(nb, count)
    _le(nb, fired)
    var msg = String("")
    for i in range(24, len(b)):
        nb.append(b[i])
        msg += chr(Int(b[i]))  # ASCII messages only
    _ = store.put(p, nb)
    if hit:
        return Optional(msg^)
    return None


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: _Inner
    var _list_trigger: String
    var _trigger_deletes: List[String]
    var _trigger_puts: List[String]
    var _trigger_bodies: List[List[UInt8]]

    def __init__(
        out self,
        var inner: _Inner,
        var list_trigger: String = String(""),
        var trigger_deletes: List[String] = List[String](),
        var trigger_puts: List[String] = List[String](),
        var trigger_bodies: List[List[UInt8]] = List[List[UInt8]](),
    ):
        self._inner = inner^
        self._list_trigger = list_trigger^
        self._trigger_deletes = trigger_deletes^
        self._trigger_puts = trigger_puts^
        self._trigger_bodies = trigger_bodies^

    def clone(self) -> Self:
        return Self(
            self._inner.clone(),
            self._list_trigger.copy(),
            self._trigger_deletes.copy(),
            self._trigger_puts.copy(),
            self._trigger_bodies.copy(),
        )

    def _check(self, op: String, path: Path) raises:
        var m = _fire(self._inner, op, path.raw())
        if m:
            raise Error(m.value())

    def head(self, path: Path) raises -> ObjectMeta:
        self._check("head", path)
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        if (
            self._list_trigger.byte_length() > 0
            and prefix.raw() == self._list_trigger
        ):
            for i in range(len(self._trigger_deletes)):
                self._inner.delete(Path.parse(self._trigger_deletes[i]))
            for i in range(len(self._trigger_puts)):
                _ = self._inner.put(
                    Path.parse(self._trigger_puts[i]), self._trigger_bodies[i]
                )
        self._check("list", prefix)
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._check("put", path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._check("put", path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._check("put", path)
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        if _fire(self._inner, "gone", path.raw()):
            self._inner.delete(path)
        self._check("get", path)
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if _fire(self._inner, "gone", path.raw()):
            self._inner.delete(path)
        self._check("get", path)
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._check("delete", path)
        self._inner.delete(path)


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 7 + i * 13) & 0xFF)
    return u^


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


def _plain(inner: _Inner) -> _FaultStore:
    return _FaultStore(inner.clone())


def _meta[
    S: CloneableConditionalWriteStore
](store: S, lineage: String) raises -> SearchMetastore[S]:
    var manifest = CasManifestStore[S](
        store.clone(), lineage.copy(), RetryPolicy.fast_test()
    )
    return SearchMetastore[S](manifest^, String("logs"))


def _exists[S: ConditionalWriteStore](store: S, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return True
    except:
        return False


def _drained_shard[
    S: CloneableConditionalWriteStore
](store: S, n: Int, publishes: Int) raises -> String:
    """A writer shard that published `publishes` splits, all retired and
    reaped. Returns its lineage prefix."""
    var lineage = shard_manifest_prefix(_L, make_shard_id(String("node"), n))
    var w = _meta(store, lineage)
    for i in range(publishes):
        _ = w.publish(_summary(n * 10 + i))
    for i in range(publishes):
        w.retire_at(Int64(i), Int64(0))
    for i in range(publishes):
        assert_true(w.reap_chunk(Int64(i), _GRACE_MS, _GRACE_MS), "reaped")
    return lineage^


# =============================================================================
# 1-3. The compare-and-swap loops of the four record writers.
# =============================================================================

comptime _WRITERS = 4


def _record_key(which: Int) raises -> String:
    if which == 0:
        return generation_floor_key(_L).raw()
    if which == 1:
        return generation_bumps_key(_L).raw()
    if which == 2:
        return retired_shards_key(_L).raw()
    return log_start_key(_L).raw()


def _write(which: Int, store: _FaultStore) raises:
    if which == 0:
        raise_generation_floor(store, _L, Int64(9))
    elif which == 1:
        bump_generation(store, _L)
    elif which == 2:
        record_retired_shard(store, _L, String("w-1"), Int64(9))
    else:
        advance_log_start_to(store, _L, Int64(9), Int64(18))


def _value(which: Int, inner: _Inner) raises -> Int64:
    if which == 0:
        return read_generation_floor(inner, _L)
    if which == 1:
        return decode_generation_bumps(inner.get(generation_bumps_key(_L)))
    if which == 2:
        return read_retired_shards(inner, _L).generation_of(String("w-1"))
    return read_log_start_seq(inner, _L)


def _expected(which: Int) -> Int64:
    if which == 1:
        return Int64(1)
    return Int64(9)


def test_a_lost_compare_and_swap_is_retried() raises:
    for which in range(_WRITERS):
        var inner = _Inner()
        var key = _record_key(which)
        _arm(inner, "put", key, _PRECOND, count=3)
        _write(which, _plain(inner))
        assert_equal(_fired(inner, "put", key), 3, "writer " + String(which))
        assert_equal(_value(which, inner), _expected(which), key)
        _ = inner^


def test_a_compare_and_swap_lost_every_time_gives_up_after_64() raises:
    for which in range(_WRITERS):
        var inner = _Inner()
        var key = _record_key(which)
        _arm(inner, "put", key, _PRECOND)
        var msg = String("")
        try:
            _write(which, _plain(inner))
        except e:
            msg = String(e)
        assert_true(
            msg.find("lost the compare-and-swap on " + key + " 64 times") >= 0,
            "writer " + String(which) + ": " + msg,
        )
        assert_equal(_fired(inner, "put", key), 64, key)
        assert_false(_exists(inner, key), "nothing written: " + key)
        _ = inner^


def test_a_store_failure_in_a_record_write_is_not_retried() raises:
    for which in range(_WRITERS):
        var inner = _Inner()
        var key = _record_key(which)
        _arm(inner, "put", key, _UNAVAILABLE)
        var msg = String("")
        try:
            _write(which, _plain(inner))
        except e:
            msg = String(e)
        assert_true(msg.find("UNAVAILABLE") >= 0, key + ": " + msg)
        assert_equal(_fired(inner, "put", key), 1, "one attempt: " + key)
        _ = inner^


# =============================================================================
# 4-6. Record reads.
# =============================================================================


def test_record_reads_fail_closed() raises:
    var inner = _Inner()
    var store = _plain(inner)
    var key = generation_bumps_key(_L).raw()
    for _ in range(4):
        bump_generation(store, _L)
    assert_equal(_value(1, inner), Int64(4))
    # A failed HEAD and a failed GET raise; nothing is written.
    _arm(inner, "head", key, _UNAVAILABLE, count=1)
    with assert_raises(contains="UNAVAILABLE"):
        bump_generation(store, _L)
    _arm(inner, "get", key, _DENIED, count=1)
    with assert_raises(contains="PERMISSION_DENIED"):
        bump_generation(store, _L)
    assert_equal(_value(1, inner), Int64(4), "no failed bump wrote")
    # Deleted between the HEAD and the GET: absent, so the counter is
    # created afresh by create-if-absent.
    _arm(inner, "gone", key, String("-"), count=1)
    bump_generation(store, _L)
    assert_equal(_fired(inner, "gone", key), 1)
    assert_equal(_value(1, inner), Int64(1), "recreated at 1")

    # The floor: absent reads 0, it only rises, a failed read raises.
    assert_equal(read_generation_floor(inner, _L), Int64(0))
    raise_generation_floor(store, _L, Int64(7))
    raise_generation_floor(store, _L, Int64(3))
    assert_equal(read_generation_floor(inner, _L), Int64(7), "never lowered")
    _arm(inner, "get", generation_floor_key(_L).raw(), _DENIED, count=1)
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = read_generation_floor(store, _L)

    # The log start: absent reads 0.
    assert_equal(read_log_start_seq(inner, String("index/other/meta")), Int64(0))
    _ = inner^


def test_record_retired_shard_writes_only_a_raise() raises:
    var inner = _Inner()
    var store = _plain(inner)
    record_retired_shard(store, _L, String("w-1"), Int64(9))
    record_retired_shard(store, _L, String("w-2"), Int64(4))
    var key = retired_shards_key(_L).raw()
    _arm(inner, "put", key, _DENIED)
    # Not above the recorded value: no write at all.
    record_retired_shard(store, _L, String("w-1"), Int64(9))
    record_retired_shard(store, _L, String("w-1"), Int64(5))
    assert_equal(_fired(inner, "put", key), 0, "no write for a non-raise")
    with assert_raises(contains="PERMISSION_DENIED"):
        record_retired_shard(store, _L, String("w-1"), Int64(10))
    var r = read_retired_shards(inner, _L)
    assert_equal(len(r), 2)
    assert_equal(r.generation_of(String("w-1")), Int64(9))
    assert_equal(r.generation_of(String("w-2")), Int64(4))
    _ = inner^


def test_reads_of_a_failing_retired_shards_record_raise() raises:
    var inner = _Inner()
    var store = _plain(inner)
    var w = _meta(store, shard_manifest_prefix(_L, make_shard_id(String("node"), 1)))
    _ = w.publish(_summary(1))
    _arm(inner, "get", retired_shards_key(_L).raw(), _UNAVAILABLE)
    with assert_raises(contains="UNAVAILABLE"):
        _ = list_live_splits_across_shards(store, _L, String("logs"))
    with assert_raises(contains="UNAVAILABLE"):
        _ = generation_across_shards(store, _L, String("logs"))
    with assert_raises(contains="UNAVAILABLE"):
        _ = reap_drained_shards(store, _L, String("logs"))
    _ = inner^


# =============================================================================
# 7-11. reap_drained_shards.
# =============================================================================


def test_a_shard_with_a_pending_tombstone_is_not_reaped() raises:
    var inner = _Inner()
    var store = _plain(inner)
    var lineage = shard_manifest_prefix(_L, make_shard_id(String("node"), 1))
    var w = _meta(store, lineage)
    _ = w.publish(_summary(1))
    w.retire_at(Int64(0), Int64(0))
    # No live split, but the retired chunk is not reaped yet.
    assert_equal(
        len(list_live_splits_across_shards(store, _L, String("logs"))), 0
    )
    var r = reap_drained_shards(store, _L, String("logs"))
    assert_equal(r.shards_examined, 1)
    assert_equal(r.shards_reaped, 0, "a pending tombstone keeps the shard")
    assert_equal(r.objects_deleted, 0)
    assert_true(_exists(inner, tombstone_key(lineage, Int64(0)).raw()))
    assert_equal(
        w.tombstoned_chunk_object_key(Int64(0)),
        String("index/logs/splits/s-1.split"),
        "the chunk still names its split object",
    )
    _ = inner^


def test_a_shard_holding_only_a_stray_object_is_retired() raises:
    var inner = _Inner()
    var store = _plain(inner)
    var lineage = shard_manifest_prefix(_L, make_shard_id(String("node"), 2))
    var stray = lineage + "/stray.obj"
    _ = inner.put(Path.parse(stray), List[UInt8]())
    var r = reap_drained_shards(store, _L, String("logs"))
    assert_equal(r.shards_examined, 1)
    assert_equal(r.shards_reaped, 1, "an empty shard is drained")
    assert_equal(r.shards_fenced, 0, "no log start is not a moved one")
    assert_equal(r.objects_deleted, 1)
    assert_false(_exists(inner, stray), "the stray is deleted")
    var seal = decode_chunk_body(inner.get(chunk_key(lineage, Int64(0))))
    assert_equal(len(seal), 0, "the seal is at slot 0")
    assert_equal(read_log_start_seq(inner, lineage), Int64(0))
    assert_equal(
        read_retired_shards(inner, _L).generation_of(
            make_shard_id(String("node"), 2)
        ),
        Int64(1),
        "recorded one above the seal",
    )
    _ = inner^


def _all_keys(
    store: DelimiterFaithfulConditionalStore, prefix: String
) raises -> List[String]:
    """Every key under `prefix`, following common prefixes to any depth."""
    var out = List[String]()
    var todo = List[String]()
    todo.append(prefix)
    while len(todo) > 0:
        var p = todo.pop()
        var listed = store.list_with_delimiter(Path.parse(p))
        for i in range(len(listed.objects)):
            out.append(listed.objects[i].location)
        for j in range(len(listed.common_prefixes)):
            todo.append(listed.common_prefixes[j])
    return out^


def _contains(xs: List[String], s: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == s:
            return True
    return False


def test_the_sweep_descends_a_delimiter_honoring_listing() raises:
    var store = DelimiterFaithfulConditionalStore()
    var lineage = _drained_shard(store, 3, 2)
    var depth2 = lineage + "/_meta/stray.obj"
    var depth3 = lineage + "/_meta/x/stray.obj"
    _ = store.put(Path.parse(depth2), List[UInt8]())
    _ = store.put(Path.parse(depth3), List[UInt8]())
    var before = _all_keys(store, lineage + "/")
    assert_true(_contains(before, chunk_key(lineage, Int64(1)).raw()))
    assert_true(_contains(before, depth3))
    var r = reap_drained_shards(store, _L, String("logs"))
    assert_equal(r.shards_reaped, 1)
    var after = _all_keys(store, lineage + "/")
    assert_equal(len(after), 3, "seal, log start and counter remain")
    assert_true(_contains(after, chunk_key(lineage, Int64(2)).raw()), "seal")
    assert_true(_contains(after, log_start_key(lineage).raw()), "log start")
    assert_true(
        _contains(after, generation_bumps_key(lineage).raw()), "counter"
    )
    assert_equal(
        r.objects_deleted, len(before) - 2, "every other object deleted"
    )


def test_a_chunk_deleted_under_the_seal_scan_is_skipped() raises:
    var inner = _Inner()
    var store = _plain(inner)
    var lineage = _drained_shard(store, 4, 3)
    # A reaper crashed after moving the log start past chunk 0 and before
    # deleting it; a racing reaper deletes it just before this sweep's seal
    # scan reads it.
    var chunk0 = chunk_key(lineage, Int64(0)).raw()
    var stub = List[UInt8]()
    stub.append(UInt8(0))
    _ = inner.put(Path.parse(chunk0), encode_chunk(stub, Int64(2)))
    _arm(inner, "gone", chunk0, String("-"), count=1)
    var r = reap_drained_shards(store, _L, String("logs"))
    assert_equal(_fired(inner, "gone", chunk0), 1, "the scan read chunk 0")
    assert_equal(r.shards_reaped, 1, "the absent chunk is skipped")
    assert_false(_exists(inner, chunk0))
    _ = inner^


def test_a_failed_read_in_the_seal_scan_raises() raises:
    var inner = _Inner()
    var store = _plain(inner)
    var lineage = _drained_shard(store, 5, 3)
    var chunk0 = chunk_key(lineage, Int64(0)).raw()
    var stub = List[UInt8]()
    stub.append(UInt8(0))
    _ = inner.put(Path.parse(chunk0), encode_chunk(stub, Int64(2)))
    _arm(inner, "get", chunk0, _DENIED)
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = reap_drained_shards(store, _L, String("logs"))
    assert_equal(_fired(inner, "get", chunk0), 1)
    assert_true(_exists(inner, chunk0), "nothing below the failure deleted")
    _ = inner^


def test_a_failed_seal_write_raises() raises:
    var inner = _Inner()
    var store = _plain(inner)
    var lineage = _drained_shard(store, 6, 2)
    var seal = chunk_key(lineage, Int64(2)).raw()
    _arm(inner, "put", seal, _UNAVAILABLE)
    with assert_raises(contains="UNAVAILABLE"):
        _ = reap_drained_shards(store, _L, String("logs"))
    assert_false(_exists(inner, seal), "no seal")
    assert_equal(len(read_retired_shards(inner, _L)), 0, "nothing recorded")
    _ = inner^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
