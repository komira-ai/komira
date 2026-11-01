# =============================================================================
# test_spill_arbitration.mojo: the intra-operator arbitrator, the routed
# grow, the operator coordinator and the arbitrator policies.
# =============================================================================
#
# The fixture `_Part` is a partition stand-in: a resident byte count, an age,
# a can-spill flag; spilling writes one small chunk and drops the resident
# bytes to 0.
#
# Every test is deterministic: no clock, no threads. Behaviour is observed
# through bytes freed, the reservation tally, the arbitrator's event counters
# and which partitions report `spilled()`.
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
#      retry succeeds. Catches a retry that never releases.
#   6. test_routed_grow_happy_path_and_no_victim: a grow that fits never
#      touches the arbitrator; a denied grow with nothing to spill is False
#      and leaves the reservation as it was.
#   7. test_coordinator_spills_oldest_partition_and_gates: the coordinator
#      reports its slab's bytes and its own age, spills one partition per
#      call, honours `set_can_spill`, and refuses a direct restore.
#   8. test_policy_tags: the three policy constructors are distinct and
#      the default is OLDEST_FIRST.
#   9. test_routed_grow_sequence_oldest_first_in_budget: a
#      scripted run of grows spills partitions in age order, one per denied
#      grow, and the reservation never passes its budget after a grant.
#  10. test_refused_grow_leaves_reservation_unchanged: a negative grow, a grow
#      above the whole budget (including Int.MAX) and a grow with nothing to
#      spill return False, spill nothing and leave the tally as it was.
#      Catches a refusal that still spills a partition or releases bytes.
#  11. test_retry_refused_after_spill_keeps_the_released_bytes: when the spill
#      cannot make room, the freed bytes stay released and the result is
#      False.
#  12. test_release_and_regrant_through_the_routed_grow: a granted grow is
#      released, the spilled partition restored and charged again, and a
#      second routed grow spills it once more within the budget.
#  13. test_restored_partition_can_spill_again: a restored partition is
#      resident again and is a victim again; a spilled one is not picked twice.
#  14. test_huge_grow_is_pressure_not_wrap: Int64.MAX of growth is pressure
#      (a wrapped sum would read as none); the budget test cannot wrap.
#  15. test_two_level_spills_oldest_partition_of_oldest_operator:
#      an outer arbitrator over two coordinators spills the operator with the
#      smaller age, then that operator's oldest partition; a closed gate
#      moves the choice to the other operator.
#      A coordinator with no spillable partition left reports it cannot spill.
#  16. test_coordinator_spills_even_with_an_unbounded_budget: the forced spill
#      does not depend on the inner budget, including Int64.MAX.
#  17. test_grow_of_exactly_the_whole_budget_spills_then_grants: a grow equal
#      to the budget is not refused up front. Catches `>` turned into `>=`.
#  18. test_equal_ages_spill_the_lowest_index: a tie goes to the lowest
#      index. Catches a victim pick that takes the last equal-age slot.
#  19. test_a_raising_arbitration_leaves_the_reservation_unchanged: an
#      unimplemented policy and a victim whose spill raises both propagate
#      with the tally, the partition and the storage untouched.
#  20. test_zero_budget_arbitrators: budget 0 with nothing resident is not
#      pressure for a zero grow; with nothing spillable it counts no victim.
#  21. test_outer_arbitrator_with_nothing_spillable_frees_nothing: every
#      operator gated off yields 0 and writes no chunk.
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
from komira_engine_runtime.spill.policies import (
    ArbitratorPolicy,
    exceeds_budget,
)
from komira_engine_runtime.spill.routed_grow import try_grow_intra_op_routed
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.spill_arbitrator import (
    SpillableOpBlock,
    SpillArbitrator,
)
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
    var _full: Int64
    var _age: UInt64
    var _spillable: Bool
    var _spilled: Bool
    var _fails: Bool

    def __init__(
        out self,
        resident: Int64,
        age: UInt64,
        spillable: Bool,
        fails: Bool = False,
    ):
        self._fails = fails
        self._resident = resident
        self._full = resident
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
        if self._fails:
            raise Error("_Part: scripted spill failure")
        var oab = OwnedAlignedBuffer(capacity=1)
        oab.view_mut().write_u8_at(0, UInt8(1))
        _ = storage.write_chunk(
            SharedAlignedBuffer[HeapRegion].from_owned(oab^)
        )
        var freed = self._resident
        self._resident = 0
        self._spilled = True
        return freed

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        _ = storage
        self._resident = self._full
        self._spilled = False

    def spilled(self) -> Bool:
        return self._spilled


comptime _Arb = IntraOpSlabArbitrator[_Part, LocalDiskSpillStorage]


def _failing_slab(resident: Int, age: Int) -> Slab[_Part]:
    var slab = Slab[_Part].with_capacity(1)
    slab.append(_Part(Int64(resident), UInt64(age), True, True))
    return slab^


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
    assert_equal(
        Int(arb.no_victim_count()), 0, "a fit never asks the arbitrator"
    )
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
    coord.set_can_spill(False)
    assert_false(coord.can_spill(), "a closed gate")
    coord.set_can_spill(True)
    assert_true(coord.can_spill())
    var outer = _storage("coord-outer")
    # Each call spills one partition, oldest first, even under budget.
    assert_equal(Int(coord.spill_to_storage(outer)), 30)
    assert_equal(Int(coord.spill_to_storage(outer)), 70)
    assert_equal(Int(coord.spill_to_storage(outer)), 0)
    assert_false(coord.can_spill(), "nothing left to spill")
    assert_equal(Int(coord.spill_event_count()), 2)
    assert_equal(Int(coord.no_victim_count()), 1)
    assert_false(coord.slab_ref()[2].spilled(), "slots past slab_len stay")
    with assert_raises(contains="not invoked directly"):
        coord.restore_from_storage(outer)
    coord.arbitrator_mut().storage_mut().cleanup()
    outer.cleanup()


def test_policy_tags() raises:
    var d = ArbitratorPolicy()
    assert_true(d.is_oldest_first())
    assert_true(ArbitratorPolicy.largest_first().is_largest_first())
    var prop = ArbitratorPolicy.proportional_reservation()
    assert_true(prop.is_proportional_reservation())
    assert_true(ArbitratorPolicy.oldest_first() == d)
    assert_true(ArbitratorPolicy.largest_first() != d)


def test_routed_grow_sequence_oldest_first_in_budget() raises:
    # Budget 0: any denied grow of the reservation is pressure for the slab.
    var arb = _Arb(_storage("sequence"), Int64(0))
    # Ages 1, 2, 3: slot 0 is the oldest. All 100 bytes are held.
    var slab = _slab((40, 1, True), (30, 2, True), (30, 3, True))
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(100))

    # 25 more: denied, slot 0 (40 B) spills, held 60, then 60 + 25 = 85.
    assert_true(try_grow_intra_op_routed(r, arb, slab, 3, 25))
    assert_equal(r.held_bytes(), 85)
    assert_true(slab[0].spilled())
    assert_false(slab[1].spilled())
    assert_false(slab[2].spilled())
    assert_true(r.held_bytes() <= r.budget_bytes())

    # Slot 1 (30 B) is next: held 55, then 80.
    assert_true(try_grow_intra_op_routed(r, arb, slab, 3, 25))
    assert_equal(r.held_bytes(), 80)
    assert_true(slab[1].spilled())
    assert_false(slab[2].spilled())
    assert_true(r.held_bytes() <= r.budget_bytes())

    # Slot 2 last: held 50, then 75.
    assert_true(try_grow_intra_op_routed(r, arb, slab, 3, 25))
    assert_equal(r.held_bytes(), 75)
    assert_true(slab[2].spilled())
    assert_true(r.held_bytes() <= r.budget_bytes())

    # An exact fit needs no spill.
    var events = arb.spill_event_count()
    assert_true(try_grow_intra_op_routed(r, arb, slab, 3, 25))
    assert_equal(r.held_bytes(), 100)
    assert_equal(Int(arb.spill_event_count()), Int(events))

    # One byte more: nothing is left to spill, so it is refused unchanged.
    assert_false(try_grow_intra_op_routed(r, arb, slab, 3, 1))
    assert_equal(r.held_bytes(), 100)
    assert_equal(Int(arb.spill_event_count()), 3)
    assert_equal(Int(arb.no_victim_count()), 1)
    assert_equal(arb.storage_ref().num_live_chunks(), 3)
    arb.storage_mut().cleanup()


def test_refused_grow_leaves_reservation_unchanged() raises:
    var arb = _Arb(_storage("refused"), Int64(100))
    var slab = _slab((60, 1, True), (40, 2, True))
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(100))
    var denied = r.try_grow_denied_count()

    # A negative grow, one above the whole budget and Int.MAX are refused:
    # no partition spills and the tally does not move.
    assert_false(try_grow_intra_op_routed(r, arb, slab, 2, -5))
    assert_false(try_grow_intra_op_routed(r, arb, slab, 2, 101))
    assert_false(try_grow_intra_op_routed(r, arb, slab, 2, Int.MAX))
    assert_equal(r.held_bytes(), 100)
    assert_equal(r.try_grow_denied_count(), denied + 3)
    assert_equal(Int(arb.spill_event_count()), 0)
    assert_equal(Int(arb.no_victim_count()), 0)
    assert_false(slab[0].spilled())
    assert_false(slab[1].spilled())
    assert_equal(arb.storage_ref().num_live_chunks(), 0)

    # A request the budget allows still spills the oldest and is granted:
    # 60 B released, 40 + 60 fits.
    assert_true(try_grow_intra_op_routed(r, arb, slab, 2, 60))
    assert_true(slab[0].spilled())
    assert_false(slab[1].spilled())
    assert_equal(r.held_bytes(), 100)
    arb.storage_mut().cleanup()


def test_retry_refused_after_spill_keeps_the_released_bytes() raises:
    var arb = _Arb(_storage("retry"), Int64(0))
    # Only 10 B can be freed, and held is 100 of 100.
    var slab = _slab((10, 1, True))
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(100))
    # 50 is within the budget, so a spill is tried; 10 freed, 90 + 50 > 100.
    assert_false(try_grow_intra_op_routed(r, arb, slab, 1, 50))
    assert_true(slab[0].spilled())
    assert_equal(r.held_bytes(), 90, "the freed 10 B stay released")
    assert_equal(r.try_grow_denied_count(), 2)
    # The release never goes below what is held.
    var arb2 = _Arb(_storage("retry2"), Int64(10))
    var slab2 = _slab((80, 1, True))
    var r2 = MemoryReservation.with_budget(100)
    assert_true(r2.try_grow(30))
    assert_true(try_grow_intra_op_routed(r2, arb2, slab2, 1, 90))
    assert_equal(r2.held_bytes(), 90, "released 30 (all held), granted 90")
    arb.storage_mut().cleanup()
    arb2.storage_mut().cleanup()


def test_restored_partition_can_spill_again() raises:
    var arb = _Arb(_storage("restore"), Int64(10))
    var slab = _slab((50, 1, True), (20, 2, True))
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 2, Int64(11))), 50)
    # Slot 0 is spilled and is not picked again; slot 1 is next.
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 2, Int64(11))), 20)
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 2, Int64(11))), 0)
    assert_equal(Int(arb.no_victim_count()), 1)
    # Restoring slot 0 brings its bytes back and makes it a victim again.
    slab[0].restore_from_storage(arb.storage_mut())
    assert_false(slab[0].spilled())
    assert_equal(Int(arb.total_resident_bytes(slab, 2)), 50)
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 2, Int64(11))), 50)
    assert_equal(Int(arb.spill_event_count()), 3)
    arb.storage_mut().cleanup()


def test_huge_grow_is_pressure_not_wrap() raises:
    assert_true(exceeds_budget(Int64(90), Int64.MAX, Int64(100)))
    assert_true(exceeds_budget(Int64(0), Int64.MAX, Int64(100)))
    assert_false(exceeds_budget(Int64(90), Int64(10), Int64(100)))
    assert_true(exceeds_budget(Int64(90), Int64(11), Int64(100)))
    # A negative grow is no growth: pressure only if already over budget.
    assert_false(exceeds_budget(Int64(90), Int64(-5), Int64(100)))
    assert_true(exceeds_budget(Int64(120), Int64(-5), Int64(100)))
    var arb = _Arb(_storage("huge"), Int64(100))
    var slab = _slab((90, 1, True))
    assert_equal(
        Int(arb.pressure_check_and_arbitrate(slab, 1, Int64.MAX)),
        90,
        "a wrapped sum would have read as no pressure",
    )
    arb.storage_mut().cleanup()


comptime _Coord = SpillableOpCoordinator[_Part, LocalDiskSpillStorage]


def _coord(
    tag: String, age_base: Int, budget: Int64, var slab: Slab[_Part], n: Int
) raises -> _Coord:
    return _Coord(_Arb(_storage(tag), budget), slab^, n, UInt64(age_base))


def test_two_level_spills_oldest_partition_of_oldest_operator() raises:
    # Operator A is older (age 3) than B (age 8). A's partitions have ages
    # 9 and 6; B's have ages 1 and 2: the oldest partition overall is in B,
    # but the operator is chosen first.
    var a = _coord(
        "two-a", 3, Int64(1000), _slab((10, 9, True), (20, 6, True)), 2
    )
    var b = _coord(
        "two-b", 8, Int64(1000), _slab((30, 1, True), (40, 2, True)), 2
    )
    var outer = SpillArbitrator[LocalDiskSpillStorage, _Coord, _Coord](
        _storage("two-outer"),
        Int64(1),
        SpillableOpBlock[_Coord, _Coord](a^, b^),
    )
    # Pressure: A's oldest partition (age 6, 20 B) goes first.
    assert_equal(Int(outer.pressure_check_and_arbitrate(Int64(1))), 20)
    assert_equal(Int(outer.op_memory_usage_bytes[0]()), 10)
    assert_equal(Int(outer.op_memory_usage_bytes[1]()), 70)
    # Then A's remaining partition.
    assert_equal(Int(outer.pressure_check_and_arbitrate(Int64(1))), 10)
    assert_equal(Int(outer.op_memory_usage_bytes[0]()), 0)
    assert_equal(Int(outer.op_memory_usage_bytes[1]()), 70)
    # A has nothing left, so it reports it cannot spill and the outer
    # arbitrator moves to B, whose oldest partition (age 1, 30 B) goes.
    assert_false(outer.op_can_spill[0]())
    assert_true(outer.op_can_spill[1]())
    assert_equal(Int(outer.pressure_check_and_arbitrate(Int64(1))), 30)
    assert_equal(Int(outer.op_memory_usage_bytes[1]()), 40)
    outer.storage_mut().cleanup()


def test_two_level_closed_gate_moves_choice_to_the_other_operator() raises:
    var a = _coord("gate-a", 3, Int64(1000), _slab((10, 9, True)), 1)
    var b = _coord(
        "gate-b", 8, Int64(1000), _slab((30, 1, True), (40, 2, True)), 2
    )
    a.set_can_spill(False)
    var outer = SpillArbitrator[LocalDiskSpillStorage, _Coord, _Coord](
        _storage("gate-outer"),
        Int64(1),
        SpillableOpBlock[_Coord, _Coord](a^, b^),
    )
    assert_false(outer.op_can_spill[0]())
    assert_true(outer.op_can_spill[1]())
    # B is the only spillable operator; its oldest partition (age 1) goes.
    assert_equal(Int(outer.pressure_check_and_arbitrate(Int64(1))), 30)
    assert_equal(Int(outer.op_memory_usage_bytes[0]()), 10)
    assert_equal(Int(outer.op_memory_usage_bytes[1]()), 40)
    outer.storage_mut().cleanup()


def test_coordinator_spills_even_with_an_unbounded_budget() raises:
    var c = _coord(
        "unbounded", 1, Int64.MAX, _slab((10, 1, True), (20, 2, True)), 2
    )
    var outer = _storage("unbounded-outer")
    assert_equal(Int(c.spill_to_storage(outer)), 10)
    assert_equal(Int(c.spill_to_storage(outer)), 20)
    assert_equal(Int(c.spill_to_storage(outer)), 0)
    c.arbitrator_mut().storage_mut().cleanup()
    outer.cleanup()


def test_release_and_regrant_through_the_routed_grow() raises:
    var arb = _Arb(_storage("regrant"), Int64(0))
    var slab = _slab((60, 1, True), (40, 2, True))
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(100))
    # First grow: slot 0 spills (60 B released), 40 + 50 is granted.
    assert_true(try_grow_intra_op_routed(r, arb, slab, 2, 50))
    assert_true(slab[0].spilled())
    assert_equal(r.held_bytes(), 90)
    # The caller gives the grant back and restores slot 0; its 60 B count
    # against the reservation again.
    r.release(50)
    assert_equal(r.held_bytes(), 40)
    slab[0].restore_from_storage(arb.storage_mut())
    assert_false(slab[0].spilled())
    assert_true(r.try_grow(60))
    assert_equal(r.held_bytes(), 100)
    # Second grow: slot 0 is the oldest spillable partition again.
    assert_true(try_grow_intra_op_routed(r, arb, slab, 2, 50))
    assert_true(slab[0].spilled())
    assert_false(slab[1].spilled())
    assert_equal(r.held_bytes(), 90)
    assert_true(r.held_bytes() <= r.budget_bytes())
    assert_equal(Int(arb.spill_event_count()), 2)
    assert_equal(arb.storage_ref().num_live_chunks(), 2)
    arb.storage_mut().cleanup()


def test_grow_of_exactly_the_whole_budget_spills_then_grants() raises:
    var arb = _Arb(_storage("wholebudget"), Int64(0))
    var slab = _slab((100, 1, True))
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(100))
    # 100 is not above the budget, so it is not refused up front: the
    # partition spills, its 100 B are released and the grow is granted.
    assert_true(try_grow_intra_op_routed(r, arb, slab, 1, 100))
    assert_true(slab[0].spilled())
    assert_equal(r.held_bytes(), 100)
    assert_equal(Int(arb.spill_event_count()), 1)
    arb.storage_mut().cleanup()


def test_equal_ages_spill_the_lowest_index() raises:
    var arb = _Arb(_storage("tie"), Int64(0))
    var slab = _slab((10, 5, True), (20, 5, True), (30, 5, True))
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 3, Int64(1))), 10)
    assert_true(slab[0].spilled())
    assert_false(slab[1].spilled())
    assert_false(slab[2].spilled())
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 3, Int64(1))), 20)
    assert_true(slab[1].spilled())
    arb.storage_mut().cleanup()


def test_a_raising_arbitration_leaves_the_reservation_unchanged() raises:
    # A policy that is not implemented.
    var largest = _Arb(
        _storage("raise-policy"), Int64(0), ArbitratorPolicy.largest_first()
    )
    var slab = _slab((60, 1, True))
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(100))
    with assert_raises(contains="LARGEST_FIRST"):
        _ = try_grow_intra_op_routed(r, largest, slab, 1, 10)
    assert_equal(r.held_bytes(), 100)
    assert_false(slab[0].spilled())
    assert_equal(largest.storage_ref().num_live_chunks(), 0)
    # A victim whose spill raises.
    var arb = _Arb(_storage("raise-spill"), Int64(0))
    var bad = _failing_slab(60, 1)
    with assert_raises(contains="scripted spill failure"):
        _ = try_grow_intra_op_routed(r, arb, bad, 1, 10)
    assert_equal(r.held_bytes(), 100)
    assert_false(bad[0].spilled())
    assert_equal(arb.storage_ref().num_live_chunks(), 0)
    largest.storage_mut().cleanup()
    arb.storage_mut().cleanup()


def test_zero_budget_arbitrators() raises:
    # Budget 0 with nothing resident: a zero grow is not pressure.
    var arb = _Arb(_storage("zero"), Int64(0))
    var slab = _slab((10, 1, True))
    _ = slab[0].spill_to_storage(arb.storage_mut())
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 1, Int64(0))), 0)
    assert_equal(Int(arb.no_victim_count()), 0)
    # Anything more is pressure, but the one partition is already spilled.
    assert_equal(Int(arb.pressure_check_and_arbitrate(slab, 1, Int64(1))), 0)
    assert_equal(Int(arb.no_victim_count()), 1)
    arb.storage_mut().cleanup()


def test_outer_arbitrator_with_nothing_spillable_frees_nothing() raises:
    var a = _coord("none-a", 3, Int64(1000), _slab((10, 9, True)), 1)
    var b = _coord("none-b", 8, Int64(1000), _slab((30, 1, True)), 1)
    a.set_can_spill(False)
    b.set_can_spill(False)
    var outer = SpillArbitrator[LocalDiskSpillStorage, _Coord, _Coord](
        _storage("none-outer"),
        Int64(0),
        SpillableOpBlock[_Coord, _Coord](a^, b^),
    )
    assert_equal(Int(outer.pressure_check_and_arbitrate(Int64(1))), 0)
    assert_equal(Int(outer.op_memory_usage_bytes[0]()), 10)
    assert_equal(Int(outer.op_memory_usage_bytes[1]()), 30)
    assert_equal(outer.storage_ref().num_live_chunks(), 0)
    outer.storage_mut().cleanup()


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
    suite.test[test_routed_grow_sequence_oldest_first_in_budget]()
    suite.test[test_refused_grow_leaves_reservation_unchanged]()
    suite.test[test_retry_refused_after_spill_keeps_the_released_bytes]()
    suite.test[test_release_and_regrant_through_the_routed_grow]()
    suite.test[test_restored_partition_can_spill_again]()
    suite.test[test_huge_grow_is_pressure_not_wrap]()
    suite.test[
        test_two_level_spills_oldest_partition_of_oldest_operator
    ]()
    suite.test[test_two_level_closed_gate_moves_choice_to_the_other_operator]()
    suite.test[test_coordinator_spills_even_with_an_unbounded_budget]()
    suite.test[test_grow_of_exactly_the_whole_budget_spills_then_grants]()
    suite.test[test_equal_ages_spill_the_lowest_index]()
    suite.test[test_a_raising_arbitration_leaves_the_reservation_unchanged]()
    suite.test[test_zero_budget_arbitrators]()
    suite.test[test_outer_arbitrator_with_nothing_spillable_frees_nothing]()
    suite^.run()
