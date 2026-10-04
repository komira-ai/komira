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

from std.testing import assert_equal, assert_false, assert_true

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

from komira_broker.manifest_body import ManifestBody, encode_manifest_body
from komira_objectstore.cas_manifest import decode_chunk_record_count


comptime _Store = SharedInMemoryConditionalStore


# creation_ts_ms is a placeholder nothing in this harness reads, and a sample
# timestamp in this tree must not decode to a real past date, so it is
# 4_000_000_000_000 ms (a date in 2096) rather than a recent epoch value.
def _producer_body(
    seg: String, rc: Int64, pid: Int64, epoch: Int64, first: Int64, last: Int64
) -> List[UInt8]:
    return encode_manifest_body(
        seg, rc, UInt32(0), Int64(seg.byte_length()), Int64(4_000_000_000_000),
        pid, epoch, first, last,
    )


def _make_manifest(store: _Store, prefix: String) -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](store.clone(), prefix, RetryPolicy.fast_test())


# -----------------------------------------------------------------------------
# Verify the three offset invariants over the manifest's committed chunks.
# -----------------------------------------------------------------------------
def _live_pid(round: Int) -> Int64:
    """The producer id the live owner of `round` used: the harness hands out ids
    from 100 upward, one to the live owner and one to the stale writer per
    round."""
    return Int64(100 + 2 * round)


def _assert_offset_invariants(
    m: CasManifestStore[_Store], expected_total_records: Int64, label: String
) raises:
    """Read back every committed chunk via the manifest and assert the three
    invariants of the header, each from the chunk's own bytes:

    (1) CONTIGUITY: chunk `seq`'s producer range starts where the previous one
        ended (`first_seq` == running sum, `last_seq` == base + rc - 1), and the
        authoritative head's `next_offset` is exactly the dense span.
    (2) DISJOINT + MONOTONE: chunk seqs are 0..n-1 (the head's `chunk_seq` is
        n-1) and bases strictly increase because every rc is positive.
    (3) LIVE-EPOCH ONLY: chunk `seq` is round `seq`'s live owner's batch (its
        object key, producer id and record count), so no fenced writer's record
        is anywhere in the log.

    `test_checker_can_fail` proves each clause rejects a log that breaks it."""
    var n = m.num_chunks()
    var expected_base = Int64(0)
    for seq in range(Int(n)):
        var raw = m.read_chunk(Int64(seq))
        var rc = decode_chunk_record_count(raw)
        var at = label + ": chunk " + String(seq)
        assert_true(rc > Int64(0), at + " has a positive record count")
        var body = ManifestBody.decode(raw)
        assert_equal(
            body.object_key,
            String("live-r") + String(seq) + String(".seg"),
            at + " is the live owner's batch (no fenced writer's record)",
        )
        assert_equal(body.producer_id, _live_pid(seq), at + " producer id")
        assert_equal(body.first_seq, expected_base, at + " starts at the dense base")
        assert_equal(
            body.last_seq, expected_base + rc - Int64(1), at + " ends at base + rc - 1"
        )
        expected_base += rc
    assert_equal(
        expected_base,
        expected_total_records,
        label + ": total committed records == dense offset span (no torn/gap)",
    )
    var head = m.read_head_authoritative()
    assert_equal(head.chunk_seq, n - Int64(1), label + ": head chunk_seq")
    assert_equal(
        head.next_offset,
        expected_total_records,
        label + ": head next_offset == dense offset span",
    )


def _commit_live(
    mut m: CasManifestStore[_Store],
    seg: String,
    rc: Int64,
    pid: Int64,
    first: Int64,
    lease: Int64,
) raises:
    var res = m.append_idempotent(
        _producer_body(seg, rc, pid, Int64(0), first, first + rc - Int64(1)),
        rc, pid, Int64(0), first, first + rc - Int64(1), Int64(0),
        lease,
        lease,
    )
    assert_equal(res.outcome, IDEMPOTENT_COMMITTED, seg + " committed")


def _checker_rejects(m: CasManifestStore[_Store], total: Int64) -> Bool:
    try:
        _assert_offset_invariants(m, total, String("planted"))
    except e:
        print("  planted log refused: " + String(e))
        return True
    return False


def test_checker_can_fail() raises:
    """Each invariant clause rejects a log that breaks it. A checker that cannot
    fail would let the takeover harness pass over a torn log."""
    var store = _Store()
    # A clean two-round log passes.
    var ok = _make_manifest(store, String("c/planted/ok"))
    _commit_live(ok, String("live-r0.seg"), Int64(3), _live_pid(0), Int64(0), Int64(1))
    _commit_live(ok, String("live-r1.seg"), Int64(4), _live_pid(1), Int64(3), Int64(2))
    assert_false(_checker_rejects(ok, Int64(7)), "a clean log passes")
    # (1)+(3) a wrong total is rejected.
    assert_true(_checker_rejects(ok, Int64(8)), "a short span is rejected")
    _ = ok^
    # (3) a record that is not the live owner's (a stale writer's key) is rejected.
    var foreign = _make_manifest(store, String("c/planted/foreign"))
    _commit_live(foreign, String("live-r0.seg"), Int64(3), _live_pid(0), Int64(0), Int64(1))
    _commit_live(foreign, String("stale-r0.seg"), Int64(4), _live_pid(1), Int64(3), Int64(1))
    assert_true(_checker_rejects(foreign, Int64(7)), "a stale writer's chunk is rejected")
    _ = foreign^
    # (3) the right key under another producer id is rejected.
    var pid = _make_manifest(store, String("c/planted/pid"))
    _commit_live(pid, String("live-r0.seg"), Int64(3), _live_pid(0) + Int64(1), Int64(0), Int64(1))
    assert_true(_checker_rejects(pid, Int64(3)), "a foreign producer id is rejected")
    _ = pid^
    # (1) a gap in the producer range is rejected even when the total matches.
    var gap = _make_manifest(store, String("c/planted/gap"))
    _commit_live(gap, String("live-r0.seg"), Int64(3), _live_pid(0), Int64(0), Int64(1))
    _commit_live(gap, String("live-r1.seg"), Int64(4), _live_pid(1), Int64(5), Int64(2))
    assert_true(_checker_rejects(gap, Int64(7)), "a gapped range is rejected")
    _ = gap^
    _ = store^


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
    test_checker_can_fail()
    test_takeover_without_torn_offset()
    print("test_takeover_without_torn_offset: ALL PASS")
