# =============================================================================
# src/komira_table_store/tests/test_group_commit_conflict_fuzz.mojo
#   MANDATORY adversarial conflict-FUZZ for table store GROUP-COMMIT.
#   The HIGHEST-RISK surface: a missed key-intersection in the codec's
#   arbitration / per-member OCC is a SILENT LOST-UPDATE.
# =============================================================================
#
# The crux of Phase-3 is `PgGroupCommitCodec.encode`: it folds (1) intra-batch
# arbitration (first-in-batch-wins) + (2) per-member OCC vs the durable head +
# (3) the winners' write-set MERGE into ONE chunk body. A bug in (1) or (2) does
# NOT crash — it silently merges TWO conflicting writes for the SAME key into one
# chunk = a lost update that no later read can detect. So the gate is a RANDOMIZED
# fuzz against an INDEPENDENT reference model:
#
#   * REFERENCE MODEL (the spec, hand-written, dead-simple, obviously correct):
#     for N members with arbitrary overlapping/disjoint key sets, the EXPECTED
#     winner set is exactly the FIRST claimant per key (FIRST-IN-BATCH-WINS over
#     the drain order). A member whose write-set touches ANY key already claimed
#     by an EARLIER surviving member is a LOSER (40001). Members with a stale
#     snapshot (a committed competitor under their snapshot) are OCC losers.
#
#   * THE ASSERTIONS (per random batch):
#     - NO LOST UPDATE: every key in the merged chunk body is written by exactly
#       ONE winner (no key appears twice in the merged write-set).
#     - EXACTLY-ONE-WINNER-PER-KEY: the set of keys in the merged body == the set
#       of keys the reference model says the winners own.
#     - LOSERS GET 40001: every member the reference says loses has a loser
#       outcome (PG_GC_LOSS_INTRA or PG_GC_LOSS_OCC); every winner has a winner
#       index; the win/loss partition is COMPLETE (every member in exactly one).
#
# A missed intersection would (a) put a second write for a claimed key into the
# merged body (NO-LOST-UPDATE fails) AND (b) report a member as a winner the
# reference says loses (EXACTLY-ONE fails) — caught either way.
#
# RED→GREEN provenance: a stubbed arbitration that ALWAYS returns "all winners"
# (the lost-update bug) is exercised by `test_red_all_winners_stub_is_a_lost_
# update` — it asserts the reference model + the no-lost-update predicate FIRE on
# that stub (so the fuzz is not a tautology; it genuinely discriminates a missed
# key-intersection).
#
# This drives the CODEC LOGIC DIRECTLY (arbitrate_intra_batch + encode over a
# real CasManifestStore with seeded competitor chunks for the OCC arm) — the
# fastest, most deterministic way to fuzz the highest-risk surface. The e2e
# coalesce + crash-atomicity tests are separate files.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_core.collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.coalescing_window import EncodedBatch

from komira_table_store.table_store_codec import (
    PG_OP_PUT,
    WriteOp,
    bytes_eq,
    decode_commit_chunk,
    encode_commit_chunk,
)
from komira_table_store.group_commit import (
    PG_GC_LOSS_INTRA,
    PG_GC_LOSS_OCC,
    PG_GC_WIN,
    PgGroupCommitCodec,
    PgGroupCommitItem,
    PgGroupHead,
    PgGroupOutcome,
    arbitrate_intra_batch,
)


comptime _Store = SharedInMemorySlowCasStore


# =============================================================================
# Helpers.
# =============================================================================


def _key(n: Int) -> List[UInt8]:
    """A deterministic 4-byte key from a small int (mirrors a table key prefix —
    a heap-lineage ordinal + a row id). Distinct ints => distinct keys."""
    var out = List[UInt8]()
    out.append(UInt8(0))
    out.append(UInt8(0))
    out.append(UInt8((n >> 8) & 0xFF))
    out.append(UInt8(n & 0xFF))
    return out^


def _row(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(n & 0xFF))
    return out^


def _member_l(snapshot: Int64, keys: List[Int]) -> PgGroupCommitItem:
    """A member that writes `keys` (each a PUT) at `snapshot`."""
    var ws = List[WriteOp]()
    for i in range(len(keys)):
        ws.append(WriteOp(PG_OP_PUT, _key(keys[i]), _row(keys[i])))
    return PgGroupCommitItem(snapshot, ws^)


def _member(snapshot: Int64, *ks: Int) -> PgGroupCommitItem:
    """A member that writes the variadic `ks` keys (each a PUT) at `snapshot`."""
    var keys = List[Int]()
    for i in range(len(ks)):
        keys.append(ks[i])
    return _member_l(snapshot, keys)


def _slab_of(items: List[PgGroupCommitItem]) raises -> Slab[PgGroupCommitItem]:
    var s = Slab[PgGroupCommitItem]()
    for i in range(len(items)):
        s.append(items[i].copy())
    return s^


# A tiny deterministic xorshift PRNG (the fuzz seed sweep is reproducible).
struct _Rng(Movable, Deinitable):
    var _s: UInt64

    def __init__(out self, seed: UInt64):
        self._s = seed | UInt64(1)

    def next(mut self) -> UInt64:
        var x = self._s
        x ^= x << UInt64(13)
        x ^= x >> UInt64(7)
        x ^= x << UInt64(17)
        self._s = x
        return x

    def below(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(n))


# =============================================================================
# The REFERENCE MODEL — first-in-batch-wins, hand-written, obviously correct.
# =============================================================================


def _ref_expected_winner_keys(items: List[PgGroupCommitItem]) raises -> List[Int]:
    """The reference set of (raw int) keys the winners SHOULD own, computed
    independently of the codec: walk members in drain order; a member SURVIVES
    iff none of its keys is already claimed by an earlier survivor; a survivor
    claims all its keys. Returns the claimed key ints in claim order. This is the
    SPEC the codec's intra-batch arbitration must match (the OCC arm is tested
    separately with seeded competitor chunks)."""
    var claimed = List[Int]()
    for i in range(len(items)):
        # Does member i intersect an already-claimed key?
        var intersects = False
        for wi in range(len(items[i].write_set)):
            var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                items[i].write_set[wi].key[3]
            )
            for cj in range(len(claimed)):
                if claimed[cj] == k:
                    intersects = True
                    break
            if intersects:
                break
        if intersects:
            continue
        # Survivor — claim all its keys.
        for wi in range(len(items[i].write_set)):
            var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                items[i].write_set[wi].key[3]
            )
            claimed.append(k)
    return claimed^


def _ref_survives_mask(items: List[PgGroupCommitItem]) raises -> List[Bool]:
    """The reference survives[i] mask (first-in-batch-wins) — the same logic as
    _ref_expected_winner_keys but returning the per-member partition."""
    var survives = List[Bool]()
    var claimed = List[Int]()
    for i in range(len(items)):
        var intersects = False
        for wi in range(len(items[i].write_set)):
            var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                items[i].write_set[wi].key[3]
            )
            for cj in range(len(claimed)):
                if claimed[cj] == k:
                    intersects = True
                    break
            if intersects:
                break
        if intersects:
            survives.append(False)
            continue
        survives.append(True)
        for wi in range(len(items[i].write_set)):
            var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                items[i].write_set[wi].key[3]
            )
            claimed.append(k)
    return survives^


def _merged_keys(body: List[UInt8]) raises -> List[Int]:
    """Decode the merged chunk body and return the raw int keys it carries."""
    var chunk = decode_commit_chunk(body)
    var out = List[Int]()
    for i in range(len(chunk.write_set)):
        out.append(
            Int(chunk.write_set[i].key[2]) * 256
            + Int(chunk.write_set[i].key[3])
        )
    return out^


def _new_empty_codec() raises -> PgGroupCommitCodec[_Store]:
    """A codec over an EMPTY WAL (auth head = -1, no committed competitor chunks)
    — the per-member OCC arm is a no-op, so encode tests ONLY the intra-batch
    arbitration + merge (the OCC arm has its own seeded test)."""
    var slow = SharedInMemorySlowCasStore(slow_ticks=0)
    var wal = CasManifestStore[_Store](
        store=slow^, prefix=String("pg/fuzz"), retry=RetryPolicy.fast_test()
    )
    return PgGroupCommitCodec[_Store](wal^)


# =============================================================================
# Test 1 — the conflict-FUZZ (the mandatory adversarial test).
# =============================================================================


def test_conflict_fuzz_no_lost_update_exactly_one_winner_per_key() raises:
    """RANDOMIZED N-txn batches with overlapping/disjoint key sets vs the
    reference model. For each random batch (all members snapshot=-1 so the OCC
    arm is a no-op — the intra-batch arbitration + merge is the surface):
      (a) NO LOST UPDATE — every key in the merged chunk body appears exactly
          once (no two members' conflicting writes for the same key both merged).
      (b) EXACTLY-ONE-WINNER-PER-KEY — the merged body's key set == the reference
          winner-key set.
      (c) COMPLETE PARTITION — every member is a winner XOR a loser; the codec's
          survives mask == the reference survives mask; losers carry 40001."""
    comptime KEY_SPACE = 6  # small => lots of forced collisions (adversarial).
    comptime SEEDS = 400
    for seed in range(1, SEEDS + 1):
        var rng = _Rng(UInt64(seed) * UInt64(2654435761))
        var n = 2 + rng.below(6)  # 2..7 members.
        var items = List[PgGroupCommitItem]()
        for _ in range(n):
            var nk = 1 + rng.below(3)  # 1..3 keys per member.
            var keys = List[Int]()
            for _ in range(nk):
                var k = rng.below(KEY_SPACE)
                # dedup within a member (a txn's write-set is key-deduped).
                var dup = False
                for j in range(len(keys)):
                    if keys[j] == k:
                        dup = True
                        break
                if not dup:
                    keys.append(k)
            items.append(_member_l(Int64(-1), keys))

        # Drive the codec (encode over an empty WAL — OCC arm no-op).
        var codec = _new_empty_codec()
        var slab = _slab_of(items)
        var batch = codec.encode(slab, PgGroupHead(Int64(-1), Int64(0)))

        # (a) NO LOST UPDATE — every merged key appears exactly once.
        var merged = _merged_keys(batch.body)
        for a in range(len(merged)):
            var cnt = 0
            for b in range(len(merged)):
                if merged[b] == merged[a]:
                    cnt += 1
            assert_equal(
                cnt,
                1,
                String("seed ")
                + String(seed)
                + ": LOST UPDATE — key "
                + String(merged[a])
                + " appears "
                + String(cnt)
                + " times in the merged chunk",
            )

        # (b) EXACTLY-ONE-WINNER-PER-KEY — merged key set == reference set.
        var ref_keys = _ref_expected_winner_keys(items)
        # same cardinality (the merged set has no dups by (a)).
        assert_equal(
            len(merged),
            len(ref_keys),
            String("seed ")
            + String(seed)
            + ": merged key COUNT != reference winner-key count",
        )
        for rk in range(len(ref_keys)):
            var found = False
            for mk in range(len(merged)):
                if merged[mk] == ref_keys[rk]:
                    found = True
                    break
            assert_true(
                found,
                String("seed ")
                + String(seed)
                + ": reference winner key "
                + String(ref_keys[rk])
                + " MISSING from the merged chunk (lost update / dropped winner)",
            )

        # (c) COMPLETE PARTITION + survives mask matches the reference.
        var ref_survives = _ref_survives_mask(items)
        # Build a per-member outcome map from the EncodedBatch (winner_idxs +
        # loser_outcomes cover every index exactly once).
        var is_winner = List[Bool]()
        for _ in range(n):
            is_winner.append(False)
        for wi in range(len(batch.winner_idxs)):
            is_winner[batch.winner_idxs[wi]] = True
        var loser_seen = List[Bool]()
        for _ in range(n):
            loser_seen.append(False)
        for li in range(len(batch.loser_outcomes)):
            ref pair = batch.loser_outcomes[li]
            loser_seen[pair[0]] = True
            # a loser carries an INTRA or OCC kind (40001), never a WIN.
            assert_true(
                pair[1].kind == PG_GC_LOSS_INTRA
                or pair[1].kind == PG_GC_LOSS_OCC,
                String("seed ")
                + String(seed)
                + ": loser member "
                + String(pair[0])
                + " carries a non-40001 kind",
            )
        for i in range(n):
            # Exactly one of winner / loser per member (complete partition).
            assert_true(
                is_winner[i] != loser_seen[i],
                String("seed ")
                + String(seed)
                + ": member "
                + String(i)
                + " is not in exactly one of {winner, loser}",
            )
            # And the partition matches the reference first-in-batch-wins mask.
            assert_equal(
                is_winner[i],
                ref_survives[i],
                String("seed ")
                + String(seed)
                + ": member "
                + String(i)
                + " win/loss disagrees with the reference model",
            )


# =============================================================================
# Test 2 — the RED discriminator: prove the fuzz catches a lost-update.
# =============================================================================


def _all_winners_stub_merge(items: List[PgGroupCommitItem]) raises -> List[Int]:
    """The BUGGY arbitration: treat EVERY member as a winner + merge ALL their
    write-sets (no key-intersection check at all). This is the silent-lost-update
    bug the fuzz must catch. Returns the merged key ints (with dups)."""
    var merged = List[Int]()
    for i in range(len(items)):
        for wi in range(len(items[i].write_set)):
            merged.append(
                Int(items[i].write_set[wi].key[2]) * 256
                + Int(items[i].write_set[wi].key[3])
            )
    return merged^


def test_red_all_winners_stub_is_a_lost_update() raises:
    """DISCRIMINATION (RED): a stubbed arbitration that merges EVERY member's
    write-set (no intersection check) produces a DUPLICATE key in the merged body
    for a batch with an overlapping key — the no-lost-update predicate the fuzz
    asserts FIRES on it. Proves the fuzz is not a tautology: it genuinely catches
    a missed key-intersection.

    FAILS-ON-BUGGY-CODE shape: two members both write key 3; the correct codec
    merges it once (member-0 wins, member-1 is an intra-batch loser), the stub
    merges it twice. We assert the stub's merge HAS a duplicate AND the real
    codec's merge does NOT — the exact predicate that discriminates the bug."""
    var items = List[PgGroupCommitItem]()
    items.append(_member(Int64(-1), 3, 4))  # member 0: {3,4}
    items.append(_member(Int64(-1), 3, 5))  # member 1: {3,5} (3 dup!)

    # The BUGGY stub merges key 3 TWICE — a lost update.
    var stub_merged = _all_winners_stub_merge(items)
    var stub_dup = False
    for a in range(len(stub_merged)):
        var cnt = 0
        for b in range(len(stub_merged)):
            if stub_merged[b] == stub_merged[a]:
                cnt += 1
        if cnt > 1:
            stub_dup = True
            break
    assert_true(
        stub_dup,
        "the all-winners stub MUST produce a duplicate key (the lost-update bug"
        " the fuzz catches) — if not, the discriminator is broken",
    )

    # The REAL codec merges key 3 ONCE (member 1 loses intra-batch).
    var codec = _new_empty_codec()
    var slab = _slab_of(items)
    var batch = codec.encode(slab, PgGroupHead(Int64(-1), Int64(0)))
    var real_merged = _merged_keys(batch.body)
    var real_dup = False
    for a in range(len(real_merged)):
        var cnt = 0
        for b in range(len(real_merged)):
            if real_merged[b] == real_merged[a]:
                cnt += 1
        if cnt > 1:
            real_dup = True
            break
    assert_false(
        real_dup,
        "the REAL codec must NOT duplicate the overlapping key (member 1 is an"
        " intra-batch loser) — a duplicate here IS the lost-update bug",
    )
    # member 0 wins {3,4}; member 1 loses; merged = {3,4} only.
    assert_equal(len(real_merged), 2)
    assert_equal(len(batch.winner_idxs), 1)
    assert_equal(batch.winner_idxs[0], 0)
    assert_equal(len(batch.loser_outcomes), 1)
    ref lpair = batch.loser_outcomes[0]
    assert_equal(lpair[0], 1)
    assert_equal(lpair[1].kind, PG_GC_LOSS_INTRA)


# =============================================================================
# Test 3 — per-member OCC arm: a stale-snapshot member loses to a committed
# competitor chunk (the OCC loser class).
# =============================================================================


def test_per_member_occ_stale_snapshot_loses_to_committed_competitor() raises:
    """The per-member OCC arm (PG_GC_LOSS_OCC). Seed the WAL with a COMMITTED
    chunk at seq 0 touching key 7 (a competitor that landed after some member's
    snapshot). A member with snapshot=-1 (BEFORE seq 0) whose write-set touches
    key 7 must be an OCC LOSER; a member writing a DISJOINT key (key 9) at the
    same stale snapshot WINS (its keys were not touched by the competitor).

    This is the real key-intersection OCC (identical to TableStore._occ_check):
    a member's OWN snapshot vs the chunks committed in (snapshot, auth_head]."""
    # Seed a committed competitor chunk at seq 0 touching key 7.
    var slow = SharedInMemorySlowCasStore(slow_ticks=0)
    var seed_wal = CasManifestStore[_Store](
        store=slow.clone(), prefix=String("pg/occ"), retry=RetryPolicy.fast_test()
    )
    var competitor = List[WriteOp]()
    competitor.append(WriteOp(PG_OP_PUT, _key(7), _row(7)))
    # encode_commit_chunk + try_append_at_seq lands it at slot 0.
    from komira_table_store.table_store_codec import encode_commit_chunk

    var body = encode_commit_chunk(Int64(-1), competitor)
    var maybe = seed_wal.try_append_at_seq(Int64(0), Int64(0), body^, Int64(1))
    assert_true(Bool(maybe), "seed competitor chunk must land at slot 0")
    _ = maybe^

    # Now the codec sees auth_head = {chunk_seq=0}. Two members both at
    # snapshot=-1 (before the competitor): one touches key 7 (OCC loser), one
    # touches key 9 (OCC winner — disjoint from the competitor).
    var codec = PgGroupCommitCodec[_Store](
        CasManifestStore[_Store](
            slow.clone(), String("pg/occ"), RetryPolicy.fast_test()
        )
    )
    var items = List[PgGroupCommitItem]()
    items.append(_member(Int64(-1), 9))  # member 0: disjoint -> WIN
    items.append(_member(Int64(-1), 7))  # member 1: stale on 7 -> OCC LOSS
    var slab = _slab_of(items)
    var batch = codec.encode(slab, PgGroupHead(Int64(0), Int64(1)))

    # member 0 wins (key 9 not in the competitor); member 1 loses OCC (key 7 was
    # committed at seq 0 > its snapshot -1).
    assert_equal(len(batch.winner_idxs), 1)
    assert_equal(batch.winner_idxs[0], 0)
    assert_equal(len(batch.loser_outcomes), 1)
    ref lpair = batch.loser_outcomes[0]
    assert_equal(lpair[0], 1)
    assert_equal(lpair[1].kind, PG_GC_LOSS_OCC)
    # The merged body carries ONLY key 9 (the winner) — member 1's stale write to
    # key 7 is NEVER merged (no lost update against the committed competitor).
    var merged = _merged_keys(batch.body)
    assert_equal(len(merged), 1)
    assert_equal(merged[0], 9)


# =============================================================================
# Test 4 — arbitrate_intra_batch unit (the pure first-in-batch-wins helper).
# =============================================================================


def _ref_occ_combined_winner_keys(
    items: List[PgGroupCommitItem],
    committed: List[List[Int]],
) raises -> List[Int]:
    """The COMBINED reference (intra-batch arbitration + per-member OCC), computed
    independently of the codec — MIRRORING THE CODEC'S EXACT ORDER (this is
    load-bearing): `encode_group_batch` runs `arbitrate_intra_batch` over ALL
    members FIRST (an intra-batch survivor claims its keys regardless of whether it
    will later fail OCC), THEN runs per-member OCC on each intra-batch survivor +
    merges ONLY the survivors that also pass OCC. So an OCC-DOOMED intra-batch
    survivor can still BLOCK a later member from winning a shared key (the later
    member lost intra-batch to the doomed claimant), and that key ends up claimed
    by NOBODY. `committed[seq]` is the keys the competitor chunk at seq committed;
    a member with snapshot S loses OCC iff any of its keys is in committed[seq] for
    some seq in (S, auth_head] (auth_head = len(committed)-1). Returns the merged
    winner key ints in claim order. The codec's merged body must match exactly."""
    var n = len(items)
    var auth_head = len(committed) - 1

    # STEP 1: intra-batch first-in-batch-wins over ALL members (== the codec's
    # `arbitrate_intra_batch`, which is OCC-oblivious). survives_intra[i] is True
    # iff member i does not intersect an EARLIER intra-batch survivor.
    var survives_intra = List[Bool]()
    var claimed_intra = List[Int]()
    for i in range(n):
        var intersects = False
        for wi in range(len(items[i].write_set)):
            var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                items[i].write_set[wi].key[3]
            )
            for cj in range(len(claimed_intra)):
                if claimed_intra[cj] == k:
                    intersects = True
                    break
            if intersects:
                break
        if intersects:
            survives_intra.append(False)
            continue
        survives_intra.append(True)
        for wi in range(len(items[i].write_set)):
            var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                items[i].write_set[wi].key[3]
            )
            claimed_intra.append(k)

    # STEP 2: for each intra-batch survivor, per-member OCC vs (snap, auth_head].
    # The winner set = intra-batch survivors that ALSO pass OCC; merge their keys.
    var claimed = List[Int]()
    for i in range(n):
        if not survives_intra[i]:
            continue
        var snap = Int(items[i].snapshot_lsn)
        var conflict = False
        var seq = snap + 1
        while seq <= auth_head:
            if seq >= 0 and seq < len(committed):
                for wi in range(len(items[i].write_set)):
                    var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                        items[i].write_set[wi].key[3]
                    )
                    for cj in range(len(committed[seq])):
                        if committed[seq][cj] == k:
                            conflict = True
                            break
                    if conflict:
                        break
            if conflict:
                break
            seq += 1
        if conflict:
            continue  # OCC loser — does NOT enter the merged set.
        for wi in range(len(items[i].write_set)):
            var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                items[i].write_set[wi].key[3]
            )
            claimed.append(k)
    return claimed^


def test_conflict_fuzz_occ_combined_seeded_competitors() raises:
    """The OCC-COMBINED conflict FUZZ (MEDIUM): the original fuzz
    is empty-WAL arbitration-only (OCC is a single hand case). This variant seeds
    RANDOM committed competitor chunks into the WAL, gives members MIXED snapshots,
    and overlapping keys — so a member can lose to (a) an EARLIER intra-batch
    survivor OR (b) a committed competitor above its snapshot. The reference model
    `_ref_occ_combined_winner_keys` computes BOTH loss classes; the codec's merged
    body must match it exactly (NO LOST UPDATE — no merged key is one a competitor
    already committed above some winner's snapshot, no two winners share a key)."""
    comptime KEY_SPACE = 6
    comptime SEEDS = 200
    for seed in range(1, SEEDS + 1):
        var rng = _Rng(UInt64(seed) * UInt64(40503) + UInt64(7))
        # Seed C committed competitor chunks (0..C-1). Each touches 1..2 keys.
        var n_comp = 1 + rng.below(3)  # 1..3 competitor chunks.
        var slow = SharedInMemorySlowCasStore(slow_ticks=0)
        var seed_wal = CasManifestStore[_Store](
            store=slow.clone(),
            prefix=String("pg/occfuzz"),
            retry=RetryPolicy.fast_test(),
        )
        var committed = List[List[Int]]()
        for c in range(n_comp):
            var ck = 1 + rng.below(2)  # 1..2 keys in this competitor.
            var comp_keys = List[Int]()
            var comp_ws = List[WriteOp]()
            for _ in range(ck):
                var k = rng.below(KEY_SPACE)
                var dup = False
                for j in range(len(comp_keys)):
                    if comp_keys[j] == k:
                        dup = True
                        break
                if not dup:
                    comp_keys.append(k)
                    comp_ws.append(WriteOp(PG_OP_PUT, _key(k), _row(k)))
            var body = encode_commit_chunk(Int64(c - 1), comp_ws)
            var maybe = seed_wal.try_append_at_seq(
                Int64(c), Int64(c), body^, Int64(len(comp_keys))
            )
            assert_true(Bool(maybe), "seed competitor chunk must land")
            _ = maybe^
            committed.append(comp_keys^)
        var auth_head_seq = Int64(n_comp - 1)

        # Build N members with MIXED snapshots in [-1, auth_head] + overlapping keys.
        var nmem = 2 + rng.below(5)  # 2..6 members.
        var items = List[PgGroupCommitItem]()
        for _ in range(nmem):
            var snap = Int64(rng.below(n_comp + 1) - 1)  # -1..auth_head
            var nk = 1 + rng.below(3)
            var keys = List[Int]()
            for _ in range(nk):
                var k = rng.below(KEY_SPACE)
                var dup = False
                for j in range(len(keys)):
                    if keys[j] == k:
                        dup = True
                        break
                if not dup:
                    keys.append(k)
            items.append(_member_l(snap, keys))

        # Drive the codec over the seeded WAL.
        var codec = PgGroupCommitCodec[_Store](
            CasManifestStore[_Store](
                slow.clone(), String("pg/occfuzz"), RetryPolicy.fast_test()
            )
        )
        var slab = _slab_of(items)
        var batch = codec.encode(
            slab, PgGroupHead(auth_head_seq, Int64(n_comp))
        )
        var merged = _merged_keys(batch.body)

        # (a) NO LOST UPDATE — every merged key appears exactly once.
        for a in range(len(merged)):
            var cnt = 0
            for b in range(len(merged)):
                if merged[b] == merged[a]:
                    cnt += 1
            assert_equal(
                cnt,
                1,
                String("occ-seed ")
                + String(seed)
                + ": LOST UPDATE — merged key "
                + String(merged[a])
                + " appears "
                + String(cnt)
                + " times",
            )

        # (b) MERGED KEY SET == the COMBINED reference (intra-batch + OCC).
        var ref_keys = _ref_occ_combined_winner_keys(items, committed)
        assert_equal(
            len(merged),
            len(ref_keys),
            String("occ-seed ")
            + String(seed)
            + ": merged key count "
            + String(len(merged))
            + " != combined-reference count "
            + String(len(ref_keys)),
        )
        for rk in range(len(ref_keys)):
            var found = False
            for mk in range(len(merged)):
                if merged[mk] == ref_keys[rk]:
                    found = True
                    break
            assert_true(
                found,
                String("occ-seed ")
                + String(seed)
                + ": reference winner key "
                + String(ref_keys[rk])
                + " MISSING from merged (an OCC/intra-batch winner was dropped)",
            )

        # (c) DIRECT lost-update-vs-durable-head: find the ACTUAL winner of each
        # merged key (the first member that is an intra-batch survivor AND an OCC
        # passer AND writes that key — the codec's exact winner selection), then
        # assert NO competitor chunk in (winner_snapshot, auth_head] committed that
        # key. (The naive "first member writing the key" lookup is WRONG: an earlier
        # member may write the key but be an intra/OCC loser; the real winner can
        # have a higher snapshot. We replicate the codec's intra+OCC fold to find
        # the true winner, so this is a genuine independent check, not a tautology.)
        var occ_survives_intra = List[Bool]()
        var occ_claimed_intra = List[Int]()
        for i in range(nmem):
            var bad = False
            for wi in range(len(items[i].write_set)):
                var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                    items[i].write_set[wi].key[3]
                )
                for cj in range(len(occ_claimed_intra)):
                    if occ_claimed_intra[cj] == k:
                        bad = True
                        break
                if bad:
                    break
            if bad:
                occ_survives_intra.append(False)
                continue
            occ_survives_intra.append(True)
            for wi in range(len(items[i].write_set)):
                var k = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                    items[i].write_set[wi].key[3]
                )
                occ_claimed_intra.append(k)
        for mk in range(len(merged)):
            var key = merged[mk]
            # The true winner: first intra-survivor + OCC-passer writing this key.
            var win_snap = Int64(-2)
            for i in range(nmem):
                if not occ_survives_intra[i]:
                    continue
                var writes_key = False
                for wi in range(len(items[i].write_set)):
                    var ik = Int(items[i].write_set[wi].key[2]) * 256 + Int(
                        items[i].write_set[wi].key[3]
                    )
                    if ik == key:
                        writes_key = True
                        break
                if not writes_key:
                    continue
                # OCC check for this intra-survivor.
                var snap_i = Int(items[i].snapshot_lsn)
                var occ_bad = False
                var s2 = snap_i + 1
                while s2 <= n_comp - 1:
                    if s2 >= 0 and s2 < len(committed):
                        for wi2 in range(len(items[i].write_set)):
                            var ik2 = Int(items[i].write_set[wi2].key[2]) * 256 + Int(
                                items[i].write_set[wi2].key[3]
                            )
                            for cj2 in range(len(committed[s2])):
                                if committed[s2][cj2] == ik2:
                                    occ_bad = True
                                    break
                            if occ_bad:
                                break
                    if occ_bad:
                        break
                    s2 += 1
                if not occ_bad:
                    win_snap = items[i].snapshot_lsn
                    break
            assert_true(
                win_snap != Int64(-2),
                String("occ-seed ")
                + String(seed)
                + ": merged key "
                + String(key)
                + " has NO valid winner in the reference fold (codec merged a key"
                " no intra+OCC winner produced)",
            )
            var seq = Int(win_snap) + 1
            while seq <= n_comp - 1:
                if seq >= 0 and seq < len(committed):
                    for cj in range(len(committed[seq])):
                        assert_false(
                            committed[seq][cj] == key,
                            String("occ-seed ")
                            + String(seed)
                            + ": LOST UPDATE vs durable head — merged key "
                            + String(key)
                            + " was committed by competitor at seq "
                            + String(seq)
                            + " above the winner's snapshot "
                            + String(win_snap),
                        )
                seq += 1


def test_arbitrate_intra_batch_first_in_batch_wins_deterministic() raises:
    """The PURE intra-batch arbitration helper: first-in-batch-wins on drain
    order. A later member intersecting an earlier SURVIVOR loses; two later
    members both colliding with an earlier survivor both lose (a later member is
    NOT checked against earlier LOSERS — so a chain a>b>c where a wins, b loses to
    a, c collides only with b's key is still a WINNER if it does not touch a's)."""
    var items = List[PgGroupCommitItem]()
    items.append(_member(Int64(-1), 1, 2))  # 0: {1,2} WIN
    items.append(_member(Int64(-1), 2, 3))  # 1: shares 2 -> LOSS
    items.append(_member(Int64(-1), 3, 4))  # 2: shares 3 only w/ LOSER 1 -> WIN
    items.append(_member(Int64(-1), 1))  # 3: shares 1 w/ survivor 0 -> LOSS
    var survives = arbitrate_intra_batch(items)
    assert_equal(len(survives), 4)
    assert_true(survives[0], "member 0 wins")
    assert_false(survives[1], "member 1 loses (shares key 2 with survivor 0)")
    assert_true(
        survives[2],
        "member 2 WINS (key 3 only collides with LOSER 1, key 4 is fresh)",
    )
    assert_false(survives[3], "member 3 loses (shares key 1 with survivor 0)")


def main() raises:
    test_conflict_fuzz_no_lost_update_exactly_one_winner_per_key()
    print("  test_conflict_fuzz_no_lost_update_exactly_one_winner_per_key: PASS")
    test_red_all_winners_stub_is_a_lost_update()
    print("  test_red_all_winners_stub_is_a_lost_update: PASS")
    test_per_member_occ_stale_snapshot_loses_to_committed_competitor()
    print(
        "  test_per_member_occ_stale_snapshot_loses_to_committed_competitor: PASS"
    )
    test_conflict_fuzz_occ_combined_seeded_competitors()
    print("  test_conflict_fuzz_occ_combined_seeded_competitors: PASS")
    test_arbitrate_intra_batch_first_in_batch_wins_deterministic()
    print("  test_arbitrate_intra_batch_first_in_batch_wins_deterministic: PASS")
    print("ALL group-commit conflict-fuzz tests PASSED")
