# The coverage census

A part of [covcheck](README.md): the census of every library, the floors of
[The ratchet](README.md#the-ratchet) it sets, and how to refresh them.

`docs/coverage_census.md` is the census of every library under `src/`: one
coverage build of each library's gate, ranked by line coverage, with its
branch coverage (the libraries of `COVERAGE_BRANCH_GATE`; the others show
*not gated*), uncovered lines, files no test compiles, whether it is
published (in `release/artifacts.textproto`, or a conda package only), its
package's floors, and the libraries a run or the gate failed for, with why.
The libraries under `src/tests/` are test code, outside the target: listed
for information, with no floor. `census.sh` makes it in three steps, the
first two at the top of a checkout with the coverage build's remote
execution configured (they run `./buck2`):

```sh
tools/build/coverage/census.sh run --out <dir>      # every gate, --keep-going; rerun until one finishes
tools/build/coverage/census.sh collect --out <dir>  # <dir>/census.tsv from the last build report
cp <dir>/census.tsv tools/build/coverage/census.tsv
BB=$(./buck2 build komira//tools/build/toolchains:busybox --show-full-simple-output | tail -1)
tools/build/coverage/census.sh render "$BB" tools/build/coverage/census.tsv \
    tools/build/coverage/ratchet.tsv docs/coverage_census.md <dir>/ratchet.tsv
cp <dir>/ratchet.tsv tools/build/coverage/ratchet.tsv
```

`run` caps each build at 265 s (`--cap`) and starts it again while the cap
stops it; the remote cache keeps what finished. `collect` reads the last
finished build report: a library whose gate result it has is `OK`, one an
action before the gate failed for `RUN_FAILED`, one whose gate failed
`GATE_FAILED`, with the failing actions and the first error line of their
output. `render` says each floor it raised, each row it dropped (a package
no library of the census is in) and each library under its floor.

**The floors** are per package (a directory), in basis points. `render`
sets a package's floor to the lowest number of its libraries (two
libraries in one directory share a row): line 0 when one of them was not
measured, and no branch floor unless every one of them has a branch number
(a library outside `COVERAGE_BRANCH_GATE` in the same directory as one in
it would otherwise fail its gate on an unmeasured branch floor). A library
with no executable line (0/0: its sources are all generated) sets nothing,
and its gate finds no unmeasured floor for its package (the gate counts
every source of the library, so it has nothing to cover). It never lowers
one: a floor is
`max(current floor, measured)`. A library that failed keeps its floor (or
0), so a failing run neither blocks the census nor lowers anything.

**The check.** `//:coverage_census` (`census.bzl`) renders from the
committed census.tsv and ratchet.tsv in a build action and fails unless
`docs/coverage_census.md` and `ratchet.tsv` are byte for byte what it
renders. So the doc is never edited by hand, every floor is at least what
the census measured, and every library package of the census has a row
and no other row is there.

**Updating** (weekly, or on demand, as one pull request of the three files):

- *Raising* is the regenerated files: `render` raises a floor to what the
  census measured, and the diff of `ratchet.tsv` lists every raise for the
  review. A number moves only with the tests or the sources: a cached run
  is the same run, so a flaky test cannot raise a floor by passing once
  more on unchanged inputs.
- *Floors are exact*, so one line fewer is a `Regression`. Where a covered
  line depends on timing (a contended slow path that only an unsynchronised
  two-thread test reaches, and kcov records a line once it ran), **pin** the
  row: a fourth field, its reason, naming the lines
  (`src/p\t9871\t-\tasync_mutex.mojo:197-198 run only when contended`).
  Its floors are what you write (the measured value without those lines);
  `render` keeps a pinned row as written, never raising or lowering it, and
  the doc lists it under "Pinned floors" with what the census measured. A
  pinned row with an empty reason is refused (covcheck and `render`). Unpin
  (drop the reason) when the test is fixed; the next `render` raises it.
- *Lowering* an unpinned floor is a hand edit of its row, then `render` again
  for the doc: `render` never lowers one, and the check refuses an unpinned
  floor under what census.tsv measured, so it needs a census that measured
  no more (the change that lowered the coverage, or a new census of it); a
  floor that must stay under the measurement is a pinned row.
- A library whose run fails is `RUN_FAILED` with floor 0 (or its old floor);
  fix the run and refresh.
