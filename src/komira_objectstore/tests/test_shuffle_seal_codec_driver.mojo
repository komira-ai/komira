# =============================================================================
# tests/test_shuffle_seal_codec_driver.mojo
#   Distributed-shuffle SEAL — byte codecs + the driver-join seal protocol
#   (P=4/R=4 over LocalFs).
# =============================================================================
#
# The correctness keystone (it gates ALL other shuffle code). This test pins:
#
#   CODEC round-trips:
#     * StepComplete LIFTED + TRAILER_FALLBACK (byte-identical decode).
#     * ShuffleEntry (producer_id / object_key / dense-index identical —
#       guards the shuffle-specific body codec the dedup decodes producer_id from).
#     * SegWriter -> SegReader with a deliberately-EMPTY MIDDLE partition (pid1
#       empty; pid0/2/3 non-empty): the dense trailer has EXACTLY R entries +
#       the empty slice reads zero bytes (guards the off-by-one / zero-length
#       DENSE-INDEX INVARIANT).
#
#   DRIVER protocol against CasManifestStore[LocalFsConditionalStore]:
#     * hand-append 4 ShuffleEntry chunks (producers 0-3) -> seal_step(
#       expected={0,1,2,3}) returns committed; read_seal returns the same set.
#     * Re-drive seal_step -> append_idempotent returns DUPLICATE (one logical
#       seal — exactly-once).
#     * Missing-producer: seal_step(expected={0,1,2,3}) with only 0-2 appended
# -> RAISES.
#     * Replay: append producer 2's entry TWICE under same (2, step_id) ->
# committed DEDUPS to one member of 2.
#
# Each invariant-pinning assertion notes which production line's reversion makes
# it fail.
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    IdempotentAppendResult,
    IDEMPOTENT_COMMITTED,
    IDEMPOTENT_DUPLICATE,
    RetryPolicy,
)
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path

from komira_objectstore.shuffle_codec import (
    put_i64_le,
    get_i64_le,
    put_len_prefixed_str,
    get_len_prefixed_str,
)
from komira_objectstore.shuffle_entry import (
    ShuffleEntry,
    PartitionSlot,
    encode_shuffle_entry,
    decode_shuffle_entry,
    decode_shuffle_entry_producer_id,
)
from komira_objectstore.shuffle_seal import (
    StepComplete,
    SEAL_WRITER,
    SEAL_INDEX_LIFTED,
    SEAL_INDEX_TRAILER_FALLBACK,
    encode_step_complete,
    decode_step_complete,
    sorted_unique_i64,
    i64_sets_equal,
)
from komira_objectstore.shuffle_segment import (
    SegWriter,
    SegReader,
    write_segment,
    decode_seg_trailer,
)
from komira_objectstore.shuffle_seal_driver import (
    seal_step,
    read_seal,
    entries_prefix,
)
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR (through `test_tmpdir()`), NOT A HARD-CODED `/tmp` PATH.
#
# The same test may run in more than one action at a time on one machine. A
# fixed `/tmp` path is shared by every one of those executions; the runner's
# `TEST_TMPDIR` is private to each run, which is what makes them disjoint.
# `test_tmpdir()` raises when it is unset rather than fall back to `/tmp`.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# -----------------------------------------------------------------------------
# Scratch root + byte helpers (the LocalFs harness shape).
# -----------------------------------------------------------------------------
def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (_scratch_dir() + String("/komira_shuffle_seal_")) + tag + String("_") + String(t)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _cleanup(root: String):
    try:
        var store = LocalFsConditionalStore(root.copy())
        var res = store.list_with_delimiter(Path.parse(String("")))
        for i in range(len(res.objects)):
            store.delete(Path.parse(res.objects[i].location))
        _ = store^
    except:
        pass


# =============================================================================
# CODEC — length-prefixed string round-trip is BYTE-IDENTICAL for a NON-ASCII
# object key (the byte-deterministic-seal invariant, DECISION (b)).
#
# A per-byte `chr(Int(b))` decode would map any byte 0x80-0xFF to a Unicode
# codepoint that re-encodes as a MULTI-byte UTF-8 sequence, so encode->decode->
# encode would NOT be byte-identical the moment an object key carries non-ASCII —
# silently breaking the byte-deterministic seal. This pins the DIRECT UTF-8
# byte-range decode (shuffle_codec.get_len_prefixed_str). Reverts if that decode
# regresses to a per-byte `chr()` loop.
# =============================================================================
def test_len_prefixed_str_non_ascii_byte_identical() raises:
    print("[test_len_prefixed_str_non_ascii_byte_identical] starting...")
    # An object key with a UTF-8 MULTI-byte char (e.g. an accented letter +
    # a 3-byte CJK char) — exactly the kind of key a real bucket can carry.
    var key = String("9/3/café_数据_42.seg")
    # Sanity: the key really IS non-ASCII (its UTF-8 byte length exceeds its
    # codepoint count would-be ASCII length — at least one byte is >= 0x80).
    var key_bytes = key.as_bytes()
    var has_non_ascii = False
    for i in range(len(key_bytes)):
        if key_bytes[i] >= UInt8(0x80):
            has_non_ascii = True
            break
    assert_true(has_non_ascii, "test key actually carries a non-ASCII byte")

    # encode -> decode -> re-encode.
    var wire1 = List[UInt8]()
    put_len_prefixed_str(wire1, key)
    var decoded = get_len_prefixed_str(wire1, 0)
    var decoded_str = decoded[0]
    var next_off = decoded[1]
    # the decoded String equals the original (codepoint-level equality).
    assert_equal(decoded_str, key, "decoded string == original (non-ASCII)")
    # the decoder consumed exactly the framed bytes (8-byte len prefix + body).
    assert_equal(next_off, len(wire1), "decoder consumed the full frame")

    # BYTE-IDENTICAL round-trip: re-encoding the decoded string yields the SAME
    # wire bytes (the load-bearing byte-deterministic-seal property). A per-byte
    # chr() decode would round-trip to a LONGER (multi-byte-expanded) re-encode
    # for the non-ASCII bytes, failing this.
    var wire2 = List[UInt8]()
    put_len_prefixed_str(wire2, decoded_str)
    assert_equal(len(wire2), len(wire1), "re-encode byte length identical")
    for i in range(len(wire1)):
        assert_equal(
            wire2[i],
            wire1[i],
            "re-encode byte[" + String(i) + "] identical (non-ASCII)",
        )
    print("[test_len_prefixed_str_non_ascii_byte_identical] PASS")


# =============================================================================
# CODEC — StepComplete LIFTED round-trip (byte-identical).
# =============================================================================
def test_step_complete_lifted_roundtrip() raises:
    print("[test_step_complete_lifted_roundtrip] starting...")
    var r = 3  # R partitions
    # 2 producers, dense R-triples each (incl a zero-length slot in producer 1).
    var rp_pids = List[Int64]()
    rp_pids.append(Int64(0))
    rp_pids.append(Int64(1))
    var rp_keys = List[String]()
    rp_keys.append(String("100/5/0.seg"))
    rp_keys.append(String("100/5/1.seg"))
    var rp_index = List[Int64]()
    # producer 0: p0=(0,10,3) p1=(10,20,7) p2=(30,5,1)
    rp_index.append(Int64(0)); rp_index.append(Int64(10)); rp_index.append(Int64(3))
    rp_index.append(Int64(10)); rp_index.append(Int64(20)); rp_index.append(Int64(7))
    rp_index.append(Int64(30)); rp_index.append(Int64(5)); rp_index.append(Int64(1))
    # producer 1: p0=(0,0,0 EMPTY) p1=(0,12,4) p2=(12,8,2)
    rp_index.append(Int64(0)); rp_index.append(Int64(0)); rp_index.append(Int64(0))
    rp_index.append(Int64(0)); rp_index.append(Int64(12)); rp_index.append(Int64(4))
    rp_index.append(Int64(12)); rp_index.append(Int64(8)); rp_index.append(Int64(2))

    var expected = List[Int64]()
    expected.append(Int64(0)); expected.append(Int64(1))
    var committed = List[Int64]()
    committed.append(Int64(0)); committed.append(Int64(1))

    var seal = StepComplete(
        Int64(100), Int64(5), Int64(r), SEAL_INDEX_LIFTED,
        expected^, committed^, rp_pids^, rp_keys^, rp_index^,
        Int64(0), Int64(0),
    )
    var wire = encode_step_complete(seal)
    var back = decode_step_complete(wire)

    # scalar fields round-trip (reverts if encode/decode_step_complete drift)
    assert_equal(back.shuffle_id, Int64(100), "shuffle_id rt")
    assert_equal(back.step_id, Int64(5), "step_id rt")
    assert_equal(back.partition_count, Int64(3), "partition_count rt")
    assert_true(back.index_mode == SEAL_INDEX_LIFTED, "index_mode LIFTED rt")
    # producer sets round-trip
    assert_true(i64_sets_equal(sorted_unique_i64(back.expected_producers),
                               sorted_unique_i64(seal.expected_producers)),
                "expected set rt")
    assert_true(i64_sets_equal(sorted_unique_i64(back.committed_producers),
                               sorted_unique_i64(seal.committed_producers)),
                "committed set rt")
    # dense read plan round-trips byte-for-byte (reverts if put/get_i64_list drift)
    assert_equal(len(back.read_plan_index), len(seal.read_plan_index),
                 "read_plan_index length rt")
    for i in range(len(seal.read_plan_index)):
        assert_equal(back.read_plan_index[i], seal.read_plan_index[i],
                     "read_plan_index[" + String(i) + "] rt")
    # object keys round-trip (reverts if put/get_str_list drift)
    assert_equal(len(back.read_plan_object_keys), 2, "2 object keys rt")
    assert_equal(back.read_plan_object_keys[0], String("100/5/0.seg"), "key0 rt")
    assert_equal(back.read_plan_object_keys[1], String("100/5/1.seg"), "key1 rt")
    # dense_slot accessor resolves the EMPTY producer-1/partition-0 slot
    # (reverts if StepComplete.dense_slot row-major math drifts)
    var slot10 = back.dense_slot(1, 0)
    assert_equal(slot10[0], Int64(0), "p1/part0 offset")
    assert_equal(slot10[1], Int64(0), "p1/part0 len = 0 (EMPTY)")
    assert_equal(slot10[2], Int64(0), "p1/part0 rowcount = 0 (EMPTY)")
    print("[test_step_complete_lifted_roundtrip] PASS")


# =============================================================================
# CODEC — StepComplete TRAILER_FALLBACK round-trip (empty read plan + window).
# =============================================================================
def test_step_complete_trailer_fallback_roundtrip() raises:
    print("[test_step_complete_trailer_fallback_roundtrip] starting...")
    var expected = List[Int64]()
    expected.append(Int64(0)); expected.append(Int64(1)); expected.append(Int64(2))
    var committed = List[Int64]()
    committed.append(Int64(0)); committed.append(Int64(1)); committed.append(Int64(2))
    # TRAILER_FALLBACK: read-plan lists EMPTY; floor/ceiling carry the window.
    var seal = StepComplete(
        Int64(7), Int64(2), Int64(4), SEAL_INDEX_TRAILER_FALLBACK,
        expected^, committed^,
        List[Int64](), List[String](), List[Int64](),
        Int64(3), Int64(11),
    )
    var wire = encode_step_complete(seal)
    var back = decode_step_complete(wire)
    assert_true(back.index_mode == SEAL_INDEX_TRAILER_FALLBACK,
                "TRAILER_FALLBACK mode rt")
    # empty read-plan lists survive the round-trip (reverts if put/get_*_list
    # drops the zero-length list framing)
    assert_equal(len(back.read_plan_producer_ids), 0, "empty rp_pids rt")
    assert_equal(len(back.read_plan_object_keys), 0, "empty rp_keys rt")
    assert_equal(len(back.read_plan_index), 0, "empty rp_index rt")
    # window round-trips (reverts if entries_floor/ceiling encode drift)
    assert_equal(back.entries_floor, Int64(3), "entries_floor rt")
    assert_equal(back.entries_ceiling, Int64(11), "entries_ceiling rt")
    assert_true(i64_sets_equal(sorted_unique_i64(back.committed_producers),
                               sorted_unique_i64(seal.committed_producers)),
                "committed set rt")
    print("[test_step_complete_trailer_fallback_roundtrip] PASS")


# =============================================================================
# CODEC — ShuffleEntry round-trip (guard: producer_id / key / dense idx).
# =============================================================================
def test_shuffle_entry_roundtrip() raises:
    print("[test_shuffle_entry_roundtrip] starting...")
    var slots = List[PartitionSlot]()
    slots.append(PartitionSlot(Int64(0), Int64(64), Int64(8)))
    slots.append(PartitionSlot(Int64(64), Int64(0), Int64(0)))  # EMPTY middle
    slots.append(PartitionSlot(Int64(64), Int64(32), Int64(4)))
    slots.append(PartitionSlot(Int64(96), Int64(16), Int64(2)))
    var entry = ShuffleEntry(Int64(42), String("9/3/42.seg"), slots^)
    var wire = encode_shuffle_entry(entry)
    var back = decode_shuffle_entry(wire)
    # producer_id round-trips — the dedup-source field (reverts if
    # encode/decode_shuffle_entry drift)
    assert_equal(back.producer_id, Int64(42), "producer_id rt")
    # the fast-path producer-id decoder (the driver's dedup source) agrees
    assert_equal(decode_shuffle_entry_producer_id(wire), Int64(42),
                 "decode_shuffle_entry_producer_id agrees")
    # object_key round-trips
    assert_equal(back.object_key, String("9/3/42.seg"), "object_key rt")
    # dense index round-trips EXACTLY R entries incl the empty middle (reverts
    # if PartitionSlot encode order drifts)
    assert_equal(back.partition_count(), 4, "R=4 dense entries rt")
    assert_equal(back.slots[1].length, Int64(0), "middle slot len=0 (EMPTY)")
    assert_equal(back.slots[1].row_count, Int64(0), "middle slot rc=0 (EMPTY)")
    assert_equal(back.slots[2].offset, Int64(64), "slot2 offset unchanged across empty")
    assert_equal(back.slots[3].length, Int64(16), "slot3 len rt")
    print("[test_shuffle_entry_roundtrip] PASS")


# =============================================================================
# SEG — SegWriter -> SegReader with a deliberately-EMPTY MIDDLE partition.
# =============================================================================
def test_seg_writer_reader_empty_middle_partition() raises:
    print("[test_seg_writer_reader_empty_middle_partition] starting...")
    var root = _scratch_root(String("seg"))
    var store = LocalFsConditionalStore(root.copy())

    # R=4: pid0/2/3 non-empty, pid1 EMPTY (the off-by-one / zero-length guard).
    var w = SegWriter()
    var p0 = _bytes(String("PART0-bytes"))      # 11 bytes
    var p1 = List[UInt8]()                        # EMPTY middle partition
    var p2 = _bytes(String("PARTITION-TWO"))     # 13 bytes
    var p3 = _bytes(String("p3"))                # 2 bytes
    w.append_partition(p0, Int64(3))
    w.append_partition(p1, Int64(0))            # empty -> dense slot (off,0,0)
    w.append_partition(p2, Int64(5))
    w.append_partition(p3, Int64(1))
    assert_equal(w.partition_count(), 4, "R=4 dense slots built")

    var key = Path.parse(String("9/3/0.seg"))
    var slots = write_segment(store, key, w^)
    # the producer's recorded dense index has EXACTLY R entries (reverts if
    # SegWriter.append_partition skips the empty partition's dense slot)
    assert_equal(len(slots), 4, "write_segment returns R=4 dense slots")
    assert_equal(slots[1].length, Int64(0), "slot1 len=0 (EMPTY middle)")
    # the empty partition's offset == prior running offset (UNCHANGED), and the
    # NEXT partition continues from there (reverts if running_offset advances on
    # an empty partition)
    assert_equal(slots[1].offset, Int64(11), "empty slot offset = running (11)")
    assert_equal(slots[2].offset, Int64(11), "slot2 offset continues at 11")

    # the on-disk trailer decodes to EXACTLY R dense entries
    var whole = store.get(key)
    var trailer = decode_seg_trailer(whole)
    assert_equal(len(trailer), 4, "on-disk dense trailer has EXACTLY R=4 entries")

    # SegReader: the empty slice reads ZERO bytes (the dense-index invariant —
    # reverts if SegReader.read_partition issues a range request for len==0)
    var reader = SegReader[LocalFsConditionalStore](store.clone(), key.copy())
    assert_true(_bytes_eq(reader.read_partition(0), p0), "part0 bytes")
    assert_equal(len(reader.read_partition(1)), 0, "EMPTY part1 reads zero bytes")
    assert_true(_bytes_eq(reader.read_partition(2), p2), "part2 bytes")
    assert_true(_bytes_eq(reader.read_partition(3), p3), "part3 bytes")
    _ = reader^
    _ = store^
    _cleanup(root)
    print("[test_seg_writer_reader_empty_middle_partition] PASS")


# -----------------------------------------------------------------------------
# Driver harness: hand-append a ShuffleEntry chunk to the `_entries` manifest
# (the producer's step-4 append, modeled directly so the test does not
# depend on the not-yet-built map-write path).
# -----------------------------------------------------------------------------
def _append_entry(
    mut store: LocalFsConditionalStore,
    shuffle_id: Int64,
    step_id: Int64,
    producer_id: Int64,
    object_key: String,
    r: Int,
) raises:
    # build a dense R-slot entry (deterministic content for a given producer)
    var slots = List[PartitionSlot]()
    var running = Int64(0)
    for p in range(r):
        var length = Int64((Int(producer_id) + 1) * (p + 1))  # nonzero, dense
        slots.append(PartitionSlot(running, length, length))
        running += length
    var entry = ShuffleEntry(producer_id, object_key, slots^)
    var body = encode_shuffle_entry(entry)
    var m = CasManifestStore[LocalFsConditionalStore](
        store.clone(), entries_prefix(shuffle_id, step_id), RetryPolicy.default()
    )
    _ = m.append(body, Int64(r))
    _ = m^


def _expected_set(n: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        out.append(Int64(i))
    return out^


# =============================================================================
# DRIVER — seal_step over the full producer set + read_seal agrees.
# =============================================================================
def test_seal_step_full_set_and_read() raises:
    print("[test_seal_step_full_set_and_read] starting...")
    var root = _scratch_root(String("full"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(1)
    var stp = Int64(0)
    var r = 4
    # hand-append 4 producer entries (0-3)
    for pid in range(4):
        _append_entry(store, sid, stp, Int64(pid),
                      String(sid) + "/" + String(stp) + "/" + String(pid) + ".seg", r)

    var seal = seal_step(store, sid, stp, Int64(r), _expected_set(4))
    # committed == expected as sets (reverts if _scan_entries / set-equality
    # in seal_step drift)
    assert_true(i64_sets_equal(sorted_unique_i64(seal.committed_producers),
                               _expected_set(4)),
                "seal committed == {0,1,2,3}")
    assert_true(seal.is_lifted(), "seal is LIFTED")
    # the lifted read plan carries all 4 producers, EXACTLY R dense triples each
    # (reverts if _build_lifted_seal drops a producer or a partition slot)
    assert_equal(len(seal.read_plan_producer_ids), 4, "4 producers in read plan")
    assert_equal(len(seal.read_plan_index), 4 * r * 3, "dense plan = P*R*3 i64s")

    # read_seal returns the SAME committed set (reverts if read_seal's re-verify
    # drifts or the seal-block read can't find the seal)
    var got = read_seal(store, sid, stp, _expected_set(4))
    assert_true(i64_sets_equal(sorted_unique_i64(got.committed_producers),
                               _expected_set(4)),
                "read_seal committed == {0,1,2,3}")
    _ = store^
    _cleanup(root)
    print("[test_seal_step_full_set_and_read] PASS")


# =============================================================================
# DRIVER — re-drive seal_step is idempotent (one logical seal; DUPLICATE).
# =============================================================================
def test_seal_step_redrive_idempotent() raises:
    print("[test_seal_step_redrive_idempotent] starting...")
    var root = _scratch_root(String("redrive"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(2)
    var stp = Int64(0)
    var r = 4
    for pid in range(4):
        _append_entry(store, sid, stp, Int64(pid),
                      String(sid) + "/" + String(stp) + "/" + String(pid) + ".seg", r)

    var seal1 = seal_step(store, sid, stp, Int64(r), _expected_set(4))
    assert_true(i64_sets_equal(sorted_unique_i64(seal1.committed_producers),
                               _expected_set(4)), "first seal committed set")

    # Re-drive: append_idempotent's DedupSentinel returns DUPLICATE under
    # (SEAL_WRITER, step_id) -> NO second seal chunk. The seal manifest holds
    # EXACTLY ONE chunk (reverts if the seal-write is not idempotent / not under
    # the reserved SEAL_WRITER identity — DECISION (b)).
    var seal2 = seal_step(store, sid, stp, Int64(r), _expected_set(4))
    assert_true(i64_sets_equal(sorted_unique_i64(seal2.committed_producers),
                               _expected_set(4)), "re-drive seal committed set")

    var seal_m = CasManifestStore[LocalFsConditionalStore](
        store.clone(),
        String(sid) + "/" + String(stp) + "/_seal",
        RetryPolicy.default(),
    )
    assert_equal(seal_m.num_chunks(), Int64(1),
                 "EXACTLY ONE seal chunk after re-drive (idempotent)")
    _ = seal_m^
    _ = store^
    _cleanup(root)
    print("[test_seal_step_redrive_idempotent] PASS")


# =============================================================================
# DRIVER — missing producer raises (torn map phase, NOT sealed).
# =============================================================================
def test_seal_step_missing_producer_raises() raises:
    print("[test_seal_step_missing_producer_raises] starting...")
    var root = _scratch_root(String("missing"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(3)
    var stp = Int64(0)
    var r = 4
    # only producers 0,1,2 committed — producer 3 is MISSING (torn map phase).
    for pid in range(3):
        _append_entry(store, sid, stp, Int64(pid),
                      String(sid) + "/" + String(stp) + "/" + String(pid) + ".seg", r)

    var raised = False
    try:
        var _s = seal_step(store, sid, stp, Int64(r), _expected_set(4))
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(String("torn")) >= 0 or msg.find(String("subset")) >= 0,
                    "raise message names the torn/subset condition")
    # reverts if seal_step's committed==expected set check is weakened to a count
    # (a count of 3 != 4 still raises, but the SET check is what catches a
    # replay-inflated count; this asserts the missing-producer fail-loud)
    assert_true(raised, "seal_step RAISES on a missing producer")

    # and NO seal was written (reverts if seal_step appends before verifying)
    var seal_m = CasManifestStore[LocalFsConditionalStore](
        store.clone(),
        String(sid) + "/" + String(stp) + "/_seal",
        RetryPolicy.default(),
    )
    assert_equal(seal_m.num_chunks(), Int64(0), "NO seal written on torn phase")
    _ = seal_m^
    _ = store^
    _cleanup(root)
    print("[test_seal_step_missing_producer_raises] PASS")


# =============================================================================
# DRIVER — replay dedups to one set member (EXACT-SET, EACH-ONCE).
# =============================================================================
def test_seal_step_replay_dedups() raises:
    print("[test_seal_step_replay_dedups] starting...")
    var root = _scratch_root(String("replay"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(4)
    var stp = Int64(0)
    var r = 4
    # producers 0,1,3 once; producer 2 committed TWICE (a map replay landed a
    # second _entries entry for the same producer).
    _append_entry(store, sid, stp, Int64(0),
                  String(sid) + "/" + String(stp) + "/0.seg", r)
    _append_entry(store, sid, stp, Int64(1),
                  String(sid) + "/" + String(stp) + "/1.seg", r)
    _append_entry(store, sid, stp, Int64(2),
                  String(sid) + "/" + String(stp) + "/2.seg", r)
    _append_entry(store, sid, stp, Int64(3),
                  String(sid) + "/" + String(stp) + "/3.seg", r)
    # the REPLAY: producer 2's entry again (deterministic identical content).
    _append_entry(store, sid, stp, Int64(2),
                  String(sid) + "/" + String(stp) + "/2.seg", r)

    var seal = seal_step(store, sid, stp, Int64(r), _expected_set(4))
    # committed DEDUPS to exactly {0,1,2,3} — producer 2 is ONE set member, not
    # two (reverts if _scan_entries uses a count or appends raw producer_ids
    # without sorted_unique_i64 dedup — the silent double-read hole).
    assert_true(i64_sets_equal(sorted_unique_i64(seal.committed_producers),
                               _expected_set(4)),
                "replay dedups: committed == {0,1,2,3}")
    assert_equal(len(seal.committed_producers), 4,
                 "EXACTLY 4 committed members (2 is NOT counted twice)")
    # the read plan carries producer 2 EXACTLY once (reverts if _build_lifted_seal
    # emits a duplicate plan row for the replayed producer -> double-read)
    var twos = 0
    for i in range(len(seal.read_plan_producer_ids)):
        if seal.read_plan_producer_ids[i] == Int64(2):
            twos += 1
    assert_equal(twos, 1, "producer 2 appears EXACTLY once in the read plan")
    _ = store^
    _cleanup(root)
    print("[test_seal_step_replay_dedups] PASS")


def main() raises:
    test_len_prefixed_str_non_ascii_byte_identical()
    test_step_complete_lifted_roundtrip()
    test_step_complete_trailer_fallback_roundtrip()
    test_shuffle_entry_roundtrip()
    test_seg_writer_reader_empty_middle_partition()
    test_seal_step_full_set_and_read()
    test_seal_step_redrive_idempotent()
    test_seal_step_missing_producer_raises()
    test_seal_step_replay_dedups()
    print("[test_shuffle_seal_codec_driver] all 9 tests PASS")
