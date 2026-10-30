# =============================================================================
# thread_census -- context switches and CPU time of every thread of the process
# =============================================================================
#
# `getrusage(RUSAGE_THREAD)` (komira_phase_timers) counts a thread only inside
# the phases that bracket it. This module counts all of them: a snapshot of
# `/proc/self/task/<tid>/status` (name, voluntary and involuntary context
# switches) and `/proc/self/task/<tid>/schedstat` (nanoseconds on a CPU,
# nanoseconds runnable and waiting for one) for every thread of the process,
# taken before and after a run. The difference, grouped by what the thread did
# in the run, says where the switches and the system time of the whole run
# come from:
#   * `driver`: the thread that called `run_sql`;
#   * `task_workers`: the threads that ran a segment task in the run;
#   * `other`: every remaining thread (workers with no task in this run,
#     I/O and helper threads), also split by thread name.
# The driver's own figures include the cost of reading the snapshots (it reads
# them), so use the other groups for the question of where the run's switches
# are. Linux only; elsewhere the snapshot is empty and every count is 0.

from std.os import listdir

from komira_host.proc_probe import _read_small_file_to_string

comptime GROUP_DRIVER: Int = 0
comptime GROUP_WORKER: Int = 1
comptime GROUP_OTHER: Int = 2
comptime GROUP_COUNT: Int = 3


struct ThreadStat(Copyable, Movable):
    var tid: Int
    var name: String
    var vol: Int
    var invol: Int
    var run_ns: Int
    """Time on a CPU (`schedstat`), 0 when the file is missing."""
    var wait_ns: Int
    """Time runnable but waiting for a CPU (`schedstat`)."""

    def __init__(out self):
        self.tid = 0
        self.name = String("")
        self.vol = 0
        self.invol = 0
        self.run_ns = 0
        self.wait_ns = 0


def _to_int(text: String) -> Int:
    """The leading decimal digits of `text` as a number (0 if none)."""
    var n = 0
    for c in text.as_bytes():
        if c < UInt8(0x30) or c > UInt8(0x39):
            break
        n = n * 10 + Int(c - UInt8(0x30))
    return n


def _line_value(text: String, key: String) -> String:
    """The text after `key:` on the line that starts with it, without the
    spaces around it; empty if there is no such line."""
    var lines = text.split("\n")
    var prefix = key + ":"
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.startswith(prefix):
            var rest = String(line[byte = prefix.byte_length() : line.byte_length()])
            return String(rest.strip())
    return String("")


def _clean(name: String) -> String:
    """`name` with every byte outside printable ASCII, and the quote and the
    backslash, replaced by an underscore (it is written into JSON)."""
    var out = String("")
    for c in name.as_bytes():
        if c < UInt8(0x20) or c > UInt8(0x7E) or c == UInt8(0x22) or c == UInt8(0x5C):
            out += "_"
        else:
            out += chr(Int(c))
    return out^


def parse_status(text: String) -> ThreadStat:
    """Name and context switches out of a `status` file's text; the other
    fields stay 0."""
    var s = ThreadStat()
    s.name = _clean(_line_value(text, "Name"))
    s.vol = _to_int(_line_value(text, "voluntary_ctxt_switches"))
    s.invol = _to_int(_line_value(text, "nonvoluntary_ctxt_switches"))
    return s^


def parse_schedstat(text: String, mut run_ns: Int, mut wait_ns: Int):
    """`run_ns wait_ns timeslices` out of a `schedstat` file's text."""
    run_ns = 0
    wait_ns = 0
    var parts = text.strip().split(" ")
    if len(parts) >= 2:
        run_ns = _to_int(String(parts[0]))
        wait_ns = _to_int(String(parts[1]))


def thread_census() -> List[ThreadStat]:
    """Every thread of this process now; empty off Linux or if `/proc` is
    unreadable."""
    var out = List[ThreadStat]()
    var tids = List[String]()
    try:
        tids = listdir("/proc/self/task")
    except:
        return out^
    for i in range(len(tids)):
        var base = String("/proc/self/task/") + tids[i]
        var status = _read_small_file_to_string(base + "/status")
        if status.byte_length() == 0:
            continue  # the thread ended between the listing and the read
        var s = parse_status(status)
        s.tid = _to_int(tids[i])
        var run_ns = 0
        var wait_ns = 0
        parse_schedstat(_read_small_file_to_string(base + "/schedstat"), run_ns, wait_ns)
        s.run_ns = run_ns
        s.wait_ns = wait_ns
        out.append(s^)
    return out^


struct GroupAgg(Copyable, Movable):
    """What the threads of one group did between two snapshots."""

    var threads: Int
    var active_threads: Int
    """Threads with at least one voluntary switch."""
    var vol_sum: Int
    var vol_max: Int
    var invol_sum: Int
    var run_ns: Int
    var wait_ns: Int
    var wait_ns_max: Int

    def __init__(out self):
        self.threads = 0
        self.active_threads = 0
        self.vol_sum = 0
        self.vol_max = 0
        self.invol_sum = 0
        self.run_ns = 0
        self.wait_ns = 0
        self.wait_ns_max = 0


struct CensusDelta(Copyable, Movable):
    var groups: List[GroupAgg]
    """`GROUP_COUNT` entries."""
    var other_names: List[String]
    """Distinct names of the `other` group's threads."""
    var other_name_threads: List[Int]
    var other_name_vol: List[Int]
    var other_name_run_ns: List[Int]

    def __init__(out self):
        self.groups = List[GroupAgg]()
        for _ in range(GROUP_COUNT):
            self.groups.append(GroupAgg())
        self.other_names = List[String]()
        self.other_name_threads = List[Int]()
        self.other_name_vol = List[Int]()
        self.other_name_run_ns = List[Int]()


def _has(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def census_delta(
    before: List[ThreadStat],
    after: List[ThreadStat],
    driver_tids: List[Int],
    worker_tids: List[Int],
) -> CensusDelta:
    """The per-group change from `before` to `after`. A thread in `after`
    only (started during the run) counts from zero; one only in `before`
    (ended) is not counted. A thread in `driver_tids` is the driver, else one
    in `worker_tids` a task worker, else `other`."""
    var d = CensusDelta()
    for i in range(len(after)):
        ref a = after[i]
        var vol = a.vol
        var invol = a.invol
        var run_ns = a.run_ns
        var wait_ns = a.wait_ns
        for j in range(len(before)):
            if before[j].tid == a.tid:
                vol -= before[j].vol
                invol -= before[j].invol
                run_ns -= before[j].run_ns
                wait_ns -= before[j].wait_ns
                break
        var g = GROUP_OTHER
        if _has(driver_tids, a.tid):
            g = GROUP_DRIVER
        elif _has(worker_tids, a.tid):
            g = GROUP_WORKER
        ref agg = d.groups[g]
        agg.threads += 1
        if vol > 0:
            agg.active_threads += 1
        agg.vol_sum += vol
        if vol > agg.vol_max:
            agg.vol_max = vol
        agg.invol_sum += invol
        agg.run_ns += run_ns
        agg.wait_ns += wait_ns
        if wait_ns > agg.wait_ns_max:
            agg.wait_ns_max = wait_ns
        if g == GROUP_OTHER:
            var k = -1
            for n in range(len(d.other_names)):
                if d.other_names[n] == a.name:
                    k = n
                    break
            if k < 0:
                d.other_names.append(a.name.copy())
                d.other_name_threads.append(0)
                d.other_name_vol.append(0)
                d.other_name_run_ns.append(0)
                k = len(d.other_names) - 1
            d.other_name_threads[k] += 1
            d.other_name_vol[k] += vol
            d.other_name_run_ns[k] += run_ns
    return d^
