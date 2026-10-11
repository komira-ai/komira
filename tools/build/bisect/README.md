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
2. **It builds bad again.** If the targets pass, the verdict is `flake` and
   nothing more is built.
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

## Command line

```
bisect --good <rev> --bad <rev> --work-dir <dir> [--repo <dir>] [--verb build|test]
       [--buck2 <path>] [--git <path>] [--copy <relpath>]... [--submodules]
       [--buck2-arg <arg>]... [--timeout-s <n>] -- <target>...
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

Configuration is flags only. bisect reads no environment variable of its own.

## The verdict

```json
{"verdict":"culprit","good":"<sha>","bad":"<sha>","targets":["//a:b"],
 "first_bad":{"commit":"<sha>","subject":"Merge pull request #N from ...","pr":N},
 "last_good":"<sha>",
 "probes":[{"commit":"<sha>","role":"recheck","outcome":"FAIL","attempts":1,
            "buck2_exit":3,"failed_targets":["//a:b"],"seconds":12}],
 "failures":[{"target":"//a:b","excerpt":"..."}],
 "infra":[{"commit":"<sha>","buck2_exit":2,"excerpt":"..."}]}
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

| exit | meaning |
|---|---|
| 0 | culprit found |
| 1 | flake: bad passes now |
| 2 | usage error |
| 3 | inconclusive |
| 4 | a git or worktree command failed |

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
- `:main_unit` runs [`main_test.zig`](main_test.zig): the command line and its
  refusals.

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
- `infra-always`: exit 2 every time.

The stand-in logs every call in the repository's git directory.

After every scenario, these must hold:
- `git worktree list` shows only the main worktree;
- `for-each-ref`, `HEAD` and `status --porcelain --ignored` are unchanged;
- no `probe-*` is left in the work dir;
- every probed commit is a first-parent commit, never a side-branch one;
- every build is followed by a `kill` in the same worktree;
- the probes' attempts add up to the builds the stand-in saw;
- no commit is probed twice.

| scenario | what it proves |
|---|---|
| `culprit_middle` | 9 candidates, the culprit at c5: `first_bad` = c5 with its subject, `pr` = 105, `last_good` = c4, at most 1 + ⌈log₂ 9⌉ probes, the excerpt is c5's failing stderr, exit 0 |
| `culprit_first` | the culprit is c0: `last_good` is good |
| `culprit_last` | the culprit is bad itself |
| `two_culprits` | c3 breaks `//t:a`, c6 also breaks `//t:b`: `first_bad` = c3, and `failures` lists `//t:a` alone |
| `flake` | bad passes again: one probe, verdict `flake`, exit 1 |
| `infra_retried` | the first search probe (c3) is INFRA once: `attempts` = 2, PASS, and the culprit c5 is still found |
| `infra_boundary` | the culprit c5 is always INFRA: it is reported in `infra`, never as FAIL; verdict `inconclusive`, candidates c5 and c6, exit 3 |
| `good_not_ancestor` | good is on an unmerged branch: exit 2, buck2 never ran, no worktree made |
| `single_commit` | good is the parent of bad: one probe, `first_bad` = bad |
