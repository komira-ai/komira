# =============================================================================
# tests/test_shuffle_continuous_epoch_seal.mojo
#   Distributed-shuffle SEAL — CONTINUOUS multi-epoch instancing: the 3
#   PER-EPOCH FALSIFYING TESTS that gate the multi-segment streaming chain.
# =============================================================================
#
# WHY THIS EXISTS — the continuous shuffle does NOT redesign the protocol; it
# INSTANCES the one-shot seal once per EPOCH. An epoch == a `step_id`: the
# shuffle namespace is ALREADY per-step (`{shuffle_id}/{step_id}/_entries`,
# `.../{step_id}/_seal`, `.../{step_id}/{producer}.seg` — see
# `entries_prefix`/`seal_prefix`/`shuffle_segment_key`), and
# `read_shuffle_partition` ALREADY takes a `step_id: Int64`. For continuous
# streaming, segment 1 never ends — it keeps minting sealed epochs (step 0, 1,
# 2, ...) while segment 2 consumes earlier ones. These tests PROVE that the
# per-epoch instancing is correct, BEFORE any conformer / MVP code builds on it.
#
# These 3 falsifiers are the PER-EPOCH lifts of the one-shot falsifiers
# (`tests/test_shuffle_seal_phase_a.mojo`). Each uses >= 2 DISTINCT
# epochs (step_ids) so it genuinely exercises the per-epoch INSTANCING, not the
# single-epoch case the one-shot tests already pin. They CONSUME the proven free
# fns (sink_shuffle_write / seal_step / read_shuffle_partition) UNCHANGED — they
# do NOT modify the seal protocol.
#
# PER-EPOCH TEST 1 — SEAL-BLOCKS-ON-ABSENCE, PER EPOCH (one-shot
#     test 1, lifted): write+seal epoch e0; then write epoch e1's full
#     producer state but DO NOT seal e1 -> read_shuffle_partition at e1 must NOT
#     read e1's (unsealed) data — it parks then RAISES (no under-read of an
#     unsealed epoch). Meanwhile e0 still reads correctly (the e1 block does not
#     poison the already-sealed e0). THEN seal e1 -> e1 reads correctly. Proves
#     epochs are INDEPENDENTLY gated by their own per-step `_seal`.
#
# PER-EPOCH TEST 2 — IDEMPOTENT-REPLAY, NO DOUBLE-READ, PER EPOCH (EXACT-SET
#     each-once / one-shot test 2, lifted): in epoch e1, producer 2 replays
#     its full write under (2, step_id=e1) -> after seal, the reducer reads e1
#     EXACTLY once (the replayed producer counted once — the exact-producer-set
#     dedup holds PER EPOCH). Cross-check e1's row set is byte-identical to a
#     no-replay baseline epoch e0 written with the SAME producer rows. Proves the
#     dedup is per-epoch, not a global accident.
#
# PER-EPOCH TEST 3 — EMPTY-EPOCH-READS-ZERO, PER EPOCH (dense-index /
#     one-shot test 3, lifted): epoch e1 has a zero-length (dense-
#     index-zero) partition for reducer pid 3 from EVERY producer -> that reducer
#     reads 0 rows for e1, never blocks or errors. A NEIGHBOR epoch e0 (written
#     with the SAME screening but is fully non-empty across 0..2) reads its rows
#     correctly. Proves the dense-index-incl-zero-length property holds PER EPOCH.
#
# Each test is fail-before/pass-after verifiable: the production line whose
# reversion makes it FAIL is named inline (the same discipline as the one-shot
# tests).
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
)
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path

from komira_objectstore.shuffle_partitioner import HashPartitioner
from komira_objectstore.shuffle_sink import (
    ShuffleRow,
    sink_shuffle_write,
)
from komira_objectstore.shuffle_source import (
    read_shuffle_partition,
    decode_partition_payloads,
)
from komira_objectstore.shuffle_seal import (
    sorted_unique_i64,
    i64_sets_equal,
)
from komira_objectstore.shuffle_seal_driver import (
    seal_step,
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
# Scratch root + byte helpers (the LocalFs harness shape, as in the one-shot tests).
# -----------------------------------------------------------------------------
def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (_scratch_dir() + String("/komira_shuffle_epoch_")) + tag + String("_") + String(t)


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


def _expected_set(n: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        out.append(Int64(i))
    return out^


# -----------------------------------------------------------------------------
# Deterministic test rows. The payload is GLOBALLY UNIQUE per (epoch, producer,
# row) so a cross-epoch read can never alias a different epoch's payload — the
# epoch tag in the payload is itself a falsifier: if a read of epoch e1 returned
# epoch e0's bytes (a namespace bleed), the payload's `e{epoch}` tag would not
# match. The KEY does NOT carry the epoch (so the SAME key set scatters
# identically across epochs — the partition assignment is epoch-stable, which is
# what lets test 3 screen "partition 3 empty" once and reuse it per epoch).
# -----------------------------------------------------------------------------
def _epoch_producer_rows(
    epoch: Int, producer_id: Int, rows_per_producer: Int
) -> List[ShuffleRow]:
    var out = List[ShuffleRow]()
    for j in range(rows_per_producer):
        var key = _bytes(String("k_") + String(producer_id) + "_" + String(j))
        var payload = _bytes(
            String("e")
            + String(epoch)
            + "_p"
            + String(producer_id)
            + "_r"
            + String(j)
        )
        out.append(ShuffleRow(key^, payload^))
    return out^


def _all_epoch_payloads(
    epoch: Int, n_producers: Int, rows_per_producer: Int
) -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    for pi in range(n_producers):
        var rows = _epoch_producer_rows(epoch, pi, rows_per_producer)
        for j in range(len(rows)):
            out.append(rows[j].payload.copy())
    return out^


def _payload_in(haystack: List[List[UInt8]], needle: List[UInt8]) -> Bool:
    for i in range(len(haystack)):
        if _bytes_eq(haystack[i], needle):
            return True
    return False


# Map an EPOCH end-to-end: every producer writes + seal. Returns the sealed
# committed-producer count (so the caller can assert the set). Reused by tests 2
# and 3 to materialize a fully-sealed neighbor epoch.
def _write_and_seal_epoch(
    mut store: LocalFsConditionalStore,
    sid: Int64,
    epoch: Int64,
    r: Int64,
    n_prod: Int,
    rows_per: Int,
) raises:
    for pi in range(n_prod):
        var rows = _epoch_producer_rows(Int(epoch), pi, rows_per)
        _ = sink_shuffle_write(store, sid, epoch, Int64(pi), r, rows)
    var seal = seal_step(store, sid, epoch, r, _expected_set(n_prod))
    if not i64_sets_equal(
        sorted_unique_i64(seal.committed_producers), _expected_set(n_prod)
    ):
        raise Error("epoch " + String(epoch) + " seal committed != expected")


# Read every partition of an EPOCH and collect the union of decoded payloads.
def _read_epoch_union(
    store: LocalFsConditionalStore,
    sid: Int64,
    epoch: Int64,
    r: Int64,
    n_prod: Int,
) raises -> List[List[UInt8]]:
    var union = List[List[UInt8]]()
    for p in range(Int(r)):
        var body = read_shuffle_partition(
            store, sid, epoch, Int64(p), _expected_set(n_prod)
        )
        var payloads = decode_partition_payloads(body)
        for k in range(len(payloads)):
            union.append(payloads[k].copy())
    return union^


# =============================================================================
# PER-EPOCH TEST 1 — SEAL-BLOCKS-ON-ABSENCE, PER EPOCH.
#
# Two distinct epochs e0, e1 of the SAME shuffle_id. e0 is fully written + sealed
# (reads fine). e1 is fully WRITTEN but NOT sealed. The reducer must:
#   (a) read e0 correctly (the already-sealed epoch is unaffected),
#   (b) RAISE on e1 (block-on-absence of e1's own per-step `_seal`; no under-read
#       of the unsealed epoch).
# Then e1 is sealed and now reads correctly. This proves each epoch is gated by
# its OWN `{shuffle_id}/{e}/_seal` — sealing e0 does NOT make e1 readable, and a
# withheld e1 seal does NOT block the sealed e0.
# =============================================================================
def test_per_epoch_seal_blocks_on_absence() raises:
    print("[test_per_epoch_seal_blocks_on_absence] starting...")
    var root = _scratch_root(String("block"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(100)
    var e0 = Int64(0)
    var e1 = Int64(1)
    var r = Int64(4)
    var n_prod = 4
    var rows_per = 4

    # ---- EPOCH e0: full write + SEAL. ----
    _write_and_seal_epoch(store, sid, e0, r, n_prod, rows_per)

    # ---- EPOCH e1: full producer state WRITTEN, but DO NOT seal. ----
    for pi in range(n_prod):
        var rows = _epoch_producer_rows(Int(e1), pi, rows_per)
        _ = sink_shuffle_write(store, sid, e1, Int64(pi), r, rows)

    # (a) e0 reads correctly — the sealed epoch is unaffected by e1 being open.
    # Reverts if read_shuffle_partition resolved the seal at the WRONG step (a
    # step_id-independent seal lookup would mix epochs); the per-step
    # `seal_prefix(sid, e0)` is what isolates e0's seal.
    var e0_union = _read_epoch_union(store, sid, e0, r, n_prod)
    var e0_inputs = _all_epoch_payloads(Int(e0), n_prod, rows_per)
    assert_equal(
        len(e0_union),
        len(e0_inputs),
        "epoch e0 (sealed) reads its full row set while e1 is open",
    )
    for i in range(len(e0_inputs)):
        assert_true(
            _payload_in(e0_union, e0_inputs[i]),
            "e0 payload " + String(i) + " present (e0 sealed independently)",
        )
    # e0's union must be PURE e0 (no e1 bleed) — every e0-union payload is a real
    # e0 input. If the seal lookup were not per-step, e1's bytes could leak in.
    for i in range(len(e0_union)):
        assert_true(
            _payload_in(e0_inputs, e0_union[i]),
            "e0 union payload " + String(i) + " is a real e0 input (no e1 bleed)",
        )

    # (b) e1 RAISES — its own `_seal` is absent (block-on-absence per epoch).
    # Reverts if read_shuffle_partition keyed the seal block on a shared/global
    # seal instead of `seal_prefix(sid, e1)`: sealing e0 would then satisfy e1's
    # block and the reducer would UNDER-READ the unsealed e1 (read e1's `.seg`
    # bodies without the each-once / exact-set guarantee).
    var raised_e1_absent = False
    try:
        var _b = read_shuffle_partition(
            store, sid, e1, Int64(0), _expected_set(n_prod), 4
        )
    except e:
        raised_e1_absent = True
        var msg = String(e)
        assert_true(
            msg.find(String("absent")) >= 0,
            "e1 absent-seal raise names the absence (per-epoch read_seal park)",
        )
    assert_true(
        raised_e1_absent,
        "read_shuffle_partition RAISES on UNSEALED epoch e1 even though e0 is"
        " sealed (per-epoch block-on-absence, NO under-read of an open epoch)",
    )

    # ---- Now SEAL e1 -> it reads correctly (its own seal closes its own epoch).
    var seal1 = seal_step(store, sid, e1, r, _expected_set(n_prod))
    assert_true(
        i64_sets_equal(
            sorted_unique_i64(seal1.committed_producers), _expected_set(n_prod)
        ),
        "e1 seal committed == {0,1,2,3}",
    )
    var e1_union = _read_epoch_union(store, sid, e1, r, n_prod)
    var e1_inputs = _all_epoch_payloads(Int(e1), n_prod, rows_per)
    assert_equal(
        len(e1_union),
        len(e1_inputs),
        "epoch e1 reads its full row set AFTER its own seal lands",
    )
    for i in range(len(e1_inputs)):
        assert_true(
            _payload_in(e1_union, e1_inputs[i]),
            "e1 payload " + String(i) + " present after e1 seal",
        )
    # e1's union is PURE e1 (no e0 bleed) — cross-epoch isolation both ways.
    for i in range(len(e1_union)):
        assert_true(
            _payload_in(e1_inputs, e1_union[i]),
            "e1 union payload " + String(i) + " is a real e1 input (no e0 bleed)",
        )
    _ = store^
    _cleanup(root)
    print("[test_per_epoch_seal_blocks_on_absence] PASS")


# =============================================================================
# PER-EPOCH TEST 2 — IDEMPOTENT-REPLAY, NO DOUBLE-READ, PER EPOCH.
#
# Two epochs e0 (no replay — the baseline) and e1 (producer 2 replays). Both use
# the SAME producer rows per (producer, row) modulo the epoch tag, so e1's row
# set is byte-identical to e0's EXCEPT the `e{epoch}` prefix. After sealing both:
#   * e1's `_entries` holds EXACTLY n_prod chunks (the replay landed NO 2nd chunk
#     — the each-once storage guard holds in epoch e1's OWN `_entries`).
#   * e1's seal counts producer 2 EXACTLY once (the per-epoch dedup).
#   * the reducer reads each of producer-2's e1 payloads EXACTLY once (no double-
#     read), and e1's full row count == e0's full row count (the replay did not
#     inflate e1 relative to the no-replay baseline).
# Proves the exact-producer-set dedup is PER EPOCH (scoped to `{sid}/{e1}/`), not
# a global accident that a single-epoch test could mask.
# =============================================================================
def test_per_epoch_idempotent_replay_no_double_read() raises:
    print("[test_per_epoch_idempotent_replay_no_double_read] starting...")
    var root = _scratch_root(String("replay"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(200)
    var e0 = Int64(0)
    var e1 = Int64(1)
    var r = Int64(4)
    var n_prod = 4
    var rows_per = 5

    # ---- EPOCH e0 (BASELINE, no replay): full write + seal. ----
    _write_and_seal_epoch(store, sid, e0, r, n_prod, rows_per)

    # ---- EPOCH e1: all producers write once, THEN producer 2 REPLAYS. ----
    for pi in range(n_prod):
        var rows = _epoch_producer_rows(Int(e1), pi, rows_per)
        _ = sink_shuffle_write(store, sid, e1, Int64(pi), r, rows)
    # producer 2 replays its FULL write under the SAME (2, step_id=e1).
    var rows2_again = _epoch_producer_rows(Int(e1), 2, rows_per)
    _ = sink_shuffle_write(store, sid, e1, Int64(2), r, rows2_again)

    # PER-EPOCH STORAGE-LAYER EACH-ONCE: epoch e1's OWN `_entries` manifest must
    # hold EXACTLY n_prod chunks after producer 2's replay (the replay landed no
    # 2nd chunk in `{sid}/{e1}/_entries`). chunk_seq is the highest committed
    # chunk seq (0-based) so n_prod chunks => chunk_seq == n_prod - 1. Reverts if
    # sink_shuffle_write used a plain `append` (each-once storage guard) — note
    # this is asserted on e1's per-step `entries_prefix(sid, e1)`, proving the
    # dedup sentinel is scoped to the EPOCH (a global `_entries` would carry e0's
    # chunks too and this count would be wrong).
    var entries_m = CasManifestStore[LocalFsConditionalStore](
        store.clone(), entries_prefix(sid, e1), RetryPolicy.default()
    )
    var entries_head = entries_m.read_head_authoritative()
    assert_equal(
        entries_head.chunk_seq,
        Int64(n_prod - 1),
        "epoch e1 `_entries` holds EXACTLY n_prod chunks after replay (per-epoch"
        " each-once: no 2nd chunk for producer 2 in `{sid}/{e1}/_entries`)",
    )
    _ = entries_m^

    var seal1 = seal_step(store, sid, e1, r, _expected_set(n_prod))
    # producer 2 dedups to ONE set member within epoch e1 (reverts if seal_step's
    # committed-set scan used a count instead of sorted_unique_i64 — and this is
    # epoch e1's seal, proving the dedup is per-epoch).
    assert_equal(
        len(seal1.committed_producers),
        4,
        "epoch e1 committed dedups to EXACTLY 4 (producer 2 not counted twice)",
    )
    var twos = 0
    for i in range(len(seal1.read_plan_producer_ids)):
        if seal1.read_plan_producer_ids[i] == Int64(2):
            twos += 1
    assert_equal(twos, 1, "producer 2 appears EXACTLY once in e1's read plan")

    # Read EVERY e1 partition; count how many of producer-2's e1 payloads appear.
    # A double-read would surface each TWICE.
    var prod2_rows = _epoch_producer_rows(Int(e1), 2, rows_per)
    var seen_counts = List[Int]()
    for _i in range(rows_per):
        seen_counts.append(0)
    for p in range(Int(r)):
        var body = read_shuffle_partition(
            store, sid, e1, Int64(p), _expected_set(n_prod)
        )
        var payloads = decode_partition_payloads(body)
        for k in range(len(payloads)):
            for ri in range(rows_per):
                if _bytes_eq(payloads[k], prod2_rows[ri].payload):
                    seen_counts[ri] += 1
    for ri in range(rows_per):
        assert_equal(
            seen_counts[ri],
            1,
            "epoch e1 producer-2 payload "
            + String(ri)
            + " appears EXACTLY once (no double-read in this epoch)",
        )

    # ---- CROSS-EPOCH BASELINE: e1's full row count == e0's full row count. ----
    # e0 had NO replay; e1 had a replay. If the per-epoch dedup failed, e1 would
    # carry MORE rows than the no-replay e0 baseline. They must match exactly
    # (n_prod * rows_per rows in BOTH).
    var e0_total = len(_read_epoch_union(store, sid, e0, r, n_prod))
    var e1_total = len(_read_epoch_union(store, sid, e1, r, n_prod))
    assert_equal(
        e0_total,
        n_prod * rows_per,
        "epoch e0 (no replay) carries n_prod*rows_per rows",
    )
    assert_equal(
        e1_total,
        e0_total,
        "epoch e1 (replayed) carries the SAME row count as the no-replay e0"
        " baseline (the replay did NOT inflate the epoch)",
    )
    _ = store^
    _cleanup(root)
    print("[test_per_epoch_idempotent_replay_no_double_read] PASS")


# =============================================================================
# PER-EPOCH TEST 3 — EMPTY-EPOCH-READS-ZERO, PER EPOCH.
#
# Two epochs e0 and e1. In BOTH epochs, keys are screened so NO row lands in
# partition 3 (partition 3 is empty from every producer in every epoch). For each
# epoch the reducer at pid 3 must read ZERO rows and complete IMMEDIATELY (the
# dense-index-incl-zero-length property), while partitions 0..2 carry all rows.
# Using TWO epochs proves the empty-partition handling instances per epoch: e0's
# empty pid-3 and e1's empty pid-3 are distinct dense-zero slots in distinct
# `{sid}/{e}/` seals, each resolved independently.
# =============================================================================
def test_per_epoch_empty_partition_reads_zero() raises:
    print("[test_per_epoch_empty_partition_reads_zero] starting...")
    var root = _scratch_root(String("empty"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(300)
    var r = Int64(4)
    var n_prod = 4
    var per_prod = 4  # rows kept per producer per epoch

    var partitioner = HashPartitioner(r)

    # Write TWO epochs e0, e1; in each, screen out any key hashing to partition 3.
    for epoch in range(2):
        for pi in range(n_prod):
            var rows = List[ShuffleRow]()
            var made = 0
            var cand = 0
            while made < per_prod:
                # key is epoch-INDEPENDENT (same screen across epochs) so the
                # partition assignment is stable; payload carries the epoch tag.
                var key = _bytes(String("e_") + String(pi) + "_" + String(cand))
                cand += 1
                if partitioner.partition_for(key) == 3:
                    continue  # skip any key landing in the (empty) partition 3
                var payload = _bytes(
                    String("z")
                    + String(epoch)
                    + "_p"
                    + String(pi)
                    + "_r"
                    + String(made)
                )
                rows.append(ShuffleRow(key^, payload^))
                made += 1
            _ = sink_shuffle_write(store, sid, Int64(epoch), Int64(pi), r, rows)
        var seal = seal_step(store, sid, Int64(epoch), r, _expected_set(n_prod))
        # the seal succeeds per epoch — the producer set is complete; empty
        # partition 3 does NOT block the seal (it has dense zero-length entries).
        assert_true(
            seal.is_lifted(),
            "epoch " + String(epoch) + " seal LIFTED with empty partition 3",
        )
        # every plan row's partition-3 slot is dense zero-length in THIS epoch.
        for i in range(len(seal.read_plan_producer_ids)):
            var slot3 = seal.dense_slot(i, 3)
            assert_equal(
                slot3[1],
                Int64(0),
                "epoch " + String(epoch) + " plan row " + String(i) + " p3 len=0",
            )
            assert_equal(
                slot3[2],
                Int64(0),
                "epoch " + String(epoch) + " plan row " + String(i) + " p3 rc=0",
            )

    # For EACH epoch: partition 3 reads ZERO rows and completes immediately;
    # partitions 0..2 carry all per_prod*n_prod rows. Reverts if SegWriter built a
    # SPARSE trailer (the reducer could not distinguish "empty" from "not landed"
    # and would block/error) — and this is asserted PER EPOCH (each epoch's own
    # `.seg` trailers + seal resolve its own empty pid-3 slot).
    var expect_nonempty = per_prod * n_prod  # 16 rows
    for epoch in range(2):
        var body3 = read_shuffle_partition(
            store, sid, Int64(epoch), Int64(3), _expected_set(n_prod)
        )
        assert_equal(
            len(body3),
            0,
            "epoch " + String(epoch) + " empty partition 3 reads ZERO bytes",
        )
        assert_equal(
            len(decode_partition_payloads(body3)),
            0,
            "epoch " + String(epoch) + " empty partition 3 yields ZERO rows",
        )
        var nonempty_total = 0
        for p in range(3):
            var b = read_shuffle_partition(
                store, sid, Int64(epoch), Int64(p), _expected_set(n_prod)
            )
            nonempty_total += len(decode_partition_payloads(b))
        assert_equal(
            nonempty_total,
            expect_nonempty,
            "epoch " + String(epoch) + " partitions 0-2 carry all "
            + String(expect_nonempty)
            + " rows",
        )

    # CROSS-EPOCH PURITY: each epoch's non-empty rows are PURE that epoch (the
    # epoch tag in the payload). A namespace bleed (resolving e1's read against
    # e0's seal/`.seg`) would surface e0's `z0_*` payloads in e1's union.
    for epoch in range(2):
        for p in range(3):
            var b = read_shuffle_partition(
                store, sid, Int64(epoch), Int64(p), _expected_set(n_prod)
            )
            var payloads = decode_partition_payloads(b)
            var tag = _bytes(String("z") + String(epoch) + "_p")
            for k in range(len(payloads)):
                # every payload in epoch `epoch` must begin with `z{epoch}_p`.
                var ok = True
                if len(payloads[k]) < len(tag):
                    ok = False
                else:
                    for t in range(len(tag)):
                        if payloads[k][t] != tag[t]:
                            ok = False
                            break
                assert_true(
                    ok,
                    "epoch " + String(epoch) + " p" + String(p)
                    + " payload carries the correct epoch tag (no cross-epoch"
                    " bleed)",
                )
    _ = store^
    _cleanup(root)
    print("[test_per_epoch_empty_partition_reads_zero] PASS")


def main() raises:
    test_per_epoch_seal_blocks_on_absence()
    test_per_epoch_idempotent_replay_no_double_read()
    test_per_epoch_empty_partition_reads_zero()
    print(
        "[test_shuffle_continuous_epoch_seal] all 3 PER-EPOCH falsifying tests"
        " PASS"
    )
