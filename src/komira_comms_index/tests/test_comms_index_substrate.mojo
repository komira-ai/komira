# =============================================================================
# tests/test_comms_index_substrate.mojo
#   Comms-index substrate proof.
# =============================================================================
#
# The required assertions:
#   (1) APPEND -> READ_STATE: append deltas, read_state returns the correct
#       merged last-writer-wins state.
#   (2) `_HEAD` RACE-SAFETY: concurrent writers on separate worker threads
#       interleave appends to the SAME collection through the SAME shared store;
#       the delta-log stays GAPLESS + totally ordered (every chunk_seq in
#       {0..N-1} once) and the fold is consistent: exactly one wins each slot,
#       the loser re-reads + retries, no torn state.
#   (3) COMPACTION PRESERVES STATE: read_state is byte-identical before/after a
#       compact (compaction changes the storage, never the materialized state),
#       AND the live-chunk count SHRINKS (the storage-cost proof).
#   (4) MUTABLE BIT: set a flag-like value (PUT value=1) then unset it (PUT
#       value=0 at a higher seq) -> the fold resolves to the latest; a TOMBSTONE
#       removes the key; a later PUT un-removes it.
#
# The substrate stands on komira_objectstore's CasManifestStore (the
# immutable-chunks + mutable-`_HEAD` create-CAS primitive). Tests (1)/(3)/(4)
# run over the single-threaded InMemoryConditionalStore (deterministic); test
# (2) runs over the thread-safe SharedInMemoryConditionalStore, with the
# writers fanned out by `parallel_fork_join_shared` over a real multi-worker
# `PerCoreAsyncRuntime` (one chunk per writer, one OS thread per worker).
#
# Encapsulation: the substrate under test has no wildcard origins, and this
# file has none either. The only pointer use is the `SharedChunkWork` idiom of
# recovering the concrete input and payload types at the top of `process`.
# =============================================================================

from std.memory import ArcPointer, UnsafePointer
from std.testing import assert_equal, assert_true, assert_false

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.parallel_fork_join_shared import (
    parallel_fork_join_shared,
)
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.shared_chunk_work import SharedChunkWork

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.cas_manifest import RetryPolicy
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.path import Path
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_comms_index.comms_chunk_codec import (
    KeyedDelta,
    DELTA_OP_PUT,
    DELTA_OP_TOMBSTONE,
    bytes_equal,
    key_bytes,
    encode_keyed_delta,
    decode_keyed_delta,
    encode_compacted_base,
    decode_compacted_base,
)
from komira_comms_index.comms_index import CommsIndex, CommsState


# =============================================================================
# Small value-byte helpers (the test keys on Strings, like the comms servers).
# =============================================================================


def _val(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _val_str(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


# =============================================================================
# §0 — codec round-trip (the body codecs the read-fold + compaction stand on)
# =============================================================================


def test_codec_round_trip() raises:
    print("[comms-index] §0 codec round-trip")
    # KeyedDelta PUT round-trip.
    var d = KeyedDelta.put(Int64(7), key_bytes("uid:42"), _val("\\Seen"))
    var enc = encode_keyed_delta(d)
    var back = decode_keyed_delta(enc)
    assert_equal(back.op, DELTA_OP_PUT)
    assert_equal(Int(back.seq), 7)
    assert_true(bytes_equal(back.key, key_bytes("uid:42")))
    assert_equal(_val_str(back.value), String("\\Seen"))

    # TOMBSTONE round-trip (empty value).
    var t = KeyedDelta.tombstone(Int64(9), key_bytes("uid:42"))
    var tback = decode_keyed_delta(encode_keyed_delta(t))
    assert_equal(tback.op, DELTA_OP_TOMBSTONE)
    assert_true(tback.is_tombstone())
    assert_equal(len(tback.value), 0)

    # Compacted-base round-trip (a survivor directory).
    var survivors = List[KeyedDelta]()
    survivors.append(KeyedDelta.put(Int64(1), key_bytes("a"), _val("A")))
    survivors.append(KeyedDelta.put(Int64(2), key_bytes("bb"), _val("BB")))
    var base_enc = encode_compacted_base(survivors)
    var base_back = decode_compacted_base(base_enc)
    assert_equal(len(base_back), 2)
    assert_true(bytes_equal(base_back[0].key, key_bytes("a")))
    assert_equal(_val_str(base_back[1].value), String("BB"))
    print("  PASS codec round-trip")


# =============================================================================
# §1 — APPEND -> READ_STATE: merged last-writer-wins state
# =============================================================================


def test_append_read_state() raises:
    print("[comms-index] §1 append -> read_state")
    var idx = CommsIndex[InMemoryConditionalStore](
        InMemoryConditionalStore(), String("mail/inbox/_idx")
    )
    # Three distinct keys, each PUT once.
    _ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("uid:1"), _val("v1")))
    _ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("uid:2"), _val("v2")))
    _ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("uid:3"), _val("v3")))

    var st = idx.read_state()
    assert_equal(st.len(), 3)
    assert_true(st.contains(key_bytes("uid:1")))
    assert_true(st.contains(key_bytes("uid:2")))
    assert_true(st.contains(key_bytes("uid:3")))
    assert_equal(_val_str(st.value_for(key_bytes("uid:1"))), String("v1"))
    assert_equal(_val_str(st.value_for(key_bytes("uid:2"))), String("v2"))
    assert_equal(_val_str(st.value_for(key_bytes("uid:3"))), String("v3"))

    # head_seq is the durable sync-token watermark (3 appends -> seq 0,1,2).
    assert_equal(Int(idx.head_seq()), 2)
    # A new key after the watermark.
    var s4 = idx.put_delta(
        KeyedDelta.put(Int64(0), key_bytes("uid:4"), _val("v4"))
    )
    assert_equal(Int(s4), 3)
    var st2 = idx.read_state()
    assert_equal(st2.len(), 4)
    print("  PASS append -> read_state (4 keys, watermark advances)")


# =============================================================================
# §4 — MUTABLE BIT: set/unset a flag-like value + tombstone/un-tombstone
# =============================================================================


def test_mutable_bit_fold() raises:
    print("[comms-index] §4 mutable bit fold")
    var idx = CommsIndex[InMemoryConditionalStore](
        InMemoryConditionalStore(), String("mail/inbox/_flags")
    )
    var uid = key_bytes("uid:100")

    # SET the flag (value = "1") at seq 0.
    _ = idx.put_delta(KeyedDelta.put(Int64(0), uid.copy(), _val("1")))
    var s1 = idx.read_state()
    assert_equal(s1.len(), 1)
    assert_equal(_val_str(s1.value_for(uid.copy())), String("1"))

    # UNSET the flag (value = "0") at a HIGHER seq -> the later write wins.
    _ = idx.put_delta(KeyedDelta.put(Int64(1), uid.copy(), _val("0")))
    var s2 = idx.read_state()
    assert_equal(s2.len(), 1)
    assert_equal(
        _val_str(s2.value_for(uid.copy())),
        String("0"),
        msg="later PUT (higher seq) must win the LWW fold",
    )

    # An OUT-OF-ORDER older delta (lower seq) must NOT clobber the newer value.
    _ = idx.put_delta(KeyedDelta.put(Int64(0), uid.copy(), _val("STALE")))
    var s3 = idx.read_state()
    assert_equal(
        _val_str(s3.value_for(uid.copy())),
        String("0"),
        msg="an older-seq delta read later must not win",
    )

    # TOMBSTONE the key at a higher seq -> removed from the live state.
    _ = idx.put_delta(KeyedDelta.tombstone(Int64(2), uid.copy()))
    var s4 = idx.read_state()
    assert_false(
        s4.contains(uid.copy()), msg="tombstone at the winning seq removes key"
    )
    assert_equal(s4.len(), 0)

    # A later PUT (higher seq) UN-removes it (a re-delivery / re-add).
    _ = idx.put_delta(KeyedDelta.put(Int64(3), uid.copy(), _val("BACK")))
    var s5 = idx.read_state()
    assert_true(s5.contains(uid.copy()))
    assert_equal(_val_str(s5.value_for(uid.copy())), String("BACK"))
    print("  PASS mutable bit (set/unset/stale-ignore/tombstone/un-tombstone)")


# =============================================================================
# §3 — COMPACTION PRESERVES STATE (read_state identical; chunk count shrinks)
# =============================================================================


def _state_signature(st: CommsState) raises -> String:
    # A deterministic signature of the merged state (sorted by key bytes) so we
    # can assert byte-identical state across a compact regardless of fold order.
    var n = st.len()
    var order = List[Int]()
    for i in range(n):
        order.append(i)
    # insertion sort by key bytes lexicographically
    for i in range(1, n):
        var v = order[i]
        var j = i - 1
        while j >= 0 and _key_gt(st.keys[order[j]], st.keys[v]):
            order[j + 1] = order[j]
            j -= 1
        order[j + 1] = v
    var sig = String("")
    for i in range(n):
        var k = order[i]
        sig += _val_str(st.keys[k]) + "=" + _val_str(st.values[k]) + ";"
    return sig^


def _key_gt(a: List[UInt8], b: List[UInt8]) -> Bool:
    var na = len(a)
    var nb = len(b)
    var m = na if na < nb else nb
    for i in range(m):
        if a[i] != b[i]:
            return a[i] > b[i]
    return na > nb


def test_compaction_preserves_state() raises:
    print("[comms-index] §3 compaction preserves state")
    var idx = CommsIndex[InMemoryConditionalStore](
        InMemoryConditionalStore(), String("caldav/cal/_idx")
    )
    # Build a tail with overwrites + a tombstone (so compaction must GC).
    _ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("ev:1"), _val("e1")))
    _ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("ev:2"), _val("e2")))
    _ = idx.put_delta(KeyedDelta.put(Int64(1), key_bytes("ev:1"), _val("e1b")))
    _ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("ev:3"), _val("e3")))
    _ = idx.put_delta(KeyedDelta.tombstone(Int64(1), key_bytes("ev:3")))
    # Live state: ev:1=e1b, ev:2=e2 (ev:3 tombstoned). 5 chunks live.

    var before = idx.read_state()
    var sig_before = _state_signature(before)
    assert_equal(sig_before, String("ev:1=e1b;ev:2=e2;"))
    assert_equal(Int(idx.num_live_chunks()), 5)

    # COMPACT — fold the tail into one base, advance _LOG_START, reap deltas.
    var base_seq = idx.compact()
    assert_true(Int(base_seq) >= 5, msg="base appended above the folded tail")

    var after = idx.read_state()
    var sig_after = _state_signature(after)
    assert_equal(
        sig_after,
        sig_before,
        msg="read_state must be IDENTICAL before/after compact",
    )

    # The storage-cost proof: the live-chunk count SHRANK to just the base.
    assert_equal(
        Int(idx.num_live_chunks()),
        1,
        msg="after compact only the base chunk is live",
    )
    assert_equal(Int(idx.log_start_seq()), Int(base_seq))

    # A delta appended AFTER the base (higher seq) still wins over the base.
    _ = idx.put_delta(KeyedDelta.put(Int64(2), key_bytes("ev:1"), _val("e1c")))
    var after2 = idx.read_state()
    assert_equal(_val_str(after2.value_for(key_bytes("ev:1"))), String("e1c"))
    assert_equal(after2.len(), 2)

    # A SECOND compact is still correct + idempotent on state.
    _ = idx.compact()
    var after3 = idx.read_state()
    assert_equal(
        _state_signature(after3),
        String("ev:1=e1c;ev:2=e2;"),
        msg="second compact preserves state",
    )
    print("  PASS compaction preserves state + shrinks chunk count")


# =============================================================================
# §3b — COMPACTWINDOW ENVELOPE CONFORMANCE 
# =============================================================================
# After CommsIndex.compact() routes through the shared `compact_once` driver
# (komira_objectstore.compact_window), these are the two deterministic
# envelope behaviors the driver supplies that the comms conformer now inherits:
#   * the PLAN no-op early-exit (lo > hi): a compact with an empty tail folds /
#     materializes / advances / reaps NOTHING and returns the current head
#     (CompactSummary.noop -> compact() returns the conformer's planned_head).
#   * the WON path: a non-empty tail folds into ONE base above the tail, advances
#     `_LOG_START`, and reaps the subsumed deltas (the K2 floor-clamped loop) —
#     the live-chunk count collapses to the single base.
# These are single-threaded + deterministic (the K1 watermark-CAS-loser-no-op +
# the K2 partial-materialize crash clamp are exhaustively covered at the
# primitive level by komira_objectstore/tests/test_compact_window.mojo; this asserts
# the comms ADOPTION drives the envelope's observable outcomes correctly).


def test_compaction_window_envelope_conformance() raises:
    print("[comms-index] §3b CompactWindow envelope conformance")
    var idx = CommsIndex[InMemoryConditionalStore](
        InMemoryConditionalStore(), String("chat/room7/_log")
    )

    # ---- (a) NO-OP early-exit on an empty tail: compact returns the head and
    #          appends NO base (the PLAN step's lo > hi early-exit). On a fresh
    #          empty log head == -1; the no-op returns it unchanged.
    var empty_head = idx.head_seq()
    assert_equal(Int(empty_head), -1, msg="fresh log head is -1")
    var noop_ret = idx.compact()
    assert_equal(
        Int(noop_ret),
        Int(empty_head),
        msg="no-op compact returns the (unchanged) head, no base appended",
    )
    assert_equal(
        Int(idx.head_seq()), -1, msg="no-op compact appended NO base chunk"
    )
    assert_equal(Int(idx.num_live_chunks()), 0)

    # ---- (b) WON path: a non-empty tail folds into ONE base above the tail,
    #          advances `_LOG_START`, reaps the subsumed deltas.
    _ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("m:1"), _val("hi")))
    _ = idx.put_delta(KeyedDelta.put(Int64(1), key_bytes("m:2"), _val("yo")))
    _ = idx.put_delta(KeyedDelta.tombstone(Int64(2), key_bytes("m:1")))
    # Live state: m:2=yo (m:1 tombstoned). 3 chunks live (seq 0,1,2).
    assert_equal(Int(idx.num_live_chunks()), 3)
    var head_before = idx.head_seq()

    var base_seq = idx.compact()
    # The WON return is the base chunk_seq, appended ABOVE the folded tail.
    assert_true(
        Int(base_seq) > Int(head_before),
        msg="WON compact appends the base above the folded tail",
    )
    # `_LOG_START` advanced to the base; the live-chunk count collapsed to the
    # single base (the deltas [0..2] were reaped — the K2 clamped loop).
    assert_equal(Int(idx.log_start_seq()), Int(base_seq))
    assert_equal(
        Int(idx.num_live_chunks()),
        1,
        msg="WON compact reaps the subsumed deltas; only the base is live",
    )
    # The observable state is preserved through the envelope (m:1 GC'd).
    var st = idx.read_state()
    assert_equal(st.len(), 1)
    assert_equal(_val_str(st.value_for(key_bytes("m:2"))), String("yo"))
    assert_false(st.contains(key_bytes("m:1")), msg="tombstoned key GC'd by base")

    # ---- (c) a SECOND compact on the now-single-base log RE-FOLDS the lone base
    #          into a fresh base (the watermark sits AT the base seq, so the
    #          plan range [base..base] is non-empty — head.chunk_seq == start_seq,
    #          NOT a no-op; this is the prior inline behavior, byte-preserved by
    #          the conformer). The live count stays 1 and the state is unchanged —
    #          the substrate's idempotent-on-state contract.
    var base_after_first = idx.head_seq()
    var second = idx.compact()
    assert_true(
        Int(second) > Int(base_after_first),
        msg="re-compact of the lone base appends a fresh base above it",
    )
    assert_equal(Int(idx.log_start_seq()), Int(second))
    assert_equal(Int(idx.num_live_chunks()), 1)
    var st2 = idx.read_state()
    assert_equal(st2.len(), 1)
    assert_equal(_val_str(st2.value_for(key_bytes("m:2"))), String("yo"))
    print("  PASS CompactWindow envelope: noop early-exit + WON fold/advance/reap")


# =============================================================================
# §2 — `_HEAD` RACE-SAFETY (concurrent writers, gapless + consistent)
# =============================================================================


@fieldwise_init
struct _AppendLog(Copyable, Movable, Deinitable):
    var seqs: List[Int64]  # the chunk_seqs this writer won
    var failed: Int64


struct _RaceInput(Deinitable):
    """Read-only, shared by every writer: the one shared store, the lineage
    prefix and the appends each writer issues."""

    var store: SharedInMemoryConditionalStore
    var prefix: String
    var num_appends: Int64

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var prefix: String,
        num_appends: Int64,
    ):
        self.store = store^
        self.prefix = prefix^
        self.num_appends = num_appends


struct _RaceResults(Movable, Deinitable):
    """The mutable shared payload: `logs[w]` is writer `w`'s result slot."""

    var logs: List[_AppendLog]

    def __init__(out self, var logs: List[_AppendLog]):
        self.logs = logs^


struct _RaceWriter(SharedChunkWork):
    """Chunk `c` is writer `c`: it appends `num_appends` deltas to the shared
    collection and records the chunk_seqs it won in `logs[c]`.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: writer `c` writes only `logs[c]`, indexed by `chunk_id`.
        The writers share the store on purpose: that sharing IS the race under
        test, and `SharedInMemoryConditionalStore` is the thread-safe store.
      * No-realloc: `logs` is pre-sized to one slot per writer before the
        dispatch; a writer only appends to its own slot's `seqs`.
      * Liveness: `parallel_fork_join_shared` is a synchronous fork-join
        barrier, so the input and payload outlive every writer.
    """

    def __init__(out self):
        pass

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut payload: P,
    ) raises:
        # SAFETY: the call site below instantiates the driver with
        # In=_RaceInput and P=_RaceResults; the bitcasts recover those concrete
        # types. Neither pointer escapes this function.
        var ip = UnsafePointer(to=input).bitcast[_RaceInput]()
        var pp = UnsafePointer(to=payload).bitcast[_RaceResults]()
        # Each writer builds its OWN CommsIndex over a SHARED store handle (Arc
        # to one map) + the SAME prefix, so all writers contend on one
        # delta-log.
        var idx = CommsIndex[SharedInMemoryConditionalStore](
            ip[].store.clone(),
            ip[].prefix.copy(),
            RetryPolicy.fast_test(),
        )
        var i = Int64(0)
        while i < ip[].num_appends:
            var k = key_bytes(
                String("w") + String(chunk_id) + String(":") + String(i)
            )
            var d = KeyedDelta.put(i, k^, _val("x"))
            try:
                var seq = idx.put_delta(d)
                pp[].logs[chunk_id].seqs.append(seq)
            except e:
                pp[].logs[chunk_id].failed += Int64(1)
                _ = e
            i += Int64(1)


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_head_swap_race_safety() raises:
    print("[comms-index] §2 _HEAD swap race-safety (4 concurrent writers)")
    comptime APPENDS_PER_WRITER = Int64(40)
    comptime k = 4

    var shared = SharedInMemoryConditionalStore()
    var prefix = String("chat/room42/_log")

    var logs = List[_AppendLog]()
    for _w in range(k):
        logs.append(_AppendLog(List[Int64](), Int64(0)))

    # A REAL k-worker runtime: a serial entry, or a one-worker runtime, would
    # order the writers and prove nothing about the `_HEAD` compare-swap race.
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(k, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    var ct = CancellationToken.new()
    ref disp = rt.dispatcher()
    var disp_ptr = Pointer(to=disp)

    var input = _RaceInput(shared.clone(), prefix.copy(), APPENDS_PER_WRITER)
    var results = parallel_fork_join_shared[
        _RaceWriter,
        _RaceInput,
        _RaceResults,
        origin_of(input),
        origin_of(disp),
    ](
        _RaceWriter(),
        input,
        _RaceResults(logs^),
        k,
        disp_ptr,
        ct.clone(),
    )
    rt.shutdown()

    # ---- Assertion A: NO writer terminally failed (the livelock bound).
    var total_won = 0
    var won_seqs = List[Int64]()
    var w = 0
    while w < k:
        ref log = results.logs[w]
        assert_equal(
            Int(log.failed),
            0,
            msg="writer "
            + String(w)
            + " terminally failed an append (livelock / torn CAS)",
        )
        for i in range(len(log.seqs)):
            won_seqs.append(log.seqs[i])
            total_won += 1
        w += 1

    var expected = Int(APPENDS_PER_WRITER) * k
    assert_equal(
        total_won, expected, msg="every append must win exactly one slot"
    )

    # ---- Assertion B: the union of won chunk_seqs is EXACTLY {0..N-1}, each
    #      ONCE. Gapless + no duplicate slot => exactly one create-winner per
    #      slot K (the linearizable-append invariant; no torn state).
    _sort_i64(won_seqs)
    for i in range(len(won_seqs)):
        assert_equal(
            Int(won_seqs[i]),
            i,
            msg="chunk_seqs must be gapless {0..N-1}, each won once (slot "
            + String(i)
            + ")",
        )

    # ---- Assertion C: a post-join read_state sees ALL N appends, consistent
    #      (the loser re-read + retried; no chunk was lost or torn).
    var reader = CommsIndex[SharedInMemoryConditionalStore](
        shared.clone(), prefix.copy()
    )
    assert_equal(Int(reader.head_seq()), expected - 1)
    var st = reader.read_state()
    assert_equal(
        st.len(),
        expected,
        msg="read_state must materialize every distinct key the writers wrote",
    )
    print(
        "  PASS _HEAD race-safe: "
        + String(expected)
        + " appends, gapless {0.."
        + String(expected - 1)
        + "}, zero torn/lost"
    )


def _sort_i64(mut xs: List[Int64]):
    var n = len(xs)
    var i = 1
    while i < n:
        var key = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > key:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = key
        i += 1


# =============================================================================
# §5 — compact() watermark OVER-ADVANCES, SKIPS a
#       concurrent-append delta that lands DURING the fold.
# =============================================================================
# The DATA-LOSS shape: `_CommsCompactionSource.advance_watermark` advances
# `_LOG_START` to `product.output` (== the BASE chunk_seq). Under a concurrent
# `put_delta` that lands DURING the fold (after PLAN reads HEAD, before the base
# create-CAS wins), the base append 412s on the now-taken slot and re-anchors
# ONE SLOT HIGHER, so `base_seq > range.hi + 1`. Advancing `_LOG_START` to
# `base_seq` then SKIPS the concurrent deltas in `[range.hi + 1, base_seq - 1]`
# at the next read — silent data loss. The FIX advances to
# `product.covered.hi + Int64(1)` (the first un-folded slot), so `read_state`
# MERGE-folds the concurrent delta correctly (a base is NOT a reset; survivors
# keep their per-key seq, so a delta in the skipped band still merges).
#
# DETERMINISTIC injection (NO threads): a test-only `ConditionalWriteStore`
# wrapper forwards every verb to a shared inner store, but the FIRST time the
# manifest tries to CREATE a BASE chunk (the compaction's `append`), it FIRST
# performs a REAL concurrent `put_delta` (a genuine append via the production
# path) into that exact next slot through a sibling handle on the SAME inner
# store. The base's create-CAS then 412s on the taken slot; `append` re-anchors
# forward and lands the base one slot higher — forcing
# `base_seq == range.hi + 2`, with the concurrent delta sitting at `range.hi + 1`
# (precisely the slot the buggy watermark over-advance would skip).


comptime _CHUNK_KIND_BASE_TAG: UInt8 = 1  # mirrors comms_index.CHUNK_KIND_BASE


struct _InjectCell(Movable, Deinitable):
    """Shared interior-mutable injection state for the watermark store hook (reached
    through `ArcPointer`, so the wrapper's borrowed-`self` verbs can flip it —
    the same Arc interior-mutability pattern `SharedInMemoryConditionalStore`
    uses). Holds a CLONE of the inner store (for the sibling-handle concurrent
    append) + the lineage prefix + the one-shot `done` latch + the injected
    key (so the test can assert the skipped-band key survives the fold)."""

    var inner: SharedInMemoryConditionalStore
    var prefix: String
    var done: Bool
    var injected_key: List[UInt8]

    def __init__(
        out self, var inner: SharedInMemoryConditionalStore, var prefix: String
    ):
        self.inner = inner^
        self.prefix = prefix^
        self.done = False
        self.injected_key = List[UInt8]()


struct _ConcurrentAppendInjectStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """Test-only `ConditionalWriteStore` that wraps a `SharedInMemoryConditional
    Store` and, on the FIRST base-chunk create, injects a REAL concurrent
    `put_delta` into that slot through a sibling handle BEFORE forwarding the
    base write (which then 412s + re-anchors). Every other verb forwards
    verbatim. ZERO wildcard origins / UnsafePointer in any signature — the
    shared latch rides an `ArcPointer[_InjectCell]` (interior mutability)."""

    var _inner: SharedInMemoryConditionalStore
    var _cell: ArcPointer[_InjectCell]

    def __init__(out self, var inner: SharedInMemoryConditionalStore, var prefix: String):
        self._inner = inner.clone()
        self._cell = ArcPointer[_InjectCell](
            _InjectCell(inner^, prefix^)
        )

    @always_inline
    def injected_key(self) -> List[UInt8]:
        return self._cell[].injected_key.copy()

    # ---- ObjectStore base surface (forward verbatim) ----
    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface ----
    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        # Hook: a BASE-chunk CREATE on a `.chunk` key, exactly once. The chunk
        # envelope is [record_count_i64][body_len_i64][TAGGED_BODY...]; the
        # tagged body's first byte (offset 16) is the CHUNK_KIND tag. A base
        # chunk's tag is CHUNK_KIND_BASE (1).
        if (
            not self._cell[].done
            and precond.is_create()
            and _ends_with(path.raw(), ".chunk")
            and len(bytes) > 16
            and bytes[16] == _CHUNK_KIND_BASE_TAG
        ):
            self._cell[].done = True
            # REAL concurrent append via a sibling handle on the SAME inner
            # store (the production put_delta path): lands at the next free slot
            # == the slot this base is about to try == range.hi + 1.
            var ik = key_bytes("CONCURRENT:mid-fold")
            self._cell[].injected_key = ik.copy()
            var sib = CommsIndex[SharedInMemoryConditionalStore](
                self._cell[].inner.clone(),
                self._cell[].prefix.copy(),
                RetryPolicy.fast_test(),
            )
            _ = sib.put_delta(
                KeyedDelta.put(Int64(99), ik^, _val("CONC"))
            )
        # Forward the (possibly now-conflicting) write to the inner store.
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
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


@always_inline
def _ends_with(s: String, suffix: String) -> Bool:
    var sb = s.as_bytes()
    var fb = suffix.as_bytes()
    if len(sb) < len(fb):
        return False
    var off = len(sb) - len(fb)
    for i in range(len(fb)):
        if sb[off + i] != fb[i]:
            return False
    return True


def test_compact_watermark_skips_concurrent_append() raises:
    print("[comms-index] §5 compact watermark skips concurrent append")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("mail/inbox/_idx")
    var hook = _ConcurrentAppendInjectStore(shared.clone(), prefix.copy())
    var idx = CommsIndex[_ConcurrentAppendInjectStore](
        hook^, prefix.copy(), RetryPolicy.fast_test()
    )

    # Build a small delta tail (slots 0..1) to fold.
    _ = idx.put_delta(KeyedDelta.put(Int64(0), key_bytes("a"), _val("A")))
    _ = idx.put_delta(KeyedDelta.put(Int64(1), key_bytes("b"), _val("B")))
    # PLAN will read HEAD == 1 (range = [0, 1], range.hi == 1).
    var head_before = idx.head_seq()
    assert_equal(Int(head_before), 1, msg="tail is slots 0,1 before compact")

    # COMPACT — the hook injects a REAL concurrent put_delta at slot 2 (range.hi
    # + 1) the instant the base create is attempted, so the base 412s + re-
    # anchors and lands at slot 3 (base_seq == range.hi + 2).
    var base_seq = idx.compact()
    assert_true(
        Int(base_seq) >= 3,
        msg="base re-anchored ABOVE the concurrent delta (base_seq > range.hi+1)",
    )

    # The concurrent delta sits at slot range.hi + 1 == 2, BELOW the base.
    # ── DEFECT: the watermark over-advanced to base_seq (== output), so log_start
    #         == base_seq and read_state SKIPS slot 2's concurrent key.
    # ── FIX: the watermark advances to product.covered.hi + 1 == range.hi + 1
    #         == 2, so read_state MERGE-folds slot 2's concurrent key.
    assert_equal(
        Int(idx.log_start_seq()),
        2,
        msg=(
            "log_start must advance to covered.hi+1 (the first un-folded slot),"
            " NOT base_seq — else the concurrent delta is skipped"
        ),
    )

    var st = idx.read_state()
    var ckey = key_bytes("CONCURRENT:mid-fold")
    assert_true(
        st.contains(ckey),
        msg=(
            "read_state MUST contain the concurrent-append key that landed"
            " mid-fold; absence is the data loss"
        ),
    )
    assert_equal(
        _val_str(st.value_for(ckey)),
        String("CONC"),
        msg="the concurrent key's exact value must survive the compact",
    )
    # The folded base survivors are still present (a + b), so the live state is
    # the EXACT union {a, b, CONCURRENT} — assert the precise signature.
    assert_equal(
        _state_signature(st),
        String("CONCURRENT:mid-fold=CONC;a=A;b=B;"),
        msg="exact merged state = base survivors UNION the concurrent delta",
    )
    print("  PASS compact watermark: concurrent mid-fold delta is NOT skipped by compact")


# =============================================================================
# §6 — a FRESH reader trusts the STALE-LOW deferred
#       `_HEAD` and UNDERCOUNTS.
# =============================================================================
# The DATA-LOSS shape: warm appends DEFER the durable `_HEAD` PUT; the catch-up
# cadence (`_HEAD_ADVANCE_DEFER_CADENCE == 64`) never fires for a short run
# (5 < 64), so the durable `_HEAD` object stays stuck at the FIRST (cold) append
# while the true tail is the 5th. A SEPARATE fresh reader handle (cold cache)
# calling `read_head()` GETs the stale-low durable `_HEAD` and TRUSTS it (its
# only LIST-recovery escape fires when `_HEAD` is ABSENT, never stale-low). The
# FIX routes the comms CORRECTNESS reads (`read_state` / `head_seq` /
# `num_live_chunks` / `read_deltas_since` / `plan_range`) through
# `read_head_fresh()` — warm = 0-RPC, cold = authoritative LIST (the true tail).
#
# DETERMINISTIC (NO threads): one writer instance does 5 warm appends; a SECOND
# fresh CommsIndex over the SAME shared store reads back.


def test_fresh_reader_sees_deferred_tail() raises:
    print("[comms-index] §6 fresh reader sees the deferred-_HEAD tail")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("chat/room99/_log")

    # Single writer instance: append 1 (cold -> durable _HEAD advances to 0),
    # then appends 2..5 WARM (deferred; 5 < cadence 64, never persisted). The
    # durable _HEAD object is stuck at chunk_seq 0 while the true tail is 4.
    var w = CommsIndex[SharedInMemoryConditionalStore](
        shared.clone(), prefix.copy(), RetryPolicy.fast_test()
    )
    _ = w.put_delta(KeyedDelta.put(Int64(0), key_bytes("k:0"), _val("v0")))
    _ = w.put_delta(KeyedDelta.put(Int64(1), key_bytes("k:1"), _val("v1")))
    _ = w.put_delta(KeyedDelta.put(Int64(2), key_bytes("k:2"), _val("v2")))
    _ = w.put_delta(KeyedDelta.put(Int64(3), key_bytes("k:3"), _val("v3")))
    _ = w.put_delta(KeyedDelta.put(Int64(4), key_bytes("k:4"), _val("v4")))

    # A SEPARATE fresh reader handle (cold cache) over the SAME store.
    # ── DEFECT: read_head() GETs the stale-low durable _HEAD (chunk_seq 0) and
    #         trusts it -> head_seq()==0, read_state() sees only k:0.
    # ── FIX: read_head_fresh() goes authoritative (LIST) on the cold cache ->
    #         head_seq()==4, read_state() sees all 5 keys.
    var r = CommsIndex[SharedInMemoryConditionalStore](
        shared.clone(), prefix.copy()
    )
    assert_equal(
        Int(r.head_seq()),
        4,
        msg=(
            "a fresh reader must see the TRUE tail (4), NOT the stale-low"
            " deferred durable _HEAD (0) — undercount is the data loss"
        ),
    )

    var st = r.read_state()
    assert_equal(
        st.len(),
        5,
        msg="read_state must materialize all 5 committed deltas, not just k:0",
    )
    for i in range(5):
        var k = key_bytes(String("k:") + String(i))
        assert_true(
            st.contains(k),
            msg="fresh reader missing key k:" + String(i) + " (deferred tail)",
        )
        assert_equal(
            _val_str(st.value_for(k)),
            String("v") + String(i),
            msg="fresh reader wrong value for k:" + String(i),
        )

    # num_live_chunks also reads HEAD -> must reflect the true tail (5 chunks).
    assert_equal(
        Int(r.num_live_chunks()),
        5,
        msg="num_live_chunks must count the true tail (head - log_start + 1)",
    )
    print("  PASS fresh reader: fresh reader sees the full deferred-_HEAD tail")


# =============================================================================
# main
# =============================================================================


def main() raises:
    print("=== comms-index substrate proof ===")
    test_codec_round_trip()
    test_append_read_state()
    test_mutable_bit_fold()
    test_compaction_preserves_state()
    test_compaction_window_envelope_conformance()
    test_head_swap_race_safety()
    test_compact_watermark_skips_concurrent_append()
    test_fresh_reader_sees_deferred_tail()
    print("=== ALL comms-index substrate assertions PASS ===")
