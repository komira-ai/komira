# The staged pipeline: build once, then beta, gamma and prod, each one run at a time

Status: design, not built. **EXISTS** names code on `main`; everything else is PROPOSED. New names
(all absent from `main`): the stage `beta`, the jobs `beta` and `beta_install`, the step kind `TEST`,
the step field `checks`, the outcome `SUPERSEDED` (as a successful stop), the job output `superseded`,
the step name `superseded`, the `main_red` decision `stalled`, rules R23, R24 and R25, the validation
kind `BUCK2_TARGET` and its fields `target`, `cloud`, `identity`, `region`, `timeout_seconds` and
`attempts`, the directory `src/tests/real_cloud/`, gamma's validations `real-cloud-<cloud>` and the
slice G0, and prod passing `--release-set-hash` twice. Related: continuous
publish (`docs/design/continuous_publish.md`, #1168; a path, not a link, until both docs are on
`main`, since the doc links lint refuses a dead link; P4 makes it a link), [ci.md](../ci.md),
[release machines](release_machine.md), [gamma validation](gamma_validation.md).

## The ruling, and what changes

The project owner's ruling: publishing is continuous, through three stages, **beta → gamma → prod**.

1. Each commit is built **once**; every stage promotes **the same files** (the same sha256 digests).
2. Each stage runs **at most one run at a time**.
3. While a stage is busy, newer commits on `main` stack up; the next run takes the **latest**. Older
   pending runs are **superseded**, never run on their own.
4. A stage promotes only after **its own checks** pass.

**The ruling for gamma (revision 2; it replaces an earlier "bake 24 hours now").**

- **(A) No bake for now.** A 24-hour bake in gamma is the goal, but it is useful only once canaries
  and monitoring watch the candidate during it. It is a future stage, gated on its prerequisites
  ([Future: gamma bake](#future-gamma-bake), #1183).
- **(B) Gamma is single-flight:** one run at a time, the latest candidate wins (b). **Departure,
  for the project owner's ruling:** gamma is two slots, the `gamma` job (publish, then the
  real-cloud validations, e2) and the `validate` job (the two installs), and `validate` runs after
  `gamma` releases `kci-gamma-main`. So candidate N's installs can run while candidate N+1
  publishes and runs its real-cloud validations: two candidates are in gamma at once, for the
  length of one install. *Recommendation:* accept. Each job is pinned to its own set's digests,
  and prod refuses unless `gamma`'s `validated_set_hash` equals `validate`'s (R19 amended, e2), so
  the overlap can never promote a set that one of the two did not vouch for. Holding both jobs in
  one group is what question 1 rules out; questions 1 and 11 give the detail.
- **(C) Prod is promoted when every gamma validation has passed**, with no wait after it.
- **(D) Gamma's validations include real-cloud tests**, as ordinary kci validations of the gamma
  stage: Buck2 targets that kci runs with the `gamma` environment's federated (OIDC) cloud
  credential. A red one fails gamma. There is no override without the project owner's explicit
  go ([e2](#e2-gamma-real-cloud-tests-as-ordinary-validations)). **Prerequisite:** the `gamma`
  environment has no deployment-branch policy today, so gamma is locked to `main` (slice G0, a
  go) **before** any cloud trusts it.

**Today (EXISTS).** One run per push carries the whole chain `build → gamma → validate → prod`
(`.github/workflows/kci.yml`). The **workflow-level** group `kci-release-main` serialises whole runs:
the newest pending *run* waits for the previous run to finish **prod**. Rule R16 of
`src/kci_workflow_check` requires that group and refuses a job-level `concurrency:`, for a reason this
doc must answer (`auto_promotion.mojo`, R16): "a job-level group's pending replacement could drop a
prod job". Rules 1 and 4 already hold (the set hash, R19); rules 2 and 3 hold for the pipeline as a
whole, not per stage: a fast `build` waits for a slow `prod`, and pausing prod stalls gamma too.

**Relation to continuous publish (#1168).** #1168 stays as written, except for its two pointers to
this doc, at its trigger section and its rollback time. This doc **supersedes** three parts of it:
"Trigger: per merge, coalesced" (one run per push, coalesced as a whole), the "within one release
duration" arithmetic and the rollback time resting on it (restated at the end of b), and the
**placement** of its two gates in "The gate between gamma and
prod": S10c's release checks move from `build` into beta's `checks`, and S12's installed-bytes checks
from gamma's `validate` to `beta_install`, so both run **before** anything is published. Everything
else in #1168 stands. #1168 leaves real cloud accounts out of its own scope and holds no cloud
credential; e2 adds one, a federated trust of the `gamma` environment with no stored key, so
#1168's slice S0 (lock `gamma` to `main`) becomes this doc's first slice, G0, and must land
before that trust exists. #1168 points here for real clouds. Merge order: this doc's first version
(#1173) merged first, and #1168 is still open; the two do not conflict, so #1168 can merge before
or after this amendment, and the index row below says which sections this doc overrides. P4 rewrites ci.md's "Queued runs" and "Never
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
   excluding `docs/**` and `**.md`). In a push run, a revision that is not main's releasable tip
   stops `SUPERSEDED` before any effect in two cases: on a **re-run** (`github.run_attempt` > 1), at
   every stage; and on the **first attempt of `build`**. That closes path (ii): an older commit that
   reaches `build` after a newer one stops there and never runs a stage on its own. The newer run it
   replaced concluded `cancelled` and is repaired by `stalled` (4). A first attempt **after**
   `build` proceeds even when `main` has moved: by 1 it is the newest that reached that stage, and
   stopping it there would starve a stage whenever pushes come faster than the pipeline. The check
   at `build` costs one fetch; a revision is stopped there only if a newer releasable commit landed
   before its first kci action. That commit's own push run is then pending, cancelled (and so
   repaired, 4) or already ahead. **Or it has none:** GitHub creates no push run for a head commit
   whose message carries a skip marker (`[skip ci]` and its variants), and occasionally fails to
   create one. Then nothing carries the tip until the next push; `stalled` reports it (4).
3. **The line on every stage.** `the prod line`'s "main is at `<tip>`, past `<revision>`" moves into
   every release job's last step (R20), success or failure, so each stage's summary names a newer
   commit it did not carry.
4. **Repair (P2).** `release/ci/main_red.py` runs on every completed kci run (`workflow_run`,
   `completed`). New decision `stalled`: a push run that concluded `cancelled`, with
   `run_attempt == 1`, whose `head_sha` is main's releasable tip **now**, and no other kci **push**
   run of that `head_sha` queued, waiting or in progress (the runs list filtered by
   `event=push`; `main_red` holds `actions: read`). Only push runs count: a manual run of the same
   sha uses its own per-ref groups and never-backward off (c), so it does not carry main's release
   and must not hold the repair off. That is exactly the case (i) to (iii) leave: the tip dropped
   and nothing carrying it. `main_red` then calls
   **`POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs`**
   ("re-run all of the failed jobs and their dependent jobs"), **never** the full re-run
   `POST .../runs/{run_id}/rerun`, which would build the commit a second time and break rule 1.
   Attempt 2 is the tip, so R24 admits it; it re-runs only the cancelled job and its dependants,
   and reads `build`'s outputs (`set_hash`) and the `kci-release-<revision>` artifact from the
   first attempt. GitHub's docs do not say whether "failed" includes **cancelled**, nor that a later attempt
   reads an earlier attempt's `needs` outputs; P0 (e) records both. If cancelled jobs are not
   re-run, `stalled` calls `POST .../actions/jobs/{job_id}/rerun` ("re-run a job and its dependent
   jobs") on the first cancelled job instead. When `build` itself was the job cancelled (path ii),
   re-running it is that commit's first build, so rule 1 still holds. GitHub allows a re-run only
   within **30 days** of the run and at most **50 re-runs** of one run; `stalled` re-runs once, and
   past 30 days it opens the issue instead. A second loss, or no `actions: write` (question 6),
   opens an issue naming the run and the endpoint. A human cancel of the tip is therefore undone:
   the way to hold a release is prod's required reviewer, not a cancel. **No push run of the tip:**
   when a push run whose `build` job ran its `superseded` step completes, and main's releasable tip
   has no kci push run in any state, there is nothing to re-run; `stalled` opens an issue naming the
   tip, which the next push to `main` releases. Before revision 3 the stopped older commit would
   have released instead; the admission check costs this delay, never a wrong release (question 8).

With 1 to 4 a dropped tip that has a push run is re-queued without a human (one without opens an
issue), an older revision never starts `build` after a newer one and a re-run of an old run never
promotes, and every stage says when main moved past it. Pausing prod should hold only the prod group
(P0 proves it).

**The arithmetic, restated (superseding #1168's).** A push to `main` that touches code reaches prod,
or is carried there by a newer commit, within one pass through the four stages plus at most one wait
per stage for the run already in it: at most two release durations, as before, and nearer one as the
stages overlap. A dropped tip adds the time until `stalled` runs; a tip with no push run waits for the
next push. The time to roll back is one PR check plus that bound. **Gamma is now the slowest stage:**
its job holds `kci-gamma-main` through its real-cloud validations (e2), so gamma takes at most one
candidate per pass and every commit that lands meanwhile coalesces into the next (rule 3). A
release duration therefore includes up to the gamma job's `timeout-minutes`, which the machine file
bounds at 330 minutes (e2, "Fits a hosted job").

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
| 9 | push first attempt at `build` of a non-tip revision (path ii) | `SUPERSEDED` before any effect | red | check re-runs only |
| 10 | push first attempt at `gamma` of a non-tip revision | proceeds | green; guards against starving a stage | check every first attempt |

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
re-run; tip cancelled and only `docs/**` or `**.md` commits after it → re-run (mutant "compare to
the raw tip" red); tip cancelled with a queued push run of the tip → nothing; tip cancelled with
only a manual run of the tip active → re-run (mutant "count every event" red); cancelled non-tip →
nothing; `run_attempt` 2 → issue, no re-run (mutant "drop the attempt cap" red); run older than 30
days → issue, no re-run; a run stopped at `build` and a releasable tip with no push run in any state
→ issue naming the tip, no re-run call (mutant "no run means nothing to do" red), and the same with
a push run of the tip in progress → nothing; (e) the re-run's request, on a fake runs API where attempt 1's `build`
succeeded and `gamma` was cancelled: exactly one call, to `.../runs/{id}/rerun-failed-jobs` (or the
per-job form P0 (e) selects), and no call to `.../runs/{id}/rerun` (mutant "full re-run" red).

## e. Beta's checks: the end-to-end suites, and the built files installed

**On the farm (the `beta` job):** a `TEST` step runs two commands over `checks:
"//src/tests/e2e/..."`, a pattern, so a new suite joins with no edit: **`buck2 build <pattern>`,
then `buck2 test <pattern>`**, the order the PR check uses (ci.md), the second only if the first
passed. Both are needed. The build README says "`buck2 test` on a `mojo_library` therefore runs
nothing; its tests run when the library (or anything depending on it) is built"
([tools/build/mojo/README.md](../../tools/build/mojo/README.md), "`test_srcs`, not `tests`"), and 8
of the e2e packages hold no `mojo_test` at all (only `broker_e2e`, `komira_shuffle_e2e` and
`komira_tls_interop_e2e` hold one or more). The build runs the welded tests; the test runs the
standalone `mojo_test`s a build never runs. Today the pattern covers 11
test-only packages, none in `release/artifacts.textproto`, none run by a release today. The
MinIO-backed `komira_job_supervisor/tests/e2e` exits 77 without its flag, a skip that cannot fail,
so it stays out until it cannot skip.

**The suite can go red, under beta's commands alone (P3).** A kci test pins the step's commands:
`build` then `test`, both over the `checks` pattern (mutants "drops the build" and "drops the test",
each red). The PR check cannot prove the rest: it runs the two verbs over the whole cell, not over
beta's pattern. So P3 runs a farm task (a scratch branch, never pushed for review, no workflow run)
that executes **exactly** beta's two commands, `./buck2 build //src/tests/e2e/...` then `./buck2
test //src/tests/e2e/...`, on two trees, each with **one** plant: (1) a failing assertion in a
welded `test_srcs` test of an e2e package with no `mojo_test`: the build must exit non-zero and name
it; (2) on a tree without (1), a failing standalone `mojo_test`: the build passes and the test must
exit non-zero and name it. The unplanted tree must pass both. Each tree also runs the command a
mutant keeps: tree (1) `./buck2 test` alone, tree (2) `./buck2 build` alone. Each is expected to
pass, which shows the dropped command is the one that catches that plant; if tree (1) goes red under
`test` alone instead, the README is wrong, the build is redundant but harmless, and the record says
so. The record quotes each command, its exit status and its `Commands:` line with `local: 0`. Two
trees, so one red cannot hide the other.

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

## e2. Gamma: real-cloud tests as ordinary validations

The project owner's ruling: the real-cloud tests are **ordinary kci validations of the gamma
stage**. They are Buck2 targets that kci runs with the `gamma` environment's federated (OIDC) cloud
credential; the gamma stage lists them as validations like its two installs, and a red one fails
gamma. Nothing outside this repository is asked or waited on. Gamma's validations become the two
installs `validate` runs (EXISTS) and one `real-cloud-<cloud>` validation per cloud.

**Prerequisite, first and a go: lock `gamma` to `main` (slice G0).** Today the `gamma` environment
has **no** deployment-branch policy and no protection rule (#1168, "How does a release run today?", and its
slice S0): any branch whose workflow names `environment: gamma` runs with gamma's identity. A cloud
trust keyed on the `gamma` environment would hand that branch the cloud. So G0, #1168's S0
unchanged (`gamma`'s deployment branches set to `main`, `gamma-breakglass` behind a required
reviewer with administrator bypass off, and the drift check in `build` that fails the release if
`gamma`'s policy is not `main` only), lands and its drift check is green **before** any cloud's
trust is created (G3's go). G0 is the project owner's go: it changes repository settings.

**What exists, and what is new.** No validation kind on `main` runs a Buck2 target:
`src/kci_api/verbs.mojo` names three, `CONDA_INSTALL_SMOKE`, `CONDA_INSTALL_ENV` and
`DEPLOY_PROBE`. release_machine.md describes those three and no other; ci.md's "Each validation
is a target" is the other direction, a `buck2 run //release/validations:<name>` target that wraps
`kci run --only validation:<name>` for a developer. So e2 adds a fourth kind, **`BUCK2_TARGET`**
(P7). It reuses what exists: `CONDA_INSTALL_ENV`'s child environment built from nothing
(`src/kci_validate/env.mojo`), the secret store `--secret-store env`, kci's own exchange of the
job's ID token (as it does for the channel's trusted publishing, ci.md), and the AWS SDK's web
identity source (`src/komira_aws_core/credential_chain.mojo`, step 3: `AWS_WEB_IDENTITY_TOKEN_FILE`,
`AWS_ROLE_ARN`, `AWS_ROLE_SESSION_NAME`).

**Where the targets live.** `src/tests/real_cloud/<suite>/`, one test-only package per suite, a
sibling of `src/tests/e2e/`, each a **`mojo_binary`**, never a `mojo_test` or a library with
`test_srcs`. That keeps them out of every run that holds no cloud credential: the pull request's
check builds them (so a suite that stops compiling is red on its PR) but `buck2 test` runs no
binary and a build runs no binary; beta's `checks` pattern is `//src/tests/e2e/...`, which does not
reach them. A lint (P8) refuses a `mojo_test`, or a target with `test_srcs`, under
`src/tests/real_cloud/`, since the pull request's check would run it with no credential, and
`kci_release_machine` refuses a `checks` pattern that reaches the directory.

**Built once, on the farm; run in gamma.** The `gamma` job runs on a hosted runner with no farm
and no Buck2 (R11: farm and tokens apart), so it builds nothing. `build` builds every
`BUCK2_TARGET` validation's `target` for `linux-x86_64`, as it builds kci itself, and puts each
executable and its sha256 in `kci-release-<revision>` (`validations/<name>/`). They are not
released artifacts: the set hash does not cover them, and they are never uploaded. The `gamma` job
refuses an executable whose sha256 is not the one `build` recorded. What the suites test is this
revision's **source**, as `build` built it; `validate`'s installs check the published bytes.

**How kci runs one (P7).** The `gamma` job's one `kci run` (R5) selects the publish step and every
validation of gamma's publish step that runs there: `kci run --stage gamma --only step:publish
--only validation:real-cloud-aws`. Then, for each `BUCK2_TARGET` validation:

1. **Start checks, before any effect,** with the run's other start checks: the run is a push to
   `main`; each `identity` and `region` secret name resolves to a non-empty value; the job can
   request an ID token (GitHub's request variables are present); each executable is present with
   `build`'s sha256. Any one missing is `REFUSED`, exit 2, and **nothing is published**: a set
   that cannot be validated is never put in gamma.
2. **Publish** (EXISTS).
3. **Exchange.** kci requests the job's ID token with the cloud's audience (`sts.amazonaws.com`
   for AWS), writes it to `<scratch>/<validation>/oidc/token`, mode 0600, and builds the child's
   environment **from nothing**, as `CONDA_INSTALL_ENV` does: `PATH`, `HOME`, `TMPDIR`, `LANG`,
   and the provider-standard variables the cloud's SDK reads (for AWS, `AWS_ROLE_ARN` from the
   `identity` secret, `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_SESSION_NAME` = `kci-<validation run
   id>`, `AWS_REGION` from the `region` secret). **Nothing else of the job's environment reaches
   the child:** in particular not GitHub's ID-token request variables, which could mint a token for
   any audience, the channel's publisher among them, and not `GITHUB_TOKEN`. The cloud credential
   is the only one the suite holds, it is short-lived and minted for this attempt, and no
   long-lived key exists anywhere.
4. **Run** the executable with flags, not variables, for what is not a credential:
   `--validation-run-id <id>` (stamped on every billable resource the suite creates, as kci's
   vocabulary requires of a validation), `--results <scratch>/<validation>/results.txt`. The
   suite's process group is killed at `timeout_seconds`.
5. **Verdict.** VALIDATED only when the process exits 0 **and** its results file lists every case
   as `PASS`. Any other exit status (77, the skip status of the e2e suites, included: a real-cloud
   suite cannot skip), a kill at the timeout, a missing or unreadable results file, or a case not
   `PASS` is FAILED. A credential that expires mid-suite fails the suite red, never green;
   `timeout_seconds` is capped at 3600 so a suite fits AWS's default one-hour role session.
6. **Re-run once** (#1168's flake policy). After a FAILED attempt kci runs the suite once more
   with a fresh token and a fresh validation run id; a second FAILED fails the validation. The
   re-run is kci's, inside the job, because a re-run of the `gamma` job would publish again. Once
   a suite needs its re-run twice in ten releases it gets an issue with an owner, as #1168 requires
   of every check; the run summary names each attempt and its result, which is what that count
   reads.
7. **Result.** kci writes `validated_set_hash` only when every selected validation VALIDATED (as it
   does today), and the `gamma` job hands it on as its output.

**Identifiers stay out of this repository.** The machine file names the role and region by
**secret name** (`identity: "KCI_GAMMA_AWS_ROLE"`), resolved by `--secret-store env` from secrets of
the `gamma` environment only, which the workflow passes on the `kci` step alone (R25). They are
secrets, not configuration variables, because this repository's job logs are public and GitHub
masks secret values in them, not variables. Masking covers only the exact value, and a resource
name a suite prints can carry an account number, so **kci never copies the suite's output to the
job log**: it keeps stdout and stderr in the scratch directory, deletes them with it, and prints
only the validation's name, each attempt's exit status and the results file's case names and
verdicts, whose names are fixed in the suite's source. A suite's owner debugs a red run by running
the target with their own credential. No account, project or subscription identifier, role name or
endpoint appears in the machine file, the workflow, a suite's source or a log.

**Which clouds.** AWS first: komira's AWS client already reads a web identity. GCP and Azure join
when their keyless identity lands (`external_account` in `komira_gcp_core`, a federated credential
in `komira_azure_core`; gamma validation decisions, item 4); until then the machine file holds no
`real-cloud-gcp` or `real-cloud-azure`, and `kci_release_machine` refuses a `cloud` kci cannot
exchange for.

**The cloud's trust, scoped to `gamma`.** Each cloud trusts this repository's OIDC issuer for the
subject `repo:<owner>/<repo>:environment:gamma` exactly, and the cloud's audience. After G0 only a
job of a `main` run can hold that subject. `gamma-breakglass`, `beta`, `build`, `prod` and the pull
request's check carry other subjects (or no environment, and no ID token), so no trust accepts
them. The trust is created by the project owner, outside this repository, as a bootstrap (kci never
holds standing access). The `gamma` job also holds the channel's trusted-publisher token: the two
share one job because both need the `gamma` environment's subject. That departs from gamma
validation decisions item 4's recommendation of a separate `gamma-cloud` environment; the ruling
names gamma's own credential, and step 3's environment from nothing is what keeps the suite from
reaching the publisher's token (question 9).

**Cost.** Zero-spend guards (e) do not apply: by the ruling this stage spends real money. kci
bounds only time (`timeout_seconds`, `attempts`, the job's `timeout-minutes`) and, by single
flight, runs at most one candidate's suites at a time. The spend itself is bounded by **each
suite's own teardown** (it deletes what it created, every resource stamped with the validation run
id so a sweep can find a leak) and by **budget alerts on the test accounts**, both owned by the
**suites' owner**, who is named in each suite's README; question 10 asks who that is.

**Where it runs: in the `gamma` job, after the publish.** The job keeps its job-level group
`kci-gamma-main` (b) for the whole run of its validations, so the `gamma` job is single-flight
through them (B): while they run, a newer commit's gamma job is pending, a still newer one
replaces it, and the running one is never cancelled. The `validate` job runs after it, in its own
slot, so one candidate's installs can overlap the next candidate's publish; that is the departure
stated under (B). The suites cannot run in `validate`: a part job holds no environment and no ID
token (R9), and `validate` runs the installs' third-party code, which must never sit beside a cloud
credential. A third job in the same group would let the stage cancel its own pending newer run
(question 1).

**Prod (C).** `prod` already `needs: [gamma, validate]`, so a red `gamma` job skips prod. That is
not enough on its own: R19 is amended so that prod passes **two** `--release-set-hash` values,
`needs.gamma.outputs.validated_set_hash` and `needs.validate.outputs.validated_set_hash`, and kci
refuses before any effect unless each equals the release directory's recomputed set hash (an empty
value exit 2, as today; a different one `KCI-E-SET-HASH`, exit 3). Prod publishes when, and only
when, every gamma validation has vouched for the same set. Nothing waits after that (A).

**Fits a hosted job.** GitHub's documented limit: "Each job in a workflow can run for up to 6 hours
of execution time" on a GitHub-hosted runner (GitHub Actions limits). The `gamma` job's worst case
is its publish (today's `timeout-minutes: 30`) plus, for each `BUCK2_TARGET` validation,
`attempts` × `timeout_seconds`. `kci_release_machine` refuses a gamma stage whose sum passes 300
minutes, so the job's `timeout-minutes`, which R25 pins to exactly 30 plus that sum, is at most
330, under the 360 the platform allows.

**Break-glass, pull requests, beta and dry runs.** Break-glass never reaches prod (EXISTS). A
break-glass gamma run does not select a `BUCK2_TARGET` validation, and kci refuses one named by
`--only` on it (exit 2): its environment, `gamma-breakglass`, holds none of the secrets and its
subject matches no trust, so the suite could only fail, and a break-glass build is judged by its
operator, not promoted. The pull request's check and beta never select one (the kind is refused on
a stage without an environment or with `farm_connected`, and the targets are binaries no `buck2
test` runs). A dry run (`--plan`) prints `WOULD_VALIDATE`, requests no token and runs nothing.

**After a red.** Gamma fails and nothing promotes. There is no flag, input or reviewer that lets
prod pass a red, absent or stale validation; a release past one is the project owner's explicit
go, carried out as a revert or fix on `main` (question 12).

**Planted tests (`src/kci_validate/tests/` and `src/kci_cli/tests/`, with fake suites: small
`mojo_binary` fixtures that exit with a scripted status, write a scripted results file, sleep, or
print their environment; a fake ID-token endpoint; no cloud).** Each names the mutant it catches.

| # | case | expect | mutant caught |
|---|---|---|---|
| 1 | the suite exits 1 | FAILED after two attempts; no `validated_set_hash`; the job red | exit status ignored |
| 2 | the suite exits 0, its results file lists one case `FAIL` | FAILED | exit status alone decides |
| 3 | the suite exits 0 and writes no results file | FAILED | absent results count as a pass |
| 4 | the suite exits 77 | FAILED, not skipped | 77 treated as a skip |
| 5 | the suite sleeps past `timeout_seconds` | killed, FAILED, its process group gone | no timeout; kill the parent only |
| 6 | first attempt red, second green | VALIDATED, exactly two runs, two token requests, two run ids | no re-run; the token reused |
| 7 | both attempts red | FAILED, exactly two runs | unbounded re-runs |
| 8 | every case `PASS`, exit 0 | VALIDATED, `validated_set_hash` written | guard (green before and after) |
| 9 | a push run whose `identity` secret does not resolve, or is empty | `REFUSED` exit 2, zero uploads, zero suite runs | check after publish |
| 10 | a push run with no ID-token request variables | `REFUSED` exit 2, zero uploads | check the secrets only |
| 11 | the executable's sha256 differs from `build`'s | refused before publish, zero suite runs | skip the compare |
| 12 | the suite prints its environment | only the named variables; no ID-token request variable, no `GITHUB_TOKEN`, no other secret | inherit the job's environment |
| 13 | the suite prints the `identity` value and an account-shaped number to stdout and stderr | neither appears in the job log or the summary; case names and verdicts do | copy the suite's output to the log |
| 14 | the token file | mode 0600, audience the cloud's; requested after the publish, never before | mint at start; world-readable file |
| 15 | prod with gamma's hash absent | exit 2, zero uploads | prod reads `validate`'s hash only |
| 16 | prod with gamma's hash unequal to the set | `KCI-E-SET-HASH`, exit 3, zero uploads | compare one of the two hashes |
| 17 | a break-glass gamma run | the suite not selected; with `--only validation:real-cloud-aws`, exit 2 | select on every run |
| 18 | `--plan` on a push run | `WOULD_VALIDATE`, zero token requests, zero suite runs | run under `--plan` |
| 19 | machine fixtures: `BUCK2_TARGET` on beta (`farm_connected`), on a stage without an environment, in a part job's validations, with `timeout_seconds` 3601, `attempts` 0 or 3, a `cloud` with no exchange, a gamma sum of 301 minutes; a `checks` pattern reaching `src/tests/real_cloud/` | each refused | one refusal per mutant |
| 20 | lint fixture: a `mojo_test` under `src/tests/real_cloud/` | refused, as is a library with `test_srcs` there | the lint checks one of the two forms |

## f. The machine file, the environments, the workflow rules

```text
stage {
  name: "beta"
  after: "build"
  farm_connected: true
  break_glass: true
  step {
    name: "e2e"
    kind: TEST                       # NEW: `buck2 build`, then `buck2 test`, over `checks`; no release directory
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

Gamma's publish step gains one validation per cloud (e2); the two installs are unchanged:

```text
validation {
  name: "real-cloud-aws"
  kind: BUCK2_TARGET                  # NEW: run an executable `build` built (e2)
  target: "//src/tests/real_cloud/<suite>:<suite>"   # a mojo_binary under src/tests/real_cloud/
  cloud: AWS                          # which federated exchange kci makes
  identity: "KCI_GAMMA_AWS_ROLE"      # secret NAMES, resolved by --secret-store env from
  region: "KCI_GAMMA_AWS_REGION"      # the gamma environment; never a value in this file
  timeout_seconds: 3600               # the suite's process group is killed at this
  attempts: 2                         # one re-run
}
```

`kci_release_machine` refuses `BUCK2_TARGET` on a stage without an environment, on a stage with
`farm_connected`, in a part job's validations (R9: no environment there), on any step but a
PUBLISH step; a `target` outside `//src/tests/real_cloud/`; a `cloud` kci cannot exchange for
(AWS only, until GCP and Azure have keyless identity); `timeout_seconds` above 3600 or below 1;
`attempts` above 2 or below 1; a gamma stage whose sum of `attempts` x `timeout_seconds` passes 300
minutes; and a `checks` pattern that reaches `src/tests/real_cloud/`.

| stage | job(s) | environment | token | runs on |
|---|---|---|---|---|
| build | `build` | `build` | farm | farm |
| beta | `beta` (`--only step:e2e`), `beta_install` | `beta`; none | farm; none | farm; hosted |
| gamma | `gamma` (publish, then the `real-cloud-<cloud>` validations on a push), `validate` | `gamma` (its subject alone is trusted by the clouds; holds the identity secrets) / `gamma-breakglass` (holds neither, trusted by no cloud); none | OIDC (channel and clouds); none | hosted |
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
- **R19, amended for prod (e2):** prod's `kci run` passes `--release-set-hash` twice, exactly
  `needs.gamma.outputs.validated_set_hash` and `needs.validate.outputs.validated_set_hash`; kci
  refuses either one unequal to the recomputed set hash. The `gamma` job declares the output.
- **R4** needs no change: the `gamma` job already holds `id-token: write`, and no release job gains
  another permission.
- **R25, new:** the `gamma` job's `timeout-minutes` is exactly 30 plus the machine file's sum of
  `attempts` x `timeout_seconds` over gamma's `BUCK2_TARGET` validations (at most 330); on a push
  its `kci run` selects every one of them; the `secrets` context appears in no release job but
  `gamma`, and there only as the names the machine file gives, on the step that runs `kci`, never
  on a `gamma-breakglass` path. R9 ("together the stage's jobs run every validation exactly once")
  counts them as run by `gamma`; their push-only selection is R9's one stated exception, and is
  safe because a break-glass run never reaches prod.

## g. Slices

Each slice: the check that is red before it. **Go** marks a project-owner action.

| # | slice | red before | go |
|---|---|---|---|
| G0 | **Lock `gamma` to `main`, first** (#1168's S0, unchanged): `gamma`'s deployment branches set to `main`; `gamma-breakglass` with a required reviewer and administrator bypass off; the drift check in `build` that reads `gamma`'s environment and fails the release unless its policy is `main` only. Until G0 is applied, any branch can run with gamma's identity, so **no cloud trust may name `gamma` before it** | the drift check fails on today's settings; a canned environment answer with no policy turns it red; after the settings change it passes | **Go** (repository settings) |
| P0 | **Probe** on a `probe/*` branch: a workflow of hosted jobs that only `sleep` and `echo`, `permissions: {}` (one job `actions: write` on its own run), no secret, no farm, no cloud, no upload, plus a `probe-wait` environment with a required reviewer. It records, from the runs API: (a) the run conclusion when a job is replaced in its group; (b) a job waiting on a reviewer holds only its group, and whether a newer arrival replaces it; (c) a job skipped by `if:` takes no group slot; (d) a re-run attempt joins the same group and downloads attempt 1's artifact; (e) on a run whose first job succeeded and whose second was cancelled while pending, a token-requested `rerun-failed-jobs` starts, and records: whether cancelled jobs count as failed (if not, the per-job `.../jobs/{job_id}/rerun` is tested instead), that the succeeded first job is **not** re-run, and that attempt 2 reads attempt 1's `needs` outputs and downloads its artifact. Plus a read of the farm's trust policy for a `beta` subject. Existing runs cannot show (a) to (e): today's `kci.yml` has only the workflow-level group (line 203). | each fact written here with the run's URL, or P2 and P4 stop | **Go**: it starts workflow runs and creates an environment |
| P1 | kci: `never_backward` per run; main-line filter; the descendant read and `SUPERSEDED` (exit 0, output `superseded`); R24's admission check; gamma's "carried" list | c's table, rows 1, 3 to 9; rows 2 and 10 guard | none |
| P2 | `main_red.py`: `classify` from jobs and the `superseded` step; `last_green` filtered; `stalled`, its re-run, and its issue when the tip has no push run | d's tests (a) to (e) | the re-run needs question 6 |
| P3 | Tasks: the loopback audit; the payload digests on a real tree (e); beta's command on the two planted trees (e). kci: `TEST`, `checks` (`buck2 build`, then `buck2 test`), beta's read of gamma's listing, step 4b for TEST, the payload comparison, validations from the handed local channel; `build` writes the local index | machine fixtures (TEST with neither; `checks` on PUBLISH) refused; c row 4; a TEST run with a mismatched `--release-set-hash` refused exit 3 with zero runner calls, and without the flag under Actions exit 2 (mutant: 4b without TEST), copying the prod case at `test_kci_ref_check.mojo:542-554` for beta, gamma and validate; a planted payload mismatch refused; the commands pinned to `build` then `test` (mutants: drops the build, drops the test); beta's two commands alone red on each of the two planted trees, and each tree green under the command its mutant keeps (e). Regression (green before, mutant named): a local-channel record with another sha256 refused (mutant: skip the compare in `conda_install_env.mojo`) | none |
| P4 | The switch, one PR: `release/machine.textproto` with beta; `kci.yml` with job groups, `beta`, `beta_install`, the `superseded` steps, R23/R24 guards and the line on every job; R16, R23, R24 in `kci_workflow_check`; ci.md's "Queued runs" and "Never backward" rewritten for every stage; the paths between this doc and continuous publish become links | fixtures refused: a workflow-level group, a job without a group, `queue: max`, a job missing R23's conjunct or step, gamma reading `beta`'s unvalidated `set_hash` (R19), a job without R24; today's `kci.yml` fails the new R16 | **Go**: changes the release; the first push creates `beta` and spends farm time |
| P5 | Retention of `kci-release-*` to the ruled value | none (a setting) | **Go** with question 3 |
| P6 | #1168 S10c's derived checks join beta's `checks`; S12's join `beta_install` | as #1168 states them | as #1168 |
| P7 | kci: the `BUCK2_TARGET` validation kind and its machine-file refusals; the start checks before publish; the token exchange (AWS web identity), the child environment from nothing, the flags, the timeout, the verdict from exit status and results file, the output kept off the log, the one re-run (e2); prod's two hashes (R19 amended); fake suites and a fake ID-token endpoint for tests | e2's table, rows 1 to 7 and 9 to 19 (8 guards) | none: no machine file uses the kind until P9 |
| P8 | `build` builds every `BUCK2_TARGET` target and ships each executable and its sha256 in `kci-release-<revision>`; the lint on `src/tests/real_cloud/`; the first AWS suite there, from its owner, with its README naming the owner, its teardown and its budget alert | e2's rows 11 and 20; a planted tree whose suite package holds a `mojo_test` refused by the lint; the suite builds on the farm (`local: 0`) and `buck2 test` over its directory runs nothing | none: it runs no suite |
| P9 | The wiring, one PR: `real-cloud-aws` in gamma's step in `release/machine.textproto`; `kci.yml`'s `gamma` job with `--secret-store env`, the two identity secrets on its `kci` step, `timeout-minutes` per R25, `validated_set_hash` handed to prod; R19 amended, R25 and R9's exception in `kci_workflow_check` | fixtures refused: a secret named in any other job or on `gamma-breakglass`'s path, a `timeout-minutes` other than R25's, prod without gamma's hash; today's `kci.yml` fails R25 | **Go**: the cloud trust for subject `environment:gamma` (question 9), created only after G0 is applied and its drift check is green. The first push spends real money |

**G0 comes first, before everything that grants a cloud anything.** P1 to P3, P7 and P8 merge on
their own and change nothing that runs (P1 changes only what a push to gamma may do when the
channel is ahead; P2's `stalled` reads only push runs, which are unchanged until P4; P7 adds a kind
no machine file uses; P8 ships executables nobody runs). P4 depends on P0 to P3. P9 depends on
**G0 applied and green**, P7 and P8, and on P4 only for gamma's job-level group: until P4, gamma's
validations hold the workflow-level `kci-release-main`, which serialises whole runs and is
single-flight already.

## h. Questions for the project owner

1. **Two jobs per stage (a departure from rule 2).** Beta (`beta`, `beta_install`) and gamma
   (`gamma`, `validate`) are two slots each: one job would put an install's third-party code next to
   the farm or publish token, and two jobs sharing one group would let one stage's second job cancel
   its own first job's pending newer run. So beta can test C while installing B. *Recommendation:*
   accept; each job is pinned to its own set's digests, so an overlap cannot check the wrong files.
   Under ruling (B) this is the one overlap gamma keeps: its `gamma` job, which publishes and runs
   the real-cloud validations (e2), is one slot, and prod needs both jobs to vouch for one set hash.
2. **Break-glass runs and the push groups (a departure from rule 2).** Manual runs keep per-ref
   groups, so a break-glass run's build and beta can overlap a push run's, and its gamma publish can
   overlap main's: two writers to one channel, each checking the listing before it uploads.
   *Recommendation:* gamma's **publish** job joins `kci-gamma-main` in every non-dry run, one writer
   per channel; build and beta stay per ref (they write nothing shared). A break-glass arrival can
   then replace main's pending gamma; `stalled` (b.4) re-runs it. **The other direction:** a main
   push can replace a **pending break-glass** gamma publish. `stalled` reads only push runs, so
   nothing re-runs it: the break-glass run concludes `cancelled` and its release is dropped. The
   remedy is to start the break-glass run again (its operator sees the run concluded `cancelled`,
   with GitHub's "higher priority waiting request" message on the gamma job). *Recommendation,
   unchanged:* accept, since break-glass is rare and a human is already watching it; the
   alternative, `stalled` opening an issue for a cancelled manual run, is a small P2 addition.
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
   `rerun-failed-jobs` of a run whose head is main's releasable tip; it runs no pull-request code.
7. **P0's probe.** *Recommendation:* go; it spends only hosted minutes and touches no cloud.
8. **A tip with no push run (b.2, b.4).** A commit merged with a skip marker in its message gets no
   push run; if an older run reaches `build` after it landed, that run stops `SUPERSEDED` and nothing
   releases until the next push, where before revision 3 the older commit would have released.
   *Recommendation:* accept, with `stalled`'s issue. Refusing skip markers in the PR check would not
   close it: the merge commit's message is written at merge time, after the check ran.
9. **The cloud credential (a go, after G0).** *Recommendation:* go for AWS first, as a role whose
   trust accepts only this repository's OIDC issuer, the audience `sts.amazonaws.com` and the
   subject `repo:<owner>/<repo>:environment:gamma` exactly; no access key is created. The role's
   permissions are the suites' and nothing more, in accounts used only for these tests, and the
   role ARN and region are secrets of the `gamma` environment only. The trust is created **only
   after G0 is applied and its drift check is green**. It names `gamma` itself, not a separate
   `gamma-cloud` environment (gamma validation decisions, item 4, recommended one), because the
   ruling names the gamma stage's credential; the publish token and the cloud token then share
   one job, and e2's child environment from nothing (row 12) is what keeps a suite from minting a
   publisher token. GCP and Azure follow the same shape once their keyless identity lands.
10. **Who owns the suites and their cost.** By the ruling this stage spends real money, and kci
    bounds only time. *Recommendation:* each suite's README names an owner who owns its teardown,
    its leak sweep (by validation run id) and a budget alert on its test accounts, and who answers
    the flake issue #1168's rule opens; no suite joins gamma's validations without one.
11. **The order inside gamma.** The real-cloud validations run in the `gamma` job, after the
    publish and **before** `validate`'s installs, which run in their own slot after it: putting the
    installs' third-party code in the job that holds the publish token and the cloud credential is
    what the split prevents (question 1). The cost: a set whose README install would fail still
    spends a real-cloud run first. *Recommendation:* accept; beta's
    `beta_install` has already installed the same bytes from the local channel (e), so an install
    failure in `validate` is rare. The alternative, one more job between `validate` and the wait,
    cannot hold gamma's group (b).
12. **An override after a red.** e2 builds none: no flag, input or reviewer lets prod pass a red,
    absent or stale validation. *Recommendation:* keep it so; a release past a red real-cloud result is
    the project owner's explicit go, carried out as a revert or fix on `main`, not a switch.

## Future: gamma bake

**Status: out for now (ruling A), tracked in #1183.** The goal: after gamma's validations pass, the
candidate stays in gamma for 24 hours under watch before prod is promoted. A bake is useful only if
something watches the candidate during it; without that it is only a delay. It is not designed
here, and no slice above builds any of it. It is designed and built when every prerequisite exists:

1. **Canaries and monitoring of the deployed candidate**: errors, drift and cost, with a red signal
   that stops promotion, owned by the deployment's observability owner.
2. **The real-cloud tests' own safety nets**: their sweeper's leak reports and budget alerts on
   their test project, so a day-long bake cannot leak resources or spend unnoticed.
3. **Lock-through-bake mechanics.** In e2 one hosted job holds `kci-gamma-main` through gamma's
   real-cloud validations. A GitHub-hosted job runs for at most 6 hours, so no job can hold the
   group for 24. The bake needs a lock that is not a running job, for example a bake record that
   prod's admission reads and gamma's next run respects, with its own planted tests (a red canary
   mid-bake, the window not yet elapsed, a newer candidate arriving mid-bake).
4. **No exception without the project owner's explicit go**: no shortened bake, no skipped bake, no
   override of a red bake.
