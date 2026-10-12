# One Zig compile wrapper (design, not built)

Every Mojo compile runs through a shell script today: `tools/build/mojo/mojo_wrapper.sh` on Linux and
`tools/build/mojo/darwin/mojo_wrapper.sh` on macOS, two copies of one contract. This note designs their
replacement: one Zig program, `mojo_compile`, built from one source for both platforms and modeled on
`tools/build/mojo/tools/zig_cc_launcher.zig`. It follows the build architecture that
[build self-tests](build_selftests.md) states: rules are Starlark, rules invoke only Zig-built tools,
and no shell runs beyond an allowlisted handful of thin wrappers. It is slice 7 ("Runners to Zig") of
that design for the compile wrapper and its watchdog cases (rows 24, 28 and 47).

Nothing here is built. The tables name the behaviours the port must keep, the tests that prove each one,
and the order of the pull requests.

## What it replaces

| File | Lines | Fate |
|---|---:|---|
| `tools/build/mojo/mojo_wrapper.sh` | 370 | deleted by the Linux pull request |
| `tools/build/tests/functional/watchdog/cases.sh` (and its BUCK/defs) | 154 | replaced by Zig cases, same pull request |
| `tools/build/mojo/darwin/mojo_wrapper.sh` | 321 | deleted by the macOS pull request |
| `tools/build/mojo/darwin/cc` (a shell script with no extension) | 45 | replaced by the wrapper's own `cc` mode, macOS pull request |
| `tools/build/mojo/darwin/host_identity.sh` | 64 | replaced by `mojo_compile host-identity`, macOS pull request |
| `tools/build/mojo/darwin/busybox.sh` | 53 | no longer used by any compile; deleted with the last darwin runner port (see below) |
| `tools/build/mojo/darwin/dyld_prelude.sh` | 9 | never used by the compile; deleted with the Zig gate runner (see below) |

**Scope, stated exactly.** `busybox.sh` and `dyld_prelude.sh` are not the compile wrapper's alone:

- `dyld_prelude.sh` is prepended to `gate_runner.sh` and `launch.sh` (the `dyld_script` rule in
  `darwin.bzl`); the compile never reads it. It goes when the Zig gate runner and launcher take a
  loader-variable flag (`--library-path-var=DYLD_LIBRARY_PATH`), which is the gate-runner port, not this one.
- `busybox.sh` is the darwin toolchain's `busybox` field, run by every darwin action that starts
  `tc.busybox`: the compile today, and also the gate runner, `run_check.sh`, the memory cap and deadline
  prefixes, and the `cp` of `mojo_shared_lib`. After this design the compile no longer runs it; the file is
  deleted by whichever runner port removes the last of those callers. This note lists the callers so that
  pull request can prove "zero callers" with `git grep`, not assume it.

## Behaviours to preserve

Every item is something the shell does today, with the test (see "Tests") that pins it.

### Arguments

1. Four positional inputs, then options, then `--`, then the compiler's arguments. Options may come in any
   order; a repeated `--link-tail` accumulates in order; any other repeated option keeps its last value.
   Fewer than five arguments, or anything but `--` after the options, is exit 2.
2. `--runpath=` must be `$ORIGIN` or start with `$ORIGIN/`, else exit 2 ("is not $ORIGIN-relative").
   Default `$ORIGIN/lib`. On macOS `$ORIGIN` maps to `@loader_path` (default `@loader_path/lib`).
3. `--watchdog-idle-secs` and `--watchdog-sample-secs`: defaults 300 and 30; each must be a non-empty
   run of digits ("whole numbers" refusal, exit 2); sample must be at least 1 (exit 2). Idle 0 turns the
   watchdog off. The port adds an overflow refusal (a value past `u32` is exit 2, not a wrap).
4. The output is the value after the last `-o` in the compiler's arguments; none is exit 2.
5. `--source-root=<dir>`: only when the subcommand is `build`, `-strip-file-prefix=<abs dir>/` is inserted
   right after the subcommand. The absolute path is `$PWD/<dir>` for a relative dir, spelled exactly as
   the shell spells it (not canonicalised), because the compiler matches the prefix as a string. When the
   subcommand is `precompile` (which ignores `-strip-file-prefix`), the compiler instead runs from the
   root's parent, the argument naming the root becomes its basename, and `-o` and relative `-I` are made
   absolute: the `.mojoc` records `<name>/<file>.mojo` under any isolation directory
   (`compile_args.runDir`; `tests//functional/mojoc_path:same_bytes`).
6. Input paths (compiler dir, link dir) are made absolute the same way, `$PWD/<path>`.
7. macOS only: an argument `shared-lib` without an argument `-install_name` is exit 2 (bundles are
   Linux only; a C-ABI library names itself for dyld).

### Scratch, closure and configuration

8. Scratch directory: `$BUCK_SCRATCH_PATH/komira` (absolute, or relative to the working directory),
   else `<cwd>/.komira_action`. It holds `cc/`, `home/`, `tmp/`, `cache/`, `modular/`. The shell removes it
   after the compiler ran (statuses 0, 3, 4 and the compiler's own), on the watchdog's 124 and on a caught
   signal with the watchdog on. It does not remove it on the exit-2 refusals that come after it is made
   (closure check, `modular.cfg`, macOS host identity), on a `set -e` failure, or on a signal with idle 0
   (no traps then). See "Deliberate differences".
9. Closure check: `<compiler>/CLOSURE_MANIFEST` must exist and be non-empty; every non-empty line must
   name a non-empty file under the compiler dir. Every missing member is reported, then exit 2. Linux also
   requires an executable `<zig_dir>/zig` (exit 2).
10. `modular.cfg`: `<compiler>/share/max/modular.cfg` with every `@@MOJO_TOOLCHAIN_ROOT@@` replaced by
    the absolute compiler dir, written to `<scratch>/modular/modular.cfg`; a token left after rendering is
    exit 2. macOS also requires exactly one line starting `shared_libs = `, equal to
    `shared_libs = -Xlinker,-rpath,-Xlinker,<compiler>/lib;`, and rewrites it to
    `shared_libs = -Xlinker,-rpath,-Xlinker,@loader_path/lib,-Xlinker,-S;`; anything else is exit 2.
11. macOS host identity: the compile refuses (exit 2, printing the host's fields) on a host whose identity
    is not among `darwin_macos_hosts`; an empty hosts list is itself exit 2 (`darwin/mojo_wrapper.sh`
    refuses a link directory whose `macos_hosts` is empty), so the port refuses when no `--macos-host` is
    given. The identity is `<sdk version>-<first 16 hex of md5>` over six
    `name=value` lines (developer dir, SDK version, SDK build, first line of `cc --version`, first line of
    `ld -v` with stderr, OS build), each read from an absolute host path; an empty field is a refusal. The
    port must print the same bytes, or every configured `darwin_macos_hosts` value goes stale.

### The environment the compiler sees

12. Linux: `PATH=<scratch>/cc:<compiler>/bin:<applets>`, `MODULAR_HOME`, `LD_LIBRARY_PATH=<compiler>/lib`,
    `CC=<scratch>/cc/cc`, `CXX=<scratch>/cc/c++`, `MODULAR_CACHE_DIR` and `XDG_CACHE_HOME` (`<scratch>/cache`),
    `TMPDIR`, `HOME`, `ZIG_GLOBAL_CACHE_DIR`, `ZIG_LOCAL_CACHE_DIR`,
    `KGEN_CompilerRT_AsyncRT_ParallelismLevel=1`, `MODULAR_CRASH_REPORTING_ENABLED=false`.
13. macOS: the same minus `LD_LIBRARY_PATH`, `CXX` and the zig caches, plus `MACOSX_DEPLOYMENT_TARGET`
    and the two variables the `cc` shim reads (today `KOMIRA_CC_RUNPATH`, `KOMIRA_CC_LINK_TAIL`).
14. Neither script consults the worker's `PATH`. Neither clears the rest of the action's environment
    either: the header says "nothing is inherited", but the shell passes on whatever buck2 gave the action.
    `cov_zig` depends on two of those (`PWD` and `BUCK_SCRATCH_PATH`). See "Deliberate differences".

### The `cc` shim (every link of `mojo build`)

15. Linux rewrite, argument by argument, exactly the shell's table:
    - `-Xlinker -L<d>` / `-Xlinker -l<x>` become `-L<d>` / `-l<x>`; `-Xlinker --<opt>` becomes `-Wl,--<opt>`;
    - `-Xlinker -rpath|--rpath|-R` drops that pair and the next value (bare or as a `-Xlinker` pair);
      `-Xlinker -rpath=*|--rpath=*` is dropped;
    - any other `-Xlinker -<opt>` passes through and its following `-Xlinker <value>` pair passes verbatim;
      that "value expected" state survives arguments that are not `-Xlinker` and ends only at the next
      `-Xlinker` pair, whatever it holds;
    - a `-Xlinker <value not starting with ->` that does not follow a `-Xlinker -<opt>` loses its `-Xlinker`
      and passes as a bare argument;
    - `-rpath|--rpath <p>`, `-Wl,-rpath <p>`, `-Wl,--rpath <p>` drop both; `-Wl,-rpath,*`, `-Wl,-rpath=*`,
      `-Wl,--rpath,*`, `-Wl,--rpath=*`, `-Wl,-R,*` are dropped; `-Wl,-L*`/`-Wl,-l*` lose the `-Wl,`;
    - a trailing `-Xlinker` with nothing after it passes through.
16. Linux exec line, byte for byte: `<abs zig_dir>/zig cc -target <cc_target> -Wl,--strip-debug
    -Wl,--enable-new-dtags -Wl,-rpath,<runpath> <rewritten args> <link-tail lines>`. `argv[0]` is the absolute
    path (`cov_zig` takes its directory from it), and zig inherits the compiler's environment.
17. The shim answers to `cc`, `c++`, `gcc`, `g++`, `clang` and `clang++`.
18. macOS rewrite: `-Xlinker -rpath -Xlinker <p>` drops all four, `-Wl,-rpath,*` and `-rpath <p>` drop;
    other `-Xlinker` pairs pass. Exec `/usr/bin/cc -Wl,-S -Wl,-rpath,<runpath> <args> <link-tail lines>`.
19. Link-tail entries are appended in the order given, after everything the compiler passed.

### The compile watchdog

20. With idle > 0 the compiler leads a session of its own. Each second the wrapper checks whether the
    root is gone (absent, or a zombie); every `sample` seconds it reads the CPU ticks (1/100 s) of the tree.
21. The tree (Linux): every process whose session id is the root's pid, plus every descendant by parent pid
    of anything in the tree, to a fixed point. Its CPU is the sum of `utime+stime+cutime+cstime` from
    `/proc/<pid>/stat` (so reaped children count). `comm` may hold spaces and parentheses: fields are read
    after the last `)`.
22. The tree (macOS today): the root and its descendants by parent pid, each process's own CPU from
    `ps`; a reaped child no longer counts.
23. A sample is idle when the tree gained fewer ticks than `sample` (under 1% of one CPU). After
    `ceil(idle/sample)` consecutive idle samples the wrapper kills the tree, prints
    `mojo-watchdog: killed deadlocked compiler after <n>s of zero process-tree CPU (mojo <subcommand>,
    output <out>); the action is safe to retry. Knobs: *` and exits 124. No wall-clock limit.
24. Killing: stop the session and every tree member (SIGSTOP), list the frozen tree again, then SIGKILL the
    session's process group and that list. Never pid 0 or 1.
25. HUP, INT or TERM to the wrapper kills the tree, removes scratch, exits 129, 130 or 143.
26. A SIGKILLed wrapper still takes the compiler with it: a tether in the compiler's session blocks on a
    pipe whose only writer is the wrapper; when the kernel closes it, the tether kills the session.
27. On a normal exit the tether is stopped and processes the compiler orphaned are left alone (the shell
    kills the tether, not the session). The port keeps this; changing it is a separate decision.
28. With idle 0: no session, no tether, no signal handling; the compiler runs as a plain child and
    inherits the wrapper's stdin and signal dispositions.
29. With idle > 0 the shell starts the compiler as a background job (`"$@" &`) of a non-interactive shell,
    so the compiler's stdin is `/dev/null` and SIGINT and SIGQUIT are ignored, and both survive the exec.
    The port keeps this: in the root, before `execve`, it opens `/dev/null` onto fd 0 and sets SIGINT and
    SIGQUIT to `SIG_IGN`. With idle 0 it changes neither, as item 28 says.

### Exit statuses and output checks

30. The compiler's status; `128+N` when signal N killed it; 124 watchdog; 129/130/143 wrapper signalled;
    2 refusal; 3 compiler exited 0 but the output is missing or empty; 4 the output contains the working
    directory. What exit 4 prints differs today: Linux prints up to five printable runs (`strings -n 4`)
    that hold `$PWD`; macOS prints up to five matches of `$PWD` alone (`grep -aoF`). The port prints the
    Linux form on both platforms; nothing parses this text. `mutation.bzl`'s
    `_INFRA_EXITS` (2, 3, 4, 124, 129, 130, 143) reads these numbers: they are a contract, not a detail.
31. The exit-4 search uses the shell's `$PWD`. The port searches both `$PWD` and `getcwd()` when they
    differ (the spelling question `cov_zig` already handles), so it can only refuse more, never less.

## Deliberate differences

- **Process shape.** In the shell the root is an intermediate `sh`: on Linux it leads the session (via
  `setsid(1)`), starts the compiler and the tether as its two children, waits for the compiler and then
  kills the tether; on macOS the same `sh` runs without a session. In the port the root is the compiler
  itself: it calls `setsid()`, starts the tether through an intermediate process that reports the
  tether's pid and exits, then `execve`s the compiler. The compiler is the session leader; the tether is
  in its session but is not its child, so a compiler that waits for every child it has never waits for,
  or reaps, the tether. The tree (items 21 and 22) and the kill (item 24)
  are unchanged in effect, because both select by session and by descendants of the root; a case pins
  that the compiler's pid is the session id.
- **Scratch removed on every exit the wrapper makes.** The port also removes scratch on the exit-2
  refusals after it exists and on any internal failure (item 8). A signal with idle 0 (no handlers, item 28)
  and a SIGKILLed wrapper still leave it, as today; buck2 owns `BUCK_SCRATCH_PATH` either way.
- **One exit-4 report.** macOS prints the Linux form (item 30).
- **Exact environment.** The port builds the compiler's environment from nothing, like
  `zig_cc_launcher.zig`: the variables of items 12 and 13, plus `PWD` and `BUCK_SCRATCH_PATH` (when set) passed through
  because `cov_zig` reads them, plus one shim variable (below). With `--ld-debug-output=<file>` (Linux)
  it also sets `LD_DEBUG=libs` and `LD_DEBUG_OUTPUT=<file>`: `functional/runtime_libs` set those two on
  the shell wrapper, which passed them on, and now asks for them by flag. Anything else buck2 or a worker put in the
  action no longer reaches the compiler. A case pins the exact list.
- **No applets on the compiler's `PATH`.** The applet directory existed for the shell itself. If the
  compiler, a link step or `xcrun` runs a tool by bare name, the build fails loudly ("not found"), never
  silently; the parity build below is where that would show.
- **One shim variable.** The shim cannot be a generated script, so it learns its settings from
  `KOMIRA_CC_SHIM=<scratch>/cc/shim.cfg` (zig path, target, runpath, then link-tail lines). macOS has used
  two such variables since its shim was written; this makes it one on both platforms. A missing or
  unreadable file is exit 2 from the shim.
- **macOS gets the session.** `setsid(2)` exists on macOS; only `setsid(1)` was missing. The port runs the
  same session, tether and process-group kill on both platforms, and reads the tree through `libproc`
  (`proc_listallpids`, `proc_pidinfo` with `PROC_PIDTBSDINFO` for parent and process group,
  `PROC_PIDTASKINFO` for CPU time, converted from Mach time units with `mach_timebase_info` to 1/100 s).
  Reaped children still do not count on macOS; there is no `cutime` there.
- **The darwin link directory goes.** `mojo_darwin_link` copied `cc`, `host_identity.sh` and a
  `macos_hosts` file into one directory. The hosts become repeated `--macos-host=<id>` flags (still part
  of every action key, now on the command line), and the other two are the wrapper itself.

## Design

### One program, three modes

`tools/build/mojo/tools/mojo_compile.zig` with imported modules, each under 1000 lines:

| Module | Holds | Pure? |
|---|---|---|
| `compile_args.zig` | option parsing, `-o` discovery, `-strip-file-prefix` insertion, `shared-lib` refusal | yes |
| `cc_shim.zig` | the two rewrite tables, the exec line, `shim.cfg` read and write | yes, except the exec |
| `modular_cfg.zig` | render, token check, macOS `shared_libs` check and rewrite | yes |
| `proc_tree.zig` | `/proc` parse (Linux), `libproc` read (macOS), tree selection, idle arithmetic, kill | parse and selection pure; read and kill not |
| `host_identity.zig` | field collection, the value, `--fields` | value pure; collection not |
| `mojo_compile.zig` | `main`: mode dispatch, scratch, environment, spawn, watchdog loop, signals, output checks | no |

The mode comes from `argv[0]`'s basename: `cc`, `c++`, `gcc`, `g++`, `clang`, `clang++` run the shim;
anything else runs the wrapper, whose first argument may be `host-identity [--fields]` (macOS only, for a
person filling `darwin_macos_hosts`, and what `DEVELOPMENT.md` will tell them to run). The wrapper puts
symlinks with those six names in `<scratch>/cc/`, all pointing to its own executable path.

### Command line

```
mojo_compile --compiler=<dir> --cc-target=<triple> --zig=<dir>                  (Linux)
mojo_compile --compiler=<dir> --deployment-target=<v> --macos-host=<id>...      (macOS)
             [--runpath=<$ORIGIN*>] [--source-root=<dir>] [--link-tail=<arg>]...
             [--watchdog-idle-secs=<n>] [--watchdog-sample-secs=<n>]
             [--ld-debug-output=<file>] -- <mojo arguments...>                     (the last: Linux)
```

Named flags replace the four positionals (flags, not environment, per the project's configuration rule).
The busybox argument goes: the compile action no longer runs any shell. A Linux flag on macOS, or the
reverse, is exit 2, so one source cannot be run with the other platform's contract.

### Process model

The wrapper forks the root. In the root: `setsid()`, then fork an intermediate process that forks the
tether (it reads the tether pipe; on EOF it sends SIGKILL to process group 0, its own, which is the
session's), reports the tether's pid on a close-on-exec status pipe and exits, so the tether is in the
session but is not the compiler's child. The root waits for the intermediate (no tether is exit 2, "the
compiler's session did not start"), then puts `/dev/null` on fd 0 and ignores SIGINT and SIGQUIT (item 29), then `execve`
the compiler with the built environment. Exec failure is written to the same pipe (errno), and the
wrapper exits 127 for `ENOENT` and 126 otherwise, the statuses the shell gives. The wrapper holds the only write end of the tether pipe.

Watchdog loop: `nanosleep` one second, interrupted early by a signal; `waitpid(root, WNOHANG)` decides
"gone" before a tree read, so the wrapper never reads a reaped pid. HUP, INT and TERM handlers only set a
flag (async-signal-safe); the loop does the killing. On normal exit the wrapper sends SIGKILL to the
tether's pid (item 27) and closes the pipe.

The Linux build stays `x86_64-linux-musl`, static, like every Zig tool. The macOS build is
`row("darwin-arm64")["zig_triple"]`, linking `libSystem` (for `libproc` and `mach_timebase_info`);
zig's arm64 Mach-O linker writes the ad-hoc code signature macOS requires. The `libproc` and Mach
declarations are written in the module as `extern` (no SDK headers), with their struct layouts pinned by
`comptime` size checks against the values the macOS headers give.

## Rule changes

- **`zig_exe` gains `target`** with the macOS pull request (default `x86_64-linux-musl`, so every
  existing command line and golden line is unchanged); the Linux pull request does not change `zig_exe`. The macOS wrapper is built on a Linux worker for the darwin triple, the way the
  osx-arm64 compiler closure is unpacked on Linux today.
- **`zig_test` stays Linux** for the pure modules; the macOS-only code paths are proved on the macOS
  workers (see "Tests").
- **New targets:** `komira//tools/build/mojo:mojo_compile` (Linux, `unit_tests = [":mojo_compile_unit"]`)
  and a darwin `mojo_compile` with the macOS pull request, each with `unit_tests` naming its `zig_test`, so
  the wrapper cannot exist unless the unit tests passed. The Linux process cases are
  `tests//functional/watchdog:cases`.
- **`MojoToolchainInfo.wrapper`** holds the executable. `busybox` stays: other actions still use it.
- **One Starlark helper builds every compile command.** Today three rule files spell the compile argv by
  hand (`defs.bzl` `_mojo_cmd`, which `coverage_branch.bzl` and `mutation.bzl` reuse; `doc.bzl`;
  `proto.bzl`), and three test rules hand `tc.wrapper` to a script (`functional/watchdog`,
  `functional/runtime_libs`, whose inline script runs the wrapper, and `functional/coverage`'s
  `link_line.sh`). `doc.bzl` and `proto.bzl` pass no watchdog flags, so they run on the wrapper's
  built-in defaults. The helper `mojo_compile_cmd(tc, args, ...)` lives in `defs.bzl`. On Linux it
  always passes the toolchain's knobs; the values are the same (300 and 30) unless a toolchain changes them.
  Until the macOS pull request it also builds the darwin shell wrapper's unchanged command line, with
  `darwin_knobs = False` for `doc.bzl` and `proto.bzl`, which passed no knobs there.
- **`mojo_darwin_toolchain`** drops `link` and passes `macos_hosts` as flags; `mojo_darwin_link` and the
  `cc`/`host_identity.sh` exports are deleted. `functional/darwin/census.bzl` runs
  `mojo_compile host-identity` instead of the script.
- The `_script_lint` entries of the two toolchains lose the deleted files; nothing else changes in lint.

## Coverage

`cov_zig.zig` is the `zig` of a coverage link directory: the wrapper runs it in place of real zig, and it
recognises the link by the shape of item 16 (`cc`, `-Wl,--strip-debug` to drop, `-o` present, no `-c`).
Three things must hold, each already checked:

- the exec line of item 16 stays byte for byte, and `argv[0]` stays absolute;
- `PWD` and `BUCK_SCRATCH_PATH` reach the link (the exact-environment pass-through);
- `cov_branch link` (`cov_branch_link.zig`) reproduces that line for the branch link, and test 47
  (`link_line.sh`) compares the two. `link_line.sh` takes the wrapper as an argument; its rule passes the new executable.

The negative coverage target (`tests//negative/coverage`, the no-op relocator) must still fail with exit 4:
it proves item 30 through a real `cov_zig` link.

## Cache impact

Every Mojo compile action's command line changes (no busybox, no script, the wrapper's digest), so every
`mojo precompile`, `mojo build` and `mojo doc` re-runs once, on Linux in the first pull request and on
macOS in the second. Nothing else needs to: the welded test runs, the gate joins, the packers and the
coverage runs take the compile outputs as inputs, and if those are byte-identical their action keys do not
move, so they are cache hits.

That turns the cost into the proof. The Linux pull request reports, from `buck2 log what-ran` of one
farm build of the affected targets, the compile actions that ran remotely and the gated-test actions that
were cached. A gated test that re-ran names a compile output that changed bytes, which is a parity defect
to explain before merge, not a cost to accept. `golden.sh`'s committed aquery lines move for every sample
that compiles Mojo (expected, listed in the pull request); `zig_cc_launcher`, `conda_unpack` and
`snappy` must not move.

## Tests

The bar: every test says which defect it catches and names the mutant planted to see it go red.

### Unit tests (`zig_test`, welded into the wrapper)

| Area | Cases | Planted mutant that must turn it red |
|---|---|---|
| options | each flag; order; repeated `--link-tail` order; last-wins; missing `--`; under five args | keep the first `--link-tail` only |
| runpath | `$ORIGIN`, `$ORIGIN/x`, `/abs`, `$ORIGINx`; macOS mapping | accept `$ORIGINx` |
| watchdog knobs | `0`, `5m`, empty, sample `0`, `4294967296` | accept sample 0 |
| `-o` | none, one, two (last wins), `-o` last argument | first `-o` wins |
| strip prefix | `build` inserts after subcommand; `precompile` and `doc` do not | insert for every subcommand |
| Linux shim | one row per bullet of item 15, plus the exact exec line of item 16 | drop `--enable-new-dtags`; keep `-Wl,-rpath=` |
| macOS shim | item 18's three drops and a passed pair; exec line | keep `-Wl,-rpath,` |
| `modular.cfg` | token replaced; token surviving; macOS `shared_libs` zero, one wrong, two, right | skip the surviving-token check |
| `/proc` parse | `comm` with `) (` and spaces; zombie state; field offsets 14-17 | read fields after the first `)` |
| tree selection | session member reparented to 1; grandchild; pid 1 never in the kill list | drop the session rule |
| idle arithmetic | delta = sample is busy, sample - 1 idle; `need` = ceil | `<=` for `<` |
| host identity | six fixed field lines give the value the shell gives for them (a golden taken from today's script) | md5 over lines without the final newline |

### Process cases (a Buck2 target on Linux, replacing `watchdog/cases.sh`)

A Zig stand-in compiler (`zig_exe`, modes `hang`, `hangpid`, `treehang`, `orphan`, `orphanspin`, `spin`,
`childspin`, `nap2`, `nap5`, `fail`, `selfkill`, plus `envdump`, `sigstate`, `link`, `empty`, `cwd`) and a Zig cases
runner that runs the real wrapper against it, each case under its own deadline so a dead watchdog is a red
case, never a hung action:

- the thirteen `expect` cases of today's `cases.sh`, same knobs, same statuses;
- its two signal cases (TERM, KILL), extended to four: TERM 143, HUP 129, INT 130, KILL 137 (by the tether), each
  requiring compiler and child gone within 5 s;
- `envdump`: the environment is exactly item 12's list plus the pass-throughs;
- `link`: the stand-in execs `cc` from `PATH` with item 15's inputs; a stand-in zig records its argv; the
  runner compares it to item 16;
- `sigstate`: with idle > 0 the stand-in reports stdin is `/dev/null`, SIGINT and SIGQUIT ignored, and its
  pid equal to its session id; with idle 0 it reports the runner's stdin and dispositions (items 28, 29);
- `selfkill` (the stand-in dies of SIGUSR1): 138, with idle > 0 and with idle 0 (item 30's `128+N`);
- `empty` 3, `cwd` 4 (output holds the working directory), no `-o` 2, a manifest member missing 2, a
  compiler that cannot be started 127 (with idle > 0 and with idle 0), each with the scratch directory
  gone afterwards.

Mutants, each run once on the farm and named in the pull request: no tether (KILL case red); no signal
flag handling (TERM, HUP, INT red); session rule dropped (`orphan` red, and `orphanspin` killed); post
checks skipped (`empty`, `cwd` red); a leaked variable added (`envdump` red); stdin
left inherited (`sigstate` red); scratch kept on a refusal (manifest case red).

### macOS

The same cases runner and stand-in, built for the darwin triple, as a target that runs on the macOS
workers. The pull-request check has no macOS leg, so the macOS pull request carries a farm build of that
target and of `//tools/build/examples/libgate_ok:libgate_ok` on the macOS workers
(`--target-platforms komira//tools/build/platforms:darwin-arm64`), with its summary line, as its proof.
The `host-identity` value is checked on each macOS worker by the census target against the configured
`darwin_macos_hosts`: equal on every worker, or the pull request does not go up.

## Rollout

1. **Linux.** Add the modules, unit tests, the Linux `mojo_compile` target, the
   stand-in and cases runner; switch the Linux toolchain's `wrapper`; add `mojo_compile_cmd` and move the
   three rule files to it; point the runtime-libs and link-line rules at the executable; regenerate the
   golden. Delete
   `tools/build/mojo/mojo_wrapper.sh` and `functional/watchdog/cases.sh`, then run `git grep mojo_wrapper.sh`
   and update every hit that means the Linux script. That is more than the docs (`mojo_rules_and_toolchain.md`,
   the Mojo, coverage and toolchain READMEs, `cov_zig.zig`'s header): comments in `defs.bzl`, `doc.bzl`,
   `coverage.bzl`, `coverage_branch.bzl`, `coverage/kcov/defs.bzl`, `mutation.bzl`, `providers.bzl`,
   `toolchain.bzl`, `gate_runner.sh`, `tests/cxx_tests.sh`, `cov_branch_link.zig`, `functional/coverage/BUCK`,
   `link_line.sh` and `tests/coverage_runs.md` name it too. The pull request lists the hits it leaves and why
   (each names the darwin script, which the macOS pull request removes).
   The darwin toolchain still names its own shell wrapper, so macOS is untouched. Proof: unit tests and
   cases green with each mutant red once; the compile-ran, tests-cached report of "Cache impact";
   test 47 and the negative coverage target unchanged.
2. **macOS.** `zig_exe` `target`; darwin `mojo_compile` target; `mojo_darwin_toolchain` and `census.bzl` changes; delete
   `darwin/mojo_wrapper.sh`, `darwin/cc`, `darwin/host_identity.sh`, `mojo_darwin_link`; update
   `DEVELOPMENT.md` ("macOS workers") and `functional/darwin/check.sh` sections that drove the scripts;
   `git grep mojo_wrapper.sh` then returns only design notes that describe the replacement.
   Proof on the macOS workers, as above.
3. **Rust** (follow-on, below).
4. `busybox.sh` and `dyld_prelude.sh` leave with the runner ports named under "What it replaces".

Each pull request deletes its shell in the same change, and none re-runs a build only to show green: the
pull-request check builds the affected targets, and the macOS proof is the one farm build the check cannot
make.

## Follow-on: `rustc_wrapper.sh`

`tools/build/rust/rustc_wrapper.sh` (88 lines) is the same shape without the watchdog: a closure check
(`bin/rustc`, `zig`), private scratch, a generated `cc` shim (`zig cc -target <t> -Wl,--strip-debug`, no
rewriting) handed to rustc as `-C linker=`, an environment of `HOME`, `TMPDIR`, `XDG_CACHE_HOME` and the
zig caches with `LD_LIBRARY_PATH`, `LD_PRELOAD`, `RUSTFLAGS` and `RUSTC_BOOTSTRAP` unset,
`--remap-path-prefix=$PWD=.`, and the same exit 3 and 4 checks. It becomes a second `main`
(`rustc_compile.zig`) over the shared modules: scratch, exact environment, the shim's exec, and the output
checks move into a `compile_common.zig` that both import. It is its own pull request after the Linux one,
because it invalidates every Rust compile once and nothing in the Mojo port depends on it.

## Risks and open questions

- **Byte parity is assumed, then measured.** If the Mojo compiler's output depends on anything the
  environment change removes, gated tests re-run in the Linux pull request and say so. The fallback is a
  temporary target that compiles the samples with both wrappers and compares bytes, deleted in the same
  pull request.
- **macOS tree accounting** through `libproc` is new code with no Linux proof; the macOS cases are its
  only test, and they run only where the macOS workers are attached.
- **A worker's `PATH` tool the compiler needed** would surface as a red build in step 1 or 2; that is
  the intended way to find it, and the fix is an explicit input, never a restored `PATH`.
- **Orphans on normal exit** (item 27): keeping them is parity; killing the session on every exit is
  probably better and is a one-line change once the port is in, decided separately.
