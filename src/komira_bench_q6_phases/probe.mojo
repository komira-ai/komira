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
# Two modes run per thread count. `q6` is the query; `decode_only` is the same
# scan with no predicate: the four columns Q6 reads (`l_shipdate`,
# `l_discount`, `l_quantity`, `l_extendedprice`) are decoded and folded into
# four aggregates, so its `decode_plain` and `claim_next_morsel` phases are
# the decode scaling on its own, with no filter evaluation.
#
# Before the timed runs of a mode the probe discards warm-up runs: at least 2
# (5 at 32 or more threads) and then until two successive runs' minor-fault
# counts agree within 20 percent (at most 30). The discarded runs' faults,
# switches and times are in the JSON (`warmup`).
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
#   * for the phases that bracket their thread's resource usage (`thread_usage`:
#     task, claim, the decodes and the filter), the voluntary and involuntary
#     context switches, user and system CPU time and the minor and major page
#     faults of the worker threads inside the phase, as the sum over workers
#     and the largest of one worker (`getrusage(RUSAGE_THREAD)` deltas);
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
    FIELD_CALLS,
    PH_CLAIM,
    PH_COUNT,
    PH_DECODE_FILTER_COLS,
    PH_DECODE_PAYLOAD,
    PH_DECODE_PLAIN,
    PH_END_STAMP,
    PH_FILTER,
    PH_JOIN_TAIL,
    PH_PARSE,
    PH_STAGED_DECODE_LATER,
    PH_TASK,
    pt_enabled,
    pt_get,
    pt_lane_count,
    pt_lane_tid,
    pt_phase_name,
    pt_reset,
    pt_ru_available,
)
from komira_scalar_arithmetic.decimal_arith import I128
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import run_sql

from .phase_snapshot import PhaseAgg, snapshot_all
from .plan_render import render_plans
from .thread_census import (
    CensusDelta,
    GROUP_COUNT,
    GROUP_DRIVER,
    GROUP_OTHER,
    GROUP_WORKER,
    census_delta,
    thread_census,
)
from .stats import faults_settled, maximum, median, minimum, quantile

comptime SCHEMA: String = "komira-q6-phase-probe/2"
comptime TPCH_SF1_Q6_REVENUE_UNSCALED: Int = 1231410782283
"""Q6 of TPC-H at scale factor 1 with the validation parameters, as the
DECIMAL(38,4) integer: 123141078.2283."""
comptime NO_EXPECTED_REVENUE: Int = -1
"""`ProbeSettings.expected_revenue` when the data is not TPC-H sf1."""

comptime DECODE_ONLY_TEXT: String = (
    "SELECT sum(l_extendedprice) AS s_price, sum(l_discount) AS s_discount,"
    " sum(l_quantity) AS s_quantity, min(l_shipdate) AS min_shipdate"
    " FROM lineitem"
)
"""The four columns Q6 reads, with no predicate. The first aggregate is the
answer the probe compares between runs."""

comptime MODE_Q6: String = "q6"
comptime MODE_DECODE_ONLY: String = "decode_only"
comptime WARMUP_MIN_RUNS: Int = 2
comptime WARMUP_MIN_RUNS_WIDE: Int = 5
"""Warm-up runs discarded at least, at `WIDE_THREADS` or more threads."""
comptime WIDE_THREADS: Int = 32
comptime WARMUP_MAX_RUNS: Int = 30

comptime NOTE: String = (
    "The machine this ran on is not a quiet host: other jobs share it, so"
    " absolute times vary from run to run. Read the numbers as RELATIVE (the"
    " share of each phase in the total, and how the time scales with the"
    " thread count), not as a headline figure and not as a comparison with"
    " another engine."
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
    var ok: Bool
    var census: CensusDelta
    var census_taken: Bool
    """The process's threads could be listed (Linux with `/proc`)."""

    def __init__(out self):
        self.census = CensusDelta()
        self.census_taken = False
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
        self.ok = False


def _run_once(mut ctx: EngineContext, text: String) raises -> RunRecord:
    var rec = RunRecord()
    pt_reset()
    var census_before = thread_census()
    var c0 = Counters.now()
    var t0 = perf_counter_ns()
    var outcome = run_sql(ctx, text)
    var t1 = perf_counter_ns()
    var c1 = Counters.now()
    var census_after = thread_census()
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
    var driver_tids = List[Int]()
    var worker_tids = List[Int]()
    for lane in range(pt_lane_count()):
        if pt_get(lane, PH_PARSE, FIELD_CALLS) > 0:
            driver_tids.append(pt_lane_tid(lane))
        elif pt_get(lane, PH_TASK, FIELD_CALLS) > 0:
            worker_tids.append(pt_lane_tid(lane))
    rec.census_taken = len(census_before) > 0 and len(census_after) > 0
    rec.census = census_delta(census_before, census_after, driver_tids, worker_tids)
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


def _has_usage(p: Int) -> Bool:
    """Phases that bracket their thread's resource usage."""
    return (
        p == PH_TASK
        or p == PH_CLAIM
        or p == PH_DECODE_FILTER_COLS
        or p == PH_STAGED_DECODE_LATER
        or p == PH_FILTER
        or p == PH_DECODE_PAYLOAD
        or p == PH_DECODE_PLAIN
    )


def _usage_pair(ref runs: List[RunRecord], p: Int, k: Int, as_ms: Bool) -> String:
    """`{"sum":..,"max":..}` of resource field `k` of phase `p`: over the
    workers of a run (sum) and the largest worker (max), each over the runs."""
    var sums = List[Int]()
    var maxes = List[Int]()
    for r in range(len(runs)):
        sums.append(runs[r].phases[p].ru_sum[k])
        maxes.append(runs[r].phases[p].ru_max[k])
    if as_ms:
        return String('{"sum":') + _dist_ms(sums) + ',"max":' + _dist_ms(maxes) + "}"
    return String('{"sum":') + _dist_count(sums) + ',"max":' + _dist_count(maxes) + "}"


def _usage_json(ref runs: List[RunRecord], p: Int) -> String:
    var out = String('{"voluntary_csw":') + _usage_pair(runs, p, 0, False)
    out += ',"involuntary_csw":' + _usage_pair(runs, p, 1, False)
    out += ',"user_ms":' + _usage_pair(runs, p, 2, True)
    out += ',"system_ms":' + _usage_pair(runs, p, 3, True)
    out += ',"minor_faults":' + _usage_pair(runs, p, 4, False)
    out += ',"major_faults":' + _usage_pair(runs, p, 5, False)
    out += "}"
    return out^


def _group_name(g: Int) -> String:
    if g == GROUP_DRIVER:
        return "driver"
    if g == GROUP_WORKER:
        return "task_workers"
    return "other"


def _group_json(ref runs: List[RunRecord], g: Int) -> String:
    var threads = List[Int]()
    var active = List[Int]()
    var vol_sum = List[Int]()
    var vol_max = List[Int]()
    var invol = List[Int]()
    var run_ns = List[Int]()
    var wait_ns = List[Int]()
    var wait_max = List[Int]()
    for r in range(len(runs)):
        ref a = runs[r].census.groups[g]
        threads.append(a.threads)
        active.append(a.active_threads)
        vol_sum.append(a.vol_sum)
        vol_max.append(a.vol_max)
        invol.append(a.invol_sum)
        run_ns.append(a.run_ns)
        wait_ns.append(a.wait_ns)
        wait_max.append(a.wait_ns_max)
    return (
        String('"') + _group_name(g) + '":{"threads":' + _dist_count(threads)
        + ',"threads_with_voluntary_switches":' + _dist_count(active)
        + ',"voluntary_csw_sum":' + _dist_count(vol_sum)
        + ',"voluntary_csw_max":' + _dist_count(vol_max)
        + ',"involuntary_csw_sum":' + _dist_count(invol)
        + ',"on_cpu_ms_sum":' + _dist_ms(run_ns)
        + ',"runnable_wait_ms_sum":' + _dist_ms(wait_ns)
        + ',"runnable_wait_ms_max":' + _dist_ms(wait_max)
        + String("}")
    )


def _census_json(ref runs: List[RunRecord]) -> String:
    """The whole process's threads, grouped by what they did in each run
    (see thread_census.mojo): where the run's switches and CPU time are."""
    var taken = len(runs) > 0 and runs[0].census_taken
    if not taken:
        return String('{"available":false}')
    var out = String('{"available":true')
    for g in range(GROUP_COUNT):
        out += "," + _group_json(runs, g)
    # The `other` threads by name: the mean per run, over the runs in which
    # the name appeared.
    var names = List[String]()
    var seen = List[Int]()
    var vol = List[Int]()
    var cpu = List[Int]()
    var nthreads = List[Int]()
    for r in range(len(runs)):
        ref c = runs[r].census
        for n in range(len(c.other_names)):
            var k = -1
            for j in range(len(names)):
                if names[j] == c.other_names[n]:
                    k = j
                    break
            if k < 0:
                names.append(c.other_names[n].copy())
                seen.append(0)
                vol.append(0)
                cpu.append(0)
                nthreads.append(0)
                k = len(names) - 1
            seen[k] += 1
            vol[k] += c.other_name_vol[n]
            cpu[k] += c.other_name_run_ns[n]
            nthreads[k] += c.other_name_threads[n]
    out += ',"other_by_name":['
    for k in range(len(names)):
        if k > 0:
            out += ","
        var s = max(seen[k], 1)
        out += '{"name":"' + names[k] + '","runs_seen":' + String(seen[k])
        out += ',"threads_per_run":' + String(nthreads[k] // s)
        out += ',"voluntary_csw_per_run":' + String(vol[k] // s)
        out += ',"on_cpu_ms_per_run":' + ms_text(Float64(cpu[k] // s)) + "}"
    out += "]}"
    return out^


struct WarmupRecord(Copyable, Movable):
    """The discarded runs of one mode at one thread count."""

    var minor_faults: List[Int]
    var vol_switches: List[Int]
    var total_ns: List[Int]
    var revenue_unscaled: List[Int]
    """The first aggregate each discarded run answered."""
    var settled: Bool

    def __init__(out self):
        self.revenue_unscaled = List[Int]()
        self.minor_faults = List[Int]()
        self.vol_switches = List[Int]()
        self.total_ns = List[Int]()
        self.settled = False


def _warmup_json(ref w: WarmupRecord) -> String:
    return (
        String('{"discarded":') + String(len(w.minor_faults))
        + ',"settled":' + String("true" if w.settled else "false")
        + ',"minor_faults":' + _series_int(w.minor_faults)
        + ',"voluntary_csw":' + _series_int(w.vol_switches)
        + ',"total_ms":' + _series_ms(w.total_ns)
        + String("}")
    )


def _json_config(
    mode: String,
    threads_requested: Int,
    threads_effective: Int,
    ref runs: List[RunRecord],
    ref warm: WarmupRecord,
) -> String:
    var totals = List[Int]()
    var minor = List[Int]()
    var major = List[Int]()
    var vol = List[Int]()
    var invol = List[Int]()
    var rss = List[Int]()
    var user = List[Int]()
    var system = List[Int]()
    for r in range(len(runs)):
        totals.append(runs[r].total_ns)
        minor.append(runs[r].minor_faults)
        major.append(runs[r].major_faults)
        vol.append(runs[r].vol_switches)
        invol.append(runs[r].invol_switches)
        rss.append(runs[r].peak_rss_bytes // 1048576)
        user.append(runs[r].user_ns)
        system.append(runs[r].system_ns)
    var total_median = median(totals)
    var out = String('{"mode":"') + mode + '"'
    out += ',"threads_requested":' + String(threads_requested)
    out += ',"threads_effective":' + String(threads_effective)
    out += ',"warmup":' + _warmup_json(warm)
    out += ',"thread_census":' + _census_json(runs)
    out += ',"runs":' + String(len(runs))
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
        if _has_usage(p) and pt_ru_available():
            out += ',"thread_usage":' + _usage_json(runs, p)
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
    var run_q6: Bool
    var run_decode_only: Bool
    var expected_decode_sum: Int
    """The unscaled `sum(l_extendedprice)` every decode-only run must give,
    or `NO_EXPECTED_REVENUE` (the runs then only have to agree with each
    other)."""

    def __init__(
        out self,
        var lineitem_path: String,
        var out_dir: String,
        var threads: List[Int],
        runs: Int,
        memory_budget_bytes: Int,
        expected_revenue: Int = NO_EXPECTED_REVENUE,
        run_q6: Bool = True,
        run_decode_only: Bool = True,
        expected_decode_sum: Int = NO_EXPECTED_REVENUE,
    ):
        self.lineitem_path = lineitem_path^
        self.out_dir = out_dir^
        self.threads = threads^
        self.runs = runs
        self.memory_budget_bytes = memory_budget_bytes
        self.expected_revenue = expected_revenue
        self.run_q6 = run_q6
        self.run_decode_only = run_decode_only
        self.expected_decode_sum = expected_decode_sum


def _answer_ok(rec: RunRecord, settings: ProbeSettings) -> Bool:
    return (
        settings.expected_revenue == NO_EXPECTED_REVENUE
        or rec.revenue_unscaled == settings.expected_revenue
    )


def _decode_answer_ok(
    rec: RunRecord, settings: ProbeSettings, mut reference: Int
) -> Bool:
    """A decode-only answer is right if it is the expected sum or, with none
    expected, the same as the first one seen."""
    if settings.expected_decode_sum != NO_EXPECTED_REVENUE:
        return rec.revenue_unscaled == settings.expected_decode_sum
    if reference == NO_EXPECTED_REVENUE:
        reference = rec.revenue_unscaled
    return rec.revenue_unscaled == reference


def _warm_up(
    mut ctx: EngineContext, text: String, threads: Int
) raises -> WarmupRecord:
    """Discard runs until the page-fault count settles (see the header); keep
    their counters."""
    var w = WarmupRecord()
    var min_runs = WARMUP_MIN_RUNS
    if threads >= WIDE_THREADS:
        min_runs = WARMUP_MIN_RUNS_WIDE
    while len(w.minor_faults) < WARMUP_MAX_RUNS:
        var rec = _run_once(ctx, text)
        w.minor_faults.append(rec.minor_faults)
        w.vol_switches.append(rec.vol_switches)
        w.total_ns.append(rec.total_ns)
        w.revenue_unscaled.append(rec.revenue_unscaled)
        if len(w.minor_faults) >= min_runs and faults_settled(w.minor_faults):
            w.settled = True
            break
    return w^


struct ProbeResult(Movable):
    var json: String
    var answers_match: Bool
    """Every run, warm-up included, gave the expected answer (True when none
    was expected; a decode-only run with none expected must agree with the
    others)."""

    def __init__(out self, var json: String, answers_match: Bool):
        self.json = json^
        self.answers_match = answers_match


def run_probe(settings: ProbeSettings) raises -> ProbeResult:
    """Run the probe, write `phases.json` and `plan.txt` into the settings'
    output directory, and return the JSON text and whether every answer was
    the expected one.

    Raises:
        If a run is refused or a file cannot be written, or no mode is selected.
    """
    if settings.runs < 5:
        raise Error("the probe needs at least 5 timed runs, got " + String(settings.runs))
    if not settings.run_q6 and not settings.run_decode_only:
        raise Error("the probe has no mode to run")
    var text = find_query(String("tpch/q6")).text
    var decode_text = String(DECODE_ONLY_TEXT)
    var configs = String("")
    var host = String("null")
    var plan_text = String("")
    var answers_match = True
    var decode_reference = NO_EXPECTED_REVENUE
    var first_config = True
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
        for m in range(2):
            var is_q6 = m == 0
            if is_q6 and not settings.run_q6:
                continue
            if not is_q6 and not settings.run_decode_only:
                continue
            var query = text.copy() if is_q6 else decode_text.copy()
            var warm = _warm_up(ctx, query, requested)
            for w in range(len(warm.revenue_unscaled)):
                var wrec = RunRecord()
                wrec.revenue_unscaled = warm.revenue_unscaled[w]
                if is_q6:
                    if not _answer_ok(wrec, settings):
                        answers_match = False
                elif not _decode_answer_ok(wrec, settings, decode_reference):
                    answers_match = False
            var runs = List[RunRecord]()
            for _ in range(settings.runs):
                var rec = _run_once(ctx, query)
                if is_q6:
                    if not _answer_ok(rec, settings):
                        answers_match = False
                elif not _decode_answer_ok(rec, settings, decode_reference):
                    answers_match = False
                runs.append(rec^)
            if not first_config:
                configs += ","
            first_config = False
            configs += _json_config(
                String(MODE_Q6) if is_q6 else String(MODE_DECODE_ONLY),
                requested,
                ctx.host_profile.thread_count,
                runs,
                warm,
            )
    var json = String('{"schema":"') + SCHEMA + '"'
    json += ',"note":"' + NOTE + '"'
    json += ',"query":"tpch/q6"'
    json += ',"decode_only_query":"' + DECODE_ONLY_TEXT + '"'
    json += ',"timers_compiled_in":' + String("true" if pt_enabled() else "false")
    json += ',"thread_usage_available":' + String("true" if pt_ru_available() else "false")
    json += ',"warmup_policy":"discard at least ' + String(WARMUP_MIN_RUNS) + " runs ("
    json += String(WARMUP_MIN_RUNS_WIDE) + " at " + String(WIDE_THREADS)
    json += " or more threads), then until two successive runs' minor faults agree within 20 percent, at most "
    json += String(WARMUP_MAX_RUNS) + '"'
    json += ',"runs_per_thread_count":' + String(settings.runs)
    json += ',"expected_revenue_unscaled":' + String(settings.expected_revenue)
    json += ',"decode_only_sum_price_unscaled":' + String(decode_reference)
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
