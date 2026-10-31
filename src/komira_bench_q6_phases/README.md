# komira_bench_q6_phases

A profiling probe of TPC-H Q6 on the komira engine: where the time of one run goes, per phase, at several thread counts. It is a measuring aid, off in every production build, and it changes no engine behaviour: with the timers off, the instrumented call sites behave the same as before (a few of them now bind a result to a local and return it by move, where they returned the expression directly).

## What it measures

Q6 is run through `run_sql` (the engine's SQL door) on TPC-H scale factor 1, warm, at 1, 8, 32, 49 and 88 threads (the staged file has 49 row groups, so 49 workers is one row group each), in two modes: `q6`, and `decode_only`, the same scan with no predicate (`SELECT sum(l_extendedprice), sum(l_discount), sum(l_quantity), min(l_shipdate) FROM lineitem`: the four columns Q6 reads, decoded and folded, with no filter evaluation, so its `decode_plain` and `claim_next_morsel` phases are the decode scaling on its own). Before the timed runs of a mode the probe discards warm-up runs: at least 2 (5 at 32 or more threads), then until two successive runs' minor-fault counts agree within 20 percent, at most 30; the discarded runs' faults, voluntary switches and times are in the JSON (`warmup`). Then at least 5 timed runs per thread count and mode (9 by default; fewer than 5 is refused). For each it reports, as median, quartiles, interquartile range, minimum and maximum over the runs:

- the wall time of the run;
- for each phase, `critical_ms` (the largest total of any one thread in that phase, so for a worker phase the busiest worker, and for a driver phase the driver's time), `sum_ms` (over all threads), `longest_call_ms`, the number of calls, the number of threads that spent time in it, and `share_of_total_pct` (median critical time over median wall time);
- for the phases that bracket their thread's resource usage (`task_busy`, `claim_next_morsel`, `decode_filter_cols`, `staged_decode_later`, `filter_mask`, `decode_payload`, `decode_plain`), `thread_usage`: voluntary and involuntary context switches, user and system CPU time and minor and major page faults of the worker threads inside the phase (`getrusage(RUSAGE_THREAD)` deltas, Linux only; `thread_usage_available` says whether they were taken), each as the sum over workers (`sum`) and the largest of one worker (`max`), median and range over the runs. Read the process-wide context switches against the sum inside `task_busy` to see how many fall outside the tasks (the driver, the workers parking between segments);
- minor and major page faults (also one per run, so the first runs of a context can be told from the steady state), voluntary and involuntary context switches, user and system CPU time (`getrusage` deltas around the run) and the peak resident set;
- the host the engine's hardware probe saw (`host`: cores, NUMA nodes, caches, memory), which the thread counts are to be read against;
- the time to read and parse the file's footer on its own, through the two caches a query uses;
- `timer_records_dropped` (per thread count and in total) and `timer_lane_capacity`: the phase timers have a fixed number of thread lanes (256); an interval recorded by a thread that finds none is counted here instead of kept. The probe refuses a thread list that does not fit, and the count must be 0.

The phases: `parse`, `bind` (reads the footer), `optimize`, `lower`, `exec_setup`, `run_plan` (both segments), `seg_build_source` (opens the file, reads the footer again, one reader per worker), `seg_build_ops_sink`, `dispatch_fork_join` (the fork to the join), `combine_finalize_take`, `task_wake_latency` (fork to the task's first instruction), `task_join_tail` (a task's end to the join returning), `task_busy`, `claim_next_morsel`, `decode_filter_cols`, `filter_mask`, `decode_payload`, `gather`, `staged_filter_arm`, `late_mat_path`, `staged_decode_later`, `staged_compact`, `decode_plain` (the decode of a row group with no decode filter), `operator_chain`, `sink_consume`, `agg_product` and `agg_sum`. `task_join_tail` is recorded for every task by the driver, so its `critical_ms` is the sum of all the idle gaps and it has no share; read its `longest_call_ms`. Phases nest (a task holds its claims, a claim holds decode and filter, `run_plan` holds the segment phases), so the shares do not add to 100.

It also writes the plan Q6 lowers to (`plan.txt`): the bound plan, the optimized plan and the lowered plan, each predicate printed as the expression the plan holds. Read it to see whether a conjunct is pushed into the scan or left as an operator after it, and whether a constant bound such as `0.06 - 0.01` was folded to a literal before it was pushed.

## The numbers are relative

A build farm worker is not a quiet host: other jobs share it, so absolute times vary from run to run. Read the output as RELATIVE: the share of each phase in the total, and how the time scales with the thread count. It is not a headline figure and not a comparison with another engine. The JSON says so in its `note`.

The timers are not free. Each interval costs two clock reads, a thread-id call (`gettid` on Linux) and a linear scan of the thread table (as long as the number of threads that have recorded), at row-group, morsel and segment granularity, never per row. The totals the probe reports are therefore somewhat above those of a build without the timers; this probe does not measure by how much (the `note` says so). Read the shares, not the absolute totals.

## How the timers are off

The phase timers are `komira_phase_timers`: compiled in only by `-D KOMIRA_PHASE_TIMERS=1`. Without the define each call is empty (see that package), so every other target of the repository, which does not set it, is unchanged. This package's probe program and its tests are built with it; the JSON says `"timers_compiled_in": true`. A program built without it still runs the probe and reports the wall time and the page faults, with no phases.

## How to run it

On the build farm, as a build target (nothing runs on the machine you type on):

```text
./buck2 build komira//src/komira_bench_q6_phases:q6_phase_probe[phases.json] --show-output
./buck2 build komira//src/komira_bench_q6_phases:q6_phase_probe[plan.txt] --show-output
```

The target stages TPC-H scale factor 1 with the pinned DuckDB and its tpch extension (one action, cached for the next run), then runs the probe program on `lineitem` (a second action). The probe checks every answer against the TPC-H reference for scale factor 1 (123141078.2283) and exits non-zero if one differs. The thread counts and the number of runs are attributes of the target (`threads`, `runs`).

The probe program itself takes flags (`--lineitem FILE` or `--cache-dir DIR`, `--out-dir DIR`, `--threads`, `--runs`, `--mode both|q6|decode-only`, `--memory-limit-gib`, `--expect-tpch-sf1`); `cli.mojo` lists them.

## Not measured: allocation counts

The probe does not count allocations. The allocator behind Mojo's `alloc` is the platform's `malloc`, which a program cannot hook from inside without interposing the C library, and a counting wrapper at the engine's call sites would miss the allocations of the standard library's `List` and `String`. The thread usage above (switches and faults inside the decode) is what this probe can say about allocator contention; a count needs a profiler on the host.

## Where the context switches of a whole run are

`thread_usage` counts a worker only inside the bracketed phases. `thread_census` counts every thread of the process: `/proc/self/task/<tid>/status` (voluntary and involuntary switches) and `schedstat` (time on a CPU, time runnable and waiting for one) before and after each run, grouped by what the thread did in the run: `driver` (the thread that called `run_sql`; its figures include the cost of reading the snapshots), `task_workers` (threads that ran a segment task; reading the snapshots wakes them too, so at high thread counts their sum can exceed the process-wide figure: compare with `thread_census_idle_control` before dividing one figure by another) and `other` (every remaining thread: workers with no task in this run, I/O and helper threads), with `other_by_name` splitting the last by thread name. Compare the process-wide switches (`context_switches`) with `task_workers` and `thread_usage.task_busy`: what is in neither is outside the tasks.

`thread_census_idle_control` is the same census over two snapshots taken back to back with no query between them (five times, after the timed runs): what the threads do over the time one snapshot takes. A run's census spans that time plus the run, so the control is the part of the run's figures that is not the run.
