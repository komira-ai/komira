# The coverage census

A part of [covcheck](README.md): the census of every library, the holds of
[The 99% threshold and holds](README.md#the-99-threshold-and-holds) it adds,
and how to refresh them.

The census doc is the census of every library under `src/`: one
coverage build of each library's gate, ranked by line coverage, with its
branch coverage (the libraries of `COVERAGE_BRANCH_GATE`; the others show
*not gated*), uncovered lines, files no test compiles, whether it is
published (in `release/artifacts.textproto`, or a conda package only), the
metrics its package holds, and the libraries a run or the gate failed for,
with why. The libraries under `src/tests/` are test code, outside the
target: listed for information, held to nothing. It is a build output,
never committed:

```sh
./buck2 build //:coverage_census --show-output   # prints the path of coverage_census.md
```

**The data lives in the packages.** Each package holds one or two files:

- `<package>/coverage_census.tsv`: what the census measured of its
  libraries: comment lines, the line `census<TAB><date><TAB><commit><TAB><note>`
  (when it was measured, of which commit), then one row per library in the
  12 fields `census.sh` describes, each naming the file's own directory as
  its package.
  When a gate left out generated sources (first line `# @generated`;
  README.md, "Generated sources"), then one `generated<TAB><path>` line each,
  after every row: a path inside the package's directory ending `.mojo`,
  sorted, each once. `census.sh collect` reads them from the gate results,
  `split` writes each into the file of the package that holds the path, and
  `assemble` checks them and leaves them out of the assembled census. A file
  without such lines is as it was. A hand-written file that gains the header
  is a diff of this file at the next refresh, which is where review sees it.
- `<package>/coverage_held`: the metrics it holds at the target, `line`
  and/or `branch`, one per line ([The 99% threshold and
  holds](README.md#the-99-threshold-and-holds)); a package that holds
  nothing has none. A package under `src/tests/` holds nothing.

So a change to one package's coverage touches that package's directory and
nothing else, and git merges two such changes, of any two packages, without
a conflict. `//:coverage_census` (`census.bzl`) finds the files with no list
to keep: its `tree` is the root package's doc_tree, which holds every file
of the cell, and it takes each file under `src/` with one of those two
names. Two build actions:

1. `census_files assemble` (`census_files.zig`) checks each file and puts
   them together as one census (`[census]`: every row, sorted by label; one
   census line, whose date is the latest of the packages', whose note says
   `packages measured from <first> to <last>` when their dates differ) and
   one file of holds (`[held]`, sorted by package). It refuses a census
   file without its census line or a library row, a row naming another
   directory than its file's, a held line that is not exactly `line` or
   `branch`, a metric held twice, a carriage return or an empty line, each
   naming the file and line; and a package the census measured at the
   target (`COVERAGE_TARGET_BP`, 99.00%) on a metric its `coverage_held`
   does not hold, naming every one. A package reaches the target on a
   metric when every library of it with an executable line was measured at
   it (and at least one was): a library that failed, or one with no number
   for the metric, keeps it from reaching it; a library with no executable
   line (0/0: its sources are all generated) neither reaches nor keeps it
   from reaching. This check reads committed data only, so it cannot flake.
2. `census_render check` writes the doc, the target's default output, and is a
   validation: a census `render` refuses (a malformed row, a library's row
   twice) fails the build.

**Refreshing** is three steps at the top of a checkout with the coverage
build's remote execution configured (they run `./buck2`):

```sh
tools/build/coverage/census.sh run --out <dir>      # every gate, --keep-going; rerun until one finishes
tools/build/coverage/census.sh collect --out <dir>  # <dir>/census.tsv from the last build report
./buck2 run //tools/build/coverage:census_files -- split 9900 "$PWD/<dir>/census.tsv" "$PWD"
```

`split` writes each package's `coverage_census.tsv` (the census line
repeated in each census file) and adds each metric a package reached to its
`coverage_held`, writing the file when the package has none. It never takes
a metric out: a hold is dropped by hand only, and the per-change check
refuses that. A package's file it does not write is left as it was, so
delete the census file of a package the census no longer has. Its first
argument is the target in basis points, `COVERAGE_TARGET_BP` of
`policy.bzl`.

`run` caps each build at 265 s (`--cap`) and starts it again while the cap
stops it; the remote cache keeps what finished. `collect` reads the last
finished build report: a library whose gate result it has is `OK`, one an
action before the gate failed for `RUN_FAILED`, one whose gate failed
`GATE_FAILED`, with the failing actions and the first error line of their
output.

**What a hold does.** A library below the target on a metric its package
holds fails its gate in every mode (a `Regression`), so its conda package
is not built; the doc marks it **below target** and counts it under "Held
and below 99.00%". Below the target and not held, a library fails nothing
(`BelowTarget` is listed, never fatal in census mode). The target is a pass
mark: nothing above it is held, so a package at 99.50% that drops to 99.10%
is still green.

**A coverage change** (one package's tests, say) updates its package's
files by hand: the rows of `coverage_census.tsv` to what its gate measured
(`[coverage][gate][result]`'s `line_hit`, `line_found` and branch numbers,
and the census line's date and commit) and, once a metric reached the
target in every library of the package, that metric in `coverage_held`
(the gate's `ReachedTarget` notice says so; the census check refuses the
change without it).

- *Holding early*: a hold may be added before the census measures the
  package at the target; the gate then fails until it does.
- *Dropping* a hold is refused by the per-change check: it reads each
  changed `coverage_held` at the change's base and refuses any metric the
  base held that the head does not, the file deleted while its package
  stays included ([The 99% threshold and
  holds](README.md#the-99-threshold-and-holds)).
- A library whose run fails is `RUN_FAILED`; its package reaches nothing
  until the run is fixed and the census refreshed.
