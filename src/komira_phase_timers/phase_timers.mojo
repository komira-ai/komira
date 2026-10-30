# =============================================================================
# phase_timers -- per-thread phase timers that exist only when asked for
# =============================================================================
#
# A measuring aid for the engine's hot path. It answers one question: of the
# wall time of a query, how much is each phase, summed over threads and on the
# slowest thread (the critical path)?
#
# OFF BY DEFAULT, AND THEN IT IS NOT THERE. Every entry point below is generic
# over a parameter and opens with `comptime if phase_timers_on():`. The flag is
# the define `KOMIRA_PHASE_TIMERS` (`-D KOMIRA_PHASE_TIMERS=1` on the program's
# `mojo build`; a Mojo package carries no machine code, so the define is read
# where the program is built, README of tools/build/mojo, "Defines"). Without
# it, each function body is the empty `else` arm: `pt_now` returns the constant
# 0, `pt_record` and its siblings do nothing, and the call sites hold a dead
# integer. Nothing reads a clock, touches a global or allocates.
#
# ON, the cost is a clock read at a phase's start and, at its end, a clock read,
# one thread-id call (`gettid` on Linux), a linear scan of the thread table (up
# to the number of threads that have recorded, at most PT_LANES) and three
# stores into the calling thread's own lane. A lane is 4,368 bytes (its phases
# and a 144-byte `struct rusage` buffer) with 64 bytes of padding at each end,
# so two threads never write one cache line whatever the alignment of the slab.
# The sites are per row group, per morsel and per segment, never per
# row.
#
# THE LANE IS THE THREAD. A thread takes the next free lane the first time it
# records, found again by its thread id (`gettid` on Linux, else
# `pthread_self`); `pt_reset` zeroes the sums and keeps
# the lanes. Only the owner writes a lane's counters (plain load and store, no
# read-modify-write), and a reader looks only after the fork-join that ended
# the work. A phase nested in another (decode inside claim) is counted in both:
# the readers decide what to add.
#
# MORE THREADS THAN LANES. A slab has PT_LANES lanes. A thread that finds none
# free records nothing; each record it drops adds 1 to an overflow count
# (`pt_overflow_count`), which `pt_reset` zeroes, and which the probe writes
# into its JSON, so a run with dropped records is visible and its numbers are
# not to be trusted. Every path that takes a lane counts the same way: the
# interval records, and the two ends of a resource-usage interval (each end
# that finds no lane adds 1). The probe also refuses a thread list that cannot
# fit.
#
# One query at a time: the slab is process-global because the sites sit in
# functions no object of the caller reaches (the same reason as
# komira_metrics' EXPLAIN ANALYZE collector).
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global, external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.sys.defines import get_defined_int
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns

# --- the phases ---------------------------------------------------------------
#
# Driver phases are recorded by the thread that calls `run_sql`; worker phases
# by the threads that run a segment's tasks (the driver runs none of them when
# the runtime has workers).

comptime PH_PARSE: Int = 0
comptime PH_BIND: Int = 1
"""Bind, which reads the footer of the table's file."""
comptime PH_OPTIMIZE: Int = 2
comptime PH_LOWER: Int = 3
comptime PH_EXEC_SETUP: Int = 4
"""The run's builder, expression pool and sink data, before `run_plan`."""
comptime PH_RUN_PLAN: Int = 5
"""`run_plan` end to end (both segments of Q6, so it holds PH_SEG_*)."""
comptime PH_SEG_SOURCE: Int = 6
"""`build_source`: opens the file, reads its footer, a reader per worker."""
comptime PH_SEG_OPS_SINK: Int = 7
"""The operator chains, the sink and `resize_worker_state`."""
comptime PH_DISPATCH: Int = 8
"""`run_with_state` from the call to the join: the fork-join wall."""
comptime PH_COMBINE: Int = 9
"""`combine`, `finalize` and `take_output` of a segment, on the driver."""
comptime PH_WAKE: Int = 10
"""Per task: the time from the fork to the task's first instruction."""
comptime PH_JOIN_TAIL: Int = 11
"""Per task: the time from the task's end to the join returning."""
comptime PH_TASK: Int = 12
"""A task end to end: the worker's busy time."""
comptime PH_CLAIM: Int = 13
"""`next_morsel` end to end: claim, decode, filter."""
comptime PH_DECODE_FILTER_COLS: Int = 14
"""Decode of the filter columns (the lead group of the staged filter, or the
late-materialization decode)."""
comptime PH_FILTER: Int = 15
"""Predicate evaluation: the mask of the filter columns."""
comptime PH_DECODE_PAYLOAD: Int = 16
"""Decode of the columns the predicates do not read."""
comptime PH_GATHER: Int = 17
"""Gather and assembly of the surviving rows."""
comptime PH_STAGED: Int = 18
"""The staged filter arm end to end (decode, filter and gather inside it)."""
comptime PH_LATE_MAT: Int = 19
"""The late-materialization path end to end."""
comptime PH_OPS: Int = 20
"""The operator chain (a residual filter, a projection)."""
comptime PH_SINK: Int = 21
"""The sink's `consume` end to end."""
comptime PH_SINK_MAP: Int = 22
"""The aggregate's argument expression (Q6: the product)."""
comptime PH_SINK_FOLD: Int = 23
"""The aggregate's fold (Q6: the sum)."""
comptime PH_END_STAMP: Int = 24
"""A stamp, not a duration: the clock when a task ended."""
comptime PH_STAGED_DECODE_LATER: Int = 25
"""Decode of the columns a later group of the staged filter needs."""
comptime PH_STAGED_COMPACT: Int = 26
"""The staged filter's compaction of the working batch."""
comptime PH_DECODE_PLAIN: Int = 27
"""Decode of the projected columns of a row group that has no decode filter
(the plain decode of the morsel source)."""
comptime PH_COUNT: Int = 32

comptime FIELD_SUM: Int = 0
comptime FIELD_MAX: Int = 1
"""The longest single interval."""
comptime FIELD_CALLS: Int = 2
comptime FIELD_RU_VOL: Int = 4
"""Voluntary context switches of the calling thread inside the phase (the
sum of the deltas of `pt_ru_begin` / `pt_ru_end` pairs)."""
comptime FIELD_RU_INVOL: Int = 5
"""Involuntary context switches of the thread inside the phase."""
comptime FIELD_RU_UTIME_NS: Int = 6
"""User CPU time of the thread inside the phase, in nanoseconds (the kernel
reports microseconds)."""
comptime FIELD_RU_STIME_NS: Int = 7
"""System CPU time of the thread inside the phase, in nanoseconds."""
comptime FIELD_RU_MINFLT: Int = 8
"""Minor page faults of the thread inside the phase."""
comptime FIELD_RU_MAJFLT: Int = 9
"""Major page faults of the thread inside the phase."""
comptime FIELD_RU_END: Int = 10
"""One past the last accumulated field."""
comptime _RU_START: Int = 10
"""Six words per phase holding the snapshot `pt_ru_begin` took."""

# `getrusage(RUSAGE_THREAD)` is Linux only, where the constant is 1 on every
# architecture the engine runs on; other targets read no thread usage and the
# `FIELD_RU_*` counters stay 0 (`pt_ru_available` says which).
comptime _RUSAGE_THREAD: Int = 1
comptime _RU_WORDS: Int = 18
"""`struct rusage` is 144 bytes on Linux LP64: 18 words."""

comptime PT_LANES: Int = 256
comptime _FIELDS: Int = 16
comptime _PAD: Int = 8
comptime _LANE_WORDS: Int = PH_COUNT * _FIELDS + 2 * _PAD + _RU_WORDS
comptime _HEADER_WORDS: Int = 8
comptime _W_FORK: Int = 0
comptime _W_LANES_USED: Int = 1
comptime _W_OVERFLOW: Int = 2
comptime _TID_BASE: Int = _HEADER_WORDS
comptime _LANES_BASE: Int = _TID_BASE + PT_LANES + _PAD
comptime _TOTAL_WORDS: Int = _LANES_BASE + PT_LANES * _LANE_WORDS


@always_inline
def phase_timers_on[_site: Int = 0]() -> Bool:
    """True when this program was built with `-D KOMIRA_PHASE_TIMERS=1`."""
    return get_defined_int["KOMIRA_PHASE_TIMERS", 0]() != 0


def _init_slab() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: the whole slab, zeroed."""
    var raw = alloc[AtomicI64](_TOTAL_WORDS)
    for i in range(_TOTAL_WORDS):
        (raw + i).unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(
            Scalar[DType.int64](0)
        )
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _SLAB = _Global["komira_phase_timers_slab", _init_slab]


def _my_thread() -> Int:
    # The key of the thread-to-lane table. On Linux the kernel thread id: it
    # is what `/proc/self/task/<tid>` names (readers match lanes to it), and
    # unlike a `pthread_t` it is not handed again to a thread created after
    # another ended, which would give the new thread the old one's lane.
    comptime if CompilationTarget.is_linux():
        # FFI-BOUNDARY: libc gettid (glibc 2.30 or later); returns an int, no
        # pointer crosses.
        return Int(external_call["gettid", Int32]())
    else:
        # FFI-BOUNDARY: libc pthread_self, no pointer crosses; the value is
        # an opaque id used only for equality.
        return Int(external_call["pthread_self", UInt]())


def _lane_word(lane: Int, phase: Int, field: Int) -> Int:
    return _LANES_BASE + lane * _LANE_WORDS + _PAD + phase * _FIELDS + field


def _scratch_word(lane: Int) -> Int:
    """The lane's own `struct rusage` buffer, after its phases."""
    return _LANES_BASE + lane * _LANE_WORDS + _PAD + PH_COUNT * _FIELDS


# Every function below reads the slab through `_SLAB.get_or_create_ptr()` once,
# in its own body, and never lets the pointer out.


def _record_interval(phase: Int, ns: Int, stamp: Bool) raises:
    _record_interval_as(_my_thread(), phase, ns, stamp)


def _find_lane(tid: Int) raises -> Int:
    """The lane of thread `tid`, taking the next free one the first time; -1
    (after adding 1 to the overflow count) when every lane is taken."""
    # SAFETY: `_SLAB` is process-lifetime storage of `_TOTAL_WORDS` words; every
    # index below is inside it (`used` is clamped to PT_LANES before the scan,
    # and a lane is stored to only after `lane < PT_LANES` is checked); the
    # pointer does not leave this function.
    var g = _SLAB.get_or_create_ptr()
    var base = UnsafePointer(to=g[][])
    var used = min(Int((base + _W_LANES_USED)[].load()), PT_LANES)
    for i in range(used):
        if Int((base + _TID_BASE + i)[].load()) == tid:
            return i
    if used >= PT_LANES:
        _ = (base + _W_OVERFLOW)[].fetch_add(Int64(1))
        return -1
    # A free lane: one fetch_add hands each registering thread its own.
    # Racing registrations can push the counter past PT_LANES; every reader
    # clamps it, and the loser here drops its record.
    var lane = Int((base + _W_LANES_USED)[].fetch_add(Int64(1)))
    if lane >= PT_LANES:
        _ = (base + _W_OVERFLOW)[].fetch_add(Int64(1))
        return -1
    (base + _TID_BASE + lane)[].store(Int64(tid))
    return lane


def _record_interval_as(tid: Int, phase: Int, ns: Int, stamp: Bool) raises:
    var lane = _find_lane(tid)
    if lane < 0:
        return
    # SAFETY: lane < PT_LANES (from `_find_lane`), phase < PH_COUNT at every
    # call site, field < _FIELDS, so every word is inside the slab; the pointer
    # does not leave this function.
    var g = _SLAB.get_or_create_ptr()
    var base = UnsafePointer(to=g[][])
    var w = _lane_word(lane, phase, 0)
    if stamp:
        (base + w + FIELD_SUM)[].store(Int64(ns))
        return
    (base + w + FIELD_SUM)[].store((base + w + FIELD_SUM)[].load() + Int64(ns))
    if Int64(ns) > (base + w + FIELD_MAX)[].load():
        (base + w + FIELD_MAX)[].store(Int64(ns))
    (base + w + FIELD_CALLS)[].store((base + w + FIELD_CALLS)[].load() + 1)


# --- per-thread resource usage around a phase ---------------------------------
#
# `pt_ru_begin[phase]()` and `pt_ru_end[phase]()` bracket a phase on the
# calling thread: the end adds the difference of `getrusage(RUSAGE_THREAD)`
# (context switches, user and system time, page faults) to the phase's
# `FIELD_RU_*` counters of that thread's lane. One system call at each end, so
# they sit at the per-row-group sites only. The kernel fills a buffer that is
# part of the lane (no allocation), and only the owning thread touches it.


def _ru_sample(lane: Int) raises -> Bool:
    """Fill the lane's rusage buffer for the calling thread; False when the
    target has no thread usage or the call failed."""
    comptime if CompilationTarget.is_linux():
        # SAFETY: `lane` < PT_LANES (from `_find_lane`), so the `_RU_WORDS`
        # words at `_scratch_word(lane)` are inside the slab and belong to the
        # calling thread's lane alone; the pointer does not leave this function.
        var g = _SLAB.get_or_create_ptr()
        var base = UnsafePointer(to=g[][])
        # FFI-BOUNDARY: libc getrusage; the buffer is `_RU_WORDS` words of the
        # slab (process-lifetime, owned by `_SLAB`, never freed here), written
        # by the kernel during the call and read by this thread after it.
        var rc = external_call["getrusage", Int32](
            Int32(_RUSAGE_THREAD),
            (base + _scratch_word(lane)).bitcast[UInt8](),
        )
        return rc == 0
    else:
        return False


def _ru_fold(phase: Int, begin: Bool) raises:
    var lane = _find_lane(_my_thread())
    if lane < 0:
        return
    if not _ru_sample(lane):
        return
    # SAFETY: lane < PT_LANES (from `_find_lane`), phase < PH_COUNT (the
    # callers are `pt_ru_begin` / `pt_ru_end` with a phase constant), so the
    # scratch words s+0..s+17 and the lane words w+FIELD_RU_VOL..+5 and
    # w+_RU_START..+5 are inside the slab; only the owning thread writes them;
    # the pointer does not leave this function.
    var g = _SLAB.get_or_create_ptr()
    var base = UnsafePointer(to=g[][])
    var s = _scratch_word(lane)
    var vals = InlineArray[Int, 6](fill=0)
    vals[0] = Int((base + s + 16)[].load())
    vals[1] = Int((base + s + 17)[].load())
    vals[2] = (
        Int((base + s + 0)[].load()) * 1000000000
        + Int((base + s + 1)[].load()) * 1000
    )
    vals[3] = (
        Int((base + s + 2)[].load()) * 1000000000
        + Int((base + s + 3)[].load()) * 1000
    )
    vals[4] = Int((base + s + 8)[].load())
    vals[5] = Int((base + s + 9)[].load())
    var w = _lane_word(lane, phase, 0)
    for k in range(6):
        if begin:
            (base + w + _RU_START + k)[].store(Int64(vals[k]))
        else:
            var before = Int((base + w + _RU_START + k)[].load())
            var acc = Int((base + w + FIELD_RU_VOL + k)[].load())
            (base + w + FIELD_RU_VOL + k)[].store(
                Int64(acc + vals[k] - before)
            )


@always_inline
def pt_ru_begin[phase: Int]():
    """Start a resource-usage interval of `phase` on the calling thread."""
    comptime if phase_timers_on():
        try:
            _ru_fold(phase, True)
        except:
            pass


@always_inline
def pt_ru_end[phase: Int]():
    """End the interval `pt_ru_begin[phase]` started on this thread: add its
    context switches, CPU time and page faults to the phase."""
    comptime if phase_timers_on():
        try:
            _ru_fold(phase, False)
        except:
            pass


def pt_ru_available() -> Bool:
    """True when the timers are on and this target reports per-thread usage."""
    comptime if phase_timers_on() and CompilationTarget.is_linux():
        return True
    else:
        return False


@always_inline
def pt_now[_site: Int = 0]() -> Int:
    """The clock in nanoseconds when the timers are on, else the constant 0."""
    comptime if phase_timers_on():
        return Int(perf_counter_ns())
    else:
        return 0


@always_inline
def pt_record[phase: Int](t0: Int):
    """Add the time since `t0` (a `pt_now`) to `phase` of the calling thread."""
    comptime if phase_timers_on():
        try:
            _record_interval(phase, Int(perf_counter_ns()) - t0, False)
        except:
            pass


@always_inline
def pt_record_ns[phase: Int](ns: Int):
    """Add `ns` to `phase` of the calling thread."""
    comptime if phase_timers_on():
        try:
            _record_interval(phase, ns, False)
        except:
            pass


@always_inline
def pt_stamp[phase: Int]():
    """Store the clock in `phase` of the calling thread (not an interval)."""
    comptime if phase_timers_on():
        try:
            _record_interval(phase, Int(perf_counter_ns()), True)
        except:
            pass


def _mark_fork() raises:
    # SAFETY: `_SLAB` outlives the process's use; index _W_FORK is a header word
    # inside the slab; the pointer does not leave this function.
    var g = _SLAB.get_or_create_ptr()
    var base = UnsafePointer(to=g[][])
    (base + _W_FORK)[].store(Int64(perf_counter_ns()))


@always_inline
def pt_mark_fork[_site: Int = 0]():
    """Driver, just before a fork: the instant `pt_record_wake` measures from."""
    comptime if phase_timers_on():
        try:
            _mark_fork()
        except:
            pass


def _wake() raises:
    # SAFETY: as `_mark_fork`: one header word (_W_FORK) read, pointer local.
    var g = _SLAB.get_or_create_ptr()
    var fork = Int((UnsafePointer(to=g[][]) + _W_FORK)[].load())
    _record_interval(PH_WAKE, Int(perf_counter_ns()) - fork, False)


@always_inline
def pt_record_wake[_site: Int = 0]():
    """Task, first thing: the time since the driver's `pt_mark_fork`."""
    comptime if phase_timers_on():
        try:
            _wake()
        except:
            pass


def _join_tails() raises:
    # SAFETY: header words and lane words read inside the slab: the lane index
    # is below min(used, PT_LANES), so every `_lane_word` is within
    # _TOTAL_WORDS; the pointer does not leave this function.
    var now = Int(perf_counter_ns())
    var g = _SLAB.get_or_create_ptr()
    var base = UnsafePointer(to=g[][])
    var fork = Int((base + _W_FORK)[].load())
    var used = min(Int((base + _W_LANES_USED)[].load()), PT_LANES)
    var tails = List[Int]()
    for i in range(used):
        var end = Int((base + _lane_word(i, PH_END_STAMP, FIELD_SUM))[].load())
        if end > fork:
            tails.append(now - end)
    for i in range(len(tails)):
        _record_interval(PH_JOIN_TAIL, tails[i], False)


@always_inline
def pt_record_join_tails[_site: Int = 0]():
    """Driver, just after a join: for each lane whose task ended since the
    fork, the time from its end to now (the lanes' idle tail)."""
    comptime if phase_timers_on():
        try:
            _join_tails()
        except:
            pass


def _reset() raises:
    # SAFETY: writes only words of lanes below min(used, PT_LANES) and header
    # words, all inside the slab; called with no query running, so no owner is
    # writing a lane; the pointer does not leave this function.
    var g = _SLAB.get_or_create_ptr()
    var base = UnsafePointer(to=g[][])
    var used = min(Int((base + _W_LANES_USED)[].load()), PT_LANES)
    for lane in range(used):
        for p in range(PH_COUNT):
            for f in range(_FIELDS):
                (base + _lane_word(lane, p, f))[].store(Int64(0))
    (base + _W_FORK)[].store(Int64(0))
    (base + _W_OVERFLOW)[].store(Int64(0))


@always_inline
def pt_reset[_site: Int = 0]():
    """Zero every lane's counters (keeps the thread-to-lane table). Call with
    no query running."""
    comptime if phase_timers_on():
        try:
            _reset()
        except:
            pass


def _forget_threads() raises:
    # SAFETY: as `_reset`: header words and words of lanes below
    # min(used, PT_LANES), all inside the slab; called with no query running
    # and the earlier threads gone; the pointer does not leave this function.
    var g = _SLAB.get_or_create_ptr()
    var base = UnsafePointer(to=g[][])
    var used = min(Int((base + _W_LANES_USED)[].load()), PT_LANES)
    for lane in range(used):
        (base + _TID_BASE + lane)[].store(Int64(0))
        for p in range(PH_COUNT):
            for f in range(_FIELDS):
                (base + _lane_word(lane, p, f))[].store(Int64(0))
    (base + _W_LANES_USED)[].store(Int64(0))
    (base + _W_FORK)[].store(Int64(0))
    (base + _W_OVERFLOW)[].store(Int64(0))


@always_inline
def pt_forget_threads[_site: Int = 0]():
    """Drop the thread-to-lane table and zero every counter, so the next
    thread to record takes lane 0. Lanes are never reclaimed otherwise, and a
    process that builds many contexts (each with new threads) would fill the
    `PT_LANES` lanes and lose later threads. Call with no query running and
    the earlier threads gone."""
    comptime if phase_timers_on():
        try:
            _forget_threads()
        except:
            pass


# --- reading (plain functions; zeros when the timers are off) ----------------


def pt_enabled[_site: Int = 0]() -> Bool:
    """True when the program was built with the timers on."""
    comptime if phase_timers_on():
        return True
    else:
        return False


@always_inline
def pt_record_ns_as[phase: Int](thread_id: Int, ns: Int):
    """`pt_record_ns` as if called by the thread `thread_id`: for tests that
    need more threads than they can start. Does nothing when off."""
    comptime if phase_timers_on():
        try:
            _record_interval_as(thread_id, phase, ns, False)
        except:
            pass


def pt_lane_count() -> Int:
    """How many threads have recorded (0 when off). Reading it creates the
    slab if nothing has recorded yet; it is a reader's call, not a hot-path
    one, and is not behind the flag."""
    try:
        # SAFETY: one header word (_W_LANES_USED) of the slab is read; the
        # pointer does not leave this function.
        var g = _SLAB.get_or_create_ptr()
        return min(
            Int((UnsafePointer(to=g[][]) + _W_LANES_USED)[].load()), PT_LANES
        )
    except:
        return 0


def pt_overflow_count() -> Int:
    """How many records were dropped since `pt_reset` because more threads
    recorded than there are lanes (PT_LANES). Non-zero means the lane numbers
    are incomplete."""
    try:
        # SAFETY: one header word (_W_OVERFLOW) of the slab is read; the
        # pointer does not leave this function.
        var g = _SLAB.get_or_create_ptr()
        return Int((UnsafePointer(to=g[][]) + _W_OVERFLOW)[].load())
    except:
        return 0


def pt_get(lane: Int, phase: Int, field: Int) -> Int:
    """One counter of one lane: `FIELD_SUM` (ns), `FIELD_MAX` (ns) or
    `FIELD_CALLS`; 0 outside the table."""
    if lane < 0 or lane >= PT_LANES or phase < 0 or phase >= PH_COUNT:
        return 0
    if field < 0 or field >= FIELD_RU_END or field == 3:
        return 0
    try:
        # SAFETY: the bounds check above puts lane, phase and field inside the
        # table, so the word is inside the slab; the pointer does not leave
        # this function. Not behind the flag: it creates the slab if absent.
        var g = _SLAB.get_or_create_ptr()
        return Int(
            (UnsafePointer(to=g[][]) + _lane_word(lane, phase, field))[].load()
        )
    except:
        return 0


def pt_lane_tid(lane: Int) -> Int:
    """The id of a lane's thread: on Linux the kernel thread id (the name of
    its `/proc/self/task` entry); 0 outside the table or with the timers off."""
    if lane < 0 or lane >= PT_LANES:
        return 0
    try:
        # SAFETY: the bounds check above puts `lane` inside the thread table,
        # so the word is inside the slab; the pointer does not leave this
        # function.
        var g = _SLAB.get_or_create_ptr()
        return Int((UnsafePointer(to=g[][]) + _TID_BASE + lane)[].load())
    except:
        return 0


def pt_phase_name(phase: Int) -> String:
    """The stable name of a phase, as the probe's JSON writes it."""
    if phase == PH_PARSE:
        return "parse"
    if phase == PH_BIND:
        return "bind"
    if phase == PH_OPTIMIZE:
        return "optimize"
    if phase == PH_LOWER:
        return "lower"
    if phase == PH_EXEC_SETUP:
        return "exec_setup"
    if phase == PH_RUN_PLAN:
        return "run_plan"
    if phase == PH_SEG_SOURCE:
        return "seg_build_source"
    if phase == PH_SEG_OPS_SINK:
        return "seg_build_ops_sink"
    if phase == PH_DISPATCH:
        return "dispatch_fork_join"
    if phase == PH_COMBINE:
        return "combine_finalize_take"
    if phase == PH_WAKE:
        return "task_wake_latency"
    if phase == PH_JOIN_TAIL:
        return "task_join_tail"
    if phase == PH_TASK:
        return "task_busy"
    if phase == PH_CLAIM:
        return "claim_next_morsel"
    if phase == PH_DECODE_FILTER_COLS:
        return "decode_filter_cols"
    if phase == PH_FILTER:
        return "filter_mask"
    if phase == PH_DECODE_PAYLOAD:
        return "decode_payload"
    if phase == PH_GATHER:
        return "gather"
    if phase == PH_STAGED:
        return "staged_filter_arm"
    if phase == PH_LATE_MAT:
        return "late_mat_path"
    if phase == PH_OPS:
        return "operator_chain"
    if phase == PH_SINK:
        return "sink_consume"
    if phase == PH_SINK_MAP:
        return "agg_product"
    if phase == PH_SINK_FOLD:
        return "agg_sum"
    if phase == PH_END_STAMP:
        return "end_stamp"
    if phase == PH_STAGED_DECODE_LATER:
        return "staged_decode_later"
    if phase == PH_STAGED_COMPACT:
        return "staged_compact"
    if phase == PH_DECODE_PLAIN:
        return "decode_plain"
    return "phase_" + String(phase)
