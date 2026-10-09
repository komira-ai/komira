# The staged pipeline: build once, then beta, gamma and prod, each one run at a time

Status: design, not built. **EXISTS** names code on `main`; everything else is PROPOSED. New names
(all absent from `main`): the stage `beta`, the jobs `beta` and `beta_install`, the step kind `TEST`,
the step field `checks`, the outcome `SUPERSEDED` (as a successful stop), the job output `superseded`,
the step name `superseded`, the `main_red` decision `stalled`, rules R23, R24 and R25, the validation
kind `EXTERNAL_STATUS`, gamma's validation `real-cloud`, the dispatch event type `kci-gamma-validate`
and the status context `kci-real-cloud/<set hash>`. Related: continuous
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
- **(B) Gamma is single-flight:** one run at a time, the latest candidate wins (b).
- **(C) Prod is promoted when every gamma validation has passed**, with no wait after it.
- **(D) Gamma's validations include an external real-cloud validation**, run privately by the
  operator, outside this repository ([e2](#e2-gamma-the-external-real-cloud-validation)).

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
credential; e2's validation keeps that true for this repository (the cloud credential is the
operator's, outside it), and #1168 points here for it. Merge order: **#1168 first, then this doc**; the two do not conflict, and the
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
its job holds `kci-gamma-main` through the external validation's wait (e2), up to 90 minutes per
dispatch and two dispatches at most, so gamma takes at most one candidate per pass and every commit
that lands meanwhile coalesces into the next (rule 3). A release duration therefore includes up to
three and a half hours in gamma (e2, "Fits a hosted job").

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

## e2. Gamma: the external real-cloud validation

Gamma's validations become three: the two installs `validate` runs (EXISTS) and **`real-cloud`**, an
operator-run validation against real clouds. This repository runs no part of it and holds no cloud
credential for it: it **asks** for the validation and **reads** its result. The interface, agreed
with the validation's owner:

| | |
|---|---|
| ask | `POST /repos/{receiver}/dispatches` (a `repository_dispatch`), `event_type: kci-gamma-validate`, `client_payload: {set_hash, commit, deadline_utc}` |
| receiver refuses | a `commit` not on `main`, or a `set_hash` other than the one that commit's gamma run published |
| answer | a commit **status** on `commit` in this repository, context exactly `kci-real-cloud/<set_hash>`, state `success`, `failure` or `error` |
| passes | `success` only |
| fails closed | `failure`; `error` (an infrastructure fault on the operator's side); no status by the deadline; a status whose context names another set hash |
| deadline | 90 minutes after the dispatch (the operator's run is capped at 75) |
| after a red | gamma fails and nothing promotes; re-run once (#1168's flake policy); no override without the project owner's explicit go |

**Where it runs: in the `gamma` job, after the publish.** `kci run --stage gamma --only step:publish
--only validation:real-cloud` (one `kci run`, R5). The job keeps its job-level group
`kci-gamma-main` (b) for the whole wait, so gamma is single-flight through its validation (B):
while it waits, a newer commit's gamma job is pending, a still newer one replaces it, and the
running one is never cancelled. It cannot be a part job like `validate`: a part job holds no
environment (R9), and the dispatch credential is an environment secret; and a job of its own in
the same group would let the stage cancel its own pending newer run (question 1).

**The steps kci takes (P7):**

1. **Before any effect,** with the run's other start checks: the run is a push to `main`, both
   secret names resolve (`--secret-store env`, kci's existing store for secret material), and
   `REVISION` is a full commit id. Otherwise `REFUSED`, exit 2, and nothing is published (a
   publish that cannot be validated never starts).
2. **Publish** (EXISTS).
3. **The clock is GitHub's.** kci reads this repository's statuses of `commit` once and takes
   `T0` from the response's `Date` header. `deadline_utc = T0 + 90 min`. Every later "now" is a
   later response's `Date`, never the runner's clock.
4. **Dispatch** with `{set_hash, commit, deadline_utc}`. Any answer but `204` is a failed attempt;
   kci does not wait on an ask that was not accepted.
5. **Wait.** Every 60 seconds, list `GET /repos/{this repo}/commits/{commit}/statuses` (newest
   first, as GitHub documents), reading pages until a status is older than `T0`. Keep only
   statuses whose context is **exactly** `kci-real-cloud/<set_hash>` and whose `created_at` lies in
   `[T0, deadline_utc]`; the newest of them decides. `success` → VALIDATED; `failure` → FAILED;
   `error` → FAILED, reported as an operator-side fault; `pending`, none yet, or a read that failed
   → keep waiting. At the deadline with no decision → FAILED, "no status by the deadline". A status
   for another set hash is listed in the summary and never counted.
6. **Re-run once.** After a FAILED attempt kci dispatches once more with a fresh `T0`; a second
   FAILED fails the validation. Each attempt stands alone: a status written before its own `T0`,
   the first attempt's red included, never decides the second.
7. **Result.** kci writes the validated set hash only when this validation VALIDATED (as it does
   for every validation), and the job hands it on as `real_cloud_set_hash`.

A late answer to the first attempt that lands after the second `T0` is counted: it is a status for
the same commit and the same set hash, so it judges the same bytes.

**Prod (C).** `prod` already `needs: [gamma, validate]`, so a red `gamma` job skips prod. That is
not enough on its own: R19 is amended so that prod's job also reads `needs.gamma.outputs.real_cloud_set_hash`
and kci refuses (`KCI-E-SET-HASH`, exit 3, before any effect) unless it equals `validate`'s
`validated_set_hash`. Prod publishes when, and only when, every gamma validation has vouched for
the same set. Nothing waits after that (A).

**Fits a hosted job.** GitHub's documented limit: "Each job in a workflow can run for up to 6 hours
of execution time" on a GitHub-hosted runner (GitHub Actions limits). The `gamma` job's worst case is
its publish (today's `timeout-minutes: 30`) plus two waits of 90 minutes: 210 minutes.
`timeout-minutes` becomes **240**, under the 360 the platform allows; R25 pins it (f).

**Break-glass and dry runs.** Break-glass never reaches prod (EXISTS), so a break-glass gamma run
does not select `real-cloud`; `gamma-breakglass` holds neither secret, and the receiver would
refuse a commit off `main` anyway. A dry run (`--plan`) prints the dispatch it would send and sends
nothing.

**The credentials.**

- **The dispatch credential** (a **go** item, question 9). Sending a `repository_dispatch` to
  another repository needs a credential of that repository: this repository's job token cannot.
  GitHub lists `POST /repos/{owner}/{repo}/dispatches` under the repository permission **Contents:
  write**, and accepts nothing narrower. Minimum: a token limited to the **one** receiving
  repository, that permission alone, with an expiry. It is stored as a secret of the **`gamma`
  environment only** (deployment branches: `main`), so only the `gamma` job of a push to `main`
  can read it; no repository-level or other environment's secret holds it. The receiver's
  `owner/name` is a second secret of the same environment, so it appears in no file and no log.
  Contents write could also push to the receiving repository; the receiver's branch protection is
  what keeps that from changing its code, and that is the operator's side to hold.
- **Reading the answer** needs `statuses: read` on the `gamma` job's own token (R4 amended for that
  job alone); an anonymous read shares a hosted runner's address and its rate limit.
- **Writing the answer** is the operator side's credential, with `statuses: write` on this
  repository. Anyone with push access can also write a status with any context; question 10
  proposes pinning the writer.

**Planted tests (`src/kci_validate/tests/`, a fake GitHub API in process: a dispatch endpoint that
records requests, a statuses list the test scripts, and a `Date` header the test sets).**

| # | case | expect | mutant caught |
|---|---|---|---|
| 1 | no status at all; the fake clock passes the deadline | FAILED, "no status by the deadline", after two dispatches | absent counts as a pass; no deadline |
| 2 | `failure` for the exact context | FAILED (both attempts red) | any final state passes |
| 3 | `error` for the exact context | FAILED, reported as an operator-side fault | `error` treated as success, or waited on |
| 4 | `success` only for `kci-real-cloud/<another hash>` | FAILED at the deadline; the other hash listed | prefix match on `kci-real-cloud/` |
| 5 | `success` for the exact context, `created_at` before `T0` (a stale answer) | FAILED at the deadline | drop the `T0` floor |
| 6 | `success` for the exact context, `created_at` after the deadline | FAILED | compare with the runner's clock or the job's end |
| 7 | the fake's `Date` runs 30 minutes ahead of the runner clock | deadline taken from `Date`: FAILED at GitHub's deadline, not the runner's | trust the runner clock |
| 8 | `pending`, then nothing until the deadline | FAILED | `pending` counts as a pass |
| 9 | dispatch answered `404` | that attempt FAILED with no wait; second attempt made | ignore the dispatch status |
| 10 | first attempt `failure`, second attempt `success` | VALIDATED, exactly two dispatches | no re-run |
| 11 | both attempts red | FAILED, exactly two dispatches | unbounded re-runs |
| 12 | older `success` and newer `failure`, both in the window | FAILED (the newest decides) | first match wins, or any success wins |
| 13 | `success` for the exact context in the window | VALIDATED, `real_cloud_set_hash` written | guard (green before and after) |
| 14 | the dispatch's bytes | `event_type` `kci-gamma-validate`; payload keys exactly `set_hash`, `commit`, `deadline_utc`; deadline `T0` + 90 min | payload drift |
| 15 | a push run whose secrets do not resolve | `REFUSED` exit 2, zero publish and dispatch calls | check after publish |
| 16 | prod with `real_cloud_set_hash` absent or unequal to `validate`'s | `KCI-E-SET-HASH`, exit 3, zero uploads | prod reads `validate`'s hash only |

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

Gamma's publish step gains a third validation (e2); the two installs are unchanged:

```text
validation {
  name: "real-cloud"
  kind: EXTERNAL_STATUS               # NEW: dispatch, then wait for a commit status (e2)
  event_type: "kci-gamma-validate"
  status_context: "kci-real-cloud/"   # kci appends the set hash; matched exactly
  deadline_s: 5400                    # 90 min after the dispatch
  attempts: 2                         # one re-run
  credential: "KCI_REAL_CLOUD_TOKEN"  # secret NAMES, resolved by --secret-store env
  receiver: "KCI_REAL_CLOUD_RECEIVER"
}
```

`kci_release_machine` refuses `EXTERNAL_STATUS` on any stage without an environment, on a part
job's validations (R9: no environment there), a `deadline_s` above 5400 and `attempts` above 2.

| stage | job(s) | environment | token | runs on |
|---|---|---|---|---|
| build | `build` | `build` | farm | farm |
| beta | `beta` (`--only step:e2e`), `beta_install` | `beta`; none | farm; none | farm; hosted |
| gamma | `gamma` (publish, then `real-cloud` on a push), `validate` | `gamma` (holds the dispatch secrets) / `gamma-breakglass` (holds neither); none | OIDC and `statuses: read`; none | hosted |
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
- **R19, amended for prod (e2):** prod's job also reads `needs.gamma.outputs.real_cloud_set_hash`
  and passes it to kci, which refuses it unequal to `validate`'s.
- **R4, amended:** the `gamma` job alone may add `statuses: read`; every other release job keeps
  `contents: read` and R4's `id-token` only.
- **R25, new:** the `gamma` job's `timeout-minutes` is exactly 240; on a push it selects
  `validation:real-cloud`; the `secrets` context appears in no release job but `gamma`, and there
  only as the two names the machine file gives, on the step that runs `kci`. R9 ("together the
  stage's jobs run every validation exactly once") counts `real-cloud` as run by `gamma`; its
  push-only selection is R9's one stated exception, and is safe because a break-glass run never
  reaches prod.

## g. Slices

Each slice: the check that is red before it. **Go** marks a project-owner action.

| # | slice | red before | go |
|---|---|---|---|
| P0 | **Probe** on a `probe/*` branch: a workflow of hosted jobs that only `sleep` and `echo`, `permissions: {}` (one job `actions: write` on its own run), no secret, no farm, no cloud, no upload, plus a `probe-wait` environment with a required reviewer. It records, from the runs API: (a) the run conclusion when a job is replaced in its group; (b) a job waiting on a reviewer holds only its group, and whether a newer arrival replaces it; (c) a job skipped by `if:` takes no group slot; (d) a re-run attempt joins the same group and downloads attempt 1's artifact; (e) on a run whose first job succeeded and whose second was cancelled while pending, a token-requested `rerun-failed-jobs` starts, and records: whether cancelled jobs count as failed (if not, the per-job `.../jobs/{job_id}/rerun` is tested instead), that the succeeded first job is **not** re-run, and that attempt 2 reads attempt 1's `needs` outputs and downloads its artifact. Plus a read of the farm's trust policy for a `beta` subject. Existing runs cannot show (a) to (e): today's `kci.yml` has only the workflow-level group (line 203). | each fact written here with the run's URL, or P2 and P4 stop | **Go**: it starts workflow runs and creates an environment |
| P1 | kci: `never_backward` per run; main-line filter; the descendant read and `SUPERSEDED` (exit 0, output `superseded`); R24's admission check; gamma's "carried" list | c's table, rows 1, 3 to 9; rows 2 and 10 guard | none |
| P2 | `main_red.py`: `classify` from jobs and the `superseded` step; `last_green` filtered; `stalled`, its re-run, and its issue when the tip has no push run | d's tests (a) to (e) | the re-run needs question 6 |
| P3 | Tasks: the loopback audit; the payload digests on a real tree (e); beta's command on the two planted trees (e). kci: `TEST`, `checks` (`buck2 build`, then `buck2 test`), beta's read of gamma's listing, step 4b for TEST, the payload comparison, validations from the handed local channel; `build` writes the local index | machine fixtures (TEST with neither; `checks` on PUBLISH) refused; c row 4; a TEST run with a mismatched `--release-set-hash` refused exit 3 with zero runner calls, and without the flag under Actions exit 2 (mutant: 4b without TEST), copying the prod case at `test_kci_ref_check.mojo:542-554` for beta, gamma and validate; a planted payload mismatch refused; the commands pinned to `build` then `test` (mutants: drops the build, drops the test); beta's two commands alone red on each of the two planted trees, and each tree green under the command its mutant keeps (e). Regression (green before, mutant named): a local-channel record with another sha256 refused (mutant: skip the compare in `conda_install_env.mojo`) | none |
| P4 | The switch, one PR: `release/machine.textproto` with beta; `kci.yml` with job groups, `beta`, `beta_install`, the `superseded` steps, R23/R24 guards and the line on every job; R16, R23, R24 in `kci_workflow_check`; ci.md's "Queued runs" and "Never backward" rewritten for every stage; the paths between this doc and continuous publish become links | fixtures refused: a workflow-level group, a job without a group, `queue: max`, a job missing R23's conjunct or step, gamma reading `beta`'s unvalidated `set_hash` (R19), a job without R24; today's `kci.yml` fails the new R16 | **Go**: changes the release; the first push creates `beta` and spends farm time |
| P5 | Retention of `kci-release-*` to the ruled value | none (a setting) | **Go** with question 3 |
| P6 | #1168 S10c's derived checks join beta's `checks`; S12's join `beta_install` | as #1168 states them | as #1168 |
| P7 | kci: the `EXTERNAL_STATUS` validation kind and its machine-file refusals; the dispatch, GitHub's clock, the wait, the exact-context read and the one re-run (e2); prod's second hash (R19 amended); a fake GitHub API for tests | e2's table, rows 1 to 12 and 14 to 16 (13 guards); machine fixtures refused: `EXTERNAL_STATUS` on a stage without an environment, `deadline_s` 5401, `attempts` 3 | none: it sends nothing until P8 wires it |
| P8 | The wiring, one PR: `real-cloud` in gamma's step in `release/machine.textproto`; `kci.yml`'s `gamma` job with `--secret-store env`, the two secrets on its `kci` step, `statuses: read`, `timeout-minutes: 240`, `real_cloud_set_hash` handed to prod; R4 and R19 amended, R25 and R9's exception in `kci_workflow_check` | fixtures refused: `statuses: read` on any other job, a secret named in any other job or in `gamma-breakglass`'s path, `timeout-minutes` other than 240, prod without the second hash; today's `kci.yml` fails R25 | **Go**, two: the dispatch credential (question 9) and the operator side's status writer (question 10); the first push dispatches to the operator's side |

P1, P2, P3 and P7 merge on their own and change nothing that runs (P1 changes only what a push to
gamma may do when the channel is ahead; P2's `stalled` reads only push runs, which are unchanged
until P4; P7 adds a kind no machine file uses). P4 depends on P0 to P3; P8 depends on P7, and on
P4 only for gamma's job-level group: until P4, gamma's wait holds the workflow-level
`kci-release-main`, which serialises whole runs and is single-flight already.

## h. Questions for the project owner

1. **Two jobs per stage (a departure from rule 2).** Beta (`beta`, `beta_install`) and gamma
   (`gamma`, `validate`) are two slots each: one job would put an install's third-party code next to
   the farm or publish token, and two jobs sharing one group would let one stage's second job cancel
   its own first job's pending newer run. So beta can test C while installing B. *Recommendation:*
   accept; each job is pinned to its own set's digests, so an overlap cannot check the wrong files.
   Under ruling (B) this is the one overlap gamma keeps: its `gamma` job, which publishes and holds
   the real-cloud wait (e2), is one slot, and prod needs both jobs to vouch for one set hash.
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
9. **The dispatch credential (a go).** e2's dispatch needs a credential of the receiving
   repository, stored as a secret here. *Recommendation:* go, at the minimum scope: limited to that
   one repository, the permission **Contents: write** alone (the only one GitHub accepts for a
   dispatch), with an expiry and a rotation owner; held as a secret of the `gamma` environment
   only, never of the repository or of `gamma-breakglass`, beside a second secret naming the
   receiver.
10. **Who may write the answer.** The answer is a commit status, and anyone with push access, or
    any workflow here granted `statuses: write`, can write one with any context. R4 already keeps
    `statuses: write` off every release job, but not off people with push access. *Recommendation:*
    go for the operator side's writer to hold `statuses: write` on this repository and nothing
    else, and, agreed with the validation's owner as an addition to the interface, kci also checks
    each counted status's `creator` against an expected writer held as a third `gamma` environment
    secret (so no account is named in this repository). Without it, a hand-written `success` would
    promote.
11. **The order inside gamma.** The real-cloud validation runs in the `gamma` job, after the
    publish and **before** `validate`'s installs, which run in their own slot after it: putting the
    installs' third-party code in the job that holds the publish token and the dispatch secret is
    what the split prevents (question 1). The cost: a set whose README install would fail is still
    validated against real clouds first, on the operator's side. *Recommendation:* accept; beta's
    `beta_install` has already installed the same bytes from the local channel (e), so an install
    failure in `validate` is rare. The alternative, one more job between `validate` and the wait,
    cannot hold gamma's group (b).
12. **An override after a red.** e2 builds none: no flag, input or reviewer lets prod pass a red,
    absent or stale answer. *Recommendation:* keep it so; a release past a red real-cloud result is
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
3. **Lock-through-bake mechanics.** Today one hosted job holds `kci-gamma-main` through the
   validation's wait (e2). A GitHub-hosted job runs for at most 6 hours, so no job can hold the
   group for 24. The bake needs a lock that is not a running job, for example a bake record that
   prod's admission reads and gamma's next run respects, with its own planted tests (a red canary
   mid-bake, the window not yet elapsed, a newer candidate arriving mid-bake).
4. **No exception without the project owner's explicit go**: no shortened bake, no skipped bake, no
   override of a red bake.
