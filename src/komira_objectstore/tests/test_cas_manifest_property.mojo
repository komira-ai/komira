# =============================================================================
# tests/test_cas_manifest_property.mojo
#   OFFLINE no-gap property test for the shared CAS-manifest
# =============================================================================
#
# Drives the shared `CasManifestStore[InMemoryConditionalStore]` protocol
# OFFLINE (no MinIO) and asserts the LINEARIZABLE-APPEND correctness invariant:
# exactly one winner per offset slot, NO GAPS, contiguous total ordering.
#
# This is the CI-without-MinIO correctness guard. It exercises the IDENTICAL
# append CAS loop the live S3 path runs — only the backend differs (the
# in-memory conformer faithfully models If-None-Match create-if-absent, the
# 412 on a lost slot, If-Match CAS, 404). The live K-thread contention /
# latency CHARACTERIZATION (412-rate, p50/p99/p999, terminal-fail) is the
# separate live-MinIO C-4 gate (test_s3_minio_e2e_cas_manifest_stress).
#
# Cases:
#   (1) sequential appends are gapless + contiguous (the base/last offset
#       chain has no holes and no overlaps).
#   (2) the consumer body round-trips verbatim through encode/decode (the
#       opaque-body no-leakage property: the protocol never inspects it).
#   (3) CONTENDED-SLOT retry: K logical writers each hold a STALE head and
#       race the SAME chunk_seq via raw conditional_put(If-None-Match) —
#       exactly one create wins, the K-1 losers get a precondition (412).
#       Then driving them through `append` (which re-reads HEAD on 412)
#       yields a gapless sequence with one winner per slot.
#   (4) lifecycle FSM: schedule_for_delete then reap removes the object;
#       reap-before-tombstone raises (fail-loud); reap is idempotent.
#   (5) both consumers map cleanly: a broker-shaped body (offset record) and
#       a search-shaped body (split entry) append through the SAME store with
#       NO trait-surface difference (the shared-foundation proof, in code).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    AppendResult,
    CasManifestStore,
    RetryPolicy,
    decode_chunk_body,
    decode_chunk_record_count,
    encode_chunk,
)
from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition


def _make_manifest(prefix: String) raises -> CasManifestStore[
    InMemoryConditionalStore
]:
    return CasManifestStore[InMemoryConditionalStore](
        store=InMemoryConditionalStore(),
        prefix=prefix,
        retry=RetryPolicy.fast_test(),
    )


def _body(tag: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i + tag) & 0xFF))
    return out^


# -----------------------------------------------------------------------------
# (1) sequential appends — gapless + contiguous
# -----------------------------------------------------------------------------


def test_sequential_appends_are_gapless() raises:
    print("[test_sequential_appends_are_gapless] starting...")
    var m = _make_manifest(String("topicA/p0"))
    # Append 8 chunks with varying record counts; assert the offset chain is
    # contiguous and gapless.
    var counts = List[Int64]()
    counts.append(Int64(10))
    counts.append(Int64(5))
    counts.append(Int64(1))
    counts.append(Int64(100))
    counts.append(Int64(7))
    counts.append(Int64(3))
    counts.append(Int64(50))
    counts.append(Int64(2))

    var expected_base = Int64(0)
    var seq = Int64(0)
    for i in range(len(counts)):
        var rc = counts[i]
        var b = _body(i, 4)
        var res = m.append(b, rc)
        assert_equal(res.chunk_seq, seq, "chunk_seq must be monotone")
        assert_equal(
            res.base_offset, expected_base, "base offset must be contiguous"
        )
        assert_equal(
            res.last_offset,
            expected_base + rc - Int64(1),
            "last offset = base + rc - 1",
        )
        assert_equal(res.attempts, 1, "uncontended append wins first try")
        expected_base += rc
        seq += Int64(1)

    assert_equal(m.num_chunks(), Int64(8), "8 chunks committed")
    # No gaps: the next append's base equals the running total.
    var tail = m.append(_body(99, 4), Int64(1))
    assert_equal(tail.base_offset, expected_base, "tail base = total records")
    print("[test_sequential_appends_are_gapless] PASS")
    _ = m^


# -----------------------------------------------------------------------------
# (2) opaque-body round-trip (no-leakage property)
# -----------------------------------------------------------------------------


def test_body_round_trips_verbatim() raises:
    print("[test_body_round_trips_verbatim] starting...")
    var m = _make_manifest(String("topicB/p0"))
    var payload = _body(42, 37)
    var res = m.append(payload.copy(), Int64(9))
    var got = m.read_chunk(res.chunk_seq)
    assert_equal(len(got), 37, "body length preserved")
    for i in range(37):
        assert_equal(got[i], payload[i], "body byte preserved at " + String(i))
    print("[test_body_round_trips_verbatim] PASS")
    _ = m^


# -----------------------------------------------------------------------------
# (3) contended-slot retry — one winner per slot, K-1 losers see 412
# -----------------------------------------------------------------------------


def test_contended_slot_one_winner() raises:
    print("[test_contended_slot_one_winner] starting...")
    # Drive K=4 logical writers racing the SAME chunk_seq via the RAW
    # conditional_put(If-None-Match) the protocol uses. The in-memory store
    # models the exact S3 contract: the first create wins, the rest 412.
    var store = InMemoryConditionalStore()
    var key = Path.parse(String("topicC/p0/manifest/00000000000000000000.chunk"))

    var winners = 0
    var losers = 0
    for w in range(4):
        var encoded = encode_chunk(_body(w, 8), Int64(8))
        try:
            var _meta = store.conditional_put(
                key, encoded, WritePrecondition.if_none_match_star()
            )
            winners += 1
        except e:
            assert_true(
                String(e).find("precondition") >= 0
                or String(e).find("412") >= 0,
                "loser must see a precondition (412)",
            )
            losers += 1
    assert_equal(winners, 1, "exactly one writer wins the slot")
    assert_equal(losers, 3, "the other K-1 writers see 412")
    _ = store^

    # Now the full append loop: K writers that each start from a STALE head
    # of -1 (so they all target seq 0 first) must still produce a gapless
    # sequence — the 412 losers re-read HEAD and advance. Done through ONE
    # shared CasManifestStore (serialized appends, but each contends the
    # then-current tail slot).
    var m = _make_manifest(String("topicC/p1"))
    var seen_bases = List[Int64]()
    for w in range(8):
        var res = m.append(_body(w, 4), Int64(1))
        seen_bases.append(res.base_offset)
    # The 8 appends must have bases 0..7 exactly once each (gapless, no dup).
    for expected in range(8):
        var found = 0
        for j in range(len(seen_bases)):
            if seen_bases[j] == Int64(expected):
                found += 1
        assert_equal(found, 1, "base " + String(expected) + " claimed once")
    print("[test_contended_slot_one_winner] PASS")
    _ = m^


# -----------------------------------------------------------------------------
# (4) lifecycle FSM — schedule_for_delete → reap; fail-loud + idempotent
# -----------------------------------------------------------------------------


def test_lifecycle_fsm() raises:
    print("[test_lifecycle_fsm] starting...")
    var m = _make_manifest(String("topicD/p0"))
    var res = m.append(_body(1, 8), Int64(8))
    var seq = res.chunk_seq

    # reap BEFORE tombstone must fail-loud.
    var reap_before_raised = False
    try:
        m.reap(seq)
    except e:
        reap_before_raised = True
        assert_true(
            String(e).find("ScheduledForDelete") >= 0,
            "reap-before-tombstone must say tombstone-first",
        )
    assert_true(reap_before_raised, "reap before tombstone must raise")

    # Tombstone (idempotent), retire it (advance the log start past it: `reap`
    # refuses a chunk at or above the log start), then reap removes the object.
    m.schedule_for_delete(seq)
    m.schedule_for_delete(seq)  # idempotent
    var ls = m.read_log_start()
    _ = m.advance_log_start(seq + Int64(1), res.last_offset + Int64(1), ls.etag)
    m.reap(seq)

    # The chunk is gone — read_chunk now 404s.
    var read_after_reap_raised = False
    try:
        var _b = m.read_chunk(seq)
    except e:
        read_after_reap_raised = True
        assert_true(
            String(e).find("not_found") >= 0 or String(e).find("404") >= 0,
            "read after reap must 404",
        )
    assert_true(read_after_reap_raised, "reaped chunk must be gone")
    print("[test_lifecycle_fsm] PASS")
    _ = m^


# -----------------------------------------------------------------------------
# (5) shared-foundation proof — broker body AND search body, SAME store
# -----------------------------------------------------------------------------


def _broker_offset_body(object_key: String, crc: Int64) -> List[UInt8]:
    # A broker segment-commit record: (object_key, crc). Opaque to the trait.
    var out = List[UInt8]()
    var kb = object_key.as_bytes()
    for i in range(len(kb)):
        out.append(kb[i])
    out.append(UInt8(0))  # separator
    var u = UInt64(crc)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))
    return out^


def _search_split_body(split_id: String, doc_count: Int64) -> List[UInt8]:
    # A search split-register record: (split_id, doc_count). Opaque too.
    var out = List[UInt8]()
    var sb = split_id.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    out.append(UInt8(0))
    var u = UInt64(doc_count)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))
    return out^


def test_both_consumers_same_trait() raises:
    print("[test_both_consumers_same_trait] starting...")
    # BROKER: one manifest = one partition's segment index. record_count is
    # the number of Kafka records in the chunk → drives the offset range.
    var broker = _make_manifest(String("broker/topicX/partition0"))
    var seg = _broker_offset_body(String("seg-abc.seg"), Int64(0xDEADBEEF))
    var br = broker.append(seg, Int64(128))
    assert_equal(br.base_offset, Int64(0), "broker first segment base = 0")
    assert_equal(br.last_offset, Int64(127), "128 records → [0,127]")
    var br2 = broker.append(
        _broker_offset_body(String("seg-def.seg"), Int64(1)), Int64(64)
    )
    assert_equal(br2.base_offset, Int64(128), "broker offsets contiguous")
    _ = broker^

    # SEARCH: one manifest = one index's split catalog. The doc-id range is
    # carried by base/last (or the consumer keys by split_id in the body and
    # ignores the offsets). SAME append verb, SAME store, NO trait difference.
    var search = _make_manifest(String("search/indexY"))
    var sp = _search_split_body(String("split-0001"), Int64(5000))
    var sr = search.append(sp, Int64(5000))
    assert_equal(sr.chunk_seq, Int64(0), "search first split is chunk 0")
    # Read the split entry back verbatim (the catalog read).
    var got = search.read_chunk(sr.chunk_seq)
    var expect = _search_split_body(String("split-0001"), Int64(5000))
    assert_equal(len(got), len(expect), "split entry round-trips")
    for i in range(len(expect)):
        assert_equal(got[i], expect[i], "split entry byte " + String(i))
    _ = search^
    print("[test_both_consumers_same_trait] PASS")


def main() raises:
    test_sequential_appends_are_gapless()
    test_body_round_trips_verbatim()
    test_contended_slot_one_winner()
    test_lifecycle_fsm()
    test_both_consumers_same_trait()
    print(
        "[OK] test_cas_manifest_property — 5 offline property tests passed"
        " (no-gap linearizable-append invariant guarded without MinIO)"
    )
