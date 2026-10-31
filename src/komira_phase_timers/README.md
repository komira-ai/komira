# komira_phase_timers

Per-thread phase timers for the engine's hot path. They answer one question: of the wall time of a query, how much is each phase, summed over threads and on the slowest thread?

They are compiled in only when the program is built with `-D KOMIRA_PHASE_TIMERS=1`. Without the define, each entry point is generic over a parameter and opens with `comptime if phase_timers_on():`, so its body is empty: `pt_now` is the constant 0, and `pt_record`, `pt_record_ns`, `pt_stamp`, `pt_mark_fork`, `pt_record_wake`, `pt_record_join_tails`, `pt_reset` and `pt_forget_threads` do nothing. No clock is read, no global is touched, nothing is allocated. A Mojo package holds no machine code, so the define is read where the program is built (see "Defines" in `tools/build/mojo/README.md`).

Import by module name: `from komira_phase_timers.phase_timers import pt_now, pt_record, PH_FILTER`. The package root exports nothing.

```text
var t0 = pt_now()
# ... the phase ...
pt_record[PH_FILTER](t0)
```

When on, the calling thread owns a lane of the process-global slab (found by its thread id: `gettid` on Linux, `pthread_self` elsewhere; `pt_lane_tid` returns it), 4,368 bytes with a cache line of padding at each end, so two threads never write one line. A lane holds, for each phase, the sum of its intervals in nanoseconds, the longest interval, and the number of intervals. Only the owner writes a lane; read after the fork-join that ended the work, with `pt_lane_count` and `pt_get`. Phases nest (decode inside claim); `pt_phase_name` gives each phase's stable name.

A slab has `PT_LANES` (256) lanes. A record from a thread that finds no free lane is dropped and counted in `pt_overflow_count` (zeroed by `pt_reset`); a user who sees a non-zero count must not trust the lane numbers.

The readers (`pt_lane_count`, `pt_get`, `pt_overflow_count`) are plain functions, not behind the flag: they read the slab and create it if nothing has recorded, so with the timers off they allocate it once and read zeros. The recording entry points are the ones that vanish.

One query at a time: the slab is process-global.

Resource usage per phase: `pt_ru_begin[phase]()` and `pt_ru_end[phase]()` bracket a phase on the calling thread and add the difference of `getrusage(RUSAGE_THREAD)` to the phase's `FIELD_RU_*` counters: voluntary and involuntary context switches, user and system CPU time (nanoseconds) and minor and major page faults. Each is one system call, so they sit at per-row-group sites only. `RUSAGE_THREAD` is Linux only (the constant is 1 on every Linux architecture); on other targets the counters stay 0 and `pt_ru_available` is False. The kernel fills a buffer that is part of the lane, so nothing is allocated.
