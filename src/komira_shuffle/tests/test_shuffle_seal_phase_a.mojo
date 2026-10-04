# =============================================================================
# tests/test_shuffle_seal_phase_a.mojo
#   Distributed-shuffle SEAL — the P=4/R=4 single-process harness + the 3
#   FALSIFYING TESTS that ARE the one-shot seal gate.
# =============================================================================
#
# This is the one-shot seal's keystone gate.
# It exercises the full map-write -> driver-join seal -> sole-read-barrier read
# loop end-to-end, single-process, over `LocalFsConditionalStore`, P=4 producers
# x R=4 partitions, and pins the 3 falsifying properties the seal exists to
# guarantee.
#
#   PARITY (the shuffle is correctness-transparent): the union of the 4 reduce-
#   partition outputs == the input row set. Deterministic round-trip parity IS
#   the honest equivalent of "equals the morsel executor" — the engine morsel
#   executor is NOT wired into the shuffle, so the
#   correctness-transparency we can falsifiably assert is: every input payload
#   appears exactly once across the 4 reduce outputs, and nothing extra appears.
#
# FALSIFYING TEST 1 — SEAL-BLOCKS-ON-ABSENCE + FAIL-ON-MISSING-SET: full P=4
#     producer state but NO seal_step ->
#     read_shuffle_partition with a bounded retry budget must NOT return data
#     (parks then raises — no under-read). Then inject a partial seal
#     (committed={0,1,2}, producer 3 missing) -> read_shuffle_partition must
#     RAISE (not aggregate the partial set).
#
# FALSIFYING TEST 2 — IDEMPOTENT-MAP-REPLAY, NO DOUBLE-READ (EXACT-SET
#     each-once): run producer 2's full write TWICE under
#     (2, step_id) -> seal_step -> read producer-2's partition -> the aggregate
#     equals the SINGLE-write result (NOT doubled).
#
# FALSIFYING TEST 3 — EMPTY-PARTITION-READS-ZERO (dense-index): inputs chosen
#     so partition 3 gets zero rows from
#     EVERY producer -> every `.seg` trailer has (off, len=0, rc=0) for pid 3 ->
#     seal_step succeeds -> read_shuffle_partition(3) returns zero rows and
#     completes IMMEDIATELY (never blocks, never raises).
#
# Each falsifying test names the EXACT production line whose reversion makes it
# FAIL (the same discipline as the codec/driver test).
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

from komira_shuffle.partitioner import HashPartitioner
from komira_shuffle.sink import (
    ShuffleRow,
    sink_shuffle_write,
)
from komira_shuffle.source import (
    read_shuffle_partition,
    decode_partition_payloads,
)
from komira_shuffle.seal import (
    StepComplete,
    SEAL_INDEX_LIFTED,
    encode_step_complete,
    sorted_unique_i64,
    i64_sets_equal,
)
from komira_shuffle.seal_driver import (
    seal_step,
    seal_prefix,
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
# Scratch root + byte helpers (the LocalFs harness shape, as in the codec/driver test).
# -----------------------------------------------------------------------------
def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (_scratch_dir() + String("/komira_shuffle_phasea_")) + tag + String("_") + String(t)


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
# Deterministic test rows: each producer makes a fixed set of (key, payload)
# rows. The payload is GLOBALLY UNIQUE ("p{producer}_r{row}") so the parity
# assert can verify each appears exactly once across the 4 reduce outputs.
# -----------------------------------------------------------------------------
def _producer_rows(producer_id: Int, rows_per_producer: Int) -> List[ShuffleRow]:
    var out = List[ShuffleRow]()
    for j in range(rows_per_producer):
        # key drives the partition; vary it across producers AND rows so the
        # scatter exercises all 4 partitions.
        var key = _bytes(String("k_") + String(producer_id) + "_" + String(j))
        var payload = _bytes(
            String("p") + String(producer_id) + "_r" + String(j)
        )
        out.append(ShuffleRow(key^, payload^))
    return out^


# Collect every input payload (across all producers) into one set-membership
# list, so the reduce-union can be checked against it.
def _all_input_payloads(
    n_producers: Int, rows_per_producer: Int
) -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    for pi in range(n_producers):
        var rows = _producer_rows(pi, rows_per_producer)
        for j in range(len(rows)):
            out.append(rows[j].payload.copy())
    return out^


def _payload_in(haystack: List[List[UInt8]], needle: List[UInt8]) -> Bool:
    for i in range(len(haystack)):
        if _bytes_eq(haystack[i], needle):
            return True
    return False


# =============================================================================
# PARITY — the full P=4/R=4 happy path: scatter, seal, reduce, union == input.
#
# (Parity note: the engine morsel executor is NOT wired into the shuffle, so
# the honest correctness-transparency assertion is the deterministic
# round-trip — every input payload appears EXACTLY once across the 4 reduce
# outputs, and the reduce union has no extras. This is the equivalent gate the
# combine/executor wiring will later strengthen into "equals the executor".)
# =============================================================================
def test_phase_a_parity_full_roundtrip() raises:
    print("[test_phase_a_parity_full_roundtrip] starting...")
    var root = _scratch_root(String("parity"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(1)
    var stp = Int64(0)
    var r = Int64(4)
    var n_prod = 4
    var rows_per = 6

    # ---- MAP: each producer scatters + writes its `.seg` + appends `_entries`.
    for pi in range(n_prod):
        var rows = _producer_rows(pi, rows_per)
        _ = sink_shuffle_write(store, sid, stp, Int64(pi), r, rows)

    # ---- DRIVER JOIN: seal the step over the full producer set {0,1,2,3}.
    var seal = seal_step(store, sid, stp, r, _expected_set(n_prod))
    assert_true(
        i64_sets_equal(
            sorted_unique_i64(seal.committed_producers), _expected_set(n_prod)
        ),
        "seal committed == {0,1,2,3}",
    )

    # ---- REDUCE: each of the 4 reduce shards reads its partition; collect the
    # union of decoded payloads.
    var union = List[List[UInt8]]()
    var total = 0
    for p in range(Int(r)):
        var body = read_shuffle_partition(
            store, sid, stp, Int64(p), _expected_set(n_prod)
        )
        var payloads = decode_partition_payloads(body)
        for k in range(len(payloads)):
            union.append(payloads[k].copy())
            total += 1

    # PARITY 1: the reduce union has EXACTLY as many rows as the input (no
    # under-read = no dropped partition; no double-read = no duplicated row).
    # Reverts if read_shuffle_partition skips a producer slice or reads one
    # twice (source.read_shuffle_partition dense-plan loop).
    var inputs = _all_input_payloads(n_prod, rows_per)
    assert_equal(total, len(inputs), "reduce-union row count == input row count")

    # PARITY 2: every input payload appears in the reduce union (correctness-
    # transparency: nothing is lost). Reverts if a partition's slice is dropped.
    for i in range(len(inputs)):
        assert_true(
            _payload_in(union, inputs[i]),
            "input payload " + String(i) + " present in reduce union",
        )
    # PARITY 3: every reduce-union payload is a real input (nothing extra /
    # corrupted). Reverts if the body codec or range-read offsets drift.
    for i in range(len(union)):
        assert_true(
            _payload_in(inputs, union[i]),
            "reduce payload " + String(i) + " is a real input",
        )
    _ = store^
    _cleanup(root)
    print("[test_phase_a_parity_full_roundtrip] PASS")


# =============================================================================
# FALSIFYING TEST 1 — SEAL-BLOCKS-ON-ABSENCE + FAIL-ON-MISSING-SET.
# =============================================================================
def test_phase_a_seal_blocks_on_absence_and_missing_set() raises:
    print("[test_phase_a_seal_blocks_on_absence_and_missing_set] starting...")
    var root = _scratch_root(String("block"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(10)
    var stp = Int64(0)
    var r = Int64(4)
    var n_prod = 4

    # Full P=4 producer state (all `.seg` + `_entries` written) but DO NOT seal.
    for pi in range(n_prod):
        var rows = _producer_rows(pi, 4)
        _ = sink_shuffle_write(store, sid, stp, Int64(pi), r, rows)

    # PART A — SEAL ABSENT: read_shuffle_partition with a SMALL bounded retry
    # budget must NOT return data; it parks then RAISES (no under-read). Reverts
    # if read_shuffle_partition reads `_entries` directly instead of blocking on
    # the seal (source step 1 `read_seal` call + seal_driver
    # read_seal's `max_park_iters` park-then-raise).
    var raised_absent = False
    try:
        var _b = read_shuffle_partition(
            store, sid, stp, Int64(0), _expected_set(n_prod), 4
        )
    except e:
        raised_absent = True
        var msg = String(e)
        assert_true(
            msg.find(String("seal absent")) >= 0 or msg.find(String("absent")) >= 0,
            "absent-seal raise names the absence (read_seal park-then-raise)",
        )
    assert_true(
        raised_absent,
        "read_shuffle_partition RAISES on an absent seal (NO under-read)",
    )

    # PART B — PARTIAL SEAL (committed={0,1,2}, producer 3 MISSING): inject a seal
    # whose committed set is a STRICT SUBSET of expected -> read_shuffle_partition
    # must RAISE (fail loud, NOT aggregate the partial set). Reverts if
    # seal_driver.read_seal drops the `committed ⊊ expected` re-verify
    # (the i64_set_contains_all check) — it would then return the partial seal and
    # the reducer would under-read the missing producer.
    #
    # Hand-write a partial LIFTED seal directly to the `_seal` manifest (models a
    # corrupt/torn seal — seal_step itself would REFUSE to write this, which is
    # exactly the point: the read path must ALSO catch it).
    var partial_committed = List[Int64]()
    partial_committed.append(Int64(0))
    partial_committed.append(Int64(1))
    partial_committed.append(Int64(2))
    # a minimal LIFTED plan (3 producers, R dense triples each, all zero — the
    # read never reaches the plan because the set re-verify raises first).
    var rp_pids = List[Int64]()
    var rp_keys = List[String]()
    var rp_index = List[Int64]()
    for ci in range(3):
        rp_pids.append(Int64(ci))
        rp_keys.append(
            String(sid) + "/" + String(stp) + "/" + String(ci) + ".seg"
        )
        for _p in range(Int(r)):
            rp_index.append(Int64(0))
            rp_index.append(Int64(0))
            rp_index.append(Int64(0))
    var partial_seal = StepComplete(
        sid,
        stp,
        r,
        SEAL_INDEX_LIFTED,
        _expected_set(n_prod),  # expected = {0,1,2,3}
        partial_committed^,  # committed = {0,1,2} (3 MISSING)
        rp_pids^,
        rp_keys^,
        rp_index^,
        Int64(0),
        Int64(0),
    )
    var seal_m = CasManifestStore[LocalFsConditionalStore](
        store.clone(), seal_prefix(sid, stp), RetryPolicy.default()
    )
    _ = seal_m.append(encode_step_complete(partial_seal), Int64(1))
    _ = seal_m^

    var raised_partial = False
    try:
        var _b2 = read_shuffle_partition(
            store, sid, stp, Int64(0), _expected_set(n_prod), 4
        )
    except e:
        raised_partial = True
        var msg = String(e)
        assert_true(
            msg.find(String("subset")) >= 0
            or msg.find(String("⊊")) >= 0
            or msg.find(String("!=")) >= 0
            or msg.find(String("Refusing")) >= 0,
            "partial-seal raise names the missing-producer / set-mismatch",
        )
    assert_true(
        raised_partial,
        "read_shuffle_partition RAISES on committed ⊊ expected (NO partial"
        " aggregate)",
    )
    _ = store^
    _cleanup(root)
    print("[test_phase_a_seal_blocks_on_absence_and_missing_set] PASS")


# =============================================================================
# FALSIFYING TEST 2 — IDEMPOTENT-MAP-REPLAY, NO DOUBLE-READ.
# =============================================================================
def test_phase_a_idempotent_replay_no_double_read() raises:
    print("[test_phase_a_idempotent_replay_no_double_read] starting...")
    var root = _scratch_root(String("replay"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(20)
    var stp = Int64(0)
    var r = Int64(4)
    var n_prod = 4
    var rows_per = 5

    # All producers write once...
    for pi in range(n_prod):
        var rows = _producer_rows(pi, rows_per)
        _ = sink_shuffle_write(store, sid, stp, Int64(pi), r, rows)

    # ...then producer 2 REPLAYS its FULL write under the SAME (2, step_id) (the
    # map-replay fault-tolerance requires). The `.seg` is
    # re-PUT byte-identical; the `_entries` append is idempotent on
    # (producer_id=2, first_seq=step_id) and does NOT land a second chunk.
    var rows2_again = _producer_rows(2, rows_per)
    _ = sink_shuffle_write(store, sid, stp, Int64(2), r, rows2_again)

    # STORAGE-LAYER EACH-ONCE (the guard the DRIVER dedup would otherwise mask):
    # the `_entries` manifest must hold EXACTLY n_prod chunks AFTER producer 2's
    # replay — the sink's append_idempotent DedupSentinel must NOT have landed a
    # second `_entries` chunk for producer 2. We assert this DIRECTLY at the
    # storage layer (over the `_entries` prefix), because the end-to-end
    # no-double-read assertion below is satisfied by the driver's _scan_entries
    # dedup EVEN IF a 2nd chunk landed (reverting the sink to a plain `append`
    # passes the end-to-end test but FAILS this storage-layer check). chunk_seq
    # is the highest committed chunk seq (0-based), so n_prod chunks => chunk_seq
    # == n_prod - 1. Reverts if sink.sink_shuffle_write uses a plain
    # `append` instead of `append_idempotent` (the each-once storage guard).
    var entries_m = CasManifestStore[LocalFsConditionalStore](
        store.clone(), entries_prefix(sid, stp), RetryPolicy.default()
    )
    var entries_head = entries_m.read_head_authoritative()
    assert_equal(
        entries_head.chunk_seq,
        Int64(n_prod - 1),
        "`_entries` holds EXACTLY n_prod chunks after replay (sink"
        " append_idempotent landed NO 2nd chunk for producer 2)",
    )
    _ = entries_m^

    var seal = seal_step(store, sid, stp, r, _expected_set(n_prod))
    # committed dedups to {0,1,2,3} — producer 2 is ONE set member, not two
    # (reverts if seal_step's committed-set scan uses a count instead of
    # sorted_unique_i64 dedup — seal_driver._scan_entries / sorted_unique_i64).
    assert_equal(
        len(seal.committed_producers),
        4,
        "committed dedups to EXACTLY 4 (producer 2 NOT counted twice)",
    )
    # the read plan carries producer 2 EXACTLY once (reverts if
    # _build_lifted_seal emits a duplicate plan row -> double-read).
    var twos = 0
    for i in range(len(seal.read_plan_producer_ids)):
        if seal.read_plan_producer_ids[i] == Int64(2):
            twos += 1
    assert_equal(twos, 1, "producer 2 appears EXACTLY once in the read plan")

    # Read EVERY partition and count how many of producer-2's payloads appear in
    # the reduce union. Producer 2 wrote `rows_per` UNIQUE payloads; a double-read
    # would surface each TWICE. Reverts if the seal counts producer 2 twice OR the
    # read plan double-reads its `.seg` partition slices.
    var prod2_rows = _producer_rows(2, rows_per)
    var seen_counts = List[Int]()
    for _i in range(rows_per):
        seen_counts.append(0)
    for p in range(Int(r)):
        var body = read_shuffle_partition(
            store, sid, stp, Int64(p), _expected_set(n_prod)
        )
        var payloads = decode_partition_payloads(body)
        for k in range(len(payloads)):
            for ri in range(rows_per):
                if _bytes_eq(payloads[k], prod2_rows[ri].payload):
                    seen_counts[ri] += 1
    # EACH of producer-2's payloads appears EXACTLY ONCE (the single-write result,
    # NOT doubled). This is the load-bearing no-double-read assertion.
    for ri in range(rows_per):
        assert_equal(
            seen_counts[ri],
            1,
            "producer-2 payload "
            + String(ri)
            + " appears EXACTLY once (no double-read)",
        )
    _ = store^
    _cleanup(root)
    print("[test_phase_a_idempotent_replay_no_double_read] PASS")


# =============================================================================
# FALSIFYING TEST 3 — EMPTY-PARTITION-READS-ZERO (completes immediately).
# =============================================================================
def test_phase_a_empty_partition_reads_zero() raises:
    print("[test_phase_a_empty_partition_reads_zero] starting...")
    var root = _scratch_root(String("empty"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(30)
    var stp = Int64(0)
    var r = Int64(4)
    var n_prod = 4

    # Choose keys so NO row lands in partition 3 — partition 3 is empty from
    # EVERY producer. We construct rows by SCREENING each candidate key through
    # the HashPartitioner: keep it only if it does NOT hash to partition 3. This
    # guarantees every `.seg` trailer has (off, len=0, rc=0) for pid 3 (the dense
    # zero-length entry —), so the partition-3 read must complete
    # IMMEDIATELY with zero rows (never block, never raise).
    var partitioner = HashPartitioner(r)
    for pi in range(n_prod):
        var rows = List[ShuffleRow]()
        var made = 0
        var cand = 0
        while made < 4:
            var key = _bytes(
                String("e_") + String(pi) + "_" + String(cand)
            )
            cand += 1
            if partitioner.partition_for(key) == 3:
                continue  # skip any key that would land in partition 3
            var payload = _bytes(
                String("e") + String(pi) + "_r" + String(made)
            )
            rows.append(ShuffleRow(key^, payload^))
            made += 1
        _ = sink_shuffle_write(store, sid, stp, Int64(pi), r, rows)

    var seal = seal_step(store, sid, stp, r, _expected_set(n_prod))
    # the seal succeeds (the producer set is complete — empty partition 3 does
    # NOT block the seal; it has dense zero-length entries). Reverts if the
    # `.seg` trailer were SPARSE (skipping empty partition 3) — _build_lifted_seal
    # would raise "torn .seg" (len(slots) != R) and the seal would never write.
    assert_true(seal.is_lifted(), "seal LIFTED with empty partition 3")
    # every plan row's partition-3 slot is dense zero-length (reverts if
    # SegWriter skipped the empty partition's dense slot — segment
    # SegWriter.append_partition records (off,0,0) for an empty partition).
    for i in range(len(seal.read_plan_producer_ids)):
        var slot3 = seal.dense_slot(i, 3)
        assert_equal(slot3[1], Int64(0), "plan row " + String(i) + " part3 len=0")
        assert_equal(slot3[2], Int64(0), "plan row " + String(i) + " part3 rc=0")

    # PARTITION 3 reads ZERO rows and completes IMMEDIATELY (never blocks, never
    # raises). Reverts if SegWriter built a SPARSE trailer (the reducer could not
    # distinguish "empty" from "not landed" and would block/error) OR if
    # read_shuffle_partition issued a get_range for a len==0 slice instead of
    # DROPPING it (source.read_shuffle_partition `if length == 0: continue`).
    var body3 = read_shuffle_partition(
        store, sid, stp, Int64(3), _expected_set(n_prod)
    )
    assert_equal(len(body3), 0, "empty partition 3 reads ZERO bytes")
    var payloads3 = decode_partition_payloads(body3)
    assert_equal(len(payloads3), 0, "empty partition 3 yields ZERO rows")

    # sanity: partitions 0-2 between them DO carry all the rows (proves we didn't
    # accidentally drop everything). 4 rows/producer x 4 producers = 16 rows.
    var nonempty_total = 0
    for p in range(3):
        var b = read_shuffle_partition(
            store, sid, stp, Int64(p), _expected_set(n_prod)
        )
        nonempty_total += len(decode_partition_payloads(b))
    assert_equal(nonempty_total, 16, "partitions 0-2 carry all 16 rows")
    _ = store^
    _cleanup(root)
    print("[test_phase_a_empty_partition_reads_zero] PASS")


# =============================================================================
# FALSIFYING TEST 3b — EMPTY *MIDDLE* PARTITION through the FULL seal-resolved
# read path (pins the dense-index off-by-one on the NEIGHBOR slices).
#
# Test 3 makes the LAST partition (pid 3) empty; an off-by-one in the dense
# index would tend to slide the missing slot off the END where it is least
# likely to corrupt a neighbor. This variant makes a MIDDLE partition (pid 1)
# empty from EVERY producer, and asserts — through the full seal-resolved
# `read_shuffle_partition` (NOT just SegReader) — that (a) pid 1 reads zero
# rows, AND (b) its neighbors pid 0 and pid 2 read CORRECTLY (their slices are
# not shifted by the empty middle slot). An off-by-one that consumed the empty
# slot's bytes into pid 0 or pid 2 would corrupt those neighbors' offsets/lens.
# =============================================================================
def test_phase_a_empty_middle_partition_through_seal() raises:
    print("[test_phase_a_empty_middle_partition_through_seal] starting...")
    var root = _scratch_root(String("emptymid"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(31)
    var stp = Int64(0)
    var r = Int64(4)
    var n_prod = 4

    # Screen keys so NO row lands in partition 1 (the MIDDLE empty partition);
    # every other row is kept. Every `.seg` trailer then has (off, len=0, rc=0)
    # for pid 1 between two NON-empty neighbors (pid 0 and pid 2).
    var partitioner = HashPartitioner(r)
    var total_written = 0
    for pi in range(n_prod):
        var rows = List[ShuffleRow]()
        var made = 0
        var cand = 0
        while made < 4:
            var key = _bytes(String("m_") + String(pi) + "_" + String(cand))
            cand += 1
            if partitioner.partition_for(key) == 1:
                continue  # skip any key that would land in the empty middle
            var payload = _bytes(
                String("m") + String(pi) + "_r" + String(made)
            )
            rows.append(ShuffleRow(key^, payload^))
            made += 1
        total_written += len(rows)
        _ = sink_shuffle_write(store, sid, stp, Int64(pi), r, rows)

    var seal = seal_step(store, sid, stp, r, _expected_set(n_prod))
    assert_true(seal.is_lifted(), "seal LIFTED with empty MIDDLE partition 1")
    # every plan row's partition-1 slot is dense zero-length.
    for i in range(len(seal.read_plan_producer_ids)):
        var slot1 = seal.dense_slot(i, 1)
        assert_equal(slot1[1], Int64(0), "plan row " + String(i) + " part1 len=0")
        assert_equal(slot1[2], Int64(0), "plan row " + String(i) + " part1 rc=0")

    # The MIDDLE partition reads ZERO through the full seal-resolved path.
    var body1 = read_shuffle_partition(
        store, sid, stp, Int64(1), _expected_set(n_prod)
    )
    assert_equal(len(body1), 0, "empty MIDDLE partition 1 reads ZERO bytes")
    assert_equal(
        len(decode_partition_payloads(body1)),
        0,
        "empty MIDDLE partition 1 yields ZERO rows",
    )

    # NEIGHBOR INTEGRITY: pid 0, 2, 3 between them carry ALL the written rows,
    # decoded cleanly (every payload is a real input — an off-by-one consuming
    # the empty middle slot into a neighbor would corrupt a payload frame and
    # either drop a row or fail to decode). The union must round-trip exactly.
    var inputs = List[List[UInt8]]()
    for pi in range(n_prod):
        var made = 0
        var cand = 0
        while made < 4:
            var key = _bytes(String("m_") + String(pi) + "_" + String(cand))
            cand += 1
            if partitioner.partition_for(key) == 1:
                continue
            inputs.append(
                _bytes(String("m") + String(pi) + "_r" + String(made))
            )
            made += 1
    var union = List[List[UInt8]]()
    for p in range(Int(r)):
        var b = read_shuffle_partition(
            store, sid, stp, Int64(p), _expected_set(n_prod)
        )
        var payloads = decode_partition_payloads(b)
        for k in range(len(payloads)):
            union.append(payloads[k].copy())
    assert_equal(
        len(union), total_written, "neighbors carry ALL rows (no slice shift)"
    )
    for i in range(len(inputs)):
        assert_true(
            _payload_in(union, inputs[i]),
            "input payload " + String(i) + " present (neighbor slices intact)",
        )
    for i in range(len(union)):
        assert_true(
            _payload_in(inputs, union[i]),
            "reduce payload " + String(i) + " is a real input (no corruption)",
        )
    _ = store^
    _cleanup(root)
    print("[test_phase_a_empty_middle_partition_through_seal] PASS")


# =============================================================================
# FALSIFYING TEST 3c — ALL PARTITIONS EMPTY (every producer writes ZERO rows).
#
# Distinct from test 3 (one empty partition): here EVERY producer writes zero
# rows, so EVERY `.seg` trailer is all-zero-length across ALL R partitions. The
# seal must still succeed (the producer set is complete — empty `.seg`s still
# committed `_entries` + dense R zero-length trailers), and EVERY
# `read_shuffle_partition(p)` for p in 0..R must return zero rows and complete
# IMMEDIATELY (never block, never raise) — the whole-step-empty termination case.
# Reverts if the seal refuses to write when committed bodies are all empty, or if
# the read blocks/raises when a partition has zero rows across all producers.
# =============================================================================
def test_phase_a_all_partitions_empty_terminates() raises:
    print("[test_phase_a_all_partitions_empty_terminates] starting...")
    var root = _scratch_root(String("allempty"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(32)
    var stp = Int64(0)
    var r = Int64(4)
    var n_prod = 4

    # Every producer writes ZERO rows -> every `.seg` trailer is all-zero-length
    # across ALL R partitions (R dense (off,0,0) slots, body is empty bytes).
    for pi in range(n_prod):
        var rows = List[ShuffleRow]()  # EMPTY: zero rows
        _ = sink_shuffle_write(store, sid, stp, Int64(pi), r, rows)

    # The seal succeeds: the producer set is complete; an empty producer still
    # appended its `_entries` entry with a dense R zero-length trailer. Reverts
    # if seal_step refused to seal an all-empty step.
    var seal = seal_step(store, sid, stp, r, _expected_set(n_prod))
    assert_true(seal.is_lifted(), "seal LIFTED with ALL partitions empty")
    assert_equal(
        len(seal.committed_producers),
        n_prod,
        "all n_prod empty producers committed (none dropped)",
    )
    # every plan row, every partition, is dense zero-length.
    for i in range(len(seal.read_plan_producer_ids)):
        for p in range(Int(r)):
            var slot = seal.dense_slot(i, p)
            assert_equal(
                slot[1], Int64(0), "row " + String(i) + " part " + String(p) + " len=0"
            )
            assert_equal(
                slot[2], Int64(0), "row " + String(i) + " part " + String(p) + " rc=0"
            )

    # EVERY partition reads ZERO rows and completes immediately (never blocks,
    # never raises). Reverts if read_shuffle_partition blocks/errors when a
    # partition's slices are all zero-length.
    for p in range(Int(r)):
        var body = read_shuffle_partition(
            store, sid, stp, Int64(p), _expected_set(n_prod)
        )
        assert_equal(
            len(body), 0, "partition " + String(p) + " reads ZERO bytes"
        )
        assert_equal(
            len(decode_partition_payloads(body)),
            0,
            "partition " + String(p) + " yields ZERO rows",
        )
    _ = store^
    _cleanup(root)
    print("[test_phase_a_all_partitions_empty_terminates] PASS")


def main() raises:
    test_phase_a_parity_full_roundtrip()
    test_phase_a_seal_blocks_on_absence_and_missing_set()
    test_phase_a_idempotent_replay_no_double_read()
    test_phase_a_empty_partition_reads_zero()
    test_phase_a_empty_middle_partition_through_seal()
    test_phase_a_all_partitions_empty_terminates()
    print(
        "[test_shuffle_seal_phase_a] all 6 tests (parity + 5 falsifying/edge)"
        " PASS"
    )
