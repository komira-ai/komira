# gate: the runner of every welded test

`gate` runs and supervises the tests the build welds into its targets: each
`test_srcs` entry of a `mojo_library`, a `mojo_test` under `buck2 test`, a
shared library's gate drivers, a README's examples, a `rust_test`, each step
of a mutation score build, and the test runs of the coverage builds. It is one
static executable built by the pinned zig (`zig_exe`), published behind its
unit tests (`zig_test`, below), so no test of any package runs unless these
passed. Linux only for now ("macOS", below). The design, with every behaviour it keeps from the shell runners it
replaced, is `docs/design/zig_gate_runner.md`.

| Mode | Runs | Called by |
|---|---|---|
| `gate mojo` | one gated Mojo test, optionally under a memory cap, a test time limit or a coverage run's limit | `gate_mojo` in [test_runtime.bzl](../mojo/test_runtime.bzl) (linux; macOS below); `cov_run.sh` and `cov_branch_run.sh` |
| `gate rust` | one libtest harness: list, then run every test | `_runner` in [rust/defs.bzl](../rust/defs.bzl) |
| `gate step` | one mutation step, its result recorded | `_step` in [mutation.bzl](../mojo/mutation.bzl) |

## gate mojo

```
gate mojo --busybox B --runtime-lib DIR --label L --test ROOT/bin/NAME --marker M
          [--mem-cap-mib N] [--deadline-s L --runner-timeout-s T]
          [--limit-s N --limit-report coverage]
          [--env NAME=VALUE]... [--arg VALUE]...
```

- The test runs from `ROOT/share` (an empty directory when it does not exist),
  with stdin `/dev/null` and its stdout and stderr in one log. Its environment
  is the action's, with `PATH` (busybox applets only), `LD_LIBRARY_PATH`
  (`DIR`; on macOS `DYLD_LIBRARY_PATH` too), `TMPDIR` = `TEST_TMPDIR`, `HOME`
  and `PWD` set by the gate, then each `--env`. The run directory,
  `.komira_test.XXXXXX` under the action's directory, is removed after the run.
- Each `--arg` is one argument of the test, every `@KOMIRA_ACTION_DIR@` in it
  replaced by the action's absolute directory.
- Exit 0: `PASS <label>\n` to the marker, nothing printed. Otherwise the
  banner, `GATED TEST FAILED: <label> (exit <rc>)` with the last 200 lines of
  the test's output, and the test's own status (128+N for a death by signal
  N; 77 is red like any other status).
- `--mem-cap-mib`: every 0.1 s the resident memory of the test and every
  process below it is summed from `/proc`; over the cap, all of them are
  stopped and killed, and `MEMORY CAP: killed <label> at <n> MiB resident,
  over its cap of <cap> MiB` follows the banner. Three readings in a row that
  cannot be used (or that do not show the gate itself) kill the test and exit
  2. Refused (exit 2) where there is no `/proc` (macOS).
- `--deadline-s`: past the limit the test and everything below it are killed
  (and its whole session if it is still alive 10 s later, or where `/proc`
  cannot be read), and `TEST TIME LIMIT: killed <label> after <n> s, under
  the test runner's timeout of <m> s (komira.test_timeout_s)` follows the
  banner.
- `--limit-s --limit-report coverage`: past the limit the whole session
  (kcov, the test and every child it left) is killed; the gate checks that
  nothing of it survived, prints the output, and exits 1 with `COVERAGE RUN
  FAILED`.

## gate rust

```
gate rust --busybox B --label L --test BIN --marker M --timeout-s N
```

`--list --format terse` names the tests (none: `EMPTY GATE`, exit 1), then one
run runs them all; the harness's summary must count every listed test as
passed and none ignored (`REFUSED`, exit 1). A harness killed by SIGKILL (137)
or by the timeout's SIGALRM (142) is `NO VERDICT`, with that status. The
harness sees exactly `PATH`, `TMPDIR` and `HOME`. On success `PASS <label>: <n>
passed\n` goes to the marker and to stdout.

## gate step

```
gate step --status S --limit-s N [--after F]... [--infra-exit N]... -- COMMAND...
```

The first line of `S` is `skipped` (an `--after` file's first line is not
`ok`), `ok`, `timeout <N>` (the command's group was sent SIGTERM, then SIGKILL
2 s later) or `fail <status>`, and the last 60 lines of the command's output
follow. A status named by `--infra-exit` fails the action instead. Arguments
that start with `@MUT_SCRATCH@` get a private scratch directory in its place;
every `-o <path>` of the command that does not exist afterwards is created
empty.

## The supervisor

Every mode runs its program as a child C in a session of its own, with a
tether Q outside that session: Q kills C's process group when the gate exits,
however it exits, SIGKILL included. C's exit is seen at once (a pidfd on
Linux). On Linux C is left a zombie (`waitid(WNOWAIT)`) while its group is
killed, so the group id cannot be reused before the kill. SIGHUP, SIGINT and
SIGTERM kill the group and the gate exits 128+N.

## Exit status

| Mode | 0 | the test's status | 1 | 2 |
|---|---|---|---|---|
| mojo | PASS | as given, 128+N for a signal | a coverage run past its limit | usage, a refused `--env`, an unreadable `/proc` under a cap, a failed clock, a cap where there is no `/proc` |
| rust | PASS | as given; 137 and 142 are NO VERDICT | EMPTY GATE, REFUSED, no summary line | usage |
| step | the result was recorded | an `--infra-exit` status | an `--after` file that cannot be read | usage |

A signal to the gate (HUP, INT, TERM) exits 129, 130 or 143 in every mode.

## Tests

Each `*_test.zig` is a `zig_test` listed in `unit_tests` of `:gate`, run as a
build action on the farm (Linux x86_64). The tests call the gate's entry point
in a forked child and replace its platform calls (the exec of the program,
kill, the clock, the `/proc` table) where a case needs a failure: the program
it supervises is [testkit.zig](testkit.zig)'s fixture, a child of the test
binary that does what its name says (exit, die by a signal, sleep, hold
memory, leave a child behind, print its arguments or environment, or act as a
libtest harness). One case executes a real program (busybox's `printenv`).
Every case names the defect it catches; the mutants planted to see each go red
are listed in the pull request that added the tool.

| File | Holds |
|---|---|
| [mojo_test.zig](mojo_test.zig) | usage, reserved names, `--env` isolation, arguments, the run directory, the environment, the working directory, the marker and the banner |
| [supervise_test.zig](supervise_test.zig) | the cap (on the sum over the test and its descendants), an unreadable or blind `/proc`, the time limit, a failed clock, signals, the tether, no pid reuse, the coverage limit, the no-`/proc` (macOS) paths |
| [rust_test.zig](rust_test.zig) | usage, the environment, each refusal, NO VERDICT, the marker |
| [step_test.zig](step_test.zig) | usage, each result, the timeout's group kill, skips, `-o` outputs, infra exits, the scratch directory |
| [util_test.zig](util_test.zig) | the tail against busybox `tail -n`, the `/proc` parsers |

## macOS

The darwin-arm64 Mojo toolchain does not use the gate yet. It keeps the shell
runner it had: `gate_runner.sh` behind `dyld_prelude.sh`, under
`test_deadline.sh` and `mem_cap.sh` (which refuses a cap there), selected in
`gate_mojo` ([test_runtime.bzl](../mojo/test_runtime.bzl)) by the toolchain
having no `gate`. The macOS workers are off the farm, so a macOS build of the
gate cannot be proven on them; the switch, and the deletion of those three
scripts and of their cases, waits for them.

The sources hold the macOS form already, built with `zig build-exe -target
aarch64-macos`: it sets `DYLD_LIBRARY_PATH` beside `LD_LIBRARY_PATH` and
executes the test itself (no system-protected binary in between prunes
`DYLD_*`), sees the child's exit through SIGCHLD and reaps it with `waitpid`
before killing its group (Linux keeps it a zombie instead), and has no
`/proc`: a memory cap is refused and the time limit kills the whole session.
The unit tests run on Linux only; the no-`/proc` paths are tested there
through the platform interface, the SIGCHLD wake-up and `waitpid` are not.
