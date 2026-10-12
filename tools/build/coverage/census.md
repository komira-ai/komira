# The coverage census

A part of [covcheck](README.md): the census of every library, the floors of
[The ratchet](README.md#the-ratchet) it sets, and how to refresh them.

The census doc is the census of every library under `src/`: one
coverage build of each library's gate, ranked by line coverage, with its
branch coverage (the libraries of `COVERAGE_BRANCH_GATE`; the others show
*not gated*), uncovered lines, files no test compiles, whether it is
published (in `release/artifacts.textproto`, or a conda package only), its
package's floors, and the libraries a run or the gate failed for, with why.
The libraries under `src/tests/` are test code, outside the target: listed
for information, with no floor. It is a build output, never committed:

```sh
./buck2 build //:coverage_census --show-output   # prints the path of coverage_census.md
```

**The data lives in the packages.** Each package holds two files:

- `<package>/coverage_census.tsv`: what the census measured of its
  libraries: comment lines, the line `census<TAB><date><TAB><commit><TAB><note>`
  (when it was measured, of which commit), then one row per library in the
  12 fields `census.sh` describes, each naming the file's own directory as
  its package. A package under `src/tests/` has this file and no floor.
- `<package>/coverage_floor.tsv`: its floor, one row ([The
  ratchet](README.md#the-ratchet)).

So a change to one package's coverage touches that package's directory and
nothing else, and git merges two such changes, of any two packages, without
a conflict. `//:coverage_census` (`census.bzl`) finds the files with no list
to keep: its `tree` is the root package's doc_tree, which holds every file
of the cell, and it takes each file under `src/` with one of those two
names. Three build actions:

1. `census_files assemble` (`census_files.zig`) checks each file and puts
   them together as one census (`[census]`: every row, sorted by label; one
   census line, whose date is the latest of the packages', whose note says
   `packages measured from <first> to <last>` when their dates differ) and
   one file of floors (`[floors]`, sorted by package). It refuses a floor
   file without exactly one row, a row naming another directory than its
   file's, a floor outside 0 to 10000, a pinned row with no reason, a census
   file without its census line or a library row, a carriage return or an
   empty line, each naming the file and line.
2. `census.sh render` writes the doc, the target's default output.
3. `census.sh check`, a validation: the build fails unless the floors are
   byte for byte what `render` writes from the census and them. So every
   floor is at least what the census measured, every library package of the
   census has a floor, and no package without a library in the census has
   one. A census `render` refuses (a malformed row, a library's row twice)
   fails it too.

**Refreshing** is three steps at the top of a checkout with the coverage
build's remote execution configured (they run `./buck2`), then a render and
a split:

```sh
tools/build/coverage/census.sh run --out <dir>      # every gate, --keep-going; rerun until one finishes
tools/build/coverage/census.sh collect --out <dir>  # <dir>/census.tsv from the last build report
./buck2 build '//:coverage_census[floors]' --out <dir>/floors.tsv   # the floors now committed
BB=$(./buck2 build komira//tools/build/toolchains:busybox --show-full-simple-output | tail -1)
tools/build/coverage/census.sh render "$BB" <dir>/census.tsv <dir>/floors.tsv \
    <dir>/coverage_census.md <dir>/ratchet.tsv
./buck2 run //tools/build/coverage:census_files -- split \
    "$PWD/<dir>/census.tsv" "$PWD/<dir>/ratchet.tsv" "$PWD"
```

`split` writes each package's `coverage_census.tsv` and `coverage_floor.tsv`
(the census line repeated in each census file); a package's file it does
not write is left as it was, so delete the files of a package the census
no longer has (the check names each stray floor).

`run` caps each build at 265 s (`--cap`) and starts it again while the cap
stops it; the remote cache keeps what finished. `collect` reads the last
finished build report: a library whose gate result it has is `OK`, one an
action before the gate failed for `RUN_FAILED`, one whose gate failed
`GATE_FAILED`, with the failing actions and the first error line of their
output. `render` says each floor it raised, each row it dropped (a package
no library of the census is in) and each library under its floor.

**The floors** are per package (a directory), in basis points. `render`
sets a package's floor to the lowest number of its libraries (two
libraries in one directory share a floor): line 0 when one of them was not
measured, and no branch floor unless every one of them has a branch number
(a library outside `COVERAGE_BRANCH_GATE` in the same directory as one in
it would otherwise fail its gate on an unmeasured branch floor). A library
with no executable line (0/0: its sources are all generated) sets nothing,
and its gate finds no unmeasured floor for its package (the gate counts
every source of the library, so it has nothing to cover). It never lowers
one: a floor is `max(current floor, measured)`. A library that failed
keeps its floor (or 0), so a failing run neither blocks the census nor
lowers anything.

**A coverage change** (one package's tests, say) updates its package's two
files by hand: the rows of `coverage_census.tsv` to what its gate measured
(`[coverage][gate][result]`'s `line_hit`, `line_found` and branch numbers,
and the census line's date and commit) and `coverage_floor.tsv` raised to
what `render` would set. The check then holds the floor to the rows.

- *Raising* is that edit, or a refresh: the diff of each `coverage_floor.tsv`
  is the raise, for the review. A number moves only with the tests or the
  sources: a cached run is the same run, so a flaky test cannot raise a
  floor by passing once more on unchanged inputs.
- *Floors are exact*, so one line fewer is a `Regression`. Where a covered
  line depends on timing (a contended slow path that only an unsynchronised
  two-thread test reaches, and kcov records a line once it ran), **pin** the
  floor: a fourth field, its reason, naming the lines
  (`src/p\t9871\t-\tasync_mutex.mojo:197-198 run only when contended`).
  Its floors are what you write (the measured value without those lines);
  `render` keeps a pinned row as written, never raising or lowering it, and
  the doc lists it under "Pinned floors" with what the census measured. A
  pinned row with an empty reason is refused (covcheck, `census_files` and
  `render`). Unpin (drop the reason) when the test is fixed; the next
  `render` raises it.
- *Lowering* a floor is refused by the per-change check: it reads each
  changed `coverage_floor.tsv` at the change's base and refuses any floor
  that went down, pinned ones included ([The ratchet](README.md#the-ratchet)).
  The census check refuses a floor under what `coverage_census.tsv`
  measured as well.
- A library whose run fails is `RUN_FAILED` with floor 0 (or its old floor);
  fix the run and refresh.
