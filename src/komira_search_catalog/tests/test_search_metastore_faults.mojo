# =============================================================================
# test_search_metastore_faults.mojo
#   SearchMetastore under store failures and damaged lineages: a failure that
#   does not prove absence reaches the caller, a proven absence is skipped,
#   and the publish retirement check refuses what no reader would see.
# =============================================================================
#
#   1. test_publish_retries_a_torn_recovery_while_the_log_start_moves: a cold
#      publish whose head recovery races a reaper (log start advanced, chunk
#      below it deleted) retries and lands at the true tail.
#   2. test_a_lineage_that_stays_torn_raises_the_torn_error: publish, the
#      live listing and generation() raise the torn-lineage error instead of
#      looping or answering from a short lineage.
#   3. test_a_failed_listing_is_not_retried_as_torn: a LIST failure that is
#      not a torn lineage reaches a cold reader after exactly one LIST.
#      test_a_torn_recovery_is_tried_exactly_twice_at_log_start_0: with the
#      log start at 0 and not moving, publish, the live listing and
#      generation() each recover the head twice (the unconditional retry),
#      then raise without a third try.
#   4. test_publish_past_a_stale_head_below_the_log_start_is_refused: a cold
#      writer that trusts a `_HEAD` below `_LOG_START` wins a slot no reader
#      replays; the publish raises instead of reporting success.
#      test_cold_publish_into_a_fully_reaped_lineage_wins_the_log_start: the
#      boundary of that refusal: every chunk reaped, the recovered head is
#      log start - 1, and the publish that wins exactly the log-start slot
#      succeeds and is visible.
#   5. test_retirement_check_steps_over_an_absent_chunk_to_a_seal: the
#      check reads down past a chunk the store proves absent, finds the seal
#      and refuses the publish.
#   6. test_retirement_check_raises_a_store_failure: a read failure in the
#      check is not taken for an absent chunk.
#   7. test_generation_raises_when_a_record_cannot_be_read: a failed or
#      corrupt `_GENERATION_FLOOR` / `_GENERATION_BUMPS` read raises.
#   8. test_reap_of_an_untombstoned_chunk_changes_nothing and
#      test_reap_raises_a_failed_tombstone_read.
#   9. test_reap_raises_a_failed_stub_rewrite_and_can_be_rerun and
#      test_reap_raises_a_failed_reread_after_a_lost_rewrite.
#  10. test_reap_without_a_head_object_advances_the_log_start and
#      test_reap_raises_a_failed_head_object_read.
#  11. test_tombstone_reads: the timestamp and object key of a tombstoned
#      chunk, and a reaped chunk answers not-found.
#  12. test_index_generation_counts_recorded_and_vanished_shards.
#
# `_FaultStore` wraps the shared in-memory store. Its rules live in the
# shared map under `__fault__/<op>/<key>`, so every clone a manifest builds
# sees them: each rule lets `skip` matching calls through, then raises its
# message on the next `count` ones and counts them. The `gone` rule deletes
# the key just before a GET of it (a racing reaper). A LIST of the trigger
# prefix first deletes and writes the trigger keys (a reaper landing inside
# a head recovery).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_objectstore import (
    CasManifestStore,
    CoalescePolicy,
    ListResult,
    LogStart,
    ManifestHead,
    ObjectMeta,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    WritePrecondition,
    chunk_key,
    decode_chunk_body,
    encode_chunk,
    encode_head,
    encode_log_start,
    head_key,
    log_start_key,
    tombstone_key,
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
    make_shard_id,
    shard_manifest_prefix,
)
from komira_search_catalog.generation import (
    generation_bumps_key,
    generation_floor_key,
    read_log_start_seq,
    record_retired_shard,
)


comptime _Inner = SharedInMemoryConditionalStore
comptime _RULES = "__fault__/"
comptime _L: String = "index/logs/meta"
comptime _DENIED = "StoreError[PERMISSION_DENIED] status=403 AccessDenied"
comptime _UNAVAILABLE = "StoreError[UNAVAILABLE] status=503 SlowDown"
comptime _PRECOND = "StoreError[PRECONDITION_FAILED] status=412"
comptime _TORN = "torn manifest lineage"


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


def _meta(store: _FaultStore, lineage: String) raises -> SearchMetastore[_FaultStore]:
    var manifest = CasManifestStore[_FaultStore](
        store.clone(), lineage.copy(), RetryPolicy.fast_test()
    )
    return SearchMetastore[_FaultStore](manifest^, String("logs"))


def _plain(inner: _Inner) -> _FaultStore:
    return _FaultStore(inner.clone())


def _exists(inner: _Inner, key: String) -> Bool:
    try:
        _ = inner.head(Path.parse(key))
        return True
    except:
        return False


def _stub(record_count: Int64) -> List[UInt8]:
    var b = List[UInt8]()
    b.append(UInt8(0))
    return encode_chunk(b, record_count)


def _error_of_publish(
    mut meta: SearchMetastore[_FaultStore], seed: Int
) -> String:
    try:
        _ = meta.publish(_summary(seed))
    except e:
        return String(e)
    return String("")


# =============================================================================
# 1-3. Torn recoveries and failed listings.
# =============================================================================


def _three_chunks_without_head(inner: _Inner) raises:
    """Chunks 0..2 of `_L`, chunk 0 already a reaped stub, and no `_HEAD`
    object, so the next cold handle recovers the head by LIST."""
    var w = _meta(_plain(inner), _L)
    for i in range(3):
        _ = w.publish(_summary(i))
    _ = inner.put(chunk_key(_L, Int64(0)), _stub(Int64(2)))
    inner.delete(head_key(_L))


def test_publish_retries_a_torn_recovery_while_the_log_start_moves() raises:
    var inner = _Inner()
    _three_chunks_without_head(inner)
    # A reaper lands inside the cold recovery: after it read the log start
    # (0) and before it reads chunk 0, the log start moves to 1 and chunk 0
    # is deleted. The recovery reports a torn lineage.
    var deletes = List[String]()
    deletes.append(chunk_key(_L, Int64(0)).raw())
    var puts = List[String]()
    puts.append(log_start_key(_L).raw())
    var bodies = List[List[UInt8]]()
    bodies.append(encode_log_start(LogStart(Int64(2), Int64(1), String(""))))
    var racing = _FaultStore(
        inner.clone(), _L + "/manifest/", deletes^, puts^, bodies^
    )
    var cold = _meta(racing, _L)
    var r = cold.publish(_summary(3))
    assert_equal(r.chunk_seq, Int64(3), "the retry lands at the true tail")
    var live = _meta(_plain(inner), _L).list_live_splits()
    assert_equal(len(live), 3, "splits 1, 2 and the new one are live")
    assert_true(_has_uuid(live, _uuid(3)), "the publish is visible")
    _ = inner^


def test_a_lineage_that_stays_torn_raises_the_torn_error() raises:
    var inner = _Inner()
    _three_chunks_without_head(inner)
    # Chunk 0 is missing at the log start (0) and nothing moves it.
    inner.delete(chunk_key(_L, Int64(0)))
    var cold = _meta(_plain(inner), _L)
    var msg = _error_of_publish(cold, 3)
    assert_true(msg.find(_TORN) >= 0, "publish: " + msg)
    assert_false(
        _exists(inner, chunk_key(_L, Int64(3)).raw()), "nothing was written"
    )
    with assert_raises(contains=_TORN):
        _ = _meta(_plain(inner), _L).list_live_splits()
    with assert_raises(contains=_TORN):
        _ = _meta(_plain(inner), _L).generation()
    _ = inner^


def test_a_failed_listing_is_not_retried_as_torn() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    var manifest_dir = _L + "/manifest/"
    _arm(inner, "list", manifest_dir, _UNAVAILABLE)
    with assert_raises(contains="UNAVAILABLE"):
        _ = _meta(_plain(inner), _L).list_live_splits()
    assert_equal(_fired(inner, "list", manifest_dir), 1, "one LIST, no retry")
    _ = inner^


def _torn_at_log_start_0(inner: _Inner) raises:
    """`_three_chunks_without_head` with chunk 0 deleted: no `_LOG_START`
    object, so the log start reads 0, and recovery finds chunk 0 missing."""
    _three_chunks_without_head(inner)
    inner.delete(chunk_key(_L, Int64(0)))


def _error_of_op(mut meta: SearchMetastore[_FaultStore], op: Int) -> String:
    try:
        if op == 0:
            _ = meta.publish(_summary(3))
        elif op == 1:
            _ = meta.list_live_splits()
        else:
            _ = meta.generation()
    except e:
        return String(e)
    return String("")


def test_a_torn_recovery_is_tried_exactly_twice_at_log_start_0() raises:
    # Each head recovery GETs chunk 0 once and finds it missing. A rule that
    # lets the first `skip` GETs through and fails the next one with
    # UNAVAILABLE counts the recoveries: with skip 1 the second recovery
    # meets it, so there was a retry although the log start (0) never
    # moved; with skip 2 nothing meets it, so there was no third try.
    var chunk0 = chunk_key(_L, Int64(0)).raw()
    var names = List[String]()
    names.append("publish")
    names.append("list_live_splits")
    names.append("generation")
    for op in range(3):
        var inner = _Inner()
        _torn_at_log_start_0(inner)
        _arm(inner, "get", chunk0, _UNAVAILABLE, skip=1, count=1)
        var cold = _meta(_plain(inner), _L)
        var msg = _error_of_op(cold, op)
        assert_true(
            msg.find("UNAVAILABLE") >= 0,
            names[op] + ": the second recovery reads chunk 0: " + msg,
        )
        assert_equal(_fired(inner, "get", chunk0), 1, names[op])
        _ = inner^
        var inner2 = _Inner()
        _torn_at_log_start_0(inner2)
        _arm(inner2, "get", chunk0, _UNAVAILABLE, skip=2, count=1)
        var cold2 = _meta(_plain(inner2), _L)
        var msg2 = _error_of_op(cold2, op)
        assert_true(msg2.find(_TORN) >= 0, names[op] + ": " + msg2)
        assert_equal(
            _fired(inner2, "get", chunk0), 0, names[op] + ": no third try"
        )
        _ = inner2^


# =============================================================================
# 4-6. The publish retirement check.
# =============================================================================


def test_publish_past_a_stale_head_below_the_log_start_is_refused() raises:
    var inner = _Inner()
    # A `_HEAD` object at chunk 0 left behind while the log start moved to 5
    # and every chunk below it was deleted.
    _ = inner.put(
        head_key(_L), encode_head(ManifestHead(Int64(0), Int64(2), String("")))
    )
    _ = inner.put(
        log_start_key(_L),
        encode_log_start(LogStart(Int64(10), Int64(5), String(""))),
    )
    var cold = _meta(_plain(inner), _L)
    var msg = _error_of_publish(cold, 1)
    assert_true(
        msg.find("publish won chunk 1 below the log start 5") >= 0, msg
    )
    assert_true(msg.find("publish again") >= 0, msg)
    assert_equal(
        len(_meta(_plain(inner), _L).list_live_splits()),
        0,
        "the refused chunk is not visible to a reader",
    )
    _ = inner^


def test_cold_publish_into_a_fully_reaped_lineage_wins_the_log_start() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    _ = w.publish(_summary(2))
    w.retire_at(Int64(0), Int64(0))
    w.retire_at(Int64(1), Int64(0))
    inner.delete(head_key(_L))
    assert_true(w.reap_chunk(Int64(0), Int64(1000), Int64(1000)), "reap 0")
    assert_true(w.reap_chunk(Int64(1), Int64(1000), Int64(1000)), "reap 1")
    assert_equal(
        read_log_start_seq(inner, _L), Int64(2), "both chunks are reaped"
    )
    # A cold writer recovers head = log start - 1 = 1 from an empty listing
    # and wins slot 2, exactly the log start: a slot every reader replays.
    var cold = _meta(_plain(inner), _L)
    var r = cold.publish(_summary(3))
    assert_equal(r.chunk_seq, Int64(2), "the publish wins the log-start slot")
    var live = _meta(_plain(inner), _L).list_live_splits()
    assert_equal(len(live), 1, "a cold reader sees the new split only")
    assert_true(_has_uuid(live, _uuid(3)), "the publish is visible")
    _ = inner^


def test_retirement_check_steps_over_an_absent_chunk_to_a_seal() raises:
    var inner = _Inner()
    # A seal at 0, chunk 1 absent, and a `_HEAD` object naming chunk 1.
    _ = inner.put(chunk_key(_L, Int64(0)), encode_chunk(List[UInt8](), Int64(0)))
    _ = inner.put(
        head_key(_L), encode_head(ManifestHead(Int64(1), Int64(0), String("")))
    )
    var cold = _meta(_plain(inner), _L)
    var msg = _error_of_publish(cold, 1)
    assert_true(is_shard_retired(msg), "past the seal: " + msg)
    var body = decode_chunk_body(inner.get(chunk_key(_L, Int64(2))))
    assert_equal(len(body), 0, "the won chunk is rewritten into a seal")
    _ = inner^


def test_retirement_check_raises_a_store_failure() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    var below = chunk_key(_L, Int64(0)).raw()
    _arm(inner, "get", below, _DENIED)
    # A second writer's cold handle wins chunk 1 above a head it did not
    # write, so it reads chunk 0 and meets the failure.
    var cold = _meta(_plain(inner), _L)
    var msg = _error_of_publish(cold, 2)
    assert_true(msg.find("PERMISSION_DENIED") >= 0, msg)
    assert_equal(_fired(inner, "get", below), 1)
    _ = inner^


# =============================================================================
# 7. Generation records that cannot be read.
# =============================================================================


def test_generation_raises_when_a_record_cannot_be_read() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    assert_equal(w.generation(), Int64(1))
    var floor = generation_floor_key(_L).raw()
    var bumps = generation_bumps_key(_L).raw()
    _arm(inner, "get", floor, _UNAVAILABLE, count=1)
    with assert_raises(contains="UNAVAILABLE"):
        _ = w.generation()
    _arm(inner, "get", bumps, _DENIED, count=1)
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = w.generation()
    # A bumps record of an unknown version is corrupt, not zero.
    var bad = List[UInt8]()
    bad.append(UInt8(2))
    _le(bad, Int64(4))
    _ = inner.put(Path.parse(bumps), bad)
    with assert_raises(contains="unknown _GENERATION_BUMPS version"):
        _ = w.generation()
    _ = inner^


# =============================================================================
# 8-10. reap_chunk.
# =============================================================================


def test_reap_of_an_untombstoned_chunk_changes_nothing() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    _ = w.publish(_summary(2))
    var g0 = w.generation()
    assert_true(
        w.reap_chunk(Int64(0), Int64(1) << 40, Int64(0)),
        "a chunk that was never retired reports reaped",
    )
    assert_equal(w.generation(), g0, "nothing moved")
    assert_equal(len(w.list_live_splits()), 2, "both splits stay live")
    assert_false(
        _exists(inner, generation_floor_key(_L).raw()), "no floor written"
    )
    _ = inner^


def test_reap_raises_a_failed_tombstone_read() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    var g0 = w.generation()
    var tomb = tombstone_key(_L, Int64(0)).raw()
    _arm(inner, "get", tomb, _DENIED, count=1)
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = w.reap_chunk(Int64(0), Int64(1) << 40, Int64(0))
    assert_equal(w.generation(), g0, "nothing moved")
    _ = inner^


def test_reap_raises_a_failed_stub_rewrite_and_can_be_rerun() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    _ = w.publish(_summary(2))
    w.retire_at(Int64(0), Int64(0))
    var chunk0 = chunk_key(_L, Int64(0)).raw()
    _arm(inner, "put", chunk0, _UNAVAILABLE, count=1)
    with assert_raises(contains="UNAVAILABLE"):
        _ = w.reap_chunk(Int64(0), Int64(1000), Int64(1000))
    var tombs = w.tombstoned_seqs()
    assert_equal(len(tombs), 1, "the tombstone stays for the next run")
    assert_true(w.reap_chunk(Int64(0), Int64(1000), Int64(1000)), "rerun")
    assert_equal(len(w.tombstoned_seqs()), 0, "the rerun finished the reap")
    var live = w.list_live_splits()
    assert_equal(len(live), 1)
    assert_true(_has_uuid(live, _uuid(2)), "the other split stays live")
    _ = inner^


def test_reap_raises_a_failed_reread_after_a_lost_rewrite() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    _ = w.publish(_summary(2))
    w.retire_at(Int64(0), Int64(0))
    var chunk0 = chunk_key(_L, Int64(0)).raw()
    # The stub rewrite loses its If-Match; the re-read that decides whether
    # a racing reaper wrote the same stub then fails. The rewrite's own read
    # of the chunk (the first GET) goes through.
    _arm(inner, "put", chunk0, _PRECOND, count=1)
    _arm(inner, "get", chunk0, _DENIED, skip=1, count=1)
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = w.reap_chunk(Int64(0), Int64(1000), Int64(1000))
    assert_equal(_fired(inner, "get", chunk0), 1)
    assert_equal(len(w.tombstoned_seqs()), 1, "the tombstone stays")
    _ = inner^


def test_reap_without_a_head_object_advances_the_log_start() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    _ = w.publish(_summary(2))
    w.retire_at(Int64(0), Int64(0))
    inner.delete(head_key(_L))
    assert_true(w.reap_chunk(Int64(0), Int64(1000), Int64(1000)), "reaped")
    assert_equal(
        read_log_start_seq(inner, _L), Int64(1), "the log start passed 0"
    )
    assert_false(
        _exists(inner, chunk_key(_L, Int64(0)).raw()), "the stub is deleted"
    )
    var live = _meta(_plain(inner), _L).list_live_splits()
    assert_equal(len(live), 1, "a cold reader sees the other split")
    assert_true(_has_uuid(live, _uuid(2)))
    _ = inner^


def test_reap_raises_a_failed_head_object_read() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    _ = w.publish(_summary(2))
    w.retire_at(Int64(0), Int64(0))
    var head = head_key(_L).raw()
    _arm(inner, "get", head, _UNAVAILABLE)
    with assert_raises(contains="UNAVAILABLE"):
        _ = w.reap_chunk(Int64(0), Int64(1000), Int64(1000))
    assert_true(
        _exists(inner, chunk_key(_L, Int64(0)).raw()),
        "no chunk is deleted without the head bound",
    )
    assert_equal(read_log_start_seq(inner, _L), Int64(0), "no advance")
    _ = inner^


# =============================================================================
# 11. Tombstone reads.
# =============================================================================


def test_tombstone_reads() raises:
    var inner = _Inner()
    var w = _meta(_plain(inner), _L)
    _ = w.publish(_summary(1))
    _ = w.publish(_summary(2))
    _ = w.publish(_summary(3))
    w.retire_at(Int64(1), Int64(1234))
    assert_equal(w.tombstone_schedule_ts(Int64(1)), Int64(1234))
    assert_equal(
        w.tombstoned_chunk_object_key(Int64(1)),
        String("index/logs/splits/s-2.split"),
    )
    var untombed = String("")
    try:
        _ = w.tombstone_schedule_ts(Int64(0))
    except e:
        untombed = String(e)
    assert_true(is_not_found(untombed), "not tombstoned: " + untombed)
    # Reaping chunk 1 leaves it a stub (chunk 0 is live, so the log start
    # cannot pass it). A stub answers not-found, like a deleted chunk.
    assert_true(w.reap_chunk(Int64(1), Int64(3000), Int64(1000)), "reaped")
    var stub = decode_chunk_body(inner.get(chunk_key(_L, Int64(1))))
    assert_equal(len(stub), 1, "chunk 1 is a reaped stub")
    var reaped = String("")
    try:
        _ = w.tombstoned_chunk_object_key(Int64(1))
    except e:
        reaped = String(e)
    assert_true(is_not_found(reaped), "a stub: " + reaped)
    assert_true(reaped.find("chunk 1 of " + _L + " was already reaped") >= 0)
    var gone = String("")
    try:
        _ = w.tombstoned_chunk_object_key(Int64(7))
    except e:
        gone = String(e)
    assert_true(is_not_found(gone), "absent: " + gone)
    _ = inner^


# =============================================================================
# 12. The index generation counts shards the record keeps.
# =============================================================================


def test_index_generation_counts_recorded_and_vanished_shards() raises:
    var inner = _Inner()
    var store = _plain(inner)
    var a = make_shard_id(String("node"), 1)
    var w = _meta(store, shard_manifest_prefix(_L, a))
    _ = w.publish(_summary(1))
    assert_equal(generation_across_shards(store, _L, String("logs")), Int64(1))
    # A recorded generation above a listed shard's live one counts instead.
    record_retired_shard(inner, _L, a, Int64(50))
    assert_equal(
        generation_across_shards(store, _L, String("logs")),
        Int64(50),
        "max(live, recorded) for a listed shard",
    )
    # A recorded shard none of whose objects remain still counts.
    record_retired_shard(inner, _L, make_shard_id(String("node"), 2), Int64(7))
    assert_equal(
        generation_across_shards(store, _L, String("logs")),
        Int64(57),
        "a vanished shard keeps its recorded value",
    )
    # A recorded value below the live one does not lower the sum.
    var b = make_shard_id(String("node"), 3)
    var wb = _meta(store, shard_manifest_prefix(_L, b))
    for i in range(4):
        _ = wb.publish(_summary(10 + i))
    record_retired_shard(inner, _L, b, Int64(2))
    assert_equal(
        generation_across_shards(store, _L, String("logs")),
        Int64(61),
        "the live value wins when it is higher",
    )
    _ = inner^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
