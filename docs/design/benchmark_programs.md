# Benchmark programs as a mopm package

Status: decided and built. Reference: [src/komira_bench/README.md](../../src/komira_bench/README.md).

## What problem does this solve?

komira's microbenchmarks lived under the `tests/` of the library they measure (`bench_spsc_ring.mojo` in
`komira_spsc_ring`). They ran only from this repository, each read its own command line, and each spelled its
result line its own way (the `komira_op_agg_state` benchmark's header documents `ns_per_unit=<x>` while its code
prints `ns_per_unit= <x>`). A number measured on one machine is a statement about that machine; a user who wants the
number for their own CPU, compiler flags and kernel needs the program on their machine.

## The decisions

1. **Benchmarks are programs of one mopm package, `komira_bench`, shipped as source.** mopm ships a program of
   `[targets] bins` as its source (`lib/mojo/komira_bench.bins/<program>.mojo`) and builds it on the user's machine
   (`mopm run --bin komira_bench:<program>`), so the numbers are the user's. Each program's `main` is one call into
   the library (`run_program`), so its logic is library code the welded tests measure, and the program file is
   program source to the coverage census ([coverage_program_sources.md](coverage_program_sources.md)).
2. **One result line, spelled in one place.** `komira_bench.harness.result_line` is the only writer of
   `RESULT <op> [<name>=<int> ...] <metric>=<value>`. Its contract keeps the line one shape for any reader: the op,
   parameter names and metric are tokens (`a`-`z`, `0`-`9`, `_`), a parameter name appears once, and a shown value
   is finite; anything else is refused by name rather than printed. `--hide-times` prints `-` for every value, so a
   test compares a program's whole output exactly and no test reads a time.
3. **One command line, strict.** `--total-ops=N`, `--caps=A,B,...`, `--hide-times`, `--help`/`-h`. A number is
   decimal digits from 1 to the largest `Int`; every argument is checked, `--help` or not; the first refused
   argument is the error. A program adds its own limits on top (`spsc_ring` takes capacities that are powers of two
   from 1 to 2^24, because the ring rounds any other up and the line would name a capacity that was not measured).
   A benchmark that guessed at a setting the user did not mean would publish a number for something else.
4. **Each measurement times exactly the operations asked for.** The count each measurement timed is part of its
   result (`_Run.ops`), and the tests hold it to `--total-ops` for counts below, at and above one round of a
   capacity, so `ns_per_op` divides by the operations that ran.
5. **The installed source is the tested source.** `:conda_holds` reads the built `.conda` back and requires
   `lib/mojo/komira_bench.bins/spsc_ring.mojo` to be the bytes of `bins/spsc_ring.mojo`; `:bins_smoke` runs komira's
   build of that file (`:spsc_ring_bench`) and checks its whole output, its help, its refusals and its exit status.
   `mopm run` itself needs a Mojo environment from the network, so it is not part of a hermetic test.
6. **What the rest of the repository learns.** Two shared pieces change, each additively. The README e2e reader
   (`tools/build/readme_e2e/conda.zig`) accepts the one extra payload path a package with programs has, so a
   package with programs can be installed by it. buildrules is pinned to a commit whose `mojo_conda` stages each
   program's source for `mopm pack` (`bins`); the same commits move buildrules' zig and mopm unpacking onto its
   pinned `unpack` program, which changes no rule komira calls and no lock. Reverting either is one change.

## Compatibility

A new package and a new accepted path: no format is renumbered, renamed or removed, and no other package's lock,
table or output changes. `komira_spsc_ring` ships its library as before; its benchmark (`tests/bench_spsc_ring.mojo`) moved here and is no longer among its tests. The result line and the flags are
new public surface; a later change to them is additive (a new parameter, a new flag), as for any format.
