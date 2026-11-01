# =============================================================================
# grain_geometry — the tasks-per-fork witness, PER SITE, for the parallel
# fork grain (`morsel_sizing_policy.FORK_GRAIN_MAX_ROWS`)
# =============================================================================
#
# WHY THIS EXISTS. The fork grain changes only HOW rows are sharded across
# workers, never WHICH rows come out — so an output oracle is structurally
# blind to it. A fork that collapses to 2 tasks on a 22-worker pool returns
# byte-identical results to one that fans 19 ways. The COUNTER is therefore the
# only falsifier the rule can have, and "tasks per fork, per site" is the exact
# quantity the defect is stated in (q21's `residual_mark_stream` forking 2 tasks
# onto 22 workers, ~9% pool occupancy).
#
# WHY PER SITE AND NOT PER QUERY. The mark join alone is three waves with three
# different geometries (prepare 22 tasks / build 22 / stream 2). A pooled
# counter averages exactly the signal away — the under-fan is invisible unless
# each wave is read separately. Sites are the `SITE_*` ids in
# `komira_async/runtime/sched_trace.mojo`, so a reading here lines up with a
# `KOMIRA_SCHED_TRACE` span for the same fork.
#
# WHY NOT `sched_trace` ITSELF. `sched_trace_add_segment(site, ..., n_tasks)`
# already records a task count per site, but (a) it is gated on
# `KOMIRA_SCHED_TRACE` being enabled BEFORE the C side caches it, which makes
# it awkward to assert from a unit test, and (b) it records n_tasks only — not
# the GRAIN or the MORSEL count, which are the two numbers that distinguish the
# rule's arms from each other. This counter is always-on, allocation-free after
# first touch, and written once per FORK (not per row or per morsel).
#
# ⚠ THIS IS AN INSTRUMENT, NOT A ROUTE. Recording never changes a grain, a
# morsel count, or a worker count. Every value stored here is one the caller
# had already computed and is about to dispatch on.
#
# Same blessed `_Global` + `Atomic` idiom as
# `komira_engine_operators/q21_parallel_mark_counter.mojo`; no env var on the
# record path, no `unsafe_from_address` laundering.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc



# -----------------------------------------------------------------------------
# Table shape
# -----------------------------------------------------------------------------
#
# Indexed by RAW SITE ID so a reader can pass `SITE_RESIDUAL_MARK_STREAM`
# straight through with no mapping table to drift. The largest id declared today
# is 54 (`SITE_SEMI_PROBE_COUNT`); 64 slots leaves headroom for the next ten
# without a resize, and `grain_geometry_record` DROPS an out-of-range site
# rather than writing past the array.
#
# ⚠ A SITE ID SHARED BY TWO FORKS IS SHARED IN THIS TABLE TOO, AND THE TABLE IS
# LAST-WRITE-WINS. `SITE_JOIN_PROBE` (25) is stamped by FOUR dispatches — both
# `compiler_parallel` probe entries, `materialize_typed_join` and
# `row_join_probe_multiworker` — so in a real query its slot answers for
# whichever ran most recently and cannot distinguish them. That is why the two
# semi-join probes got ids of their own (53 / 54 — the same reason id 30 was
# split into 51 / 52), and why `tests/engine/test_fork_grain_site_guards.mojo`
# resets the table and drives exactly ONE entry point per leg. A guard that
# reads a shared slot can pass while the site it names sits reverted.
#
# ⚠ If a `SITE_*` id ever reaches 64, this constant must grow. The drop is
# silent by design on the WRITE path (an instrument must never fault a query),
# but `grain_geometry_field` returns -1 for the same range so a test asserting
# on a too-large site reads an obviously-wrong value rather than a plausible 0.
comptime GRAIN_MAX_SITES: Int = 64

# Fields recorded per site.
comptime GRAIN_F_ROWS: Int = 0      # the input row count the fork was sized on
comptime GRAIN_F_GRAIN: Int = 1     # rows per morsel (the rule's output)
comptime GRAIN_F_MORSELS: Int = 2   # ceil(rows / grain)
comptime GRAIN_F_WORKERS: Int = 3   # min(morsels, pool) — the TASKS the fork gets
comptime GRAIN_F_CALLS: Int = 4     # how many forks recorded at this site

comptime GRAIN_N_FIELDS: Int = 5
comptime _GRAIN_N: Int = GRAIN_MAX_SITES * GRAIN_N_FIELDS


def _init_grain_geom() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate the site x field array once per process."""
    var raw = alloc[AtomicI64](_GRAIN_N)
    for i in range(_GRAIN_N):
        (raw + i).unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(
            Scalar[DType.int64](0)
        )
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _GRAIN_GEOM = _Global[
    "komira_engine_runtime_grain_geometry",
    _init_grain_geom,
]


def grain_geometry_record(
    site: UInt32,
    rows: Int,
    grain: Int,
    morsels: Int,
    workers: Int,
    trace: Bool = False,
) raises:
    """Record ONE fork's realised grain geometry at `site`.

    Called once per parallel dispatch (not per morsel, not per row), immediately
    before the fork, with the values the fork is actually about to use.

    ⚠ A RECORDED `workers == 1` MAY MEAN THE SITE TOOK ITS SERIAL FAST PATH.
    Two of the probe sites record BEFORE their `num_morsels <= 1` early-return,
    so a 1 there reads "this input was processed by one task", which is true
    either way and is exactly the reading an under-fan census wants. It does NOT
    distinguish a 1-task fork from a serial call, and no assertion should try to.

    LAST-WRITE-WINS per site, plus a monotone CALLS counter. A site that forks
    repeatedly (a probe inside a loop) leaves its most recent geometry readable
    and its total fork count intact — the two questions a test asks are "what
    shape was the last fork" and "did it fork at all".

    An out-of-range `site` is DROPPED: an instrument must never fault the query
    it is measuring.

    `trace` prints the recorded geometry as one line, for reading a run.
    """
    var s = Int(site)
    if s < 0 or s >= GRAIN_MAX_SITES:
        return
    # SAFETY: FFI carve-out for the process-global counter array. The `+ i`
    # arithmetic stays inside this module and never crosses a module boundary;
    # `_init_grain_geom` allocated `_GRAIN_N` contiguous elements and `s` is
    # range-checked above.
    var gp = _GRAIN_GEOM.get_or_create_ptr()
    var base = UnsafePointer(to=gp[][])
    var off = s * GRAIN_N_FIELDS
    (base + off + GRAIN_F_ROWS)[].store(Scalar[DType.int64](rows))
    (base + off + GRAIN_F_GRAIN)[].store(Scalar[DType.int64](grain))
    (base + off + GRAIN_F_MORSELS)[].store(Scalar[DType.int64](morsels))
    (base + off + GRAIN_F_WORKERS)[].store(Scalar[DType.int64](workers))
    _ = (base + off + GRAIN_F_CALLS)[].fetch_add(Int64(1))

    # `trace` prints the geometry FROM A RUN. Do NOT infer a morsel count from
    # a row count, print it.
    if trace:
        print(
            "[GRAIN-GEOM] site=", s,
            " rows=", rows,
            " grain=", grain,
            " morsels=", morsels,
            " tasks=", workers,
            sep="",
        )


def grain_geometry_field(site: UInt32, field: Int) raises -> Int:
    """Read one recorded field. Out-of-range site/field returns -1 rather than
    reading past the array — an obviously-wrong value, never a plausible 0."""
    var s = Int(site)
    if s < 0 or s >= GRAIN_MAX_SITES:
        return -1
    if field < 0 or field >= GRAIN_N_FIELDS:
        return -1
    # SAFETY: FFI carve-out (see `grain_geometry_record`); both indices are
    # range-checked above against the `_GRAIN_N` elements allocated.
    var gp = _GRAIN_GEOM.get_or_create_ptr()
    var base = UnsafePointer(to=gp[][])
    return Int((base + s * GRAIN_N_FIELDS + field)[].load())


def grain_geometry_calls(site: UInt32) raises -> Int:
    """How many forks recorded geometry at `site` since the last reset.

    0 means the recorder never ran at this site — which is exactly what a mutant
    that stops emitting produces, and is why the value readers alone are not the
    whole falsifier. A test that asserts only on GRAIN/MORSELS can pass against
    a STALE slot; asserting CALLS too is what closes that."""
    return grain_geometry_field(site, GRAIN_F_CALLS)


def grain_geometry_reset() raises:
    """Zero every site x field cell (test setup)."""
    # SAFETY: FFI carve-out (see `grain_geometry_record`); the loop bound is the
    # allocation size.
    var gp = _GRAIN_GEOM.get_or_create_ptr()
    var base = UnsafePointer(to=gp[][])
    for i in range(_GRAIN_N):
        (base + i)[].store(Scalar[DType.int64](0))
