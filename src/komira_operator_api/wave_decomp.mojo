# =============================================================================
# wave_decomp — the SUB-PHASE partition INSIDE `fj_probe_wave` (region 64)
# (hc4 parity campaign, 2026-09-03)
# =============================================================================
#
# ⛔ THIS IS AN INSTRUMENT, NOT A LEVER. Every counter here is DEFAULT-OFF
# behind a switch the CALLER owns (an argument, never the environment), read once
# per fork body, and every recorder is called only from inside an `if _wd_on:`
# arm. The shipped arm pays
# one cold Bool per worker-body entry and per `execute()` entry — no clock, no
# atomic, no branch beyond that test.
#
# =============================================================================
# WHY IT EXISTS
# =============================================================================
#
# `fj_probe_wave` is 55-75% of hc4's wall depending on the SEG_OUT disposition,
# and NOTHING could say what is inside it. The rooted region partition stops at
# the fork; `SCHED_OPWAVE` splits the fork's worker-busy time exactly TWO ways
# (`op_ns` from the operator's own `elapsed_compute`, `scan_ns` = the residual);
# and below that the only instrument was a symbol profile, which is the
# cycle-side method that produced four retractions in this campaign.
#
# A 75% region is not a finding. It is a missing instrument.
#
# =============================================================================
# THE PARTITION, AND WHY IT CLOSES EXACTLY
# =============================================================================
#
# Two nested brackets, each of which measures its OWN total rather than
# inferring one, so `residual = total - sum(parts)` is a MEASUREMENT and a
# non-zero residual names un-bracketed code rather than being absorbed:
#
#   WORKER BODY  (`_StreamingTask.execute`, one call per worker per fork)
#     wb_total = src_next + op_exec + sink_push + <residue>
#       src_next    `source.next_morsel(wid)`        — parquet DECODE
#       op_exec     `op.execute(m)`                  — the join probe operator
#       sink_push   `sink.consume_morsel(...)`       — collect-sink accumulate
#       residue     the pull loop's own plumbing (morsel moves, HMO chunk
#                   extraction, the `RecordBatch()` placeholder swaps)
#
#   OPERATOR  (`JoinProbeOp.execute`, INNER arms only)
#     jp_total = intake + key + bufs + kernel + marshal + assemble + install
#       intake      entry dispatch + fresh-morsel batch move + probe reset
#       key         `column_index` + `_acquire_probe_key`
#       bufs        chunk buffer acquisition (alloc or slot reuse)
#       kernel      `probe_inner_chunk` — THE PROBE
#       marshal     the mask walk that copies the raw match buffers into
#                   `List[Int]` — a SECOND full pass over the matches
#       assemble    `assemble_join_result` — THE GATHER
#       install     chunk into `morsel.batch`, slot clear, metric record
#
# `jp_total` is bracketed at the same two points `_record_metrics` uses, so it
# is directly comparable to the `elapsed_compute` that `SCHED_OPWAVE` reads as
# `op_ns`. Two independent clocks over one interval: if they disagree, the
# op-wave split is wrong, and that is worth knowing on its own.
#
# ⚠ THE SUM IS OVER WORKERS. Every figure here is a worker-ns TOTAL across the
# fork's 20 threads, not a wall. The denominator is `region64_wall x workers`,
# which is what `SCHED_OPWAVE`'s `busy_ns` is a share of too.
#
# =============================================================================
# ⭐ AND THE OPERATION COUNTS, WHICH ARE THE POINT
# =============================================================================
#
# Cycle-side stories died four times in this campaign while the counters stood.
# So the ns columns are the SECONDARY output here; the primary one is how many
# times each thing HAPPENS, at a row count both engines agree on:
#
#   n_morsels        morsels pulled from the source
#   n_exec           `execute()` calls (>= n_morsels: HAVE_MORE_OUTPUT resumes)
#   n_kernel         `probe_inner_chunk` calls
#   n_pairs_raw      matches the kernel WROTE into the raw buffers
#   n_pairs_kept     matches that survived the selection-mask walk
#   n_assemble       `assemble_join_result` calls
#   n_rows_out       rows those calls emitted
#   n_pushes         `consume_morsel` calls into the collect sink
#   n_defer          `_execute_inner_deferred` entries (the OTHER INNER arm —
#                    a non-zero here and a zero `n_assemble` means the cell is
#                    on the deferred route and every chunked figure is dark)
#
# ⚠ `n_pairs_raw` vs `n_pairs_kept` vs `n_rows_out` is the excess-work reading.
# They are three counts of ONE row set, taken at three points, and any gap
# between them is a pass this engine executes over rows it has already
# produced. DuckDB's counterpart emits matched pairs straight into the output
# chunk and has no second pass to count.
# =============================================================================

from komira_counters.global_counter import GlobalCounter

from std.io import FileDescriptor


# ---- WORKER BODY brackets (ns) ----------------------------------------------
comptime _WD_WB_TOTAL = GlobalCounter["komira_wd_wb_total"]
comptime _WD_SRC_NEXT = GlobalCounter["komira_wd_src_next"]
comptime _WD_OP_EXEC = GlobalCounter["komira_wd_op_exec"]
comptime _WD_SINK_PUSH = GlobalCounter["komira_wd_sink_push"]

# ---- OPERATOR brackets (ns) -------------------------------------------------
comptime _WD_JP_TOTAL = GlobalCounter["komira_wd_jp_total"]
comptime _WD_JP_INTAKE = GlobalCounter["komira_wd_jp_intake"]
comptime _WD_JP_KEY = GlobalCounter["komira_wd_jp_key"]
comptime _WD_JP_BUFS = GlobalCounter["komira_wd_jp_bufs"]
comptime _WD_JP_KERNEL = GlobalCounter["komira_wd_jp_kernel"]
comptime _WD_JP_MARSHAL = GlobalCounter["komira_wd_jp_marshal"]
comptime _WD_JP_ASSEMBLE = GlobalCounter["komira_wd_jp_assemble"]
comptime _WD_JP_INSTALL = GlobalCounter["komira_wd_jp_install"]

# ---- OPERATION COUNTS -------------------------------------------------------
comptime _WD_N_MORSELS = GlobalCounter["komira_wd_n_morsels"]
comptime _WD_N_EXEC = GlobalCounter["komira_wd_n_exec"]
comptime _WD_N_KERNEL = GlobalCounter["komira_wd_n_kernel"]
comptime _WD_N_PAIRS_RAW = GlobalCounter["komira_wd_n_pairs_raw"]
comptime _WD_N_PAIRS_KEPT = GlobalCounter["komira_wd_n_pairs_kept"]
comptime _WD_N_ASSEMBLE = GlobalCounter["komira_wd_n_assemble"]
comptime _WD_N_ROWS_OUT = GlobalCounter["komira_wd_n_rows_out"]
comptime _WD_N_PUSHES = GlobalCounter["komira_wd_n_pushes"]
comptime _WD_N_DEFER = GlobalCounter["komira_wd_n_defer"]
comptime _WD_N_PROBE_ROWS = GlobalCounter["komira_wd_n_probe_rows"]


# -----------------------------------------------------------------------------
# Gate
# -----------------------------------------------------------------------------
#
# There is none here. The caller owns the switch and READS IT ONCE PER FORK BODY,
# NOT PER MORSEL: every call site carries the answer as a cold `Bool` local for
# the life of a worker body or an `execute()` frame. A per-morsel gate read would
# put an atomic load on the hot path of the shipped arm's control measurement,
# which is exactly the contamination this campaign's regime forbids.


# -----------------------------------------------------------------------------
# Recorders — one relaxed fetch_add each, called only from an armed arm
# -----------------------------------------------------------------------------


def wd_wb(total_ns: Int, src_ns: Int, op_ns: Int, sink_ns: Int) raises:
    """One WORKER BODY. Recorded once per worker per fork, never per morsel —
    the four values are that body's own accumulated totals."""
    _WD_WB_TOTAL.add(total_ns)
    _WD_SRC_NEXT.add(src_ns)
    _WD_OP_EXEC.add(op_ns)
    _WD_SINK_PUSH.add(sink_ns)


def wd_wb_counts(morsels: Int, execs: Int, pushes: Int) raises:
    """The worker body's operation counts. Same once-per-body contract."""
    _WD_N_MORSELS.add(morsels)
    _WD_N_EXEC.add(execs)
    _WD_N_PUSHES.add(pushes)


def wd_jp(
    total_ns: Int,
    intake_ns: Int,
    key_ns: Int,
    bufs_ns: Int,
    kernel_ns: Int,
    marshal_ns: Int,
    assemble_ns: Int,
    install_ns: Int,
) raises:
    """One `JoinProbeOp.execute` frame's seven sub-phases plus its own total.

    ⚠ ONE CALL PER `execute()`, NOT ONE PER PHASE. Seven separate recorders
    would put seven contended atomics on a path entered thousands of times per
    rep across 20 threads; batching them into one call keeps the instrument's
    own cost inside the noise floor it has to measure under."""
    _WD_JP_TOTAL.add(total_ns)
    _WD_JP_INTAKE.add(intake_ns)
    _WD_JP_KEY.add(key_ns)
    _WD_JP_BUFS.add(bufs_ns)
    _WD_JP_KERNEL.add(kernel_ns)
    _WD_JP_MARSHAL.add(marshal_ns)
    _WD_JP_ASSEMBLE.add(assemble_ns)
    _WD_JP_INSTALL.add(install_ns)


def wd_jp_counts(
    probe_rows: Int,
    kernel_calls: Int,
    pairs_raw: Int,
    pairs_kept: Int,
    assembles: Int,
    rows_out: Int,
) raises:
    """One `execute()` frame's operation counts. The excess-work reading."""
    _WD_N_PROBE_ROWS.add(probe_rows)
    _WD_N_KERNEL.add(kernel_calls)
    _WD_N_PAIRS_RAW.add(pairs_raw)
    _WD_N_PAIRS_KEPT.add(pairs_kept)
    _WD_N_ASSEMBLE.add(assembles)
    _WD_N_ROWS_OUT.add(rows_out)


def wd_note_deferred() raises:
    """One `_execute_inner_deferred` entry — the OTHER INNER arm.

    ⚠ THIS IS THE ROUTE WITNESS, AND IT IS THE FIRST THING TO READ. hc4's arm
    is decided by `_defer_armed` in the driver, and that decision has moved
    three times: `KOMIRA_JOIN_DEFER_TRAFFIC_RULE` going default-ON
    (2026-09-01) sent hc4 to the deferred arm; `KOMIRA_JOIN_SEG_OUT` going
    default-ON (2026-09-02) took it straight back off, because a `not _seg_out`
    conjunct then HARD-SELECTED the staged producer; and 2026-09-12 replaced
    that conjunct with a cost comparison (`deferred_gather_outprices_segments`),
    which returns hc4 to the deferred arm ON ITS SHAPE rather than on a lever.
    So which arm this cell takes is not safe to assume from any landing's memo
    — `n_defer` against `n_assemble` is what settles it per run."""
    _WD_N_DEFER.add(1)


# -----------------------------------------------------------------------------
# Readers
# -----------------------------------------------------------------------------


# NOTE: there is deliberately no `get(g: OwnedPointer[...])` helper here.
# `OwnedPointer` is Movable-only, so it cannot be a by-value parameter; every
# read is written out with the same double-deref the levers module uses.


def wave_decomp_reset_counters() raises:
    """Zero every accumulator. TEST-ONLY, and the per-rep boundary for a
    harness that wants ONE rep's figures rather than a cumulative total."""
    _WD_WB_TOTAL.reset()
    _WD_SRC_NEXT.reset()
    _WD_OP_EXEC.reset()
    _WD_SINK_PUSH.reset()
    _WD_JP_TOTAL.reset()
    _WD_JP_INTAKE.reset()
    _WD_JP_KEY.reset()
    _WD_JP_BUFS.reset()
    _WD_JP_KERNEL.reset()
    _WD_JP_MARSHAL.reset()
    _WD_JP_ASSEMBLE.reset()
    _WD_JP_INSTALL.reset()
    _WD_N_MORSELS.reset()
    _WD_N_EXEC.reset()
    _WD_N_KERNEL.reset()
    _WD_N_PAIRS_RAW.reset()
    _WD_N_PAIRS_KEPT.reset()
    _WD_N_ASSEMBLE.reset()
    _WD_N_ROWS_OUT.reset()
    _WD_N_PUSHES.reset()
    _WD_N_DEFER.reset()
    _WD_N_PROBE_ROWS.reset()


def wave_decomp_dump(site: StaticString, enabled: Bool = False) raises:
    """Print the cumulative partition. Silent unless `enabled` (DEFAULT OFF).

    ⚠ A COUNTER THAT DOES NOT PRINT ON THE ROUTE UNDER TEST IS NOT AN
    OBSERVABLE (the standing rule on `join_probe_levers_dump`, earned twice
    by dumps wired to the wrong funnel). hc4 reaches
    `materialize_join._run_fused_parquet_probe`; that is where this is called.

    RESIDUALS ARE PRINTED, NOT ABSORBED. `wb_resid` and `jp_resid` are each
    `total - sum(parts)` over two independently-measured brackets. A large one
    names code inside the bracket that no sub-phase covers, which is a finding
    about the instrument and has to be visible as such."""
    if not enabled:
        return
    var wb = _WD_WB_TOTAL.read()
    var src = _WD_SRC_NEXT.read()
    var opx = _WD_OP_EXEC.read()
    var snk = _WD_SINK_PUSH.read()
    var jt = _WD_JP_TOTAL.read()
    var j1 = _WD_JP_INTAKE.read()
    var j2 = _WD_JP_KEY.read()
    var j3 = _WD_JP_BUFS.read()
    var j4 = _WD_JP_KERNEL.read()
    var j5 = _WD_JP_MARSHAL.read()
    var j6 = _WD_JP_ASSEMBLE.read()
    var j7 = _WD_JP_INSTALL.read()
    print(
        "[WAVE_DECOMP] at=", site,
        " wb_total=", wb,
        " src_next=", src,
        " op_exec=", opx,
        " sink_push=", snk,
        " wb_resid=", wb - src - opx - snk,
        " jp_total=", jt,
        " jp_intake=", j1,
        " jp_key=", j2,
        " jp_bufs=", j3,
        " jp_kernel=", j4,
        " jp_marshal=", j5,
        " jp_assemble=", j6,
        " jp_install=", j7,
        " jp_resid=", jt - j1 - j2 - j3 - j4 - j5 - j6 - j7,
        " n_morsels=", _WD_N_MORSELS.read(),
        " n_exec=", _WD_N_EXEC.read(),
        " n_kernel=", _WD_N_KERNEL.read(),
        " n_pairs_raw=", _WD_N_PAIRS_RAW.read(),
        " n_pairs_kept=", _WD_N_PAIRS_KEPT.read(),
        " n_assemble=", _WD_N_ASSEMBLE.read(),
        " n_rows_out=", _WD_N_ROWS_OUT.read(),
        " n_pushes=", _WD_N_PUSHES.read(),
        " n_defer=", _WD_N_DEFER.read(),
        " n_probe_rows=", _WD_N_PROBE_ROWS.read(),
    )


# =============================================================================
# STREAM-WTRACE — per-WORKER, per-MORSEL timeline of a msink streaming fork.
# (phrase-count family lane, 2026-09-25, ). DEFAULT-OFF.
# =============================================================================
# `SCHED_FORK` reports a fork's span and its summed worker busy time, so it can
# say a fork ran at occupancy 0.82 -- but not WHY: a few heavy units finishing
# last, a slow worker, a late starter, and a coarse last claim all produce the
# same occupancy. This trace records, for every worker body of a streaming
# fork, its start / end instants and thread-CPU delta, and for every morsel it
# pulled the partition id (the parquet row group), its row count and three
# instants: pull start, pull end (decode + pushed filter), consume end (sink
# fold). A Gantt reconstruction over those lines names the tail directly.
#
# ⚠ Gate read ONCE per body; records are body-local and printed at body end,
# so the hot loop pays two clock reads per morsel only when armed. Lines:
#   SWTB w=<wid> t0=<abs ns> t1=<abs ns> cpu=<thread cpu ns> n=<morsels>
#   SWTM w=<wid> p=<partition_id> r=<rows> a=<abs ns> b=<abs ns> c=<abs ns>
# Absolute `perf_counter_ns` instants; group bodies into forks by t0 proximity.

def stream_wtrace_emit(
    wid: Int, t0: Int, t1: Int, cpu_ns: Int, rec: List[Int]
) raises:
    """Print one worker body's timeline. `rec` holds 5 ints per morsel:
    partition id, rows, pull-start, pull-end, consume-end."""
    var n = len(rec) // 5
    var out = String()
    out.write(
        "SWTB w=", wid, " t0=", t0, " t1=", t1, " cpu=", cpu_ns, " n=", n, "\n"
    )
    for i in range(n):
        var k = 5 * i
        out.write(
            "SWTM w=", wid, " p=", rec[k], " r=", rec[k + 1],
            " a=", rec[k + 2], " b=", rec[k + 3], " c=", rec[k + 4], "\n",
        )
    # stderr, never stdout: `//src/cmd/plan_exec` streams Arrow IPC on fd 1
    # (`scripts/lint_plan_exec_stdout.py`).
    print(out, end="", file=FileDescriptor(2))
