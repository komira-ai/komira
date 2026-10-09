# The staged pipeline: build once, then beta, gamma and prod, each one run at a time

Status: design, not built. **EXISTS** names code on `main`; everything else is PROPOSED. New names
(all absent from `main`): the stage `beta`, the jobs `beta` and `beta_install`, the step kind `TEST`,
the step field `checks`, the outcome `SUPERSEDED` (as a successful stop), the job output `superseded`,
the step name `superseded`, the `main_red` decision `stalled`, rules R23 and R24. Related: continuous
publish (`docs/design/continuous_publish.md`, open in #1168), [ci.md](../ci.md),
[release machines](release_machine.md), [gamma validation](gamma_validation.md).

## The ruling, and what changes

The project owner's ruling: publishing is continuous, through three stages, **beta → gamma → prod**.

1. Each commit is built **once**; every stage promotes **the same files** (the same sha256 digests).
2. Each stage runs **at most one run at a time**.
3. While a stage is busy, newer commits on `main` stack up; the next run takes the **latest**. Older
   pending runs are **superseded**, never run on their own.
4. A stage promotes only after **its own checks** pass.

**Today (EXISTS).** One run per push carries the whole chain `build → gamma → validate → prod`
(`.github/workflows/kci.yml`). The **workflow-level** group `kci-release-main` serialises whole runs:
the newest pending *run* waits for the previous run to finish **prod**. Rule R16 of
`src/kci_workflow_check` requires that group and refuses a job-level `concurrency:`, for a reason this
doc must answer (`auto_promotion.mojo`, R16): "a job-level group's pending replacement could drop a
prod job". Rules 1 and 4 already hold (the set hash, R19); rules 2 and 3 hold for the pipeline as a
whole, not per stage: a fast `build` waits for a slow `prod`, and pausing prod stalls gamma too.

**Relation to continuous publish (#1168).** #1168 stays as written. This doc **supersedes** three
parts of it: "Trigger: per merge, coalesced" (one run per push, coalesced as a whole), the "within one
release duration" arithmetic, and the **placement** of its two gates in "The gate between gamma and
prod": S10c's release checks move from `build` into beta's `checks`, and S12's installed-bytes checks
from gamma's `validate` to `beta_install`, so both run **before** anything is published. Everything
else in #1168 stands. Merge order: **#1168 first, then this doc**; the two do not conflict, and the
index row below says which sections this doc overrides. P4 rewrites ci.md's "Queued runs" and "Never
backward", which today describe prod only.

## a. Where the build-once files live, and how each stage proves it has them

**Decision: one workflow run carries all four stages, so the files stay a workflow artifact of that
run.** `build` uploads `kci-release-<revision>` and every later job downloads it by name, scoped to
the current run (another run's artifact needs `actions: read`, which R4 grants no release job).

**The proof is kci's set hash, at every stage.** `--release-set-hash` makes kci recompute the release
directory's set hash and refuse another one, `KCI-E-SET-HASH`, exit 3, before any effect
(`src/kci_cli/dispatch.mojo`, step 4b). **Today step 4b runs only for a run that selects a PUBLISH
step or a validation** (dispatch.mojo:76-84); `beta` runs `--only step:e2e`, a `TEST` step, so P3
**extends 4b to a run that selects a TEST step**, with the flag required under Actions as for the
others. The hash is handed job to job and never typed (R19): `build`'s `set_hash` → `beta` and
`beta_install` → `beta_install`'s `validated_set_hash` → `gamma` and `validate` → `validate`'s
`validated_set_hash` → `prod`. kci writes a validated hash only when every selected validation
VALIDATED and SUCCEEDED. Installs are pinned to the release's version, build string and sha256
(`src/kci_validate/readback.mojo`, check 2).

**Retention.** `kci-release-*` is kept 14 days (`kci.yml`). A run whose prod waits longer fails to
download and goes red; it never publishes other bytes. Recommendation: 30 days (question 3).

**Rejected: a staging bucket or a private channel**: a cloud credential, new trust and spend, for
nothing while the stages share a run.

**Beta is not a channel**: nothing is uploaded. `build` also writes the local channel index of the
release directory (`komira_pack conda-index`), and beta installs from it. `--channel` stays refused
under Actions and by R14: beta gets its local channel from its step kind, not a flag.

## b. One run at a time per stage, and why the latest wins

GitHub's concurrency documentation: in a group at most one job runs; a newer arrival cancels the
**pending** one and takes its place; groups ignore case; FIFO by the time each started waiting, "not
guaranteed"; `queue: max` keeps up to 100 pending.

**Exclusion (rule 2): one workflow, no workflow-level group, a job-level group on every release
job**, `cancel-in-progress: false`, no `queue` key (`queue: max` would run every commit). A push to
`main`: `kci-<job id>-main`; a manual dry run: `kci-<job id>-plan-<run id>`; any other manual run:
`kci-<job id>-ref-<ref name>`, except as question 2 proposes for gamma's publish.

**The hazard R16 names, stated.** GitHub keeps the newest **arrival**, not the newest **commit**. An
older arrival cancels a newer pending job, and nothing brings the newer one back. Three paths deliver
an older arrival: (i) a re-run of any job of an old push run, which joins `kci-<job>-main`; (ii) two
pushes close together reaching `build` in reverse order (FIFO "not guaranteed"); (iii) a human
cancel. With a group per stage nearly every stage has a pending job, so the window is wider than
today's one workflow-level slot. Never-backward (c) stops the channel going backwards; it does not
release the cancelled commit. **Groups alone cannot hold rule 3.** Four parts do:

1. **Order for live runs.** `build` is a single slot, each later stage is a single slot fed by the
   previous stage's completions, so after `build` arrivals follow push order and the pending slot
   holds the newest. A running job is never cancelled: throughput is the slowest stage's.
2. **Admission (R24, new).** Every release job's first kci action fetches `main` (anonymous) and
   counts the commits after `REVISION` a push would release (the count `the prod line` uses today,
   excluding `docs/**` and `**.md`). On a **re-run** (`github.run_attempt` > 1) of a push run, a
   revision that is not main's releasable tip stops `SUPERSEDED` before any effect. So a re-run of
   an old run never promotes anything, at any stage; a first attempt proceeds (it is the newest that
   reached this stage).
3. **The line on every stage.** `the prod line`'s "main is at `<tip>`, past `<revision>`" moves into
   every release job's last step (R20), success or failure, so each stage's summary names a newer
   commit it did not carry.
4. **Repair (P2).** `release/ci/main_red.py` runs on every completed kci run (`workflow_run`,
   `completed`). New decision `stalled`: a push run that concluded `cancelled`, with
   `run_attempt == 1`, whose `head_sha` is main's releasable tip **now**, and no other kci run of
   that `head_sha` queued, waiting or in progress (the runs list; `main_red` holds `actions: read`).
   That is exactly the case (i) to (iii) leave: the tip dropped and nothing carrying it. `main_red`
   then **re-runs that run** (it becomes attempt 2, the tip, so R24 admits it), once; a second loss,
   or no `actions: write` (question 6), opens an issue naming the run to re-run. A human cancel of
   the tip is therefore undone: the way to hold a release is prod's required reviewer, not a cancel.

With 1 to 4 a dropped tip is re-queued without a human, an old run never promotes, and every stage
says when main moved past it. Pausing prod should hold only the prod group (P0 proves it).

**Rejected: separate workflows chained by `workflow_run`.** It fires only from the default branch
(no break-glass), allows three levels (`main-red` would be a fourth and never run), sets
`GITHUB_SHA` to the default branch's last commit (R21's check has nothing to hold), moves the
artifact across runs (`actions: read`, refused by R4), and would re-register both trusted
publishers, which name `kci.yml` (ci.md).

## c. Ordering safety: nothing older after something newer

**Rule: a stage refuses to promote a revision older than what it already promoted.** Mechanism:
extend "Never backward" (ci.md; `superseding_files` and `backward_files` in
`src/kci_publish/plan.mojo`) from prod to every push stage. Today it is per stage:
`req.never_backward = not stage.break_glass` (`src/kci_cli/dispatch.mojo:418`), so gamma has neither
refusal. Proposed:

- **gamma and prod:** `never_backward` is a property of the **run**: true on a push to `main`, false
  on break-glass. At gamma the listing is read over **main-line builds** only: files whose
  `h<8 hex>` resolves to a commit on `origin/main`'s history (an ambiguous prefix counts as
  main-line, the side that refuses rather than ignores). A break-glass build of a branch is reported
  and does not stall `main`.
- **beta** reads gamma's listing anonymously and stops if gamma already holds a main-line build that
  supersedes this revision, before any index, install or farm action.
- **Two outcomes, split by history.** The channel's newest main-line build **descends from** the
  revision: `SUPERSEDED`, exit 0, nothing uploaded or run, output `superseded=true`, later jobs skip
  (R23). History **unrelated**: `REFUSED`, `KCI-E-SUPERSEDED`, exit 3, red, as today.
- **This is a new history read, not reuse.** Today kci reads only `git rev-list <revision>` (is the
  channel's newest **on** this revision's history; `backward_files`). `SUPERSEDED` asks the inverse:
  resolve the newest build's `h<8 hex>` to one commit (`git rev-parse --verify`), then ask whether the
  revision is on **its** history (`git merge-base --is-ancestor`). A prefix that is unknown or
  ambiguous, or a shallow history, is INDETERMINATE, `KCI-E-CANNOT-TELL`, exit 5 (the existing path),
  never a pass. P1 builds it.

**Planted tests (`src/kci_publish/tests/test_publish_never_backward.mojo`, kci_cli dispatch tests).**
Each names the mutant that turns it red.

| # | case | expect | today | mutant caught |
|---|---|---|---|---|
| 1 | push run at gamma, newest listed build names a descendant | `SUPERSEDED`, exit 0, zero uploads | red (gamma uploads) | restore `not stage.break_glass` |
| 2 | gamma listing also holds a higher-numbered off-`main` build | publishes | green; guards the filter | count every build |
| 3 | gamma, unrelated history | `REFUSED`, exit 3 | red at gamma; regression at prod | split by number only |
| 4 | beta, fake gamma listing ahead | `SUPERSEDED` before any index, install or farm call | red | skip the read |
| 5 | gamma, newest build's prefix ambiguous between a main and an off-main commit | counted main-line: refused or superseded, never published | red | treat ambiguous as off-main |
| 6 | descendant check on an unknown prefix or shallow clone | exit 5 | red | default to SUPERSEDED |
| 7 | push re-run (`run_attempt` 2) of a non-tip revision, every stage | `SUPERSEDED` before any effect | red | drop R24's check |
| 8 | the same re-run of the releasable tip (only docs after it) | proceeds | red | compare to the raw tip |

## d. What "superseded" looks like, and what `main_red.py` reads

- **Replaced while pending:** the job is cancelled ("Canceling since a higher priority waiting
  request ... exists"), its dependants skip. The run's conclusion is expected to be `cancelled`, which
  `classify` ignores (`main_red.py:77`, `RED`; 282-289). P0 proves the conclusion before P2 relies on
  it.
- **Stopped as `SUPERSEDED`:** exit 0, so the job concludes `success`; job **outputs are not in the
  REST API**, so the signal is a **step**: every release job carries a step named exactly
  `superseded`, run only when kci's output says so (`if: steps.<run>.outputs.superseded == 'true'`).
  The jobs list `main_red.py` already reads (`/attempts/N/jobs`, :366) carries each job's `steps[]`
  with name and conclusion. R23 pins the step's name and condition.
- **Every place `main_red.py` reads success**, changed in P2: `classify` (:282, called at :458) takes
  the run's jobs: green only when job `prod` concluded `success` and its step `superseded` did not
  run; `last_green` (:176), fed from the `status=success` runs list (:344), keeps only candidates
  `classify` calls green (one jobs read per candidate, within the existing 30); `decide_green` (:300)
  and the close path use the same `classify`, so a superseded run never closes an issue as "Fixed".
  `stalled` (b.4) is the fourth decision.
- **The record of a superseded commit** is the run that carries it: each publishing stage's summary
  lists the commits between the channel's previous build and this one ("carried").

**Planted tests (`release/ci/main_red` tests):** (a) a `success` run whose `prod` skipped: ignore;
(b) `prod` `success` with step `superseded` `success`: ignore (mutant "green iff prod succeeded"
turns it red); (c) a newer superseded success run ahead of the true last green: `last_green` returns
the older (mutant "trust the success list" red); (d) `stalled`: tip cancelled, nothing active →
re-run; tip cancelled with a queued run of the tip → nothing; cancelled non-tip → nothing;
`run_attempt` 2 → issue, no re-run (mutant "drop the attempt cap" red).

## e. Beta's checks: the end-to-end suites, and the built files installed

**On the farm (the `beta` job):** a `TEST` step runs **`buck2 test`** over `checks:
"//src/tests/e2e/..."`, a pattern, so a new suite joins with no edit. `buck2 test` builds first, so
welded tests run too, and it runs the standalone `mojo_test`s a build never runs (`broker_e2e` holds
only one; `komira_shuffle_e2e` and `komira_tls_interop_e2e` hold some). Today the pattern covers 11
test-only packages, none in `release/artifacts.textproto`, none run by a release today. The
MinIO-backed `komira_job_supervisor/tests/e2e` exits 77 without its flag, a skip that cannot fail,
so it stays out until it cannot skip.

**The suite can go red (P3).** A kci test pins the step's command: verb `test`, the `checks` pattern
(mutant `build` red). A planted-red draft PR, never merged, adds a failing welded test and a failing
standalone `mojo_test` under `src/tests/e2e`, and the PR check
(it runs `./buck2 test`, ci.md) must go red on each; that proves the suites fail under the verb beta uses.

**Zero spend** rests on what can be enforced: `beta`'s environment holds no secret and no cloud
credential, so a suite that reached a cloud would be unauthenticated. "No suite opens a socket off
loopback" is an **audit** (P3's first task), not a check; a grep today finds only signature-test
strings.

**Tying the source suites to the built files.** The `TEST` step compares, for every released library
the suites build, buck2's payload sha256 with `payload_sha256` in the release's `metadata.json`
(`tools/build/package/conda.bzl`), and refuses a mismatch before running anything. **Risk:** the
suites build libraries in their own configuration, the release builds `<lib>_conda[release]`; if
those payloads differ, beta is red forever (safe, but it blocks every release). **P3's second task**
builds both on the farm on a real tree (a build, no run, nothing uploaded) and records the digests.
If they differ, the `TEST` step builds the suites in the release's configuration; if that cannot be
done, P3 stops, the comparison is withdrawn, and the claim narrows to "the suites passed on this
revision's source; `beta_install` checked the built bytes", which returns to the project owner.

**On a hosted runner (`beta_install`, no environment, no token):** the existing `CONDA_INSTALL_ENV`
validations install from beta's local channel with the pinned pixi and run every installed README.
Split from `beta` as `validate` is from `gamma`: an install runs third-party code, `beta` holds the
farm's identity token. #1168's S12 checks land here.

## f. The machine file, the environments, the workflow rules

```text
stage {
  name: "beta"
  after: "build"
  farm_connected: true
  break_glass: true
  step {
    name: "e2e"
    kind: TEST                       # NEW: `buck2 test` over `checks`; writes no release directory
    platform: "linux-x86_64"
    artifacts: "release/artifacts.textproto"
    checks: "//src/tests/e2e/..."    # NEW field (#1168 S10c's, on a TEST step)
    validation { name: "install-komira-encoding" kind: CONDA_INSTALL_ENV install: "komira_encoding" ... smoke: README }
    validation { name: "install-set" kind: CONDA_INSTALL_ENV install: "komira_all" ... smoke: README }
  }
}
```

`gamma`'s `after` becomes `"beta"`; prod is unchanged. `kci_release_machine` refuses a `TEST` step
with neither `checks` nor validations, and `checks` on any other kind.

| stage | job(s) | environment | token | runs on |
|---|---|---|---|---|
| build | `build` | `build` | farm | farm |
| beta | `beta` (`--only step:e2e`), `beta_install` | `beta`; none | farm; none | farm; hosted |
| gamma | `gamma` (publish), `validate` | `gamma` / `gamma-breakglass`; none | OIDC; none | hosted |
| prod | `prod` | `prod` | OIDC | hosted |

`beta` is a new environment; whether a `beta` subject joins the farm is read from the farm's trust
policy (P0, a read).

**Workflow rules (`src/kci_workflow_check`):**

- **R16, rewritten:** no workflow-level `concurrency:`; every release job a job-level one, exactly
  `group: kci-<job id>-<canonical suffix>`, `cancel-in-progress: false`, no `queue`.
- **R23, new:** every job of a stage with an `after` carries the conjunct
  `needs.<J>.outputs.superseded != 'true'` (J: the job R19 reads its hash from), J declares the
  output, and every release job has the step `superseded` with R23's exact `if:`.
- **R24, new:** every release job's first `kci` invocation runs with the admission check (b.2).
- **R19** for beta: gamma's hash is `needs.beta_install.outputs.validated_set_hash`, never
  `needs.beta.outputs.set_hash`. **R20**'s last step carries the "main is at" line on every job.
  R9, R11 and R14 need no change.

## g. Slices

Each slice: the check that is red before it. **Go** marks a project-owner action.

| # | slice | red before | go |
|---|---|---|---|
| P0 | **Probe** on a `probe/*` branch: a workflow of hosted jobs that only `sleep` and `echo`, `permissions: {}` (one job `actions: write` on its own run), no secret, no farm, no cloud, no upload, plus a `probe-wait` environment with a required reviewer. It records, from the runs API: (a) the run conclusion when a job is replaced in its group; (b) a job waiting on a reviewer holds only its group, and whether a newer arrival replaces it; (c) a job skipped by `if:` takes no group slot; (d) a re-run attempt joins the same group and downloads attempt 1's artifact; (e) a token-requested re-run of a cancelled run starts. Plus a read of the farm's trust policy for a `beta` subject. Existing runs cannot show (a) to (e): today's `kci.yml` has only the workflow-level group (line 202). | each fact written here with the run's URL, or P2 and P4 stop | **Go**: it starts workflow runs and creates an environment |
| P1 | kci: `never_backward` per run; main-line filter; the descendant read and `SUPERSEDED` (exit 0, output `superseded`); R24's admission check; gamma's "carried" list | c's table, rows 1 and 3 to 8; row 2 guards | none |
| P2 | `main_red.py`: `classify` from jobs and the `superseded` step; `last_green` filtered; `stalled` and its re-run | d's tests (a) to (d) | the re-run needs question 6 |
| P3 | Tasks: the loopback audit; the payload digests on a real tree (e). kci: `TEST`, `checks` (`buck2 test`), beta's read of gamma's listing, step 4b for TEST, the payload comparison, validations from the handed local channel; `build` writes the local index | machine fixtures (TEST with neither; `checks` on PUBLISH) refused; c row 4; a TEST run with a mismatched `--release-set-hash` refused exit 3 with zero runner calls, and without the flag under Actions exit 2 (mutant: 4b without TEST), copying the prod case at `test_kci_ref_check.mojo:542-554` for beta, gamma and validate; a planted payload mismatch refused; the command pinned to `test`; the planted-red draft PR. Regression (green before, mutant named): a local-channel record with another sha256 refused (mutant: skip the compare in `conda_install_env.mojo`) | none |
| P4 | The switch, one PR: `release/machine.textproto` with beta; `kci.yml` with job groups, `beta`, `beta_install`, the `superseded` steps, R23/R24 guards and the line on every job; R16, R23, R24 in `kci_workflow_check`; ci.md's "Queued runs" and "Never backward" rewritten for every stage | fixtures refused: a workflow-level group, a job without a group, `queue: max`, a job missing R23's conjunct or step, gamma reading `beta`'s unvalidated `set_hash` (R19), a job without R24; today's `kci.yml` fails the new R16 | **Go**: changes the release; the first push creates `beta` and spends farm time |
| P5 | Retention of `kci-release-*` to the ruled value | none (a setting) | **Go** with question 3 |
| P6 | #1168 S10c's derived checks join beta's `checks`; S12's join `beta_install` | as #1168 states them | as #1168 |

P1, P2 and P3 merge on their own and change nothing that runs (P1 changes only what a push to gamma
may do when the channel is ahead; P2's `stalled` reads only push runs, which are unchanged until P4).
P4 depends on P0 to P3.

## h. Questions for the project owner

1. **Two jobs per stage (a departure from rule 2).** Beta (`beta`, `beta_install`) and gamma
   (`gamma`, `validate`) are two slots each: one job would put an install's third-party code next to
   the farm or publish token, and two jobs sharing one group would let one stage's second job cancel
   its own first job's pending newer run. So beta can test C while installing B. *Recommendation:*
   accept; each job is pinned to its own set's digests, so an overlap cannot check the wrong files.
2. **Break-glass runs and the push groups (a departure from rule 2).** Manual runs keep per-ref
   groups, so a break-glass run's build and beta can overlap a push run's, and its gamma publish can
   overlap main's: two writers to one channel, each checking the listing before it uploads.
   *Recommendation:* gamma's **publish** job joins `kci-gamma-main` in every non-dry run, one writer
   per channel; build and beta stay per ref (they write nothing shared). A break-glass arrival can
   then replace main's pending gamma; `stalled` (b.4) re-runs it.
3. **Retention.** *Recommendation:* 30 days; a longer pause fails the held run red, the next push
   carries its commits.
4. **Break-glass builds in gamma.** They share the channel and can out-number `main`; the main-line
   filter keeps them from stalling `main`, but a consumer installing "latest" from gamma gets the
   highest-numbered build, which may be a branch's. *Recommendation:* accept now; a separate
   break-glass channel later (an upload setting).
5. **The suites as a release gate.** One flaky suite blocks gamma and prod. *Recommendation:* gate,
   with #1168's re-run-once and quarantine-by-PR policy.
6. **`actions: write` for `main_red`'s repair.** Without it a dropped tip waits for a human click on
   the issue `stalled` opens. *Recommendation:* grant it to `main_red`'s job only, used for one
   re-run of a run whose head is main's releasable tip; it runs no pull-request code.
7. **P0's probe.** *Recommendation:* go; it spends only hosted minutes and touches no cloud.
