# Continuous publish: every package built, published to gamma, tested there, promoted to prod

Status: design, not built (revision 4). Everything marked **EXISTS** names the code that does it on
`main`; everything marked **PROPOSED** has no code yet. **Every name this document introduces is
PROPOSED and absent from `main`:** `komira_test_emulator`, `EmulatorEndpoint`,
`LoopbackOnlyConnector`, the `release_checks` attribute, the `[conda_status]` sub-target,
`release/unreleased.textproto`, `release_ledger_check`, `release/quarantine.textproto`,
`release/yanked.textproto`, `KCI-E-YANKED`, `kci yank`, the BUILD step's `checks:` field, the probe
rows `netns_loopback_only` and `ambient_identity`, the `tests/fixture_tier/` directories and the
`src/tests/emulator/` tree. It builds on
[gamma validation](gamma_validation.md) and its
[decisions](gamma_validation_decisions.md), which say what checks each package family before prod,
and on [ci.md](../ci.md), the authority for the workflows. Where this document and
`gamma_validation.md` disagree on how an emulator runs, this document is the later decision, and
`gamma_validation.md` points here. Related: #371, #779, #835, #929, #1136, #1138, #1140, #1153.

## What is it for, and what is out of scope?

The goal: every komira library is built, published to the conda channel `gamma`, tested there, and
promoted to `prod`, on every change to `main`, with no human click per release. That includes the
cloud SDK packages, which are tested **without spending money on a cloud**. They are tested against
in-memory fakes (`kci_cloud_fake`), against emulators that run as local processes, and against
fixtures derived from pinned models and documented examples where no emulator exists.

This document covers:

1. how a release runs today and what is missing (with evidence);
2. the target pipeline: the trigger, what "continuous" means at the CI's throughput, the gate between
   gamma and prod, rollback and yank;
3. what stands between "the declared set" and "every package";
4. the emulator test tier: where it runs, how emulators start and stop, one harness for all generated
   clients, the mapping from package to emulator, and fixture tests for the rest;
5. the safety rules: no cloud spend, no credentials, no route to a real endpoint;
6. the rollout as slices that can each be merged on their own;
7. the questions for the project owner.

Out of scope:

- **Real cloud accounts in gamma.** These are decision 4 of
  [gamma validation decisions](gamma_validation_decisions.md#open-decisions-for-the-project-owner).
  This design spends nothing and holds no cloud credential.
- **The native package format.** That is #835. This document depends on it but does not decide it.
- **Other platforms** (linux-aarch64, macOS) and Python wheels.
- **DEPLOY.** See [the DEPLOY step](deploy_step.md).
- **Who may run actions on the farm.** The `build` environment has no deployment-branch policy
  either (live settings), which bears on who can run actions on the farm. That belongs to the farm's
  own design ([What farm access means](../ci.md#what-farm-access-means)), not to this one.

## How does a release run today? (EXISTS)

**Promotion is already continuous.** A push to `main` that touches more than documentation runs
`.github/workflows/kci.yml` as four jobs:

1. `build` runs on the build farm.
2. `gamma` publishes to the `gamma` channel.
3. `validate` installs what `gamma` published and runs the README examples. It `needs: [build,
   gamma]`, so it runs after `gamma` has published.
4. `prod` publishes the same release set to `prod`.

`prod` runs automatically when `validate` succeeds. It publishes exactly the set `validate` installed,
using the `validated_set_hash` that `validate` hands it (the `kci.yml` header, "CONTINUOUS
AUTO-PROMOTION"; `release/machine.textproto`). It never publishes a lower build number, or a revision
off `main`'s history (`KCI-E-SUPERSEDED`, [ci.md](../ci.md)). Releases run one at a time, in the
concurrency group `kci-release-main`. A newer push replaces the pending run, so pushes made during a
release coalesce into the next one. To pause promotion, add a required reviewer to the `prod`
environment ([ci.md](../ci.md#pausing-promotion-to-prod)).

| piece | today | evidence |
|---|---|---|
| trigger | a push to `main` (not `docs/**` or `**.md` only), or a manual run with a `reason` | `kci.yml` `on:` |
| gate before prod | two `CONDA_INSTALL_ENV` validations: `install-komira-encoding` and `install-set`. Each runs a fresh pixi install from `gamma`, checks the README sha256 and runs every ` ```mojo ` README block. | `release/machine.textproto`; [gamma validation](gamma_validation.md#what-runs-in-gamma-today-exists) |
| what is released | the libraries in `release/artifacts.textproto` (41 libraries plus `komira_all`: 42 `artifacts {` blocks) | `grep -c '^artifacts {'` |
| what is not released | 161 libraries: 202 directories under `src/` hold a `BUCK` file (`src/tests` holds none) and 41 are declared | see [What blocks every package?](#what-blocks-every-package) |
| cloud SDK tests | welded unit tests with `ScriptedConnector`, `AwsEchoConnector`, in-memory fakes and loopback fakes on `komira_http_server`. No emulator anywhere. | [gamma validation](gamma_validation.md#aws), §AWS, §GCP, §Azure |
| a release on the release revision | builds `<lib>_conda[release]` and those libraries' welded tests. It runs no standalone e2e, conformance or service test. | [gamma validation](gamma_validation.md#where-can-a-check-run); decision item 6 |
| a failed validate | prod does not start (no `always()`). The gamma bytes stay in `gamma`. | `kci.yml`, job `prod` |
| rollback | "a revert on `main`, released forward as the next build number". There is no yank path. | [ci.md](../ci.md) |

**Measured run time.** These are the last ten releases that ran to the end, all of them after the
switch to auto-promotion, read from the GitHub jobs API:

| part | range | median |
|---|---|---|
| push to prod done | 13.5 to 85 min | about 31 min |
| waiting behind the previous release | 0 to 29 min | |
| `build` | 4.3 to 54 min | about 8 min |
| `gamma` + `validate` + `prod` | 8 to 12 min on every run | |

The slow `build` runs are the ones in which kci's own code changed. The step "build kci" took 16 to
50 s when it was cached, and 650 to 2509 s when kci's code had changed (#1153). Of the last 200 runs on
`main`, 162 were pending runs that a newer push replaced. So coalescing already does the batching.

**Where the settings and the docs disagree** (live repository settings, read through the GitHub API
again for revision 2; unchanged):

| the docs say | the settings say |
|---|---|
| `gamma` deploys from `main` only (`kci.yml` header, BREAK-GLASS) | `gamma` has **no** deployment-branch policy and no protection rule |
| `gamma-breakglass` has a required reviewer | `gamma-breakglass` **does not exist** |
| `prod` deploys from `main` only | holds: its policy is `main` |

The `kci.yml` header admits it: "until those settings exist, a branch's own workflow can still publish
to gamma". **What that allows:** a branch's upload can take the next name and build number in
`gamma` and serve bytes that no check vouched for to anyone who installs from `gamma`. **What it does
not allow:** reaching `prod`. `validate` checks each installed file's sha256 against the release set
([ci.md](../ci.md)), so a release whose name a branch took fails instead of promoting. Prod is locked;
gamma is not. Slice S0 closes this.

**Stale docs.** `docs/releases.md` still says that the repository "does not yet contain the step that
uploads", and it lists upload and channels as "Held". `gamma_validation.md` says 37 libraries and 16
AWS clients. Main has 41 libraries and 17 `mojo_aws_client` calls (`komira_aws_ses` is missing from
the doc), as tracked in #779. Slice S1 fixes `releases.md`.

## The target pipeline

### Trigger: per merge, coalesced

**Superseded in part:** this trigger, and the placement of the two gates in "The gate between gamma and
prod", are superseded by [the staged pipeline](staged_pipeline.md) (#1173).

**PROPOSED: keep the trigger as it is.** Every push to `main` is a release, and pushes made during a
release coalesce into the next one. That *is* the per-batch trigger. The batch is whatever landed while
the previous release ran, so there is no clock to tune and no second trigger to keep in step with the
first. A scheduled batch trigger (nightly, for example) would only add delay: a release that changed
nothing is a NOOP that exits 0 (build numbers count first-parent commits, not runs).

"Continuous" therefore means **every push to `main` that touches code reaches `prod` within one release
duration, or within two if it lands during a release, or it fails loudly**. At today's numbers that is
15 to 70 minutes. Two prerequisites keep it there as the released set grows. Both are needed today,
independent of this design, and each is its own slice:

- **S10a: kci built once per revision of `main`, not once per job** (#1153's first direction). A cold
  kci build can by itself use most of `build`'s 120 minutes.
- **S10b: the release `build` step split into batches,** each under `--build-timeout-s`. A change
  under `tools/build/package/` or in a core library re-keys every package. #1153 measured 299 units in
  one batch, which overran the 60-minute batch limit. The step builds the released targets in
  fixed-size batches in dependency order, so that a cold full release takes several batches rather
  than one oversized one. The first such release is slow, and the queue coalesces behind it.

### The gate between gamma and prod: results, not clicks

**EXISTS:** prod publishes only the set that `validate` vouched for. **PROPOSED:** two more inputs,
at two different points:

| input | runs in | runs when | a failure stops | slice |
|---|---|---|---|---|
| the release checks | `build` (farm) | before `gamma` publishes | `gamma` and everything after it | S10c |
| the installed-bytes checks: the cloud smoke and the native `.so` check | `validate` (hosted runner) | after `gamma` has published, before `prod` | `prod` only; the bytes stay in `gamma` | S12 (after #835) |

Neither one changes what `prod` trusts: `prod` still publishes only `validate`'s set.

1. **The release checks** (S10c) are Buck2 standalone test targets that the release's `build` step
   *runs* (`buck2 test`, not `buck2 build`: building a standalone test does not run it) on the release
   revision. A failure fails `build`, so nothing reaches `gamma`. **The list is derived, not kept by
   hand**: it is every check `release/ci/derive_checks.py` derives whose targets depend on a declared
   library, the emulator and fixture tiers included. A new standalone test of a released library, or a
   newly declared library, joins the gate with no edit. This is decision item 6 of
   [gamma validation decisions](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma)
   restricted to the released set's reverse dependencies. **That restriction is PROPOSED S10c work:**
   `derive_checks.py` today groups targets by path and has no reverse-dependency filter; S10c adds one
   through `buck2 cquery "rdeps(<standalone tests>, <declared libraries>)"`. It is sized before it gates: S10c's first
   task measures its wall time and farm cost on a release revision and writes both here. It gates only
   if the measured time plus the 95th-percentile `build` time fits under `build`'s 120 minutes with a
   margin; otherwise it goes back to the project owner with the numbers.
   These tests run on the source build. The conda payload is that same gated `.mojoc`
   (`tools/build/package/conda.bzl`), so they test the bytes that are published. The installed-path
   differences (linking, loading, the README against the install) are what `validate` covers.
2. **The installed-bytes checks** (S12, only after #835). One emulator round trip per cloud family,
   run against the *installed* package, plus decision item 8's check of every installed `.so`: the
   rules of `tools/build/native/native_check.sh` and the highest `GLIBC_` symbol version against the
   declared floor. They catch the defect class the build cannot catch: a native library in the conda
   package that fails to load or link from the install. The cloud smoke needs decision 1 of the gamma
   validation decisions (a `service` block); the `.so` check needs only the native packages.

**Flakes.** One emulator that fails to start now blocks every release to prod, so the gate has a
policy: a release check that fails is re-run once, alone; a second failure fails the release. A check
that needed its re-run twice in any ten releases gets an issue with an owner. A check may be
quarantined only by a PR that names the issue and owner in `release/quarantine.textproto`
(PROPOSED, S10c). S10c's reach check (below) still requires every released cloud library to keep at
least one check that reaches it and is not quarantined, so quarantining a library's only check stops
that library's release until it is fixed.

A human enters only to pause, by adding a reviewer to `prod`, or for break-glass. Neither one is part
of the normal path.

### Rollback and yank

**Rollback stays "forward"** (EXISTS). A revert on `main` is released as the next build number. A
consumer that solves for the latest version gets the revert. A consumer pinned to the bad build keeps
it. The revert passes the same pull-request check and the same release, so the time to roll back is
one PR check plus one release duration. The rule "Fix forward or revert within the hour" ([ci.md](../ci.md))
already covers it.

**Yank** (PROPOSED, slice S11, and **every use needs the project owner's go**). A yank is for a
published build that is unsafe for anyone to keep solving to: a security defect, or corrupt bytes.

- **What a yank does.** It removes the file from `prod` (and from `gamma`), so that no new solve
  selects it, and it records the file in `release/yanked.textproto` on `main`, through a PR.
- **What stops it coming back.** kci refuses to publish a file that `release/yanked.textproto` names
  (a new `KCI-E-YANKED`, checked before any upload, in `gamma` and `prod`). Without that tombstone a
  manual re-run of the same commit would regenerate the same name and build number (both count
  first-parent commits), find the name absent from the channel, and upload the yanked bytes again:
  "never overwrites" checks only what the channel holds. **kci reads the tombstone from `main`'s
  head, never from the revision it releases:** it fetches `origin/main` and reads
  `release/yanked.textproto` there (`git show origin/main:release/yanked.textproto`). A re-run of
  an old commit checks out a tree whose own copy predates the yank, so reading the checked-out file
  would let the yanked bytes through. A tombstone that cannot be fetched or parsed fails the
  publish; there is no fail-open path. The existing refusals ([ci.md](../ci.md), "Never backward")
  cover part of this, at `prod` only. If a build later than the yanked one is already in `prod`, a
  re-run of the yanked commit carries a lower number and is refused by number. If the yanked build
  was the newest, the yank removes it, so the highest number left is the previous build's. A
  re-run of the yanked commit then carries a higher number, descends from the newest remaining
  build, and passes both refusals. `gamma` has neither refusal. The tombstone covers both cases at
  both channels. Planted defect (S11): a re-run of a commit older than the tombstone commit,
  whose own tree does not name the file, is refused in `gamma` before any upload; a variant of kci
  that reads the checked-out file uploads it and turns the test red.
- **What a yank never does.** It never removes anything from a consumer's lockfile, and it never
  publishes anything.
- **Why yank cannot be automatic.** It deletes from a public channel.
- **What has to be confirmed first.** Whether the channel host supports deleting a single package
  file, or marking it removed in the repodata, is **not verified**. It is the first task of S11.
- **Form.** A `kci yank --channel prod --file <name>` verb with a dry run by default. If the host
  cannot delete a file, a yank is the tombstone plus a forward release whose build is higher than the
  bad one, which is rollback.

## What blocks every package?

A library is published only if `release/artifacts.textproto` declares it. The build refuses a conda
package for a library in any of these cases (`_conda_facts` in `tools/build/mojo/defs.bzl`, computed at
analysis; asking for `[release]` then fails naming the reason, `tools/build/package/conda.bzl`):

- it links native code, directly or through a dependency;
- it has no tests;
- it depends on a library that is refused.

The packer refuses a library that uses `OwnedDLHandle` (`tools/build/package/pack/conda.zig`). Gamma
refuses a library that has no README, or a README with no runnable example
(`src/kci_validate/readme_installed.mojo`). **PROPOSED (S3a):** one more refusal, below, for a cloud
library with no release check.

The table below is from a static parse of every library's `BUCK` file at the time of writing, not
from `cquery`. As a cross-check, all 41 declared libraries came out buildable. Its rows sum to 162
against 161 unreleased libraries, so one library is counted in two rows; S1's ledger replaces this
table with one the build checks.

| reason a library is not released | count | unblocked by |
|---|---|---|
| links native code directly (async, crypto, http_core, libc, log, fs and others) | 17 | the native package format, #835 |
| links native code through a dependency (most often through `komira_async` or `komira_libc`) | 122 | #835 |
| opens a library at run time (`komira_lz4`, `komira_zlib`) | 2 | #835 (system codecs by soname) |
| no README (`kci_artifact_proto`, `kci_deploy_model_proto`, `kci_manifest_proto`) | 3 | #1138 |
| buildable, declared by an open PR | 14 | #1136 |
| depends on a library that is not declared yet | 4 | the PRs above, then a declare PR |

**Every cloud SDK package is in the native rows.** They all reach `komira_http_core`, `komira_crypto`
or `komira_async`. So no cloud package can be published to `gamma`, or be tested there as installed
bytes, before #835 is decided and built. What can ship before it:

- **The 21 non-native libraries** in the last three rows: through #1136, #1138 and three small declare
  PRs (slice S2).
- **The emulator and fixture tiers, run on the release revision** (S4 to S10c). They test the same
  source the package will carry.

**A cloud package cannot be declared without its check** (PROPOSED, S3a, before any cloud declare PR).
This is a build rule, not an ordering hope:

The rule has two halves, because Buck2 analysis can compute only one of them:

- **At analysis (S3a).** `mojo_library` gains a `release_checks` attribute: a list of plain labels
  (`attrs.label`, not a dependency: the test depends on the library, so a dependency edge back would
  be a cycle). `_conda_facts` refuses the package of a library in a cloud family, with the reason "no
  emulator or fixture check", when `release_checks` is empty. That is all analysis can see: it cannot
  read `release/quarantine.textproto`, and a plain label is not resolved, so analysis checks neither
  that the target exists nor what it tests. A cloud family is computed at analysis from `deps`, which
  is the full transitive closure: the library is, or depends on, `komira_aws_core`, `komira_gcp_core`
  or `komira_azure_core`. Like the other refusals, it passes to dependents, and asking for
  `[release]` fails. Planted defect: a cloud-family fixture library with `release_checks = []` turns
  its `[release]` red; naming one target turns it green.
- **At release time and in the pull-request check (S10c, the reach check).** Before it runs the
  checks, S10c runs, for each declared cloud library, `buck2 cquery "rdeps(set(<its
  release_checks>), <library>)"` and requires at least one named target that (a) exists, (b) is a
  standalone test, (c) has the library in its dependency closure, and (d) is not in
  `release/quarantine.textproto`. A failure fails `build`, so nothing reaches `gamma`. The same query
  runs in the pull-request check of a PR that changes `release/` or a `release_checks` attribute.
  Planted defects, each red: a `release_checks` naming a test of an unrelated library (fails c), a
  label with no target (fails a), and a library whose only named check is quarantined (fails d).
- S10c also runs every `release_checks` target named by a declared library, in addition to the
  derived set, so a check cannot be named and then not run.
- **Residual risk, stated:** a test target that depends on the library and asserts nothing passes
  both halves. The reach check proves the test can reach the library, not that it exercises it;
  review of the test is the guard.

S3's cloud declare PRs therefore **depend on** S3a and S10c and on that family's suite (S5 to S8):
without them the declare PR's `[release]` fails in its own pull-request check.

**PROPOSED, slice S1: the release ledger.** "Every package" has to be a number the build checks, not a
count in a document. `release/unreleased.textproto` lists every library that is not declared, with a
reason from a closed set: `NATIVE`, `DLOPEN`, `NO_README`, `UNDECLARED_DEP`, `NO_CLOUD_CHECK`,
`TEST_SUPPORT`, or `PENDING_DECLARE` with the PR number. A standalone test target in `release/BUCK`,
`release_ledger_check`, checks two things:

- every library directory is in exactly one of the two files;
- a reason that the build can compute agrees with the build (each library exposes a `[conda_status]`
  sub-target, written at analysis from the refusals `_conda_facts` already makes).

It is not welded into `kci_release_set`: that would make kci's build depend on every library's
`[conda_status]`, so kci would rebuild whenever any library changed, which is the slowness #1153 is
about. As a standalone target it is derived by `derive_checks.py`, runs in the pull-request check
whenever `release/` or a library changes, and is a release check (S10c). There is no "the ledger only
shrinks" rule: a test that sees one tree has no history to compare with. A new library that nobody
declares or lists turns the check red. The day #835 lands, the `NATIVE` rows become declare work, and
the ledger says how much of it remains.

## The emulator test tier

### Where it runs: on the farm, as pinned processes

| option | for | against | verdict |
|---|---|---|---|
| GitHub-hosted runner, `services:` containers | Docker is there. Contributors can reproduce the run with Docker. | It is not the farm, and it is a new job. Under rules R2, R3, R4 and R9 of `kci_workflow_check` it blocks prod and needs an amendment (decision item 7). A second test runner would duplicate Buck2's. | only for the installed-bytes checks (S12) |
| farm, container per test | the image is the upstream artifact | Docker inside a farm action is not a probed capability. Privileged Docker-in-Docker was rejected for the earlier LocalStack-on-farm proposal (a container escape gives node root). | no |
| **farm, pinned process per test** | A **partial precedent EXISTS**: `komira_test_minio` runs a sha256-checked MinIO binary on a random loopback port under `setpriv --pdeathsig`, and the [farm capability probe](../ci.md#what-a-farm-test-action-can-do) checks the capabilities it needs. The tests are ordinary Buck2 tests: affected-set aware, runnable by anyone with `./buck2 test`. | Emulators that are Python, Java or Node need a pinned runtime. The precedent differs in two ways this tier must not copy (below). | **yes** |

**Where `komira_test_minio` is not the pattern.** Its binary comes in through a flag,
`--test-minio-binary`, not as a build input, and its pin is checked at run time
(`minio_pins.mojo`). With no flag the test SKIPS with exit 77
(`src/tests/helpers/komira_test_bucket/BUCK`). A skip that counts as a pass in a gate is a check that
cannot fail. **Rule: an emulator test never skips.** The emulator and its runtime are build inputs
(below); the harness has no skip path; a missing or unstartable emulator FAILS the test. S4 plants
the defect (an emulator descriptor pointing at a missing file) and the test must turn red.

**PROPOSED:** the emulator tier is made of standalone Buck2 test targets under
`src/tests/emulator/<family>/`. Each one starts its emulator as a pinned process inside the test
action. They run in three places:

- in the pull-request check when they are affected (`release/ci/derive_checks.py` derives them like any
  other standalone check);
- on every release revision, as release checks (S10c);
- on a developer's machine with the same command.

**Not cached.** The test binaries and the pinned emulators are built and fetched through the action
cache, but a test *result* is not cached ([ci.md](../ci.md#what-a-farm-test-action-can-do): "A test
result is not cached"). Every affected PR and every release starts its emulators again. S10c's
measurement counts that cost.

The earlier LocalStack-on-farm proposal needed local, uncached compiles, because its test held a
LocalStack auth token, and the farm's action cache cannot be trusted with a secret. The emulator tier
holds no secret (see [the safety rules](#the-safety-rules)), so a secret in the cache is not a risk.
**Supply chain is a separate risk**, covered by rule 5 of the safety rules: the tier runs third-party
code (moto's wheel set, the Firestore jar, Azurite's package set) on a worker where an action runs as
uid 0 with outbound network next to shared storage, and such an action can write action-cache entries
([What farm access means](../ci.md#what-farm-access-means)).

### How a test starts and stops an emulator

**PROPOSED: one harness library, `src/tests/helpers/komira_test_emulator`.** It reuses
`komira_test_minio`'s process code (`process.mojo`, `server.mojo`). Every emulator test does the same
six things.

**The processes, named.** *P0* is the process the test runner starts and kills: the outermost one,
in the worker's namespaces. *P1* is the test body, re-executed by P0 inside fresh namespaces: it is
**PID 1** of its PID namespace. *E* is the emulator, a child of P1; *G* is anything E starts (a JVM
behind a wrapper script, a server's workers).

1. **Isolate.** P0 starts P1 with `clone(CLONE_NEWUSER | CLONE_NEWNET | CLONE_NEWPID |
   CLONE_NEWNS)` through a C shim (the util-linux form is `unshare --user --net --pid --mount
   --mount-proc --fork --kill-child`, but its `--map-root-user` maps only uid 0, which step 2 cannot
   use). In order:
   - P1 sets `PR_SET_PDEATHSIG(SIGKILL)`, then blocks on a pipe from P0. EOF on that pipe means P0
     died before the death signal was armed, and P1 exits. P0 creates P1 from the thread that then
     waits for it, because the death signal fires when the parent *thread* exits.
   - P0, still in the worker's user namespace, writes P1's maps itself: `uid_map` `0 0 1` and
     `65534 65534 1`, `gid_map` the same, so inner uid 65534 is outer 65534. Writing a second line
     needs `CAP_SETUID` in the parent namespace, which a uid-0 P0 has. Where P0 is not uid 0 (a
     developer's machine), the map is the single line `0 <caller uid> 1`, the only map an
     unprivileged writer may set; step 2's drop is skipped, and E runs as the developer's own
     unprivileged uid outside. P0 then writes the go byte. This "is P0 uid 0" test only chooses
     the map; the safety of the result is checked by step 3's outer-uid check, which has no
     condition.
   - P1 makes its mounts private, mounts a fresh `/proc` (so `/proc` lists only the namespace's
     processes, by namespace pid), brings up `lo`, and runs the self-checks of
     [safety rule 3](#the-safety-rules).
   If a namespace, a map or the mount cannot be made, the test FAILS naming the capability; it never
   falls back to the host network. Inside the namespace each test has its own loopback, so two tests
   on one worker cannot meet on a port.
2. **Start.** P1 runs the pinned emulator E as the namespace's only workload. Where P0 is uid 0, E
   is started with `setpriv --reuid 65534 --regid 65534 --clear-groups`, inside the namespace, where
   step 1's map makes 65534 a mapped uid. The probe's `uid` row proved this drop only in the
   worker's own user namespace ([ci.md](../ci.md#what-a-farm-test-action-can-do)), so it does not carry over;
   the `netns_loopback_only` row repeats it inside the namespace. **If the drop fails, the test
   FAILS;** E never runs as uid 0, which step 1's map makes the worker's real uid 0 (checked in
   step 3, from outside). `nobody` cannot write `TEST_TMPDIR`, so P1 creates the emulator's state
   directory under it and hands it to uid 65534 first. The emulator binds `127.0.0.1` on a port taken from the descriptor (in a private
   namespace no other process holds it). Its command line comes from a per-emulator descriptor: the
   runtime, the entry point, the arguments, the readiness probe, the start-up budget and the
   environment keys E needs beyond the harness's fixed set (safety rule 3). E's environment is
   built from that allowlist, never inherited. P1 starts E with every descriptor above 2 closed
   except those on an explicit inherit list, empty in normal use.
3. **Ready.** The harness polls the readiness route until a budget runs out, and requires the
   emulator's process to be alive after the answer. Running out of budget, or an answer from a process
   that has exited, fails the test, naming the emulator and the elapsed time. Each budget is
   measured, written in the descriptor, and kept well under the 600 s test-action timeout.
   **Then the outer-uid check, by P0, with no condition.** P1 writes `ready` on a status pipe to P0
   and waits for P0's verdict byte. P0 reads `/proc/<P1>/ns/pid` (P1's outer pid is the one `clone`
   returned) and scans its own `/proc` for every other process whose `ns/pid` link is the same:
   E and every G. It requires at least one, and requires each one's `Uid:` line in
   `/proc/<pid>/status` to be non-zero in all four fields. It reads uids in the worker's user
   namespace, so the answer does not depend on the map or on which branch chose it. The check runs
   after the readiness answer, so the process that answered has already exec'd past `setpriv`'s
   `setresuid`; it cannot catch the moment between fork and drop. The same rule holds on a farm
   worker (outer uid 65534) and on a developer's machine (the developer's uid). *Planted:* (a) the
   drop skipped; E is outer uid 0, red. (b) The "is P0 uid 0" test always answers no; on a uid-0
   worker the map becomes `0 0 1`, the drop is skipped, E is outer uid 0, red. (c) A scan that
   compares the wrong link and so matches no process would pass vacuously; "at least one" makes
   it red.
4. **Hand over.** The test receives an `EmulatorEndpoint`: a loopback IPv4 address and port, a
   `LoopbackOnlyConnector` (see the safety rules), and a static credential. For AWS that is
   `StaticCredsSource` with a fixed dummy key pair. For GCP it is `StaticTokenSource` with the
   emulator bearer. For Azure it is Azurite's published development key.
5. **Run.** The test runs the package's round-trip table.
6. **Stop.** P1 sends SIGTERM to E's process group and waits up to the descriptor's stop budget.
   Then, having checked `getpid() == 1` again (also a self-check of safety rule 3), it sends `kill(-1, SIGKILL)`, which
   inside a PID namespace reaches every process in that namespace except P1, including a G that
   left E's process group with `setsid`. It reaps until `waitpid` answers `ECHILD`: as PID 1, P1 is
   the parent every orphan in the namespace is re-parented to, so no subreaper flag is needed
   (revision 2's `PR_SET_CHILD_SUBREAPER` is dropped as a second way to do what PID 1 already does).
   **The assertion is a scan, not `ECHILD`:** before the test ends, P1 lists the fresh `/proc` and
   requires that the only process in it is pid 1. `ECHILD` alone cannot see a process that was
   re-parented away from the caller.
   **If P0 is killed,** three links fire in order, and each is necessary: P1's death signal kills
   P1; P1 is PID 1, so the kernel kills every process in its namespace; the namespace holds E and
   every G. `PR_SET_PDEATHSIG` alone reaches only P1, and the PID namespace alone does nothing if P1
   outlives P0.

**Emulators as build inputs, pinned by sha256.** No test downloads anything. Each runtime and each
emulator is an action input:

| emulator | form | runtime |
|---|---|---|
| moto server | pinned wheels through the hermetic Python (`tools/build/python`: `python_dist`, `python_wheel`), its dependency set included (boto3, botocore, cryptography and the rest, each pinned) | CPython from `third_party/python` |
| storage-testbench | pinned wheels, the same way (grpcio included) | the same |
| Firestore emulator | the emulator jar, pinned by sha256 | a pinned JRE 21 archive |
| Azurite | decided by a probe in S8: a pinned Node archive plus Azurite's lockfile-pinned package set, or a container once a farm capability row proves one | Node |

### One harness for every generated client

Every generated client is generic over `Connector` and takes its endpoint and credentials as plain
values (`tools/build/cloud/aws.bzl`, `gcp.bzl`). The generated `_no_env_reads` test forbids
environment reads in the generated files. The harness therefore gives every client the same three
values, and each package supplies only a table.

**The table uses only operations the client has.** A generated client emits only the operations its
`BUCK` file lists (`tools/build/cloud/aws.bzl`, "Scope"), and a row that names any other operation
does not compile. Many packages cannot create, list and delete their own state:
`komira_aws_sqs` has no `SendMessage`, `komira_aws_lambda` has no `List*`, `komira_aws_ecr` has no
`Delete*`, `komira_aws_logs` has only `GetLogEvents`, `komira_aws_route53` cannot create a hosted
zone, and `komira_aws_metrics` sends only GetMetricData. **The state a row needs comes from the
harness, by the emulator's own route**: for moto through boto3, a client we did not write that moto
already depends on, so it is pinned with moto at no extra cost; for the GCP emulators and Azurite
through their documented REST routes, written by hand in the harness. Seeding and checking through
a client we did not write also makes the oracle independent: a row asserts that what our client
wrote is what boto3 reads back, and the reverse. **No operation list grows for the tier.** Adding an
operation changes a published API and goes through its own PR.

```text
# one row per operation group: what the harness seeds, the call under test, what to assert
round_trip("sqs", seed = boto3("send_message", body = "b1"),
           act = "ReceiveMessage", then = "DeleteMessage",
           expect = "the body received is b1; boto3 then sees an empty queue")
```

- **AWS client mode** (15 packages; most have four test files, `komira_aws_s3` and
  `komira_aws_secretsmanager` five): the client is built as
  `<Svc>Client[LoopbackOnlyConnector[KernelTcpConnector], StaticCredsSource]` with
  `<Svc>EndpointConfig.endpoint` set to the emulator.
- **AWS pure mode** (`komira_aws_dynamodb`, `komira_aws_logs`): a small shim that signs with
  `build_sigv4_signed_request` and sends.
- **GCP REST** (Firestore): `FirestoreClient[LoopbackOnlyConnector[KernelTcpConnector],
  StaticTokenSource]` over the emulator's plaintext HTTP/1.1 (`firestore_endpoint.mojo`). Only the
  document client: see the next section for Listen.
- **GCP gRPC unary** (`komira_gcp_storage`'s unary methods): `GrpcClient` with
  `plaintext_h2c = True` and the bearer hook. `komira_grpc` routes only `unary_call` over h2c
  (`src/komira_grpc/client.mojo`, the `_plaintext_h2c` field and the "NO h2c BRANCH" notes on
  `server_stream` and the client stream).

The table is hand-written per package, starting with what the operation list allows: create, read,
list with pagination, delete, where they exist, and one error case. Generating it from the service
model can come later, when the tables show a shape worth generating.

### What a package needs before it can reach its emulator

Some libraries build their own connector or credential transport inside, so a connector handed in
by the harness never sees those dials, or they dial a fixed public host. Each is work in its family's
slice, or it stays out of the tier and says so:

| library and site (`main`) | what it does | resolution | slice |
|---|---|---|---|
| `komira_aws_core`, `sts_credentials.mojo` (`_sts_request`) | the STS request is `https`, `sts.<region>.amazonaws.com`, port 443, fixed | the STS test drives `DefaultChainCredsSource[E, F, X, K]` with a fake environment and file source and a harness `CredentialTransport` that sends every request to moto over the loopback connector, and asserts the host it was asked for was the regional STS host. No library change. | S5 |
| `komira_aws_core`, `process_creds.mojo` (`ProcessCredsSource`, `process_creds_source`) | the process chain builds its own plaintext and public-CA TLS connectors and reads the process's environment, credential files, the container-credentials endpoint and the instance-metadata endpoint | refused in the tier by the lint below; tier tests use `StaticCredsSource`, and the chain only as in the STS row | S4 (lint) |
| `komira_gcp_firestore`, `firestore_client.mojo` (`firestore_cloud_client`, `firestore_adc_token_source`) | public-CA TLS to the Firestore host and to the OAuth token host, and ADC | refused in the tier by the lint; tier tests build `FirestoreClient[C, StaticTokenSource]` | S4 (lint), S7 |
| `komira_gcp_firestore`, `firestore_watch_source.mojo` (`listen_open`) | dials public-CA TLS to port 443 itself, with no connector parameter; the emulator serves plaintext; `komira_grpc` has no h2c streaming | **out of the tier** until both a connector parameter on the watch source and h2c streaming exist; Listen stays on its scripted tests | S7b (proposed, not scheduled) |
| `komira_objectstore_gcs`, `grpc_backend.mojo` (`GcsTlsConnector`, `build_gcs_tls_connector`) | the connector type is fixed as `TlsConnector[KernelTcpConnector]`, always `https`; "There is no plaintext (h2c) route" for ReadObject and WriteObject | **out of the tier** until the backend takes a connector type parameter and `komira_grpc` carries h2c streaming, or a pinned TLS terminator fronts storage-testbench and the test uses `build_gcs_tls_connector_trusting` with the terminator's root. S7b chooses between the two. | S7b |
| `komira_gcp_storage` streaming methods (ReadObject, WriteObject) | server and client streaming, no h2c route | out of the tier with the row above; the unary methods are in | S7b |
| `komira_http_client`, `http_transport.mojo` (`default_tls_factory`) and `scheme_connector.mojo` (`kernel_tls_scheme_connector`) | default factories that build public-CA connectors | refused in the tier by the lint; `azure_fs_for[C]` and `S3Store[C, ...]` take a connector factory, so the tier passes the loopback one | S4 (lint) |

**The lint** (S4, a test of `komira_test_emulator` run over every file under `src/tests/emulator/`,
in the style of the generated `_no_env_reads` scan): a tier test may not name
`build_public_ca_tls_connector`, `build_unpinned_public_ca_tls_connector`, `default_tls_factory`,
`kernel_tls_scheme_connector`, `KernelSchemeConnector`, `KernelTcpConnector.new` outside the harness,
`ProcessCredsSource`, `process_creds_source`, `ProcessEnv`, `ProcessFiles`, `firestore_cloud_client`,
`firestore_adc_token_source`, `FirestoreWatchSource`, `build_firestore_tls_connector`
(`firestore_endpoint.mojo`: a public-CA or skip-verify factory), `build_gcs_tls_connector`, or any ADC
or managed-identity source. **The match is on the whole identifier**, not a substring, so
`build_gcs_tls_connector` does not refuse `build_gcs_tls_connector_trusting`, which S7b may use. Its
planted defects: a tier test that calls `process_creds_source` turns it red; a tier test that calls
`build_gcs_tls_connector_trusting` stays green (a substring matcher would turn it red). It also refuses an emulator descriptor whose
environment keys name a credential variable (the list in safety rule 3); planted: a descriptor
listing `AWS_ACCESS_KEY_ID` turns it red. The lint covers what a tier test names, not what a library does inside; the namespace of safety
rule 3 covers that.

### Which emulator covers which package

| package | emulator | what is covered, and what is not |
|---|---|---|
| `komira_aws_core` (STS through the chain, as above); the generated clients for s3, sqs, sns, dynamodb, dynamodbstreams, iam, ec2, ecr, ecs, lambda, logs, route53, scheduler, secretsmanager, ses, sesv2, apigatewayv2; `komira_objectstore_s3` (`S3Store[C, StaticCredsSource, ...]`) | **moto** server (Apache-2.0, no token) | each client's own operations, state seeded and checked through boto3. Lambda: create, get, update and delete; `Invoke` needs Docker in moto and is not executed. ECS `RunTask` and Scheduler firing are not executed; their responses are fixtures. Signature checking: claimed only once a corrupted-signature mutant turns a run red with moto's authentication on (S5). |
| `komira_aws_metrics` (CloudWatch GetMetricData, awsJson 1.0) | moto, **if** it answers GetMetricData in the awsJson 1.0 form | **not verified.** S6's first task is that probe; data is seeded with boto3 `put_metric_data`. If moto does not answer that protocol, the package moves to the fixture tier, and this row says so. |
| `komira_gcp_firestore` (document client), `komira_gcp_firestore_db` | Google's **Firestore emulator** | `FirestoreClient[C: Connector, S]` speaks the emulator's plaintext HTTP/1.1 and bearer (`FIRESTORE_EMULATOR_BEARER`); `FirestoreDatabase` takes that client by value. Listen (`FirestoreWatchSource`) is not covered (S7b). |
| `komira_gcp_storage` unary methods (GetObject, ListObjects, DeleteObject, StartResumableWrite, the bucket methods) | **storage-testbench** (Apache-2.0; gRPC `google.storage.v2`, fault injection) | through h2c unary. That storage-testbench's gRPC port serves plaintext is inferred and is S7's first check. ReadObject, WriteObject and `komira_objectstore_gcs` are not covered (S7b). Not fake-gcs-server, which serves the v1 gRPC proto ([gamma validation](gamma_validation.md#gcp)). |
| `komira_azure_blob` | **Azurite** (MIT), blob service | through `azure_fs_for[C]` with the loopback connector factory; `AzureConfig.azurite` exists. Azurite does not support soft delete, versions, blob query or incremental copy. |
| `kci_cloud`, `kci_reconciler` | **`kci_cloud_fake`** (EXISTS, in-memory, with a faulty variant) | no kci library reaches a cloud client yet. When a real adapter lands (#1108 for GCP), its emulator test joins this tier. |
| Pub/Sub, Bigtable, Spanner, Datastore; Azure queue and table; Cosmos DB | none: **komira has no client for them** | each emulator is adopted in the PR that adds its client, with the same harness |

LocalStack is not proposed. Its current images need an auth token to start; the free plan is for
non-commercial use; ECR and ECS need a paid plan. A token is a secret, and that would break both the
"no credentials" rule below and outside reproducibility
([decision 2](gamma_validation_decisions.md#open-decisions-for-the-project-owner)).

### Fixture tests for the rest

No emulator exists for:

- the GCP management clients (apigateway, artifactregistry, cloudresourcemanager, cloudscheduler,
  compute, iam, logging, monitoring, monitoring_client, run, secretmanager, serviceusage, wif);
- `komira_gcp_core`'s token and ADC paths;
- `komira_gcp_fcm`;
- `komira_azure_core`'s Entra and IMDS paths;
- `komira_aws_lambda_http`, which is the Lambda runtime side and has no API to emulate;
- the moto gaps above (ECS `RunTask`, Scheduler firing, and `komira_aws_metrics` if S6's probe fails).

These packages are tested with fixture responses replayed through `ScriptedConnector`. **They are
synthetic, not recorded: no response is captured from a live cloud.** Capturing from a live cloud needs
a credential and an account, which this design does not have. Every fixture comes from one of three
sources:

| source | how | example |
|---|---|---|
| the pinned service model | a generator walks the pinned discovery document or botocore model and writes one maximal response per operation: every field present, every enum value used once, nested messages to depth 2. It is deterministic. | a GCP `operations.get` returning an LRO in every state |
| the provider's documented examples | copied from the provider's public reference page; the excerpt is kept beside the fixture | AIP-193 error envelopes; the OAuth 2.0 token responses of RFC 6749 and Microsoft's identity platform pages; IMDS token responses; FCM v1 send responses |
| an emulator in this tier | captured once from the emulator, with its name and pinned version | moto error bodies, reused as fixtures for unit tests |

**What model-derived fixtures prove, and what they cannot.** A fixture derived from a model and parsed
by a client generated from the same model proves only that the two agree. If they shared a model
reader, one misreading would appear in both and pass. Rule: **the fixture generator shares no code
with the client generators** (`tools/build/cloud`, `tools/build/proto-codegen`); it is a separate
reader of the same pinned file, and S9's lint refuses an import of either. Even so, a model that
misdescribes the live service is invisible to this tier; only the live service, which this design does
not reach, could show it.

**How the fixtures are kept honest** (PROPOSED, slice S9; each rule is a lint that turns the build red):

- **Provenance.** Every file under a package's `tests/fixture_tier/` has a sidecar `.provenance` line:
  `model <path> sha256 <hex>`; `doc "<title>" "<section>" excerpt <file> sha256 <hex>`, where the
  excerpt file holds the copied text, so a later edit of either shows in review; or
  `emulator <name> <version> sha256 <hex of the pinned artifact>`. A fixture without one is refused.
- **The schema check.** A fixture whose source is a model, or a documented example of an operation a
  pinned model declares, is re-checked against that model on every build: every field name exists,
  and every value has the declared type. When the model pin is bumped, a fixture that drifted turns
  red, and the fix is to regenerate it, with a visible diff. A documented example with no model (the
  OAuth token responses) is checked against a hand-written schema from the cited section.
- **No secrets.** The lint refuses an `Authorization` header, a JWT-shaped value, or a key-shaped
  value other than the documented example keys.
- **No dead fixtures.** Every fixture must be read by at least one test.
- **Scope.** The tier's claim counts only fixtures under `tests/fixture_tier/`. Response bytes written
  inline in existing unit tests are unit tests, not part of this tier's claim, and the lint does not
  cover them.

### What the tier proves, and what it does not

| proves | does not prove |
|---|---|
| that an implementation we did not write parses our requests and answers them, operation by operation | that the real cloud accepts them: IAM, quotas, regional behaviour, real TLS chains |
| state round trips within each client's own operation list, checked against an independent client (boto3) or route, pagination tokens, conditional writes, error codes as each emulator maps them | that an emulator matches its cloud: each one is a third party's reading of the API, with documented gaps |
| SigV4 as an independent server checks it, only if moto's corrupted-signature mutant goes red (S5) | GCP bearer validity, scopes or expiry: the emulators accept any bearer |
| that response parsers accept every field the pinned model declares (the model-derived fixtures, from a separate reader) | that the live service sends what its model says, or documents what it sends |
| that the library under test is the one the release publishes (the release checks, S10c) | installed-package loading of native code: that is S12, after #835 |
| | Firestore Listen, GCS streaming reads and writes, `komira_objectstore_gcs` (out until S7b) |

## The safety rules

1. **No cloud spend.** No test in the tier has a credential to any account. With no credential,
   nothing can be billed. No real-cloud step exists in this design.
2. **No credentials.** The harness passes only fixed dummy values: a dummy AWS key pair, the emulator
   bearer, and Azurite's published development key. The emulator test targets carry no secret
   attribute, and the jobs that run them hold no cloud identity (`build` holds only the farm
   connection; `validate` has no `id-token`). The generated `_no_env_reads` scan covers only the
   generated files and only environment reads; it does **not** stop `komira_aws_core`'s chain from
   reading credential files or the metadata endpoints. Those are kept out by the lint above and by
   rule 3.
3. **No route to a real endpoint.** The guarantee is the network namespace; the connector and the
   credential are defence in depth.
   - **The namespace (the guarantee; a precondition of every emulator test, release-gating or not).**
     Each test runs in a network namespace whose only interface is `lo` (step 1 of the harness). No
     dial from the test, from a library's own connector, or from the emulator can leave it, whatever
     connector built it. A test that cannot create the namespace FAILS; there is no host-network
     fallback. The farm capability probe gets a required `netns_loopback_only` row (S4): create the
     namespaces of harness step 1 with the two-line uid and gid maps, mount the fresh `/proc`, bring
     up `lo`, run the network self-checks below, and drop a child to uid 65534 *inside* the namespace
     (the existing `uid` row proves the drop only outside it). If the workers refuse it, S4 stops
     there and the choice goes to the project owner (question 10); the tier does not gate a release
     without it.
   - **The self-checks**, run by P1 at the start of every test, before the emulator starts (the
     environment check on E and the outer-uid check run after E's readiness answer, before the
     hand-over). Each failure
     fails the test, naming the check. Each one is listed with the defect it exists to catch, the
     planted form of that defect in S4, and why the check sees it. A check that also passes on the
     worker's own network is not a check of the namespace, so none of the network checks is "a
     connect fails": on the worker's network a connect to an unused address also fails, by timeout
     or `EHOSTUNREACH`, and on a worker that is not a cloud VM so does a connect to the metadata
     address.
     - **A different network namespace.** P0 passes P1 the inode of its own `/proc/self/ns/net`; P1
       requires its own to differ. *Catches:* the clone without `CLONE_NEWNET`, or a re-exec that
       never entered the namespace. *Planted:* the shim with `CLONE_NEWNET` removed; the inodes are
       equal, and the check is red.
     - **Only `lo` is usable, and it is up.** From `getifaddrs()`: `lo` has `IFF_UP`; every other
       interface has `IFF_UP` clear and no IPv4 or IPv6 address; and `/proc/net/route` (the fresh
       `/proc`, so P1's namespace) holds only its header line. It does not require `lo` to be the only interface:
       a kernel with `ipip`, `sit`, `ip6_tunnel` or `gre` loaded gives every new namespace its
       fallback tunnel devices (`tunl0`, `sit0`, `ip6tnl0`, `gre0` and others), down and
       address-less, unless `net.core.fb_tunnels_only_for_init_net` is set, and such a namespace is
       still loopback-only. The `netns_loopback_only` probe row reports the interface names it sees.
       *Catches:* a namespace that is not loopback-only (an interface moved or created in it and
       brought up), and the same missing `CLONE_NEWNET` (a farm worker has outbound network, so a
       second interface is up with an address and a route). *Planted:* the harness creates a dummy
       interface in the namespace with an address and a default route; it is up, holds an address,
       and `/proc/net/route` has a line, so the check is red three ways. A second planted defect,
       `lo` left down, fails the `lo` flag. *Green-expected row:* the harness creates a dummy
       interface left down with no address (the shape of a fallback tunnel); the check stays green,
       which kills the over-strict "exactly one interface" form.
     - **No route, by error code.** A non-blocking connect to a TEST-NET address of RFC 5737 and to
       each link-local metadata address (`IMDS_IPV4_HOST` in `komira_aws_core/imds_credentials.mojo`,
       `METADATA_IP` in `komira_gcp_core/token_wire.mojo`, the Azure IMDS address in
       `komira_azure_core`, the AWS container-credentials address) must fail at once with
       `ENETUNREACH`. Any other result fails the check: success, `EINPROGRESS` followed by a timeout,
       `EHOSTUNREACH` or `ECONNREFUSED`. *Catches:* any route out of the namespace. *Planted:* the
       dummy-interface defect above; with a default route the connect is `EINPROGRESS`, not
       `ENETUNREACH`, and the check is red even if the interface check were removed.
     - **PID 1.** `getpid() == 1`. *Catches:* the clone without `CLONE_NEWPID`, which would also
       make step 6's `kill(-1, SIGKILL)` reach every process the action's uid may signal on the
       worker; step 6 runs the kill only after this check. *Planted:* the shim with `CLONE_NEWPID`
       removed; `getpid()` is the worker's pid, and the check is red before any emulator starts.
     - **A fresh, empty `HOME`.** `HOME` names a directory under `TEST_TMPDIR`, created by the
       harness and empty, so no `~/.aws/credentials`, `~/.aws/config` or gcloud
       `application_default_credentials.json` can be found. *Catches:* the action's `HOME` passed
       through. *Planted:* the harness forwards the action's `HOME`; it is not under `TEST_TMPDIR`.
     - **E's environment is exactly the allowlist.** Every key in `/proc/<E>/environ` is in the
       harness's fixed set (`PATH`, `HOME`, `TMPDIR`, `LANG`) or in the keys E's descriptor names;
       any other key fails the check, which names it. Read after the readiness answer, so E has
       exec'd. *Catches:* an environment inherited instead of built from the allowlist, whatever
       variables the action happens to carry. *Planted:* the harness passes the environment
       through; the test target sets `KOMIRA_TIER_CANARY=1`, which no allowlist names, and the check
       is red on it (and on every other inherited key). The lint refuses a descriptor whose keys
       include a credential variable: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
       `AWS_SESSION_TOKEN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_CONTAINER_CREDENTIALS_*`,
       `GOOGLE_APPLICATION_CREDENTIALS`, `CLOUDSDK_CONFIG`, `GCE_METADATA_HOST`, `AZURE_*`,
       `IDENTITY_ENDPOINT`, `MSI_ENDPOINT`. *Planted:* a descriptor listing `AWS_ACCESS_KEY_ID`; the
       lint test is red.
     - **No credential variable in P1's environment.** P1 runs the package's own code under test,
       which needs the test action's variables, so its environment is not rebuilt; this check is a
       denylist (the names above) and says only that none of them is set. *Planted:* the test target
       sets `AWS_ACCESS_KEY_ID` to a dummy value; the check names it.
     - **No process in the namespace runs as outer uid 0.** Harness step 3, by P0, with no
       condition. *Planted:* the drop skipped; the "is P0 uid 0" test forced to "no".
   - **The worker assumption, stated.** Farm actions run as uid 0 with outbound network
     ([ci.md](../ci.md#what-a-farm-test-action-can-do), rows `uid` and `egress`). Whether a worker is a
     cloud VM with an attached identity is **not verified here**. The design does not depend on the
     answer: an attached identity is reachable only through the metadata address, a credential file
     or a variable, and the namespace plus the self-checks remove all three. A new reported probe row,
     `ambient_identity`, records whether the metadata address answers *outside* the namespace, so
     the assumption is visible.
   - **The connector** (defence in depth). `LoopbackOnlyConnector[C: Connector]` wraps the real
     connector and refuses any `connect` whose address is outside `127.0.0.0/8`, before a socket is
     opened. The check runs on the address after DNS (`Connector.connect` takes the resolved
     `ip_be: UInt32`, `src/komira_http_core/transport/io_stream.mojo`), so a host name that resolves
     to a public address is refused as well. It covers what the harness hands out; it cannot cover a
     library's own connectors (the table above), which is why it is not the guarantee.
   - **The credential** (defence in depth). If a request escaped both, it would carry a dummy key,
     which any cloud rejects, and a rejected unauthenticated request is not billed.
4. **No upload and no cluster write from the tier.** Emulators are build inputs. The tier publishes
   nothing; only the `gamma` and `prod` jobs publish, as they do today.
5. **Third-party code runs unprivileged.** Where the action runs as uid 0, as every farm action
   does, every emulator and its runtime run as `nobody` (harness step 2; a failed drop fails the
   test), inside the namespace, with a state directory as the only place they may write. The pins
   are sha256 only; a pin bump is a reviewed PR that names the upstream release. This narrows, and
   does not remove, the farm's exposure described in
   [What farm access means](../ci.md#what-farm-access-means): the test process itself still runs as
   the action's user.

## Rollout

Each slice can be merged on its own, in this order. The proof of each slice is one of: a check that is
red before the slice and green after it; a planted mutant that turns the slice's own check red; or,
where neither exists, a stated residual risk. **Go** marks a step that needs the project owner's
explicit go. Everything else is code that publishes nothing on its own.

| # | slice | proof | go |
|---|---|---|---|
| S0 | **Lock gamma.** `gamma`'s deployment branches set to `main`. `gamma-breakglass` created with a required reviewer, and administrator bypass unchecked. The gamma channel's second trusted publisher confirmed. These are settings. Plus a drift check: the release's `build` step, which runs from `main`, reads `gamma`'s environment through the API and fails the release if its branch policy is not `main` only. | Before: the drift check fails on today's settings. After the settings change: it passes. Planted: the check run against a canned environment answer with no policy turns red. Whether the job's token may read environments is S0's first check; if it may not, the drift check is a documented manual read and S0 says so. A drift check detects; it does not lock: only the settings lock. | **Go** (repository settings) |
| S1 | **The release ledger** (`release/unreleased.textproto`, a `[conda_status]` sub-target, `release_ledger_check` in `release/BUCK`). Fix `docs/releases.md`'s "Held" list. | A planted library that is in neither file turns the check red. A ledger `NATIVE` row on a library that is not native turns it red. | none |
| S2 | **Declare the 21 non-native libraries:** #1136, #1138, then three declare PRs. | Before merge: the PR's ledger check is red until the library leaves `PENDING_DECLARE`, and its `[release]` builds in the pull-request check. **Residual risk:** `install-set` runs only after merge, so the new name reaches `gamma` before any installed check; a failure stops `prod`, and `gamma` keeps the bad name. | **Go per PR:** a merged declare PR publishes permanent names to `gamma` and then `prod` |
| S3a | **The cloud-check refusal, analysis half:** the `release_checks` label attribute and the `_conda_facts` refusal of an empty list; `NO_CLOUD_CHECK` in the ledger. | Planted: a cloud-family fixture library with `release_checks = []` turns `[release]` red; naming one target turns it green. **Residual risk until S10c:** the named target is not checked to exist, to reach the library or to be unquarantined; no cloud declare PR merges before S10c. | none |
| S3 | **Native packaging,** #835 and its stack. Then declare the `NATIVE` and `DLOPEN` rows in ledger-sized PRs; each cloud declare PR depends on S3a, S10c and its family's suite. | As S2 (ledger check and `[release]` before merge; `install-set` after). For a cloud library, `[release]` is red without a check (S3a). The installed `.so` check is S12. | **Go:** the #835 decision, then per declare PR as in S2 |
| S4 | **`komira_test_emulator`:** the namespace and its self-checks, process start as PID 1 with the two-line uid map and the drop to `nobody`, the inherit list and the allowlisted environment, readiness and the outer-uid check, stop, `LoopbackOnlyConnector`, the tier lint; probe rows `netns_loopback_only` (required) and `ambient_identity` (reported). | Mutants, each turning a named test red. **Range:** the refusal test uses a counting inner connector and asserts zero inner connects for a TEST-NET address; rows for the byte-swapped form of `127.0.0.1` (refused), the addresses just below and just above `127.0.0.0/8` (refused) and its last address (accepted) kill a byte-order mutant and the edge mutants. **Killed harness:** an outer test creates a pipe and starts P0 with the pipe's write end W on the harness's inherit list (step 2), so W reaches P1, E and G while every other descriptor is closed; the outer test closes its own copy of W. The fake emulator E starts a grandchild G that calls `setsid`. P1, E and G each write one byte naming themselves (`P`, `E`, `G`) through W, then block in `pause()`; P1 writes after the readiness answer and never reaches step 6, so its body blocks until it is killed. **Armed first:** the outer test reads until it holds all three bytes, within the start-up budget; EOF or the budget before that fails the test as "oracle not armed", never as a pass, and each byte proves its writer was alive and held W. Only then does it SIGKILL P0, the outermost process (as the probe's `pdeathsig` row does), and require EOF within 10 s: EOF arrives only when every holder of W is gone, in any namespace, so the oracle does not depend on the mechanism it checks. On red, the outer test names and SIGKILLs every process whose `/proc/<pid>/fd` links to the pipe's inode, so a mutant run leaves nothing behind. Three mutants, each red as written: (1) P1's death signal dropped (`PR_SET_PDEATHSIG`; util-linux's `--kill-child`): the three bytes arrive, P1 outlives P0 holding W, and it cannot finish its body and stop everything itself because the body blocks, so no EOF. (2) `CLONE_NEWPID` dropped with the death signal kept: without a new PID namespace the fresh-`/proc` mount fails, the PID 1 check fails, and the outer-uid scan matches every process on the worker; each would fail the test before the oracle is armed, so this run bypasses the mount and disables those two checks, keeping step 6's own `getpid() == 1` guard; the three bytes arrive, the kill takes P1 but leaves E and G, re-parented outside, holding W, so no EOF. (3) A harness that ignores the inherit list and closes W before exec: E's and G's bytes never arrive, so the read ends in the budget (P1 still holds W) or in EOF (it lost W too) before all three bytes, and the test is red as not armed. Neither of the first two links masks the other. **Normal stop:** a fake emulator whose G calls `setsid` and writes its namespace pid to the state directory; after stop, `kill(G, 0)` answers `ESRCH` and the fresh `/proc` holds only pid 1. The mutant that stops by signalling E's process group only (no `kill(-1, SIGKILL)` sweep) leaves G alive, and both assertions turn red. **Readiness:** against a fake emulator that never answers, "not ready treated as ready" and "budget ignored" each turn the readiness test red (it expects a failure naming the emulator within the budget); against one that answers once and exits, dropping the alive-after-answer check turns it red. **No skip:** a descriptor pointing at a missing file turns the test red. **Namespace and self-checks:** each self-check of safety rule 3 with its own planted defect, as listed there: `CLONE_NEWNET` removed (red on the namespace inode and the interface list), a dummy interface with a default route (red on the interface list and on `ENETUNREACH`), `lo` left down, a down address-less dummy interface (green-expected: the fallback-tunnel shape), `CLONE_NEWPID` removed (red on PID 1), the action's `HOME` forwarded, the environment passed through (red on `KOMIRA_TIER_CANARY`), a credential variable set in P1's environment, the drop to `nobody` skipped and the "is P0 uid 0" test forced to "no" (each red on the outer-uid check). **Lint:** a tier test calling `process_creds_source` turns red; a descriptor whose environment keys include `AWS_ACCESS_KEY_ID` turns red; one calling `build_gcs_tls_connector_trusting` stays green (whole-identifier match). | none |
| S5 | **moto, pinned wheels,** with the first AWS suite: STS through the chain, s3, sqs, secretsmanager, `komira_objectstore_s3` | A planted serialization bug (a required parameter dropped from `ReceiveMessage`) turns the round trip red. The corrupted-signature mutant with moto's authentication on decides whether the tier claims SigV4. | **Go (one-time ruling):** moto over LocalStack, and third-party emulator packages as build inputs (decisions 3 and 5) |
| S6 | **The remaining AWS packages:** round-trip tables for the other client-mode services, the pure-mode shim, and the `komira_aws_metrics` probe | a planted bug per package (for example, a pagination token not echoed in `ListObjectsV2` or `Scan`) | none |
| S7 | **GCP:** the Firestore emulator (pinned JRE and jar) for the document client and firestore_db; storage-testbench's gRPC plaintext checked, then `komira_gcp_storage`'s unary methods | a planted precondition bug (an ignored `currentDocument.exists`) turns the Firestore suite red; a planted generation-match bug (an ignored `if_generation_match` on DeleteObject) turns the storage suite red | **Go:** the Firestore emulator's redistribution terms checked and accepted |
| S7b | **GCP streaming** (proposed, not scheduled): h2c for `server_stream` and the client stream in `komira_grpc`, a connector parameter on `FirestoreWatchSource` and the GCS backend, or a pinned TLS terminator; then Listen, ReadObject, WriteObject and `komira_objectstore_gcs` join | a planted range bug (an off-by-one `read_offset` in ReadObject) turns the streaming suite red | none (a TLS terminator is a third-party input: decision 5) |
| S8 | **Azure:** a probe to choose Azurite's form, then the blob suite | a planted bug in the `NextMarker` loop turns list pagination red | none (unless the probe picks containers: then decision 5) |
| S9 | **Fixtures:** the provenance, schema, secret, dead-fixture and generator-independence lints; fixtures for the packages that have no emulator | a planted fixture without provenance; a planted unknown field; a planted bearer token; a fixture generator that imports `tools/build/cloud`. Each turns the lint red. | none |
| S10a | **kci built once per revision** (#1153) | a release whose kci is unchanged spends the cached-build time on "build kci" in every job but the first | none |
| S10b | **The release build in batches** | a cold full release (every package re-keyed) finishes in batches each under `--build-timeout-s` | none |
| S10c | **Release checks:** a `checks:` field on the BUILD step that runs (`buck2 test`) the derived checks reaching a declared library plus every `release_checks` target; the flake re-run and `release/quarantine.textproto`; the reach check of `release_checks` (cquery `rdeps`), at release time and in the pull-request check; the reverse-dependency filter on the derived checks. First task: measure its time and farm cost on a release revision and write them in this document. | a machine-file fixture whose check target fails: `kci run --stage build` fails and `gamma` never starts; a check that fails once then passes is re-run once and passes; a `release_checks` naming an unrelated library's test, a label with no target, and a library whose only check is quarantined each fail `build` | none: it adds a gate to an approved pipeline |
| S11 | **Yank:** verify that the channel host can delete a file or mark it removed; a `kci yank` verb, dry run by default; `release/yanked.textproto` and `KCI-E-YANKED` | a dry run against the fake channel lists exactly one file. A real run is refused without `--channel` and `--file`. A re-run of a commit older than the tombstone, whose own tree does not name the file, is refused before any upload in `gamma` (the tombstone is read from `main`'s head); a kci that reads the checked-out copy turns that test red. | **Go per use** |
| S12 | **Installed-bytes checks** in `validate` (after S3): one emulator round trip per cloud family against the installed package, and the installed `.so` check (decision item 8) | a planted missing `.so` in a fixture package turns it red; a fixture `.so` with a `GLIBC_` version above the floor turns it red | **Go:** decision 1 (a `service` block in gamma) and the workflow-rule amendment (item 7) |

S0 is independent of the rest and should go first. S4 to S10c can start at once, in parallel with S2
and S3, because they test source code. S3's cloud declare PRs cannot merge before S3a, S10c and their
family's suite: S3a makes that a build failure, not a convention.

## Questions for the project owner

Each has a recommendation. None is decided here.

1. **Lock gamma now (S0)?** *Recommendation:* yes, today. It is two settings, and until they exist any
   branch can publish to `gamma` (it cannot reach `prod`; see above).
2. **Is merging a declare PR the go for its new names?** A merged declare PR publishes names to
   `gamma` and then to `prod`, permanently and with no further click. *Recommendation:* yes, the merge
   is the go. The `gamma` job summary already lists "NEW NAMES" for `prod`.
3. **Native packaging (#835).** 139 of the 161 unreleased libraries, and every cloud SDK package,
   wait on it. *Recommendation:* decide #835 next. Nothing else in this document moves the count as
   much.
4. **moto, not LocalStack, for AWS.** *Recommendation:* moto. LocalStack needs a token (a secret), its
   free plan is for non-commercial use, and ECR and ECS are behind a paid plan.
5. **Pinned third-party emulators as build inputs** (moto and its wheel set, storage-testbench, the
   Firestore emulator, Azurite, and their runtimes), run as `nobody` in a loopback-only namespace.
   *Recommendation:* yes, by sha256 only. Accept the Firestore emulator's terms before pinning it.
6. **Where the cloud tier gates.** *Recommendation:* the release checks in `build`, before `gamma`
   (S10c), once their measured cost fits. The installed-bytes checks in `validate`, before `prod`, once
   #835 ships native packages (S12), because that is when the build stops being able to see the
   defect.
7. **Yank.** *Recommendation:* approve the mechanism (S11), with the tombstone, and each use still a
   separate go.
8. **Fixtures from a live cloud.** *Recommendation:* no. It needs an account and a credential, so the
   fixture tier uses models, documented examples and emulators only. Revisit together with real gamma
   projects (decision 4).
9. **The Pub/Sub, Bigtable, Spanner, Datastore and Cosmos DB emulators.** komira has no client for any
   of them. *Recommendation:* adopt each emulator in the PR that adds its client, with this harness.
10. **If the farm refuses a loopback-only namespace** (S4's `netns_loopback_only` row fails).
    *Recommendation:* the tier then does not gate releases, and the farm operator enables
    unprivileged user namespaces on the workers. The alternative, connector parameters on every
    library in the seams table plus the lint as the only guarantee, leaves any future library
    that builds its own connector able to dial out; it is not recommended.
11. **The tier as a gate on every release.** Every affected PR and every release starts its emulators
    again (test results are not cached), and one flaky emulator blocks prod until it is re-run,
    quarantined or fixed. *Recommendation:* accept, with the re-run-once policy and quarantine by PR,
    once S10c's measurement is in.
12. **GCP streaming (S7b).** Firestore Listen, GCS streaming and `komira_objectstore_gcs` stay out of
    the tier until it lands. *Recommendation:* schedule S7b after S7, choosing h2c streaming in
    `komira_grpc` over a third-party TLS terminator, because it adds no new pinned input and the
    library gains a route it lacks today.
