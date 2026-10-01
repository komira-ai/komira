# =============================================================================
# tests/test_shuffle_retention_reaper.mojo
#   PER-EPOCH SHUFFLE RETENTION / GC — the FAIL-SAFE cross-epoch whole-epoch
#   reaper that bounds an UNBOUNDED multi-segment continuous stream's shuffle
# storage.
# =============================================================================
#
# Per-epoch retention/GC: the floor is tied to the consumer's CHECKPOINTED
# cursor, NEVER wall-clock.
#
# THE LOAD-BEARING PROPERTY = FAIL-SAFE. The reclaim FLOOR is the MINIMUM
# checkpointed consumer cursor across ALL reducers/consumers (the slowest
# consumer's durable position). An epoch `e` is reclaimable iff `e < floor`
# (STRICTLY below) — an epoch AT the floor is STILL NEEDED by the slowest
# consumer (its cursor points AT it), so reaping it is silent data loss. A
# too-low floor merely wastes storage (recoverable); a too-high floor is
# FORBIDDEN data loss. The reaper NEVER uses wall-clock and NEVER the producer's
# position — only the durable consumer cursor.
#
#   TEST 1 — HAPPY PATH (reap below the floor; retain at/above):
#     Write+seal+fully-consume epochs e0..e3 (advance a consumer cursor).
#     Checkpoint the consumer cursor at e2 (next-to-poll = e2 => read through e1).
#     floor = min({e2}) = 2. reap epochs < 2 -> e0, e1 DELETED (objects gone from
#     the store); e2, e3 RETAINED and STILL READ correctly via
#     read_shuffle_partition.
#
#   TEST 2 — THE DECISIVE OVER-REAP FALSIFIER (fail-before/pass-after):
#     A reaper that reaps AT or ABOVE the floor (deletes e2, which a consumer at
#     cursor=e2 still needs) MUST be caught. The production line uses STRICT
#     `e < floor`. Reading e2 after a CORRECT reap (floor=2) still returns its
#     rows. The fail-before reversion (reap `e <= floor` instead of `e < floor`)
#     deletes e2 -> reading e2 fails/returns empty -> this test's assert fires.
#     The reversion is demonstrated DIRECTLY here by calling reap_epoch on the
#     floor epoch (modelling the `<=` bug) and asserting reading it then FAILS —
#     the inverse-oracle proves the strict-below predicate is what protects e2.
#
#   TEST 3 — THE LAGGING-CONSUMER PINS THE FLOOR (min-across-consumers):
#     A second, SLOWER consumer at cursor=e1 must pin the floor to e1 (the min
#     across consumers). With consumers {cursor=e2 (fast), cursor=e1 (slow)},
#     floor = min(2, 1) = 1. Only e0 is reaped; e1 is RETAINED (the lagging
#     consumer still needs it) and STILL READ correctly. Inverse-oracle: had the
#     floor been the MAX/fast cursor (2), e1 would be gone — assert e1 reads its
#     rows to catch that.
#
# Single-process LocalFs (no infra). Consumes the proven sink_shuffle_write ->
# seal_step -> read_shuffle_partition UNCHANGED + the NEW reaper free fns
# (reclaim_floor / reap_epoch / reap_epochs_below). Network-free.
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
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
from komira_objectstore.shuffle_seal_driver import seal_step
from komira_objectstore.shuffle_retention import (
    reclaim_floor,
    reap_epoch,
    reap_epochs_below,
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
# Scratch root + helpers (the LocalFs harness shape, mirrors the seal tests).
# -----------------------------------------------------------------------------
def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (_scratch_dir() + String("/komira_shuffle_reap_")) + tag + String("_") + String(t)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


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


def _epoch_producer_rows(
    epoch: Int, producer_id: Int, rows_per_producer: Int
) -> List[ShuffleRow]:
    """Deterministic rows; payload is globally unique per (epoch, producer,
    row). The KEY is epoch-independent (stable partition assignment)."""
    var out = List[ShuffleRow]()
    for j in range(rows_per_producer):
        var key = _bytes(String("k_") + String(producer_id) + "_" + String(j))
        var payload = _bytes(
            String("e") + String(epoch) + "_p" + String(producer_id)
            + "_r" + String(j)
        )
        out.append(ShuffleRow(key^, payload^))
    return out^


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


def _read_epoch_row_count(
    store: LocalFsConditionalStore,
    sid: Int64,
    epoch: Int64,
    r: Int64,
    n_prod: Int,
) raises -> Int:
    """Read every partition of an epoch and total the decoded payload count."""
    var total = 0
    for p in range(Int(r)):
        var body = read_shuffle_partition(
            store, sid, epoch, Int64(p), _expected_set(n_prod)
        )
        total += len(decode_partition_payloads(body))
    return total


def _count_epoch_objects(
    store: LocalFsConditionalStore, sid: Int64, epoch: Int64
) raises -> Int:
    """Count durable object keys belonging to epoch `{sid}/{epoch}/` (the
    `.seg` bodies + the `_entries`/`_seal` manifest key families). Portable
    on LocalFs (flat prefix-match returns all keys recursively under the
    root). Zero means the WHOLE epoch family is gone from the store."""
    var prefix = String(sid) + "/" + String(epoch) + "/"
    var res = store.list_with_delimiter(Path.parse(String("")))
    var n = 0
    for i in range(len(res.objects)):
        var loc = res.objects[i].location
        if loc.find(prefix) == 0:
            n += 1
    return n


# =============================================================================
# TEST 1 — HAPPY PATH: reap below the floor, retain at/above.
# =============================================================================
def test_reap_below_floor_retains_at_and_above() raises:
    print("[test_reap_below_floor_retains_at_and_above] starting...")
    var root = _scratch_root(String("happy"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(700)
    var r = Int64(4)
    var n_prod = 4
    var rows_per = 4
    var n_epochs = 4  # e0..e3

    # Write + seal + fully-consume epochs e0..e3 (advance a consumer cursor as it
    # reads through each). Cursor convention = next-to-poll epoch.
    var consumer_cursor = Int64(0)
    for e in range(n_epochs):
        _write_and_seal_epoch(store, sid, Int64(e), r, n_prod, rows_per)
        # consume the epoch fully, then advance the cursor past it.
        var got = _read_epoch_row_count(store, sid, Int64(e), r, n_prod)
        assert_equal(
            got, n_prod * rows_per,
            "epoch " + String(e) + " fully consumed before checkpoint",
        )
        consumer_cursor = Int64(e) + Int64(1)
    # After consuming e0..e3 the cursor sits at n_epochs (next-to-poll past the
    # head). The driver checkpoints whatever cursor it has durably committed.
    assert_equal(
        consumer_cursor, Int64(n_epochs),
        "consumer cursor advanced past every consumed epoch",
    )

    # CHECKPOINT the consumer cursor at e2 (the consumer has durably read through
    # e1; next-to-poll = e2). We model the checkpoint as setting the cursor.
    consumer_cursor = Int64(2)

    # floor = min over all consumers = the single consumer's checkpointed cursor.
    var cursors = List[Int64]()
    cursors.append(consumer_cursor)
    var floor = reclaim_floor(cursors)
    assert_equal(floor, Int64(2), "reclaim_floor = the (single) consumer cursor")

    # All four epochs are durable before the reap.
    for e in range(n_epochs):
        assert_true(
            _count_epoch_objects(store, sid, Int64(e)) > 0,
            "epoch " + String(e) + " has durable objects before reap",
        )

    # Reap every epoch STRICTLY below the floor (e0, e1).
    var stats = reap_epochs_below(store, sid, floor, Int64(0), _expected_set(n_prod))
    assert_equal(stats.floor, Int64(2), "reap used floor=2")
    assert_equal(stats.epochs_reaped, Int64(2), "reaped exactly 2 epochs (e0,e1)")
    assert_true(stats.objects_deleted > Int64(0), "issued DELETE calls")

    # e0, e1 are DELETED (objects gone from the store).
    assert_equal(
        _count_epoch_objects(store, sid, Int64(0)), 0,
        "epoch e0 (< floor) object family is DELETED",
    )
    assert_equal(
        _count_epoch_objects(store, sid, Int64(1)), 0,
        "epoch e1 (< floor) object family is DELETED",
    )
    # e2, e3 are RETAINED and STILL READ correctly via read_shuffle_partition.
    assert_true(
        _count_epoch_objects(store, sid, Int64(2)) > 0,
        "epoch e2 (== floor) object family is RETAINED",
    )
    assert_true(
        _count_epoch_objects(store, sid, Int64(3)) > 0,
        "epoch e3 (> floor) object family is RETAINED",
    )
    assert_equal(
        _read_epoch_row_count(store, sid, Int64(2), r, n_prod),
        n_prod * rows_per,
        "epoch e2 (== floor) STILL reads its full row set after reap",
    )
    assert_equal(
        _read_epoch_row_count(store, sid, Int64(3), r, n_prod),
        n_prod * rows_per,
        "epoch e3 (> floor) STILL reads its full row set after reap",
    )

    # Idempotent re-run: reaping again over the same floor is a no-op (e2/e3 stay).
    var stats2 = reap_epochs_below(
        store, sid, floor, Int64(0), _expected_set(n_prod)
    )
    assert_equal(stats2.epochs_reaped, Int64(2), "re-run reaps the same 2 epochs")
    assert_equal(
        _read_epoch_row_count(store, sid, Int64(2), r, n_prod),
        n_prod * rows_per,
        "epoch e2 STILL reads correctly after idempotent re-run",
    )
    _ = store^
    _cleanup(root)
    print("[test_reap_below_floor_retains_at_and_above] PASS")


# =============================================================================
# TEST 2 — THE DECISIVE OVER-REAP FALSIFIER (fail-before/pass-after).
#
# The production reaper uses STRICT `e < floor`. The fail-before reversion is
# `e <= floor` (reaping the floor epoch e2, which a consumer at cursor=e2 STILL
# needs). We demonstrate that reversion DIRECTLY by calling reap_epoch on the
# floor epoch (modelling the `<=` bug) and asserting that reading e2 then FAILS
# (returns empty / raises) — proving the strict-below predicate is exactly what
# protects the floor epoch. The pass-after path (reap_epochs_below with `<`)
# leaves e2 fully readable.
# =============================================================================
def test_over_reap_at_floor_is_data_loss() raises:
    print("[test_over_reap_at_floor_is_data_loss] starting...")
    var root = _scratch_root(String("overreap"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(710)
    var r = Int64(4)
    var n_prod = 4
    var rows_per = 4

    # Write + seal e0, e1, e2.
    for e in range(3):
        _write_and_seal_epoch(store, sid, Int64(e), r, n_prod, rows_per)

    # Consumer checkpointed at e2 (still needs e2). floor = 2.
    var cursors = List[Int64]()
    cursors.append(Int64(2))
    var floor = reclaim_floor(cursors)
    assert_equal(floor, Int64(2), "floor = the consumer cursor (still needs e2)")

    # ---- PASS-AFTER: the CORRECT strict-below reap leaves e2 fully readable. ----
    var stats = reap_epochs_below(store, sid, floor, Int64(0), _expected_set(n_prod))
    assert_equal(
        stats.epochs_reaped, Int64(2),
        "strict-below reap reclaims e0,e1 only (NOT the floor epoch e2)",
    )
    assert_equal(
        _read_epoch_row_count(store, sid, Int64(2), r, n_prod),
        n_prod * rows_per,
        "e2 (== floor) STILL reads its full row set under the CORRECT reaper"
        " (strict-below is what protects the floor epoch)",
    )

    # ---- FAIL-BEFORE DEMONSTRATION: the `e <= floor` bug reaps the floor epoch.
    # Calling reap_epoch directly on e2 models a reaper that reclaims AT the floor
    # (the off-by-one `<=` regression). After it, reading e2 MUST fail/return
    # empty — the inverse-oracle that the strict-below predicate prevents. This
    # confirms WHY the production predicate is `<` not `<=`: had reap_epochs_below
    # used `<=`, e2's family would be gone and the consumer at cursor=e2 would
    # silently under-read. ----
    _ = reap_epoch(store, sid, Int64(2), _expected_set(n_prod))
    assert_equal(
        _count_epoch_objects(store, sid, Int64(2)), 0,
        "the `<=` (reap-at-floor) bug DELETES e2's object family",
    )
    # Reading e2 after the over-reap now fails (seal absent -> raise) OR returns
    # empty — either way the consumer at cursor=e2 has LOST its data. Assert the
    # read no longer returns the full row set (the data-loss the strict predicate
    # forbids).
    var lost = False
    var read_rows = -1
    try:
        read_rows = _read_epoch_row_count(store, sid, Int64(2), r, n_prod)
    except e:
        lost = True  # seal gone -> block-on-absence raise (the expected loss)
        _ = e
    if not lost:
        # If it did not raise, it must have under-read (NOT the full row set).
        assert_false(
            read_rows == n_prod * rows_per,
            "over-reap (reap-at-floor) caused e2 to UNDER-READ (data loss the"
            " strict-below predicate prevents)",
        )
    else:
        assert_true(
            lost,
            "over-reap (reap-at-floor) caused e2's seal-block-on-absence raise"
            " (data loss the strict-below predicate prevents)",
        )
    _ = store^
    _cleanup(root)
    print("[test_over_reap_at_floor_is_data_loss] PASS")


# =============================================================================
# TEST 3 — THE LAGGING CONSUMER PINS THE FLOOR (min-across-consumers).
#
# Two consumers: a FAST one at cursor=e2 and a SLOW one at cursor=e1. The floor
# is the MIN across consumers = 1 (the slow consumer still needs e1). Only e0 is
# reaped; e1 is RETAINED and STILL READ correctly. Inverse-oracle: had the floor
# been the MAX (the fast cursor, 2), e1 would have been reaped — asserting e1
# reads its full rows catches that.
# =============================================================================
def test_lagging_consumer_pins_floor() raises:
    print("[test_lagging_consumer_pins_floor] starting...")
    var root = _scratch_root(String("lag"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(720)
    var r = Int64(4)
    var n_prod = 4
    var rows_per = 4

    # Write + seal e0, e1, e2.
    for e in range(3):
        _write_and_seal_epoch(store, sid, Int64(e), r, n_prod, rows_per)

    # Two consumers: fast (cursor=e2, read through e1) + slow/lagging (cursor=e1,
    # read through e0; STILL needs e1).
    var cursors = List[Int64]()
    cursors.append(Int64(2))  # fast consumer
    cursors.append(Int64(1))  # lagging consumer pins the floor
    var floor = reclaim_floor(cursors)
    assert_equal(
        floor, Int64(1),
        "floor = MIN across consumers = the lagging cursor (1), NOT the fast (2)",
    )

    # Reap epochs strictly below the (pinned) floor -> only e0.
    var stats = reap_epochs_below(store, sid, floor, Int64(0), _expected_set(n_prod))
    assert_equal(
        stats.epochs_reaped, Int64(1),
        "only e0 reaped (the lagging consumer pins the floor at 1, retaining e1)",
    )
    assert_equal(
        _count_epoch_objects(store, sid, Int64(0)), 0,
        "epoch e0 (< floor) is DELETED",
    )
    # e1 is RETAINED because the lagging consumer still needs it.
    assert_true(
        _count_epoch_objects(store, sid, Int64(1)) > 0,
        "epoch e1 is RETAINED — the lagging consumer (cursor=1) still needs it",
    )
    # Inverse-oracle: e1 STILL reads its full row set (had the floor been the
    # fast/max cursor 2, e1 would be gone and this would fail).
    assert_equal(
        _read_epoch_row_count(store, sid, Int64(1), r, n_prod),
        n_prod * rows_per,
        "epoch e1 STILL reads its full row set (the lagging consumer's data is"
        " preserved — min-across-consumers floor is what protects it)",
    )
    # e2 (above the floor) is of course retained too.
    assert_true(
        _count_epoch_objects(store, sid, Int64(2)) > 0,
        "epoch e2 (> floor) is RETAINED",
    )

    # And the EMPTY-consumer fail-safe: reclaim_floor RAISES on no consumers
    # (a missing consumer must NOT permit reclamation).
    var raised_empty = False
    try:
        var _f = reclaim_floor(List[Int64]())
    except e:
        raised_empty = True
        _ = e
    assert_true(
        raised_empty,
        "reclaim_floor RAISES on an EMPTY consumer set (fail-safe: a missing"
        " consumer must not permit reclamation)",
    )
    _ = store^
    _cleanup(root)
    print("[test_lagging_consumer_pins_floor] PASS")


def main() raises:
    test_reap_below_floor_retains_at_and_above()
    test_over_reap_at_floor_is_data_loss()
    test_lagging_consumer_pins_floor()
    print(
        "[test_shuffle_retention_reaper] all 3 per-epoch retention/GC tests PASS"
    )
