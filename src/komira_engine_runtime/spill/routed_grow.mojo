# =============================================================================
# routed_grow.mojo: a breaker's grow that spills one of its own partitions
# when its reservation denies.
# =============================================================================
#
# `try_grow_intra_op_routed` joins two layers:
#
#   1. `MemoryReservation.try_grow`: the breaker's own budget.
#   2. `IntraOpSlabArbitrator.pressure_check_and_arbitrate`: picks the
#      oldest spillable partition in the breaker's slab and spills it.
#
# The behaviour:
#
#   1. Try the reservation. On True, return True: no arbitrator traffic on
#      the happy path.
#   2. On a denial, ask the arbitrator to spill one partition of the
#      caller's slab. If it frees nothing (no pressure, or no partition can
#      spill), return False: the caller falls back to its own path.
#   3. The spilled partition belonged to this breaker, so the bytes it freed
#      are released from the reservation (never more than it holds), and the
#      grow is retried once.
#
# Step 3's release is what lets the retry succeed: without it the
# reservation is unchanged and the retry gives the same denial.
#
# There is no inter-operator form here. A cross-operator spill frees another
# operator's memory, which this breaker's reservation does not account for,
# so retrying the local grow after it could not change the answer.
#
# Lifetime: `reservation`, `arbitrator` and `slab` are borrowed from the
# caller for the call only; nothing is retained.
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
    partitions first if the reservation denies.

    Args:
        reservation: The breaker's reservation.
        arbitrator:  The breaker's intra-operator arbitrator.
        slab:        The breaker's partitions; the arbitrator may spill
                     `slab[i]` for one `i < slab_len`.
        slab_len:    How many slots of `slab` are live.
        want_bytes:  The bytes to grow by.

    Returns:
        True if the grow succeeded, on the first try or after one spill.

    Raises:
        What the arbitrator raises: the victim's `spill_to_storage`, or a
        policy that is not implemented.
    """
    if reservation.try_grow(want_bytes):
        return True
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
