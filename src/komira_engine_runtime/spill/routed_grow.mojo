# =============================================================================
# routed_grow.mojo: a breaker's grow that spills one of its own partitions
# when its reservation refuses.
# =============================================================================
#
# `try_grow_intra_op_routed` joins two layers: the breaker's
# `MemoryReservation.try_grow` and its `IntraOpSlabArbitrator`.
#
#   1. Ask the reservation. If it grants, return True; the arbitrator is not
#      touched.
#   2. If it refuses a request that spilling cannot satisfy, return False and
#      change nothing but the reservation's denied-grow count (the first ask
#      was counted): a negative `want_bytes` (a grow cannot free memory), or
#      a `want_bytes` above the whole budget (it would not fit even with
#      nothing held). No partition is spilled for such a request.
#   3. Otherwise ask the arbitrator to spill one of the caller's partitions.
#      If that frees nothing (no pressure, or no partition can spill), return
#      False; the reservation is unchanged.
#   4. The spilled partition's bytes were counted in this reservation, so
#      release them (never more than it holds) and try the grow once more.
#      The retry can still refuse. Then the reservation is lower than before
#      by the bytes the spill freed (that memory really was freed) and the
#      result is False.
#
# `reservation`, `arbitrator` and `slab` are borrowed for the call only.
# A spill of another operator's partitions is not routed here: it frees memory
# this reservation does not count.
# =============================================================================

from komira_collections.slab import Slab
from komira_engine_runtime.memory.reservation import MemoryReservation

from .intra_op_slab_arbitrator import IntraOpSlabArbitrator
from .spill_storage import SpillStorage
from .spillable_op import SpillableOp


def try_grow_intra_op_routed[
    T: SpillableOp, S: SpillStorage, o_slab: Origin[mut=True], //,
](
    mut reservation: MemoryReservation,
    mut arbitrator: IntraOpSlabArbitrator[T, S],
    ref [o_slab] slab: Slab[T],
    slab_len: Int,
    want_bytes: Int,
) raises -> Bool:
    """Grow `reservation` by `want_bytes`, spilling one of the caller's own
    partitions first if the reservation refuses.

    Args:
        reservation: The breaker's reservation.
        arbitrator:  The breaker's intra-operator arbitrator.
        slab:        The breaker's partitions; the arbitrator may spill
                     `slab[i]` for one `i < slab_len`.
        slab_len:    How many slots of `slab` are live.
        want_bytes:  The bytes to grow by.

    Returns:
        True if the grow succeeded, on the first try or after one spill.
        False if it was refused and not retried (negative or above the
        budget, or the spill freed nothing: the held bytes are unchanged), or
        refused again after a spill (the held bytes fell by the freed bytes,
        so a caller must not read False as "nothing changed").

    Raises:
        What the arbitrator raises: the victim's `spill_to_storage`, or a
        policy that is not implemented. The raise comes before any release,
        so the held bytes are unchanged.
    """
    if reservation.try_grow(want_bytes):
        return True
    if want_bytes < 0:
        return False
    if reservation.has_budget() and want_bytes > reservation.budget_bytes():
        return False
    var freed = arbitrator.pressure_check_and_arbitrate(
        slab, slab_len, Int64(want_bytes)
    )
    if freed <= 0:
        return False
    var release = Int(freed)
    if release > reservation.held_bytes():
        release = reservation.held_bytes()
    reservation.release(release)
    return reservation.try_grow(want_bytes)
