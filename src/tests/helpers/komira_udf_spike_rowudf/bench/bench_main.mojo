# The row runtime's numbers, measured inside the engine loop
# (native/row_engine.c, through engine.mojo): one JSON object on stdout.
#
# usage: bench_main <runtime library> <run id>
#
# price_qty (`row.price * row.qty`) over inputs of 4, 16 and 64 float64
# columns, of which it reads 2, two ways: the producer's read set
# (read_sets.tsv: {price, qty}, the only columns that cross) and every
# column declared (all of them cross; the function still reads 2). Each at
# 1, 4 and 16 engine threads (each thread its own context and instance,
# opened on that thread), 8192-row batches; and at 1 thread over 1-row
# batches, where the per-call cost of the argument struct shows. The
# one-thread runs alternate the two read sets three times (`round`), so a
# slow phase of a shared worker lands on both; scaling efficiency is against
# the best one-thread round of the same read set.
#
# Each row of the report: rows/s over the measured phase (from the barrier
# all threads pass once warm to the one each passes after its last batch),
# rows/s per thread, scaling efficiency rows/s(N) / (N x rows/s(1)), argument
# bytes exported per row and per call, call_batch latency (min, median,
# p90, max over every thread's measured calls, timed around the table entry
# alone), process CPU over wall time, CPU ns per row, and the `noisy` flag (CPU < 0.8 x wall
# x min(N, CPUs)), involuntary context switches, the cgroup's throttling
# over the phase, the load average before it, warm-up calls, and memory
# per context as the process RSS delta over opening N contexts with their
# instances and one batch each, divided by N (labelled so: threads in one
# process, not PSS). Cold start is engine open (before dlopen) to the end
# of the first batch, on the first run of the process.

from std.sys import argv

from komira_udf_spike_rowudf.engine import RowEngine, RowReport, RowWorkload, quantile
from komira_udf_spike_rowudf.read_sets import load_read_sets, read_set_of

comptime ROWS = 8192
comptime BATCHES = 30
comptime WARM_WINDOW = 5
comptime WARM_CAP = 40
comptime OVERHEAD_BATCHES = 20000
comptime OVERHEAD_WINDOW = 200
comptime ROUNDS = 3
comptime BUILD = "bench program mojo -O3 (mojo_binary default); engine loop and runtime C -O2; CPython 3.13 sub-interpreters"


def _q(s: String) -> String:
    """`s` as a JSON string: quotes and backslashes escaped, control bytes as
    spaces."""
    var out = List[UInt8]()
    out.append(0x22)
    for b in s.as_bytes():
        if b == 0x22 or b == 0x5C:
            out.append(0x5C)
            out.append(b)
        elif b < 0x20:
            out.append(0x20)
        else:
            out.append(b)
    out.append(0x22)
    return String(from_utf8_lossy=Span(out))


def _median(xs: List[Int64]) -> Int64:
    return quantile(xs.copy(), 0.5)


def _row(width: Int, mode: String, rows_per_batch: Int, rnd: Int, r: RowReport, base: Float64) -> String:
    var n = len(r.threads)
    var ok = r.status == 0
    var s = String("{")
    s += '"width": ' + String(width) + ', "read_set": ' + _q(mode) + ', "fields_crossing": ' + String(r.read_fields)
    s += ', "rows_per_batch": ' + String(rows_per_batch) + ', "threads": ' + String(n) + ', "round": ' + String(rnd)
    s += ', "status": ' + _q("OK" if ok else "FAIL")
    if not ok:
        return s + ', "error": ' + _q(r.message) + "}"
    var rps = r.rows_per_s()
    var all = r.all_samples()
    var cpu = Float64(r.cpu_user_ns + r.cpu_sys_ns)
    var lanes = min(n, Int(r.cpus))
    var ctx = List[Int64]()
    var inst = List[Int64]()
    var first = List[Int64]()
    var warm = List[Int64]()
    var stable = 0
    for t in r.threads:
        ctx.append(t.open_context_ns)
        inst.append(t.open_instance_ns)
        first.append(t.first_call_ns)
        warm.append(t.warmup_calls)
        if t.warm_stable:
            stable += 1
    s += ', "rows_per_s": ' + String(Int(rps)) + ', "rows_per_s_per_thread": ' + String(Int(rps / Float64(n)))
    if base > 0:
        s += ', "efficiency": ' + String(rps / (Float64(n) * base))
    s += ', "bytes_per_row": ' + String(r.bytes_per_row())
    s += ', "bytes_per_call": ' + String(Int(r.bytes_per_row() * Float64(rows_per_batch)))
    s += ', "call_ns": {"min": ' + String(quantile(all.copy(), 0.0)) + ', "median": ' + String(_median(all))
    s += ', "p90": ' + String(quantile(all.copy(), 0.9)) + ', "max": ' + String(quantile(all.copy(), 1.0))
    s += ', "samples": ' + String(len(all)) + "}"
    s += ', "wall_ns": ' + String(r.wall_ns) + ', "cpu_over_wall": ' + String(cpu / Float64(r.wall_ns))
    s += ', "cpu_ns_per_row": ' + String(cpu / Float64(r.measured_rows()))
    s += ', "noisy": ' + ("true" if cpu < 0.8 * Float64(r.wall_ns) * Float64(lanes) else "false")
    if n > Int(r.cpus):
        s += ', "not_measured": ' + _q(String(n) + " threads on " + String(r.cpus) + " cpus")
    s += ', "involuntary_switches": ' + String(r.involuntary_switches)
    s += ', "cgroup_nr_throttled": ' + String(r.nr_throttled) + ', "cgroup_throttled_usec": ' + String(r.throttled_usec)
    s += ', "loadavg_1m": ' + String(Float64(r.loadavg_milli) / 1000.0)
    s += ', "warmup_calls_median": ' + String(_median(warm)) + ', "warm_stable_threads": ' + String(stable)
    s += ', "rss_delta_per_context_bytes": ' + String((r.rss_open - r.rss_before) // Int64(n))
    s += ', "open_context_ns_median": ' + String(_median(ctx)) + ', "open_instance_ns_median": ' + String(_median(inst))
    s += ', "first_call_ns_median": ' + String(_median(first))
    return s + "}"


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("usage: bench_main <runtime library> <run id>")
    var sets = load_read_sets()
    var e = RowEngine(String(args[1]))
    if e.status() != 0:
        raise Error("engine open: " + e.message())
    var rows = List[String]()
    var cold: Int64 = -1
    var cpus: Int64 = 0
    var threads: List[Int] = [1, 4, 16]
    var widths: List[Int] = [4, 16, 64]
    var labels: List[String] = ["declared", "every_column"]
    for wi in range(len(widths)):
        var p = read_set_of(sets, "price_qty@" + String(widths[wi]))
        var reads: List[List[String]] = [p.read_set.copy(), p.input.copy()]
        # One thread, both read sets in turn, ROUNDS times, so that a slow
        # phase of a shared worker lands on both.
        var base: List[Float64] = [0.0, 0.0]
        for rnd in range(ROUNDS):
            for mode in range(2):
                var r = e.run(
                    RowWorkload(p.entry, p.input.copy(), reads[mode].copy(), "price", "qty", 1, ROWS, BATCHES, WARM_WINDOW, WARM_CAP)
                )
                if r.cold_ns >= 0:
                    cold = r.cold_ns
                cpus = r.cpus
                if r.status == 0 and r.rows_per_s() > base[mode]:
                    base[mode] = r.rows_per_s()
                rows.append(_row(widths[wi], labels[mode], ROWS, rnd, r, 0))
                # The per-call cost: 1-row batches.
                var o = e.run(
                    RowWorkload(p.entry, p.input.copy(), reads[mode].copy(), "price", "qty", 1, 1, OVERHEAD_BATCHES, OVERHEAD_WINDOW, WARM_CAP)
                )
                rows.append(_row(widths[wi], labels[mode], 1, rnd, o, 0))
        # Scaling, against the best one-thread round of the same read set.
        for ti in range(1, len(threads)):
            for mode in range(2):
                var r = e.run(
                    RowWorkload(p.entry, p.input.copy(), reads[mode].copy(), "price", "qty", threads[ti], ROWS, BATCHES, WARM_WINDOW, WARM_CAP)
                )
                rows.append(_row(widths[wi], labels[mode], ROWS, 0, r, base[mode]))
    var out = String("{")
    out += '"run_id": ' + _q(String(args[2])) + ', "runtime_id": ' + _q(e.runtime_id())
    out += ', "cpus": ' + String(cpus) + ', "cpu_model": ' + _q(e.cpu_model())
    out += ', "cgroup_cpu_max": ' + _q(e.cgroup_cpu_max()) + ', "open_ns": ' + String(e.open_ns())
    out += ', "cold_start_ns": ' + String(cold) + ', "build": ' + _q(BUILD) + ', "rows": ['
    for i in range(len(rows)):
        out += ("" if i == 0 else ", ") + rows[i]
    print(out + "]}")
