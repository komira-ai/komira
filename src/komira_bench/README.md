# komira_bench

Microbenchmarks of komira libraries, as programs you build and run on your own machine, and the small harness they
share. The package is published as source: `mopm` builds a program on your machine, so the numbers are those of your
CPU, your compiler flags and your kernel.

| program | measures |
|---|---|
| `spsc_ring` | `komira_spsc_ring`: one producer thread and one consumer thread over one ring; three ops (`push_only`, `push_pop`, `drop_push`) at four capacities |

## Running a benchmark

In a mopm project, with `pixi` on your `PATH` (`mopm sync` installs the Mojo compiler with it):

```sh
mopm add komira_bench
mopm sync
mopm run --bin komira_bench:spsc_ring
```

`mopm run` passes no arguments to a program, so this runs with the defaults (20000000 operations per measurement, four
capacities). To choose the settings, build the installed source and run that:

```sh
mopm build .mopm/.pixi/envs/default/lib/mojo/komira_bench.bins/spsc_ring.mojo -o spsc_ring --prefix .mopm/.pixi/envs/default
./spsc_ring --total-ops=1000000 --caps=64,1024
```

Each measurement is one line:

```text
RESULT push_pop cap=1024 ns_per_op=11.25
```

`RESULT <op> [<name>=<int> ...] <metric>=<value>`: the operation, the parameters it ran with, and the measured value
(nanoseconds per operation here). The programs take these flags:

| flag | meaning |
|---|---|
| `--total-ops=N` | operations per measurement (`spsc_ring`: 20000000) |
| `--caps=A,B,...` | the ring capacities to measure (`spsc_ring`: 64,1024,4096,65536) |
| `--hide-times` | print `-` for every measured value, so the output is the same on every machine |
| `--help` | print the flags and their defaults |

Any other argument, and a number that is not a positive integer, is refused by name; nothing runs.

A time on a shared machine is noise. Run on a quiet one, pinned to one core (`taskset -c 2 ./spsc_ring`), several
times, and compare the minimum.

## The harness

`komira_bench.harness` has the one place that spells a `RESULT` line, and the command line every program reads:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_bench.harness import Param, result_line

var params = List[Param]()
params.append(Param("cap", 1024))
assert_equal(
    result_line("push_pop", params, "ns_per_op", 11.25),
    "RESULT push_pop cap=1024 ns_per_op=11.25",
)
# With the times hidden the value is `-`:
assert_equal(
    result_line("push_pop", params, "ns_per_op", 11.25, True),
    "RESULT push_pop cap=1024 ns_per_op=-",
)
```

`parse_args` takes the arguments without the program name and the defaults of the program:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_bench.harness import parse_args

var defaults = List[Int]()
defaults.append(64)
defaults.append(1024)

var args = List[String]()
args.append("--total-ops=5000")
args.append("--hide-times")
var parsed = parse_args(args, 20_000_000, defaults)
assert_equal(parsed.total_ops, 5000)
assert_equal(len(parsed.caps), 2)  # not given: the defaults
assert_true(parsed.hide_times)

var message = String()
try:
    var bad = List[String]()
    bad.append("--total-ops=0")
    _ = parse_args(bad, 20_000_000, defaults)
except e:
    message = String(e)
assert_equal(message, "komira_bench: --total-ops must be a positive integer, got '0'")
```

A new program is a file under `bins/`, a line in `[targets] bins` of `mopm.toml`, and a module in
`src/komira_bench/` whose function returns its lines, so a test can run it on a few records.

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_bench`, version 0.1.0
(`mopm.toml`). The library is `src/komira_bench/` (`harness.mojo`, `spsc_ring_bench.mojo` and the `__init__.mojo`),
the programs are `bins/` (declared under `[targets] bins`: `:bin_spsc_ring`, which `:build` and `:ci` build), its tests
are `tests/`, and `smoke/` holds the test that runs a program. It depends on two packages, `komira_atomic_alias` and
`komira_spsc_ring`, sibling directories (`[dependencies]` of `mopm.toml`: `{ path = "../komira_atomic_alias", version =
"0.1" }` and `{ path = "../komira_spsc_ring", version = "0.1" }`). `komira_spsc_ring` depends on `komira_collections`,
which depends on `komira_atomic_alias`, so the lock holds all three and the `.conda` of this package records
`mojo-komira_atomic_alias >=0.1,<0.2` and `mojo-komira_spsc_ring >=0.1,<0.2` as dependencies and holds none of their
files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library, the programs and the tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, as `mopm lock` writes them (no registry is reached: every dependency is a sibling; each lists its own dependencies) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_atomic_alias` and `komira_spsc_ring`, and exists only once
the tests of `tests/` have passed (they run the harness and the benchmark on a few records and assert nothing about a
time). After any change to a source, a test, a manifest of this package or of a sibling, run `buildrules mojo sync`
with the packages staged, commit what it writes, and build `komira//src/komira_bench:lib` on the farm. A test file
that the sync has not listed is not run: run the sync after adding one.

`:bins_smoke` is a `mojo_test` (not welded: the program imports `:komira_bench`, which waits for its welded tests):
it runs `:spsc_ring_bench`, komira's build of `bins/spsc_ring.mojo` (`buck2 run //src/komira_bench:spsc_ring_bench -- --caps=64`), on a few records with `--hide-times` and requires
the whole output to be the three `RESULT` lines of one capacity, then once with real values, where it requires the
lines and no value. `:conda` is buildrules' `mojo_conda` over `:lib` (`mojo-komira_bench-0.1.0-mojo1.0.0_0.conda`);
publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_bench` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted target of
each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from. It also
compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not run again.
