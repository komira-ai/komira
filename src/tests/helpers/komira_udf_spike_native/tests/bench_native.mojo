# Measurements of native UDF libraries in-process (not a welded test: the
# :native_bench target). It prints one JSON object: the run id it was given
# (./run_id), the facts of the machine it ran on, and per runtime:
#   - cold start: dlopen of the runtime library, init and describe (open);
#     load (for the native runtime: reading the library, its sha256, the copy
#     into a memory file, dlopen, the library's init, describe and load);
#     open_context and open_instance; and the first call_batch;
#   - per-batch cost: call_batch of `identity` on 0 and 1 rows, timed around
#     the call alone, after a warmup: min, median, p90 and max over the
#     samples, in ns;
#   - rows/s: `double` (int64) and `fahrenheit` (float64) at 1024, 8192 and
#     65536 rows, from the median;
#   - threads: `double` at 8192 rows on 1, 4 and 16 threads (each its own
#     context and instance), where the machine has that many CPUs: rows/s
#     over the wall time of the whole loop (the export, the call, reading
#     every output back, the release) and over the calls alone (the slowest
#     thread's summed call time), per thread, efficiency (rows/s at N over N
#     times rows/s at 1, from the calls alone), the process's CPU time over
#     the wall time, and `noisy` when that is below 0.8 of N;
#   - for each native library: its size, its sha256 time (komira_crypto),
#     and one dlopen of its staged copy by path (RTLD_NOW | RTLD_LOCAL),
#     apart from the native runtime's load, which does both and more.
# The runtimes: the reference runtime echo.so called directly (the floor: the
# same C fixtures with no loader), and the native runtime with the C library
# and with the Mojo library. echo and the C library run the same C code, so
# their difference is the native runtime's forwarding.
#
# Every timed call is checked: a failed call, an output other than the
# fixture's, or an input array not released fails the run, so no number
# comes from a broken call. No time is asserted. The timed loop is C
# (komira_udf_spike_abi native/bench_loop.c); this file, compiled at -O1,
# only sets up and reports.

from std.ffi import OwnedDLHandle, RTLD
from std.memory import alloc
from std.os import getenv
from std.time import perf_counter_ns

from komira_udf_spike_abi.contract import SHAPE_MAP_BATCHES_COLUMN, SHAPE_SCALAR
from komira_udf_spike_abi.runtime import CallTimes, CodeSet, Handle, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import ColumnType, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_native.code import code_set, digest_of, hex_of

comptime WINDOW = 50
comptime MAX_WINDOWS = 40
comptime SAMPLES = 400


def _text(path: String) -> String:
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return ""


def _first_line_with(text: String, key: String) -> String:
    """The value after the first `:` of the first line starting with `key`."""
    for line in text.split("\n"):
        var l = String(line)
        if l.startswith(key):
            var at = l.find(":")
            return String(l[byte = at + 1 : l.byte_length()].strip()) if at >= 0 else ""
    return ""


def _json_str(s: String) -> String:
    var out = String('"')
    for b in s.as_bytes():
        if b == 0x22 or b == 0x5C:
            out += "\\" + chr(Int(b))
        elif b < 0x20:
            out += " "
        else:
            out += chr(Int(b))
    return out + '"'


def _cpus() -> Int:
    """CPUs this process may run on, from Cpus_allowed_list (`0-3,8`)."""
    var list = _first_line_with(_text("/proc/self/status"), "Cpus_allowed_list")
    var n = 0
    for part in list.split(","):
        var p = String(part.strip())
        if p == "":
            continue
        var ends = p.split("-")
        try:
            if len(ends) == 2:
                n += Int(String(ends[1])) - Int(String(ends[0])) + 1
            else:
                n += 1
        except:
            pass
    return n


def _sorted(v: List[Int64]) -> List[Int64]:
    var s = v.copy()
    sort(s)
    return s^


def _median(v: List[Int64]) -> Int64:
    return _sorted(v)[len(v) // 2]


def _check(t: CallTimes, what: String) raises:
    if t.failures != 0 or t.mismatches != 0 or t.released != len(t.samples_ns):
        raise Error(
            "BENCH_BROKEN_CALL: " + what + ": " + String(t.failures) + " failed, " + String(t.mismatches)
            + " wrong, " + String(t.released) + " of " + String(len(t.samples_ns)) + " released"
        )


def _measure(mut rt: UdfRuntime, inst: Handle, rows: Int, is_float: Bool, a: Float64, b: Float64, what: String) raises -> String:
    """Warm up until three window medians in a row agree within 2% (at most
    MAX_WINDOWS windows), then SAMPLES calls: the JSON stats."""
    var medians = List[Int64]()
    var warm = 0
    for _ in range(MAX_WINDOWS):
        var w = rt.time_call_batch(inst, rows, is_float, a, b, WINDOW)
        _check(w, what)
        medians.append(_median(w.samples_ns))
        warm += WINDOW
        var k = len(medians)
        if k >= 3:
            var lo = min(medians[k - 1], min(medians[k - 2], medians[k - 3]))
            var hi = max(medians[k - 1], max(medians[k - 2], medians[k - 3]))
            if Float64(hi - lo) <= 0.02 * Float64(lo):
                break
    var t = rt.time_call_batch(inst, rows, is_float, a, b, SAMPLES)
    _check(t, what)
    var s = _sorted(t.samples_ns)
    var med = s[len(s) // 2]
    var rate = Float64(rows) * 1e9 / Float64(med) if med > 0 else 0.0
    return (
        '{"rows": ' + String(rows) + ', "warmup_calls": ' + String(warm) + ', "samples": ' + String(len(s))
        + ', "min_ns": ' + String(s[0]) + ', "median_ns": ' + String(med) + ', "p90_ns": '
        + String(s[len(s) * 9 // 10]) + ', "max_ns": ' + String(s[len(s) - 1]) + ', "rows_per_s": '
        + String(Int(rate)) + "}"
    )


def _spec(entry: String, shape: UInt32, type_id: Int, code: CodeSet) -> UdfSpec:
    var s = UdfSpec(shape, entry, [ColumnType(type_id, True)], [ColumnType(type_id, True)])
    s.code_root = code.root
    s.code = code.objects.copy()
    return s^


def _instance(mut rt: UdfRuntime, spec: UdfSpec, slot: Int) raises -> Handle:
    var u = rt.load(spec)
    if not u.outcome.is_ok():
        raise Error("BENCH_LOAD: " + String(u.outcome))
    var ctx = rt.open_context(UInt32(slot))
    var inst = rt.open_instance(ctx.handle, u.handle)
    if not inst.outcome.is_ok():
        raise Error("BENCH_OPEN_INSTANCE: " + String(inst.outcome))
    return inst.handle.copy()


def _runtime(path: String, code: CodeSet, name: String, cpus: Int) raises -> String:
    """Everything above, for one runtime library and code set."""
    var t0 = perf_counter_ns()
    var rt = UdfRuntime.open(path)
    var t1 = perf_counter_ns()
    var ident = _spec("identity", SHAPE_MAP_BATCHES_COLUMN, TYPE_INT64, code)
    var u = rt.load(ident)
    var t2 = perf_counter_ns()
    if not u.outcome.is_ok():
        raise Error("BENCH_LOAD: " + String(u.outcome))
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, u.handle)
    var t3 = perf_counter_ns()
    var first = rt.time_call_batch(inst.handle, 1, False, 1.0, 0.0, 1)
    var t4 = perf_counter_ns()
    _check(first, name + " first call")
    var out = '{"runtime": ' + _json_str(name) + ', "library": ' + _json_str(path)
    out += ', "cold_ns": {"open": ' + String(t1 - t0) + ', "load": ' + String(t2 - t1)
    out += ', "context_and_instance": ' + String(t3 - t2) + ', "first_call": ' + String(t4 - t3)
    out += ', "first_call_alone": ' + String(first.samples_ns[0]) + ', "total": ' + String(t4 - t0) + "}"
    out += ', "per_batch": [' + _measure(rt, inst.handle, 0, False, 1.0, 0.0, name + " identity 0")
    out += ", " + _measure(rt, inst.handle, 1, False, 1.0, 0.0, name + " identity 1") + "]"
    var dbl = _instance(rt, _spec("double", SHAPE_SCALAR, TYPE_INT64, code), 1)
    var fah = _instance(rt, _spec("fahrenheit", SHAPE_MAP_BATCHES_COLUMN, TYPE_FLOAT64, code), 2)
    out += ', "double": ['
    var sizes: List[Int] = [1024, 8192, 65536]
    for i in range(len(sizes)):
        out += (", " if i > 0 else "") + _measure(rt, dbl, sizes[i], False, 2.0, 0.0, name + " double")
    out += '], "fahrenheit": ['
    for i in range(len(sizes)):
        out += (", " if i > 0 else "") + _measure(rt, fah, sizes[i], True, 1.8, 32.0, name + " fahrenheit")
    out += '], "threads": ['
    var one_rate = 0.0
    var ns: List[Int] = [1, 4, 16]
    var slot = 10
    for k in range(len(ns)):
        var n = ns[k]
        if k > 0:
            out += ", "
        if n > cpus:
            out += '{"threads": ' + String(n) + ', "not_measured": "' + String(cpus) + ' cpus"}'
            continue
        var insts = List[Handle]()
        for _ in range(n):
            insts.append(_instance(rt, _spec("double", SHAPE_SCALAR, TYPE_INT64, code), slot))
            slot += 1
        _ = rt.time_call_batch_threads(insts, 8192, False, 2.0, 0.0, 20)  # warmup
        var iters = 200
        var r = rt.time_call_batch_threads(insts, 8192, False, 2.0, 0.0, iters)
        if r.failures != 0 or r.mismatches != 0 or r.released != n * iters:
            raise Error("BENCH_BROKEN_CALL: " + name + " threads " + String(n))
        var rows = Float64(n * iters * 8192)
        var rate = rows * 1e9 / Float64(r.wall_ns)
        var call_rate = rows * 1e9 / Float64(r.calls_ns_max_thread)
        if n == 1:
            one_rate = call_rate
        var cpu_ratio = Float64(r.process_cpu_ns) / Float64(r.wall_ns)
        out += '{"threads": ' + String(n) + ', "rows_per_s_loop": ' + String(Int(rate))
        out += ', "rows_per_s_calls": ' + String(Int(call_rate))
        out += ', "rows_per_s_calls_per_thread": ' + String(Int(call_rate / Float64(n)))
        out += ', "efficiency": ' + String(call_rate / (Float64(n) * one_rate) if one_rate > 0 else 0.0)
        out += ', "wall_ns": ' + String(r.wall_ns) + ', "process_cpu_ns": ' + String(r.process_cpu_ns)
        out += ', "threads_cpu_ns": ' + String(r.threads_cpu_ns) + ', "cpu_over_wall": ' + String(cpu_ratio)
        out += ', "involuntary_switches": ' + String(r.involuntary_switches)
        out += ', "noisy": ' + ("true" if cpu_ratio < 0.8 * Float64(n) else "false") + "}"
    out += "]}"
    return out^


def _library(path: String, name: String) raises -> String:
    """A native library's size, sha256 time and one dlopen by path."""
    var size = 0
    with open(path, "r") as f:
        size = len(f.read_bytes())
    var t0 = perf_counter_ns()
    var d = digest_of(path)
    var t1 = perf_counter_ns()
    var copy = getenv("TMPDIR") + "/dlopen_" + hex_of(d) + ".so"
    with open(copy, "w") as f:
        with open(path, "r") as src:
            f.write_bytes(Span(src.read_bytes()))
    var t2 = perf_counter_ns()
    var h = OwnedDLHandle(copy, RTLD.NOW | RTLD.LOCAL)
    var t3 = perf_counter_ns()
    # SAFETY: one heap slot that keeps the handle, never freed, so the copy
    # is never dlclosed (a library may register exit handlers).
    var keep = alloc[OwnedDLHandle](1)
    keep.init_pointee_move(h^)
    return (
        '{"library": ' + _json_str(name) + ', "bytes": ' + String(size) + ', "sha256_ns": ' + String(t1 - t0)
        + ', "dlopen_ns": ' + String(t3 - t2) + "}"
    )


def main() raises:
    var run_id = String(_text("./run_id").strip())
    var tmp = getenv("TMPDIR")
    var cpus = _cpus()
    var facts = '{"run_id": ' + _json_str(run_id) + ', "cpus": ' + String(cpus)
    facts += ', "cpu_model": ' + _json_str(_first_line_with(_text("/proc/cpuinfo"), "model name"))
    facts += ', "loadavg": ' + _json_str(String(_text("/proc/loadavg").strip()))
    facts += ', "cgroup_cpu_max": ' + _json_str(String(_text("/sys/fs/cgroup/cpu.max").strip()))
    facts += ', "cgroup_cpu_stat": ' + _json_str(String(_text("/sys/fs/cgroup/cpu.stat").strip()))
    facts += ', "opt_levels": "Mojo libraries -O3 (mojo_shared_lib), C -O2, this driver -O1; the timed loop is C at -O2"'
    print(facts + ', "libraries_and_runtimes": [')
    print(_runtime("./echo.so", CodeSet.none(), "echo, direct", cpus) + ",")
    print(_library("./native_c.so", "C library") + ",")
    print(_library("./native_mojo.so", "Mojo library") + ",")
    var c = code_set("./native_c.so", tmp + "/code")
    print(_runtime("./native.so", c, "native + C library", cpus) + ",")
    var m = code_set("./native_mojo.so", tmp + "/code")
    print(_runtime("./native.so", m, "native + Mojo library", cpus))
    print("]}")
