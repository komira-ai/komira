# One Zig gate runner and bounded-run supervisor

This is the design for replacing five shell scripts that run and supervise welded tests with one Zig
tool:

- [tools/build/mojo/gate_runner.sh](../../tools/build/mojo/gate_runner.sh) runs one gated Mojo test.
- `tools/build/rust/test_runner.sh` ran one gated Rust test (deleted; `gate rust` replaces it).
- [tools/build/mojo/mem_cap.sh](../../tools/build/mojo/mem_cap.sh) enforces a memory cap.
- [tools/build/mojo/test_deadline.sh](../../tools/build/mojo/test_deadline.sh) enforces the time limit of a
  `mojo_test`.
- The time bound of [cov_run.sh](../../tools/build/coverage/kcov/cov_run.sh) (its step 2) and of
  `mut_step.sh` (deleted; `gate step` replaces it).

Status: design only, nothing is built. Every gate in the build depends on these scripts, and their
behaviour is timing- and signal-sensitive, so this note lists every behaviour the port must keep before any
code is written. Each behaviour gets a Zig unit test and a planted mutant. The build rules still call
every script named above as they do today.

The architecture rules this design follows: rules invoke only Zig-built tools; every CI entrypoint is a
Buck2 target; no shell is added. The tool is built by `zig_exe` and welded to its `zig_test`s
([toolchain.bzl](../../tools/build/mojo/toolchain.bzl)), the same way as `cov_normalize`.

## 1. Behaviours to keep, script by script

The tables below are the specification. The new tool must keep each row exactly, unless the row is marked
**change**. A change is deliberate and is listed again in section 3.

### 1.1 gate_runner.sh (Mojo)

| # | Behaviour |
|---|---|
| G1 | Usage: `<busybox> <compiler_dir> <label> <test_binary> <marker> [--env N=V]... [--arg V]...`. Fewer than 5 positionals, an unknown argument, `--env`/`--arg` without a value, or an `--env` after an `--arg` exit **2** with a `gate_runner:` message. |
| G2 | `<test_binary>` must be `<root>/bin/<name>`. The root is cut at the **last** `/bin/`. Anything else exits 2. |
| G3 | `--env` names must match `[A-Za-z_][A-Za-z0-9_]*`, and the value may be empty. These names are refused with exit 2: `PATH LD_LIBRARY_PATH LD_PRELOAD DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES TMPDIR TEST_TMPDIR HOME PWD`. |
| G4 | **`--env` isolation.** A variable reaches the test process only, never the runner's own state. `--env BIN=true`, `BIN=<passing program>`, `rc=0`, `MARKER=…`, `LABEL=…`, `T=`, `CWD=`, `IFS=`, `ENV=`, `BB=`, `RUNNER=` must all leave a failing test red. A value may hold spaces and `=`. |
| G5 | `--arg` values are passed in order and exactly as given, except that every `@KOMIRA_ACTION_DIR@` (anywhere in the value, any number of times) becomes the action's absolute working directory. An argument is never exported. |
| G6 | A run directory `.komira_test.XXXXXX` is made under the action's working directory, never under `TMPDIR`. It holds `bin/` (every busybox applet, made with `busybox --install -s`), `tmp/`, `home/` and `share/`. Every run gets a different one, and it is removed on exit. |
| G7 | Before the test changes directory, `<busybox>`, `<compiler_dir>` and `<test_binary>` are made absolute against the action's working directory, so `LD_LIBRARY_PATH` is always absolute. Environment: `PATH=<run>/bin`, `LD_LIBRARY_PATH=<compiler_dir>/lib`, `TMPDIR=TEST_TMPDIR=<run>/tmp` (the same empty directory), `HOME=<run>/home`, plus each `--env`. Everything else in the action's environment is **inherited** (the script exports into its own environment; it does not run `env -i`). |
| G8 | The working directory is `<root>/share` if it exists, otherwise the empty `<run>/share`. It is never the action's directory. Stdin is `/dev/null`. Stdout and stderr go together, interleaved, to `<run>/log`. |
| G9 | **PASS-marker contract.** `<marker>` is used as given; a relative path is resolved from the action's working directory, not from the test's. On exit 0, the tool writes exactly `PASS <label>\n` to `<marker>`, prints nothing, and exits 0. `/dev/null` is a valid marker. The marker bytes must not change: a package action takes every marker as an input, so identical bytes keep the packages cached (section 5). |
| G10 | On a non-zero status, nothing is written to the marker. The tool prints the banner to stderr: 66 `=`, `GATED TEST FAILED: <label> (exit <rc>)`, `The library's package is not produced until this test passes.`, a 66-column `-` rule ending in ` output`, the last 200 lines of the log, and 66 `=`. Then it exits with the test's own status. A signal death is 128+N (137 for SIGKILL, 134 for SIGABRT). There is no SKIP: 77 is red. |
| G11 | Banner text is a contract with other code: [release/ci/main_red.py](../../release/ci/main_red.py) matches `^GATED TEST FAILED: (\S+)`, and [cov_run.sh](../../tools/build/coverage/kcov/cov_run.sh) and `cov_branch run` ([cov_branch_run.zig](../../tools/build/coverage/branch/cov_branch_run.zig)) remove the `GATED TEST FAILED: <label> (exit <rc>)` line and the `The library's package is not produced until this test passes.` line (banner lines 2 and 3) by exact text match, at the first match only, and keep the 66-`=` rule and the `--- output` rule. These lines must stay byte-identical. |
| G12 | Darwin: the toolchain prepends [dyld_prelude.sh](../../tools/build/mojo/darwin/dyld_prelude.sh), which sets `DYLD_LIBRARY_PATH=<compiler_dir>/lib`. No SIP-protected binary may sit between the runner and the test, because dyld would strip `DYLD_*`. The test must see both `DYLD_LIBRARY_PATH` and `LD_LIBRARY_PATH` at `<compiler_dir>/lib` (case `darwin_loader`). |

### 1.2 test_runner.sh (Rust)

| # | Behaviour |
|---|---|
| R1 | Usage: `<busybox> <label> <test_binary> <marker> <timeout_s>`, exactly 5 arguments. The timeout must be a positive integer (empty, non-digit, or `0` is refused, but `007` is accepted). Bad usage exits 2. |
| R2 | A run directory `.komira_rust_test.XXXXXX` under the action's working directory, with `bin/` (applets), `tmp/`, `home/` and `cwd/`. It is removed on exit. |
| R3 | The harness runs under `env -i` with exactly `PATH`, `TMPDIR` and `HOME`: no `TEST_TMPDIR`, no `LD_LIBRARY_PATH`, nothing inherited. Its working directory is `cwd/` and stdin is `/dev/null`. |
| R4 | Run 1 is `--list --format terse`, with stdout and stderr captured separately. Tests are the lines ending in `: test`. If listing fails, print `GATED TEST FAILED: <label>: listing its tests exited <rc>.` and the last 50 lines of stderr, then exit with the harness status. If no tests are listed, print `EMPTY GATE: …` and exit **1**. |
| R5 | Run 2 runs every test in one invocation, with stdout and stderr merged. If it fails, print `GATED TEST FAILED: <label> (exit <rc>)` and the last 100 lines, then exit with the harness status. |
| R6 | The first `^test result: ok\.` line is parsed as `N passed; M failed; K ignored;`. If that line is missing, or K != 0 (printed with the ` ... ignored` lines), or N != listed, print `REFUSED`/`GATED TEST FAILED` and the last 50 lines, then exit **1**. |
| R7 | **NO VERDICT.** In either run, a harness exit of 137 (SIGKILL) or 142 (SIGALRM from the timeout) prints `NO VERDICT: …` and exits with that same code. This check comes before every other verdict. Each run has its own timeout, which is `timeout -s ALRM` sent to the harness process only. |
| R8 | On success, write `PASS <label>: <n> passed\n` to the marker and the same line to stdout. Banners open with 66 `=`. |

### 1.3 mem_cap.sh

| # | Behaviour |
|---|---|
| M1 | Usage: `<busybox> <cap_mib> <label> -- <command…>`. The cap must be a positive integer with no leading zero. A bad cap, a missing `--`, or no `/proc/self/status` (macOS) is refused with exit 2. On macOS, a capped test is never run uncapped. |
| M2 | Every 0.1 s, sum `VmRSS` over the command and its descendants (found by `PPid`). A zombie root counts as exited. Resident memory is used, not address space: tcmalloc reserves 1 GiB regions, so `RLIMIT_AS` aborts tests. |
| M3 | **change** (section 3, change 3). Over the cap (sum > cap×1024 KiB, strictly), SIGSTOP every descendant, then SIGKILL every descendant (the list is read again between the two). Today the command is the `gate_runner.sh` shell and the test is one of its descendants, so the command is spared and the runner can report `exit 137` and the output. In the port the tool's child C *is* the test (section 2.1, step 2), so the cap kills C and every process below it, sparing only the tether Q; the tool itself reports `exit 137`. Then print `MEMORY CAP: killed <label> at <sum/1024> MiB resident, over its cap of <cap> MiB` **after** the runner's banner, and exit with the command's status. |
| M4 | A reading only counts if it shows the supervisor's own pid. After three unusable readings in a row, kill the command's process group and print `mem_cap: cannot read the process tree of <label> from /proc; killed it rather than run it uncapped`, then exit 2. |
| M5 | The command leads its own session and process group. After it exits, the group is killed (this catches reparented children). On HUP, INT or TERM, the group is killed and the tool exits **143** for all three signals. |
| M6 | If the supervisor is SIGKILLed, the session still dies: a tether blocked on a FIFO kills the group when the FIFO's only writer goes away. |

### 1.4 test_deadline.sh

| # | Behaviour |
|---|---|
| D1 | Usage: `<busybox> <limit_s> <timeout_s> <label> -- <command…>`. Both numbers must be positive integers with no leading zero. Otherwise exit 2. The rule passes `limit = timeout - 60` ([test_limit.bzl](../../tools/build/mojo/test_limit.bzl), `TEST_LIMIT_MARGIN_S`). |
| D2 | If the command exits before the limit, its status is passed through **at once**, with no wait for the limit. |
| D3 | **change** (section 3, change 2). At the limit, SIGSTOP and then SIGKILL every process below the command whose executable is not busybox. This kills the test and its children but spares the runner shells, so the runner still reports `exit 137` with output. Then print `TEST TIME LIMIT: killed <label> after <limit> s, under the test runner's timeout of <timeout> s (komira.test_timeout_s)` and exit with the command's status. |
| D4 | If `/proc` cannot be read (macOS), or the command is still alive 10 s after that kill, kill the whole group. The runner's report is lost, but the TEST TIME LIMIT line is still printed. |
| D5 | If the timer itself fails, print `test_deadline: the timer of <label> failed, so the test ran without its limit of <limit> s` and exit 2. |
| D6 | Session, group kill after exit, and the tether work as in M5 and M6. Signals exit 129, 130 or 143 (HUP, INT, TERM). |

### 1.5 The time bounds of cov_run.sh and mut_step.sh

| # | Behaviour |
|---|---|
| C1 | cov_run.sh: the gate runner, with kcov as its program, leads a new session. Past `<limit>` s (whole seconds, polled once a second), the **whole** group is killed, including the runner, kcov, the test and any child left behind. Then cov_run.sh checks that `/proc/$$/stat` and `/proc/self/stat` both start with its own pid; if not, it fails because the scan would be blind. Any group member that is not a zombie and is still alive after up to 10 s is reported as `survived the kill` with its pid, state and comm. The output of every `.komira_test.*/log` left behind is printed (last 200 lines), and the run fails with the `COVERAGE RUN FAILED` message and exit 1. |
| S1 | mut_step.sh: usage is `<busybox> <status> <limit_s> [--after F]... [--infra-exit N]... -- <cmd…>`. Exit 2 for: fewer than 4 arguments, a bad limit (empty, non-digit or leading zero), `--after` or `--infra-exit` with no value, a non-numeric (or empty) `--infra-exit`, an unknown option, or a missing `--` or command. An `--after` file that cannot be read ends the script through `set -e` with busybox `head`'s non-zero status, before any status is written. |
| S2 | `--after F`: if the first line of F is not exactly `ok`, write `skipped` and do not run the command. |
| S3 | Each argument that **starts with** `@MUT_SCRATCH@` has that prefix replaced by `$BUCK_SCRATCH_PATH/mut_step`. The path may be absolute or relative to the working directory. If the variable is unset or empty, a `mktemp` directory `.mut_step.XXXXXX` under the working directory is used. The scratch directory is created before the `--after` verdict, so it exists on a skip too. The log is `<scratch>/log`. The scratch directory and its log are kept after the step; nothing removes them. |
| S4 | The command runs in its own session, with stdin `/dev/null` and stdout and stderr to the log. At the limit, send SIGTERM to the group, wait 2 s, send SIGKILL to the group, and write status `timeout <limit>`. Otherwise write `ok`, or `fail <rc>`. A status that cannot be read counts as 137. |
| S5 | If the status is in `--infra-exit` and the step did not time out, print the machine-failure message and the last 60 log lines, then exit with that status, so the action fails and is not cached. In every other case, append the last 60 log lines to the status file and exit 0. |
| S6 | After a run or a skip, every `-o <path>` argument of the command that does not exist is created empty, along with its parent directories. The paths are read from the arguments **after** the `@MUT_SCRATCH@` replacement (S3), so `-o @MUT_SCRATCH@/x` creates `<scratch>/x`. |

## 2. The tool

One executable, `komira//tools/build/run:gate` (a `zig_exe`, statically linked against musl on Linux). It
has three subcommands that share one supervisor. Flags replace positionals, so a call site reads as what it
means:

```
gate mojo --busybox B --runtime-lib DIR --label L --test ROOT/bin/NAME --marker M
          [--mem-cap-mib N] [--deadline-s L --runner-timeout-s T]
          [--limit-s N --limit-report coverage]
          [--env NAME=VALUE]... [--arg VALUE]...
gate rust --busybox B --label L --test BIN --marker M --timeout-s N
gate step --status S --limit-s N [--after F]... [--infra-exit N]... -- COMMAND...
```

- `mojo` covers G1–G12. With `--mem-cap-mib` it also covers M1–M6, and with `--deadline-s` it also covers
  D1–D6. Today these are stacked as up to three processes (`test_deadline.sh mem_cap.sh gate_runner.sh`).
  They become one process.
- `--limit-s … --limit-report coverage` is C1, called by `cov_run.sh` in place of its `setsid` and
  watcher.
- `rust` covers R1–R8.
- `step` covers S1–S6. The command it runs is generic: a compile command (`mojo_wrapper.sh` today), or a
  test run, which is `gate mojo …` again.

The darwin loader variable is not a flag. The tool is built per target OS. On macOS it sets
`DYLD_LIBRARY_PATH` alongside `LD_LIBRARY_PATH` (G12) and executes the test directly with `execve`, so no
SIP-protected binary sits in between.

### 2.1 The supervisor (shared)

1. **Run directory.** Same name pattern, same parent and same contents as today (G6, R2). The suffix
   comes from `getrandom`. Applets are made by executing `<busybox> --install -s <run>/bin`, which is a
   process exec, not a shell.
2. **Session.** The tool forks child C. C calls `setsid()`, `chdir`s, sets up its file descriptors, and
   calls `execve(test, argv, envp)` with an `envp` the tool builds itself. G4 then holds by construction:
   the tool's own state never comes from the environment. The G4 cases still run as tests, because they
   catch a regression in how `envp` is built.
3. **Tether.** The tool forks a second child Q **outside** C's session, before it forks C. Q holds only
   the read end of a pipe, and the tool holds the only write end. When Q reads EOF (the tool exited,
   however it exited, SIGKILL included), it SIGKILLs group C and exits. This keeps M6 and D6. Q is not a
   child of the test, so a test that calls `wait()` cannot reap it, and the cap's tree kill does not
   count it or kill it (see section 3).
4. **No pid reuse.** When C exits, the tool waits with `waitid(…, WEXITED | WNOWAIT)` so that C stays a
   zombie. It kills group C, then kills and reaps Q, then reaps C. Keeping C unreaped keeps the group id
   C from being reused by a new process before the kill. The shell scripts have this race; the port
   closes it.
5. **The loop.** On Linux, `pidfd_open(C)` is polled with a 100 ms timeout. An exit is seen at once
   (D2), and the cap and the deadline are checked on each tick. On macOS, a `kqueue` `EVFILT_PROC` exit
   event is used, with the same tick. Time is read from `CLOCK_MONOTONIC`.
6. **Signals.** HUP, INT and TERM go through a self-pipe into the loop. The loop SIGKILLs group C and
   exits with the status the active mode had before (M5, D6, section 3).
7. **The process table** (Linux) is read once per tick from `/proc/[0-9]*/status`. It parses `Pid`,
   `PPid`, `State` and `VmRSS`, plus `/proc/<pid>/exe` and the `stat` pgrp field where a mode needs
   them. A process that exits mid-read is skipped, as `cat` skips it today. The reading must show the
   tool's own pid (M4). The table is behind an interface, so tests can inject a table that is
   unreadable, blind (does not show the tool's own pid), or synthetic.
8. **Output.** The log file, then a tail of the last N lines, written to stderr. N is 200 for mojo, 100
   or 50 for rust, and 60 for step. The tail follows busybox `tail -n` on a final line with no trailing
   newline. A golden test pins this.

### 2.2 Exit codes (unchanged per mode)

| Mode | 0 | Test or harness status | 1 | 2 | Signals |
|---|---|---|---|---|---|
| mojo | PASS | as given, 128+N for a signal death | `--limit-report coverage` expiry (C1) | usage, refused `--env`, unreadable `/proc` (M4), timer failure (D5), cap requested on macOS (M1) | 129 / 130 / 143 |
| rust | PASS | as given; 137 and 142 are NO VERDICT | EMPTY GATE, REFUSED, no summary line | usage | 128+N |
| step | recorded result | `--infra-exit` statuses only | | usage | 128+N |

Today, a test that exits 2 cannot be told apart from a usage error. The port keeps that ambiguity. It is
not fixed here, because markers and messages are the contract and exit 2 is not.

## 3. Deliberate changes

Each change below is a fix that only becomes possible once the tool is one process. Each has its own
mutant and is called out in the switch-over PR.

1. **macOS deadline report.** In D4, the group kill used to take the runner down with it, so its report
   was lost. The runner is now the supervisor, so a group kill never kills the reporter. On macOS the
   `GATED TEST FAILED … (exit 137)` banner and its output are now printed too.
2. **Deadline victims.** D3 spared any process whose executable is busybox, so that the runner shells
   survived. As a side effect, a test's own `sh` child also escaped until the 10 s group kill. No runner
   shell exists any more, so the deadline kills everything below the tool except Q.
3. **The cap kills the test itself, and the tether is outside the tree.** mem_cap.sh spared its command
   (M3) because the command was the runner shell and the test was a descendant. In the port C is the
   test, so sparing C would leave a one-process test, which is the normal Mojo test, running past its
   cap: the negative fixture `tests//negative/mem_cap:test_unbounded` would reach its 2 GiB fuse and pass.
   The cap therefore kills C and everything below it except Q, and the tool, not a runner shell, prints
   `exit 137` and the output before the `MEMORY CAP` line. Q's memory no longer counts toward the cap, and
   the cap's kill no longer kills it. This closes the gap that mem_cap.sh documents: "if this script is SIGKILLed between
   the cap's kill and its own group kill, a reparented child is left alive".
4. **Signal status in mem_cap-only runs.** mem_cap.sh exits 143 for HUP, INT and TERM alike. The one
   process now exits 129, 130 or 143, as test_deadline.sh already does. Only gated `test_srcs` actions
   with a cap and no deadline see this change. No rule or script tells these statuses apart for such an
   action (a `git grep` for `143` in the rules finds only `mutation.bzl`'s `_INFRA_EXITS`, which lists
   129, 130 and 143 alike).
5. **Rust session.** test_runner.sh never made a session, so a harness child that outlived the harness
   outlived the action too. `rust` now runs the harness in a session and kills the group after each run.
   The SIGALRM still goes to the harness pid alone, so 142 is still its status (R7).
6. **mut_step timing.** The limit is measured on the monotonic clock rather than by counting 0.1 s
   sleeps. A step can therefore time out a little earlier than before, by at most the loop's overhead.
   The `timeout <limit>` text is unchanged.

What stays as it is: the Mojo gate keeps inheriting the action environment (G7). Moving it to the Rust
model (`env -i` with a fixed list) is a separate decision, with its own cache invalidation, because tests
may read variables such as `BUCK_SCRATCH_PATH`.

## 4. Rule changes (Starlark)

| File | Today | After |
|---|---|---|
| [toolchain.bzl](../../tools/build/mojo/toolchain.bzl) | `_gate_runner = gate_runner.sh`. `zig_exe` and `zig_test` hard-code `-target x86_64-linux-musl`. | `_gate = komira//tools/build/run:gate`, and `MojoToolchainInfo.gate_runner` becomes `gate` (a `RunInfo`). `zig_exe` gets a `target` attribute whose default is today's string, so the command and the action key of every existing `zig_exe` stay the same. |
| [darwin.bzl](../../tools/build/mojo/darwin.bzl) and `tools/build/toolchains/darwin/BUCK` | `gate_runner = dyld_script(dyld_prelude.sh + gate_runner.sh)` | `gate_runner = …run:gate_darwin`, a `zig_exe` with `target = "aarch64-macos"`. The `gate_runner` `dyld_script` target is deleted. `dyld_prelude.sh` stays until `launch.sh` is ported. |
| [defs.bzl](../../tools/build/mojo/defs.bzl): test_srcs, README examples, shared-lib gate drivers, `mojo_test` | `busybox sh gate_runner.sh …`, prefixed by the result of `capped_prefix` and `deadline_prefix`, which are defined in `defines.bzl` and `test_limit.bzl`; `defs.bzl` only calls them | One `cmd_args(tc.gate, "mojo", "--busybox", …)`. `capped_prefix` ([defines.bzl](../../tools/build/mojo/defines.bzl)) and `deadline_prefix` ([test_limit.bzl](../../tools/build/mojo/test_limit.bzl)), which `defs.bzl` calls, return flags (`["--mem-cap-mib", n]`, `["--deadline-s", l, "--runner-timeout-s", t]`), not a script prefix. |
| [defines.bzl](../../tools/build/mojo/defines.bzl) and [test_limit.bzl](../../tools/build/mojo/test_limit.bzl) | `_mem_cap` and `_test_deadline` attributes, each holding a script | Both attributes are removed. The cap logic and the `TEST_LIMIT_MARGIN_S` arithmetic stay in Starlark, so the numbers are still decided at analysis time. |
| [mutation.bzl](../../tools/build/mojo/mutation.bzl) and `coverage/mutate/defs.bzl` | `_step` emits `busybox sh mut_step.sh …`. The run step emits `mem_cap.sh` and `gate_runner.sh`. | `_step` emits `gate step --status … --limit-s …`. The run step's command becomes `gate mojo … --mem-cap-mib …`. `@MUT_SCRATCH@` and `_INFRA_EXITS` are unchanged. |
| [coverage.bzl](../../tools/build/mojo/coverage.bzl) and [coverage_branch.bzl](../../tools/build/mojo/coverage_branch.bzl) | Pass `tc.gate_runner` to the two scripts. | Pass `tc.gate`. Step 2 of `cov_run.sh` calls `gate mojo … --limit-s $LIMIT --limit-report coverage` and drops its `setsid`, its watcher, `group_left` and its log scan. The rest of `cov_run.sh` belongs to the coverage port. |
| [rust/defs.bzl](../../tools/build/rust/defs.bzl) | `_runner` returns `busybox sh test_runner.sh …` | `cmd_args(tc.gate, "rust", "--busybox", …, "--timeout-s", …)` |

The rule-side refusals of reserved `--env` names stay where they are, so a bad `env` still fails at
analysis time, before any action runs.

## 5. Cache impact

The switch-over changes one input of every test-running action, the runner, so each such action's key
changes and every welded test runs again, once:

- **Re-run:** every `mojo_gated_test` (each `test_srcs` entry), `mojo_shared_lib_gate`, README example
  gate, every Rust test run, and, in the configurations that build them, every mutation step and
  coverage run.
  - A rough size: `git ls-files 'src/*/tests/*.mojo'` gives 2,479 files named `test_*.mojo`. That is a
    file count, not a count of welded tests, which a cquery on the farm should give before the switch.
- **Not rebuilt:** the test binaries (`mojo_build_test`) and every compile. They do not take the runner as
  an input.
- **Not rebuilt if the markers are byte-identical (G9, R8):** the packages and everything downstream. A
  package action takes the markers as inputs, and buck2 keys it on their digests, not on the action that
  wrote them. So the switch-over PR's proof includes a farm build that shows `mojo_precompile` and
  `conda` actions as cache hits after the gates re-ran. A marker byte change would show up there as a
  full rebuild.

The goal is one invalidation, not several. That is why the Mojo gate, the cap, the deadline, mutation and
coverage switch together (section 7, step 3). Landing them one at a time would re-run every capped or
mutation action more than once.

## 6. Test plan

All tests are `zig_test`s next to the tool, listed in `unit_tests` of its `zig_exe`. A cached `gate` binary
therefore means they passed on identical inputs. They run as build actions on the farm (Linux x86_64).
They use no shell stand-ins. The program under test is the tool itself (the test binary forks and calls
the subcommand entry point). The "test" it supervises is a child of the test binary that forks and runs a
behaviour picked by its arguments: exit N, kill itself with signal S, sleep, allocate and touch N MiB,
daemonize a sleeper, print its environment, print its arguments, or wait on any child.

Each row below names the behaviour, the case that proves it, and a mutant planted in the tool that the
case must turn red. Every mutant is planted once by hand while the tests are written, and the red build
is recorded in the PR.

| Behaviour | Case | Planted mutant |
|---|---|---|
| G1, R1, S1, M1, D1 usage | table of bad argv lists, each with the expected exit 2 and message prefix | accept a leading-zero number, or accept `--env` after `--arg` |
| G3 reserved names | each of the 10 names is refused | drop `LD_PRELOAD` from the list |
| G4 isolation | the 11 names from today's `env_*` cases, each with a failing test | read the label or marker from `envp` |
| G5 args | `--pair=@KOMIRA_ACTION_DIR@/a,@KOMIRA_ACTION_DIR@/b`, `two words`, `SEEN_ARG=1` arrive as 3 args, nothing exported | replace only the first token |
| G6 run dir | two runs in one directory get different empty `TEST_TMPDIR`s under the cwd, and both are gone afterwards | fixed directory name, or no cleanup |
| G7, R3 env | mojo: the five fixed variables plus an inherited variable are seen. rust: exactly 3 variables. | inherit in rust, or drop inheritance in mojo |
| G8 cwd | `share/` when present, empty otherwise, never the action dir. Stdin is empty. | use the action dir |
| G9, R8 marker | byte golden `PASS //x:y\n` and `PASS //x:y: 3 passed\n`. Nothing written on red. | trailing space, or marker written before the verdict |
| G10, G11 banner | byte golden of the whole banner for exit 1, 137, 134 and 77 | 65 `=` characters, or 77 treated as pass |
| tail | 0, 1, 200, 201 and 10,000 lines, with and without a final newline, match busybox `tail -n` | off by one line |
| R4–R7 rust | a fake harness binary for each case: empty list, list fails, ignored test, count mismatch, missing summary, SIGKILL (137), hang past the timeout (142) | check NO VERDICT after the rc check |
| M2, M3 cap | a child that holds 64 MiB under a cap of 32 is killed with 137 and the cap line comes **after** the banner. One that holds 16 MiB under 32 passes. A daemonized hog is killed by the group kill. | `>=` instead of `>`, spare C (the case uses a single-process hog, which then survives the cap), or print the line before the banner |
| M4 unreadable | an injected table that fails 3 times gives exit 2 and the group killed. Failing twice and then reading is not a refusal. A blind table (does not show the tool's own pid) counts as unreadable. | accept a reading without the tool's own pid |
| D2 prompt exit | exit 7 under a 30 s limit returns in under 2 s | sleep until the limit |
| D3, D4 deadline | a sleeper under `--deadline-s 2` gives 137, then the banner, then the `TEST TIME LIMIT` line naming 2 and the timeout. A child that ignores SIGSTOP and SIGTERM still dies within 12 s. | omit the 10 s group-kill fallback |
| D5 timer | an injected clock failure gives exit 2 and the D5 message | ignore the failure |
| M5, D6 signals | SIGTERM and SIGINT to the tool kill the session (no member alive after 5 s) and give exit 143 or 130 | exit 0 on a signal |
| M6 tether | SIGKILL to the tool: the session is gone within 5 s | tether inside the session, killed by the cap |
| no pid reuse | C is still a zombie when its group is killed (inspected through `/proc/<C>/stat`) | reap before the kill |
| C1 coverage limit | a sleeper and its daemonized child under `--limit-s 2 --limit-report coverage` give exit 1, the COVERAGE RUN FAILED text and the log tail. An injected survivor gives `survived the kill`. A blind `/proc` gives the refusal. | kill the leader only |
| S2–S6 step | ok, `fail 3`, `timeout 2` with the whole group gone, a run inside its limit, skipped with an empty `-o` file, `-o` kept after success, an infra exit of 124 failing the action, and `@MUT_SCRATCH@` resolved for an absolute, a relative and an unset scratch path | record a timeout as `fail`, or create `-o` outputs after a success |
| darwin paths | on Linux, with the platform interface forced to "no /proc": the cap is refused with exit 2, and the deadline group-kills and still prints the banner | fall back to running uncapped |

**End-to-end.** The existing planted fixtures `tests//negative/mem_cap` and `tests//negative/test_deadline`
stay unchanged. They test our tool, not a buck2 built-in, so they are allowed. They must go red with the
same text as before, and their expected strings (`MEMORY CAP: killed`, `TEST TIME LIMIT: killed … after
30 s`, `GATED TEST FAILED: … (exit 137)`) do not change. The switch-over PR runs them on the farm and
records the red result.

**Darwin.** The `zig_test`s run on Linux only, because the farm has no macOS workers in the PR check. The
macOS-only code is small: `kqueue`, setting `DYLD_LIBRARY_PATH`, and the "no /proc" branch. The last two
are covered on Linux through the platform interface. `kqueue` is not covered by any test until macOS
workers join CI. This is stated in the tool's README.

## 7. Rollout

1. **The tool alone.** Add `tools/build/run/` with `gate.zig` (argument parsing and subcommands),
   `supervise.zig` (session, tether, loop, signals), `proctab.zig` (the `/proc` reader and the platform
   interface), `mojo.zig`, `rust.zig` and `step.zig`, each under 1000 lines, plus their `*_test.zig`. No
   rule calls the tool yet, so nothing is invalidated. Proof: the mutants of section 6 go red on the farm.
2. **Rust.** Switch `rust/defs.bzl` and delete `test_runner.sh`. Only the Rust tests re-run. `rust_binary`,
   `rust_library` and `rust_test` appear in 4 BUCK files today (`tools/build/examples/rust`,
   `tools/build/proto-codegen`, `tools/build/tests/negative/rust_missing_dep` and
   `tools/build/tests/negative/rust_test`); Rust tests are in 2 of them (`proto-codegen` and
   `negative/rust_test`). This small switch-over exercises the toolchain wiring first.
3. **Mojo, in one PR.** Switch `toolchain.bzl`, `darwin.bzl`, `defs.bzl`, `defines.bzl`, `test_limit.bzl`,
   `mutation.bzl`, `coverage.bzl`, `coverage_branch.bzl` and step 2 of `cov_run.sh` together. This is the
   one full invalidation. Proof:
   - a farm build of the gated libraries that shows `local: 0`, with the package actions as cache hits
     (section 5);
   - the two negative fixtures red with today's text;
   - one test with a planted failure, red with the byte-identical banner.
4. **Delete the case scripts** that only tested the deleted shell. They can go in step 3's PR, since
   their targets would otherwise point at deleted scripts.

## 8. Files deleted

| File | Lines today | Replaced by |
|---|---:|---|
| `tools/build/mojo/gate_runner.sh` | 158 | `gate mojo` |
| `tools/build/rust/test_runner.sh` | 138 | `gate rust` |
| `tools/build/mojo/mem_cap.sh` | 155 | `gate mojo --mem-cap-mib` |
| `tools/build/mojo/test_deadline.sh` | 133 | `gate mojo --deadline-s` |
| `tools/build/coverage/mutate/mut_step.sh` | 145 | `gate step` |
| `tools/build/tests/functional/test_data/runner_cases.sh` (and `runner_cases.bzl`) | 168 | `mojo_test.zig` |
| `tools/build/tests/functional/mem_cap/cases.sh` | 155 | `supervise_test.zig` |
| `tools/build/tests/functional/test_deadline/cases.sh` | 157 | `supervise_test.zig` |
| `tools/build/coverage/mutate/mut_step_cases.sh` | 130 | `step_test.zig` |

That is 1,339 lines of shell. In `cov_run.sh`, the watcher, `group_left` and the log scan go (about 60
lines). The rest of that file belongs to the coverage port. The BUCK targets that export or lint the deleted
files go with them (`tools/build/mojo/BUCK`, `tools/build/tests/functional/{mem_cap,test_deadline}/BUCK`,
the `test_deadline:shell_lint` line in the root `BUCK`, and `coverage/mutate/BUCK`). Docs that name the
scripts are updated in the same PRs: [gates_test_welding_and_lints.md](gates_test_welding_and_lints.md),
`tools/build/mojo/README.md`, `tools/build/rust/README.md` and `tools/build/tests/README.md`.

## 9. Open questions

1. Should the Mojo gate move to `env -i` (section 3, last paragraph)? It costs a second full
   invalidation, so if the answer is yes, it should land together with step 3.
2. Today a test's exit 2 means the same as a usage error. Should the tool reserve a status that no test
   can produce? Changing it touches `main_red.py` and the `mut_step` `--infra-exit` list.
