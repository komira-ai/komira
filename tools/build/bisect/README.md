# bisect

`bisect` finds the first commit between a good one and a bad one at which a
set of Buck2 targets stops building. It is a generic tool. It names nothing of
this repository and works on any git repository built with buck2. Whatever
noticed the red build calls it with the last green commit, the red one and
the targets that failed: a CI job, a person, or a service.

```sh
./buck2 run //tools/build/bisect:bisect -- \
    --good <rev> --bad <rev> --work-dir <dir outside any buck2 project> \
    --repo "$PWD" --buck2 ./buck2 --copy .buckconfig.local -- //:docs
```

## What it does

1. **It checks the inputs.** Each of these is a usage error (exit 2) before
   anything is built:
   - good or bad names no commit;
   - good and bad are the same commit;
   - good is not an ancestor of bad;
   - no target is given;
   - a `--copy` file is missing;
   - `--work-dir` is not empty;
   - `--work-dir` lies inside a buck2 project, meaning it or a directory above
     it holds a `.buckconfig` or `.buckroot`. A probe worktree there would be
     part of that project, and its builds would use that project's daemon.
2. **It builds bad again.** If the targets pass, the verdict is `flake`:
   bisect measures each target `--flake-runs` times at bad (below, "Flake
   mode") and searches nothing.
3. **It lists the candidates.** `git rev-list --first-parent --reverse
   good..bad` gives c[0..n-1], oldest first, with c[n-1] = bad. On a
   branch that only takes merges, these are the merge commits, one per pull
   request. The commits of the merged branches are never probed.
4. **It binary-searches the candidates** ([`search.zig`](search.zig)).
   - good is assumed to pass and is never built. bad is known to fail.
   - Each probe builds the commit halfway between the newest commit known to
     pass and the oldest known to fail.
   - A probe that ends `INFRA` makes its commit untestable. The next probe
     is the untested commit closest to the midpoint, as `git bisect skip`
     does.
   - If every commit left between the two is untestable, the verdict is
     `inconclusive`, and it lists the commits that remain.
5. **It prints the verdict** on stdout as one JSON object (below). Progress
   goes to stderr.

### A probe

A probe ([`probe.zig`](probe.zig)) builds the targets at one commit, in a
worktree of its own:

1. `git worktree add --detach <work-dir>/probe-<id12> <commit>`. The object
   store is shared and no branch or ref is made.
2. It copies the `--copy` files in from the repository, and runs
   `git submodule update --init --recursive` when `--submodules` is given.
3. It runs buck2 in the worktree:
   - `root --kind project` must print the worktree itself. Otherwise bisect
     stops with exit 2 and kills no daemon, because a daemon found from there
     would belong to another project.
   - `<verb> --build-report <work-dir>/logs/... <--buck2-arg>... <targets>`.
   - `kill`.
4. It runs `git worktree remove --force`.

It passes no `--isolation-dir`. Each worktree is its own project, and the
default isolation dir keeps output paths the same across worktrees, so a
probe gets cache hits for everything its commit shares with the others.

A relative `--buck2` path that contains a slash, such as `./buck2`, is
resolved in each worktree, so every probe runs the buck2 its own commit pins.
buck2 runs with this process's environment minus its `BUCK*` variables, which
an outer `buck2 run` sets.

Nothing outside the worktrees and `--work-dir` changes. The worktrees'
metadata under the repository's git directory goes when the worktree is
removed. bisect never runs `checkout`, `prune` or anything that updates a ref.

### PASS, FAIL or INFRA

[`classify.zig`](classify.zig) reads buck2's exit code and its build report.
The exit codes are those of the pinned release
(`app/buck2_error/src/exit_code.rs`).

| outcome | rule |
|---|---|
| PASS | exit 0 |
| FAIL | exit 3 and the build report names one of the given targets as failed; with `--verb test`, also exit 32 (a test failed) |
| INFRA | everything else: exit 1, 2 (infrastructure), 4 or 5 (daemon busy or preempted), 6, 11 (connect), 12, a signal, `--timeout-s`; a missing or unreadable report; an exit 3 whose report names none of the given targets as failed |

A target matches a report label when the two are the same apart from the
cell, or when the label falls under a given `//p/...` or `//p:` pattern.

An INFRA probe is tried again once. If the second attempt is also INFRA, the
commit is reported in `infra` and is never counted as a failure.

### Flake mode

[`flake.zig`](flake.zig) measures how often targets fail at one commit.
bisect runs it after a `flake` verdict, and `bisect flake` runs it alone:

```sh
./buck2 run //tools/build/bisect:bisect -- flake --rev <rev> --runs 20 \
    --work-dir <dir outside any buck2 project> --repo "$PWD" --buck2 ./buck2 \
    --copy .buckconfig.local -- //src/x:x
```

- One worktree is made for the measurement (as for a probe) and removed
  after it.
- The targets are measured one at a time. Run i of a target is one build
  of that target alone with `-c komira.rerun=<target>#<n>`, n = base + i.
  The flag gives that target's test actions an environment variable
  `KOMIRA_RERUN=<n>` and leaves every other action alone. Each run's test
  actions therefore have a key no other run had, and run again on the farm,
  while everything else stays a cache hit. Two runs with the same n would
  share a key, and the second would replay the first from the cache.
- The base is `--rerun-base`, or the time in milliseconds when bisect
  started, so a second measurement does not reuse the n of the first. The
  verdict states it; `--rerun-base 0` gives the n 1..K.
- A target is a single label. A pattern (`//p/...`, `//p:`) is a usage
  error, because a rerun names one target and a pattern's runs would all be
  cache hits.
- A run that ends INFRA is tried again once with the same n. If it stays
  INFRA it is listed in `infra` and counted neither as a run nor as a
  failure.
- Failing runs are grouped by their first failing line: the first line of
  the excerpt that says assert, expect, panic, fail or error (in any case),
  else its first line that is not blank. Each group keeps the excerpt of
  its first run.

The flag only has an effect once the build rules read `komira.rerun`.
Before that, every run after the first is a cache hit of the first run,
and the measurement shows 0 or K failures.

## Command line

```
bisect --good <rev> --bad <rev> --work-dir <dir> [--repo <dir>] [--verb build|test]
       [--buck2 <path>] [--git <path>] [--copy <relpath>]... [--submodules]
       [--buck2-arg <arg>]... [--timeout-s <n>] [--flake-runs <k>]
       [--rerun-base <n>] -- <target>...
bisect flake --rev <rev> --runs <k> --work-dir <dir> [the same flags, but
       not --good, --bad or --flake-runs] -- <target>...
```

| flag | default | meaning |
|---|---|---|
| `--repo` | `.` | the repository |
| `--work-dir` | | where the worktrees and `logs/` (each attempt's build report and buck2 output) go. It must be empty and outside any buck2 project |
| `--verb` | `build` | `buck2 build` or `buck2 test` |
| `--buck2` | `buck2` | absolute, a bare name looked up on PATH, or relative to each worktree |
| `--git` | `git` | the git to run |
| `--copy` | | a file, relative to the repository, copied into each worktree, for example a gitignored `.buckconfig.local`. It is never printed |
| `--buck2-arg` | | passed to each build, before the targets |
| `--timeout-s` | 3600 | each build is killed after this many seconds, which makes the attempt INFRA |
| `--flake-runs` | 5 | bisect: K, the runs per target at bad after a `flake` verdict. 0 measures nothing and allows patterns |
| `--runs` | | `bisect flake`: K, required, at least 1 |
| `--rev` | | `bisect flake`: the commit measured |
| `--rerun-base` | the time in ms | n of run i is base + i |

Configuration is flags only. bisect reads no environment variable of its own.

## The verdict

```json
{"verdict":"culprit","good":"<sha>","bad":"<sha>","targets":["//a:b"],
 "first_bad":{"commit":"<sha>","subject":"Merge pull request #N from ...","pr":N},
 "last_good":"<sha>",
 "probes":[{"commit":"<sha>","role":"recheck","outcome":"FAIL","attempts":1,
            "buck2_exit":3,"failed_targets":["//a:b"],"seconds":12}],
 "failures":[{"target":"//a:b","excerpt":"..."}],
 "infra":[{"commit":"<sha>","buck2_exit":2,"excerpt":"..."}],
 "flake_runs":null}
```

- `first_bad` is null unless the verdict is `culprit`.
- `pr` is N when the subject starts `Merge pull request #N`, and null
  otherwise.
- `last_good` is the newest commit known to pass before `first_bad`, or
  before the candidates. It is null for `flake`.
- `candidates` appears only for `inconclusive`. It lists the commits one of
  which is the first bad one.
- `probes` lists every probe in order, the recheck of bad first. `attempts`
  is 2 when an INFRA attempt was retried, and `buck2_exit` is null when buck2
  was killed.
- `failures` gives the failing targets at `first_bad`, or at bad when there is
  no culprit. The excerpt is the failing action's stderr, or the error message
  when the action has no stderr, cut to 20 lines and 2 KiB.
- `infra` lists the commits that stayed INFRA after the retry, each with the
  reason and the end of buck2's stderr.
- `flake_runs` is the measurement at bad after a `flake` verdict (below), and
  null for any other verdict or with `--flake-runs 0`.

| exit | meaning |
|---|---|
| 0 | culprit found |
| 1 | flake: bad passes now |
| 2 | usage error |
| 3 | inconclusive |
| 4 | a git or worktree command failed |
| 5 | tool error: an error bisect did not expect (out of memory, a filesystem call, a stdout it cannot write); stdout holds no verdict, or a cut one, and stderr names the error. Never 1, so a crash cannot read as a flake |

`bisect flake` prints

```json
{"mode":"flake","verdict":"flake",
 "measurement":{"rev":"<sha>","runs_requested":15,"rerun_base":0,
  "targets":[{"target":"//a:b","runs":15,"failures":3,"failure_rate":0.2,
    "attempts":15,"failing_runs":[3,8,13],
    "excerpts":[{"first_failing_line":"...","runs":[3,8,13],"excerpt":"..."}],
    "infra":[{"run":4,"buck2_exit":2,"excerpt":"..."}]}]}}
```

- `runs` counts the runs that ended PASS or FAIL; `failure_rate` is
  `failures / runs` (0 when `runs` is 0); `attempts` counts every build,
  retries included. A rate of 1 means the target failed every counted run.
- `failing_runs` and the `runs` of each excerpt group are the n of the runs.

| exit | `bisect flake` verdict |
|---|---|
| 0 | `never_failed`: every target was counted in all K runs and never failed |
| 1 | `flake`: some target failed in at least one counted run |
| 2 | usage error |
| 3 | `inconclusive`: no target failed, but some run stayed INFRA |
| 4 | a git or worktree command failed |
| 5 | tool error, as above |

## Limits

- One search covers all the given targets. When two commits break different
  targets, it names the earlier one. A separate run per target separates
  them.
- good is assumed to pass and is not built.
- Probes run one after another.

## Tests

Everything below is a build action. `:bisect` is built only after all of it
passes.

**Unit tests.** Each is a `zig_test`.

- `:search_unit` runs [`search_test.zig`](search_test.zig): every culprit
  position for every length up to 40, found within ⌈log₂ n⌉ probes and never
  probing bad; skips around untestable commits; the inconclusive spans.
- `:classify_unit` runs [`classify_test.zig`](classify_test.zig) over three
  build reports in `testdata/`. Each was written by the pinned buck2 for a
  small throwaway package built on the farm, with its trace id, project root
  and a remote-execution link taken out:
  - `report_action_failed.json`: a `zig_test` whose test fails, exit 3;
  - `report_analysis_failed.json`: a `zig_module` named `std`, refused at
    analysis, exit 3;
  - `report_success.json`: a passing `zig_test`, exit 0.

  No report of an infrastructure error was captured. The cases hold every exit
  code other than 0 and 3 to INFRA, even next to a report that names the
  target as failed.
- `:report_unit` runs [`report_test.zig`](report_test.zig): the JSON read back
  field by field, and the pull request number of a merge subject.
- `:flake_unit` runs [`flake_test.zig`](flake_test.zig): the rerun flag's
  value, label versus pattern, the first failing line (the assertion, not a
  first line naming the run), the grouping of failing runs, the rate, the
  verdict (any failure is `flake`; a run that stayed INFRA makes "never
  failed" `inconclusive`), and both verdicts' JSON read back.
- `:main_unit` runs [`main_test.zig`](main_test.zig): the command line, both
  modes, and their refusals (no `--rev`, `--runs` 0, a pattern, the other
  mode's flags, a `--rerun-base` that would overflow).

**Scenarios.** Each scenario is one `bisect_scenario` target
([`defs.bzl`](defs.bzl)). [`testing/scenario.zig`](testing/scenario.zig) runs
it with the pinned git (`//third_party/git:git`) against `:bisect_unchecked`,
which is the same tool built behind the unit tests only.

The scenario builds a throwaway repository. Each candidate is a `--no-ff`
merge, `Merge pull request #<100+i>`, of a one-commit side branch. Each
commit's `bisect_fixture.txt` tells [`testing/fake_buck2.zig`](testing/fake_buck2.zig)
what to do there:

- `pass`;
- `fail <targets>`: a report in buck2's shape, exit 3;
- `infra-once`: exit 2 the first time;
- `infra-always`: exit 2 every time;
- `flaky <period> <phase> <targets>`: a listed target fails when the
  `komira.rerun` flag names it with an n where n % period = phase. Without
  the flag n is 0. Its stderr names the run on the first line and then
  always has the same assertion line;
- `infra-run <n>`, `infra-run-always <n>`: exit 2 for the build with
  rerun n, the first time or every time.

The stand-in logs every call in the repository's git directory, with the
rerun value and the targets of each build.

After every scenario, these must hold:
- `git worktree list` shows only the main worktree;
- `for-each-ref`, `HEAD` and `status --porcelain --ignored` are unchanged;
- no `probe-*` is left in the work dir;
- every probed commit is a first-parent commit, never a side-branch one;
- every build is followed by a `kill` in the same worktree;
- the probes' attempts add up to the builds without a rerun flag that the
  stand-in saw;
- in a scenario with no measurement, no build had a rerun flag;
- no commit is probed twice.

| scenario | what it proves |
|---|---|
| `culprit_middle` | 9 candidates, the culprit at c5: `first_bad` = c5 with its subject, `pr` = 105, `last_good` = c4, at most 1 + ⌈log₂ 9⌉ probes, the excerpt is c5's failing stderr, exit 0 |
| `culprit_first` | the culprit is c0: `last_good` is good |
| `culprit_last` | the culprit is bad itself |
| `two_culprits` | c3 breaks `//t:a`, c6 also breaks `//t:b`: `first_bad` = c3, and `failures` lists `//t:a` alone |
| `flake` | bad (`flaky 5 3`) passes the recheck: one probe, verdict `flake`, exit 1, and `flake_runs` measured 5 runs at bad, 1 failure (any 5 consecutive n hold one n = 3 mod 5, whatever the base) |
| `infra_retried` | the first search probe (c3) is INFRA once: `attempts` = 2, PASS, and the culprit c5 is still found |
| `infra_boundary` | the culprit c5 is always INFRA: it is reported in `infra`, never as FAIL; verdict `inconclusive`, candidates c5 and c6, exit 3 |
| `good_not_ancestor` | good is on an unmerged branch: exit 2, buck2 never ran, no worktree made |
| `single_commit` | good is the parent of bad: one probe, `first_bad` = bad |
| `stdout_unwritable` | bisect's stdout is a file opened read-only: the search finds the culprit c4, writing the verdict fails, and bisect exits 5 (not 1, the flake code) with `bisect: tool error: NotOpenForWriting` on stderr |
| `flake_rate` | `bisect flake --runs 15 --rerun-base 0` of `//t:a` (`flaky 5 3`) and `//t:b`: `//t:a` 3 of 15, rate 0.2, `failing_runs` 3, 8, 13 in one excerpt group under `assertion failed: ...` although each run's first line differs; `//t:b` 0 of 15; exit 1 |
| `flake_never` | a target that never fails: 0 of 5, verdict `never_failed`, exit 0 |
| `flake_infra` | run 4 is INFRA once (retried and counted), run 8, a failing run, is always INFRA: 9 runs, 1 failure (run 3), `infra` lists run 8, 12 attempts; exit 1 |
| `flake_fresh_base` | `bisect flake` twice with the tool's own base: 1 failure in 5 each time, and no rerun value of the first recurs in the second |

In each measuring scenario the stand-in must have seen, for every target,
builds of that target alone whose flag names it, as many as its
`attempts`, with exactly K distinct n, all in base+1..base+K.
