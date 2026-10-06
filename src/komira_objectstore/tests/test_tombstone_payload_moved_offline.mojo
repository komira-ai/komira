# =============================================================================
# tests/test_tombstone_payload_moved_offline.mojo
#   The tombstone body and its `payload_moved` flag — OFFLINE
# =============================================================================
#
# A tombstone body is the 8-byte schedule ts, plus one flags byte when the
# chunk's payload moved to another manifest (chunk_reclaim_guard.mojo). The
# broker reaper reads the flag to keep a `.seg` that `_base` still reads.
#
#   (1) The codec. A retention tombstone encodes to exactly the 8 LE bytes
#       every tombstone had before the flag existed; a moved one appends 0x01.
#       Decoding: 8 bytes -> not moved; a zero flags byte -> not moved; any
#       nonzero flags byte -> moved (an unknown flag never causes a delete);
#       fewer than 8 bytes raises. Catches: a flag appended to retention
#       tombstones (changes the old format), a decoder that reads a 9th byte
#       of an 8-byte body, one that treats an unknown flag as "reclaim".
#   (2) The manifest verbs. `schedule_for_delete` and `schedule_for_delete_at`
#       without the flag write the old 8-byte body; with it, 9 bytes.
#       `read_tombstone` returns both fields in one GET, `tombstone_schedule_ts`
#       still returns the ts, a rewrite replaces ts and flag (last writer
#       wins), and an untombstoned chunk raises not_found. A raw 8-byte
#       marker written the old way reads as not moved. Catches: the flag
#       dropped on the way to the store, or a rewrite that keeps a stale flag.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    is_not_found,
    tombstone_key,
)
from komira_objectstore.chunk_reclaim_guard import (
    Tombstone,
    decode_tombstone_body,
    encode_tombstone_body,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore
comptime _PREFIX = "tombflag/_meta/topics/t/0"


def _le8(v: Int64) -> List[UInt8]:
    """`v` as 8 little-endian bytes, built independently of the codec."""
    var out = List[UInt8]()
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))
    return out^


def _assert_bytes(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), what + ": byte " + String(i))


def _raw(store: _Store, seq: Int64) raises -> List[UInt8]:
    return store.get(tombstone_key(String(_PREFIX), seq))


# =============================================================================
# (1) the codec
# =============================================================================


def test_codec() raises:
    print("[test_codec] starting...")
    var ts = Int64(0x0102030405060708)

    var plain = encode_tombstone_body(ts, False)
    _assert_bytes(plain, _le8(ts), "retention tombstone = the old 8 bytes")
    var moved = encode_tombstone_body(ts, True)
    var want = _le8(ts)
    want.append(UInt8(1))
    _assert_bytes(moved, want, "moved = 8 bytes + 0x01")

    var d0 = decode_tombstone_body(plain)
    assert_equal(d0.schedule_ts_ms, ts, "plain ts")
    assert_false(d0.payload_moved, "an 8-byte body is not moved")
    var d1 = decode_tombstone_body(moved)
    assert_equal(d1.schedule_ts_ms, ts, "moved ts")
    assert_true(d1.payload_moved, "flag 0x01 is moved")

    var zero_flag = _le8(Int64(-1))
    zero_flag.append(UInt8(0))
    var d2 = decode_tombstone_body(zero_flag)
    assert_equal(d2.schedule_ts_ms, Int64(-1), "a negative ts round-trips")
    assert_false(d2.payload_moved, "a zero flags byte is not moved")

    var unknown = _le8(Int64(7))
    unknown.append(UInt8(0x80))
    unknown.append(UInt8(0xFF))
    assert_true(
        decode_tombstone_body(unknown).payload_moved,
        "an unknown nonzero flag keeps the payload",
    )

    var short = _le8(Int64(7))
    _ = short.pop()
    var raised = False
    try:
        _ = decode_tombstone_body(short)
    except e:
        raised = True
        assert_true(String(e).find("truncated") >= 0, String(e))
    assert_true(raised, "a 7-byte body raises")
    print("[test_codec] PASS")


# =============================================================================
# (2) the manifest verbs
# =============================================================================


def test_manifest_verbs() raises:
    print("[test_manifest_verbs] starting...")
    var store = _Store()
    var m = CasManifestStore[_Store](
        store=store.clone(), prefix=String(_PREFIX), retry=RetryPolicy.fast_test()
    )
    for _ in range(4):
        var body = List[UInt8]()
        body.append(UInt8(9))
        _ = m.append(body^, Int64(1))

    # Without the flag: the old 8-byte body, read back as not moved.
    m.schedule_for_delete_at(Int64(0), Int64(5000))
    _assert_bytes(_raw(store, Int64(0)), _le8(Int64(5000)), "default body")
    var t0 = m.read_tombstone(Int64(0))
    assert_equal(t0.schedule_ts_ms, Int64(5000), "ts 5000")
    assert_false(t0.payload_moved, "not moved")
    assert_equal(m.tombstone_schedule_ts(Int64(0)), Int64(5000), "ts verb")

    # The clock-less verb writes the old body too.
    m.schedule_for_delete(Int64(3))
    assert_equal(len(_raw(store, Int64(3))), 8, "clock-less: 8 bytes")
    assert_false(m.read_tombstone(Int64(3)).payload_moved, "clock-less")

    # With the flag: 9 bytes, read back as moved.
    m.schedule_for_delete_at(Int64(1), Int64(6000), payload_moved=True)
    var want = _le8(Int64(6000))
    want.append(UInt8(1))
    _assert_bytes(_raw(store, Int64(1)), want, "moved body")
    var t1 = m.read_tombstone(Int64(1))
    assert_equal(t1.schedule_ts_ms, Int64(6000), "ts 6000")
    assert_true(t1.payload_moved, "moved")

    # A rewrite replaces both fields, either way.
    m.schedule_for_delete_at(Int64(0), Int64(7000), payload_moved=True)
    var t2 = m.read_tombstone(Int64(0))
    assert_equal(t2.schedule_ts_ms, Int64(7000), "re-stamped")
    assert_true(t2.payload_moved, "flag set by the rewrite")
    m.schedule_for_delete_at(Int64(0), Int64(8000))
    var t3 = m.read_tombstone(Int64(0))
    assert_equal(t3.schedule_ts_ms, Int64(8000), "re-stamped again")
    assert_false(t3.payload_moved, "flag cleared by the rewrite")

    # A marker written the old way (raw 8 bytes) reads as not moved.
    _ = store.put(tombstone_key(String(_PREFIX), Int64(2)), _le8(Int64(4000)))
    var t4 = m.read_tombstone(Int64(2))
    assert_equal(t4.schedule_ts_ms, Int64(4000), "old marker ts")
    assert_false(t4.payload_moved, "old marker: not moved")

    # An untombstoned chunk.
    var raised = False
    try:
        _ = m.read_tombstone(Int64(9))
    except e:
        raised = True
        assert_true(is_not_found(String(e)), String(e))
    assert_true(raised, "no tombstone: not_found")
    _ = m^
    _ = store^
    print("[test_manifest_verbs] PASS")


def main() raises:
    test_codec()
    test_manifest_verbs()
    print("[OK] test_tombstone_payload_moved_offline — 2 cases passed")
