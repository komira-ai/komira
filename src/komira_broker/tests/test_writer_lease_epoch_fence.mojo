# =============================================================================
# tests/test_writer_lease_epoch_fence.mojo
#   WRITER-LEASE-EPOCH FENCE — the DISCRIMINATING gate.
# =============================================================================
#
# THE CORRECTNESS PROPERTY: Kafka dense offsets are preserved by single-writer-
# per-partition. Without an ownership fence, a dead/displaced partition owner can
# splice late records into the NEW owner's lineage = TORN OFFSET (silent data
# corruption). The writer-lease-epoch fence rejects a stale displaced writer
# (whose lease generation is below the live one) BEFORE its records take an
# offset.
#
# THIS GATE (discriminating): two CasManifestStore handles A, B over the SAME
# prefix (a shared in-memory ConditionalStore = the cross-process analogue):
#   (a) A appends with lease_epoch=1 -> COMMITTED at offset 0.
#   (b) transfer: the live generation -> 2 (B is the new owner, lease_epoch=2).
#   (c) DISCRIMINATOR: stale A (paused, never saw the transfer) appends with
#       lease_epoch=1 vs current=2 -> FENCED, and NO new chunk is created (A's
#       records took NO offset, the manifest tail is unchanged).
#   (d) B appends with lease_epoch=2 -> COMMITTED densely + contiguous.
#
# WHAT THE FENCE PREVENTS: without the
# `writer_lease_epoch < current_lease_epoch -> FENCED` check, step (c)'s stale A
# would WIN its slot (the create-CAS does not know about leases), so:
#   * the COMMITTED/FENCED assertion in (c) flips (A would be COMMITTED), AND
#   * num_chunks would be 2 after (c) (A spliced a chunk), AND
#   * B's append in (d) would land at offset 10 (after A's torn chunk) instead of
#     contiguous with the live lineage = the torn-offset corruption this guards.
# So this test is a genuine falsifier of the no-fence behavior, not a tautology.
#
# Pure-value test (no S3, no network) — the fence lives on CasManifestStore.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

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


comptime _Store = SharedInMemoryConditionalStore


def _producer_body(
    seg: String, rc: Int64, pid: Int64, epoch: Int64, first: Int64, last: Int64
) -> List[UInt8]:
    """A manifest chunk body shaped like the broker's ManifestBody (so the
    idempotent path's tail-scan + offset replay work)."""
    return encode_manifest_body(
        seg, rc, UInt32(0), Int64(seg.byte_length()), Int64(1700000000000),
        pid, epoch, first, last,
    )


def _plain_body(seg: String, rc: Int64) -> List[UInt8]:
    """A non-idempotent (at-least-once) manifest body."""
    return encode_manifest_body(
        seg, rc, UInt32(0), Int64(seg.byte_length()), Int64(1700000000000)
    )


def _make_manifest(store: _Store, prefix: String) -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](store.clone(), prefix, RetryPolicy.fast_test())


# =============================================================================
# Idempotent / exactly-once path — the load-bearing real Kafka produce path.
# =============================================================================
def test_writer_lease_epoch_fences_stale_displaced_writer() raises:
    """The DISCRIMINATING case (idempotent path). A stale displaced writer (lease 1)
    is FENCED after a transfer to lease 2, takes NO offset, and the new owner B
    commits densely + contiguous."""
    print("[test_writer_lease_epoch_fences_stale_displaced_writer] starting...")
    var store = _Store()
    var prefix = String("c/t/0")
    var m_a = _make_manifest(store, prefix)  # the OLD owner (lease 1)
    var m_b = _make_manifest(store, prefix)  # the NEW owner (lease 2)

    # --- (a) A appends at lease_epoch=1, current=1 -> COMMITTED at offset 0. ---
    # A is the live owner (writer_lease==current==1), so the fence passes.
    var ra = m_a.append_idempotent(
        _producer_body(String("a0.seg"), Int64(5), Int64(7), Int64(0), Int64(0), Int64(4)),
        Int64(5),  # record_count
        Int64(7),  # producer_id
        Int64(0),  # producer_epoch
        Int64(0),  # first_seq
        Int64(4),  # last_seq
        Int64(0),  # registered_epoch
        Int64(1),  # writer_lease_epoch (A's lease)
        Int64(1),  # current_lease_epoch (live == A's lease)
    )
    assert_equal(ra.outcome, IDEMPOTENT_COMMITTED, "(a) A COMMITTED")
    assert_equal(ra.base_offset, Int64(0), "(a) A base offset 0")
    assert_equal(ra.last_offset, Int64(4), "(a) A last offset 4")
    assert_equal(m_a.num_chunks(), Int64(1), "(a) one chunk after A")
    var tail_before = m_a.num_chunks()

    # --- (b) TRANSFER: the live generation bumps to 2 (B is the new owner). ---
    # (No store op needed — the live generation is what the caller reads at flush;
    # B carries lease 2, A is FROZEN at lease 1 because it never saw the transfer.)

    # --- (c) DISCRIMINATOR: stale A appends at lease 1 vs current 2 -> FENCED, ---
    #         and NO new chunk is created (A took NO offset).
    var rc_fenced = m_a.append_idempotent(
        _producer_body(String("a1-stale.seg"), Int64(5), Int64(7), Int64(1), Int64(5), Int64(9)),
        Int64(5),  # record_count
        Int64(7),  # producer_id
        Int64(1),  # producer_epoch (advanced — but the LEASE fence fires first)
        Int64(5),  # first_seq
        Int64(9),  # last_seq
        Int64(0),  # registered_epoch
        Int64(1),  # writer_lease_epoch (A's STALE lease)
        Int64(2),  # current_lease_epoch (live is now 2 — A is displaced)
    )
    # The LEASE fence returns the DISTINCT
    # IDEMPOTENT_LEASE_FENCED outcome (the partition-OWNERSHIP fence), NOT
    # IDEMPOTENT_FENCED (which stays the producer-id epoch fence). The broker maps
    # this to NOT_LEADER_OR_FOLLOWER, not INVALID_PRODUCER_EPOCH.
    assert_equal(
        rc_fenced.outcome, IDEMPOTENT_LEASE_FENCED, "(c) stale A LEASE-FENCED"
    )
    assert_equal(
        m_a.num_chunks(),
        tail_before,
        "(c) NO new chunk — stale A took NO offset (tail unchanged)",
    )

    # --- (d) B appends at lease_epoch=2, current=2 -> COMMITTED densely. ---
    var rd = m_b.append_idempotent(
        _producer_body(String("b1.seg"), Int64(3), Int64(8), Int64(0), Int64(0), Int64(2)),
        Int64(3),  # record_count
        Int64(8),  # producer_id (B's producer)
        Int64(0),  # producer_epoch
        Int64(0),  # first_seq
        Int64(2),  # last_seq
        Int64(0),  # registered_epoch
        Int64(2),  # writer_lease_epoch (B's lease)
        Int64(2),  # current_lease_epoch (live == B's lease)
    )
    assert_equal(rd.outcome, IDEMPOTENT_COMMITTED, "(d) B COMMITTED")
    # B's chunk is the SECOND chunk (slot 1), contiguous after A's chunk 0. The
    # offsets are dense: A took [0,4], B takes [5,7] — NO gap, NO torn slot from
    # the stale A.
    assert_equal(rd.chunk_seq, Int64(1), "(d) B chunk slot 1 (after A's 0)")
    assert_equal(rd.base_offset, Int64(5), "(d) B base offset 5 (contiguous)")
    assert_equal(rd.last_offset, Int64(7), "(d) B last offset 7")
    assert_equal(m_b.num_chunks(), Int64(2), "(d) exactly 2 chunks (A + B)")

    _ = m_a^
    _ = m_b^
    _ = store^
    print("[test_writer_lease_epoch_fences_stale_displaced_writer] PASS")


# =============================================================================
# At-least-once `append` path — the fence raises the classified error.
# =============================================================================
def test_writer_lease_epoch_fences_at_least_once_append() raises:
    """The at-least-once `append` path fences a stale displaced writer by RAISING
    the classified `lease_fenced` error, and the stale writer takes NO offset."""
    print("[test_writer_lease_epoch_fences_at_least_once_append] starting...")
    var store = _Store()
    var prefix = String("c/t/1")
    var m_a = _make_manifest(store, prefix)
    var m_b = _make_manifest(store, prefix)

    # (a) A appends at lease 1 (live 1) -> COMMITTED offset 0.
    var ra = m_a.append(_plain_body(String("a0.seg"), Int64(4)), Int64(4), Int64(1), Int64(1))
    assert_equal(ra.base_offset, Int64(0), "(a) A base 0")
    assert_equal(ra.last_offset, Int64(3), "(a) A last 3")
    var tail_before = m_a.num_chunks()
    assert_equal(tail_before, Int64(1), "(a) one chunk")

    # (b) transfer -> live generation 2.
    # (c) DISCRIMINATOR: stale A at lease 1 vs current 2 -> RAISES lease_fenced,
    #     and NO new chunk is created.
    var raised = False
    try:
        _ = m_a.append(
            _plain_body(String("a1-stale.seg"), Int64(4)),
            Int64(4),
            Int64(1),  # writer_lease_epoch (stale)
            Int64(2),  # current_lease_epoch (live)
        )
    except e:
        raised = True
        assert_true(
            is_lease_fenced(String(e)),
            "(c) the raise is classified as lease_fenced",
        )
    assert_true(raised, "(c) stale A append RAISED")
    assert_equal(
        m_a.num_chunks(),
        tail_before,
        "(c) NO new chunk — stale A took NO offset",
    )

    # (d) B at lease 2 (live 2) -> COMMITTED densely (offset 4, contiguous).
    var rd = m_b.append(_plain_body(String("b1.seg"), Int64(2)), Int64(2), Int64(2), Int64(2))
    assert_equal(rd.chunk_seq, Int64(1), "(d) B slot 1 (after A's 0)")
    assert_equal(rd.base_offset, Int64(4), "(d) B base 4 (contiguous, no gap)")
    assert_equal(rd.last_offset, Int64(5), "(d) B last 5")
    assert_equal(m_b.num_chunks(), Int64(2), "(d) exactly 2 chunks")

    _ = m_a^
    _ = m_b^
    _ = store^
    print("[test_writer_lease_epoch_fences_at_least_once_append] PASS")


# =============================================================================
# The LIVE owner (writer_lease == current) is NEVER fenced (no false positive).
# =============================================================================
def test_live_owner_never_fenced() raises:
    """A LIVE owner whose lease equals the current generation is NEVER fenced —
    the fence rejects ONLY a strictly-stale writer (no false positives that would
    stall a healthy owner)."""
    print("[test_live_owner_never_fenced] starting...")
    var store = _Store()
    var prefix = String("c/t/2")
    var m = _make_manifest(store, prefix)

    # writer_lease == current (3 == 3) -> NOT fenced.
    var r1 = m.append(_plain_body(String("s0.seg"), Int64(2)), Int64(2), Int64(3), Int64(3))
    assert_equal(r1.base_offset, Int64(0), "live owner committed (lease==current)")

    # writer_lease > current (a brand-new acquire whose owner raced ahead of a
    # stale current read) -> also NOT fenced (the fence is strictly `<`).
    var r2 = m.append(_plain_body(String("s1.seg"), Int64(2)), Int64(2), Int64(5), Int64(4))
    assert_equal(r2.base_offset, Int64(2), "writer_lease > current not fenced")

    # Default (0,0) -> no-op (a non-lease caller is never fenced).
    var r3 = m.append(_plain_body(String("s2.seg"), Int64(2)), Int64(2))
    assert_equal(r3.base_offset, Int64(4), "default (0,0) no-op")

    assert_equal(m.num_chunks(), Int64(3), "all three committed (no false fence)")
    _ = m^
    _ = store^
    print("[test_live_owner_never_fenced] PASS")


def main() raises:
    test_writer_lease_epoch_fences_stale_displaced_writer()
    test_writer_lease_epoch_fences_at_least_once_append()
    test_live_owner_never_fenced()
    print("test_writer_lease_epoch_fence: ALL PASS")
