# The staged pipeline: build once, then beta, gamma and prod, each one run at a time

Status: design, not built. **EXISTS** names code or a setting on `main`; everything else is
PROPOSED. New names (all absent from `main`): the conda channel `beta` and its environments `beta`
and `beta-breakglass`; the job `beta_validate`; the stage `gamma` in its new meaning (real cloud
resources, no channel); the stage and job `prod_deploy` and its environment `prod-deploy`; the step
kind `TEST`, its field `checks` and the steps `test` and `real-cloud`; the outcome `SUPERSEDED` (as
a successful stop), the job output `superseded` and the step `superseded`; the `main_red` decision
`stalled`; rules R23, R24, R25 and R26; the validation kind `BUCK2_TARGET`, its fields `target`,
`cloud`, `identity`, `region`, `timeout_seconds` and `attempts`, and the suite flag `--list-cases`;
the directory `src/tests/real_cloud/`; the validations `real-cloud-<cloud>`; the named form
`--release-set-hash <stage>=<hash>`; the slices G0 and M1 to M4. Related: continuous publish
(`docs/design/continuous_publish.md`, #1168; a path, not a link, until that doc is on `main`, since
the doc links lint refuses a dead link; P4 makes it a link), [ci.md](../ci.md), [release
machines](release_machine.md), [gamma validation](gamma_validation.md), [the DEPLOY
step](deploy_step.md).

## Glossary

This is the one definition of these words for this doc, continuous publish and the code that
implements them. Continuous publish links here; it does not define them again.

| word | meaning |
|---|---|
| **stage** | One of the pipeline's three: **beta**, **gamma**, **prod**. The machine file (`release/machine.textproto`) also holds a stage `build`, the first part of beta, and, once the DEPLOY step is built, a stage `prod_deploy`, the second part of prod: a machine-file stage has one environment and is farm-connected or not, and beta's build runs on the farm while its publish runs on a hosted runner with a publishing token (R11 keeps the two apart); prod's deploy and prod's publish never share a job (e2, "Prod deploy"). |
| **beta** | The first stage. It **builds each commit once** (job `build`, on the farm), runs the per-package **fake, emulator and fixture tiers** on that build (the `TEST` step `test`, same job) and, once the engine port lands, the **e2e suite**; it **publishes** the packages to the beta channel (job `beta`), then **installs** them from that channel and runs every README example (job `beta_validate`). It holds no cloud credential and spends no cloud money. |
| **beta channel** | The public conda channel `beta`. A test channel: consumers install from prod. Today the channel in this role is named **`gamma`**; M1 to M4 (section e3) move it to `beta`, each step with the project owner's go. |
| **gamma** | The second stage: **only real resources, in the gamma cloud accounts**. kci deploys there (once the DEPLOY step is built, [deploy_step.md](deploy_step.md)) and runs the real-cloud kci tests as gamma's `BUCK2_TARGET` validations (e2). Gamma publishes nothing: **`gamma` names no conda channel**. |
| **gamma accounts** | Cloud accounts used only by gamma. Their roles trust the `gamma` environment's OIDC subject, in GitHub's immutable form (e2), and nothing else trusts that subject. |
| **prod** | The third stage: it promotes **the same bytes** (the same sha256 digests) to the prod channel (job `prod`), and, once the DEPLOY step is built, deploys prod from a **separate** job `prod_deploy` in the environment `prod-deploy`, so no job holds a publishing identity and a cloud trust together (e2, "Prod deploy"). |
| **prod channel** | The public conda channel `prod`. |
| **build once, same bytes** | Every job after `build` handles the files `build` wrote to the run's artifact `kci-release-<revision>`; nothing is rebuilt or re-downloaded from a channel to promote. |
| **set hash** | kci's hash of the release directory; `build` outputs it as `set_hash`. Every later job recomputes it and refuses another one (`KCI-E-SET-HASH`, exit 3). |
| **validated hash** | The set hash a job hands on only when it selected **every** validation of its stage and each one VALIDATED and SUCCEEDED: `beta_validate`'s and `gamma`'s output `validated_set_hash`. Prod requires both, by stage name. |
| **tiers** | *fake*: in-memory fakes (`kci_cloud_fake`); *emulator*: pinned emulator processes in a loopback-only namespace on the farm; *fixture* (the ruling's "recorded-response"): **synthetic** responses from pinned models and documented examples, replayed through `ScriptedConnector`, never captured from a live cloud; *e2e*: `//src/tests/e2e/...`; *real-cloud*: gamma's validations, the only tier that reaches a cloud. The first four run in beta. |
| **single flight** | One run at a time per release job: a job-level group `kci-<job id>-main`, one job running and at most one pending, `cancel-in-progress: false`. |
| **latest wins, superseded** | A newer arrival replaces the pending job; a revision older than what a stage (or a later one) already holds stops as `SUPERSEDED` (exit 0) and never runs on its own. |
| **never backward** | A stage refuses to act on a revision older than the newest main-line build its own channel holds (beta, prod); gamma, which has no channel, reads prod's (c). |
| **break-glass** | A manual run. It reaches **beta only**, from the environment `beta-breakglass`; never gamma, never prod. |
| **main red** | A push run of `kci.yml` on `main` that ends red at any stage. `release/ci/main_red.py` opens an issue; the rule is fix forward or revert within the hour ([ci.md](../ci.md)). |

**Stage → jobs → channels → credentials.**

| stage | job | runs on | environment | identity token, trusted by | channel |
|---|---|---|---|---|---|
| beta | `build` (machine stage `build`: BUILD, then `TEST`) | farm | `build` | the farm's token, trusted by the farm only | none |
| beta | `beta` (PUBLISH) | hosted | `beta` on a push; `beta-breakglass` on a manual run | OIDC, trusted by the beta channel's publisher only | writes `beta` |
| beta | `beta_validate` (the installs) | hosted | none | none (`contents: read`) | reads `beta`, anonymously |
| gamma | `gamma` (DEPLOY once built, then `real-cloud`) | hosted | `gamma`, push only | OIDC, trusted by the gamma accounts' roles only; the role and region as `gamma` secrets | reads `prod`'s listing, anonymously; writes none |
| prod | `prod` (PUBLISH) | hosted | `prod` | OIDC, trusted by the prod channel's publisher only | writes `prod` |
| prod | `prod_deploy` (machine stage `prod_deploy`: DEPLOY and its `DEPLOY_PROBE`s; once DEPLOY is built) | hosted | `prod-deploy`, push only | OIDC, trusted by the prod deploy role only; no channel trusts it | none |

## The ruling, and what changes

The project owner's ruling: publishing is continuous, through three stages, **beta → gamma → prod**,
in the meanings of the glossary.

1. Each commit is built **once**; every stage handles **the same files** (the same sha256 digests).
2. Each stage runs **at most one run at a time**.
3. While a stage is busy, newer commits on `main` stack up; the next run takes the **latest**. Older
   pending runs are **superseded**, never run on their own.
4. A stage promotes only after **its own checks** pass.
5. **No bake for now.** A 24-hour bake in gamma is the goal once canaries and monitoring watch the
   candidate ([Future: gamma bake](#future-gamma-bake), #1183).
6. **Prod is promoted when every gamma validation has passed**, with no wait after it. A red
   real-cloud validation fails gamma; there is no override without the project owner's explicit go.

**What the vocabulary ruling changes from the first version (#1173) and revisions 1 to 3 of this
amendment.** #1173 said "beta is not a channel" and kept the conda channel named `gamma`. Now **beta
is the publishing stage** (the beta channel, its installs and README examples, and the fake,
emulator and fixture tiers), and **gamma holds only real cloud resources**. Everything #1173 and
revision 3 put on gamma's channel moves to beta: the publish, the two installs, never-backward on a
channel and break-glass. Gamma keeps single flight and the real-cloud validations, and gains the
deploy. Because gamma no longer publishes, its job holds **no publishing identity**, which is what
answers the credential-boundary review of revision 3 (e2). Prod's deploy, once built, gets a job of
its own for the same reason: prod's publish job holds the prod channel's identity, so no cloud
trusts it. The rename of the channel itself is a migration with the project owner's go at each step
(e3).

**Today (EXISTS).** One run per push carries `build → gamma → validate → prod`
(`.github/workflows/kci.yml`); `gamma` publishes to the conda channel `gamma` and `validate` installs
from it. That is, in this doc's words, **beta under its old name**: today there is no gamma stage in
the new sense. The **workflow-level** group `kci-release-main` serialises whole runs: the newest
pending *run* waits for the previous run to finish **prod**. Rule R16 of `src/kci_workflow_check`
requires that group and refuses a job-level `concurrency:`, for a reason this doc must answer
(`auto_promotion.mojo`, R16): "a job-level group's pending replacement could drop a prod job". Rules 1
and 4 already hold (the set hash, R19); rules 2 and 3 hold for the pipeline as a whole, not per stage.

**Relation to continuous publish (#1168).** #1168 uses this glossary. This doc **supersedes** two of
its parts: "Trigger: per merge, coalesced" (one run per push, coalesced as a whole) and the "within
one release duration" arithmetic with the rollback time resting on it (restated at the end of b).
#1168's two gates keep their places under the new names: S10c's release checks run in `build`
(the `TEST` step, e), before anything is published, and S12's installed-bytes checks in
`beta_validate`, before gamma. #1168's slice S0 (lock today's `gamma` environment to `main`) is
this doc's G0. #1168 holds no cloud credential; e2 adds the first, in gamma (prod's deploy
credential, once built, sits in its own job, `prod_deploy`). Merge order: #1173
merged first and #1168 is still open; they do not conflict, so #1168 can merge before or after this
amendment. P4 rewrites ci.md's "Queued runs" and "Never backward", which today describe prod only.

## a. Where the build-once files live, and how each stage proves it has them

**Decision: one workflow run carries every stage, so the files stay a workflow artifact of that
run.** `build` uploads `kci-release-<revision>` and every later job downloads it by name, scoped to
the current run (another run's artifact needs `actions: read`, which R4 grants no release job).
**Prod promotes the artifact's files, not a download from the beta channel:** the beta channel is
where those bytes were installed and checked, and `beta_validate` holds each installed file to the
release's sha256 (`src/kci_validate/readback.mojo`, check 2).

**The proof is kci's set hash, at every job.** `--release-set-hash` makes kci recompute the release
directory's set hash and refuse another one, `KCI-E-SET-HASH`, exit 3, before any effect
(`src/kci_cli/dispatch.mojo`, step 4b). Step 4b runs for a run that selects a PUBLISH step or a
validation (EXISTS), which covers every job after `build`; the `TEST` step runs inside `build`'s own
run, on the directory it just built, so it needs no hash. The hash is handed job to job and never
typed (R19): `build`'s `set_hash` → `beta` and `beta_validate` → `beta_validate`'s
`validated_set_hash` → `gamma` → `gamma`'s `validated_set_hash` → `prod`, which also takes
`beta_validate`'s (e2, "Prod").

**Retention.** `kci-release-*` is kept 14 days (`kci.yml`). A run whose prod waits longer fails to
download and goes red; it never publishes other bytes. Recommendation: 30 days (question 3).

**Rejected: a staging bucket, or prod downloading from the beta channel.** A bucket is a cloud
credential and spend for nothing while the stages share a run. Downloading from beta would make the
channel host part of the proof; the artifact and the set hash already are.

## b. One run at a time per stage, and why the latest wins

GitHub's concurrency documentation: in a group at most one job runs; a newer arrival cancels the
**pending** one and takes its place; groups ignore case; FIFO by the time each started waiting, "not
guaranteed"; `queue: max` keeps up to 100 pending.

**Exclusion (rule 2): one workflow, no workflow-level group, a job-level group on every release
job** (`build`, `beta`, `beta_validate`, `gamma`, `prod`, and `prod_deploy` once built),
`cancel-in-progress: false`, no `queue`
key (`queue: max` would run every commit). A push to `main`: `kci-<job id>-main`; a manual dry run:
`kci-<job id>-plan-<run id>`; any other manual run: `kci-<job id>-ref-<ref name>`, except as question
2 proposes for beta's publish. **Gamma is one job, so it is single-flight as a whole.** Beta is
three jobs (question 1); prod is one job until DEPLOY is built, then two (question 14).

**The hazard R16 names, stated.** GitHub keeps the newest **arrival**, not the newest **commit**. An
older arrival cancels a newer pending job, and nothing brings the newer one back. Three paths deliver
an older arrival: (i) a re-run of any job of an old push run, which joins `kci-<job>-main`; (ii) two
pushes close together reaching `build` in reverse order (FIFO "not guaranteed"); (iii) a human
cancel. With a group per job nearly every job has a pending arrival, so the window is wider than
today's one workflow-level slot. Never-backward (c) stops a channel going backwards; it does not
release the cancelled commit. **Groups alone cannot hold rule 3.** Four parts do:

1. **Order for live runs.** `build` is a single slot, each later job is a single slot fed by the
   previous job's completions, so after `build` arrivals follow push order and the pending slot
   holds the newest. A running job is never cancelled: throughput is the slowest job's.
2. **Admission (R24, new).** Every release job's first kci action fetches `main` (anonymous) and
   counts the commits after `REVISION` a push would release (the count `the prod line` uses today,
   excluding `docs/**` and `**.md`). In a push run, a revision that is not main's releasable tip
   stops `SUPERSEDED` before any effect in two cases: on a **re-run** (`github.run_attempt` > 1), at
   every job; and on the **first attempt of `build`**. That closes path (ii): an older commit that
   reaches `build` after a newer one stops there. The newer run it replaced concluded `cancelled` and
   is repaired by `stalled` (4). A first attempt **after** `build` proceeds even when `main` has
   moved: by 1 it is the newest that reached that job, and stopping it would starve a stage whenever
   pushes come faster than the pipeline. **Or the tip has no push run:** GitHub creates none for a
   head commit whose message carries a skip marker (`[skip ci]` and its variants), and occasionally
   fails to create one. Then nothing carries the tip until the next push; `stalled` reports it (4).
3. **The line on every job.** `the prod line`'s "main is at `<tip>`, past `<revision>`" moves into
   every release job's last step (R20), success or failure, so each stage's summary names a newer
   commit it did not carry.
4. **Repair (P2).** `release/ci/main_red.py` runs on every completed kci run (`workflow_run`,
   `completed`). New decision `stalled`: a push run that concluded `cancelled`, with
   `run_attempt == 1`, whose `head_sha` is main's releasable tip **now**, and no other kci **push**
   run of that `head_sha` queued, waiting or in progress (the runs list filtered by `event=push`;
   `main_red` holds `actions: read`). Only push runs count: a manual run of the same sha uses its own
   per-ref groups and never-backward off (c), so it does not carry main's release. `main_red` then
   calls **`POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs`** ("re-run all of
   the failed jobs and their dependent jobs"), **never** the full re-run `POST .../runs/{run_id}/rerun`,
   which would build the commit a second time and break rule 1. Attempt 2 is the tip, so R24 admits
   it; it re-runs only the cancelled job and its dependants, and reads `build`'s outputs and the
   `kci-release-<revision>` artifact from the first attempt. GitHub's docs do not say whether
   "failed" includes **cancelled**, nor that a later attempt reads an earlier attempt's `needs`
   outputs; P0 (e) records both. If cancelled jobs are not re-run, `stalled` calls
   `POST .../actions/jobs/{job_id}/rerun` on the first cancelled job instead. When `build` itself was
   cancelled (path ii), re-running it is that commit's first build, so rule 1 holds. GitHub allows a
   re-run only within **30 days** and at most **50 re-runs** of one run; `stalled` re-runs once, and
   past 30 days it opens an issue instead. A second loss, or no `actions: write` (question 6), opens
   an issue naming the run and the endpoint. The way to hold a release is to add a required reviewer
   to `prod` (ci.md, "Pausing promotion to prod"; `prod` has none today, only its branch policy), not
   a cancel. **No push run of the tip:** when a push run whose `build` ran its `superseded` step
   completes and the tip has no kci push run in any state, `stalled` opens an issue naming the tip,
   which the next push releases (question 8).

**Main red, per stage.** A red job at any stage makes the run red, and `main_red` opens its issue as
today. Beta red: a build, tier, publish or install failure, the bytes stay where they reached (at
most the beta channel). Gamma red: a real-cloud validation failed (or a deploy, once built);
nothing reaches prod. Prod red: the prod publish failed. In each case the fix is a revert or a fix
on `main`; a gamma red caused by the cloud itself (an outage, a quota) is re-run as question 12 says,
never overridden.

**The arithmetic, restated (superseding #1168's).** A push to `main` that touches code reaches prod,
or is carried there by a newer commit, within one pass through the jobs plus at most one wait per job
for the run already in it: at most two release durations, and nearer one as the jobs overlap. A
dropped tip adds the time until `stalled` runs; a tip with no push run waits for the next push. The
time to roll back is one PR check plus that bound. **Gamma is the slowest stage:** its one job holds
`kci-gamma-main` through its real-cloud validations, so gamma takes one candidate per pass and every
commit that lands meanwhile coalesces into the next. A release duration therefore includes up to the
gamma job's `timeout-minutes`, which the machine file bounds at 330 minutes (e2, "Fits a hosted job").

**Rejected: separate workflows chained by `workflow_run`.** It fires only from the default branch
(no break-glass), allows three levels (`main-red` would be a fourth and never run), sets
`GITHUB_SHA` to the default branch's last commit (R21's check has nothing to hold), moves the
artifact across runs (`actions: read`, refused by R4), and would re-register both trusted
publishers, which name `kci.yml` (ci.md).

## c. Ordering safety: nothing older after something newer

**Rule: a stage refuses to act on a revision older than what it, or a later stage, already holds.**
Mechanism: extend "Never backward" (ci.md; `superseding_files` and `backward_files` in
`src/kci_publish/plan.mojo`) from prod to every push stage. Today `req.never_backward = not
stage.break_glass` (`src/kci_cli/dispatch.mojo:418`), so today's publish before prod (the channel
`gamma`, beta's channel after M2) has neither refusal. Proposed:

- **beta and prod:** `never_backward` is a property of the **run**: true on a push to `main`, false
  on break-glass. At beta the listing is read over **main-line builds** only: files whose `h<8 hex>`
  resolves to a commit on `origin/main`'s history (an ambiguous prefix counts as main-line, the side
  that refuses rather than ignores). A break-glass build of a branch is reported and does not stall
  `main`. `build` reads the beta channel's listing before its `TEST` step, so a superseded revision
  spends no farm time on checks.
- **gamma** has no channel. It reads the **prod** channel's listing anonymously, before any token,
  deploy or suite run, and stops if prod already holds a main-line build that supersedes this
  revision: no real-cloud money is spent on a candidate that can never be promoted. Once the DEPLOY
  step is built, the deployed revision of each gamma cell is the deploy step's own record
  ([deploy_step.md](deploy_step.md), its question Q12), not this doc's.
- **Two outcomes, split by history.** The listing's newest main-line build **descends from** the
  revision: `SUPERSEDED`, exit 0, nothing uploaded or run, output `superseded=true`, later jobs skip
  (R23). History **unrelated**: `REFUSED`, `KCI-E-SUPERSEDED`, exit 3, red, as today.
- **This is a new history read, not reuse.** Today kci reads only `git rev-list <revision>` (is the
  channel's newest **on** this revision's history; `backward_files`). `SUPERSEDED` asks the inverse:
  resolve the newest build's `h<8 hex>` to one commit (`git rev-parse --verify`), then ask whether the
  revision is on **its** history (`git merge-base --is-ancestor`). A prefix that is unknown or
  ambiguous, or a shallow history, is INDETERMINATE, `KCI-E-CANNOT-TELL`, exit 5 (the existing path),
  never a pass. P1 builds it.

**Planted tests (`src/kci_publish/tests/test_publish_never_backward.mojo`, kci_cli dispatch tests).**

| # | case | expect | today | mutant caught |
|---|---|---|---|---|
| 1 | push run at beta, newest listed build names a descendant | `SUPERSEDED`, exit 0, zero uploads | red (beta's publish uploads) | restore `not stage.break_glass` |
| 2 | beta listing also holds a higher-numbered off-`main` build | publishes | green; guards the filter | count every build |
| 3 | beta, unrelated history | `REFUSED`, exit 3 | red at beta; regression at prod | split by number only |
| 4 | `build`'s `TEST` step, fake beta listing ahead | `SUPERSEDED` before any farm check runs | red | skip the read |
| 5 | beta, newest build's prefix ambiguous between a main and an off-main commit | counted main-line: refused or superseded, never published | red | treat ambiguous as off-main |
| 6 | descendant check on an unknown prefix or shallow clone | exit 5 | red | default to SUPERSEDED |
| 7 | push re-run (`run_attempt` 2) of a non-tip revision, every job | `SUPERSEDED` before any effect | red | drop R24's check |
| 8 | the same re-run of the releasable tip (only docs after it) | proceeds | red | compare to the raw tip |
| 9 | push first attempt at `build` of a non-tip revision (path ii) | `SUPERSEDED` before any effect | red | check re-runs only |
| 10 | push first attempt at `gamma` of a non-tip revision | proceeds | green; guards against starving a stage | check every first attempt |
| 11 | gamma, fake prod listing holds a descendant | `SUPERSEDED` with zero token requests and zero suite runs | red | gamma reads no listing |

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
  `stalled` (b.4) is the fourth decision. The rename (M2) changes no name `main_red.py` reads: it
  keys on `prod`. When `prod_deploy` is wired, `classify` requires both `prod` and `prod_deploy`
  green, in the same PR, with a planted run whose `prod` succeeded and `prod_deploy` failed (red).
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
a push run of the tip in progress → nothing; (e) the re-run's request, on a fake runs API where
attempt 1's `build` succeeded and `gamma` was cancelled: exactly one call, to
`.../runs/{id}/rerun-failed-jobs` (or the per-job form P0 (e) selects), and no call to
`.../runs/{id}/rerun` (mutant "full re-run" red).

## e. Beta: the tiers on the build, then the beta channel and its installs

**On the farm (the `build` job, machine stage `build`):** after the BUILD step, a `TEST` step `test`
runs two commands over `checks` and the derived set: **`buck2 build <targets>`, then `buck2 test
<targets>`**, the order the PR check uses (ci.md), the second only if the first passed. The targets
are **#1168 S10c's derived release checks** (every standalone check `release/ci/derive_checks.py`
derives whose targets depend on a declared library: the fake, emulator and fixture tiers, plus every
`release_checks` target) and the patterns in `checks`. The e2e suite, `//src/tests/e2e/...`, joins
`checks` **once the engine port lands**; until then `checks` is empty and the derived set alone runs.
Both commands are needed: the build README says "`buck2 test` on a `mojo_library` therefore runs
nothing; its tests run when the library (or anything depending on it) is built"
([tools/build/mojo/README.md](../../tools/build/mojo/README.md), "`test_srcs`, not `tests`"); the
build runs the welded tests, the test runs the standalone `mojo_test`s a build never runs. A test
that skips (exit 77, as the MinIO-backed `komira_job_supervisor/tests/e2e` does without its flag)
cannot fail, so nothing that can skip joins `checks`; #1168's "an emulator test never skips" holds
for the derived set.

**The checks can go red, under these commands alone (P3).** A kci test pins the step's commands:
`build` then `test`, over the same targets (mutants "drops the build" and "drops the test", each
red). The PR check cannot prove the rest: it runs the two verbs over the whole cell. So P3 runs a farm
task (a scratch branch, never pushed for review, no workflow run) that executes **exactly** the
step's two commands on two trees, each with **one** plant: (1) a failing assertion in a welded
`test_srcs` test of a package with no `mojo_test`: the build must exit non-zero and name it; (2) on a
tree without (1), a failing standalone `mojo_test`: the build passes and the test must exit non-zero
and name it. The unplanted tree must pass both. Each tree also runs the command a mutant keeps: tree
(1) `./buck2 test` alone, tree (2) `./buck2 build` alone; each is expected to pass, which shows the
dropped command is the one that catches that plant. The record quotes each command, its exit status
and its `Commands:` line with `local: 0`.

**Zero spend** rests on what can be enforced: the `build` environment holds no secret and no cloud
credential (a settings review at G0 and on every change to it: the anonymous drift check cannot list
an environment's secrets), so a check that reached a cloud would be unauthenticated; #1168's loopback-only namespace
is the guarantee for the emulator tier. "No check opens a socket off loopback" outside that tier is
an **audit** (P3's first task), not a check.

**Tying the source checks to the built files.** The `TEST` step compares, for every released library
the checks build, buck2's payload sha256 with `payload_sha256` in the release's `metadata.json`
(`tools/build/package/conda.bzl`), and refuses a mismatch before running anything. **Risk:** the
checks build libraries in their own configuration, the release builds `<lib>_conda[release]`; if
those payloads differ, beta is red forever (safe, but it blocks every release). **P3's second task**
builds both on the farm on a real tree and records the digests. If they differ, the `TEST` step
builds the checks in the release's configuration; if that cannot be done, the comparison is
withdrawn and the claim narrows to "the checks passed on this revision's source; `beta_validate`
checked the built bytes", which returns to the project owner.

**Publish (the `beta` job, hosted, environment `beta`):** `kci run --stage beta`'s PUBLISH step, to
the beta channel, exactly as today's `gamma` job publishes to the channel `gamma` (EXISTS under the
old name). Its token is trusted by the beta channel's publisher and by nothing else (section e3).

**Installs (`beta_validate`, hosted, no environment, no token):** the existing `CONDA_INSTALL_ENV`
validations install from the beta channel with the pinned pixi and run every installed README, as
today's `validate` does from the channel `gamma`. An install runs third-party code, so it never sits
beside the publishing token. #1168's S12 installed-bytes checks land here. `beta_validate` outputs
beta's validated hash.

## e2. Gamma: real-cloud tests as ordinary validations

The project owner's ruling: the real-cloud tests are **ordinary kci validations of the gamma
stage**: Buck2 targets that kci runs with the `gamma` environment's federated (OIDC) cloud
credential; a red one fails gamma. Nothing outside this repository is asked or waited on. Gamma's
step `real-cloud` is a `TEST` step with no `checks` (it only validates) holding one
`real-cloud-<cloud>` validation per cloud; the DEPLOY step precedes it once it is built.

**Prerequisites, first and each a go.** (1) **G0, lock `gamma` to `main`** (and give
`gamma-breakglass` a required reviewer, g). Today the `gamma` environment has **no**
deployment-branch policy and no protection rule (read through the API again for this revision): any
branch whose workflow names `environment: gamma` runs with gamma's subject.
(2) **M3, the old channel stops trusting `gamma`.** Until the rename, the channel `gamma`'s trusted
publisher accepts the `gamma` environment's subject; a cloud trust of the same subject would put a
publishing identity and a cloud identity in one job. No cloud trust names `gamma` before both.

**What exists, and what is new.** No validation kind on `main` runs a Buck2 target:
`src/kci_api/verbs.mojo` names three, `CONDA_INSTALL_SMOKE`, `CONDA_INSTALL_ENV` and `DEPLOY_PROBE`.
So e2 adds a fourth, **`BUCK2_TARGET`** (P7). It reuses `CONDA_INSTALL_ENV`'s child environment
built from nothing (`src/kci_validate/env.mojo`), the secret store `--secret-store env`, kci's own
exchange of the job's ID token (as for trusted publishing, ci.md), and the AWS SDK's web identity
source (`src/komira_aws_core/credential_chain.mojo`, step 3: `AWS_WEB_IDENTITY_TOKEN_FILE`,
`AWS_ROLE_ARN`, `AWS_ROLE_SESSION_NAME`).

**Where the targets live.** `src/tests/real_cloud/<suite>/`, one test-only package per suite, each a
**`mojo_binary`**, never a `mojo_test` or a library with `test_srcs`, so no run without a cloud
credential runs one: the PR check builds them (a suite that stops compiling is red on its PR), but a
build runs no binary and `buck2 test` runs none. A lint (P8) refuses a `mojo_test`, or a target with
`test_srcs`, under `src/tests/real_cloud/`, and `kci_release_machine` refuses a `checks` pattern that
reaches the directory.

**Built once, on the farm; run in gamma.** The `gamma` job has no farm (R11), so `build` builds every
`BUCK2_TARGET` validation's `target` for `linux-x86_64` and puts each executable and its sha256 in
`kci-release-<revision>` (`validations/<name>/`). They are not released artifacts: the set hash does
not cover them and they are never uploaded. The `gamma` job refuses an executable whose sha256 is not
the one `build` recorded. The suites test this revision's **source**; beta's installs checked the
published bytes.

**How kci runs one (P7).** The `gamma` job's one `kci run --stage gamma` (R5; a FULL run, no `--only`,
R9) runs, for each `BUCK2_TARGET` validation:

1. **Start checks, before any effect,** with the run's other start checks: the run is a push to
   `main` (event `push` **and** ref `refs/heads/main`); every `BUCK2_TARGET` validation of the stage
   is selected (below); each `identity` and `region` secret name resolves to a non-empty value; the
   job can request an ID token; each executable is present with `build`'s sha256; `<executable>
   --list-cases` (run with the child environment of step 3 minus every credential) exits 0 within
   60 s, its process group killed at 60 s, having printed at least one case name, each once. Any
   one failing is `REFUSED`, exit 2, with zero token requests and zero suite runs.
2. **Exchange.** kci requests the job's ID token with the cloud's audience (AWS STS's own audience
   for AWS), writes it to `<scratch>/<validation>/oidc/token`, mode 0600, and builds the child's
   environment **from nothing**: `PATH`, `HOME`, `TMPDIR`, `LANG`, and the provider-standard
   variables the cloud's SDK reads (for AWS, `AWS_ROLE_ARN` from the `identity` secret,
   `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_SESSION_NAME` = `kci-<validation run id>`, `AWS_REGION`
   from the `region` secret). This keeps a suite from **using by accident** what it was not handed
   (`GITHUB_TOKEN`, the request variables); it is **not** containment (next paragraph).
3. **Run** the executable with flags, not variables, for what is not a credential:
   `--validation-run-id <id>` (stamped on every billable resource the suite creates),
   `--results <scratch>/<validation>/results.txt`. The suite's process group is killed at
   `timeout_seconds`.
4. **Verdict.** VALIDATED only when the process exits 0 **and** the results file lists **exactly**
   the case set `--list-cases` printed, each case once, each `PASS`. FAILED otherwise: any other exit
   status (77 included: a real-cloud suite cannot skip), a kill at the timeout, a missing,
   unreadable or **empty** results file, a declared case missing, an undeclared or repeated case, a
   case not `PASS`. The expected set comes from the suite's own source (`--list-cases` prints fixed
   names), so a suite that exits 0 having run nothing is red. A credential that expires mid-suite
   fails the suite; `timeout_seconds` is capped at 3600 so a suite fits AWS's default one-hour role
   session.
5. **Re-run once** (#1168's flake policy). After a FAILED attempt kci runs the suite once more with a
   fresh token and a fresh validation run id; a second FAILED fails the validation. Once a suite
   needs its re-run twice in ten releases it gets an issue with an owner; the run summary names each
   attempt and its result.
6. **Result.** kci hands on `validated_set_hash` only when **every** validation of the stage was
   selected and each VALIDATED and SUCCEEDED (below).

**Every validation, or no hash (P7), for every stage.** On `main` today,
`keep_set_hash_only_if_validated` (`src/kci_cli/start_checks.mojo`) returns early when a run selects
**no** validation, so such a run keeps its set hash, and otherwise compares the passes with the
**selected** count, not the stage's: a gamma job whose `kci run` gained `--only` and lost the
real-cloud validation, or a `beta_validate` run selecting only `install-komira-encoding`, would hand
prod a valid hash. Two changes close it in kci, not only in a workflow lint, for every validation
kind (`CONDA_INSTALL_ENV` in beta, `BUCK2_TARGET` in gamma, `DEPLOY_PROBE` once DEPLOY is built):
(a) **selection, all or none:** a push run that selects any validation of its stage and omits
another is `REFUSED`, exit 2, before any effect; a stage that holds a `BUCK2_TARGET` validation must
select all of them, so gamma's run cannot select none either. A push run selecting none of a stage
without `BUCK2_TARGET` is admitted, as beta's publish job (`--only step:publish`) is today. (b)
**the hash:** any run, break-glass included, hands on a validated hash only when its selection holds
**every** validation of the stage, counted over the stage and not the selection, and each VALIDATED
and SUCCEEDED; a run selecting some or none hands on an empty one (prod refuses an empty hash, exit
2). Beta's publish job therefore hands on an empty hash: nothing reads it (`kci.yml` reads `build`'s
and `validate`'s), and row 19b guards that the publish still runs. R9 and R25 keep their workflow
clauses as well.

**The real trust boundary, stated.** A suite is a child process of kci in the `gamma` job, as the
runner's user, the same user as kci. It can read kci's and the runner's environment
(`/proc/<pid>/environ`), including GitHub's ID-token request variables, and a GitHub-hosted runner
gives that user passwordless `sudo`. So **a suite can mint an ID token for any audience carrying the
`gamma` environment's subject**, and the child environment from nothing does not prevent that. What
bounds the suite is **who trusts that subject**: after G0 only a job of a `main` run holds it; after
M3 no channel trusts it (the beta channel trusts `beta`, the prod channel `prod`); the farm trusts
`build` (P0 reads the farm's trust policy and records that no `gamma` subject is in it); and the
gamma accounts' roles trust it. The suite therefore holds **the gamma accounts' roles and nothing
else**: it cannot publish, reach the farm or touch prod. Its code has the trust kci's has: reviewed
source on `main` (G0), built on the farm, pinned by sha256. Once DEPLOY runs in the same job, a suite
also holds what the gamma deploy role holds in the gamma accounts (question 11).

**Bound to the immutable subject.** This repository's ID tokens carry GitHub's **immutable** subject
form, `repo:<owner>@<owner id>/<repo>@<repo id>:environment:<name>` (its OIDC subject setting,
read through the API, uses it by default). Each cloud trusts this repository's OIDC issuer for the
subject `repo:<owner>@<owner id>/<repo>@<repo id>:environment:gamma` **exactly**, the cloud's
audience, and, where the cloud can condition on further claims (GCP's attribute conditions, Azure's
claim matching), `environment` = `gamma` and `repository_id` = `<repo id>` as well. The ids are never
reused, so a renamed, transferred or re-created repository with the same name cannot match; a trust
written in the name form `repo:<owner>/<repo>:...` matches no token this repository mints and would
fail closed, but must not be written. The trust is created by the project owner, outside this
repository, as a bootstrap (kci holds no standing access); P9's go carries the trust policy's text
for review and a read-back of the created policy, compared field by field. That is a review and a
read, not a test, and is stated as such.

**Identifiers stay out of this repository.** The machine file names the role and region by **secret
name** (`identity: "KCI_GAMMA_AWS_ROLE"`), resolved by `--secret-store env` from secrets of the
`gamma` environment only, passed on the `kci` step alone (R25). They are secrets, not variables,
because this repository's job logs are public and GitHub masks secret values, not variables. Masking
covers only the exact value, and a resource name a suite prints can carry an account number, so
**kci never copies the suite's output to the job log**: it keeps stdout and stderr in the scratch
directory, deletes them with it, and prints only the validation's name, each attempt's exit status
and the results file's case names and verdicts, whose names are fixed in the suite's source. No
account, project or subscription identifier, role name or endpoint appears in the machine file, the
workflow, a suite's source or a log.

**Which clouds.** AWS first: komira's AWS client already reads a web identity. GCP and Azure join
when their keyless identity lands (`external_account` in `komira_gcp_core`, a federated credential in
`komira_azure_core`; gamma validation decisions, item 4); until then `kci_release_machine` refuses a
`cloud` kci cannot exchange for.

**Cost.** By the ruling this stage spends real money. kci bounds only time (`timeout_seconds`,
`attempts`, the job's `timeout-minutes`) and, by single flight, runs one candidate's suites at a
time. The spend is bounded by **each suite's own teardown** (every resource stamped with the
validation run id, so a sweep can find a leak) and by **budget alerts on the gamma accounts**, owned
by the **suites' owner**, named in each suite's README (question 10).

**Single flight, literally.** Gamma is one job holding `kci-gamma-main` from its start checks to its
last validation: one candidate in gamma at a time, a newer commit pending, a still newer one
replacing it, the running one never cancelled. Revision 3's two gamma slots (the publish job and the
installs job) are gone: the installs are beta's.

**Prod.** `prod` `needs: [beta_validate, gamma]`. kci on a stage whose `after` chain holds **two or
more** stages that declare validations (after P9: `beta` and `gamma`) requires **exactly one**
`--release-set-hash <stage>=<hash>` for each of them, refuses a missing stage, a repeated stage or an
unknown one (exit 2), and refuses any value unequal to the recomputed set hash (`KCI-E-SET-HASH`, exit
3). R19 pins the values: `beta=` is `needs.beta_validate.outputs.validated_set_hash` and `gamma=` is
`needs.gamma.outputs.validated_set_hash`, each exactly once. In a good run the two values are equal
(one set), so kci cannot tell one job's output passed twice from two; that is R19's to refuse, with a
fixture. Nothing waits after that.

**The transition to named hashes (P7, then P9).** Today's `kci.yml` passes prod one bare
`--release-set-hash "$RELEASE_SET_HASH"` (parsed by `src/kci_cli/args.mojo`), and today's chain has
exactly one stage that declares validations (the old `gamma`; `beta` after M2). P7 merges with
`kci.yml` unchanged, so P7 keeps the bare form **while exactly one stage on the chain declares
validations**, bound to that stage, accepts the named form as well, and refuses the bare form once
two stages do (rows 31 and 32). P9, which adds the second such stage, carries `kci.yml`'s named
`beta=` and `gamma=` and R19's clause in the same PR, under its go. **Prod's stages are pinned twice:**
by the machine file's chain and by R19's literal `beta=` and `gamma=` clauses in
`src/kci_workflow_check`. A machine-file PR that deletes the gamma stage leaves `kci.yml` passing
`gamma=`, which kci refuses as an unknown stage (row 24), and R19 still demanding it; the PR is red
until it also changes kci_workflow_check's code, a reviewed change to kci, never a silent drop.

**Prod deploy: its own job (once DEPLOY is built).** Prod's publish and prod's deploy never share a
job. `prod` (PUBLISH, environment `prod`) holds the subject that only the prod channel's publisher
trusts. Prod's deploy runs in a separate machine-file stage and job, `prod_deploy`: its DEPLOY step
and `DEPLOY_PROBE` validations, environment `prod-deploy` (deployment branches `main` only),
`after: "prod"`, push only, no break-glass, `needs: [prod, beta_validate, gamma]` and the same `beta=` and
`gamma=` as prod (R19). `needs` alone does not stop it: a `prod` that stops `SUPERSEDED` exits 0
and concludes `success` having published nothing, so R23 gives `prod_deploy` the conjunct
`needs.prod.outputs.superseded != 'true'` (its J is `prod`, not the jobs R19 reads hashes from) and
`prod` declares that output; with both, it deploys only what prod published and both stages
validated (fixture in P4's row). Its
subject is trusted by the prod deploy role only, in the immutable form and with the claim conditions
gamma's trust uses. The reason is the one e2 applies to gamma: that job runs kci and the
digest-pinned `DEPLOY_PROBE` images this revision built, and any process in a job can mint the job's
ID token ("The real trust boundary, stated"), so a publishing identity beside them would let a
faulty or hostile probe publish to prod. kci_release_machine refuses (row 29) a stage holding a
DEPLOY step whose environment a channel's `push_identity` or `break_glass_push_identity` names, and
a stage holding both a PUBLISH to a channel and a DEPLOY step (both accepted on `main` today:
`graph.mojo` lets a stage hold steps of different kinds); R26 keeps `prod-deploy` out of every
other job (R2 holds `kci.yml`'s release jobs to their own stage's). Gamma's deploy and suites share
one job (question 11): gamma holds no publishing identity, so that pairing crosses no boundary between a channel and a cloud. Prod becomes two jobs, like beta's
three (question 14).

**Fits a hosted job.** GitHub's documented limit: "Each job in a workflow can run for up to 6 hours of
execution time" on a GitHub-hosted runner. The `gamma` job's worst case is a fixed 30 minutes
(download, start checks, the listing read, the summary) plus, per `BUCK2_TARGET` validation,
`attempts` × `timeout_seconds`. `kci_release_machine` refuses a gamma stage whose sum passes 300
minutes, so the job's `timeout-minutes`, which R25 pins to 30 plus that sum, is at most 330.

**Break-glass, pull requests, beta and dry runs.** Gamma is not a `break_glass` stage, so kci refuses
a manual run of it (EXISTS for prod), and gamma's and prod's `if:` admit a push to `main` only. The PR
check and beta never select a `BUCK2_TARGET` validation (the kind is refused on a stage without an
environment or with `farm_connected`, and the targets are binaries). A dry run (`--plan`) prints
`WOULD_VALIDATE`, requests no token and runs nothing.

**After a red.** Gamma fails and nothing promotes. No flag, input or reviewer lets prod pass a red,
absent or stale validation; a release past one is the project owner's explicit go, carried out as a
revert or fix on `main` (question 12).

**Planted tests (`src/kci_validate/tests/`, `src/kci_cli/tests/`, `src/kci_release_machine/tests/`,
with fake suites: small `mojo_binary` fixtures that print a scripted `--list-cases`, exit with a
scripted status, write a scripted results file, sleep, start a child, or print their environment; a
fake ID-token endpoint; no cloud).** Each names the mutant it catches.

| # | case | expect | mutant caught |
|---|---|---|---|
| 1 | the suite exits 1 | FAILED after two attempts; no validated hash; the job red | exit status ignored |
| 2 | exit 0, results list a declared case `FAIL` | FAILED | exit status alone decides |
| 3 | exit 0, no results file | FAILED | absent results count as a pass |
| 4 | exit 0, results file **empty** (zero bytes) | FAILED | "every listed case PASS" over an empty list |
| 5 | exit 0, results list two of three declared cases, both `PASS` | FAILED | check listed cases, not the declared set |
| 6 | exit 0, results add an undeclared case, or repeat one | FAILED | ignore extras and repeats |
| 7 | `--list-cases` prints nothing | `REFUSED` exit 2, zero token requests, zero runs | accept a suite with no cases |
| 7a | `--list-cases` prints one name twice | `REFUSED` exit 2, zero token requests, zero runs | accept repeated case names |
| 7b | `--list-cases` prints names, then exits 1 | `REFUSED` exit 2, zero token requests, zero runs | ignore `--list-cases`' exit status |
| 7c | `--list-cases` sleeps past 60 s | `REFUSED` exit 2 within 70 s, its process group gone, zero token requests | no `--list-cases` timeout |
| 8 | the suite exits 77 | FAILED, not skipped | 77 treated as a skip |
| 9 | the suite starts a child that holds a pipe to the test and sleeps; the parent sleeps past `timeout_seconds` | FAILED; the pipe reaches EOF within 10 s of the kill (every holder gone) | kill the parent only; no timeout |
| 10 | first attempt red, second green | VALIDATED, exactly two runs, two token requests, two run ids | no re-run; the token reused |
| 11 | both attempts red | FAILED, exactly two runs | unbounded re-runs |
| 12 | every declared case `PASS`, exit 0 | VALIDATED, validated hash handed on | guard (green before and after) |
| 13 | push run, `identity` secret unresolved | `REFUSED` exit 2, zero token requests, zero runs | check after the exchange |
| 13a | push run, `identity` secret resolves to the empty string | `REFUSED` exit 2, zero token requests, zero runs | check presence only |
| 14 | push run, `region` secret unresolved, `identity` fine | `REFUSED` exit 2 | check `identity` only |
| 14a | push run, `region` secret resolves to the empty string, `identity` fine | `REFUSED` exit 2 | check presence only |
| 15 | push run with no ID-token request variables | `REFUSED` exit 2 | check the secrets only |
| 16 | a push of a ref other than `refs/heads/main` | `REFUSED` exit 2 | check the event only |
| 16a | an event that is neither `push` nor a manual run (`schedule`) of `refs/heads/main` | `REFUSED` exit 2 (green on `main` today: a guard) | check the ref only |
| 17 | the executable's sha256 differs from `build`'s | `REFUSED` before any run | skip the compare |
| 18 | push run of gamma whose `--only` selects none of its `BUCK2_TARGET` validations | `REFUSED` exit 2, zero token requests, zero runs | no selection check |
| 18a | push run of gamma on a fixture machine with two `BUCK2_TARGET` validations, selecting one | `REFUSED` exit 2, zero token requests, zero runs | at least one selected is enough |
| 18b | push run of beta on a fixture machine with two `CONDA_INSTALL_ENV` validations, selecting one | `REFUSED` exit 2, zero installs | the selection check for `BUCK2_TARGET` only |
| 19 | a run of a stage with validations that selects none | the validated hash empty | `keep_set_hash_only_if_validated`'s early return (red on `main` today) |
| 19a | a break-glass run of beta on a fixture machine with two `CONDA_INSTALL_ENV` validations, selecting one, which VALIDATED and SUCCEEDED | the validated hash empty | compare against the selection, not the stage (red on `main` today) |
| 19b | push run of beta's publish job, `--only step:publish`, no validation selected | the publish uploads and exits 0; the validated hash empty | refuse a run that selects no validation (a guard) |
| 20 | the suite prints its environment | only the named variables; no request variable, no `GITHUB_TOKEN` | inherit the job's environment (accident guard, not containment) |
| 21 | the suite prints the `identity` value and an account-shaped number | neither in the job log or summary; case names and verdicts are | copy the suite's output to the log |
| 22 | the token file | mode 0600, the cloud's audience, requested after the start checks | mint at start; world-readable file |
| 23 | prod with only `beta=` | exit 2, zero uploads | prod accepts any one hash |
| 24 | prod with `beta=` twice, or a stage `delta=` | exit 2 | count values, not stages |
| 25 | prod, `gamma=` unequal to the set, `beta=` equal | `KCI-E-SET-HASH`, exit 3 | compare `beta=` only |
| 26 | prod, `beta=` unequal, `gamma=` equal | `KCI-E-SET-HASH`, exit 3 | compare `gamma=` only |
| 27 | a manual run of gamma, and `--only validation:real-cloud-aws` on one | refused, exit 2 | gamma treated as break-glass |
| 28 | `--plan` | `WOULD_VALIDATE`, zero token requests, zero runs | run under `--plan` |
| 29 | machine fixtures: `BUCK2_TARGET` on a `farm_connected` stage, on a stage without an environment, in a part job, on a PUBLISH step, `timeout_seconds` 3601, `attempts` 0 or 3, a `cloud` with no exchange, a gamma sum of 301 minutes, a `checks` pattern reaching `src/tests/real_cloud/`, a stage holding `BUCK2_TARGET` whose environment a channel's `push_identity` or `break_glass_push_identity` names, a stage holding a DEPLOY step whose environment either names, a stage holding a PUBLISH to a channel and a DEPLOY step | each refused, each test asserting that fixture's own error | one refusal per mutant. Thirteen fixtures (`attempts` 0 and 3 are two). The first eleven use a kind or field new here (`BUCK2_TARGET`, `attempts`, `cloud`, `checks`): `main` refuses them only as unknown, so each test is red on `main` because the error differs. The last two parse on `main` and are accepted there. The last three are the trust-table refusals (`BUCK2_TARGET`, DEPLOY, the shared stage) |
| 30 | lint fixture: a `mojo_test` under `src/tests/real_cloud/`, and a library with `test_srcs` there | each refused | the lint checks one form |
| 31 | prod on a chain where exactly one stage declares validations (today's machine, and M2's), bare `--release-set-hash` equal to the set | publishes | refuse the bare form before P9 (main red on P7's merge) |
| 32 | prod on a chain where two stages declare validations, bare `--release-set-hash` equal to the set | exit 2, zero uploads | accept the bare form on any chain |
| 33 | workflow fixtures, today's job names, every other line of today's workflows unchanged; (a) to (f) in a new file `.github/workflows/extra.yml` (not `pr.yml`, whose R2 and R1 already refuse any environment and any second job): (a) a job naming `environment: gamma`; (b) the same as a mapping, `environment: {name: gamma}`; (c) the same as an expression, `environment: ${{ inputs.env }}` under `workflow_dispatch`; (d) the same naming `farm`, which no machine or channels file names; (e) a `pull_request_target` job naming `beta`; (f) a `workflow_run` job naming `prod`; (g) a non-release job of `kci.yml` naming `prod-deploy`; (h) `kci.yml`'s `build` job naming `prod`; (i) the part job `validate` (`beta_validate` after M2) naming `prod`; (j) the `gamma` job's expression with `'prod'` as its second branch | each refused, each test asserting that fixture's own error; today's workflows pass (guard) | (a) to (f) are R26's, red before P7, each test asserting R26's own error for its fixture (as row 29 does), so a refusal by another rule cannot pass it: R26 reads `kci.yml` only (a); matches the plain string only (b); skips an expression (c); guards only a list of named environments (d); skips `pull_request_target` or `workflow_run` (e, f). (g) to (j) are guards, refused on `main` today and kept so a rewrite cannot relax them: (g) is R1's (a `kci.yml` job that is no stage and runs no part of one), so R26 adds nothing there and "R26 exempts every job of `kci.yml`" is no mutant this row can catch; (h) to (j) are R2's: "a release job may name any stage's environment" (h, i); "compare only the expression's first branch" (j). R26's "`kci.yml`'s included" for `pull_request_target` and `workflow_run` is R6's on `main` (`kci.yml` takes `push` and `workflow_dispatch` only), so no fixture of this row tests it |

## e3. The channel rename: `gamma` to `beta` (a migration, each step a go)

The channel host is outside this repository, its names are public and permanent, and every step
below changes what consumers or publishers can do. **Nothing here happens silently**: each step is
the project owner's go, in this order. What exists today (read through the API for this revision):
the environments `build`, `farm`, `farm-pr`, `gamma` and `prod`; `gamma` has no branch policy and no
secrets; `gamma-breakglass` and `beta` do not exist; the channels file names `gamma` (trusted
publishers `environment:gamma` and `environment:gamma-breakglass`) and `prod`.

- **M1, create (go).** On the channel host: a public channel `beta`, with trusted publishers for this
  repository, `kci.yml` and the environments `beta` and `beta-breakglass`. Two reads are recorded
  here: which subject form the host matches (name or immutable), and a read-back of each publisher
  showing that it pins the repository, the workflow `kci.yml` **and** the environment. A publisher
  that does not pin the environment is not accepted and M2 waits: otherwise a `gamma` token, or any
  other job of `kci.yml`, could publish to `beta`. On GitHub: the environment `beta`,
  deployment branches `main` only, and `beta-breakglass`, a required reviewer with administrator
  bypass off; **neither holds a secret** (trusted publishing; a settings review, G0, since an
  anonymous read cannot list secrets). Both are locked before anything trusts
  them. Proof: the drift check (G0) reads `beta` and passes; a canned answer with no policy is red.
- **M2, switch (go: it changes the release).** One PR: `release/channels.textproto` names `beta`
  (location, `push_identity` and `break_glass_push_identity` **in the form M1 recorded**: the
  immutable form if the host matches it, else the name form today's file uses; environments `beta`
  and `beta-breakglass`) and drops `gamma`; `release/machine.textproto`'s stage `gamma` becomes
  `beta` (its `channel` field `beta`, `environment` `beta`, `break_glass_environment`
  `beta-breakglass`), and prod's `after` becomes `beta` (the real-cloud gamma stage arrives in P9);
  `release/validations/BUCK` maps `install-komira-encoding` and `install-set` to the stage `beta`
  (kci_release_machine's welded test holds it to the machine file); `kci.yml`'s jobs `gamma` and
  `validate` become `beta` and `beta_validate`, with their environments; `test_repo_kci_yml` and the
  workflow-check fixtures follow. **Every other place on `main` that says `gamma` for the channel,
  the stage or its jobs** (from `git grep -i gamma` on `main`, math functions excluded) says `beta`:
  the docs ci.md, release_machine.md (the stage list and its validations), gamma_validation.md and
  gamma_validation_decisions.md (their headers already point here); the comment headers of
  `.github/workflows/kci.yml`, `release/channels.textproto` (lines 3 to 17),
  `release/machine.textproto` (lines 19 to 77) and `release/artifacts.textproto` (the NEW NAMES
  note); the comments of `.github/workflows/pr.yml` (its job list),
  `src/kci_pkg_upload/prefix_dev_registry.mojo` (the `komira-ai/gamma` examples),
  `src/kci_release_machine/parse.mojo` (its example machine),
  `src/kci_workflow_check/auto_promotion.mojo` (the chain `build -> gamma -> validate -> prod`) and
  `src/kci_workflow_check/rules.mojo` (its list of release jobs, one of them in a refusal message);
  the example in `src/kci_release_machine/README.md`; and `docs/index.md`'s rows for gamma_validation.md (what "checks a release before prod") and its "CI and deploy" link text ("what gamma checks per package family"), which under the glossary describe beta. **Kept on purpose:** test fixtures under
  `src/kci_*/tests/`, `src/kci_publish/release_fixture.mojo` and `src/kci_validate/README.md`, which
  name an example channel or stage `gamma` on `example.invalid` (fixtures, not the channel);
  `release/ci/tests/test_main_red.py`, whose job named `gamma` is a fixture for `main_red.py`, which
  keys on `prod`; and `.github/ci/tests/coverage_ci_cases.sh`, where `gamma` is a placeholder
  package name. `docs/releases.md` names no channel `gamma`; it gains M4's notice. **The install
  tests** (`CONDA_INSTALL_ENV`) install from their step's channel, so they follow the `channel`
  field with no edit of their own. A parser row: `push_identity_environment` reads `beta` from the
  form M1 recorded (`_environment_of` today is documented for the name form only, so the immutable
  form needs the row). Red before: today's channels file has no `beta`, so a fixture machine whose
  beta stage publishes to it is refused. After merge, the first push publishes to `beta` and `prod`;
  the next build number continues (build numbers count first-parent commits), so beta's empty
  listing passes never-backward; the old channel receives nothing, which a read of its listing
  confirms.
- **M3, retire the old publishers (go).** After M2's first green release, the channel `gamma`'s
  trusted publishers (`environment:gamma`, `environment:gamma-breakglass`) are removed on the host.
  **This must precede any cloud trust of `environment:gamma` (P9).** Proof: the host's publisher
  list read back where it offers one, else the project owner's record of the change.
- **M4, the old channel's packages (go, question 13).** Every build in `gamma` is either one prod
  also holds (every validated set was promoted) or one that failed its checks; no consumer needs
  one prod lacks. Nothing is copied into `beta`. The channel is kept read-only (no publisher, after
  M3) for a notice period, named in `docs/releases.md`, then deleted with a go; whether the host can
  delete a channel is read first. The environment `gamma-breakglass` is deleted with it.

**Environments and secrets after M4.** `beta` and `beta-breakglass`: no secrets. `gamma`: locked to
`main` (G0), no secrets until P9 adds `KCI_GAMMA_AWS_ROLE` and `KCI_GAMMA_AWS_REGION`, trusted by no
channel. `gamma-breakglass`: created by G0 with a required reviewer (`kci.yml` names it on every
manual run until M2, and GitHub would otherwise create it unprotected on first use); after M2 no
workflow names it, R26 refuses it in any workflow, and the drift check reads it until M3, after
which nothing trusts it, so M4 deletes it with the old channel's go; the new
gamma has no break-glass. `prod`: unchanged. `prod-deploy`: created with prod's deploy, locked to
`main`, trusted by the prod deploy role only (e2, "Prod deploy").

## f. The machine file, the environments, the workflow rules

```text
stage {
  name: "build"   farm_connected: true   break_glass: true   environment: "build"
  step { name: "build" kind: BUILD platform: "linux-x86_64" artifacts: "release/artifacts.textproto" }
  step {
    name: "test"
    kind: TEST                       # NEW: `buck2 build`, then `buck2 test`, over S10c's derived set + checks
    # checks: "//src/tests/e2e/..."  # NEW field, optional; added once the engine port lands
  }
}
stage {
  name: "beta"   environment: "beta"   after: "build"
  break_glass: true   break_glass_environment: "beta-breakglass"
  step {
    name: "publish" kind: PUBLISH platform: "linux-x86_64" artifacts: "release/artifacts.textproto"
    channels: "release/channels.textproto" channel: "beta"
    validation { name: "install-komira-encoding" kind: CONDA_INSTALL_ENV install: "komira_encoding" ... smoke: README }
    validation { name: "install-set" kind: CONDA_INSTALL_ENV install: "komira_all" ... smoke: README }
  }
}
stage {
  name: "gamma"   environment: "gamma"   after: "beta"     # no break_glass, no channel
  step {
    name: "real-cloud"
    kind: TEST                       # validations only; no checks off the farm
    validation {
      name: "real-cloud-aws"
      kind: BUCK2_TARGET                                  # NEW (e2)
      target: "//src/tests/real_cloud/<suite>:<suite>"    # a mojo_binary
      cloud: AWS
      identity: "KCI_GAMMA_AWS_ROLE"                      # secret NAMES, from the gamma
      region: "KCI_GAMMA_AWS_REGION"                      # environment; never a value here
      timeout_seconds: 3600
      attempts: 2                                         # one re-run
    }
  }
}
# prod: unchanged except `after: "gamma"`.
# Once the DEPLOY step is built (never as a step of `prod`):
# stage { name: "prod_deploy"  environment: "prod-deploy"  after: "prod"   # no break_glass
#   step { name: "deploy" kind: DEPLOY ... validation { kind: DEPLOY_PROBE ... } } }
```

On a `farm_connected` stage a `TEST` step always runs S10c's derived set, and `checks` adds patterns
to it. `kci_release_machine` refuses a `TEST` step off the farm with no validation (it would run
nothing), `checks` on a stage that is not `farm_connected`, `checks` on any other kind, and every
`BUCK2_TARGET` case of e2's row 29.

**Workflow rules (`src/kci_workflow_check`):**

- **R16, rewritten:** no workflow-level `concurrency:`; every release job a job-level one, exactly
  `group: kci-<job id>-<canonical suffix>`, `cancel-in-progress: false`, no `queue`.
- **R23, new:** every job of a stage with an `after` carries the conjunct
  `needs.<J>.outputs.superseded != 'true'` (J: the job R19 reads its hash from; for `prod_deploy`,
  `prod`, whose `SUPERSEDED` stop concludes `success`), every release job declares the output
  `superseded`, and every release job has the step `superseded` with R23's exact `if:`.
- **R24, new:** every release job's first `kci` invocation runs with the admission check (b.2).
- **R19, amended (in P9, with `kci.yml`'s named form; e2, "The transition"):** `beta` and
  `beta_validate` read `needs.build.outputs.set_hash`; `gamma` reads
  `needs.beta_validate.outputs.validated_set_hash`; prod (and `prod_deploy`, once built) passes
  `beta=` and `gamma=` (e2, "Prod"), each from its own job's output, never the same output twice.
  **R20**'s last step carries the "main is at" line on every job.
- **R4, amended:** `id-token: write` also on a job whose stage holds a `BUCK2_TARGET` validation
  with a `cloud` (and on `prod_deploy`, once built); no release job gains any other permission.
- **R25, new:** the `gamma` job's `timeout-minutes` is exactly 30 plus the machine file's sum of
  `attempts` × `timeout_seconds` over gamma's `BUCK2_TARGET` validations; its `kci run` carries no
  `--only`; its `if:` admits a push to `main` only; the `secrets` context appears in no release job
  but `gamma`, and there only as the names the machine file gives, on the step that runs `kci`.
- **R26, new, over every file in `.github/workflows/`** (today's rules read `kci.yml` and `pr.yml`
  only; it lands in P7): **no job names an environment**, in any form (a string, a mapping's `name`,
  an expression), except `kci.yml`'s release jobs; a job of a workflow triggered by `workflow_run`
  or `pull_request_target` names none, `kci.yml`'s included. The release jobs are R2's, on `main`
  today: each runs in exactly its own stage's `environment` (a string or `{name: ...}`), a part job
  in none, and a stage with a `break_glass_environment` in exactly one expression, compared byte for
  byte, so a release job naming another stage's environment, or an expression with any other branch,
  is already refused. R26 keeps no list of protected names, so `farm`, `farm-pr`, `gamma-breakglass`
  until M4 deletes it, and any environment created later are covered with no edit; a workflow that
  needs an environment is a reviewed change to R26. G0 binds the `gamma` subject to the branch
  `main`, not to a workflow, so without R26 any workflow file on `main` could name
  `environment: gamma` and get the subject the gamma accounts trust; no workflow does today (only
  `kci.yml` names an environment, none uses `pull_request_target`, and `main_red.yml`, on
  `workflow_run`, names none). Its "`kci.yml`'s included" clause is R6's on `main` (`kci.yml` takes
  `push` and `workflow_dispatch` only), as the release jobs' environments are R2's. Fixtures: e2's row 33.
- R9, R11 and R14 need no change: gamma is a FULL run, so R9's "every validation exactly once" holds
  with no exception.

## g. Slices

Each slice: the check that is red before it. **Go** marks a project-owner action.

| # | slice | red before | go |
|---|---|---|---|
| G0 | **Lock `gamma` to `main`, first** (#1168's S0): `gamma`'s deployment branches set to `main`; **`gamma-breakglass` created now** with a required reviewer and administrator bypass off (`kci.yml` names it on every manual run, the channel `gamma` trusts its subject until M3, and GitHub creates a named environment that does not exist with no protection rule, so today the first manual run would publish to the channel `gamma` unreviewed; it cannot reach prod, whose installs check each file's sha256). The drift check in `build` reads every environment the channels file's push identities name, `gamma-breakglass` until M3 (the old channel trusts it until then, though after M2 no file names it), every environment of a stage holding a `BUCK2_TARGET` validation or a DEPLOY step, `prod`, and each of `farm` and `farm-pr` whose subject P0 finds the farm trusts; it fails the release unless each **exists**, a push environment's policy is `main` only, and a break-glass environment has a required reviewer and `can_admins_bypass` false (today it is true on every environment). It reads `build` for existence only (it is not locked to `main`: break-glass builds run on any ref, and its subject reaches only the farm). The read is anonymous: this repository is public, and an unauthenticated `GET .../environments/<name>` and `.../deployment-branch-policies` answer with the protection rules, `can_admins_bypass` and the policy (200, read for this revision). An environment's secrets are **not** readable that way (`GET .../environments/build/secrets` answers 401 without a token), so "`build` and the publishing environments hold no secret" is a **settings review**, not a check: the project owner confirms it on the settings page at G0 and at M1, and the slice records it; the check holds no token. A failed read fails the release | the drift check fails on today's settings; canned answers each red: `gamma` with no policy; `prod` with no policy; `build` absent; `gamma-breakglass` absent; `gamma-breakglass` with no reviewer; `gamma-breakglass` with a reviewer and `can_admins_bypass` true; `beta` with no policy (once M1 exists); after the change it passes | **Go** (repository settings) |
| P0 | **Probe** on a `probe/*` branch: hosted jobs that only `sleep` and `echo`, `permissions: {}` (one job `actions: write` on its own run), no secret, farm, cloud or upload, plus a `probe-wait` environment with a required reviewer. Records (a) the run conclusion when a job is replaced in its group; (b) a job waiting on a reviewer holds only its group; (c) a job skipped by `if:` takes no group slot; (d) a re-run attempt joins the same group and downloads attempt 1's artifact; (e) whether `rerun-failed-jobs` re-runs cancelled jobs, does not re-run a succeeded one, and lets attempt 2 read attempt 1's `needs` outputs. Plus a read of the farm's trust policy: no `gamma` or `beta` subject in it, and which of `farm` and `farm-pr` it trusts (those join the drift check, G0) | each fact written here with the run's URL, or P2 and P4 stop | **Go**: it starts workflow runs and creates an environment |
| P1 | kci: `never_backward` per run; the main-line filter; the descendant read and `SUPERSEDED`; R24's admission; gamma's read of prod's listing; the "carried" list | c's table, rows 1, 3 to 9 and 11; rows 2 and 10 guard | none |
| P2 | `main_red.py`: `classify` from jobs and the `superseded` step; `last_green` filtered; `stalled`, its re-run and its issue | d's tests (a) to (e) | the re-run needs question 6 |
| M1 | Create the beta channel, its trusted publishers, and the environments `beta` and `beta-breakglass` (e3) | the drift check red on a canned `beta` with no policy | **Go** (channel host and repository settings) |
| M2 | The rename switch, one PR (e3) | a fixture machine publishing to `beta` refused by today's channels file; the immutable-form parser row | **Go**: it changes where every release publishes |
| M3 | Remove the old channel's trusted publishers (e3) | the publisher list read back, or recorded | **Go** (channel host); before P9 |
| M4 | The old channel kept read-only, then deleted (e3, question 13) | its listing read: no build after M2 | **Go** (channel host) |
| P3 | Tasks: the loopback audit; the payload digests on a real tree; the two planted trees (e). kci: `TEST` and `checks`, S10c's derived set added, `build`'s read of the beta listing before `test`, the payload comparison | machine fixtures (`TEST` off the farm with no validation; `checks` off the farm; `checks` on PUBLISH) refused; c row 4; a planted payload mismatch refused; the commands pinned (mutants: drops the build, drops the test); the two trees as e says | none |
| P4 | The groups, one PR: job-level groups on every release job, the `superseded` steps, R23/R24 guards and the line on every job; R16, R23, R24; ci.md's "Queued runs" and "Never backward" for every stage; the paths to continuous publish become links | fixtures refused: a workflow-level group, a job without a group, `queue: max`, a job missing R23's conjunct or step, a release job without the output `superseded`, a `prod_deploy` job whose conjunct reads `gamma` or `beta_validate` instead of `prod` (mutant "J is always the hash job"), a job without R24; today's `kci.yml` fails the new R16 | **Go**: changes the release |
| P5 | Retention of `kci-release-*` to the ruled value | none (a setting) | **Go** with question 3 |
| P6 | #1168's S10c derived checks run in `build`'s `test`; S12's in `beta_validate` | as #1168 states them | as #1168 |
| P7 | kci: `BUCK2_TARGET` and its machine-file refusals (row 29, the trust-table refusal included); the start checks; `--list-cases` and the exact case set; the exchange; the child environment; the flags; the timeout and process-group kill; the verdict; the output kept off the log; the one re-run; the every-validation rule for every stage and the hash fix; prod's named hashes, with the bare form kept while one stage on the chain declares validations; the DEPLOY trust-table refusals (row 29); R26 (f) | e2's rows 1 to 11 and 13 to 33 with their lettered rows (12, 16a, 19b, 31 and row 33's (g) to (j) guard); rows 19, 19a and row 29's two DEPLOY fixtures are red on `main` today | none: no machine file uses the kind until P9, today's `kci.yml` keeps working (row 31), and today's workflows pass R26 (row 33's guard) |
| P8 | `build` builds every `BUCK2_TARGET` target and ships each executable and its sha256; the lint on `src/tests/real_cloud/`; the first AWS suite, with its README naming its owner, teardown and budget alert | e2's rows 17 and 30; the suite builds on the farm (`local: 0`) and `buck2 test` over its directory runs nothing | none: it runs no suite |
| P9 | The wiring, one PR: the `gamma` stage of f; `kci.yml`'s `gamma` job (`--secret-store env`, the two secrets on its `kci` step, `timeout-minutes` per R25, push-only `if:`, `validated_set_hash` output); prod's `after`; `kci.yml`'s named `beta=` and `gamma=` and R19's clause (e2, "The transition"); R4 and R25 | fixtures refused, each **correct except one clause**: a secret named in another job; a `timeout-minutes` other than R25's; a `kci run` with `--only` omitting `real-cloud-aws` (timeout and secrets correct, so only the selection clause can turn it red); prod without `gamma=`; prod passing `needs.beta_validate.outputs.validated_set_hash` as both `beta=` and `gamma=` | **Go**: the cloud trust for the immutable `environment:gamma` subject (question 9), only after G0 is green and M3 is done. The first push spends real money |

**Order.** G0 first. M1 → M2 → M3 → M4. `prod_deploy` (e2, "Prod deploy") lands with the DEPLOY
step's own wiring ([deploy_step.md](deploy_step.md)), never as a step of `prod`; P7's row-29 refusal
makes the shared form unwritable before then. P1 to P3, P7 and P8 merge on their own and change nothing
that runs. P4 depends on P0 to P3 and on M2 (it names the renamed jobs). P9 depends on **G0 applied
and green**, **M3 done**, P7 and P8, and on P4 only for gamma's job-level group: until P4, gamma holds
the workflow-level `kci-release-main`, which is single-flight already.

## h. Questions for the project owner

1. **Beta is three jobs (a departure from rule 2).** `build` (farm), `beta` (publish) and
   `beta_validate` (installs) are three slots: one job would put an install's third-party code next
   to the publishing token, or the farm's token next to a publishing one (R11), and jobs sharing one
   group would let a stage cancel its own pending newer run. So beta can build C while publishing B
   and installing A. *Recommendation:* accept; each job is pinned to its own set's digests. Gamma is
   one job and holds rule 2 literally; prod does until DEPLOY is built (question 14).
2. **Break-glass runs and the push groups.** Manual runs keep per-ref groups, so a break-glass
   publish to beta could overlap main's: two writers to one channel. *Recommendation:* beta's
   **publish** job joins `kci-beta-main` in every non-dry run, one writer per channel; `build` stays
   per ref. A break-glass arrival can then replace main's pending publish, and `stalled` re-runs it;
   a main push can replace a pending break-glass publish, which its operator starts again.
3. **Retention.** *Recommendation:* 30 days; a longer pause fails the held run red, the next push
   carries its commits.
4. **Break-glass builds in the beta channel.** They can out-number `main`; the main-line filter keeps
   them from stalling `main`, but "latest" from beta may be a branch's build. *Recommendation:*
   accept; consumers install from prod.
5. **The real-cloud suites as a release gate.** One flaky suite blocks prod. *Recommendation:* gate,
   with #1168's re-run-once and quarantine-by-PR policy.
6. **`actions: write` for `main_red`'s repair.** *Recommendation:* grant it to `main_red`'s job only,
   for one `rerun-failed-jobs` of a run whose head is main's releasable tip.
7. **P0's probe.** *Recommendation:* go; hosted minutes only, no cloud.
8. **A tip with no push run.** *Recommendation:* accept, with `stalled`'s issue; refusing skip
   markers in the PR check cannot close it (the merge commit's message is written after the check).
9. **The cloud credential (a go, after G0 and M3).** *Recommendation:* go for AWS first: a role whose
   trust accepts only this repository's OIDC issuer, AWS STS's audience and the subject
   `repo:<owner>@<owner id>/<repo>@<repo id>:environment:gamma` exactly (the immutable form; never
   the name form); no access key. Its permissions are the suites' and nothing more, in accounts used
   only by gamma; the role and region are `gamma` secrets only. The trust policy's text is reviewed
   with the go and read back after creation. GCP and Azure follow the same shape, adding the
   `environment` and `repository_id` claim conditions their trust can express.
10. **Who owns the suites and their cost.** *Recommendation:* each suite's README names an owner of
    its teardown, its leak sweep (by validation run id) and a budget alert on the gamma accounts, who
    answers its flake issue; no suite joins without one.
11. **Deploy and tests in one gamma job, once DEPLOY is built.** They share the `gamma` subject, so a
    suite can do what the gamma deploy role can in the gamma accounts. *Recommendation:* accept; the
    gamma accounts hold only gamma. The alternative, a `gamma-tests` environment trusted only by a
    test role, needs a second gamma job and so two candidates in gamma at once.
12. **An override after a red.** None is built. The **only allowances** are kci's one in-job re-run
    of a suite (`attempts: 2`, #1168's flake policy) and a re-run of the `gamma` job, now safe
    because gamma publishes nothing (R24 admits a re-run only for the tip). **Combined bound:** each
    run of the `gamma` job runs a suite at most `attempts` (2) times (rows 10 and 11), so one
    whole-job re-run makes at most **4 runs of each suite** for one release, and each further job
    re-run adds 2. kci does not count job attempts (GitHub caps a run at 50 re-runs), so the bound
    past one re-run is this recommendation and the run's attempt history, not a check.
    *Recommendation:* keep exactly these two allowances, with at most one whole-job re-run per
    release (a `stalled` repair counts as it); a release past a red result is a revert or fix on
    `main`.
13. **The old channel `gamma` (M4).** *Recommendation:* no copy into `beta`; keep `gamma` read-only
    for 30 days after M2 with a notice in `docs/releases.md`, then delete it; each of M1 to M4 is its
    own go.
14. **Prod as two jobs, once DEPLOY is built (a departure from rule 2).** `prod` publishes and
    `prod_deploy` deploys (e2, "Prod deploy"), each with its own environment, subject and group, so
    prod can publish C while deploying B; whether a cell may go backward is the deploy step's
    per-cell record ([deploy_step.md](deploy_step.md), its question Q12), as for gamma (c).
    The alternative, one prod job holding both, puts the prod channel's publishing identity beside
    the code DEPLOY runs, the pairing M3 removes from gamma. *Recommendation:* accept two jobs; the
    machine file refuses the shared form (row 29), so choosing it later would be a reviewed change to
    kci, not a setting.

## Future: gamma bake

**Status: out for now (ruling 5), tracked in #1183.** The goal: after gamma's validations pass, the
candidate stays in gamma for 24 hours under watch before prod is promoted. A bake is useful only if
something watches the candidate during it; without that it is only a delay. It is not designed here,
and no slice above builds any of it. It is designed and built when every prerequisite exists:

1. **Canaries and monitoring of the deployed candidate**: errors, drift and cost, with a red signal
   that stops promotion, owned by the deployment's observability owner.
2. **The real-cloud tests' own safety nets**: their sweeper's leak reports and budget alerts on the
   gamma accounts, so a day-long bake cannot leak resources or spend unnoticed.
3. **Lock-through-bake mechanics.** In e2 one hosted job holds `kci-gamma-main` through gamma's
   real-cloud validations. A GitHub-hosted job runs for at most 6 hours, so no job can hold the
   group for 24. The bake needs a lock that is not a running job, for example a bake record that
   prod's admission reads and gamma's next run respects, with its own planted tests (a red canary
   mid-bake, the window not yet elapsed, a newer candidate arriving mid-bake).
4. **No exception without the project owner's explicit go**: no shortened bake, no skipped bake, no
   override of a red bake.
