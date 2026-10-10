# =============================================================================
# tests/test_cov_cas_faults.mojo
#   CasManifestStore under a backend that fails: the error arms of the head
#   reads, the LIST escalation, the `_HEAD` advance and the marker listings.
# =============================================================================
#
# `_FaultStore` wraps a SharedInMemoryConditionalStore and fires scripted
# faults on a verb + key substring: RAISE (fail without touching the map),
# STEAL (another writer takes the slot first, so the put 412s) and a stray
# listing entry. The rules are shared through an ArcPointer so a test can
# script the store after the manifest owns it.
#
# What each case catches:
#   * a non-404 store error on a head / log-start read that is swallowed as
#     "absent" (the manifest then renumbers over live state) instead of
#     raised;
#   * the LIST escalation: re-anchoring on the wrong tail (empty manifest,
#     seed below the log start, seed at the top, a hole in the gap), a
#     transport error in the gap swallowed;
#   * the `_HEAD` advance: a backwards write, an advance that raises out of
#     an acknowledged append, a fast-path conflict that is not retried;
#   * a stray listing key read as a chunk or a tombstone.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_backoff_probe import (
    cas_backoff_counts,
    reset_cas_backoff_counts,
)
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    LogStart,
    ManifestHead,
    RetryPolicy,
    chunk_key,
    decode_head,
    encode_chunk,
    encode_head,
    encode_log_start,
    head_key,
    log_start_key,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# ---- the fault-injecting backend ------------------------------------------

comptime V_PUT = 0
comptime V_GET = 1
comptime V_HEAD = 2
comptime V_LIST = 3
comptime V_DELETE = 4

comptime M_RAISE = 0
comptime M_STEAL = 1


@fieldwise_init
struct _Rule(Copyable, Movable):
    var verb: Int
    var key_sub: String
    var mode: Int
    var msg: String
    var skip: Int
    var times: Int


struct _Rules(Movable):
    var rules: List[_Rule]
    var fired: Int
    var stray: List[String]
    var stray_cp: List[String]

    def __init__(out self):
        self.rules = List[_Rule]()
        self.fired = 0
        self.stray = List[String]()
        self.stray_cp = List[String]()


struct _FaultStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    var inner: SharedInMemoryConditionalStore
    var rules: ArcPointer[_Rules]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var rules: ArcPointer[_Rules],
    ):
        self.inner = inner^
        self.rules = rules^

    def _match(self, verb: Int, key: String) -> Int:
        """The index of the rule that fires for this call, or -1."""
        ref r = self.rules[]
        for i in range(len(r.rules)):
            ref rule = r.rules[i]
            if rule.verb != verb or rule.times == 0:
                continue
            if key.find(rule.key_sub) < 0:
                continue
            if rule.skip > 0:
                rule.skip -= 1
                return -1
            if rule.times > 0:
                rule.times -= 1
            r.fired += 1
            return i
        return -1

    def _raise_if(self, verb: Int, key: String) raises:
        var i = self._match(verb, key)
        if i >= 0:
            raise Error(self.rules[].rules[i].msg + " key=" + key)

    def head(self, path: Path) raises -> ObjectMeta:
        self._raise_if(V_HEAD, path.raw())
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
        var i = self._match(V_PUT, path.raw())
        if i >= 0:
            if self.rules[].rules[i].mode == M_STEAL:
                var other = List[UInt8]()
                other.append(UInt8(0x5A))
                _ = self.inner.put(path, encode_chunk(other, Int64(1)))
            else:
                raise Error(self.rules[].rules[i].msg + " key=" + path.raw())
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
        self._raise_if(V_GET, path.raw())
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._raise_if(V_GET, path.raw())
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._raise_if(V_DELETE, path.raw())
        self.inner.delete(path)


comptime TRANSPORT = "StoreError[TRANSPORT] connection reset status=503"
comptime FAKE_412 = "precondition (412) injected"


def _rule(verb: Int, key_sub: String, msg: String, times: Int = 1, skip: Int = 0) -> _Rule:
    return _Rule(verb, key_sub, M_RAISE, msg, skip, times)


struct _Fixture(Movable):
    var shared: SharedInMemoryConditionalStore
    var rules: ArcPointer[_Rules]
    var m: CasManifestStore[_FaultStore]

    def __init__(out self, prefix: String, retry: RetryPolicy = RetryPolicy.fast_test()):
        self.shared = SharedInMemoryConditionalStore()
        self.rules = ArcPointer[_Rules](_Rules())
        self.m = CasManifestStore[_FaultStore](
            store=_FaultStore(self.shared.clone(), self.rules.copy()),
            prefix=prefix,
            retry=retry,
        )

    def add(mut self, var r: _Rule):
        self.rules[].rules.append(r^)

    def clear(mut self):
        self.rules[].rules = List[_Rule]()
        self.rules[].stray = List[String]()
        self.rules[].stray_cp = List[String]()

    def fired(self) -> Int:
        return self.rules[].fired

    def fresh(self) -> CasManifestStore[_FaultStore]:
        """A second, cold handle over the same backend and rules."""
        return CasManifestStore[_FaultStore](
            store=_FaultStore(self.shared.clone(), self.rules.copy()),
            prefix=self.m.prefix(),
            retry=RetryPolicy.fast_test(),
        )


def _body(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8(i & 0xFF))
    return out^


def _err_of_append(mut m: CasManifestStore[_FaultStore]) -> String:
    try:
        _ = m.append(_body(4), Int64(2))
        return String("")
    except e:
        return String(e)


# ---- head reads raise a non-404 error ---------------------------------------


def test_head_reads_raise_transport() raises:
    var f = _Fixture(String("t/hr"))
    _ = f.m.append(_body(4), Int64(2))
    var cold = f.fresh()
    # read_head (cold cache) GETs `_HEAD`: a 503 is raised, never "absent".
    f.add(_rule(V_GET, String("_HEAD"), String(TRANSPORT)))
    var e1 = String("")
    try:
        _ = cold.read_head()
    except e:
        e1 = String(e)
    assert_true(e1.find("status=503") >= 0, e1)
    # read_durable_head: the same GET, the same refusal.
    f.add(_rule(V_GET, String("_HEAD"), String(TRANSPORT)))
    var e2 = String("")
    try:
        _ = cold.read_durable_head()
    except e:
        e2 = String(e)
    assert_true(e2.find("status=503") >= 0, e2)
    # The gate was released on both raises: the next read succeeds.
    assert_equal(cold.read_head().chunk_seq, Int64(0))
    # The LIST recovery reads `_LOG_START`: a 503 there is raised too.
    f.add(_rule(V_GET, String("_LOG_START"), String(TRANSPORT)))
    var e3 = String("")
    try:
        _ = cold.read_head_authoritative()
    except e:
        e3 = String(e)
    assert_true(e3.find("status=503") >= 0, e3)
    # A HEAD failure on the top chunk only loses the advisory etag.
    f.add(_rule(V_HEAD, String("/manifest/"), String(TRANSPORT)))
    var h = cold.read_head_authoritative()
    assert_equal(h.chunk_seq, Int64(0))
    assert_equal(h.next_offset, Int64(2))
    assert_equal(h.etag_of_last_chunk, String(""))
    assert_equal(f.fired(), 4)


def test_recovery_clamps_negative_log_start() raises:
    var f = _Fixture(String("t/neg"))
    _ = f.m.append(_body(4), Int64(3))
    _ = f.m.append(_body(4), Int64(5))
    # A `_LOG_START` body holding a negative seq is read as "from 0 at 0",
    # never as a negative slot or a non-zero offset.
    _ = f.shared.put(
        log_start_key(String("t/neg")),
        encode_log_start(LogStart(Int64(77), Int64(-4), String(""))),
    )
    var h = f.fresh().read_head_authoritative()
    assert_equal(h.chunk_seq, Int64(1))
    assert_equal(h.next_offset, Int64(8))


# ---- the LIST escalation --------------------------------------------------


def test_escalation_on_empty_manifest() raises:
    # (The escalation counter, `enable_escalation_metrics`, is not exercised:
    # its MetricsSet factory writes into uninitialized memory, komira-ai/komira#1072.)
    var f = _Fixture(String("t/esc0"))
    # Three 412s with no chunk written: the escalation finds an empty
    # manifest and re-anchors at slot 0, where the 4th attempt wins.
    f.add(_rule(V_PUT, String("/manifest/"), String(FAKE_412), times=3))
    var r = f.m.append(_body(4), Int64(2))
    assert_equal(r.chunk_seq, Int64(0))
    assert_equal(r.base_offset, Int64(0))
    assert_equal(r.attempts, 4)


def test_escalation_after_real_steals() raises:
    var f = _Fixture(String("t/steal"))
    # Another writer takes slots 0, 1 and 2 (1 record each) just before us.
    f.rules[].rules.append(
        _Rule(V_PUT, String("/manifest/"), M_STEAL, String(""), 0, 3)
    )
    var r = f.m.append(_body(4), Int64(2))
    assert_equal(r.chunk_seq, Int64(3))
    assert_equal(r.base_offset, Int64(3))
    assert_equal(r.last_offset, Int64(4))
    assert_equal(r.attempts, 4)


def test_escalation_seed_at_top() raises:
    var f = _Fixture(String("t/top"))
    _ = f.m.append(_body(4), Int64(2))
    _ = f.m.append(_body(4), Int64(2))
    # The writer deferred its second `_HEAD` advance; put `_HEAD` at the top.
    _ = f.shared.put(
        head_key(String("t/top")),
        encode_head(ManifestHead(Int64(1), Int64(4), String(""))),
    )
    var cold = f.fresh()
    # `_HEAD` is at the true top; three fake 412s: the escalation keeps the
    # seed (nothing to replay) and the 4th attempt takes slot 2 at offset 4.
    f.add(_rule(V_PUT, String("/manifest/"), String(FAKE_412), times=3))
    var r = cold.append(_body(4), Int64(1))
    assert_equal(r.chunk_seq, Int64(2))
    assert_equal(r.base_offset, Int64(4))


def test_escalation_seed_below_log_start() raises:
    var f = _Fixture(String("t/below"))
    for _ in range(5):
        _ = f.m.append(_body(4), Int64(2))
    # Retention moved the log start to slot 3 (offset 6) and reaped 0..2; a
    # stale `_HEAD` still says slot 0.
    _ = f.m.advance_log_start(Int64(3), Int64(6), String(""))
    for s in range(3):
        f.shared.delete(chunk_key(String("t/below"), Int64(s)))
    _ = f.shared.put(
        head_key(String("t/below")),
        encode_head(ManifestHead(Int64(0), Int64(2), String(""))),
    )
    var cold = f.fresh()
    f.add(_rule(V_PUT, String("/manifest/"), String(FAKE_412), times=3))
    # The escalation sees the seed below the log start and recovers from the
    # LIST: the next slot is 5 at offset 6 + 2 * 2 = 10.
    var r = cold.append(_body(4), Int64(1))
    assert_equal(r.chunk_seq, Int64(5))
    assert_equal(r.base_offset, Int64(10))


def test_escalation_hole_in_gap_fails_loud() raises:
    var f = _Fixture(String("t/hole"))
    for _ in range(4):
        _ = f.m.append(_body(4), Int64(1))
    _ = f.shared.put(
        head_key(String("t/hole")),
        encode_head(ManifestHead(Int64(0), Int64(1), String(""))),
    )
    f.shared.delete(chunk_key(String("t/hole"), Int64(2)))
    var cold = f.fresh()
    f.add(_rule(V_PUT, String("/manifest/"), String(FAKE_412), times=3))
    # A hole above the seed is a torn lineage: refuse, never renumber.
    var msg = _err_of_append(cold)
    assert_true(msg.find("MISSING committed chunk at seq 2") >= 0, msg)


def test_escalation_gap_read_transport() raises:
    var f = _Fixture(String("t/gap"))
    for _ in range(3):
        _ = f.m.append(_body(4), Int64(1))
    _ = f.shared.put(
        head_key(String("t/gap")),
        encode_head(ManifestHead(Int64(0), Int64(1), String(""))),
    )
    var cold = f.fresh()
    f.add(_rule(V_PUT, String("/manifest/"), String(FAKE_412), times=3))
    # 412 at slot 1 (the probe finds chunk 1), 412 at slot 2 (the probe reads
    # chunk 2 as absent, so the head falls back to the stale `_HEAD`), 412 at
    # slot 1: the escalation replays from slot 1 and its read of chunk 2 hits
    # a 503, which is raised, not read as a hole.
    f.add(_rule(V_GET, String("00000000000000000002.chunk"), String("not_found (404) injected"), times=1))
    f.add(_rule(V_GET, String("00000000000000000002.chunk"), String(TRANSPORT), times=1))
    var msg = _err_of_append(cold)
    assert_true(msg.find("status=503") >= 0, msg)


def test_escalation_top_etag_miss_tolerated() raises:
    var f = _Fixture(String("t/etag"))
    for _ in range(3):
        _ = f.m.append(_body(4), Int64(1))
    _ = f.shared.put(
        head_key(String("t/etag")),
        encode_head(ManifestHead(Int64(0), Int64(1), String(""))),
    )
    var cold = f.fresh()
    f.add(_rule(V_PUT, String("/manifest/"), String(FAKE_412), times=3))
    # As above, the probe of slot 2 reads it as absent so the escalation
    # replays the gap; then the HEAD for the top chunk's etag fails: advisory,
    # the append lands.
    f.add(_rule(V_GET, String("00000000000000000002.chunk"), String("not_found (404) injected"), times=1))
    f.add(_rule(V_HEAD, String("00000000000000000002.chunk"), String(TRANSPORT), times=1))
    var r = cold.append(_body(4), Int64(1))
    assert_equal(r.chunk_seq, Int64(3))
    assert_equal(r.base_offset, Int64(3))


def test_probe_transport_is_raised() raises:
    var f = _Fixture(String("t/probe"))
    _ = f.m.append(_body(4), Int64(1))
    var cold = f.fresh()
    # One fake 412 at slot 1, then the probe of slot 1 hits a 503.
    f.add(_rule(V_PUT, String("/manifest/"), String(FAKE_412), times=1))
    f.add(_rule(V_GET, String("00000000000000000001.chunk"), String(TRANSPORT), times=1))
    var msg = _err_of_append(cold)
    assert_true(msg.find("status=503") >= 0, msg)


def test_zero_backoff_is_counted() raises:
    reset_cas_backoff_counts()
    var f = _Fixture(String("t/zero"), RetryPolicy(Int64(0), Int64(0), 4))
    f.add(_rule(V_PUT, String("/manifest/"), String(FAKE_412), times=2))
    var r = f.m.append(_body(4), Int64(1))
    assert_equal(r.attempts, 3)
    var c = cas_backoff_counts()
    # Two backoffs, each under a 0 bound, neither drawn nor slept.
    assert_equal(c.draws(), 2)
    assert_equal(c.upper_sum_at[0], 0)
    assert_equal(c.drawn_us, 0)
    assert_equal(c.slept_us, 0)
    assert_equal(c.draws_over_upper, 0)
    reset_cas_backoff_counts()


# ---- the `_HEAD` advance ------------------------------------------------------


def _durable_head_seq(f: _Fixture) raises -> Int64:
    return decode_head(f.shared.get(head_key(f.m.prefix()))).chunk_seq


def test_head_advance_never_regresses() raises:
    var f = _Fixture(String("t/adv"))
    for s in range(3):
        _ = f.m.try_append_at_seq(Int64(s), Int64(s), _body(4), Int64(1))
    assert_equal(_durable_head_seq(f), Int64(2))
    # Slot 1 freed, then re-taken at exactly slot 1: the advance (fast path:
    # it holds `_HEAD`'s etag) sees `_HEAD` already at 2 and writes nothing.
    f.shared.delete(chunk_key(String("t/adv"), Int64(1)))
    var won = f.m.try_append_at_seq(Int64(1), Int64(1), _body(4), Int64(1))
    assert_true(Bool(won))
    assert_equal(_durable_head_seq(f), Int64(2))
    # The parked-path finalize (no `_HEAD` etag: the read-recheck path) for a
    # slot below `_HEAD` writes nothing either.
    f.m.apply_async_append_win(Int64(0), Int64(0), Int64(1), String("e"))
    assert_equal(_durable_head_seq(f), Int64(2))


def test_head_advance_fast_path_faults() raises:
    var f = _Fixture(String("t/fast"))
    _ = f.m.append(_body(4), Int64(1))
    # The fast path's GET of `_HEAD` fails: the slow path still advances.
    f.add(_rule(V_GET, String("_HEAD"), String(TRANSPORT), times=1))
    _ = f.m.try_append_at_seq(Int64(1), Int64(1), _body(4), Int64(1))
    assert_equal(_durable_head_seq(f), Int64(1))
    # The fast path's If-Match PUT fails: the slow path still advances.
    f.add(_rule(V_PUT, String("_HEAD"), String(TRANSPORT), times=1))
    _ = f.m.try_append_at_seq(Int64(2), Int64(2), _body(4), Int64(1))
    assert_equal(_durable_head_seq(f), Int64(2))
    assert_equal(f.fired(), 2)


def test_head_advance_slow_path_faults() raises:
    var f = _Fixture(String("t/slow"))
    _ = f.m.append(_body(4), Int64(1))
    # A transient (non-404) read of `_HEAD`: give up, `_HEAD` unchanged, and
    # the win is not raised.
    f.add(_rule(V_GET, String("_HEAD"), String(TRANSPORT), times=1))
    f.m.apply_async_append_win(Int64(1), Int64(1), Int64(1), String("e"))
    assert_equal(_durable_head_seq(f), Int64(0))
    # A transient write error: give up after one try.
    f.add(_rule(V_PUT, String("_HEAD"), String(TRANSPORT), times=1))
    f.m.apply_async_append_win(Int64(1), Int64(1), Int64(1), String("e"))
    assert_equal(_durable_head_seq(f), Int64(0))
    assert_equal(f.fired(), 2)
    # A 412 is retried: one conflict, then the advance lands.
    f.add(_rule(V_PUT, String("_HEAD"), String(FAKE_412), times=1))
    f.m.apply_async_append_win(Int64(1), Int64(1), Int64(1), String("e"))
    assert_equal(_durable_head_seq(f), Int64(1))
    # Five conflicts exhaust the bounded retry: `_HEAD` stays, no raise.
    f.add(_rule(V_PUT, String("_HEAD"), String(FAKE_412), times=5))
    f.m.apply_async_append_win(Int64(2), Int64(2), Int64(1), String("e"))
    assert_equal(_durable_head_seq(f), Int64(1))
    assert_equal(f.fired(), 8)
    # A sixth try would have landed: the bound is exactly five.
    f.m.apply_async_append_win(Int64(2), Int64(2), Int64(1), String("e"))
    assert_equal(_durable_head_seq(f), Int64(2))


def test_head_advance_swallows_bad_key() raises:
    # A prefix `Path.parse` refuses: the advisory advance raises inside and
    # must not escape out of an acknowledged win.
    var shared = SharedInMemoryConditionalStore()
    var m = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=String("bad/../p"), retry=RetryPolicy.fast_test()
    )
    m.apply_async_append_win(Int64(0), Int64(0), Int64(1), String("e"))
    assert_equal(len(shared.list_with_delimiter(Path.parse(String(""))).objects), 0)


# ---- marker and chunk listings ------------------------------------------------


def test_listing_errors_and_strays() raises:
    var f = _Fixture(String("t/mk"))
    _ = f.m.append(_body(4), Int64(1))
    _ = f.m.append(_body(4), Int64(1))
    f.m.schedule_for_delete(Int64(0))
    # A stray key in every listing is neither a chunk nor a tombstone.
    f.rules[].stray.append(String("elsewhere/x"))
    f.rules[].stray.append(String("t/mk/manifest/notanumber.chunk"))
    var ts = f.m.tombstone_seqs()
    assert_equal(len(ts), 1)
    assert_equal(ts[0], Int64(0))
    assert_equal(len(f.m.moved_tombstone_seqs()), 0)
    assert_equal(f.fresh().read_head_authoritative().chunk_seq, Int64(1))
    f.clear()
    # LIST failures are raised (and release the gate).
    f.add(_rule(V_LIST, String("/tombstones/"), String(TRANSPORT)))
    var e1 = String("")
    try:
        _ = f.m.tombstone_seqs()
    except e:
        e1 = String(e)
    assert_true(e1.find("status=503") >= 0, e1)
    f.add(_rule(V_LIST, String("/moved_tombstones/"), String(TRANSPORT)))
    var e2 = String("")
    try:
        _ = f.m.moved_tombstone_seqs()
    except e:
        e2 = String(e)
    assert_true(e2.find("status=503") >= 0, e2)
    # A moved-marker read failing with a non-404 is raised, not "no marker".
    f.add(_rule(V_GET, String("/moved_tombstones/"), String(TRANSPORT)))
    var e3 = String("")
    try:
        _ = f.m.moved_tombstone_ts(Int64(0))
    except e:
        e3 = String(e)
    assert_true(e3.find("status=503") >= 0, e3)
    # The gate is free again: a write-locked verb runs.
    f.m.schedule_for_delete(Int64(1))
    assert_equal(len(f.m.tombstone_seqs()), 2)


def test_purge_all_sweeps_sentinels_and_raises() raises:
    var f = _Fixture(String("t/purge"))
    var trailer_body = _body(4)
    _ = f.m.append(trailer_body, Int64(1))
    # Two dedup sentinels under `_meta/dedup/` are deleted with the rest.
    _ = f.shared.put(Path.parse(String("t/purge/_meta/dedup/a/1.seq")), _body(2))
    _ = f.shared.put(Path.parse(String("t/purge/_meta/dedup/b/2.seq")), _body(2))
    # Chunk 0, `_HEAD` and the two sentinels.
    assert_equal(len(f.shared.list_with_delimiter(Path.parse(String("t/purge/"))).objects), 4)
    # Deletes counted: 1 chunk + 2 sentinels + the flat sweep's `_HEAD` + the
    # unconditional `_HEAD` and `_LOG_START` deletes.
    assert_equal(f.m.purge_all(), Int64(6))
    assert_equal(len(f.shared.list_with_delimiter(Path.parse(String("t/purge/"))).objects), 0)
    # A failing delete is raised (and releases the gate).
    _ = f.m.append(trailer_body, Int64(1))
    f.add(_rule(V_DELETE, String("/manifest/"), String(TRANSPORT)))
    var msg = String("")
    try:
        _ = f.m.purge_all()
    except e:
        msg = String(e)
    assert_true(msg.find("status=503") >= 0, msg)
    assert_equal(f.m.purge_all() >= Int64(1), True)



# ---- more read arms -------------------------------------------------------------


def test_fresh_and_schedule_reads_raise() raises:
    var f = _Fixture(String("t/fr"))
    _ = f.m.append(_body(4), Int64(1))
    f.m.schedule_for_delete_at(Int64(0), Int64(1234))
    assert_equal(f.m.tombstone_schedule_ts(Int64(0)), Int64(1234))
    # A cold read_head_fresh goes to the LIST recovery; a 503 on its
    # `_LOG_START` read is raised.
    var cold = f.fresh()
    f.add(_rule(V_GET, String("_LOG_START"), String(TRANSPORT)))
    var e1 = String("")
    try:
        _ = cold.read_head_fresh()
    except e:
        e1 = String(e)
    assert_true(e1.find("status=503") >= 0, e1)
    # A tombstone's schedule read failing is raised (and frees the gate).
    f.add(_rule(V_GET, String("t/fr/tombstones/"), String(TRANSPORT)))
    var e2 = String("")
    try:
        _ = f.m.tombstone_schedule_ts(Int64(0))
    except e:
        e2 = String(e)
    assert_true(e2.find("status=503") >= 0, e2)
    assert_equal(cold.read_head_fresh().chunk_seq, Int64(0))
    f.m.schedule_for_delete_at(Int64(0), Int64(99))
    assert_equal(f.m.tombstone_schedule_ts(Int64(0)), Int64(99))


def test_discover_shard_ids_listing_edges() raises:
    var f = _Fixture(String("t/disc"))
    # A LIST that says the prefix is absent: no shards. Any other error: raised.
    f.add(_rule(V_LIST, String("_lineage"), String("NoSuchKey: the prefix")))
    assert_equal(len(f.m.discover_shard_ids(String("idx/meta"))), 0)
    f.add(_rule(V_LIST, String("_lineage"), String(TRANSPORT)))
    var msg = String("")
    try:
        _ = f.m.discover_shard_ids(String("idx/meta"))
    except e:
        msg = String(e)
    assert_true(msg.find("status=503") >= 0, msg)
    # Malformed listing entries never become shard ids: the bare prefix, a
    # foreign key of the same length class, an empty segment, in both arms.
    _ = f.shared.put(Path.parse(String("idx/meta/_lineage/real/_HEAD")), _body(1))
    f.rules[].stray.append(String("idx/meta/_lineage/"))
    f.rules[].stray.append(String("zzz/meta/_lineage/abc/_HEAD"))
    f.rules[].stray.append(String("idx/meta/_lineage//x"))
    f.rules[].stray_cp.append(String("idx/meta/_lineage/"))
    f.rules[].stray_cp.append(String("zzz/meta/_lineage/cp/"))
    f.rules[].stray_cp.append(String("idx/meta/_lineage//"))
    f.rules[].stray_cp.append(String("idx/meta/_lineage/c1/"))
    f.rules[].stray_cp.append(String("idx/meta/_lineage/real/"))
    var ids = f.m.discover_shard_ids(String("idx/meta"))
    assert_equal(len(ids), 2)
    assert_equal(ids[0], String("real"))
    assert_equal(ids[1], String("c1"))


def main() raises:
    print("[test_cov_cas_faults] test_head_reads_raise_transport")
    test_head_reads_raise_transport()
    print("[test_cov_cas_faults] test_recovery_clamps_negative_log_start")
    test_recovery_clamps_negative_log_start()
    print("[test_cov_cas_faults] test_escalation_on_empty_manifest")
    test_escalation_on_empty_manifest()
    print("[test_cov_cas_faults] test_escalation_after_real_steals")
    test_escalation_after_real_steals()
    print("[test_cov_cas_faults] test_escalation_seed_at_top")
    test_escalation_seed_at_top()
    print("[test_cov_cas_faults] test_escalation_seed_below_log_start")
    test_escalation_seed_below_log_start()
    print("[test_cov_cas_faults] test_escalation_hole_in_gap_fails_loud")
    test_escalation_hole_in_gap_fails_loud()
    print("[test_cov_cas_faults] test_escalation_gap_read_transport")
    test_escalation_gap_read_transport()
    print("[test_cov_cas_faults] test_escalation_top_etag_miss_tolerated")
    test_escalation_top_etag_miss_tolerated()
    print("[test_cov_cas_faults] test_probe_transport_is_raised")
    test_probe_transport_is_raised()
    print("[test_cov_cas_faults] test_zero_backoff_is_counted")
    test_zero_backoff_is_counted()
    print("[test_cov_cas_faults] test_head_advance_never_regresses")
    test_head_advance_never_regresses()
    print("[test_cov_cas_faults] test_head_advance_fast_path_faults")
    test_head_advance_fast_path_faults()
    print("[test_cov_cas_faults] test_head_advance_slow_path_faults")
    test_head_advance_slow_path_faults()
    print("[test_cov_cas_faults] test_head_advance_swallows_bad_key")
    test_head_advance_swallows_bad_key()
    print("[test_cov_cas_faults] test_listing_errors_and_strays")
    test_listing_errors_and_strays()
    print("[test_cov_cas_faults] test_purge_all_sweeps_sentinels_and_raises")
    test_purge_all_sweeps_sentinels_and_raises()
    print("[test_cov_cas_faults] test_fresh_and_schedule_reads_raise")
    test_fresh_and_schedule_reads_raise()
    print("[test_cov_cas_faults] test_discover_shard_ids_listing_edges")
    test_discover_shard_ids_listing_edges()
    print("[test_cov_cas_faults] PASS")
