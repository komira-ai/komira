# =============================================================================
# cd_passenger_lane_counter — which INSTANTIATION of the grouped
# COUNT(DISTINCT) row loop ran: the all-CD one, or the MIXEDFUSE one
# =============================================================================
#
# WHY THIS EXISTS. `WorkerCDState.consume_batch` folds fixed aggregates (SUM /
# COUNT / MIN / MAX / MEAN) as a PASSENGER LANE on the gid the COUNT(DISTINCT)
# lane resolves. An all-COUNT(DISTINCT) query must run the instantiation with
# no passenger code at all (`has_fixed = False`): a version that ran the fused
# body with zero fixed aggregates ran slower on such a query (the row
# loop grew in code size). NO VALUE ASSERTION CAN SEE WHICH
# instantiation ran: both produce the same COUNT(DISTINCT) answers. These
# counters are the observable half — the number of grouped batches consumed,
# and how many of them executed the passenger-lane setup. For an all-CD query
# the second MUST be 0.
#
# ⭐ THE FIRST COUNTER IS WHAT KEEPS THE SECOND FROM BEING VACUOUS. "zero
# passenger batches" is also what a query that never reached `WorkerCDState`
# at all would report, so a test asserts `batches > 0` beside `fx == 0`.
#
# ⚠ NOT A PER-ROW OR PER-BATCH ATOMIC. Each `WorkerCDState` counts into two
# plain `Int` fields (one add per BATCH); `CountDistinctAggSink._finalize_batch`
# folds them in here ONCE PER WORKER PER QUERY, from the loop that already walks
# every worker to build the global group directory.
#
# A `_Global` atomic, like this package's other route counters.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_cd_grouped_batches() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: the grouped-batch counter, once per process (0)."""
    # FFI-BOUNDARY: the allocation is owned by the `_Global` slot, lives for the
    # whole process and is never freed; nothing else holds the pointer.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _init_cd_passenger_batches() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: the passenger-lane batch counter, once per process."""
    # FFI-BOUNDARY: the allocation is owned by the `_Global` slot, lives for the
    # whole process and is never freed; nothing else holds the pointer.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CD_GROUPED_BATCHES = _Global[
    "komira_cd_grouped_consume_batches", _init_cd_grouped_batches,
]

comptime _CD_PASSENGER_BATCHES = _Global[
    "komira_cd_passenger_lane_batches", _init_cd_passenger_batches,
]


def cd_grouped_route_note(batches: Int, passenger_batches: Int) raises:
    """Fold one worker's per-query counts into the process-wide totals.

    `batches` is every non-empty batch the worker's grouped `consume_batch`
    took; `passenger_batches` is how many of those ran the MIXEDFUSE passenger
    lane. Called once per worker per query, never on the row path."""
    # FFI-BOUNDARY: `get_or_create_ptr` returns a pointer into the `_Global`
    # slot's process-lifetime storage. The slot owns and never frees it; the
    # pointer's origin is the stdlib `_Global` API's own return type and does
    # not leave this helper.
    if batches != 0:
        var gb = _CD_GROUPED_BATCHES.get_or_create_ptr()
        _ = gb[][].fetch_add(Int64(batches))
    if passenger_batches != 0:
        var gp = _CD_PASSENGER_BATCHES.get_or_create_ptr()
        _ = gp[][].fetch_add(Int64(passenger_batches))


def cd_grouped_batches_count() raises -> Int:
    """Read the process-wide count of grouped COUNT(DISTINCT) batches."""
    # FFI-BOUNDARY: see `cd_grouped_route_note`.
    var gb = _CD_GROUPED_BATCHES.get_or_create_ptr()
    return Int(gb[][].load())


def cd_passenger_lane_batches_count() raises -> Int:
    """Read the process-wide count of batches that ran the passenger lane."""
    # FFI-BOUNDARY: see `cd_grouped_route_note`.
    var gp = _CD_PASSENGER_BATCHES.get_or_create_ptr()
    return Int(gp[][].load())


def reset_cd_grouped_route_counters() raises:
    """Reset both process-wide counters to 0 (test setup)."""
    # FFI-BOUNDARY: see `cd_grouped_route_note`.
    var gb = _CD_GROUPED_BATCHES.get_or_create_ptr()
    gb[][].store(Scalar[DType.int64](0))
    var gp = _CD_PASSENGER_BATCHES.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
