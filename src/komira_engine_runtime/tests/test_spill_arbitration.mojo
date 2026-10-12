# =============================================================================
# test_spill_arbitration.mojo: the intra-operator arbitrator, the routed
# grow, the operator coordinator and the arbitrator policies.
# =============================================================================
#
# The fixture `_Part` is a partition stand-in: a resident byte count, an age,
# a can-spill flag; spilling writes one small chunk and drops the resident
# bytes to 0.
#
# What each test proves (and the defect it catches):
#   1. test_no_pressure_spills_nothing: at exactly the budget nothing spills
#      (strict greater-than), one byte over spills. Catches `>=` vs `>`.
#   2. test_oldest_spillable_is_the_victim: the oldest partition that can
#      spill is chosen; an older one that cannot spill is skipped. Catches a
#      victim pick that ignores `can_spill` or picks the youngest.
#   3. test_no_spillable_partition_counts_no_victim: pressure with nothing
#      spillable frees 0 and counts a no-victim pass.
#   4. test_unimplemented_policies_raise: LARGEST_FIRST and
#      PROPORTIONAL_RESERVATION refuse instead of silently picking.
#   5. test_routed_grow_retry_succeeds_after_own_spill: a denied grow spills
#      one of the breaker's own partitions, releases the freed bytes and the
#      retry succeeds. Catches a retry that never releases (it would deny
#      again on an unchanged reservation).
#   6. test_routed_grow_happy_path_and_no_victim: a grow that fits never
#      touches the arbitrator; a denied grow with nothing to spill is False.
#   7. test_coordinator_spills_oldest_partition_and_gates: the coordinator
#      reports its slab's bytes and its own age, spills one partition per
#      call, honours `set_can_spill`, and refuses a direct restore.
#   8. test_policy_tags: the three policy constructors are distinct and
#      the default is OLDEST_FIRST.
# =============================================================================

from std.ffi import external_call
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_libc.posix import _read_env

from komira_engine_runtime.memory.reservation import MemoryReservation
from komira_engine_runtime.spill.intra_op_slab_arbitrator import (
    IntraOpSlabArbitrator,
)
from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_engine_runtime.spill.op_coordinator import SpillableOpCoordinator
from komira_engine_runtime.spill.policies import ArbitratorPolicy
from komira_engine_runtime.spill.routed_grow import try_grow_intra_op_routed
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.spillable_op import SpillableOp


# Scratch files go under $TEST_TMPDIR (set by the test runner, unique per
# action), else $TMPDIR. `_read_env` rather than `std.os.getenv`:
# komira_libc.posix owns the one `getenv` declaration in the link.
def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


def _storage(tag: String) raises -> LocalDiskSpillStorage:
    var pid = external_call["getpid", Int32]()
    return LocalDiskSpillStorage.with_unlimited(
        _scratch_dir()
        + String("/komira-spill-arbitration-")
        + String(Int(pid))
        + String("-")
        + tag
    )


struct _Part(SpillableOp):
    var _resident: Int64
    var _age: UInt64
    var _spillable: Bool
    var _spilled: Bool

    def __init__(out self, resident: Int64, age: UInt64, spillable: Bool):
        self._resident = resident
        self._age = age
        self._spillable = spillable
        self._spilled = False

    def memory_usage_bytes(self) -> Int64:
        return self._resident

    def age_ticks(self) -> UInt64:
        return self._age

    def can_spill(self) -> Bool:
        return self._spillable and not self._spilled

    def spill_to_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises -> Int64:
        var oab = OwnedAlignedBuffer(capacity=1)
        oab.view_mut().write_u8_at(0, UInt8(1))
        _ = storage.write_chunk(SharedAlignedBuffer[HeapRegion].from_owned(oab^))
        var freed = self._resident
        self._resident = 0
        self._spilled = True
        return freed

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        _ = storage

    def spilled(self) -> Bool:
        return self._spilled


comptime _Arb = IntraOpSlabArbitrator[_Part, LocalDiskSpillStorage]


def _slab(*parts: Tuple[Int, Int, Bool]) -> Slab[_Part]:
    var slab = Slab[_Part].with_capacity(len(parts))
    for p in parts:
        slab.append(_Part(Int64(p[0]), UInt64(p[1]), p[2]))
    return slab^


def test_no_pressure_spills_nothing() raises:
    var arb = _Arb(_storage("nopressure"), Int64(100))
    var slab = _slab((60, 1, True), (30, 2, True))
    # 90 resident + 10 == 100: exactly the budget, no pressure.
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 2, Int64(10))), 0)
    assert_equal(Int(arb.spill_event_count()), 0)
    assert_equal(Int(arb.total_resident_bytes(slab, 2)), 90)
    # One byte more: pressure, the oldest (60 B) spills.
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 2, Int64(11))), 60)
    assert_equal(Int(arb.spill_event_count()), 1)
    assert_equal(arb.storage_ref().num_live_chunks(), 1)
    arb.storage_mut().cleanup()


def test_oldest_spillable_is_the_victim() raises:
    var arb = _Arb(_storage("oldest"), Int64(10))
    # age 1 cannot spill; age 3 is the oldest that can; age 7 is younger.
    var slab = _slab((50, 1, False), (40, 7, True), (20, 3, True))
    var freed = arb.pressure_check_and_arbitrate(slab, 3, Int64(1))
    assert_equal(Int(freed), 20)
    assert_false(slab[0].spilled(), "an unspillable partition is skipped")
    assert_false(slab[1].spilled(), "a younger partition stays")
    assert_true(slab[2].spilled(), "the oldest spillable partition spills")
    # Only the first `slab_len` slots are considered.
    var freed2 = arb.pressure_check_and_arbitrate(slab, 1, Int64(1))
    assert_equal(Int(freed2), 0)
    arb.storage_mut().cleanup()


def test_no_spillable_partition_counts_no_victim() raises:
    var arb = _Arb(_storage("novictim"), Int64(10))
    var slab = _slab((50, 1, False))
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 1, Int64(1))), 0)
    assert_equal(Int(arb.no_victim_count()), 1)
    assert_equal(Int(arb.spill_event_count()), 0)
    arb.storage_mut().cleanup()


def test_unimplemented_policies_raise() raises:
    var slab = _slab((50, 1, True))
    var largest = _Arb(
        _storage("largest"), Int64(10), ArbitratorPolicy.largest_first()
    )
    with assert_raises(contains="LARGEST_FIRST"):
        _ = largest.pressure_check_and_arbitrate(slab, 1, Int64(1))
    var prop = _Arb(
        _storage("prop"), Int64(10), ArbitratorPolicy.proportional_reservation()
    )
    with assert_raises(contains="PROPORTIONAL_RESERVATION"):
        _ = prop.pressure_check_and_arbitrate(slab, 1, Int64(1))
    # Under budget, no policy is consulted.
    assert_equal(Int(prop.pressure_check_and_arbitrate(slab, 0, Int64(1))), 0)
    largest.storage_mut().cleanup()
    prop.storage_mut().cleanup()


def test_routed_grow_retry_succeeds_after_own_spill() raises:
    var arb = _Arb(_storage("routed"), Int64(100))
    var slab = _slab((60, 1, True), (40, 2, True))
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(100), "the breaker holds its 100 partition bytes")
    # 50 more is denied; the arbitrator spills the 60 B partition; the
    # reservation releases 60 (held 40) and 40 + 50 fits.
    assert_true(try_grow_intra_op_routed(r, arb, slab, 2, 50))
    assert_equal(r.held_bytes(), 90)
    assert_true(slab[0].spilled())
    assert_false(slab[1].spilled())
    assert_equal(r.try_grow_denied_count(), 1)
    arb.storage_mut().cleanup()


def test_routed_grow_happy_path_and_no_victim() raises:
    var arb = _Arb(_storage("routed2"), Int64(100))
    var slab = _slab((60, 1, False))
    var r = MemoryReservation.with_budget(100)
    assert_true(try_grow_intra_op_routed(r, arb, slab, 1, 30))
    assert_equal(Int(arb.no_victim_count()), 0, "a fit never asks the arbitrator")
    # Held 30; 80 more is denied and nothing can spill.
    assert_false(try_grow_intra_op_routed(r, arb, slab, 1, 80))
    assert_equal(Int(arb.no_victim_count()), 1)
    assert_equal(r.held_bytes(), 30)
    arb.storage_mut().cleanup()


def test_coordinator_spills_oldest_partition_and_gates() raises:
    var inner = _Arb(_storage("coord"), Int64(1000))
    var coord = SpillableOpCoordinator[_Part, LocalDiskSpillStorage](
        inner^, _slab((70, 5, True), (30, 2, True), (99, 9, True)), 2, 42
    )
    assert_equal(Int(coord.memory_usage_bytes()), 100, "only live slots count")
    assert_equal(Int(coord.age_ticks()), 42)
    assert_true(coord.can_spill())
    var outer = _storage("coord-outer")
    # Each call spills one partition, oldest first, even under budget.
    assert_equal(Int(coord.spill_to_storage(outer)), 30)
    assert_equal(Int(coord.spill_to_storage(outer)), 70)
    assert_equal(Int(coord.spill_to_storage(outer)), 0)
    assert_equal(Int(coord.spill_event_count()), 2)
    assert_equal(Int(coord.no_victim_count()), 1)
    assert_false(coord.slab_ref()[2].spilled(), "slots past slab_len stay")
    coord.set_can_spill(False)
    assert_false(coord.can_spill())
    with assert_raises(contains="not invoked directly"):
        coord.restore_from_storage(outer)
    coord.arbitrator_mut().storage_mut().cleanup()
    outer.cleanup()


def test_policy_tags() raises:
    var d = ArbitratorPolicy()
    assert_true(d.is_oldest_first())
    assert_true(ArbitratorPolicy.largest_first().is_largest_first())
    assert_true(
        ArbitratorPolicy.proportional_reservation().is_proportional_reservation()
    )
    assert_true(ArbitratorPolicy.oldest_first() == d)
    assert_true(ArbitratorPolicy.largest_first() != d)


def main() raises:
    var suite = TestSuite()
    suite.test[test_no_pressure_spills_nothing]()
    suite.test[test_oldest_spillable_is_the_victim]()
    suite.test[test_no_spillable_partition_counts_no_victim]()
    suite.test[test_unimplemented_policies_raise]()
    suite.test[test_routed_grow_retry_succeeds_after_own_spill]()
    suite.test[test_routed_grow_happy_path_and_no_victim]()
    suite.test[test_coordinator_spills_oldest_partition_and_gates]()
    suite.test[test_policy_tags]()
    suite^.run()
