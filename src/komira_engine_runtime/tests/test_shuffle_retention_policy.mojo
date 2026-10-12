# =============================================================================
# test_shuffle_retention_policy: `ShuffleRetentionPolicy[S]`, the driver-side
# retention policy around `komira_shuffle.retention`.
# =============================================================================
#
# Every case writes and seals real shuffle epochs into a `LocalFsConditionalStore`
# under the test's private `TEST_TMPDIR`, drives the policy, and then counts
# each epoch's durable objects and reads the retained epochs back. What each
# case proves, and the defect it catches:
#
#   * floor = MIN across consumers: cursors {3, 1} reap epoch 0 only; epochs
#     1..3 stay readable. Catches a floor taken as the max (or the first)
#     cursor, which would delete epoch 1 under the slow consumer.
#   * successive passes: a second pass at floor 3 reaps 1 and 2 only and
#     `lowest_live_epoch` moves 1 -> 3; the totals add up (3 epochs). Catches a
#     policy that does not persist `lowest_live_epoch` (it would reap from 0
#     again and count epoch 0 twice) and one that reaps the floor epoch.
#   * fail-safe: an empty cursor list and an all-`Int64.MAX` list retain
#     everything and do not count as passes. Catches a policy that treats "no
#     consumer" as "nothing needed".
#   * lagging consumer: a floor at or below `lowest_live_epoch` deletes
#     nothing and returns False (but counts as a pass that reached a floor).
#   * cadence: with `reap_every_n_rounds = 3` the first two calls skip and the
#     third reaps. Catches a cadence counter that is not reset or not ticked.
#   * constructor clamps: a cadence <= 0 means every round and a negative
#     start epoch means 0.
# =============================================================================

from std.time import perf_counter_ns
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_shuffle.sink import ShuffleRow, sink_shuffle_write
from komira_shuffle.source import (
    decode_partition_payloads,
    read_shuffle_partition,
)
from komira_shuffle.seal_driver import seal_step
from komira_runtime_paths import test_tmpdir

from komira_engine_runtime.shuffle_retention_policy import (
    ShuffleRetentionPolicy,
)

comptime _SID: Int64 = 7
comptime _R: Int64 = 2
comptime _N_PROD: Int = 2
comptime _ROWS: Int = 3
comptime _EPOCHS: Int = 4


def _root(tag: String) raises -> String:
    return (
        test_tmpdir() + "/retention_policy_" + tag + "_"
        + String(UInt64(perf_counter_ns()))
    )


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _producers() -> List[Int64]:
    var out = List[Int64]()
    for i in range(_N_PROD):
        out.append(Int64(i))
    return out^


def _seeded_store(tag: String) raises -> LocalFsConditionalStore:
    """A store holding sealed epochs 0.._EPOCHS-1, each `_N_PROD` producers x
    `_ROWS` rows over `_R` partitions."""
    var store = LocalFsConditionalStore(_root(tag))
    for e in range(_EPOCHS):
        for p in range(_N_PROD):
            var rows = List[ShuffleRow]()
            for j in range(_ROWS):
                rows.append(
                    ShuffleRow(
                        _bytes("k_" + String(p) + "_" + String(j)),
                        _bytes(
                            "e" + String(e) + "_p" + String(p) + "_r" + String(j)
                        ),
                    )
                )
            _ = sink_shuffle_write(store, _SID, Int64(e), Int64(p), _R, rows)
        _ = seal_step(store, _SID, Int64(e), _R, _producers())
    return store^


def _epoch_objects(store: LocalFsConditionalStore, epoch: Int) raises -> Int:
    """Durable objects under `{sid}/{epoch}/`; 0 means the epoch is gone."""
    var prefix = String(_SID) + "/" + String(epoch) + "/"
    var res = store.list_with_delimiter(Path.parse(String("")))
    var n = 0
    for i in range(len(res.objects)):
        if res.objects[i].location.find(prefix) == 0:
            n += 1
    return n


def _epoch_rows(store: LocalFsConditionalStore, epoch: Int) raises -> Int:
    var total = 0
    for p in range(Int(_R)):
        var body = read_shuffle_partition(
            store, _SID, Int64(epoch), Int64(p), _producers()
        )
        total += len(decode_partition_payloads(body))
    return total


def _cursors(a: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(a)
    return out^


def _cursors(a: Int64, b: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(a)
    out.append(b)
    return out^


def _assert_live(store: LocalFsConditionalStore, epoch: Int, label: String) raises:
    assert_true(_epoch_objects(store, epoch) > 0, label + ": objects present")
    assert_equal(_epoch_rows(store, epoch), _N_PROD * _ROWS, label + ": rows")


def _assert_gone(store: LocalFsConditionalStore, epoch: Int, label: String) raises:
    assert_equal(_epoch_objects(store, epoch), 0, label + ": objects gone")


def test_floor_is_the_minimum_consumer_cursor() raises:
    var store = _seeded_store("min")
    var policy = ShuffleRetentionPolicy(store.clone(), _SID, _producers())
    # A fast consumer at epoch 3 and a slow one at epoch 1: the floor is 1.
    assert_true(policy.maybe_reap(_cursors(Int64(3), Int64(1))))
    _assert_gone(store, 0, "epoch 0")
    _assert_live(store, 1, "epoch 1 (slow consumer's)")
    _assert_live(store, 2, "epoch 2")
    _assert_live(store, 3, "epoch 3")
    assert_equal(policy.last_floor(), Int64(1))
    assert_equal(policy.lowest_live_epoch(), Int64(1))
    assert_equal(policy.total_epochs_reaped(), Int64(1))
    assert_true(policy.total_objects_deleted() > Int64(0))
    assert_equal(policy.reap_passes(), Int64(1))
    assert_true(policy.last_pass_reaped())


def test_successive_passes_reap_only_new_epochs() raises:
    var store = _seeded_store("succ")
    var policy = ShuffleRetentionPolicy(store.clone(), _SID, _producers())
    assert_true(policy.maybe_reap(_cursors(Int64(1))))
    var deleted_first = policy.total_objects_deleted()
    assert_true(policy.maybe_reap(_cursors(Int64(3))))
    _assert_gone(store, 0, "epoch 0")
    _assert_gone(store, 1, "epoch 1")
    _assert_gone(store, 2, "epoch 2")
    _assert_live(store, 3, "epoch 3 (at the floor)")
    assert_equal(policy.lowest_live_epoch(), Int64(3))
    # Epoch 0 is counted once: the second pass started at 1, not 0.
    assert_equal(policy.total_epochs_reaped(), Int64(3))
    assert_true(policy.total_objects_deleted() > deleted_first)
    assert_equal(policy.reap_passes(), Int64(2))
    var snap = policy.observability()
    assert_equal(snap.last_floor, Int64(3))
    assert_equal(snap.lowest_live_epoch, Int64(3))
    assert_equal(snap.total_epochs_reaped, Int64(3))
    assert_equal(snap.total_objects_deleted, policy.total_objects_deleted())
    assert_equal(snap.reap_passes, Int64(2))
    assert_true(snap.last_pass_reaped)


def test_no_consumer_floor_retains_everything() raises:
    var store = _seeded_store("failsafe")
    var policy = ShuffleRetentionPolicy(store.clone(), _SID, _producers())
    assert_false(policy.maybe_reap(List[Int64]()))
    assert_false(policy.maybe_reap(_cursors(Int64.MAX, Int64.MAX)))
    for e in range(_EPOCHS):
        _assert_live(store, e, "epoch " + String(e))
    assert_equal(policy.reap_passes(), Int64(0))
    assert_equal(policy.total_epochs_reaped(), Int64(0))
    assert_equal(policy.last_floor(), Int64.MIN)
    assert_false(policy.last_pass_reaped())


def test_lagging_consumer_reaps_nothing() raises:
    var store = _seeded_store("lag")
    var policy = ShuffleRetentionPolicy(
        store.clone(), _SID, _producers(), start_lowest_live_epoch=Int64(2)
    )
    assert_false(policy.maybe_reap(_cursors(Int64(2))))
    assert_false(policy.maybe_reap(_cursors(Int64(1))))
    for e in range(_EPOCHS):
        _assert_live(store, e, "epoch " + String(e))
    assert_equal(policy.lowest_live_epoch(), Int64(2))
    assert_equal(policy.last_floor(), Int64(1))
    assert_equal(policy.total_epochs_reaped(), Int64(0))
    assert_equal(policy.reap_passes(), Int64(2))
    assert_false(policy.last_pass_reaped())


def test_cadence_skips_then_reaps() raises:
    var store = _seeded_store("cadence")
    var policy = ShuffleRetentionPolicy(
        store.clone(), _SID, _producers(), reap_every_n_rounds=3
    )
    assert_false(policy.maybe_reap(_cursors(Int64(2))))
    assert_false(policy.maybe_reap(_cursors(Int64(2))))
    _assert_live(store, 0, "epoch 0 after two skipped rounds")
    assert_equal(policy.reap_passes(), Int64(0))
    assert_true(policy.maybe_reap(_cursors(Int64(2))))
    _assert_gone(store, 0, "epoch 0")
    _assert_gone(store, 1, "epoch 1")
    _assert_live(store, 2, "epoch 2")
    # The counter restarted: the next two rounds skip again.
    assert_false(policy.maybe_reap(_cursors(Int64(3))))
    assert_false(policy.maybe_reap(_cursors(Int64(3))))
    _assert_live(store, 2, "epoch 2 after two more skipped rounds")
    assert_true(policy.maybe_reap(_cursors(Int64(3))))
    _assert_gone(store, 2, "epoch 2")
    assert_equal(policy.reap_passes(), Int64(2))


def test_constructor_clamps() raises:
    var store = _seeded_store("clamp")
    var policy = ShuffleRetentionPolicy(
        store.clone(),
        _SID,
        _producers(),
        reap_every_n_rounds=0,
        start_lowest_live_epoch=Int64(-5),
    )
    assert_equal(policy.lowest_live_epoch(), Int64(0))
    # Cadence 0 means every round: the first call reaps.
    assert_true(policy.maybe_reap(_cursors(Int64(1))))
    _assert_gone(store, 0, "epoch 0")
    _assert_live(store, 1, "epoch 1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
