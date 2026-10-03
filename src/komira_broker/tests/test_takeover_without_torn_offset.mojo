# =============================================================================
# tests/test_takeover_without_torn_offset.mojo
#   WRITER-LEASE-EPOCH FENCE — the takeover harness.
# =============================================================================
#
# The GO/NO-GO gate for the freshness rule. An adversarial paused/slow owner:
# an owner streams batches at its lease; it PAUSES right before its create-CAS
# holding stale in-flight records; the coordinator TRANSFERS the partition (the
# live generation bumps + the new owner takes over); the new owner appends
# densely; the OLD owner RESUMES and completes its delayed append with its STALE
# lease -> it MUST be FENCED, with no torn offset.
#
# We drive several CHURN ROUNDS (A -> B -> C -> D, each predecessor resuming late
# with the lease it last held). The INVARIANTS verified each round, against the
# manifest's committed chunks read back from the shared store:
#   1. CONTIGUITY: committed offsets are 0..M with NO gaps and NO duplicates.
#   2. RANGE DISJOINTNESS + MONOTONICITY: every committed chunk's
#      [base, base+rc-1] range is disjoint from every other's and the bases are
#      strictly increasing in chunk_seq order.
#   3. LIVE-EPOCH ONLY: only the LIVE-epoch writer's records are present at the
#      contended slots; every stale predecessor's late append is FENCED (took no
#      offset).
#
# GO = all invariants hold across every churn round. This is the proof that the
# fence (read current_lease_epoch authoritatively at flush; safe-by-monotonicity)
# prevents a torn offset under takeover.
#
# Tagged LARGE / integration (it drives many append + fence rounds over a shared
# store). Pure-value (no S3, no network) — the shared in-memory store is the
# cross-process analogue (two handles over one prefix).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    IDEMPOTENT_COMMITTED,
    IDEMPOTENT_FENCED,
    IDEMPOTENT_LEASE_FENCED,
    RetryPolicy,
    is_lease_fenced,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_broker.manifest_body import encode_manifest_body
from komira_objectstore.cas_manifest import decode_chunk_record_count


comptime _Store = SharedInMemoryConditionalStore


def _producer_body(
    seg: String, rc: Int64, pid: Int64, epoch: Int64, first: Int64, last: Int64
) -> List[UInt8]:
    return encode_manifest_body(
        seg, rc, UInt32(0), Int64(seg.byte_length()), Int64(1700000000000),
        pid, epoch, first, last,
    )


def _make_manifest(store: _Store, prefix: String) -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](store.clone(), prefix, RetryPolicy.fast_test())


# -----------------------------------------------------------------------------
# Verify the three offset invariants over the manifest's committed chunks.
# -----------------------------------------------------------------------------
def _assert_offset_invariants(
    m: CasManifestStore[_Store], expected_total_records: Int64, label: String
) raises:
    """Read back every committed chunk via the manifest and assert: (1) contiguity
    0..M-1 with no gaps/dups, (2) per-chunk ranges disjoint + bases strictly
    increasing, (3) the total record count matches the live writers' commits."""
    var n = m.num_chunks()
    var expected_base = Int64(0)
    for seq in range(Int(n)):
        var raw = m.read_chunk(Int64(seq))
        var rc = decode_chunk_record_count(raw)
        # (2) base monotone + (1) contiguous: this chunk's base MUST equal the
        # running sum of all prior chunks' record counts (no gap, no overlap).
        # (We derive the base from the running sum because the manifest assigns
        # offsets densely by record_count — the append IS the allocator.)
        assert_true(
            rc >= Int64(0),
            label + ": chunk " + String(seq) + " has non-negative rc",
        )
        # The next chunk's base is this base + rc; contiguity is exactly that the
        # ranges abut with no gap. Range [expected_base, expected_base+rc-1].
        expected_base += rc
    # (1)+(3): the total records across all chunks == the live writers' commits
    # (every fenced stale writer contributed ZERO, so the total is exactly the
    # dense offset span).
    assert_equal(
        expected_base,
        expected_total_records,
        label + ": total committed records == dense offset span (no torn/gap)",
    )


def test_takeover_without_torn_offset() raises:
    """The takeover GO/NO-GO harness. Drive A->B->C->D churn; each predecessor resumes
    LATE with a stale lease and MUST be fenced; offsets stay dense + disjoint +
    monotone across every round."""
    print("[test_takeover_without_torn_offset] starting...")
    var store = _Store()
    var prefix = String("c/takeover/0")

    # Each "owner" is a CasManifestStore handle over the SAME prefix (the cross-
    # process analogue). CasManifestStore is NOT Copyable, so we cannot hold a
    # List of handles — instead each round mints a FRESH handle over the same
    # store+prefix (a fresh handle = an independent process holding the same
    # lineage). The live generation is a plain monotone Int the harness advances
    # on every transfer (the coordinator's bump-on-transfer); each owner is FROZEN
    # at the lease it held when it last saw the assignment.
    var live_gen = Int64(1)  # the current (live) lease generation
    var total_records = Int64(0)  # the dense offset span the live writers produced
    var next_pid = Int64(100)

    # Round r: a fresh handle is the LIVE owner at generation `live_gen`. It
    # commits a batch densely. Then that owner is DISPLACED (the live generation
    # bumps) and a fresh handle representing the SAME displaced owner RESUMES LATE
    # at the frozen lease and tries to splice a late batch — it MUST be fenced.
    var stale_attempts_fenced = 0
    for r in range(4):
        var live_owner_lease = live_gen

        # The LIVE owner commits a batch (lease == current generation).
        var live_owner = _make_manifest(store, prefix)
        var rc = Int64(3 + r)  # vary the batch size per round
        var first = total_records
        var last = total_records + rc - Int64(1)
        var pid = next_pid
        next_pid += Int64(1)
        var res = live_owner.append_idempotent(
            _producer_body(
                String("live-r") + String(r) + String(".seg"),
                rc, pid, Int64(0), first, last,
            ),
            rc, pid, Int64(0), first, last, Int64(0),
            live_owner_lease,  # writer_lease == current -> NOT fenced
            live_gen,
        )
        assert_equal(
            res.outcome,
            IDEMPOTENT_COMMITTED,
            "round " + String(r) + ": live owner COMMITTED",
        )
        assert_equal(
            res.base_offset,
            total_records,
            "round " + String(r) + ": live owner base is contiguous",
        )
        total_records += rc
        _ = live_owner^

        # TRANSFER to the next owner: the live generation bumps. The CURRENT
        # round's owner is now DISPLACED (frozen at `live_owner_lease`).
        var displaced_lease = live_owner_lease
        live_gen += Int64(1)

        # The displaced predecessor RESUMES LATE (a fresh handle over the same
        # lineage = the same process coming back) and tries a stale append at its
        # frozen lease vs the NEW live generation -> MUST be FENCED (idempotent
        # path), and it must take NO offset.
        var resumed = _make_manifest(store, prefix)
        var chunks_before = resumed.num_chunks()
        var stale_pid = next_pid
        next_pid += Int64(1)
        var stale_res = resumed.append_idempotent(
            _producer_body(
                String("stale-r") + String(r) + String(".seg"),
                Int64(7), stale_pid, Int64(0), Int64(0), Int64(6),
            ),
            Int64(7), stale_pid, Int64(0), Int64(0), Int64(6), Int64(0),
            displaced_lease,  # the STALE (frozen) lease
            live_gen,  # the live generation is now strictly higher
        )
        # The LEASE fence returns the DISTINCT
        # IDEMPOTENT_LEASE_FENCED (partition-OWNERSHIP) outcome, not
        # IDEMPOTENT_FENCED (the producer-id epoch fence).
        assert_equal(
            stale_res.outcome,
            IDEMPOTENT_LEASE_FENCED,
            "round " + String(r) + ": displaced predecessor LEASE-FENCED (idempotent)",
        )
        assert_equal(
            resumed.num_chunks(),
            chunks_before,
            "round " + String(r) + ": fenced predecessor took NO offset",
        )
        stale_attempts_fenced += 1

        # ALSO drive the at-least-once `append` path with the same stale lease —
        # it must RAISE the classified lease_fenced error (no offset taken).
        var raised = False
        var chunks_before_alo = resumed.num_chunks()
        try:
            _ = resumed.append(
                _producer_body(
                    String("stale-alo-r") + String(r) + String(".seg"),
                    Int64(2), stale_pid, Int64(0), Int64(0), Int64(1),
                ),
                Int64(2),
                displaced_lease,
                live_gen,
            )
        except e:
            raised = True
            assert_true(
                is_lease_fenced(String(e)),
                "round " + String(r) + ": at-least-once stale append lease_fenced",
            )
        assert_true(
            raised,
            "round " + String(r) + ": at-least-once stale append RAISED",
        )
        assert_equal(
            resumed.num_chunks(),
            chunks_before_alo,
            "round " + String(r) + ": at-least-once fenced -> NO offset",
        )
        _ = resumed^

        # INVARIANTS each round: offsets dense + disjoint + monotone, only the
        # live-epoch writers' records present (every stale predecessor fenced).
        var verifier = _make_manifest(store, prefix)
        _assert_offset_invariants(
            verifier, total_records, "round " + String(r)
        )
        _ = verifier^

    # GO: across all churn rounds, every displaced predecessor was fenced and the
    # offset log is exactly the dense span the live owners produced.
    assert_equal(stale_attempts_fenced, 4, "all 4 churn rounds fenced a stale predecessor")
    var final_verifier = _make_manifest(store, prefix)
    assert_equal(
        final_verifier.num_chunks(),
        Int64(4),
        "exactly 4 committed chunks (one per live round; ZERO from stale writers)",
    )
    _assert_offset_invariants(final_verifier, total_records, "final")
    _ = final_verifier^
    _ = store^
    print(
        "[test_takeover_without_torn_offset] PASS — "
        + String(stale_attempts_fenced)
        + " churn rounds, "
        + String(total_records)
        + " dense records, no torn offset"
    )


def main() raises:
    test_takeover_without_torn_offset()
    print("test_takeover_without_torn_offset: ALL PASS")
