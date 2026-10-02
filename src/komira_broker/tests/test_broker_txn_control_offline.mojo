# =============================================================================
# tests/test_broker_txn_control_offline.mojo
#   Exactly-once transactions — OFFLINE property/unit tests
# =============================================================================
#
# Drives the transactions machinery over the OFFLINE clone-shared in-memory
# ConditionalWriteStore — the IDENTICAL code path a real object store runs,
# only the backend differs. These are the MANDATORY property tests + the
# supporting codec/state-machine units.
#
# Cases:
#   (1) Control-object state machine — Empty -> Ongoing (CREATE) -> add
#       partitions -> PrepareCommit -> Complete via If-Match CAS; illegal
#       transitions raise; terminal states reject further transitions.
#   (2) ManifestBody transaction backward-compat: producer-trailer 9-field bodies decode with
#       marker_type=NONE, txn_id=""; new txn body round-trips the txn tag +
#       marker_type.
#   (3) Marker codec — a COMMIT/ABORT marker chunk body round-trips
#       (marker_type + txn_id, record_count 0).
#   (4) txn-id -> producer_id binding (bind_or_read): first bind returns the
#       candidate; a re-init reads back the SAME stable id (restart reuse).
#   -- THE FOUR MANDATORY PROPERTY TESTS --
#   (5) flip-interleaved multi-partition Fetch (torn-view guard):
#       the control object flips to Complete BETWEEN what would be per-partition
#       reads — the PINNED SNAPSHOT yields a CONSISTENT all-or-nothing view
#       (never partial).
#   (6) abort-after-partial-markers recovery: markers on P1,P2 but the control
#       object never flipped to Complete -> reaper aborts -> consumer sees NONE.
#   (7) fencing under concurrent epochs: txn epoch E1 aborts, re-init E2 commits
#       -> E1 markers/chunks filtered by epoch-equality, only E2 visible.
#   (8) torn-commit recovery: broker dies AFTER the flip-to-Complete -> durable,
#       consumer sees ALL; dies BEFORE -> abortable, consumer sees NONE.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_broker.manifest_body import (
    ManifestBody,
    encode_manifest_body,
    MARKER_NONE,
    MARKER_COMMIT,
    MARKER_ABORT,
)
from komira_broker.txn_control import (
    TxnControl,
    TxnControlStore,
    TxnPartition,
    txn_control_key,
    txn_state_name,
    txn_state_is_terminal,
    TXN_STATE_ONGOING,
    TXN_STATE_PREPARE_COMMIT,
    TXN_STATE_COMPLETE,
    TXN_STATE_ABORT,
)
from komira_broker.txn_registry import TxnIdRegistry
from komira_broker.read_committed import (
    ChunkTxnTag,
    TxnSnapshot,
    chunk_is_visible,
    chunk_is_offset_bearing,
    collect_referenced_txn_ids,
)

from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


def _ctl(store: _Store, cluster: String) -> TxnControlStore[_Store]:
    return TxnControlStore[_Store](store.clone(), cluster)


def _parts(topic: String, n: Int) raises -> List[TxnPartition]:
    var out = List[TxnPartition]()
    for p in range(n):
        out.append(TxnPartition(topic.copy(), Int64(p)))
    return out^


# =============================================================================
# (1) Control-object state machine
# =============================================================================


def test_txn_control_state_machine() raises:
    print("[test_txn_control_state_machine] starting...")
    var store = _Store()
    var cluster = String("cl-txn-sm")
    var ctl = _ctl(store, cluster)
    var tid = String("txn-app-1")

    # Empty -> Ongoing (CREATE via If-None-Match).
    var begun = ctl.begin(tid, Int64(7), Int64(0))
    assert_equal(begun.state, TXN_STATE_ONGOING, "begin -> Ongoing")
    assert_equal(begun.producer_id, Int64(7), "pid stored")
    assert_equal(begun.epoch, Int64(0), "epoch stored")
    assert_true(begun.etag.byte_length() > 0, "etag returned on create")

    # add partitions (idempotent union).
    var p3 = _parts(String("t"), 3)
    var added = ctl.add_partitions(tid, p3^)
    assert_equal(len(added.partitions), 3, "3 partitions added")
    # re-add the same partitions -> still 3 (idempotent).
    var added2 = ctl.add_partitions(tid, _parts(String("t"), 3))
    assert_equal(len(added2.partitions), 3, "re-add idempotent -> still 3")

    # Ongoing -> PrepareCommit -> Complete.
    var pc = ctl.prepare_commit(tid)
    assert_equal(pc.state, TXN_STATE_PREPARE_COMMIT, "-> PrepareCommit")
    var done = ctl.complete_commit(tid)
    assert_equal(done.state, TXN_STATE_COMPLETE, "-> Complete")
    assert_true(txn_state_is_terminal(done.state), "Complete is terminal")

    # Illegal: complete a non-PrepareCommit txn raises.
    var raised = False
    try:
        _ = ctl.prepare_commit(tid)  # Complete -> not Ongoing
    except e:
        raised = True
        _ = e
    assert_true(raised, "prepare_commit on a Complete txn raises")

    # Illegal: abort a Complete txn raises (no torn commit).
    var raised2 = False
    try:
        _ = ctl.abort(tid)
    except e2:
        raised2 = True
        _ = e2
    assert_true(raised2, "abort on a Complete txn raises (no torn commit)")
    _ = ctl^
    _ = store^
    print("[test_txn_control_state_machine] PASS")


# =============================================================================
# (2) ManifestBody transaction backward-compat + (3) marker codec
# =============================================================================


def test_manifest_body_m5b_compat_and_marker() raises:
    print("[test_manifest_body_m5b_compat_and_marker] starting...")
    # An idempotent-producer 9-field body (no txn trailer) decodes marker_type=NONE, txn_id="".
    var m5a = encode_manifest_body(
        String("seg.seg"), Int64(10), UInt32(0xABCD), Int64(4096),
        Int64(1700000000000), Int64(7), Int64(3), Int64(100), Int64(109),
    )
    var dm5a = ManifestBody.decode(m5a)
    assert_equal(dm5a.producer_id, Int64(7), "m5a pid preserved")
    assert_equal(dm5a.marker_type, MARKER_NONE, "m5a body -> marker NONE")
    assert_equal(dm5a.txn_id.byte_length(), 0, "m5a body -> txn_id empty")

    # A NEW transaction txn-open data chunk round-trips the txn tag.
    var m5b = encode_manifest_body(
        String("seg-txn.seg"), Int64(5), UInt32(0x1111), Int64(2048),
        Int64(1700000000001), Int64(9), Int64(2), Int64(0), Int64(4),
        MARKER_NONE, String("txn-app-42"),
    )
    var dm5b = ManifestBody.decode(m5b)
    assert_equal(dm5b.marker_type, MARKER_NONE, "txn-open chunk marker NONE")
    assert_equal(dm5b.txn_id, String("txn-app-42"), "txn_id round-trip")
    assert_equal(dm5b.producer_epoch, Int64(2), "epoch preserved (fence input)")

    # A COMMIT marker chunk (record_count 0).
    var commit = encode_manifest_body(
        String(""), Int64(0), UInt32(0), Int64(0), Int64(1700000000002),
        Int64(9), Int64(2), Int64(-1), Int64(-1),
        MARKER_COMMIT, String("txn-app-42"),
    )
    var dcommit = ManifestBody.decode(commit)
    assert_equal(dcommit.marker_type, MARKER_COMMIT, "COMMIT marker type")
    assert_equal(dcommit.record_count, Int64(0), "marker has 0 records")
    assert_equal(dcommit.txn_id, String("txn-app-42"), "marker txn_id")

    # An ABORT marker chunk.
    var abort = encode_manifest_body(
        String(""), Int64(0), UInt32(0), Int64(0), Int64(1700000000003),
        Int64(9), Int64(1), Int64(-1), Int64(-1),
        MARKER_ABORT, String("txn-app-42"),
    )
    var dabort = ManifestBody.decode(abort)
    assert_equal(dabort.marker_type, MARKER_ABORT, "ABORT marker type")
    print("[test_manifest_body_m5b_compat_and_marker] PASS")


# =============================================================================
# (4) txn-id -> producer_id binding (restart reuse)
# =============================================================================


def test_txn_id_binding_restart_reuse() raises:
    print("[test_txn_id_binding_restart_reuse] starting...")
    var store = _Store()
    var cluster = String("cl-txn-bind")
    var reg = TxnIdRegistry[_Store](store.clone(), cluster)
    var tid = String("payments-svc")

    # No binding yet.
    assert_equal(reg.lookup(tid), Int64(-1), "no binding -> -1")
    # First bind: candidate 5 wins the create.
    var pid1 = reg.bind_or_read(tid, Int64(5))
    assert_equal(pid1, Int64(5), "first bind returns candidate")
    # Restart: a NEW candidate (8) loses; the stable bound id (5) is returned.
    var pid2 = reg.bind_or_read(tid, Int64(8))
    assert_equal(pid2, Int64(5), "restart reuses the SAME pid (5, not 8)")
    assert_equal(reg.lookup(tid), Int64(5), "lookup confirms stable binding")
    # A DIFFERENT transactional-id binds independently.
    var pid_other = reg.bind_or_read(String("orders-svc"), Int64(8))
    assert_equal(pid_other, Int64(8), "distinct id binds its own candidate")
    _ = reg^
    _ = store^
    print("[test_txn_id_binding_restart_reuse] PASS")


# =============================================================================
# (5) MANDATORY: flip-interleaved multi-partition Fetch (torn-view guard)
# =============================================================================
#
# A 2-partition transaction. We build the per-partition chunk tags (each txn-
# open under txn-flip @ epoch 0). The pinned snapshot is taken ONCE. We then
# simulate a concurrent Complete-flip BETWEEN what would be the per-partition
# reads by flipping the control object AFTER the snapshot was taken — and assert
# that resolving BOTH partitions against the ALREADY-PINNED snapshot yields a
# CONSISTENT view (all hidden, since the snapshot pre-dates the flip), never a
# partial P1-visible/P2-hidden split. Then a FRESH snapshot (taken after the
# flip) makes BOTH visible. The point: one snapshot == one consistent decision.


def _txn_open_tag(txn_id: String, epoch: Int64) -> ChunkTxnTag:
    return ChunkTxnTag(MARKER_NONE, txn_id, epoch)


def _build_snapshot(ctl: TxnControlStore[_Store], txn_id: String) raises -> TxnSnapshot:
    """Step 1+2 of the pinned-snapshot flow for ONE referenced txn: GET the
    control object ONCE and freeze (state, control_epoch)."""
    var snap = TxnSnapshot()
    var tc = ctl.read(txn_id)
    if tc:
        ref c = tc.value()
        snap.put(txn_id.copy(), c.state, c.epoch)
    return snap^


def test_flip_interleaved_pinned_snapshot() raises:
    print("[test_flip_interleaved_pinned_snapshot] starting...")
    var store = _Store()
    var cluster = String("cl-attack1")
    var ctl = _ctl(store, cluster)
    var tid = String("txn-flip")

    # Open the txn @ epoch 0, add 2 partitions, prepare-commit (markers durable
    # but NOT yet Complete).
    _ = ctl.begin(tid, Int64(1), Int64(0))
    _ = ctl.add_partitions(tid, _parts(String("t"), 2))
    _ = ctl.prepare_commit(tid)

    # The chunk tags for partition 0 and partition 1 (each one txn-open chunk).
    var p0_tag = _txn_open_tag(tid, Int64(0))
    var p1_tag = _txn_open_tag(tid, Int64(0))

    # --- PINNED snapshot taken NOW (txn is PrepareCommit, NOT Complete) ---
    var snap_before = _build_snapshot(ctl, tid)
    assert_equal(
        snap_before.state_of(tid), TXN_STATE_PREPARE_COMMIT,
        "snapshot froze PrepareCommit",
    )

    # --- The CONCURRENT FLIP: another broker completes the commit. This would
    #     be the torn-view window (flip between per-partition reads). ---
    _ = ctl.complete_commit(tid)

    # Resolve BOTH partitions against the ALREADY-PINNED snapshot. Because the
    # snapshot pre-dates the flip, BOTH must resolve to HIDDEN — a CONSISTENT
    # all-or-nothing view. A per-partition RE-READ would have seen P1 Complete
    # (the torn break) — the pin prevents it.
    var p0_vis = chunk_is_visible(p0_tag, snap_before)
    var p1_vis = chunk_is_visible(p1_tag, snap_before)
    assert_false(p0_vis, "P0 hidden under pre-flip pinned snapshot")
    assert_false(p1_vis, "P1 hidden under pre-flip pinned snapshot")
    assert_equal(p0_vis, p1_vis, "TORN-VIEW GUARD: both partitions agree")

    # A NEW Fetch (fresh snapshot taken AFTER the flip) sees the consistent
    # COMMITTED view: BOTH visible.
    var snap_after = _build_snapshot(ctl, tid)
    assert_equal(
        snap_after.state_of(tid), TXN_STATE_COMPLETE, "fresh snapshot Complete"
    )
    var p0_after = chunk_is_visible(p0_tag, snap_after)
    var p1_after = chunk_is_visible(p1_tag, snap_after)
    assert_true(p0_after, "P0 visible post-commit (fresh snapshot)")
    assert_true(p1_after, "P1 visible post-commit (fresh snapshot)")
    assert_equal(p0_after, p1_after, "post-commit: both partitions agree")
    _ = ctl^
    _ = store^
    print("[test_flip_interleaved_pinned_snapshot] PASS")


# =============================================================================
# (6) MANDATORY: abort-after-partial-markers recovery
# =============================================================================
#
# Markers were appended to P1 and P2 but the control object NEVER flipped to
# Complete (a broker died after the markers, before complete_commit). A reaper
# (or the next InitProducerId epoch-bump) aborts the txn. A read_committed
# consumer must see NONE of the txn's records.


def test_abort_after_partial_markers() raises:
    print("[test_abort_after_partial_markers] starting...")
    var store = _Store()
    var cluster = String("cl-partial")
    var ctl = _ctl(store, cluster)
    var tid = String("txn-partial")

    _ = ctl.begin(tid, Int64(2), Int64(0))
    _ = ctl.add_partitions(tid, _parts(String("t"), 2))
    _ = ctl.prepare_commit(tid)
    # ... markers durable on P1, P2 (modeled as the txn-open chunk tags), but
    # the broker dies HERE — complete_commit() never runs.

    var p0_tag = _txn_open_tag(tid, Int64(0))
    var p1_tag = _txn_open_tag(tid, Int64(0))

    # The reaper resolves the torn txn to Abort (PrepareCommit -> Abort).
    var aborted = ctl.abort(tid)
    assert_equal(aborted.state, TXN_STATE_ABORT, "reaper -> Abort")

    # A read_committed consumer pins a snapshot AFTER the abort: NONE visible.
    var snap = _build_snapshot(ctl, tid)
    assert_equal(snap.state_of(tid), TXN_STATE_ABORT, "snapshot Abort")
    assert_false(chunk_is_visible(p0_tag, snap), "P0 NOT visible (aborted)")
    assert_false(chunk_is_visible(p1_tag, snap), "P1 NOT visible (aborted)")
    _ = ctl^
    _ = store^
    print("[test_abort_after_partial_markers] PASS")


# =============================================================================
# (7) MANDATORY: fencing under concurrent epochs
# =============================================================================
#
# Txn epoch E1 ABORTS (its E1 chunks/markers stay durable). The producer re-
# inits to E2 (begin RESETS the control object to Ongoing @ E2) and COMMITS.
# The control object now reads (Complete, E2). The E1 chunks carry epoch E1 !=
# E2 -> filtered by epoch-equality. Only the E2 chunks (epoch E2) are visible.


def test_fencing_under_concurrent_epochs() raises:
    print("[test_fencing_under_concurrent_epochs] starting...")
    var store = _Store()
    var cluster = String("cl-epochs")
    var ctl = _ctl(store, cluster)
    var tid = String("txn-epoch")

    # E1 transaction: open @ epoch 1, prepare, then ABORT (zombie / timeout).
    _ = ctl.begin(tid, Int64(3), Int64(1))
    _ = ctl.add_partitions(tid, _parts(String("t"), 1))
    _ = ctl.prepare_commit(tid)
    _ = ctl.abort(tid)
    var e1_chunk = _txn_open_tag(tid, Int64(1))  # written under epoch 1

    # E2 incarnation: re-init bumps the epoch; begin RESETS the control object to
    # a fresh Ongoing @ epoch 2; commit to Complete.
    _ = ctl.begin(tid, Int64(3), Int64(2))
    _ = ctl.add_partitions(tid, _parts(String("t"), 1))
    _ = ctl.prepare_commit(tid)
    _ = ctl.complete_commit(tid)
    var e2_chunk = _txn_open_tag(tid, Int64(2))  # written under epoch 2

    # The pinned snapshot reads (Complete, control_epoch=2).
    var snap = _build_snapshot(ctl, tid)
    assert_equal(snap.state_of(tid), TXN_STATE_COMPLETE, "snapshot Complete")
    assert_equal(snap.epoch_of(tid), Int64(2), "control epoch == 2")

    # E1 chunk (epoch 1) is FENCED by epoch-equality; E2 chunk (epoch 2) visible.
    assert_false(
        chunk_is_visible(e1_chunk, snap),
        "E1 chunk fenced by epoch-equality (1 != 2)",
    )
    assert_true(
        chunk_is_visible(e2_chunk, snap), "E2 chunk visible (epoch 2 == 2)"
    )
    _ = ctl^
    _ = store^
    print("[test_fencing_under_concurrent_epochs] PASS")


# =============================================================================
# (8) MANDATORY: torn-commit recovery (die after flip vs before)
# =============================================================================


def test_torn_commit_recovery() raises:
    print("[test_torn_commit_recovery] starting...")
    var store = _Store()
    var cluster = String("cl-torn")

    # --- Case A: broker dies AFTER the flip-to-Complete -> durable, sees ALL ---
    var ctl_a = _ctl(store, cluster)
    var tid_a = String("txn-after")
    _ = ctl_a.begin(tid_a, Int64(4), Int64(0))
    _ = ctl_a.add_partitions(tid_a, _parts(String("ta"), 3))
    _ = ctl_a.prepare_commit(tid_a)
    _ = ctl_a.complete_commit(tid_a)  # flip lands, THEN the broker dies.
    # Recovery: a fresh control-store handle (new broker) reads the durable
    # Complete state via S3 strong consistency.
    var ctl_a2 = _ctl(store, cluster)
    var snap_a = _build_snapshot(ctl_a2, tid_a)
    assert_equal(snap_a.state_of(tid_a), TXN_STATE_COMPLETE, "durable Complete")
    var ta0 = _txn_open_tag(tid_a, Int64(0))
    var ta1 = _txn_open_tag(tid_a, Int64(0))
    var ta2 = _txn_open_tag(tid_a, Int64(0))
    assert_true(chunk_is_visible(ta0, snap_a), "P0 visible (committed)")
    assert_true(chunk_is_visible(ta1, snap_a), "P1 visible (committed)")
    assert_true(chunk_is_visible(ta2, snap_a), "P2 visible (committed)")

    # --- Case B: broker dies BEFORE the flip -> abortable, sees NONE ---
    var ctl_b = _ctl(store, cluster)
    var tid_b = String("txn-before")
    _ = ctl_b.begin(tid_b, Int64(5), Int64(0))
    _ = ctl_b.add_partitions(tid_b, _parts(String("tb"), 3))
    _ = ctl_b.prepare_commit(tid_b)  # broker dies HERE (before complete).
    # Recovery: a fresh handle finds PrepareCommit (abortable).
    var ctl_b2 = _ctl(store, cluster)
    var pre = ctl_b2.read(tid_b)
    assert_true(Bool(pre), "control object present")
    assert_equal(
        pre.value().state, TXN_STATE_PREPARE_COMMIT, "left at PrepareCommit"
    )
    # The reaper aborts it.
    _ = ctl_b2.abort(tid_b)
    var snap_b = _build_snapshot(ctl_b2, tid_b)
    assert_equal(snap_b.state_of(tid_b), TXN_STATE_ABORT, "recovered to Abort")
    var tb0 = _txn_open_tag(tid_b, Int64(0))
    assert_false(chunk_is_visible(tb0, snap_b), "NONE visible (aborted)")
    _ = ctl_a^
    _ = ctl_a2^
    _ = ctl_b^
    _ = ctl_b2^
    _ = store^
    print("[test_torn_commit_recovery] PASS")


# =============================================================================
# (9) read_committed filter primitives — marker / non-txn / offset-bearing
# =============================================================================


def test_read_committed_filter_primitives() raises:
    print("[test_read_committed_filter_primitives] starting...")
    var snap = TxnSnapshot()  # empty snapshot

    # A non-transactional chunk is ALWAYS visible (read_committed never hides
    # at-least-once data).
    var non_txn = ChunkTxnTag(MARKER_NONE, String(""), Int64(-1))
    assert_true(chunk_is_visible(non_txn, snap), "non-txn chunk always visible")
    assert_true(chunk_is_offset_bearing(non_txn), "data chunk offset-bearing")

    # A marker chunk is NEVER visible as data + NOT offset-bearing.
    var marker = ChunkTxnTag(MARKER_COMMIT, String("tx"), Int64(0))
    assert_false(chunk_is_visible(marker, snap), "marker not visible as data")
    assert_false(chunk_is_offset_bearing(marker), "marker not offset-bearing")

    # A txn chunk whose txn is UNKNOWN to the snapshot -> hidden (safe default).
    var unknown = ChunkTxnTag(MARKER_NONE, String("ghost"), Int64(0))
    assert_false(
        chunk_is_visible(unknown, snap), "unknown-txn chunk hidden (safe)"
    )

    # collect_referenced_txn_ids dedupes + skips non-txn tags.
    var tags = List[ChunkTxnTag]()
    tags.append(ChunkTxnTag(MARKER_NONE, String(""), Int64(-1)))  # non-txn
    tags.append(ChunkTxnTag(MARKER_NONE, String("a"), Int64(0)))
    tags.append(ChunkTxnTag(MARKER_NONE, String("a"), Int64(0)))  # dup
    tags.append(ChunkTxnTag(MARKER_COMMIT, String("b"), Int64(0)))
    var ids = collect_referenced_txn_ids(tags)
    assert_equal(len(ids), 2, "2 distinct txn ids (a, b)")
    assert_equal(ids[0], String("a"), "first id a")
    assert_equal(ids[1], String("b"), "second id b")
    print("[test_read_committed_filter_primitives] PASS")


def main() raises:
    test_txn_control_state_machine()
    test_manifest_body_m5b_compat_and_marker()
    test_txn_id_binding_restart_reuse()
    test_flip_interleaved_pinned_snapshot()
    test_abort_after_partial_markers()
    test_fencing_under_concurrent_epochs()
    test_torn_commit_recovery()
    test_read_committed_filter_primitives()
    print(
        "[OK] test_broker_txn_control_offline — transaction tests passed"
        " (control-object state machine, manifest-body txn trailer + marker"
        " codec, txn-id binding restart-reuse, AND the 4 mandatory property"
        " tests: flip-interleaved pinned-snapshot [torn-view guard], abort-after-"
        "partial-markers, fencing-under-concurrent-epochs, torn-commit recovery)"
    )
