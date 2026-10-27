# =============================================================================
# join_layout_counter -- FIRE witness + stderr marker for the single-key
# chain-entry layouts (`nobi`: no `build_indices`; `fused`: one interleaved
# key/next record per build row)
# =============================================================================
#
# WHY THIS MODULE EXISTS. A layout change is answer-preserving by construction,
# so a byte-equivalence oracle is BLIND to which arm ran: both arms produce the
# same bytes, which is the whole claim. A join lever once shipped with no firing
# observable, fired on 0 of 84 corpus cells, and nothing went red. A lever whose
# only guard is its own output cannot be shown to have run.
#
# So the layouts carry TWO observables, and they answer different questions:
#
#   * `[JOIN_CHAIN_LAYOUT]` -- printed by the BUILD, once per hash-join build.
#     It states the arm and the size of what it deleted or allocated. This
#     proves the INDEX WAS BUILT in that layout.
#   * `[JOIN_PROBE_LAYOUT]` -- printed by the first probe ENTRY per process that
#     takes a specialised arm, naming the site. This proves a PROBE ACTUALLY
#     ENTERED the specialised loop. Once per process, not once per call: the
#     entry points are per-batch and `probe_inner_chunk` is per-64K-chunk.
#
# THE MARKERS PRINT ONLY UNDER THE SCHEDULER TRACE (`sched_trace_enabled`), AND
# TO STDERR (fd 2), NEVER TO STDOUT. An earlier guard tested the LEVER VALUES
# ("print when a non-default arm is on"); when both layouts became the default
# that guard became unconditionally true and every hash-join build printed its
# marker onto stdout, which is a query's result stream: the conformance gates
# read the marker where the header should be. Whether somebody ASKED for a
# trace is the one condition a promotion cannot make stale.
#
# `[JOIN_PROBE_LAYOUT]` resolves the trace HERE rather than taking it as an
# argument, because its call sites are probe-entry dispatchers with no such
# flag in hand. The resolve happens AFTER the once-per-process latch, so the
# hot entry (`join_layout_record_probe_hot`, ~50k calls/query) never pays it.
#
# The COUNTERS are the assertable form of the same facts and are what the
# byte-equivalence test reads: a printed line is not a test assertion.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.io import FileDescriptor
from std.memory import OwnedPointer, alloc

from komira_async.runtime.sched_trace import sched_trace_enabled

# fd 2. A query's stdout is its RESULT STREAM: a diagnostic written there is
# not a log line, it is a corrupted answer.
comptime _JL_STDERR: FileDescriptor = FileDescriptor(2)


def _init_jl_counter() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _JL_BUILD_NOBI = _Global[
    "komira_join_layout_build_nobi", _init_jl_counter
]
comptime _JL_BUILD_FUSED = _Global[
    "komira_join_layout_build_fused", _init_jl_counter
]
comptime _JL_PROBE_NOBI = _Global[
    "komira_join_layout_probe_nobi", _init_jl_counter
]
comptime _JL_PROBE_FUSED = _Global[
    "komira_join_layout_probe_fused", _init_jl_counter
]
# The HOT-ENTRY latch. See `join_layout_record_probe_hot`.
comptime _JL_HOT_SEEN = _Global[
    "komira_join_layout_hot_seen", _init_jl_counter
]


# -----------------------------------------------------------------------------
# BUILD side
# -----------------------------------------------------------------------------


def join_layout_record_build(
    kernel: StaticString,
    nobi: Bool,
    fused: Bool,
    rows: Int,
    trace: Bool,
) raises:
    """Record — and, when a lever is on, ANNOUNCE — the chain-entry layout one
    hash-join build produced.

    `kernel` is `serial` / `serial_bloom` / `chain` (the parallel Treiber build),
    so a reader can tell WHICH builder emitted the layout. `trace` is the caller's
    already-resolved `sched_trace_enabled()` — passed in rather than read here so
    this module does not import the async layer.

    Prints ONLY under the scheduler trace, and prints to STDERR. The counters
    are unconditional; see the module header for why a lever-valued guard is a
    defect once the layouts are the default."""
    # SAFETY: FFI carve-out — `_Global.get_or_create_ptr` targets KGEN-runtime
    # static storage (process-lifetime); the wildcard is the stdlib API's own
    # return type, confined to this helper.
    if nobi:
        var gp = _JL_BUILD_NOBI.get_or_create_ptr()
        _ = gp[][].fetch_add(Int64(1))
    if fused:
        var gp2 = _JL_BUILD_FUSED.get_or_create_ptr()
        _ = gp2[][].fetch_add(Int64(1))
    # `trace` AND NOTHING ELSE. See the module header: testing the lever
    # values here is what put this line on a query's result stream.
    if not trace:
        return
    print(
        "[JOIN_CHAIN_LAYOUT] kernel=",
        kernel,
        " nobi=",
        Int(nobi),
        " keynext=",
        Int(fused),
        " rows=",
        rows,
        # What the arm deleted / what it allocated instead, in BYTES, so the
        # marker states the size of the change and not merely that it happened.
        " bi_bytes_saved=",
        rows * 8 if nobi else 0,
        " keynext_bytes=",
        rows * 16 if fused else 0,
        " bk_nc_bytes=",
        0 if fused else rows * 16,
        file=_JL_STDERR,
    )


def join_layout_build_nobi_count() raises -> Int:
    """Builds that produced the ELIDED-`build_indices` layout, process-wide."""
    # SAFETY: FFI carve-out (see `join_layout_record_build`).
    var gp = _JL_BUILD_NOBI.get_or_create_ptr()
    return Int(gp[][].load())


def join_layout_build_fused_count() raises -> Int:
    """Builds that produced the FUSED key/next layout, process-wide."""
    # SAFETY: FFI carve-out (see `join_layout_record_build`).
    var gp = _JL_BUILD_FUSED.get_or_create_ptr()
    return Int(gp[][].load())


# -----------------------------------------------------------------------------
# PROBE side
# -----------------------------------------------------------------------------


def join_layout_record_probe(
    site: StaticString, nobi: Bool, fused: Bool
) raises:
    """Record one probe ENTRY that took a non-default specialised loop.

    Called from the DISPATCHER of each converted probe entry point — never from
    inside a loop — so this costs one atomic increment per batch/dispatch, not
    per row. Returns immediately on the default arm.

    The marker fires only on the FIRST such entry per lever per process (the
    `fetch_add` returning 0), names the site that got there first, goes to
    STDERR, and is emitted ONLY under the scheduler trace. The counters are
    unconditional either way — the trace resolve sits behind the latch, so the
    per-morsel entry never pays for it."""
    if not (nobi or fused):
        return
    var first = False
    # SAFETY: FFI carve-out (see `join_layout_record_build`).
    if nobi:
        var gp = _JL_PROBE_NOBI.get_or_create_ptr()
        if Int(gp[][].fetch_add(Int64(1))) == 0:
            first = True
    if fused:
        var gp2 = _JL_PROBE_FUSED.get_or_create_ptr()
        if Int(gp2[][].fetch_add(Int64(1))) == 0:
            first = True
    if not first:
        return
    # AFTER the latch, never before: this is the ONE call per lever per
    # process that reaches here, so resolving the trace costs nothing on the
    # ~50k-calls-per-query hot entry. And it is the guard that keeps the marker
    # off a query's result stream now that both layouts ship as `True`.
    if not sched_trace_enabled():
        return
    print(
        "[JOIN_PROBE_LAYOUT] site=",
        site,
        " nobi=",
        Int(nobi),
        " keynext=",
        Int(fused),
        file=_JL_STDERR,
    )


def join_layout_record_probe_hot(
    site: StaticString, nobi: Bool, fused: Bool
) raises:
    """The PER-MORSEL entry's recorder — records ONCE per process, then latches.

    THIS EXISTS BECAUSE THE INSTRUMENT WOULD OTHERWISE BE MEASURED INSTEAD OF
    THE LEVER. `probe_inner_chunk` is hc4's ACTUAL hot entry (the join probe
    operator calls it once per probe morsel), so at a 2048-row grain
    over a 100M-row probe it is entered on the order of FIFTY THOUSAND times per
    query. `join_layout_record_probe`'s unconditional `fetch_add` on a
    process-global would put ~50,000 CONTENDED atomic read-modify-writes, across
    20 workers, on one cache line, inside the arm whose wall time the whole
    exercise exists to compare -- single-digit ms of pure instrumentation charged
    to the TREATMENT arm only, which biases the measurement in the direction that
    makes the lever look worse.

    So the treatment arm pays: two already-cached field reads, ONE RELAXED ATOMIC
    LOAD of a line nobody writes after the first call, and a predicted branch.
    The CONTROL arm pays nothing at all -- the `nobi or fused` test short-circuits
    before the load.

    ⚠ THE CONSEQUENCE, STATED: this contributes EXACTLY ONE to the probe fire
    counters per process, not one per call. A test asserting a per-entry-point
    count must expect one from here (see `_EXPECTED_PROBE_ENTRIES` in
    `test_join_chain_layout_byte_equiv`), and `reset_join_layout_counters` clears
    the latch so consecutive arms in one process each get their own fire."""
    if not (nobi or fused):
        return
    # SAFETY: FFI carve-out (see `join_layout_record_build`).
    var seen = _JL_HOT_SEEN.get_or_create_ptr()
    if Int(seen[][].load()) != 0:
        return
    seen[][].store(Scalar[DType.int64](1))
    join_layout_record_probe(site, nobi, fused)


def join_layout_probe_nobi_count() raises -> Int:
    """Probe entries that took the elided-`build_indices` arm, process-wide."""
    # SAFETY: FFI carve-out (see `join_layout_record_build`).
    var gp = _JL_PROBE_NOBI.get_or_create_ptr()
    return Int(gp[][].load())


def join_layout_probe_fused_count() raises -> Int:
    """Probe entries that took the fused key/next arm, process-wide."""
    # SAFETY: FFI carve-out (see `join_layout_record_build`).
    var gp = _JL_PROBE_FUSED.get_or_create_ptr()
    return Int(gp[][].load())


def reset_join_layout_counters() raises:
    """Reset all four process-wide counters to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `join_layout_record_build`).
    _JL_BUILD_NOBI.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JL_BUILD_FUSED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JL_PROBE_NOBI.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JL_PROBE_FUSED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JL_HOT_SEEN.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
