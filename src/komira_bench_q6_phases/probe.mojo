# =============================================================================
# probe -- TPC-H Q6 run n times per thread count, per-phase timings as JSON
# =============================================================================
#
# For each thread count: one context (the engine's workers), the lineitem file
# registered, one discarded run (the page cache and the engine's own caches
# warm), then `runs` timed runs of the corpus text of tpch/q6 through
# `run_sql`. Each run is bracketed by `Counters.now()` (page faults, context
# switches) and by the phase timers (komira_phase_timers), which the probe
# resets before the run and reads after it.
#
# The phase timers exist only in a build with `-D KOMIRA_PHASE_TIMERS=1`; the
# JSON says which this was (`timers_compiled_in`), and without them it holds
# the total and the page faults only.
#
# What the JSON reports per thread count, each as median, quartiles and
# range over the runs:
#   * total: the wall time of `run_sql`, in the probe's own clock;
#   * for each phase: `critical_ms` (the largest total of one thread in the
#     run; for a driver phase that is its time), `sum_ms` (over threads),
#     `longest_call_ms` (the longest single interval), `calls`, `lanes`
#     (threads that spent time in it) and `share_of_total_pct` (the median
#     critical time over the median total);
#   * page faults (minor, major), context switches and the peak resident set.
# Phases nest (claim holds decode and filter; task holds claim and sink; run_plan
# holds the segment phases), so shares are not meant to add to 100.

from std.os import makedirs
from std.time import perf_counter_ns

from komira_bench_corpus.catalog import find_query
from komira_engine_runtime.counters import Counters
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_footers.footer_cache import FooterCache
from komira_phase_timers.phase_timers import (
    PH_COUNT,
    PH_END_STAMP,
    PH_JOIN_TAIL,
    PT_LANES,
    pt_enabled,
    pt_overflow_count,
    pt_phase_name,
    pt_reset,
)
from komira_scalar_arithmetic.decimal_arith import I128
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import run_sql

from .phase_snapshot import PhaseAgg, snapshot_all
from .plan_render import render_plans
from .stats import maximum, median, minimum, quantile

comptime SCHEMA: String = "komira-q6-phase-probe/1"
comptime TPCH_SF1_Q6_REVENUE_UNSCALED: Int = 1231410782283
"""Q6 of TPC-H at scale factor 1 with the validation parameters, as the
DECIMAL(38,4) integer: 123141078.2283."""
comptime NO_EXPECTED_REVENUE: Int = -1
"""`ProbeSettings.expected_revenue` when the data is not TPC-H sf1."""

comptime NOTE: String = (
    "The machine this ran on is not a quiet host: other jobs share it, so"
    " absolute times vary from run to run. Read the numbers as RELATIVE (the"
    " share of each phase in the total, and how the time scales with the"
    " thread count), not as a headline figure and not as a comparison with"
    " another engine. The phase timers are not free: each interval costs two"
    " clock reads, a pthread_self and a scan of the thread table (about the"
    " number of threads), at row-group, morsel and segment granularity, so the"
    " total here is somewhat above that of a build without the timers; the"
    " overhead was not measured by this probe. timer_records_dropped is the"
    " number of intervals lost because more threads recorded than the timers"
    " have lanes (timer_lane_capacity); it must be 0."
)


struct RunRecord(Copyable, Movable):
    var total_ns: Int
    var phases: List[PhaseAgg]
    var minor_faults: Int
    var major_faults: Int
    var vol_switches: Int
    var invol_switches: Int
    var peak_rss_bytes: Int
    var user_ns: Int
    var system_ns: Int
    var revenue_unscaled: Int
    var dropped_records: Int
    """Phase-timer records lost to a full thread table in this run."""
    var ok: Bool

    def __init__(out self):
        self.total_ns = 0
        self.phases = List[PhaseAgg]()
        self.minor_faults = 0
        self.major_faults = 0
        self.vol_switches = 0
        self.invol_switches = 0
        self.peak_rss_bytes = 0
        self.user_ns = 0
        self.system_ns = 0
        self.revenue_unscaled = -1
        self.dropped_records = 0
        self.ok = False


def _run_once(mut ctx: EngineContext, text: String) raises -> RunRecord:
    var rec = RunRecord()
    pt_reset()
    var c0 = Counters.now()
    var t0 = perf_counter_ns()
    var outcome = run_sql(ctx, text)
    var t1 = perf_counter_ns()
    var c1 = Counters.now()
    rec.total_ns = Int(t1 - t0)
    var d = c1.delta_from(c0)
    rec.minor_faults = d.minor_page_faults
    rec.major_faults = d.major_page_faults
    rec.vol_switches = d.voluntary_ctx_switches
    rec.invol_switches = d.involuntary_ctx_switches
    rec.peak_rss_bytes = c1.peak_rss_bytes
    rec.user_ns = d.user_time_us * 1000
    rec.system_ns = d.system_time_us * 1000
    rec.phases = snapshot_all()
    rec.dropped_records = pt_overflow_count()
    if outcome.refusal:
        raise Error(
            "Q6 was refused at "
            + outcome.refusal.value().step
            + ": "
            + outcome.refusal.value().reason
        )
    ref batch = outcome.batches[0]
    var v: I128 = batch.column_at(0).as_decimal128().get_i128(0)
    rec.revenue_unscaled = Int(v.cast[DType.int64]())
    rec.ok = True
    return rec^


# --- JSON text -----------------------------------------------------------------


def _pad3(n: Int) -> String:
    var s = String(n)
    while s.byte_length() < 3:
        s = String("0") + s
    return s^


def ms_text(ns: Float64) -> String:
    """`ns` nanoseconds as milliseconds with three decimals."""
    var us = Int(ns / 1000.0 + 0.5)
    var neg = us < 0
    if neg:
        us = -us
    var out = String(us // 1000) + "." + _pad3(us % 1000)
    if neg:
        out = String("-") + out
    return out^


def _dist_ms(xs: List[Int]) -> String:
    var q1 = quantile(xs, 0.25)
    var q3 = quantile(xs, 0.75)
    return (
        String('{"median":') + ms_text(median(xs))
        + ',"q1":' + ms_text(q1)
        + ',"q3":' + ms_text(q3)
        + ',"iqr":' + ms_text(q3 - q1)
        + ',"min":' + ms_text(Float64(minimum(xs)))
        + ',"max":' + ms_text(Float64(maximum(xs)))
        + String("}")
    )


def _num(x: Float64) -> String:
    var tenths = Int(x * 10.0 + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10)


def _dist_count(xs: List[Int]) -> String:
    return (
        String('{"median":') + _num(median(xs))
        + ',"min":' + String(minimum(xs))
        + ',"max":' + String(maximum(xs))
        + String("}")
    )


def _series_ms(xs: List[Int]) -> String:
    var out = String("[")
    for i in range(len(xs)):
        if i > 0:
            out += ","
        out += ms_text(Float64(xs[i]))
    out += "]"
    return out^


def _series_int(xs: List[Int]) -> String:
    var out = String("[")
    for i in range(len(xs)):
        if i > 0:
            out += ","
        out += String(xs[i])
    out += "]"
    return out^


def _host_json(ref ctx: EngineContext) -> String:
    """What the engine's hardware probe saw on this host: the cores and
    caches the thread counts are to be read against."""
    ref hw = ctx.host_profile.hardware
    return (
        String('{"physical_cores":') + String(hw.physical_cores)
        + ',"logical_cores":' + String(hw.logical_cores)
        + ',"numa_nodes":' + String(hw.numa_nodes)
        + ',"l2_cache_kib":' + String(hw.l2_cache_bytes // 1024)
        + ',"l3_cache_mib":' + String(hw.l3_cache_bytes // 1048576)
        + ',"total_ram_gib":' + String(hw.total_ram_bytes // 1073741824)
        + ',"available_ram_gib":' + String(hw.available_ram_bytes // 1073741824)
        + String("}")
    )


def _json_config(
    threads_requested: Int, threads_effective: Int, ref runs: List[RunRecord]
) -> String:
    var totals = List[Int]()
    var minor = List[Int]()
    var major = List[Int]()
    var vol = List[Int]()
    var invol = List[Int]()
    var rss = List[Int]()
    var user = List[Int]()
    var system = List[Int]()
    var dropped = 0
    for r in range(len(runs)):
        dropped += runs[r].dropped_records
        totals.append(runs[r].total_ns)
        minor.append(runs[r].minor_faults)
        major.append(runs[r].major_faults)
        vol.append(runs[r].vol_switches)
        invol.append(runs[r].invol_switches)
        rss.append(runs[r].peak_rss_bytes // 1048576)
        user.append(runs[r].user_ns)
        system.append(runs[r].system_ns)
    var total_median = median(totals)
    var out = String('{"threads_requested":') + String(threads_requested)
    out += ',"threads_effective":' + String(threads_effective)
    out += ',"runs":' + String(len(runs))
    out += ',"timer_records_dropped":' + String(dropped)
    out += ',"total_ms":' + _dist_ms(totals)
    out += ',"total_ms_per_run":' + _series_ms(totals)
    out += ',"page_faults":{"minor_per_run":' + _series_int(minor)
    out += ',"minor":' + _dist_count(minor)
    out += ',"major":' + _dist_count(major) + "}"
    out += ',"context_switches":{"voluntary":' + _dist_count(vol)
    out += ',"involuntary":' + _dist_count(invol) + "}"
    out += ',"peak_rss_mib":' + _dist_count(rss)
    out += ',"cpu_ms":{"user":' + _dist_ms(user)
    out += ',"system":' + _dist_ms(system) + "}"
    out += ',"phases":{'
    var first = True
    for p in range(PH_COUNT):
        if p == PH_END_STAMP:
            continue
        var crit = List[Int]()
        var sums = List[Int]()
        var longest = List[Int]()
        var calls = List[Int]()
        var lanes = List[Int]()
        var any_calls = 0
        for r in range(len(runs)):
            ref a = runs[r].phases[p]
            crit.append(a.crit_ns)
            sums.append(a.sum_ns)
            longest.append(a.longest_ns)
            calls.append(a.calls)
            lanes.append(a.lanes)
            any_calls += a.calls
        if any_calls == 0:
            continue
        if not first:
            out += ","
        first = False
        var share = 0.0
        if total_median > 0.0:
            share = 100.0 * median(crit) / total_median
        out += '"' + pt_phase_name(p) + '":{"critical_ms":' + _dist_ms(crit)
        out += ',"sum_ms":' + _dist_ms(sums)
        out += ',"longest_call_ms":' + _dist_ms(longest)
        out += ',"calls":' + _dist_count(calls)
        out += ',"lanes":' + _dist_count(lanes)
        if p == PH_JOIN_TAIL:
            # Recorded for every task by the driver, so `critical_ms` is the
            # sum of the idle gaps of all tasks and has no share; the
            # longest gap is the one to read.
            out += ',"share_of_total_pct":null}'
        else:
            out += ',"share_of_total_pct":' + _num(share) + "}"
    out += "}}"
    return out^


# --- footer cost ----------------------------------------------------------------


def _footer_json(path: String, repeats: Int) raises -> String:
    """The time to read and parse the file's footer, on its own, through the
    two caches a query uses (the binder's `FooterCache` and the scan's
    `ParquetMetadataCache`), each on a fresh cache, in a quiet process: the
    serial cost one footer read adds to a query."""
    var binder = List[Int]()
    var scan = List[Int]()
    for _ in range(repeats + 1):
        var fc = FooterCache()
        var t0 = perf_counter_ns()
        _ = fc.footer(path)
        var t1 = perf_counter_ns()
        var mc = ParquetMetadataCache()
        _ = mc.get_or_parse(path)
        var t2 = perf_counter_ns()
        binder.append(Int(t1 - t0))
        scan.append(Int(t2 - t1))
    _ = binder.pop(0)
    _ = scan.pop(0)
    return (
        String('{"binder_footer_cache_ms":') + _dist_ms(binder)
        + ',"scan_metadata_cache_ms":' + _dist_ms(scan)
        + ',"repeats":' + String(repeats)
        + String("}")
    )


# --- the probe ---------------------------------------------------------------------


struct ProbeSettings(Copyable, Movable):
    var lineitem_path: String
    var out_dir: String
    var threads: List[Int]
    var runs: Int
    var memory_budget_bytes: Int
    var expected_revenue: Int
    """The DECIMAL(38,4) answer as an integer every run must give, or
    `NO_EXPECTED_REVENUE`."""

    def __init__(
        out self,
        var lineitem_path: String,
        var out_dir: String,
        var threads: List[Int],
        runs: Int,
        memory_budget_bytes: Int,
        expected_revenue: Int = NO_EXPECTED_REVENUE,
    ):
        self.lineitem_path = lineitem_path^
        self.out_dir = out_dir^
        self.threads = threads^
        self.runs = runs
        self.memory_budget_bytes = memory_budget_bytes
        self.expected_revenue = expected_revenue


def _answer_ok(rec: RunRecord, settings: ProbeSettings) -> Bool:
    return (
        settings.expected_revenue == NO_EXPECTED_REVENUE
        or rec.revenue_unscaled == settings.expected_revenue
    )


struct ProbeResult(Movable):
    var json: String
    var answers_match: Bool
    """Every run, warm-up included, gave `expected_revenue` (True when none
    was expected)."""

    def __init__(out self, var json: String, answers_match: Bool):
        self.json = json^
        self.answers_match = answers_match


def run_probe(settings: ProbeSettings) raises -> ProbeResult:
    """Run the probe, write `phases.json` and `plan.txt` into the settings'
    output directory, and return the JSON text and whether every answer was
    the expected one.

    Raises:
        If a run is refused or a file cannot be written.
    """
    if settings.runs < 5:
        raise Error("the probe needs at least 5 timed runs, got " + String(settings.runs))
    var text = find_query(String("tpch/q6")).text
    var configs = String("")
    var host = String("null")
    var plan_text = String("")
    if pt_enabled():
        # The driver and the workers each need a lane.
        for t in range(len(settings.threads)):
            if settings.threads[t] + 1 > PT_LANES:
                raise Error(
                    "the phase timers have "
                    + String(PT_LANES)
                    + " lanes (the driver and the workers); "
                    + String(settings.threads[t])
                    + " threads do not fit"
                )
    var answers_match = True
    var records_dropped = 0
    for t in range(len(settings.threads)):
        var requested = settings.threads[t]
        var ctx = EngineContext(
            EngineOptions(
                worker_count=requested,
                memory_budget_bytes=settings.memory_budget_bytes,
            )
        )
        register_parquet(ctx, "lineitem", settings.lineitem_path)
        if t == 0:
            host = _host_json(ctx)
            plan_text = render_plans(ctx, text)
        var warm = _run_once(ctx, text)
        if not _answer_ok(warm, settings):
            answers_match = False
        var runs = List[RunRecord]()
        for _ in range(settings.runs):
            var rec = _run_once(ctx, text)
            if not _answer_ok(rec, settings):
                answers_match = False
            runs.append(rec^)
        for r in range(len(runs)):
            records_dropped += runs[r].dropped_records
        if t > 0:
            configs += ","
        configs += _json_config(requested, ctx.host_profile.thread_count, runs)
    var json = String('{"schema":"') + SCHEMA + '"'
    json += ',"note":"' + NOTE + '"'
    json += ',"query":"tpch/q6"'
    json += ',"timers_compiled_in":' + String("true" if pt_enabled() else "false")
    json += ',"timer_lane_capacity":' + String(PT_LANES)
    json += ',"timer_records_dropped":' + String(records_dropped)
    json += ',"warmup_runs_discarded":1'
    json += ',"runs_per_thread_count":' + String(settings.runs)
    json += ',"expected_revenue_unscaled":' + String(settings.expected_revenue)
    json += ',"answers_match_expected":' + String("true" if answers_match else "false")
    json += ',"host":' + host
    json += ',"footer_cost":' + _footer_json(settings.lineitem_path, settings.runs)
    json += ',"configs":[' + configs + "]}\n"
    makedirs(settings.out_dir, exist_ok=True)
    var jf = open(settings.out_dir + "/phases.json", "w")
    jf.write(json)
    jf.close()
    var pf = open(settings.out_dir + "/plan.txt", "w")
    pf.write(plan_text)
    pf.close()
    return ProbeResult(json^, answers_match)
