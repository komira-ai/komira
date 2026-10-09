# The staged pipeline: build once, then beta, gamma and prod, each one run at a time

Status: design, not built. **EXISTS** names code on `main`; everything else is PROPOSED. New names
(all absent from `main`): the stage `beta`, the jobs `beta` and `beta_install`, the step kind `TEST`,
the step field `checks`, the outcome `SUPERSEDED` (as a successful stop), the job output `superseded`,
rule R23. Related: continuous publish (`docs/design/continuous_publish.md`, open in #1168), [ci.md](../ci.md),
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
`src/kci_workflow_check` requires that group and refuses a job-level `concurrency:`. So rules 1 and 4
already hold (the set hash, R19); rules 2 and 3 hold for the pipeline as a whole, not per stage: a
fast `build` waits for a slow `prod`, and pausing prod (a required reviewer) stalls gamma too.

**What this doc supersedes in continuous publish (#1168):** its section "Trigger:
per merge, coalesced" (the one-run-per-push, whole-pipeline coalescing), its "continuous means within
one release duration" arithmetic, and in "The gate between gamma and prod" the **placement** of its two
gates: S10c's release checks move from `build` into beta's `checks`, and S12's installed-bytes checks
move from gamma's `validate` to `beta_install`, so both run **before** anything is published.
**What stays:** S0 (lock gamma), the release ledger (S1, S2), native packaging (S3), the emulator tier
and its safety rules (S4 to S9), S10a and S10b, yank and its tombstone (S11), and its questions.

## a. Where the build-once files live, and how each stage proves it has them

**Decision: one workflow run carries all four stages, so the files stay a workflow artifact of that
run.** `build` already uploads `kci-release-<revision>` (the release directory, the kci binary and the
build's result) and every later job downloads it by name. GitHub scopes `actions/download-artifact`
to the current run by default; another run's artifact needs `run-id` and a `github-token` with
`actions: read`, which R4 grants no release job. Inside one run nothing new is needed. The action's
`digest-mismatch` defaults to `error` (a corrupted download fails), but that is transport, not the
proof.

**The proof is kci's, at every stage (EXISTS for gamma, validate and prod; extended to beta):**
`--release-set-hash` makes kci recompute the release directory's set hash (each file's manifest sha256)
and refuse another one, `KCI-E-SET-HASH`, exit 3, before any check, upload or install
(`src/kci_cli/dispatch.mojo`, step 4b). The hash is handed job to job and never typed (R19): `build`'s
`set_hash` → `beta` and `beta_install` → `beta_install`'s `validated_set_hash` → `gamma` and `validate`
→ `validate`'s `validated_set_hash` → `prod`. kci writes a validated hash only for a real run whose
selected validations all VALIDATED and SUCCEEDED, so a stage cannot hand on a set it did not check.
Gamma's and beta's installs are pinned: each install name must resolve to the release's version, build
string and sha256 (`src/kci_validate/readback.mojo`, check 2), so a newer build in the channel cannot
stand in.

**Retention.** `kci-release-*` is kept 14 days (`kci.yml`). A run whose prod waits longer (a pause)
fails to download and goes red; it never publishes other bytes. Recommendation: 30 days (question 2).

**Rejected: a staging bucket or a private channel.** It needs a cloud credential, a new trust and
spend, and buys nothing while the stages share a run.

**Beta's input** is the same artifact. **Beta is not a channel**: nothing is uploaded. `build` also
writes the local channel index of the release directory (`komira_pack conda-index`, the PRE-PUBLISH
mode `kci run --channel` reads today), and beta installs from that directory. The local channel's reads
already check each record's sha256 against the release (`src/kci_validate/conda_install_env.mojo`, "A
LOCAL CHANNEL"). The flag `--channel` stays refused under GitHub Actions and by R14: beta gets its local
channel from its step kind (f), not from a flag a workflow could point anywhere.

## b. One run at a time per stage, latest wins

GitHub's concurrency documentation: in a group, at most one job runs; by default "any existing
`pending` job or workflow in the same concurrency group will be canceled and the new queued job or
workflow will take its place"; `cancel-in-progress: true` would cancel the running one too; groups
compare ignoring case; ordering is FIFO by the time each one started waiting, "not guaranteed"; the
optional `queue: max` keeps up to 100 pending. With `cancel-in-progress: false` and no `queue`, a group
is exactly rules 2 and 3: one running, one pending, the newest arrival replaces the pending one.

**Decision: one workflow (`kci.yml`), no workflow-level group, a job-level group on every release
job.** On a push to `main` the group is `kci-<job id>-main`; a manual dry run `kci-<job id>-plan-<run
id>`; any other manual run `kci-<job id>-ref-<ref name>` (today's three-way split, per job). `queue` is
refused: `queue: max` would run every commit, against rule 3.

**Rejected: separate workflows chained by `workflow_run`.** From GitHub's event reference and this
repository:

- `workflow_run` "will only trigger a workflow run if the workflow file exists on the default branch":
  a break-glass run of a branch could not chain at all.
- At most three levels: `build → beta → gamma → prod` uses all three, and `main-red`, itself a
  `workflow_run` of the release, would be a fourth level and never run.
- In a `workflow_run` run `GITHUB_SHA` is the default branch's last commit, not the revision; R21's
  check (`REVISION` is `GITHUB_SHA`) and kci's start-up check would have nothing to hold, and the
  inputs `revision`, `reason` and `dry_run` are not carried.
- The artifact crosses runs (`actions: read`, refused by R4), and each channel's trusted publisher
  names the workflow file `kci.yml` (ci.md): moving gamma or prod to another file means re-registering
  both publishers.
- kci holds one workflow file to one machine file at start-up; four files would need four.

**Why ordering holds for live runs.** `build` is itself a single slot, so builds finish in push order,
and each later stage receives arrivals in that order; the pending slot always holds the newest. A
running job is never cancelled, so every stage makes progress: throughput is the slowest stage's, not
the sum. Pausing prod (a required reviewer) should then hold only the prod group, so beta and gamma
keep running (P0 confirms).

## c. Ordering safety: nothing older after something newer

Live runs keep order (b), but three paths break it: a re-run of an old run, GitHub's FIFO that is "not
guaranteed", and a failed job re-run later. Example: beta for B finishes late, after C reached gamma.
**Rule: a stage refuses to promote a revision older than what it already promoted.**

**Mechanism: extend "Never backward" (ci.md; `superseding_files` and `backward_files` in
`src/kci_publish/plan.mojo`) from prod to every push stage.** Today it is per *stage*:
`req.never_backward = not stage.break_glass` (`src/kci_cli/dispatch.mojo`), so gamma, a break-glass
stage, has neither refusal. Proposed:

- **gamma and prod:** `never_backward` is a property of the **run**: true on a push to `main`, false
  on a break-glass run. At gamma, the listing is read over **main-line builds** only: files whose
  `h<8 hex>` names a commit on `origin/main`'s history (an ambiguous prefix counts as main-line). A
  break-glass build of a branch, which may carry a higher number or a commit off `main`, is reported
  and does not stall `main`.
- **beta** has no channel to read, so it asks **the next stage's**: it reads gamma's listing
  anonymously (the same read and functions) and stops if gamma already holds a main-line build that
  supersedes this revision. Beta never hands gamma a set gamma would refuse, and spends no farm time.
- **Two outcomes, split by history.** The channel's newest main-line build **descends from** the
  revision (the revision is on that build's history): `SUPERSEDED`, exit 0, nothing uploaded or run,
  the job's output `superseded=true`, and the later jobs skip (R23). History **unrelated** either
  way: `REFUSED`, `KCI-E-SUPERSEDED`, exit 3, red, as today. A late re-run is routine, not an incident;
  an unrelated history is.

**Planted tests (`src/kci_publish/tests/test_publish_never_backward.mojo`, kci_cli dispatch tests):**
(1) a push run at gamma (a `break_glass` stage) against a fake listing whose newest build names a
descendant commit: expect `SUPERSEDED`, exit 0, zero uploads. Red today; the mutant that restores
`not stage.break_glass` uploads and turns it red. (2) the listing also holds a higher-numbered build of
an off-`main` commit: the push still publishes; counting every build turns it red. (3) unrelated
history: `REFUSED`, exit 3, still. (4) beta against a fake gamma listing that is ahead: `SUPERSEDED`
before any index, install or farm action; a beta that skips the read turns it red.

## d. What "superseded" looks like

- **Replaced while pending** (the common case: GitHub's "Canceling since a higher priority waiting
  request ... exists"). The job is cancelled; its `needs` dependants skip. `release/ci/main_red.py`
  classifies a run by its conclusion: `failure`, `timed_out`, `startup_failure` are red, `success` is
  green, **anything else, `cancelled` included, is ignored** (`classify`, `RED`). So it never alerts.
  The run's conclusion when one *job* is cancelled by its group is expected to be `cancelled`; slice
  P0 confirms it from the first run's API record before anything relies on it.
- **Stopped as `SUPERSEDED`** (c): a successful job whose summary says `superseded at <stage> by
  <build>`, and skipped later jobs. The run concludes `success`. Today `main_red.py` would read that as
  green; **proposed:** a push run is green only when its `prod` job concluded `success` and its prod
  result is not `SUPERSEDED`; otherwise it is ignored.
- **The record of a superseded commit** is the run that carries it: prod's summary already lists the
  commits between the channel's previous build and this one (`previous_build_number`, "carried");
  gamma's summary gets the same list. No job lists replaced runs (that needs `actions: read`).

## e. Beta's checks: the end-to-end suites, and the built files installed

**On the farm (the `beta` job):** a `TEST` step builds and runs `checks: "//src/tests/e2e/..."`, a
pattern, so a new suite joins with no edit. Today that is 11 test-only packages: `broker_e2e`,
`komira_azure_blob_e2e`, `komira_formats_e2e`, `komira_http_tls_e2e`,
`komira_job_supervisor_loopback`, `komira_pandas_door_e2e`, `komira_search_e2e`, `komira_secrets_e2e`,
`komira_shuffle_e2e`, `komira_tls_interop_e2e`, `komira_udf_e2e`. None is in
`release/artifacts.textproto`. Ten are test-only libraries whose welded tests a `buck2 build` runs;
`broker_e2e` is a standalone `mojo_test` only, and `komira_shuffle_e2e` and `komira_tls_interop_e2e`
also hold standalone `mojo_test`s, which only `buck2 test` runs. The release `build` builds only
`<lib>_conda[release]`, so none of these runs on a release today. The `*_e2e` test files inside
released libraries are welded and already run in `build`. Zero spend: no suite holds a cloud
credential; the two cloud suites run over loopback against in-process fakes (the secrets suite's fake
AWS and GCP services verify signatures themselves; Azure against a loopback blob fake), and P3's first
task confirms that no other suite opens a socket off loopback. The
MinIO-backed `komira_job_supervisor/tests/e2e` exits 77 without its flag, a skip that cannot fail, so
it stays out until it cannot skip. `beta`'s environment holds no secret and no cloud credential.

**Tying the source suites to the built files.** These suites link the libraries built from source at
the revision; the packages carry those libraries' payload. The `TEST` step compares, for every released
library the suites build, the sha256 of buck2's payload output with `payload_sha256` in the release's
`metadata.json` (`tools/build/package/conda.bzl`), and refuses a mismatch before running anything. So
"the suites passed" is about the bytes beta hands on, or beta fails.

**On a hosted runner (the `beta_install` job, no environment, no token):** the existing
`CONDA_INSTALL_ENV` validations, `install-komira-encoding` then `install-set`, install from beta's
local channel with the pinned pixi and run every installed README. Split from `beta` for the reason
`validate` is split from `gamma`: an install runs third-party package code, and `beta` holds the
identity token that joins the farm. #1168's S12 checks land here.

## f. The machine file, the environments, the workflow rules

```text
stage {
  name: "beta"
  after: "build"
  farm_connected: true
  break_glass: true
  step {
    name: "e2e"
    kind: TEST                       # NEW: runs `checks` at the revision; writes no release directory
    platform: "linux-x86_64"
    artifacts: "release/artifacts.textproto"
    checks: "//src/tests/e2e/..."    # NEW field (#1168 S10c's, on a TEST step)
    validation { name: "install-komira-encoding" kind: CONDA_INSTALL_ENV install: "komira_encoding" ... smoke: README }
    validation { name: "install-set" kind: CONDA_INSTALL_ENV install: "komira_all" ... smoke: README }
  }
}
```

`gamma`'s `after` becomes `"beta"`; prod is unchanged. A `TEST` step's validations read the handed
release's local channel (no `wait_for_index_seconds`); `kci_release_machine` refuses a `TEST` step
with neither `checks` nor validations, and `checks` on any other kind.

| stage | job(s) | environment | token | runs on |
|---|---|---|---|---|
| build | `build` | `build` | farm | farm |
| beta | `beta` (`--only step:e2e`), `beta_install` (its two validations) | `beta`; part job none | farm; none | farm; hosted |
| gamma | `gamma` (publish), `validate` | `gamma` / `gamma-breakglass`; none | OIDC; none | hosted |
| prod | `prod` | `prod` | OIDC | hosted |

`beta` is a new environment. The farm's credential trusts tokens whose subject is this repository
(ci.md, "farm-connect"), so a `beta` subject should join; P0 checks it.

**Workflow rules (`src/kci_workflow_check`):**

- **R16, rewritten:** no workflow-level `concurrency:`; every release job has a job-level one, exactly
  `group: kci-<job id>-<canonical suffix>` and `cancel-in-progress: false`, and no `queue` key. A
  stage's part job is its own group: `validate` for B may overlap `gamma`'s publish of C (question 1).
- **R23, new:** every job of a stage with an `after` carries the top-level conjunct
  `needs.<J>.outputs.superseded != 'true'`, J being the job R19 reads its hash from, and that job
  declares the output; a stage stopped as `SUPERSEDED` hands on no hash and nothing runs after it.
- **R9 and R19** apply to beta as they do to gamma: the split runs every step and validation once;
  gamma's hash is `needs.beta_install.outputs.validated_set_hash`.
- **R11** needs no change (the farm-connect action follows `farm_connected`). R14 stays.

## g. Slices

Each slice: the check that is red before it. **Go** marks a project-owner action.

| # | slice | red before | go |
|---|---|---|---|
| P0 | Confirm three facts before P4: the run conclusion when a job is cancelled by its group; a `beta` subject joins the farm; a job waiting on an environment reviewer holds only its job group. From the API record of existing runs and the trust policy; nothing started for it. | each written here with its evidence, or P4 stops | none |
| P1 | kci: `never_backward` per run; main-line builds at gamma; `SUPERSEDED` as exit 0 with output `superseded`; gamma's "carried" list | tests (1)-(3) of c | none |
| P2 | `main_red.py`: green only with a successful, non-superseded `prod` | a `success` run whose `prod` was skipped: expected ignore, green today | none |
| P3 | First task: confirm every `//src/tests/e2e/...` suite opens no socket off loopback. kci: step kind `TEST`, field `checks`, beta's read of gamma's listing, the payload digest comparison, validations from the handed local channel; `build` writes the local index | machine fixtures (TEST with neither, `checks` on PUBLISH) refused; test (4) of c; a planted payload digest mismatch refused; a local-channel record with another sha256 refused | none |
| P4 | The switch, in one PR (kci checks the workflow against the machine at start-up, and `test_repo_kci_yml` welds them): `release/machine.textproto` with beta, `kci.yml` with job groups, `beta`, `beta_install` and R23 guards, R16 and R23 in `kci_workflow_check`, ci.md and the `kci.yml` header | the rule fixtures: a workflow-level group, a job without a group, `queue: max`, a job missing R23's conjunct, each refused; today's `kci.yml` fails the new R16 | **Go**: changes the release; the first push creates `beta` and spends farm time on the suites |
| P5 | Artifact retention of `kci-release-*` to the ruled value | none (a setting in `kci.yml`) | **Go** with question 2 |
| P6 | #1168 S10c's derived release checks join beta's `checks`; S12's installed checks join `beta_install` | as #1168 states them | as #1168 |

P1, P2 and P3 merge on their own and change nothing that runs (P1 changes only what a push to gamma
may do when the channel is ahead). P4 depends on all three and on P0.

## h. Questions for the project owner

1. **Gamma's two jobs.** Rule 2 read strictly makes `gamma` and `validate` one slot, but job-level
   groups lock one job each, and one job would put the install's third-party code next to the publish
   token. *Recommendation:* two slots, publish and validate, each one at a time; the install is pinned
   to its own set's digests, so an overlap cannot validate the wrong files.
2. **Retention.** *Recommendation:* 30 days for `kci-release-*`; a pause longer than that makes the
   held run fail red, and the next push carries its commits.
3. **Break-glass builds in gamma.** They share the channel and can out-number `main`. *Recommendation:*
   accept the main-line filter (c) now; consider a separate break-glass channel later (an upload
   setting).
4. **The suites as a release gate.** One flaky suite blocks gamma and prod. *Recommendation:* gate,
   with #1168's re-run-once and quarantine-by-PR policy.
