# =============================================================================
# join_build_table_fns -- the per-arity free functions of `JoinBuildTable`
# over typed key values: insert (`join_build_insert_slot_N`), the first match
# (`join_build_probe_N`), every match (`join_build_probe_all_slots_N`) and a
# prefetch of a key's home slot (`join_build_prefetch_key_N`), N = 1..4
# =============================================================================
#
# For callers that hold a key as `Scalar`s rather than as a batch cell. The
# hash (XOR of the columns' `key_hash`) and equality (`slot_eq_value`, the
# key model) are the batch-row path's, so the two paths can build and probe
# the same table. A run of occupied slots ends at the first empty slot.
# =============================================================================

from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_key_slot import key_hash
from komira_op_join_stage.join_key_bundle import (
    KeyBundle1,
    KeyBundle2,
    KeyBundle3,
    KeyBundle4,
)
from komira_op_join_stage.join_payload_column import PayloadColumn


# -----------------------------------------------------------------------------
# Key equality at a slot, per arity (False for an empty slot).
# -----------------------------------------------------------------------------


@always_inline
def _eq1[
    K0: DType, *P: PayloadColumn
](t: JoinBuildTable[KeyBundle1[K0], *P], s: Int, k0: Scalar[K0]) -> Bool:
    return t.keys.cols[0].slot_eq_value(s, k0)


@always_inline
def _eq2[
    K0: DType, K1: DType, *P: PayloadColumn
](
    t: JoinBuildTable[KeyBundle2[K0, K1], *P],
    s: Int,
    k0: Scalar[K0],
    k1: Scalar[K1],
) -> Bool:
    return t.keys.cols[0].slot_eq_value(s, k0) and t.keys.cols[
        1
    ].slot_eq_value(s, k1)


@always_inline
def _eq3[
    K0: DType, K1: DType, K2: DType, *P: PayloadColumn
](
    t: JoinBuildTable[KeyBundle3[K0, K1, K2], *P],
    s: Int,
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
) -> Bool:
    return (
        t.keys.cols[0].slot_eq_value(s, k0)
        and t.keys.cols[1].slot_eq_value(s, k1)
        and t.keys.cols[2].slot_eq_value(s, k2)
    )


@always_inline
def _eq4[
    K0: DType, K1: DType, K2: DType, K3: DType, *P: PayloadColumn
](
    t: JoinBuildTable[KeyBundle4[K0, K1, K2, K3], *P],
    s: Int,
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
    k3: Scalar[K3],
) -> Bool:
    return (
        t.keys.cols[0].slot_eq_value(s, k0)
        and t.keys.cols[1].slot_eq_value(s, k1)
        and t.keys.cols[2].slot_eq_value(s, k2)
        and t.keys.cols[3].slot_eq_value(s, k3)
    )


@always_inline
def _home(h: UInt64, capacity_mask: Int) -> Int:
    return Int(h & UInt64(capacity_mask))


# -----------------------------------------------------------------------------
# Insert: grow if needed, walk the run to its first empty slot (noting an
# equal key on the way), write the key there, count the row, return the slot.
# The caller writes the payload columns at the returned slot.
# -----------------------------------------------------------------------------


def join_build_insert_slot_1[
    K0: DType, *P: PayloadColumn
](mut table: JoinBuildTable[KeyBundle1[K0], *P], k0: Scalar[K0]) -> Int:
    """Insert a one-column key; returns its slot."""
    table._maybe_grow()
    var mask = table.capacity_mask
    var slot = _home(key_hash[K0](k0), mask)
    while not table.keys.slot_is_empty(slot):
        if _eq1(table, slot, k0):
            table.has_duplicate_keys = True
        slot = (slot + 1) & mask
    table.keys.cols[0].write_value(slot, k0)
    table.n_used += 1
    return slot


def join_build_insert_slot_2[
    K0: DType, K1: DType, *P: PayloadColumn
](
    mut table: JoinBuildTable[KeyBundle2[K0, K1], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
) -> Int:
    """Insert a two-column key; returns its slot."""
    table._maybe_grow()
    var mask = table.capacity_mask
    var slot = _home(key_hash[K0](k0) ^ key_hash[K1](k1), mask)
    while not table.keys.slot_is_empty(slot):
        if _eq2(table, slot, k0, k1):
            table.has_duplicate_keys = True
        slot = (slot + 1) & mask
    table.keys.cols[0].write_value(slot, k0)
    table.keys.cols[1].write_value(slot, k1)
    table.n_used += 1
    return slot


def join_build_insert_slot_3[
    K0: DType, K1: DType, K2: DType, *P: PayloadColumn
](
    mut table: JoinBuildTable[KeyBundle3[K0, K1, K2], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
) -> Int:
    """Insert a three-column key; returns its slot."""
    table._maybe_grow()
    var mask = table.capacity_mask
    var h = key_hash[K0](k0) ^ key_hash[K1](k1) ^ key_hash[K2](k2)
    var slot = _home(h, mask)
    while not table.keys.slot_is_empty(slot):
        if _eq3(table, slot, k0, k1, k2):
            table.has_duplicate_keys = True
        slot = (slot + 1) & mask
    table.keys.cols[0].write_value(slot, k0)
    table.keys.cols[1].write_value(slot, k1)
    table.keys.cols[2].write_value(slot, k2)
    table.n_used += 1
    return slot


def join_build_insert_slot_4[
    K0: DType, K1: DType, K2: DType, K3: DType, *P: PayloadColumn
](
    mut table: JoinBuildTable[KeyBundle4[K0, K1, K2, K3], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
    k3: Scalar[K3],
) -> Int:
    """Insert a four-column key; returns its slot."""
    table._maybe_grow()
    var mask = table.capacity_mask
    var h = key_hash[K0](k0) ^ key_hash[K1](k1) ^ key_hash[K2](
        k2
    ) ^ key_hash[K3](k3)
    var slot = _home(h, mask)
    while not table.keys.slot_is_empty(slot):
        if _eq4(table, slot, k0, k1, k2, k3):
            table.has_duplicate_keys = True
        slot = (slot + 1) & mask
    table.keys.cols[0].write_value(slot, k0)
    table.keys.cols[1].write_value(slot, k1)
    table.keys.cols[2].write_value(slot, k2)
    table.keys.cols[3].write_value(slot, k3)
    table.n_used += 1
    return slot


# -----------------------------------------------------------------------------
# First match: the first slot of the key's run holding an equal key, or -1.
# -----------------------------------------------------------------------------


def join_build_probe_1[
    K0: DType, *P: PayloadColumn
](table: JoinBuildTable[KeyBundle1[K0], *P], k0: Scalar[K0]) -> Int:
    """The first slot whose key equals `k0`, or -1."""
    var mask = table.capacity_mask
    var slot = _home(key_hash[K0](k0), mask)
    for _ in range(mask + 1):
        if table.keys.slot_is_empty(slot):
            return -1
        if _eq1(table, slot, k0):
            return slot
        slot = (slot + 1) & mask
    return -1


def join_build_probe_2[
    K0: DType, K1: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle2[K0, K1], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
) -> Int:
    """The first slot whose key equals `(k0, k1)`, or -1."""
    var mask = table.capacity_mask
    var slot = _home(key_hash[K0](k0) ^ key_hash[K1](k1), mask)
    for _ in range(mask + 1):
        if table.keys.slot_is_empty(slot):
            return -1
        if _eq2(table, slot, k0, k1):
            return slot
        slot = (slot + 1) & mask
    return -1


def join_build_probe_3[
    K0: DType, K1: DType, K2: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle3[K0, K1, K2], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
) -> Int:
    """The first slot whose key equals `(k0, k1, k2)`, or -1."""
    var mask = table.capacity_mask
    var h = key_hash[K0](k0) ^ key_hash[K1](k1) ^ key_hash[K2](k2)
    var slot = _home(h, mask)
    for _ in range(mask + 1):
        if table.keys.slot_is_empty(slot):
            return -1
        if _eq3(table, slot, k0, k1, k2):
            return slot
        slot = (slot + 1) & mask
    return -1


def join_build_probe_4[
    K0: DType, K1: DType, K2: DType, K3: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle4[K0, K1, K2, K3], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
    k3: Scalar[K3],
) -> Int:
    """The first slot whose key equals `(k0, k1, k2, k3)`, or -1."""
    var mask = table.capacity_mask
    var h = key_hash[K0](k0) ^ key_hash[K1](k1) ^ key_hash[K2](
        k2
    ) ^ key_hash[K3](k3)
    var slot = _home(h, mask)
    for _ in range(mask + 1):
        if table.keys.slot_is_empty(slot):
            return -1
        if _eq4(table, slot, k0, k1, k2, k3):
            return slot
        slot = (slot + 1) & mask
    return -1


# -----------------------------------------------------------------------------
# Every match (M:N): append every slot of the key's run holding an equal key
# to `out_slots` (not cleared).
# -----------------------------------------------------------------------------


def join_build_probe_all_slots_1[
    K0: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle1[K0], *P],
    k0: Scalar[K0],
    mut out_slots: List[Int],
):
    """Append every slot whose key equals `k0`."""
    var mask = table.capacity_mask
    var slot = _home(key_hash[K0](k0), mask)
    for _ in range(mask + 1):
        if table.keys.slot_is_empty(slot):
            return
        if _eq1(table, slot, k0):
            out_slots.append(slot)
        slot = (slot + 1) & mask


def join_build_probe_all_slots_2[
    K0: DType, K1: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle2[K0, K1], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    mut out_slots: List[Int],
):
    """Append every slot whose key equals `(k0, k1)`."""
    var mask = table.capacity_mask
    var slot = _home(key_hash[K0](k0) ^ key_hash[K1](k1), mask)
    for _ in range(mask + 1):
        if table.keys.slot_is_empty(slot):
            return
        if _eq2(table, slot, k0, k1):
            out_slots.append(slot)
        slot = (slot + 1) & mask


def join_build_probe_all_slots_3[
    K0: DType, K1: DType, K2: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle3[K0, K1, K2], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
    mut out_slots: List[Int],
):
    """Append every slot whose key equals `(k0, k1, k2)`."""
    var mask = table.capacity_mask
    var h = key_hash[K0](k0) ^ key_hash[K1](k1) ^ key_hash[K2](k2)
    var slot = _home(h, mask)
    for _ in range(mask + 1):
        if table.keys.slot_is_empty(slot):
            return
        if _eq3(table, slot, k0, k1, k2):
            out_slots.append(slot)
        slot = (slot + 1) & mask


def join_build_probe_all_slots_4[
    K0: DType, K1: DType, K2: DType, K3: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle4[K0, K1, K2, K3], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
    k3: Scalar[K3],
    mut out_slots: List[Int],
):
    """Append every slot whose key equals `(k0, k1, k2, k3)`."""
    var mask = table.capacity_mask
    var h = key_hash[K0](k0) ^ key_hash[K1](k1) ^ key_hash[K2](
        k2
    ) ^ key_hash[K3](k3)
    var slot = _home(h, mask)
    for _ in range(mask + 1):
        if table.keys.slot_is_empty(slot):
            return
        if _eq4(table, slot, k0, k1, k2, k3):
            out_slots.append(slot)
        slot = (slot + 1) & mask


# -----------------------------------------------------------------------------
# Prefetch the key's home slot (key column 0's cache line) ahead of a probe.
# -----------------------------------------------------------------------------


@always_inline
def join_build_prefetch_key_1[
    K0: DType, *P: PayloadColumn
](table: JoinBuildTable[KeyBundle1[K0], *P], k0: Scalar[K0]):
    """Prefetch `k0`'s home slot."""
    table.keys.cols[0].prefetch_at(
        _home(key_hash[K0](k0), table.capacity_mask)
    )


@always_inline
def join_build_prefetch_key_2[
    K0: DType, K1: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle2[K0, K1], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
):
    """Prefetch `(k0, k1)`'s home slot."""
    var h = key_hash[K0](k0) ^ key_hash[K1](k1)
    table.keys.cols[0].prefetch_at(_home(h, table.capacity_mask))


@always_inline
def join_build_prefetch_key_3[
    K0: DType, K1: DType, K2: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle3[K0, K1, K2], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
):
    """Prefetch `(k0, k1, k2)`'s home slot."""
    var h = key_hash[K0](k0) ^ key_hash[K1](k1) ^ key_hash[K2](k2)
    table.keys.cols[0].prefetch_at(_home(h, table.capacity_mask))


@always_inline
def join_build_prefetch_key_4[
    K0: DType, K1: DType, K2: DType, K3: DType, *P: PayloadColumn
](
    table: JoinBuildTable[KeyBundle4[K0, K1, K2, K3], *P],
    k0: Scalar[K0],
    k1: Scalar[K1],
    k2: Scalar[K2],
    k3: Scalar[K3],
):
    """Prefetch `(k0, k1, k2, k3)`'s home slot."""
    var h = key_hash[K0](k0) ^ key_hash[K1](k1) ^ key_hash[K2](
        k2
    ) ^ key_hash[K3](k3)
    table.keys.cols[0].prefetch_at(_home(h, table.capacity_mask))
