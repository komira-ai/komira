# =============================================================================
# explain_analyze_collect.mojo — the process-global EXPLAIN ANALYZE collector
# =============================================================================
#
# WHY THIS EXISTS, AND WHY IT IS NOT A `Pointer[ExecutionReport]` PARAMETER.
#
# Threading an `ExecutionReport` through the executors by parameter cannot
# reach the engine's pipeline breakers. Every breaker on the live path is
# reached through an erased POD function pointer (the engine's walker thunk),
# whose type is `def (mut LocalDispatcher, _ErasedCarrierPtr, mut
# ParquetMetadataCache) raises thin -> None`. Adding a report parameter means
# changing that fn-ptr signature, i.e. changing the signature of every
# `execute_*_plan` and every recursion arm. That signature is the deliberate
# firewall that keeps the heavy executors from co-elaborating — the
# co-elaboration reproducibly WEDGES the Mojo compiler. Threading a report
# through it trades a diagnostic for a build-system hazard.
#
# SO THE COLLECTION IS PROCESS-GLOBAL, the same `_Global` + `Atomic` idiom the
# engine's other cross-cutting execution counters use (the scheduler trace,
# the planner-scale and join-index counters). No new mechanism.
#
# The `ExecutionReport` type and its renderer are NOT bypassed — they are the
# OUTPUT of this module: `build_execution_report()` folds the slot table into a
# real `ExecutionReport` with real `MetricsSnapshot` entries, so
# `format_execution_report` renders populated blocks.
#
# -----------------------------------------------------------------------------
# COST WHEN DISARMED
# -----------------------------------------------------------------------------
#
# A Mojo `_Global.get_or_create_ptr()` is NOT a cheap flag read: it is a
# `raises` lookup into the KGEN runtime's process-global registry, keyed by the
# global's NAME STRING, inside a `try`/`except` — on the order of 30 ns/call,
# against the ~2-4 ns a relaxed atomic load costs, on a path every breaker
# crosses. `tests/test_explain_analyze_disarmed_cost.mojo` holds the disarmed
# path to at most 20 ns/call over a same-shape baseline in the same binary.
#
# THE DISARMED COST IS TWO-TIER:
#
#   TIER 1 — `EA_COLLECTION_COMPILED_IN`, a module-level `comptime Bool`. EVERY
#   recording seam wraps its body in `@parameter if EA_COLLECTION_COMPILED_IN:`,
#   so flipping it to False elides the flag read, the `perf_counter_ns()` calls,
#   the `_ea_kind_for_plan_tag` map and the `ea_record` monomorph from those
#   translation units entirely. That — and ONLY that — is the setting for which
#   "zero instructions" is true. It ships True.
#
#   TIER 2 — with tier 1 compiled in, `ea_armed()` is
#   `external_call["komira_ea_armed", Int32]()`: a relaxed `__ATOMIC_RELAXED`
#   load of a TU-static in this package's C file
#   (`native/komira_metrics_ea_flag.c`), reached through one non-inlinable C call.
#   NOT zero, and the sentence does not say zero — it is measured by the test
#   named above rather than asserted here.
#
# ONLY THE ARM FLAG LIVES IN C. The per-kind slot table below stays in Mojo
# `_Global` storage: it is read and written ONLY on the armed path, where a
# registry lookup is irrelevant against the query being measured.
#
# Every recording site is written as `if _on: <read clock> ... <fetch_add>` with
# `_on` hoisted out of the region. Nothing is recorded, no clock is read, and
# no `String` is built unless a caller has armed it.
#
# WHAT THIS COSTS A REAL QUERY. Every seam is per-OPERATOR-INSTANCE (one
# plan-node dispatch, one scan-leaf collect, one streaming-sink driver run),
# never per row, per morsel or per batch. A multi-join query is therefore
# O(20-40) crossings: ~80 ns per query at 2 ns each, within noise of the
# collection compiled out.
#
# ARMING IS SCOPED, NOT ENV-GATED. `ctx.explain_analyze(...)` arms, runs, and
# disarms around ONE query (`komira_sdk`'s explain-analyze renderer).
# There is deliberately no env var: an env-armed collector would accumulate
# across a whole process and report a sum over every query that ran, which is
# not what "EXPLAIN ANALYZE this query" means.
#
# THREAD SAFETY. Every slot is an `Atomic[DType.int64]` mutated with a relaxed
# `fetch_add`. All the recording sites in this repo are DRIVER-side (the walk,
# the collect leaf, the streaming-sink driver — all post-barrier or pre-fork),
# so contention is nil; the atomics are for correctness under a future
# worker-side site, not for a hot loop.
#
# ⚠ ONE QUERY AT A TIME, AND THIS MODULE CANNOT ENFORCE IT. The table is
# process-global, so two `explain_analyze` calls running CONCURRENTLY on two
# threads would interleave into one table and both reports would be wrong. There
# is no lock and no per-call handle: adding one would mean a lock on a path whose
# only purpose is to be cheap when disarmed. `ctx.explain_analyze` is a
# developer-facing diagnostic invoked deliberately, not a production-serving
# call, so serial use is the contract. If that ever stops being true the fix is a
# per-call arena keyed by a token, not a mutex on the counters.
#
# ⚠ THIS IS A PROCESS-GLOBAL, AND `komira_metrics/__init__.mojo` SAYS "no
# process-global singletons". That principle is about the
# metric registry: a library must not force a global one on an embedder, who
# owns and injects its `MetricsSet`s. It is not a ban on diagnostic counters — the engine's
# other execution counters are process-global tables for the same reason this
# one is (the measurement points are unreachable from any object the caller
# holds). The
# distinction that matters is that NOTHING here participates in query semantics:
# every slot is write-only from the engine's side and read-only from the
# diagnostic's, and a failure to materialize the global degrades to "not armed".
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global, external_call
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_metrics.explain_analyze import (
    ExecutionReport,
    record_operator_metrics,
)
from komira_metrics.metrics_set import (
    MetricsSnapshot,
    METRIC_KIND_COUNTER,
    METRIC_KIND_TIME,
)
from komira_name_registry import name_id as _literal_name_id


# -----------------------------------------------------------------------------
# TIER 1: the comptime kill-switch
# -----------------------------------------------------------------------------

comptime EA_COLLECTION_COMPILED_IN: Bool = True
"""Compile the EXPLAIN ANALYZE collection seams into the binary at all.

True (shipped): each seam emits its `ea_armed()` read — one relaxed atomic load
of a TU-static, through one C call — and records only when a caller has armed
the collector. `ctx.explain_analyze(...)` reports real per-operator numbers.

False: `@parameter if` drops the whole block at every recording seam, so
neither the flag read, nor the `perf_counter_ns()` bracket, nor `ea_record`, nor
`_ea_kind_for_plan_tag` is emitted or named in those translation units, and
`ea_armed()` folds to a comptime `False`. This is the only setting for which
"zero instructions on the collection path" holds, and
`tests/test_explain_analyze_disarmed_cost.mojo` asserts the contract in
BOTH settings so neither can rot.

⚠ FLIPPING THIS TO FALSE DOES NOT BREAK `ctx.explain_analyze` — it degrades it.
The call still runs, still renders all six sections, and section 4 reports every
operator kind as not-fired. That is deliberate: a kill-switch that turns a
diagnostic into a crash is one nobody dares to use.
"""


# -----------------------------------------------------------------------------
# Operator kinds. Stable ids — APPEND ONLY (a renderer and a test join on them).
#
# The kind is the OPERATOR IDENTITY, not the plan tag. Each recording site names
# its own kind; the one site that starts from a `PLAN_*` tag
# (`materialize_subplan._dispatch_thunk`) owns the tag->kind map LOCALLY, in
# `_ea_kind_for_plan_tag`.
#
# ⚠ THE MAP DELIBERATELY DOES NOT LIVE HERE. Here it would have to spell the
# `PLAN_*` values as integer literals to avoid a `komira_metrics ->
# the core packages` import — a mirror, and a mirror of a tag table drifts
# silently. It lives beside the ONE call site, in a module that already
# imports the real `PLAN_*` constants, so there is nothing to keep in sync.
# -----------------------------------------------------------------------------
comptime EA_SCAN_LEAF: Int = 0        # materialize_parquet_collect (the tower-free leaf)
comptime EA_STREAM_SINK: Int = 1      # execute_collect_morsel_sink{,_op} driver
comptime EA_AGGREGATE: Int = 2
comptime EA_SORT: Int = 3
comptime EA_DISTINCT: Int = 4
comptime EA_JOIN: Int = 5
comptime EA_CROSS_JOIN: Int = 6
comptime EA_WINDOW: Int = 7
comptime EA_PARTITION_TOPN: Int = 8
comptime EA_ASOF_JOIN: Int = 9
comptime EA_UNION: Int = 10
comptime EA_OTHER_BREAKER: Int = 11   # a tag the map does not name — never silent
# THE TWO SIDES OF A HASH JOIN, reported separately. `EA_JOIN` above is the
# whole join NODE (its output cardinality); these two are its INPUTS. They are
# separate kinds and not fields on `EA_JOIN` because the build/probe ORIENTATION
# is a real, decided question in this engine — `materialize_inmem_build_inmem_
# probe_join` contains an explicit swap heuristic whose whole job is to put the
# smaller side on the build — and a report that folded the two together could
# not answer "which side did it build?".
comptime EA_JOIN_BUILD: Int = 12      # rows on the side the hash table was built from
comptime EA_JOIN_PROBE: Int = 13      # rows on the side streamed through the probe

comptime EA_N_KINDS: Int = 14

# Per-kind slot layout. 4 spare so a new field does not renumber the table.
comptime EA_F_CALLS: Int = 0
comptime EA_F_ROWS: Int = 1
comptime EA_F_NS: Int = 2
comptime EA_SLOT_STRIDE: Int = 8


def _write_ea_kind_name[W: Writer](mut writer: W, kind: Int):
    """WRITE what `ea_kind_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library can
    bind such a pair CROSSED, and the host process crashes with it."""
    if kind == EA_SCAN_LEAF:
        writer.write(String("ScanLeaf(parquet collect)"))
        return
    if kind == EA_STREAM_SINK:
        writer.write(String("StreamingSink(morsel driver)"))
        return
    if kind == EA_AGGREGATE:
        writer.write(String("Aggregate"))
        return
    if kind == EA_SORT:
        writer.write(String("Sort"))
        return
    if kind == EA_DISTINCT:
        writer.write(String("Distinct"))
        return
    if kind == EA_JOIN:
        writer.write(String("Join"))
        return
    if kind == EA_CROSS_JOIN:
        writer.write(String("CrossJoin"))
        return
    if kind == EA_WINDOW:
        writer.write(String("Window"))
        return
    if kind == EA_PARTITION_TOPN:
        writer.write(String("PartitionTopN"))
        return
    if kind == EA_ASOF_JOIN:
        writer.write(String("AsofJoin"))
        return
    if kind == EA_UNION:
        writer.write(String("Union"))
        return
    if kind == EA_OTHER_BREAKER:
        writer.write(String("OtherBreaker"))
        return
    if kind == EA_JOIN_BUILD:
        writer.write(String("  JoinBuildSide"))
        return
    if kind == EA_JOIN_PROBE:
        writer.write(String("  JoinProbeSide"))
        return
    writer.write(String("kind#") + String(kind))
    return


def ea_kind_name(kind: Int) -> String:
    """Human label for a kind id. Unknown ids render as `kind#<n>` — the
    renderer never silently drops a slot that carries counts."""
    var out = String()
    _write_ea_kind_name(out, kind)
    return out^


# -----------------------------------------------------------------------------
# Process-global storage
# -----------------------------------------------------------------------------


def _init_ea_slots() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: the whole per-kind slot table, zeroed."""
    var n = EA_N_KINDS * EA_SLOT_STRIDE
    var raw = alloc[AtomicI64](n)
    for i in range(n):
        (raw + i).unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(
            Scalar[DType.int64](0)
        )
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _EA_SLOTS = _Global["komira_metrics_explain_analyze_slots", _init_ea_slots]


# -----------------------------------------------------------------------------
# Arm / disarm / reset
#
# THE ARM FLAG IS NOT A MOJO `_Global`. It is a TU-static `int` in this
# package's `native/komira_metrics_ea_flag.c` (`_ea_armed_flag`), read with a
# relaxed `__atomic_load_n`. See the COST WHEN DISARMED block at the top of
# this file: a `_Global.get_or_create_ptr()` read costs ~30 ns, on a path every
# breaker crosses. The C file is linked with this library, so every binary that
# imports this module carries the flag.
# -----------------------------------------------------------------------------


@always_inline
def ea_armed() -> Bool:
    """True iff a caller has armed the collector for the current query.

    The ONE thing every recording site calls first. Hoist it out of any region
    you bracket — do not call it per row, per morsel, or per worker.

    Compiles to a comptime `False` when `EA_COLLECTION_COMPILED_IN` is False,
    which is what lets the `@parameter if` at each seam drop that seam entirely.
    """

    comptime if not EA_COLLECTION_COMPILED_IN:
        return False
    else:
        # One relaxed atomic load of the shim's TU-static, through one C call.
        # No allocation, no getenv, no `try` — so, unlike a `_Global` registry
        # lookup, there is no failure mode to swallow.
        return external_call["komira_ea_armed", Int32]() != Int32(0)


def ea_arm() raises:
    """Arm the collector. Callers MUST pair this with `ea_disarm()` (the SDK
    entry point does so in a `try/finally`).

    A no-op when `EA_COLLECTION_COMPILED_IN` is False: with the seams compiled
    out there is nothing that could observe the flag, and setting it anyway
    would make `ea_armed()` and the flag disagree.
    """

    comptime if EA_COLLECTION_COMPILED_IN:
        _ = external_call["komira_ea_set_armed", Int32](Int32(1))


def ea_disarm() raises:
    """Disarm the collector. Leaves the slot table intact so the caller can read
    it after the query has finished."""

    comptime if EA_COLLECTION_COMPILED_IN:
        _ = external_call["komira_ea_set_armed", Int32](Int32(0))


def ea_reset() raises:
    """Zero every slot. Called by the SDK entry BEFORE the query so a report
    describes ONE query rather than every query the process has run."""
    var g = _EA_SLOTS.get_or_create_ptr()
    var base = UnsafePointer(to=g[][])
    for i in range(EA_N_KINDS * EA_SLOT_STRIDE):
        (base + i)[].store(Int64(0))


# -----------------------------------------------------------------------------
# Record / read
# -----------------------------------------------------------------------------


def ea_record(kind: Int, rows: Int, elapsed_ns: Int) raises:
    """Record ONE execution of an operator of `kind`.

    Args:
        kind: One of the `EA_*` kind ids.
        rows: Rows the operator PRODUCED. Pass 0 when the driver genuinely
            cannot know (the generic streaming driver returns `K.Output`, which
            is not a `RecordBatch` — it reports calls and wall, and says so).
        elapsed_ns: Wall of this execution, in nanoseconds.

    Callers gate on `ea_armed()`; this function does NOT re-check, so a site
    that forgets the gate pays the atomics unconditionally. That is deliberate:
    the gate belongs where the clock read is, not here.

    ⚠ `elapsed_ns` IS INCLUSIVE OF NESTED OPERATORS, AND THE COLUMN THEREFORE
    DOES NOT SUM TO THE QUERY WALL. The walker's bracket is around a plan NODE,
    and the walker RECURSES through the same bracket, so a Join over an Aggregate
    charges the aggregate's wall to both rows. That is the ordinary convention
    for a tree-shaped EXPLAIN ANALYZE (a node's time includes its children's),
    but it means the section-4 column is a per-node total and not a partition of
    the query. `explain_analyze`'s section 6 carries the one true wall.
    """
    if kind < 0 or kind >= EA_N_KINDS:
        return
    # SAFETY: FFI carve-out (see `ea_armed`).
    var g = _EA_SLOTS.get_or_create_ptr()
    var base = UnsafePointer(to=g[][]) + kind * EA_SLOT_STRIDE
    _ = (base + EA_F_CALLS)[].fetch_add(Int64(1))
    if rows != 0:
        _ = (base + EA_F_ROWS)[].fetch_add(Int64(rows))
    if elapsed_ns > 0:
        _ = (base + EA_F_NS)[].fetch_add(Int64(elapsed_ns))


def ea_slot(kind: Int, field: Int) raises -> Int64:
    """Read one slot field. `field` is `EA_F_CALLS` / `EA_F_ROWS` / `EA_F_NS`."""
    if kind < 0 or kind >= EA_N_KINDS or field < 0 or field >= EA_SLOT_STRIDE:
        return Int64(0)
    # SAFETY: FFI carve-out (see `ea_armed`).
    var g = _EA_SLOTS.get_or_create_ptr()
    var base = UnsafePointer(to=g[][]) + kind * EA_SLOT_STRIDE
    return (base + field)[].load()


# -----------------------------------------------------------------------------
# Fold into an ExecutionReport — the bridge back to `explain_analyze`'s data model
# -----------------------------------------------------------------------------


comptime _EA_NAME_ROWS_EMITTED: UInt32 = _literal_name_id["rows_emitted"]()
comptime _EA_NAME_ELAPSED_COMPUTE: UInt32 = _literal_name_id["elapsed_compute"]()


def build_execution_report() raises -> ExecutionReport:
    """Fold the slot table into a real `ExecutionReport`.

    One `OperatorMetricsBlock` per kind THAT FIRED (calls > 0); kinds that did
    not run are omitted rather than rendered as zero rows, so the report is a
    record of what executed. The label carries the call count, because "Join ran
    twice" and "Join ran once over twice the rows" are different facts and the
    metric entries alone cannot separate them.

    The metric names are the SAME comptime FNV-1a digests
    `explain_analyze._name_for_id` already knows (`rows_emitted`,
    `elapsed_compute`), so the existing renderer prints them by name with the
    right units and no table edit.
    """
    var report = ExecutionReport()
    # RENDER ORDER, stated explicitly rather than taken from the id numbering.
    # The ids are append-only (a new kind takes the next number), so id order
    # drifts away from reading order the moment anything is added — as it already
    # has: the two join SIDES are ids 12/13 but belong directly under the `Join`
    # node they are the inputs to. This list is where reading order lives.
    var order = List[Int]()
    order.append(EA_SCAN_LEAF)
    order.append(EA_STREAM_SINK)
    order.append(EA_AGGREGATE)
    order.append(EA_SORT)
    order.append(EA_DISTINCT)
    order.append(EA_JOIN)
    order.append(EA_JOIN_BUILD)
    order.append(EA_JOIN_PROBE)
    order.append(EA_CROSS_JOIN)
    order.append(EA_WINDOW)
    order.append(EA_PARTITION_TOPN)
    order.append(EA_ASOF_JOIN)
    order.append(EA_UNION)
    order.append(EA_OTHER_BREAKER)
    # A kind missing from `order` would be silently dropped from every report,
    # a silent drop no reader of the report could notice. Assert the list
    # covers the table instead of trusting whoever edits it next.
    if len(order) != EA_N_KINDS:
        raise Error(
            "explain_analyze_collect.build_execution_report: the render-order"
            " list has " + String(len(order)) + " entries but EA_N_KINDS is "
            + String(EA_N_KINDS) + ". A kind was added without being given a"
            " place in the report, and would render nowhere."
        )
    for oi in range(len(order)):
        var kind = order[oi]
        var calls = ea_slot(kind, EA_F_CALLS)
        if calls == Int64(0):
            continue
        var rows = ea_slot(kind, EA_F_ROWS)
        var ns = ea_slot(kind, EA_F_NS)
        var snap = MetricsSnapshot()
        # A METRIC IS OMITTED RATHER THAN RENDERED AS ZERO. "rows_emitted: 0"
        # reads as "this operator produced nothing", and "elapsed_compute: 0 us"
        # reads as "instantaneous" — but for the two join-SIDE rows the wall is
        # genuinely not a quantity (they are cardinalities of inputs), and for
        # the streaming-sink row the row count is genuinely not measurable (its
        # driver returns an associated `K.Output`, not a batch). Printing a zero
        # in either place would be an assertion the collector cannot support.
        # An absent line says "not measured here"; a zero would say "measured,
        # and it was zero".
        if rows > Int64(0):
            _ = snap.append(_EA_NAME_ROWS_EMITTED, METRIC_KIND_COUNTER, rows)
        if ns > Int64(0):
            _ = snap.append(_EA_NAME_ELAPSED_COMPUTE, METRIC_KIND_TIME, ns)
        var label = ea_kind_name(kind) + " x" + String(calls)
        if kind == EA_STREAM_SINK:
            label += "  (rows not measurable at this driver)"
        record_operator_metrics(report, label^, snap^)
    return report^
