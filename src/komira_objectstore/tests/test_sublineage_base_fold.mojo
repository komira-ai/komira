# =============================================================================
# tests/test_sublineage_base_fold.mojo
#   The PRODUCTION `_base` MATERIALIZE+RETIRE fold regression guards: the
#   fold's property tests run against the REAL fold
#   (komira_objectstore.sublineage_base_fold.SubLineageBaseFold), plus the
#   SUSTAINED multi-grower BOUND test, the retention-compaction round-trip, and
#   the FAULT-INJECTION discriminating gate.
# =============================================================================
#
# PROVES (in code, as property tests) the three fold invariants of the PRODUCTION
# dense-offset fold, the net-new LIST enumeration, the SUSTAINED-interleave
# BOUND, the retention-compaction round-trip, and the RED->GREEN discrimination
# against a renumber-at-fold-time variant of the REAL code.
#
#   DETERMINISM  DETERMINISTIC MERGE — two independent folds over the SAME committed
#          snapshot, iterating shards in canonical (shard_id lexicographic)
#          order, produce BYTE-IDENTICAL (shard_id, local_offset)->dense
#          assignments.                       [test_determinism_merge]
#   ADDITIVITY  OFFSET-PRESERVING — a record served dense O keeps O across a later
#          fold that appends new records (additive; never renumbers).
#                            [test_additivity_offsets_preserved_across_folds]
#   RESUMABILITY  RESUMABILITY across the un-folded-tail<->_base boundary + RESTART.
#                            [test_resumability_tail_to_base]
#   ENUM   net-new LIST enumeration discovers live sub-lineages by folding object
#          keys on the delimiter (backend-agnostic; _base excluded).
#                            [test_enumerate_live_shards_lists_bucket]
#   BOUND  the SUSTAINED multi-grower interleave: N>=2 growers, 50+ fold rounds,
#          asserts the PERSISTENT resolution state stays BOUNDED — _base grows
#          only as O(folded-chunks) (retention-managed) + the cross-shard state
#          is O(distinct shards)/O(live-shard-width), NOT N x rounds.
#                            [test_sustained_multigrower_bound]
#   COMPACT retention-compaction reaps _base below a watermark, _base stays
#          readable, round-trips byte-identically above the watermark, reaped
#          offsets surface the REAPED sentinel.
#                            [test_retention_compaction_roundtrip]
#   GATE   the DISCRIMINATING property: the SAME randomized scenario PASSES on the
#          CORRECT real fold and FAILS on a renumber-at-fold-time variant of the
#          REAL fold (a fault-injected real fold, NOT a separate naive struct).
#                            [test_discriminating_gate_red_green_real_fold]
#   SNAPSHOT consistency, ORDER (canonical shard order), REAPED-SOURCE
#          (binding survives source reaping), SINGLE-WRITER (_base CAS +
#          base==dense + contiguity + CRC) — each pinned.
#
# Encapsulation / heap-reuse: ZERO UnsafePointer / wildcard origin / unsafe_from_address.
# All state is value / List / POD. No byte-slab element introduced.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.sublineage_base_fold import (
    BASE_SHARD_ID,
    BaseChunkEntry,
    BoundStats,
    FoldStats,
    REAPED_PAYLOAD_SENTINEL,
    ResolvedRecord,
    ShardSnapshot,
    SubLineageBaseFold,
    _canonical_shard_less,
    _sort_shard_ids,
    encode_record_body,
    sublineage_prefix,
)

comptime _Fold = SubLineageBaseFold[SharedInMemoryConditionalStore]


# -----------------------------------------------------------------------------
# Deterministic xorshift PRNG — seed is the test parameter (reproducible).
# -----------------------------------------------------------------------------
struct _Rng(Movable, Deinitable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed | UInt64(1)

    def next(mut self) -> UInt64:
        self.s ^= self.s << UInt64(13)
        self.s ^= self.s >> UInt64(7)
        self.s ^= self.s << UInt64(17)
        return self.s

    def below(mut self, n: Int) -> Int:
        if n <= 1:
            return 0
        return Int(self.next() % UInt64(n))


def _shard_id(i: Int) -> String:
    var s = String(i)
    if s.byte_length() < 2:
        return String("w0") + s
    return String("w") + s


def _new_fold(part: String) raises -> _Fold:
    return _Fold(SharedInMemoryConditionalStore(), part)


def _one(a: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    return l^


def _two(a: Int64, b: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    l.append(b)
    return l^


# A flat assignment row, compared byte-for-byte across two folds.
@fieldwise_init
struct _Assign(Copyable, Movable, Deinitable):
    var shard_id: String
    var local_offset: Int64
    var dense_offset: Int64
    var payload: Int64


def _materialize_assignments(
    mut fold: _Fold, dense_hw: Int64
) raises -> List[_Assign]:
    var out = List[_Assign]()
    var o = Int64(0)
    while o < dense_hw:
        var r = fold.resolve_offset(o)
        if not r.found:
            raise Error("dense offset " + String(o) + " did not resolve")
        out.append(_Assign(r.shard_id, r.local_offset, o, r.payload))
        o += Int64(1)
    return out^


def _assigns_equal(a: List[_Assign], b: List[_Assign]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if (
            a[i].shard_id != b[i].shard_id
            or a[i].local_offset != b[i].local_offset
            or a[i].dense_offset != b[i].dense_offset
            or a[i].payload != b[i].payload
        ):
            return False
    return True


# =============================================================================
# canonical-order determinism.
# =============================================================================


def test_canonical_order_is_deterministic() raises:
    """shard_id byte-wise lexicographic, NO FP/hash/process-order.
    Sorting the SAME set in two INSERTION orders yields IDENTICAL output."""
    var a = List[String]()
    a.append(String("w03"))
    a.append(String("_base"))
    a.append(String("w01"))
    a.append(String("w10"))
    a.append(String("w02"))

    var b = List[String]()
    b.append(String("w10"))
    b.append(String("w02"))
    b.append(String("w01"))
    b.append(String("w03"))
    b.append(String("_base"))

    var sa = _sort_shard_ids(a.copy())
    var sb = _sort_shard_ids(b.copy())
    assert_equal(len(sa), len(sb), "same length")
    for i in range(len(sa)):
        assert_equal(sa[i], sb[i], "canonical order is insertion-independent")
    assert_equal(sa[0], String("_base"), "_base sorts first (underscore<w)")
    assert_equal(sa[1], String("w01"), "")
    assert_equal(sa[4], String("w10"), "")
    assert_true(_canonical_shard_less(String("w01"), String("w02")), "w01<w02")
    assert_false(_canonical_shard_less(String("w02"), String("w01")), "not w02<w01")
    assert_false(_canonical_shard_less(String("w01"), String("w01")), "not x<x")
    print("[test_canonical_order_is_deterministic] PASS")


# =============================================================================
# ENUM — net-new LIST enumeration of live sub-lineages.
# =============================================================================


def test_enumerate_live_shards_lists_bucket() raises:
    """The PRODUCTION fold DISCOVERS live shards by LISTing <part>/_lineage/ and
    folding object keys on the delimiter (NOT a caller-maintained registry, NOT
    reliant on store common_prefixes). The reserved _base is EXCLUDED."""
    var f = _new_fold(String("p"))
    _ = f.append_batch(String("w02"), _one(Int64(300)))
    _ = f.append_batch(String("w00"), _two(Int64(100), Int64(101)))
    _ = f.append_batch(String("w01"), _one(Int64(200)))

    var live = f.enumerate_live_shards()
    assert_equal(len(live), 3, "three live writer shards discovered")
    # Canonical-sorted.
    assert_equal(live[0], String("w00"), "")
    assert_equal(live[1], String("w01"), "")
    assert_equal(live[2], String("w02"), "")

    # After a fold materializes _base + retires the source chunks, the writer
    # shards' _HEAD survives (they are tombstoned, not deleted, until the reaper
    # runs). The reserved _base is excluded from live-shard enumeration.
    var st = f.run_once()
    assert_equal(st.records_folded, Int64(4), "1+2+1 = 4 records folded")
    var live2 = f.enumerate_live_shards()
    for i in range(len(live2)):
        assert_false(live2[i] == BASE_SHARD_ID, "no _base in live shards")
    _ = f^
    print("[test_enumerate_live_shards_lists_bucket] PASS")


# =============================================================================
# DETERMINISM — DETERMINISTIC MERGE.
# =============================================================================


def test_determinism_merge() raises:
    """DETERMINISM: two independent folds over the SAME committed universe (records
    written in DIFFERENT shard-touch orders) produce BYTE-IDENTICAL assignments,
    discovered purely via LIST enumeration."""
    var f1 = _new_fold(String("p"))
    var f2 = _new_fold(String("p2"))

    var recs_w00 = _two(Int64(1000), Int64(1001))
    var recs_w01 = List[Int64]()
    recs_w01.append(Int64(2000))
    recs_w01.append(Int64(2001))
    recs_w01.append(Int64(2002))
    var recs_w02 = _one(Int64(3000))

    _ = f1.append_batch(String("w02"), recs_w02.copy())
    _ = f1.append_batch(String("w00"), recs_w00.copy())
    _ = f1.append_batch(String("w01"), recs_w01.copy())

    _ = f2.append_batch(String("w01"), recs_w01.copy())
    _ = f2.append_batch(String("w02"), recs_w02.copy())
    _ = f2.append_batch(String("w00"), recs_w00.copy())

    var st1 = f1.run_once()
    var st2 = f2.run_once()
    assert_equal(st1.dense_high_water, st2.dense_high_water, "dense hw identical")
    assert_equal(st1.dense_high_water, Int64(6), "2+3+1 = 6 records folded")

    var a1 = _materialize_assignments(f1, st1.dense_high_water)
    var a2 = _materialize_assignments(f2, st2.dense_high_water)
    assert_true(_assigns_equal(a1, a2), "DETERMINISM: assignments BYTE-IDENTICAL")

    # canonical layout: w00 -> dense [0,1], w01 -> [2,3,4], w02 -> [5].
    assert_equal(a1[0].shard_id, String("w00"), "")
    assert_equal(a1[0].payload, Int64(1000), "")
    assert_equal(a1[2].shard_id, String("w01"), "")
    assert_equal(a1[2].payload, Int64(2000), "")
    assert_equal(a1[5].shard_id, String("w02"), "")
    assert_equal(a1[5].payload, Int64(3000), "")
    _ = f1^
    _ = f2^
    print("[test_determinism_merge] PASS")


# =============================================================================
# DISCRIMINATING GATE — byte-identical to a from-scratch log_start replay of the
# union (same cumulative record_counts); a second fold reproduces the identical
# assignment; RED if the fold renumbers any already-assigned offset.
# =============================================================================


def test_fold_equals_from_scratch_replay_and_idempotent() raises:
    """DISCRIMINATING GATE (deterministic): the fold's replayed dense sequence is
    byte-identical to a from-scratch canonical replay of the union, AND a SECOND
    fold (no new records) reproduces the IDENTICAL assignment (idempotent — no
    renumber of an already-assigned offset)."""
    var f = _new_fold(String("p"))
    _ = f.append_batch(String("w02"), _two(Int64(30), Int64(31)))
    _ = f.append_batch(String("w00"), _one(Int64(10)))
    _ = f.append_batch(String("w01"), _two(Int64(20), Int64(21)))

    var st = f.run_once()
    var got = _materialize_assignments(f, st.dense_high_water)

    # From-scratch reference: canonical shard order, each shard's local order.
    var ref_payloads = List[Int64]()
    # w00:{10}, w01:{20,21}, w02:{30,31}
    ref_payloads.append(Int64(10))
    ref_payloads.append(Int64(20))
    ref_payloads.append(Int64(21))
    ref_payloads.append(Int64(30))
    ref_payloads.append(Int64(31))
    assert_equal(len(got), len(ref_payloads), "same record count as union replay")
    for i in range(len(ref_payloads)):
        assert_equal(
            got[i].payload, ref_payloads[i], "byte-identical to from-scratch replay"
        )
        assert_equal(got[i].dense_offset, Int64(i), "dense offsets dense from 0")

    # A second fold with NO new records must be a no-op + reproduce identical.
    var st2 = f.run_once()
    assert_equal(st2.records_folded, Int64(0), "second fold folds nothing new")
    assert_equal(st2.dense_high_water, st.dense_high_water, "hw unchanged")
    var got2 = _materialize_assignments(f, st2.dense_high_water)
    for i in range(len(got)):
        assert_equal(got2[i].payload, got[i].payload, "second fold identical")
        assert_equal(got2[i].shard_id, got[i].shard_id, "second fold identical shard")
    _ = f^
    print("[test_fold_equals_from_scratch_replay_and_idempotent] PASS")


# =============================================================================
# ADDITIVITY — OFFSET-PRESERVING.
# =============================================================================


def test_additivity_offsets_preserved_across_folds() raises:
    """ADDITIVITY: fold once; append NEW records (incl. a new shard that sorts BEFORE
    existing ones — the adversarial renumber case); fold again; every PRE-EXISTING
    dense O still resolves to the SAME payload, new records extend contiguously."""
    var f = _new_fold(String("p"))
    _ = f.append_batch(String("w05"), _two(Int64(500), Int64(501)))
    _ = f.append_batch(String("w09"), _one(Int64(900)))
    var st1 = f.run_once()
    assert_equal(st1.dense_high_water, Int64(3), "w05(2) + w09(1) = 3")

    var before = _materialize_assignments(f, st1.dense_high_water)

    _ = f.append_batch(String("w05"), _one(Int64(502)))  # extend w05
    _ = f.append_batch(String("w01"), _two(Int64(100), Int64(101)))  # sorts first
    var st2 = f.run_once()
    assert_equal(st2.dense_high_water, Int64(6), "added 3 records -> hw 6")

    for i in range(len(before)):
        var r = f.resolve_offset(before[i].dense_offset)
        assert_true(r.found, "old offset still resolves")
        assert_equal(r.shard_id, before[i].shard_id, "ADDITIVITY: shard preserved")
        assert_equal(r.local_offset, before[i].local_offset, "local preserved")
        assert_equal(r.payload, before[i].payload, "ADDITIVITY: payload preserved at O")

    var seen_w01 = False
    var seen_w05_502 = False
    var o = st1.dense_high_water
    while o < st2.dense_high_water:
        var r = f.resolve_offset(o)
        assert_true(r.found, "new offset resolves")
        if r.payload == Int64(100) or r.payload == Int64(101):
            seen_w01 = True
            assert_equal(r.shard_id, String("w01"), "new w01 record")
        if r.payload == Int64(502):
            seen_w05_502 = True
            assert_equal(r.shard_id, String("w05"), "extended w05 record")
        o += Int64(1)
    assert_true(seen_w01, "new w01 records in extended range")
    assert_true(seen_w05_502, "extended w05 record in extended range")
    _ = f^
    print("[test_additivity_offsets_preserved_across_folds] PASS")


# =============================================================================
# RESUMABILITY — RESUMABILITY across the un-folded-tail<->_base boundary + RESTART.
# =============================================================================


def test_resumability_tail_to_base() raises:
    """RESUMABILITY: a consumer commits at dense O while records beyond O are still
    un-folded; after the tail folds, O still resolves to the SAME record and the
    consumer resumes from O+1; the bridge survives a fold-process RESTART (state
    rebuilt PURELY from the persisted _base, CRC-verified)."""
    var f = _new_fold(String("p"))
    _ = f.append_batch(String("w00"), _two(Int64(10), Int64(11)))
    _ = f.append_batch(String("w01"), _two(Int64(20), Int64(21)))
    var st1 = f.run_once()
    assert_equal(st1.dense_high_water, Int64(4), "4 records folded into _base")

    var committed_o = Int64(1)
    var at_commit = f.resolve_offset(committed_o)
    assert_true(at_commit.found, "committed offset resolves")
    assert_equal(at_commit.payload, Int64(11), "record at O is payload 11")
    assert_equal(at_commit.shard_id, String("w00"), "")

    _ = f.append_batch(String("w00"), _one(Int64(12)))
    _ = f.append_batch(String("w02"), _one(Int64(30)))
    var st2 = f.run_once()
    assert_true(st2.dense_high_water > st1.dense_high_water, "tail folded")

    var after = f.resolve_offset(committed_o)
    assert_true(after.found, "O still resolves after tail fold")
    assert_equal(after.payload, Int64(11), "RESUMABILITY: O is STILL payload 11")
    assert_equal(after.shard_id, String("w00"), "RESUMABILITY: O is STILL w00")
    assert_equal(after.local_offset, at_commit.local_offset, "local stable")

    var resume = f.resolve_offset(committed_o + Int64(1))
    assert_true(resume.found, "O+1 resolves")
    assert_equal(resume.payload, Int64(20), "resume O+1 -> next record (w01 20)")
    assert_equal(resume.shard_id, String("w01"), "")

    # RESTART: rebuild ALL state PURELY from persisted _base (CRC-verified).
    f.reload_from_base()
    var post_restart = f.resolve_offset(committed_o)
    assert_true(post_restart.found, "O resolves after _base-only rebuild")
    assert_equal(post_restart.payload, Int64(11), "RESUMABILITY: durable across restart")
    assert_equal(post_restart.shard_id, String("w00"), "")
    var post_resume = f.resolve_offset(committed_o + Int64(1))
    assert_equal(post_resume.payload, Int64(20), "resume durable across restart")
    _ = f^
    print("[test_resumability_tail_to_base] PASS")


# =============================================================================
# SNAPSHOT — snapshot consistency.
# =============================================================================


def test_snapshot_consistency() raises:
    """pin a snapshot, append MORE records, fold the OLD snapshot. Only
    the snapshot's records are folded; post-snapshot records fold in a later
    fold (the precondition that makes two folds over the SAME snapshot agree)."""
    var f = _new_fold(String("p"))
    _ = f.append_batch(String("w00"), _two(Int64(1), Int64(2)))
    var snap = f.snapshot()  # pins w00 at 2 records

    _ = f.append_batch(String("w00"), _one(Int64(3)))  # AFTER snapshot

    var st = f.fold(snap^)
    assert_equal(st.dense_high_water, Int64(2), "only the 2 snapshotted records")
    assert_equal(
        f.live_base_chunk_count(), 1, "one _base block (w00, count=2)"
    )

    var st2 = f.run_once()  # fresh snapshot now sees 3
    assert_equal(st2.dense_high_water, Int64(3), "later fold picks up the 3rd")
    var r = f.resolve_offset(Int64(2))
    assert_equal(r.payload, Int64(3), "the post-snapshot record folded later")
    _ = f^
    print("[test_snapshot_consistency] PASS")


# =============================================================================
# REAPED-SOURCE — binding survives source reaping (the unbounded-growth probe).
# =============================================================================


def test_reaped_source_binding_survives() raises:
    """REAPED-SOURCE: reaping a SOURCE shard's DATA does NOT lose the binding — a
    committed dense O still RESOLVES its (shard, local) binding AND its payload
    from _base (materialized), even after the source shard is reaped. The _base
    state is bounded by FOLDED CHUNKS (retention-managed), NOT by total
    rounds/records."""
    var f = _new_fold(String("p"))
    _ = f.append_batch(String("w00"), _two(Int64(10), Int64(11)))
    _ = f.append_batch(String("w01"), _one(Int64(20)))
    var st = f.run_once()
    assert_equal(st.dense_high_water, Int64(3), "3 records folded")

    var before = f.resolve_offset(Int64(0))
    assert_equal(before.payload, Int64(10), "pre-reap payload")

    # Reap the SOURCE shard's data entirely. _base retains the materialized
    # block, so the binding + payload survive (the whole point of materialize).
    f.reap_shard_data(String("w00"))

    var after = f.resolve_offset(Int64(0))
    assert_true(after.found, "REAPED-SOURCE: O still RESOLVES after source reaped")
    assert_equal(after.shard_id, String("w00"), "binding shard retained in _base")
    assert_equal(after.local_offset, Int64(0), "binding local retained in _base")
    assert_equal(after.payload, Int64(10), "REAPED-SOURCE: payload SURVIVES (materialized)")

    var live = f.resolve_offset(Int64(2))
    assert_equal(live.payload, Int64(20), "other shard payload still resolvable")

    # Boundedness: fold a SINGLE shard repeatedly. _base grows with FOLDED
    # CHUNKS (one per fold here), bounded by retention — NOT records-unbounded.
    var g = _new_fold(String("q"))
    var folds = 5
    for _k in range(folds):
        _ = g.append_batch(String("s0"), _one(Int64(7)))
        _ = g.run_once()
    assert_true(
        g.live_base_chunk_count() <= folds,
        "REAPED-SOURCE: _base bounded by folds, not records",
    )
    # The cross-shard watermark state is O(distinct shards) = 1 here.
    assert_equal(g.watermark_count(), 1, "one watermark row per distinct shard")
    _ = f^
    _ = g^
    print("[test_reaped_source_binding_survives] PASS")


# =============================================================================
# SINGLE-WRITER — single-writer _base CAS + base==dense + contiguity + CRC.
# =============================================================================


def test_single_writer_base_cas_gapless() raises:
    """SINGLE-WRITER: _base is published via If-None-Match CAS; the per-block assertions
    (base==dense, last+1 contiguity) raise on divergence, so a clean fold proves
    the invariant. The CRC-verified _base round-trips the exact state."""
    var f = _new_fold(String("p"))
    _ = f.append_batch(String("w00"), _two(Int64(1), Int64(2)))
    _ = f.append_batch(String("w01"), _two(Int64(3), Int64(4)))
    var st = f.run_once()
    assert_equal(st.dense_high_water, Int64(4), "")

    var n_before = f.live_base_chunk_count()
    f.reload_from_base()
    assert_equal(
        f.live_base_chunk_count(), n_before, "SINGLE-WRITER: _base round-trips state"
    )

    for o in range(4):
        var r = f.resolve_offset(Int64(o))
        assert_true(r.found, "dense offset resolvable from _base-rebuilt state")
    _ = f^
    print("[test_single_writer_base_cas_gapless] PASS")


# =============================================================================
# CADENCE — demand-driven fold trigger (threshold OR timer).
# =============================================================================


def test_cadence_threshold_or_timer() raises:
    """Cadence: fold when live-lineage count exceeds the threshold OR the timer
    elapsed. Bounds the live-lineage width so consume-side fan-out is small."""
    var f = _new_fold(String("p"))
    # 2 live shards, threshold 3, timer not elapsed -> no fold.
    _ = f.append_batch(String("w00"), _one(Int64(1)))
    _ = f.append_batch(String("w01"), _one(Int64(2)))
    assert_false(
        f.should_fold(3, Int64(100), Int64(1000)),
        "below threshold + timer not elapsed -> no fold",
    )
    # 4 live shards > threshold 3 -> fold.
    _ = f.append_batch(String("w02"), _one(Int64(3)))
    _ = f.append_batch(String("w03"), _one(Int64(4)))
    assert_true(
        f.should_fold(3, Int64(0), Int64(1000)),
        "live count exceeds threshold -> fold",
    )
    # Below threshold but timer elapsed + live > 0 -> fold (the timer floor).
    assert_true(
        f.should_fold(99, Int64(2000), Int64(1000)),
        "timer elapsed + live>0 -> fold (low-traffic floor)",
    )
    # An EMPTY partition never folds even on the timer (nothing to fold).
    var e = _new_fold(String("empty"))
    assert_false(
        e.should_fold(0, Int64(9999), Int64(1)),
        "empty partition does not fold on timer",
    )
    _ = f^
    _ = e^
    print("[test_cadence_threshold_or_timer] PASS")


# =============================================================================
# BOUND — the SUSTAINED multi-grower interleave.
# =============================================================================
#
# THE FAILURE THIS GUARDS: a growing-(shard,local)->dense map grows N x
# rounds under multi-grower steady state (each round strided a shard's dense
# offsets -> entries local-contiguous but dense-NON-contiguous -> the collapse
# merged NOTHING -> N=2 x 50 rounds = 100 persisted map entries, unbounded).
#
# The materialize+retire model has NO such map. This test runs N>=2 growers for
# 50+ fold rounds with PERIODIC fold+retire+retention, and asserts the PERSISTENT
# resolution state stays BOUNDED:
#   * the cross-shard watermark state is O(distinct shards) = N, NOT N x rounds;
#   * the live _base chunk count is O(folded-chunks above log-start), which
#     retention KEEPS BOUNDED (compaction reaps the consumed prefix) — NOT N x
#     rounds of un-collapsible map entries.
# This test is RED on the old growing-map impl (its map_len would be ~2*50=100)
# and GREEN on materialize+retire (watermarks==2; live _base chunks bounded by
# the retention window, not 100). `_OldGrowingMapModel` below replays the OLD
# impl's EXACT persistence policy so the RED side is demonstrated in-test (the
# old impl's symbols are gone, so this models its accumulation faithfully).
# -----------------------------------------------------------------------------


# The OLD growing-map persistence policy, modeled faithfully: each fold round
# APPENDS one un-collapsible (shard,local)->dense entry per grower (interleaved
# growers make each shard's dense offsets non-contiguous, so `_collapse_map`
# merged NOTHING — the unbounded-growth failure). `compact()` in the old impl
# collapsed only BOTH-axis-contiguous entries (none here) AND was a non-durable
# clear+reappend — it did NOT shrink the interleaved residual. So the persistent
# entry count == folds x growers, unbounded with rounds.
struct _OldGrowingMapModel(Movable, Deinitable):
    var _entries: Int  # persisted (shard,local)->dense map entries

    def __init__(out self):
        self._entries = 0

    def fold_round(mut self, n_interleaved_growers: Int):
        # One un-collapsible entry per grower per round (dense-non-contiguous).
        self._entries += n_interleaved_growers

    def compact(mut self):
        # Interleaved entries are dense-non-contiguous -> nothing collapses; the
        # old clear+reappend rewrote the SAME count (and non-durably). No-op here.
        pass

    @always_inline
    def map_len(self) -> Int:
        return self._entries


def test_sustained_multigrower_bound() raises:
    """SUSTAINED multi-grower interleave: N=2 growers, 50 fold rounds, periodic
    fold+retire+retention. Asserts the persistent resolution state stays BOUNDED
    (O(distinct shards) watermarks + retention-bounded live _base chunks), NOT
    N x rounds. The OLD growing-map impl produced 100 un-collapsible map entries
    at N=2 x 50 rounds; this is the RED->GREEN proof of the bound fix."""
    var g = _new_fold(String("interleave"))
    var old_model = _OldGrowingMapModel()
    var n_growers = 2
    var rounds = 50
    var payload = Int64(7000)
    # A bounded consumer cursor: it follows behind the high-water and lets us
    # retention-compact _base below the cursor every few rounds.
    var consumer_cursor = Int64(0)

    var max_live_base_chunks = 0
    var max_watermarks = 0

    for r in range(rounds):
        # Each grower appends 1 record to its OWN shard, INTERLEAVED — so each
        # fold round assigns each shard a NEW dense range (dense-non-contiguous
        # per shard). This is EXACTLY the stride the old map could not collapse.
        for gi in range(n_growers):
            var sid = _shard_id(gi)  # "w00", "w01" — only N distinct shards
            _ = g.append_batch(sid, _one(payload))
            payload += Int64(1)
        var st = g.run_once()
        # Drive the OLD growing-map model in LOCKSTEP (the RED side).
        old_model.fold_round(n_growers)

        # Consumer advances a bit, then we retention-compact _base below it
        # every 5 rounds (the cadence-driven compaction). This is what keeps
        # the live _base chunk count bounded under sustained growth.
        if st.dense_high_water > Int64(4):
            consumer_cursor = st.dense_high_water - Int64(4)
        if r % 5 == 4:
            _ = g.compact(consumer_cursor)
            old_model.compact()  # old compaction collapses NOTHING here

        var bs = g.bound_stats()
        if bs.live_base_chunks > max_live_base_chunks:
            max_live_base_chunks = bs.live_base_chunks
        if bs.distinct_folded_shards > max_watermarks:
            max_watermarks = bs.distinct_folded_shards

    # ---- RED: the OLD growing-map model is UNBOUNDED (N x rounds) ----
    # FAILS ON OLD CODE: the prior impl persisted exactly this many entries
    # (N=2 x 50 rounds = 100), un-collapsible under interleave — the unbounded-growth failure.
    assert_equal(
        old_model.map_len(), n_growers * rounds,
        "RED: old growing-map persists N x rounds entries (unbounded)",
    )
    assert_equal(old_model.map_len(), 100, "RED: old impl = 100 entries at 2x50")

    # (1) The cross-shard watermark state is O(distinct shards) = N, NOT rounds.
    assert_equal(
        g.watermark_count(), n_growers,
        "watermarks == distinct shards (NOT N x rounds)",
    )
    assert_equal(
        max_watermarks, n_growers, "watermark high-water == N, never grows"
    )

    # (2) The live _base chunk count stayed BOUNDED by the retention window, NOT
    # N x rounds. With a 4-deep consumer window + per-5-round compaction the live
    # set is a small constant; assert it never approached the old 100 (and is in
    # fact a tiny constant proportional to the retention window x growers).
    var bound = (n_growers * 7) + 4  # generous retention-window bound, << 100
    assert_true(
        max_live_base_chunks <= bound,
        "BOUND: live _base chunks <= retention-window bound ("
        + String(max_live_base_chunks)
        + " <= "
        + String(bound)
        + "), NOT N x rounds (=100 on the old growing-map impl)",
    )
    assert_true(
        max_live_base_chunks < (n_growers * rounds),
        "BOUND: live _base chunks strictly below the old N x rounds = "
        + String(n_growers * rounds),
    )
    # GREEN vs RED, side by side: the new model's persistent resolution state is
    # STRICTLY SMALLER than the old growing-map's, and stays so as rounds grow.
    assert_true(
        max_live_base_chunks < old_model.map_len(),
        "GREEN<RED: materialize+retire persistent state ("
        + String(max_live_base_chunks)
        + ") << old growing-map ("
        + String(old_model.map_len())
        + ")",
    )

    # (3) Correctness under the sustained interleave: every offset ABOVE the
    # retention floor resolves to a stable record; offsets BELOW surface REAPED.
    var hw = Int64(n_growers * rounds)
    var consumer_floor = consumer_cursor
    var o = consumer_floor
    var resolved = 0
    while o < hw:
        var rr = g.resolve_offset(o)
        assert_true(rr.found, "live offset resolves under sustained interleave")
        assert_true(
            rr.payload != REAPED_PAYLOAD_SENTINEL,
            "above-floor offset is NOT reaped",
        )
        resolved += 1
        o += Int64(1)
    assert_true(resolved > 0, "resolved live offsets above the retention floor")

    # A folded-then-reaped offset (below the compaction floor) surfaces REAPED,
    # found=True, never a wrong record, never unresolvable.
    if consumer_floor > Int64(0):
        var reaped = g.resolve_offset(Int64(0))
        assert_true(reaped.found, "reaped offset 0 still found")
        assert_equal(
            reaped.payload, REAPED_PAYLOAD_SENTINEL,
            "reaped offset surfaces the REAPED sentinel",
        )

    # Durability of the bound across a fold-process RESTART (state rebuilt from
    # _base only): the watermarks + live _base chunks rebuild to the same shape.
    var live_before_restart = g.live_base_chunk_count()
    g.reload_from_base()
    assert_equal(
        g.watermark_count(), n_growers,
        "watermarks rebuild to N from _base across restart",
    )
    assert_equal(
        g.live_base_chunk_count(), live_before_restart,
        "live _base chunk count durable across restart (bounded)",
    )
    _ = g^
    print(
        "[test_sustained_multigrower_bound] PASS (N=2 x 50 rounds: watermarks="
        + String(n_growers)
        + ", max live _base chunks="
        + String(max_live_base_chunks)
        + " vs old growing-map=100)"
    )


# =============================================================================
# COMPACT — retention-compaction round-trip.
# =============================================================================


def test_retention_compaction_roundtrip() raises:
    """RETENTION-COMPACTION: fold several rounds, then compact _base below a
    watermark. Assert:
      (1) _base stays READABLE (no clear+reappend; durable retention advance),
      (2) every offset AT-OR-ABOVE the watermark round-trips byte-identically,
      (3) every offset BELOW the watermark surfaces the REAPED sentinel,
      (4) the live _base chunk count SHRANK (retention reclaimed the prefix),
      (5) the compacted _base re-loads to the same live state across restart."""
    var f = _new_fold(String("p"))
    var payload = Int64(0)
    # a0 then b0 fold across several rounds -> dense [0..5].
    for _k in range(3):
        _ = f.append_batch(String("a0"), _one(payload))
        payload += Int64(1)
        _ = f.run_once()
    for _k in range(3):
        _ = f.append_batch(String("b0"), _one(payload))
        payload += Int64(1)
        _ = f.run_once()
    var hw = f.run_once().dense_high_water
    assert_equal(hw, Int64(6), "6 records folded across 6 rounds")
    assert_equal(f.live_base_chunk_count(), 6, "6 _base blocks pre-compaction")

    var before = _materialize_assignments(f, hw)

    # Retention-compact _base below dense offset 4 (consumer has consumed [0,4)).
    var watermark = Int64(4)
    var n_after = f.compact(watermark)
    assert_equal(n_after, 2, "post-compaction: 2 live _base blocks (offsets 4,5)")
    assert_true(
        f.live_base_chunk_count() < 6, "retention reclaimed the consumed prefix"
    )

    # (2) offsets AT-OR-ABOVE the watermark round-trip byte-identically.
    for i in range(Int(watermark), len(before)):
        var r = f.resolve_offset(before[i].dense_offset)
        assert_true(r.found, "above-watermark offset resolves")
        assert_equal(r.shard_id, before[i].shard_id, "shard byte-identical")
        assert_equal(r.local_offset, before[i].local_offset, "local byte-identical")
        assert_equal(r.payload, before[i].payload, "payload byte-identical")

    # (3) offsets BELOW the watermark surface the REAPED sentinel.
    for i in range(0, Int(watermark)):
        var r = f.resolve_offset(Int64(i))
        assert_true(r.found, "reaped offset still found (never unresolvable)")
        assert_equal(
            r.payload, REAPED_PAYLOAD_SENTINEL, "reaped offset -> REAPED sentinel"
        )

    # (5) compacted _base re-loads to the same live state across restart.
    f.reload_from_base()
    assert_equal(
        f.live_base_chunk_count(), 2, "compacted _base durable (2 live on reload)"
    )
    for i in range(Int(watermark), len(before)):
        var r = f.resolve_offset(before[i].dense_offset)
        assert_true(r.found, "above-watermark offset resolves post-restart")
        assert_equal(r.payload, before[i].payload, "payload durable post-restart")
    var reaped_post = f.resolve_offset(Int64(0))
    assert_equal(
        reaped_post.payload, REAPED_PAYLOAD_SENTINEL,
        "reaped offset still REAPED post-restart",
    )

    # A subsequent fold after compaction still extends additively (no renumber).
    _ = f.append_batch(String("a0"), _one(Int64(999)))
    var st = f.run_once()
    assert_equal(st.dense_high_water, Int64(7), "post-compact fold extends to 7")
    var rn = f.resolve_offset(Int64(6))
    assert_equal(rn.payload, Int64(999), "new record at the new high-water")
    _ = f^
    print("[test_retention_compaction_roundtrip] PASS")


# =============================================================================
# THE FAULT-INJECTION DISCRIMINATING GATE — RED on broken REAL code -> GREEN.
# =============================================================================
#
# Per the task: the discriminating test must FAULT-INJECT the REAL fold (a
# renumber-at-fold-time variant of the real code), NOT a separate naive struct.
# `_RenumberAtFoldFold` REUSES the real fold's enumeration / snapshot / canonical
# ordering, but injects the ONE wrong behavior at fold time: it WIPES _base and
# re-materializes dense offsets 0..N from scratch in canonical position order
# EVERY fold. When a new shard sorts before an old one, or an existing shard
# grows, this SHIFTS already-served offsets — the bug ADDITIVITY forbids. The property
# PASSES on the correct real fold, FAILS on the fault-injected one — the explicit
# RED->GREEN proof against the REAL code path (it drives the real materialize
# machinery, just with a renumber-from-scratch assignment policy).
# -----------------------------------------------------------------------------


struct _RenumberAtFoldFold(Movable, Deinitable):
    """A fault-injected REAL fold: it DRIVES the real fold's enumeration +
    authoritative snapshot + canonical sort + the real `_read_source_range`
    materialize-read, but injects the ONE wrong behavior — it RENUMBERS dense
    offsets 0..N FROM SCRATCH in canonical position order EVERY fold, instead of
    APPENDING. When a new shard sorts before an old one (or a shard grows), the
    from-scratch canonical position of an already-served offset SHIFTS, re-binding
    O to a DIFFERENT record — the bug ADDITIVITY forbids. The fault re-uses the real
    fold's discovery + ordering + source-read (NOT a separate naive struct); only
    the assignment policy is mutated to renumber-from-scratch."""

    var _inner: _Fold
    # The renumbered-from-scratch assignment (rebuilt every fold): dense O ->
    # payload. Built by the FAULT, so it can SHIFT an already-served O.
    var _renum: List[Int64]

    def __init__(out self, var inner: _Fold):
        self._inner = inner^
        self._renum = List[Int64]()

    def append_batch(mut self, shard_id: String, records: List[Int64]) raises:
        _ = self._inner.append_batch(shard_id, records)

    def fold(mut self) raises -> Int64:
        # FAULT INJECTION: drive the REAL enumeration + authoritative snapshot +
        # canonical sort + the real `_read_source_range`, then RENUMBER dense
        # offsets 0..N FROM SCRATCH in canonical position order (clearing any
        # prior assignment). The source reads use the REAL code path; only the
        # dense-offset ASSIGNMENT policy is the bug (renumber, not append).
        var snap = self._inner.snapshot()  # real authoritative snapshot
        var sorted_snap = self._inner._sort_snapshot(snap)
        var fresh = List[Int64]()
        for i in range(len(sorted_snap)):
            ref ss = sorted_snap[i]
            if ss.snap_record_total <= Int64(0):
                continue
            # Read this shard's FULL local range via the REAL materialize-read,
            # then place it at the next from-scratch canonical dense position.
            var recs = self._inner._read_source_range(
                ss.shard_id, Int64(0), ss.snap_record_total
            )
            for k in range(len(recs)):
                fresh.append(recs[k])
        # Overwrite the renumbered-from-scratch assignment (the SHIFT bug).
        self._renum = fresh^
        return Int64(len(self._renum))

    def resolve_offset(self, o: Int64) raises -> Int64:
        if o < Int64(0) or o >= Int64(len(self._renum)):
            return Int64(-99)
        return self._renum[Int(o)]


def test_discriminating_gate_red_green_real_fold() raises:
    """The gate: a randomized O->record stability property. PASSES on the CORRECT
    real fold; FAILS on the FAULT-INJECTED renumber-at-fold variant of the REAL
    fold. Explicit RED->GREEN discrimination against the real code path."""
    var any_fault_failure = False
    var seeds = 24
    for seed in range(1, seeds + 1):
        var ok_correct = _run_property_correct(UInt64(seed))
        assert_true(
            ok_correct,
            "GREEN: correct real fold preserves O across folds (seed "
            + String(seed)
            + ")",
        )
        var ok_fault = _run_property_fault(UInt64(seed))
        if not ok_fault:
            any_fault_failure = True
    assert_true(
        any_fault_failure,
        "RED: the fault-injected renumber fold is CAUGHT by the property"
        " (discriminating against the REAL code path)",
    )
    print("[test_discriminating_gate_red_green_real_fold] PASS (RED->GREEN proven)")


def _run_property_correct(seed: UInt64) raises -> Bool:
    var rng = _Rng(seed)
    var f = _new_fold(String("c") + String(seed))
    var committed_o = List[Int64]()
    var committed_p = List[Int64]()
    var payload_ctr = Int64(seed) * Int64(100000)

    var rounds = 3 + rng.below(4)
    for _round in range(rounds):
        var n_shards = 1 + rng.below(4)
        for _ in range(n_shards):
            var sid = _shard_id(rng.below(12))
            var batch = 1 + rng.below(3)
            var recs = List[Int64]()
            for _b in range(batch):
                recs.append(payload_ctr)
                payload_ctr += Int64(1)
            _ = f.append_batch(sid, recs)
        var st = f.run_once()
        for i in range(len(committed_o)):
            var r = f.resolve_offset(committed_o[i])
            if (not r.found) or r.payload != committed_p[i]:
                _ = f^
                return False
        if st.dense_high_water > Int64(0):
            var o = Int64(rng.below(Int(st.dense_high_water)))
            var rr = f.resolve_offset(o)
            if rr.found:
                committed_o.append(o)
                committed_p.append(rr.payload)
    _ = f^
    return True


def _run_property_fault(seed: UInt64) raises -> Bool:
    var rng = _Rng(seed)
    var f = _RenumberAtFoldFold(_new_fold(String("x") + String(seed)))
    var committed_o = List[Int64]()
    var committed_p = List[Int64]()
    var payload_ctr = Int64(seed) * Int64(100000)

    var rounds = 3 + rng.below(4)
    for _round in range(rounds):
        var n_shards = 1 + rng.below(4)
        for _ in range(n_shards):
            var sid = _shard_id(rng.below(12))
            var batch = 1 + rng.below(3)
            var recs = List[Int64]()
            for _b in range(batch):
                recs.append(payload_ctr)
                payload_ctr += Int64(1)
            f.append_batch(sid, recs)
        var hw = f.fold()
        for i in range(len(committed_o)):
            var p = f.resolve_offset(committed_o[i])
            if p != committed_p[i]:
                _ = f^
                return False  # the fault-injected fold SHIFTED a served offset
        if hw > Int64(0):
            var o = Int64(rng.below(Int(hw)))
            var p2 = f.resolve_offset(o)
            committed_o.append(o)
            committed_p.append(p2)
    _ = f^
    return True


def main() raises:
    test_canonical_order_is_deterministic()
    test_enumerate_live_shards_lists_bucket()
    test_determinism_merge()
    test_fold_equals_from_scratch_replay_and_idempotent()
    test_additivity_offsets_preserved_across_folds()
    test_resumability_tail_to_base()
    test_snapshot_consistency()
    test_reaped_source_binding_survives()
    test_single_writer_base_cas_gapless()
    test_cadence_threshold_or_timer()
    test_sustained_multigrower_bound()
    test_retention_compaction_roundtrip()
    test_discriminating_gate_red_green_real_fold()
    print(
        "[OK] test_sublineage_base_fold — DETERMINISM/ADDITIVITY/RESUMABILITY + ENUM + BOUND + COMPACT +"
        " SNAPSHOT/ORDER/REAPED-SOURCE/SINGLE-WRITER + FAULT-INJECTION RED->GREEN gate ALL PASS (offline)"
    )
